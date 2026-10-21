//! The core's side of the conversation with the page.
//!
//! ## Why a URI scheme and not a buffer
//!
//! The engine's window is the engine's: `wpe_view_wayland_get_wl_surface` publishes a
//! surface this framework can read but not draw into, and there is no snapshot API and no
//! buffer the engine will hand over. So a channel that ends in "the engine sends us its
//! frames" cannot be built on this ABI, and pretending otherwise would be a design built on
//! a door that was measured to be closed.
//!
//! What the engine does support is calling back. Registering a scheme makes the page's
//! request land in this process, with the request object in hand, and lets this code
//! answer with a stream built over memory it already owns. That inverts the direction of
//! the zero-copy claim in the useful way: nothing is copied *out of* the engine, and the
//! bytes the page receives are the core's own bytes, served where they lie.
//!
//! ## What this is not
//!
//! It is not a general RPC system and it does not pretend to be one. It answers requests,
//! counts them, and hands back a body. A real bridge needs a message format, a request
//! identifier and a way to stream a large body in pieces; all three belong to whoever first
//! needs them, and inventing them now would be a protocol designed by imagination.
//!
//! ## Lifetime
//!
//! WebKit may call the callback at any time until the context is dropped, and it holds the
//! user-data pointer for exactly as long as the registration. The body is therefore held
//! here, in a context-level variable, rather than in a caller's stack frame: a response
//! backed by a frame that has returned is a use-after-return that would show up as a
//! truncated page rather than as a crash.

const std = @import("std");
const assets = @import("assets.zig");
const transport = @import("transport.zig");
const respond = @import("respond.zig");
const secret = @import("secret.zig");
const invoke = @import("invoke.zig");
const events = @import("events.zig");
const region = @import("region.zig");
const record = @import("record.zig");
const page_replay = @import("page_replay.zig");
const wire = @import("../../ipc/wire.zig");

/// The engine's request object: WebKit's or WebView2's, the same calls on both.
const engine = @import("request.zig");

/// The scheme the page addresses the core on. Short on purpose: it appears in every
/// request the page makes and in every string in the frontend that builds one.
pub const scheme = "lepton";

/// What the bridge has seen, for a caller to report rather than guess at.
pub const Counters = struct {
    /// Requests the engine delivered. The figure that proves the door is open: a bridge
    /// with none of these answered every call with a body nobody asked for.
    requests: u32 = 0,
    /// Requests that could not be answered, usually because the stream could not be made.
    refused: u32 = 0,
    /// Bytes handed back, counted at answer time rather than at read time. What the page
    /// received depends on how much of it it read; what was served does not.
    bytes_served: u64 = 0,
};

/// The bridge the engine's callback reaches.
///
/// File scope, because the pointer is handed to the engine and used whenever a request
/// arrives — not during the call that registered it.
var registered: ?*Bridge = null;

/// The path of the request the bridge last answered.
///
/// The page reports back through this: it has no other way to be heard, because the core
/// cannot read the document. A check that wanted to know what the page concluded has to
/// listen here rather than guess.
pub fn lastPath() ?[]const u8 {
    const bridge = registered orelse return null;
    if (bridge.path_len == 0) return null;
    return bridge.path[0..bridge.path_len];
}

/// The registered bridge.
///
/// One per web context. The body is copied in rather than pointed at, because the caller
/// that produced it may well have returned by the time the page's request arrives.
/// How many `invoke` requests may wait for a later answer at once — open file dialogs.
pub const max_later = 8;
/// How many pages may wait on `/__lepton/region` at once; one more evicts the oldest.
pub const max_region_held = 4;

const Later = struct {
    request: ?*anyopaque = null,
    generation: u32 = 0,
    /// The command was `private`: its late reply is recorded masked too.
    private: bool = false,
};

pub const Bridge = struct {
    body: [8192]u8 = @splat(0),
    body_len: usize = 0,
    content_type: [64]u8 = @splat(0),
    content_type_len: usize = 0,

    /// The path of the most recent request.
    ///
    /// Read from the request rather than remembered from an earlier one: a bridge that
    /// reported the last path it last *saw* would look busy while answering nothing.
    path: [128]u8 = @splat(0),
    path_len: usize = 0,
    counters: Counters = .{},

    /// The directory `lepton://localhost/` is served from; empty until `serveFrom`.
    asset_root: [assets.max_path]u8 = @splat(0),
    asset_root_len: usize = 0,

    /// The ring the page snapshots at `/__lepton/region`; empty until `exposeRegion`.
    region: []const u8 = &.{},
    /// Region requests waiting for the ring to move past their `after`: one per page (a
    /// `window.open` view is a second), and one a page abandoned until it is answered.
    region_held: [max_region_held]?*anyopaque = @splat(null),
    region_after: [max_region_held]u64 = @splat(0),
    region_evict: usize = 0,
    /// Set when the page asked at `/__lepton/close`; the owner's loop reads it.
    close_requested: bool = false,
    /// One request frame, plus one byte to tell "exactly the limit" from "more".
    request_frame: [invoke.max_request + 1]u8 = @splat(0),
    /// Requests answered through `invoke`.
    invokes: u32 = 0,
    /// The commands a page may call. Empty until the application sets it: nothing is
    /// granted by default.
    registry: invoke.Registry = .{},
    /// The window the `window.*` commands act on; set by the view that owns it.
    window: invoke.Window = .{},
    /// Events for the page, and the one events request waiting for the next of them.
    events: events.Log = .{},
    held: ?*anyopaque = null,
    held_after: u64 = 0,
    /// `invoke` requests a command answers later (`invoke.takeLater`): referenced until
    /// `finishLater`. The generation tells a stale `Later` from the slot's next owner.
    later: [max_later]Later = @splat(.{}),
    /// Every request and reply, when `LEPTON_RECORD` names a file (`record.zig`).
    recorder: ?record.Recorder = null,
    /// A command is running: an event emitted now belongs to its request.
    handling: bool = false,
    /// `LEPTON_REPLAY_PAGE=<file>`: the page's calls answered from a recording.
    page_replay: ?page_replay.Script = null,
    /// The one origin answers may be read from cross-origin (the dev server's), or empty.
    allowed_origin: [respond.max_origin]u8 = @splat(0),
    allowed_origin_len: usize = 0,

    /// Answers `/__lepton/region` with `bytes`, served in place from the mapping. The
    /// mapping must outlive the view, which is the channel's lifetime in the template.
    pub fn exposeRegion(self: *Bridge, bytes: []const u8) void {
        self.region = bytes;
    }

    /// Lets the page at `url`'s origin read this bridge's answers — the dev server, whose
    /// page fetches the ring from `lepton://localhost`. Refused (false) for anything that
    /// is not an absolute URL: a malformed origin would allow nothing and hide why.
    pub fn allowOriginOf(self: *Bridge, url: []const u8) bool {
        const origin_text = respond.originOf(url, &self.allowed_origin) orelse return false;
        // The window's own page from now on (`features.isOwnPage`): nothing else of this
        // machine's is.
        @import("features.zig").setPageOrigin(origin_text);
        self.allowed_origin_len = origin_text.len;
        return true;
    }

    /// The owner published into the ring: the pages waiting for it are answered now.
    /// Called after `Channel.publishLatest`, so an idle page sleeps instead of re-reading.
    pub fn published(self: *Bridge) void {
        const newest = region.position(self.region);
        for (&self.region_held, self.region_after) |*slot, after| {
            const waiting = slot.* orelse continue;
            if (newest == after) continue;
            slot.* = null;
            self.sendRegion(waiting, after);
            engine.unref(waiting);
        }
    }

    /// `/__lepton/region?after=N`: the frames published since `N` (`region.zig`), now
    /// when there are any, otherwise held until `published`. With every slot taken, the
    /// oldest hold is answered empty — the page asks again — and released.
    fn answerRegion(self: *Bridge, request: ?*anyopaque) void {
        const uri = engine.uri(request);
        const after = events.afterOf(uri);
        if (after == 0 or region.position(self.region) != after) {
            self.sendRegion(request, after);
            return;
        }
        const index = for (self.region_held, 0..) |slot, i| {
            if (slot == null) break i;
        } else evict: {
            const i = self.region_evict;
            self.region_evict = (i + 1) % max_region_held;
            const stale = self.region_held[i].?;
            _ = respond.bytes(stale, "", 0, null, "application/octet-stream", self.origin());
            engine.unref(stale);
            break :evict i;
        };
        self.region_held[index] = engine.ref(request);
        self.region_after[index] = after;
    }

    fn sendRegion(self: *Bridge, request: ?*anyopaque, after: u64) void {
        const len = region.deltaLen(self.region, after) orelse {
            // No destroy: the bytes are the live mapping, owned by the channel.
            if (respond.bytes(request, self.region.ptr, self.region.len, null, "application/octet-stream", self.origin())) {
                self.counters.bytes_served += self.region.len;
            } else self.counters.refused += 1;
            return;
        };
        const raw = std.c.malloc(len) orelse {
            respond.refuse(request, "no memory for the frames");
            return;
        };
        const out: [*]u8 = @ptrCast(raw);
        region.writeDelta(self.region, after, out[0..len]);
        if (respond.bytes(request, out, len, std.c.free, "application/octet-stream", self.origin())) {
            self.counters.bytes_served += len;
        }
    }

    /// The dev server's origin the page is served from, or "" for a packaged page.
    pub fn pageOrigin(self: *Bridge) []const u8 {
        return self.allowed_origin[0..self.allowed_origin_len];
    }

    fn origin(self: *Bridge) [:0]const u8 {
        return self.allowed_origin[0..self.allowed_origin_len :0];
    }

    /// The dev server's origin the page may come from, "" without one.
    pub fn devOrigin(self: *const Bridge) []const u8 {
        return self.allowed_origin[0..self.allowed_origin_len];
    }

    /// Serves the bundled frontend at `lepton://localhost/` from `root` (absolute).
    pub fn serveFrom(self: *Bridge, root: []const u8) void {
        self.asset_root_len = @min(root.len, self.asset_root.len);
        @memcpy(self.asset_root[0..self.asset_root_len], root[0..self.asset_root_len]);
    }

    /// Registers `lepton://` against `context`, for *this* bridge (WPE; WebView2's view
    /// delivers its requests itself).
    ///
    /// Takes the pointer rather than returning a value, and that is the whole reason:
    /// WebKit holds the user-data pointer until the context is dropped, so registering the
    /// address of a local here and handing back a copy would leave the engine calling a
    /// returned frame — which reads as a bridge that never receives anything, forever.
    pub const attach = if (@TypeOf(engine.attach) == void) {} else attachToContext;

    fn attachToContext(self: *Bridge, context: ?*anyopaque) void {
        engine.attach(Bridge, self, context, scheme);
    }

    /// Answers one request the engine delivered.
    pub fn deliver(self: *Bridge, request: ?*anyopaque) void {
        registered = self;
        if (tracing()) {
            std.debug.print("lepton request {s} {s} origin={s} referer={s}\n", .{
                engine.method(request),
                engine.uri(request),
                engine.header(request, "Origin") orelse "-",
                engine.header(request, "Referer") orelse "-",
            });
        }
        self.answer(request);
    }

    /// Sets what the next requests are answered with.
    ///
    /// Copied, not referenced. The caller owns its bytes and may return; a bridge that read
    /// through a pointer it was given would answer the next page load from freed memory.
    pub fn setBody(self: *Bridge, bytes: []const u8, kind: []const u8) void {
        self.body_len = @min(bytes.len, self.body.len);
        @memcpy(self.body[0..self.body_len], bytes[0..self.body_len]);

        self.content_type_len = @min(kind.len, self.content_type.len);
        @memcpy(self.content_type[0..self.content_type_len], kind[0..self.content_type_len]);
    }

    /// Answers a frontend request with the file it names, read whole into a buffer the
    /// engine frees (libc `free`) when its stream is done.
    fn serveAsset(self: *Bridge, request: ?*anyopaque) void {
        const raw_path = engine.path(request) orelse "/";
        var path_buffer: [assets.max_path]u8 = undefined;
        const file = assets.resolve(self.asset_root[0..self.asset_root_len], raw_path, &path_buffer) catch {
            self.counters.refused += 1;
            refuse(request, "the path leaves the frontend directory");
            return;
        };
        const loaded = assets.load(file) orelse {
            self.counters.refused += 1;
            respond.missing(request, "no such file in the frontend");
            return;
        };
        if (!respond.bytes(request, loaded.bytes, loaded.len, std.c.free, assets.mimeFor(file), self.origin())) {
            self.counters.refused += 1;
            return;
        }
        self.counters.bytes_served += loaded.len;
    }

    /// Answers one request: a file for `lepton://localhost/`, the channel body otherwise.
    /// Publishes an event to the page: appended to the log, and answered at once to a
    /// request waiting for it.
    pub fn emit(self: *Bridge, name: []const u8, data: []const u8) events.EmitError!u64 {
        const number = try self.events.emit(name, data);
        if (self.recorder) |*recorder| {
            var frame: [wire.header_bytes + @sizeOf(wire.Notice) + events.max_name + events.max_data]u8 = undefined;
            if (self.events.writeSince(number - 1, &frame)) |written| {
                recorder.addEvent(name, written, self.handling);
            } else |_| {}
        }
        if (self.held) |waiting| {
            self.held = null;
            self.sendEvents(waiting, self.held_after);
            engine.unref(waiting);
        }
        return number;
    }

    /// `/__lepton/events?after=N`: answered now when there is something newer, otherwise
    /// held until `emit`. A page has one such request open at a time, so a new one means
    /// the previous was abandoned (the page aborts after `events.hold_ms`): it is answered
    /// empty and released, never left referenced.
    fn answerEvents(self: *Bridge, request: ?*anyopaque) void {
        const uri = engine.uri(request);
        if (events.wantsLatest(uri)) {
            const raw = std.c.malloc(8) orelse {
                respond.refuse(request, "no memory for the answer");
                return;
            };
            const out: *[8]u8 = @ptrCast(raw);
            std.mem.writeInt(u64, out, self.events.latest, .little);
            _ = respond.bytes(request, out, 8, std.c.free, "application/octet-stream", self.origin());
            return;
        }
        const after = events.afterOf(uri);
        if (self.held) |stale| {
            self.held = null;
            _ = respond.bytes(stale, "", 0, null, "application/octet-stream", self.origin());
            engine.unref(stale);
        }
        if (self.events.hasAfter(after)) {
            self.sendEvents(request, after);
            return;
        }
        self.held = engine.ref(request);
        self.held_after = after;
    }

    fn sendEvents(self: *Bridge, request: ?*anyopaque, after: u64) void {
        const raw = std.c.malloc(events.max_response) orelse {
            respond.refuse(request, "no memory for the events");
            return;
        };
        const out: [*]u8 = @ptrCast(raw);
        const bytes = self.events.writeSince(after, out[0..events.max_response]) catch {
            std.c.free(raw);
            respond.refuse(request, "the events do not fit");
            return;
        };
        if (respond.bytes(request, out, bytes.len, std.c.free, "application/octet-stream", self.origin())) {
            self.counters.bytes_served += bytes.len;
        }
    }

    /// Reads the POSTed request frame, handles it, and answers with the reply frame.
    ///
    /// The reply is written into memory the engine frees when it has read it: a second
    /// request may arrive before the first response is consumed, so a buffer kept here
    /// could be overwritten under the engine.
    fn answerInvoke(self: *Bridge, request: ?*anyopaque) void {
        if (!std.mem.eql(u8, engine.method(request), "POST")) {
            self.counters.refused += 1;
            respond.refuse(request, "invoke takes a POST");
            return;
        }
        const read = engine.body(request, &self.request_frame) catch |failure| {
            self.counters.refused += 1;
            respond.refuse(request, switch (failure) {
                error.Missing => "invoke needs a request frame as its body",
                error.Unreadable => "the request body could not be read",
            });
            return;
        };
        if (read > invoke.max_request) {
            self.counters.refused += 1;
            respond.refuse(request, "the request frame is larger than invoke accepts");
            return;
        }

        if (self.page_replay) |*script| {
            if (self.answerFromRecording(script, request, self.request_frame[0..read])) return;
        }

        const raw = std.c.malloc(invoke.max_reply) orelse {
            self.counters.refused += 1;
            respond.refuse(request, "no memory for the reply");
            return;
        };
        const out: [*]u8 = @ptrCast(raw);
        var effects: invoke.Effects = .{};
        const free_slot: ?u16 = for (self.later, 0..) |slot, index| {
            if (slot.request == null) break @intCast(index);
        } else null;
        if (free_slot) |index| {
            effects.later = .{
                .context = self,
                .finish_fn = &finishLater,
                .slot = index,
                .generation = self.later[index].generation,
            };
            // Held before the command runs: one that fails at once calls `finish` while
            // it is still running, and that answer must find the request already here —
            // with whether it is private, or that late reply would be recorded unmasked.
            self.later[index].request = engine.ref(request);
            self.later[index].private = if (record.commandOf(self.request_frame[0..read])) |id| self.registry.isPrivate(id) else false;
        }
        const begun = if (self.recorder) |*recorder| recorder.now() else 0;
        self.handling = true;
        const answered = invoke.handle(self.request_frame[0..read], &self.registry, self.window, &effects, out[0..invoke.max_reply]);
        self.handling = false;
        if (!effects.deferred) if (free_slot) |index| self.release(index);
        const frame = answered catch {
            std.c.free(raw);
            self.counters.refused += 1;
            respond.refuse(request, "the reply does not fit");
            return;
        };
        self.invokes += 1;
        if (self.recorder) |*recorder| {
            const private = if (record.commandOf(self.request_frame[0..read])) |id| self.registry.isPrivate(id) else false;
            recorder.add(.request, self.request_frame[0..read], private, effects.deferred, begun);
            if (!effects.deferred) recorder.add(.reply, frame, private, false, recorder.now());
        }
        if (effects.close_requested) self.close_requested = true;
        if (effects.deferred) {
            // Held until the command calls `finish` — which may already have happened.
            std.c.free(raw);
            return;
        }
        if (!respond.bytes(request, out, frame.len, std.c.free, "application/octet-stream", self.origin())) {
            self.counters.refused += 1;
            return;
        }
        self.counters.bytes_served += frame.len;
    }

    /// A page replay's answer to `frame`, when the recording has one: the events the
    /// command emitted, then the reply — now, or after the recorded delay for a deferred
    /// call. False when the call runs live instead.
    fn answerFromRecording(self: *Bridge, script: *page_replay.Script, request: ?*anyopaque, frame: []const u8) bool {
        const command = record.commandOf(frame) orelse return false;
        const header = wire.readHeader(frame) catch return false;
        const argument = page_replay.argumentOf(frame) orelse return false;
        const call = switch (script.decide(command, argument)) {
            .recorded => |call| call,
            .live => |why| {
                const name = self.registry.nameOf(command) orelse "unknown command";
                switch (why) {
                    .other_argument => std.debug.print("page     {s}: another argument than recorded; run live\n", .{name}),
                    .unrecorded => std.debug.print("page     {s}: called more often than recorded; run live\n", .{name}),
                    .window, .masked => {},
                }
                return false;
            },
        };
        const owed = call.answer orelse return false;
        for (script.eventsOf(call)) |event| {
            const data = event.data orelse {
                std.debug.print("page     event {s} was recorded without its data; not sent\n", .{event.name});
                continue;
            };
            _ = self.emit(event.name, data) catch {};
        }
        self.invokes += 1;
        if (call.deferred and owed.delay_ns >= std.time.ns_per_ms and self.answerAfter(request, header.sequence, owed, self.registry.nameOf(command) orelse "unknown command")) return true;

        const raw = std.c.malloc(invoke.max_reply) orelse {
            respond.refuse(request, "no memory for the reply");
            return true;
        };
        const out: [*]u8 = @ptrCast(raw);
        const reply = invoke.reply(out[0..invoke.max_reply], header.sequence, owed.status, owed.result) catch {
            std.c.free(raw);
            respond.refuse(request, "the reply does not fit");
            return true;
        };
        if (respond.bytes(request, out, reply.len, std.c.free, "application/octet-stream", self.origin())) {
            self.counters.bytes_served += reply.len;
        }
        return true;
    }

    /// A recorded answer owed after a delay, as a timeout's data.
    const Owed = struct {
        bridge: *Bridge,
        slot: u16,
        generation: u32,
        sequence: u64,
        answer: page_replay.Answer,
        name: []const u8,
        started: std.Io.Clock.Timestamp,

        fn fire(data: ?*anyopaque) callconv(.c) c_int {
            const owed: *Owed = @ptrCast(@alignCast(data orelse return 0));
            const io = std.Io.Threaded.global_single_threaded.io();
            const waited = owed.started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
            std.debug.print("page     {s}: the recorded answer after {d} ms (recorded {d} ms)\n", .{
                owed.name,
                @divTrunc(@max(waited, 0), std.time.ns_per_ms),
                owed.answer.delay_ns / std.time.ns_per_ms,
            });
            finishLater(owed.bridge, owed.slot, owed.generation, owed.sequence, owed.answer.status, owed.answer.result);
            std.c.free(owed);
            return 0;
        }
    };

    /// Holds `request` in a free slot and answers it after `answer.delay_ns`; false when
    /// no slot is free (the caller answers now).
    fn answerAfter(self: *Bridge, request: ?*anyopaque, sequence: u64, recorded: page_replay.Answer, name: []const u8) bool {
        const index: u16 = for (self.later, 0..) |slot, at| {
            if (slot.request == null) break @intCast(at);
        } else return false;
        const raw = std.c.malloc(@sizeOf(Owed)) orelse return false;
        const owed: *Owed = @ptrCast(@alignCast(raw));
        owed.* = .{
            .bridge = self,
            .slot = index,
            .generation = self.later[index].generation,
            .sequence = sequence,
            .answer = recorded,
            .name = name,
            .started = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake),
        };
        self.later[index].request = engine.ref(request);
        const ms: c_uint = @intCast(@min(recorded.delay_ns / std.time.ns_per_ms, std.math.maxInt(c_uint)));
        engine.timeoutOnce(ms, &Owed.fire, owed);
        return true;
    }

    /// After the run: prints a page replay's verdict and says whether it passed; null when
    /// this run was not a page replay.
    pub fn pageReplayPassed(self: *Bridge) ?bool {
        const script = if (self.page_replay) |*script| script else return null;
        var report: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer report.deinit();
        script.report(&self.registry, &report.writer) catch return script.passed();
        std.debug.print("{s}", .{report.written()});
        return script.passed();
    }

    /// Drops a slot's hold on a request no command took.
    fn release(self: *Bridge, index: u16) void {
        const held = &self.later[index];
        if (held.request) |request| engine.unref(request);
        held.request = null;
        held.private = false;
        held.generation +%= 1;
    }

    /// `invoke.Later.finish`: answers the held request with a reply frame, once.
    fn finishLater(context: ?*anyopaque, slot: u16, generation: u32, sequence: u64, status: invoke.Status, result: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(context orelse return));
        if (slot >= self.later.len) return;
        const held = &self.later[slot];
        if (held.generation != generation) return;
        const request = held.request orelse return;
        const private = held.private;
        held.request = null;
        held.private = false;
        held.generation +%= 1;
        defer engine.unref(request);
        const raw = std.c.malloc(invoke.max_reply) orelse {
            respond.refuse(request, "no memory for the reply");
            return;
        };
        const out: [*]u8 = @ptrCast(raw);
        const frame = invoke.reply(out[0..invoke.max_reply], sequence, status, result) catch
            invoke.reply(out[0..invoke.max_reply], sequence, .too_large, &.{}) catch {
            std.c.free(raw);
            respond.refuse(request, "the reply does not fit");
            return;
        };
        // Before `respond.bytes`, which hands `out` to the engine to free.
        if (self.recorder) |*recorder| recorder.add(.late_reply, frame, private, false, recorder.now());
        if (respond.bytes(request, out, frame.len, std.c.free, "application/octet-stream", self.origin())) {
            self.counters.bytes_served += frame.len;
        }
    }

    fn answer(self: *Bridge, request: ?*anyopaque) void {
        self.counters.requests += 1;

        // The core's own paths come first, on any host, and only under this run's key
        // (`secret.zig`): a document without the transport cannot name them. Before, any
        // page the engine showed could POST `invoke` (measured on WPE: a sandboxed
        // `srcdoc` frame's request reached the core). Anything else under `/__lepton/` is
        // refused rather than served as a frontend file.
        if (engine.path(request)) |path| {
            if (secret.corePath(path)) |name| {
                if (std.mem.eql(u8, name, transport.region_name) and self.region.len != 0) {
                    self.answerRegion(request);
                } else if (std.mem.eql(u8, name, transport.events_name)) {
                    self.answerEvents(request);
                } else if (std.mem.eql(u8, name, transport.invoke_name)) {
                    self.answerInvoke(request);
                } else if (std.mem.eql(u8, name, transport.close_name)) {
                    self.close_requested = true;
                    const ok = "closing";
                    _ = respond.bytes(request, ok.ptr, ok.len, null, "text/plain", self.origin());
                } else {
                    respond.refuse(request, "no such path in the core");
                }
                return;
            }
            if (std.mem.startsWith(u8, path, "/__lepton/")) {
                respond.refuse(request, "the core answers its own page only");
                return;
            }
        }

        if (self.asset_root_len != 0) {
            if (std.mem.eql(u8, hostOf(engine.uri(request)), assets.host)) {
                self.serveAsset(request);
                return;
            }
        }

        if (engine.path(request)) |text| {
            self.path_len = @min(text.len, self.path.len);
            @memcpy(self.path[0..self.path_len], text[0..self.path_len]);
        }

        // An empty body is a refusal dressed as a success: the page would receive a
        // zero-length response and read it as an empty document. Refusing leaves the page
        // with an error it can report, which is the difference between a bridge that is
        // not ready and a bridge that is broken.
        if (self.body_len == 0) {
            self.counters.refused += 1;
            respond.refuse(request, "the core has no response to give");
            return;
        }

        // The content type has to be NUL-terminated on the C side and the buffer here is
        // a fixed-size array that is not, so the terminator is written before the call
        // rather than assumed.
        self.content_type[self.content_type_len] = 0;
        if (!respond.bytes(request, &self.body, self.body_len, null, @ptrCast(&self.content_type), self.origin())) {
            self.counters.refused += 1;
            return;
        }
        self.counters.bytes_served += self.body_len;
    }
};

/// The host of a `scheme://host/path` URI, or "" when there is none.
/// `LEPTON_TRACE_REQUESTS=1`: every request the engine delivers, with the headers that say
/// who sent it — how each engine's origins were measured.
fn tracing() bool {
    const value = std.c.getenv("LEPTON_TRACE_REQUESTS") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

pub fn hostOf(uri: []const u8) []const u8 {
    const start = (std.mem.indexOf(u8, uri, "://") orelse return "") + 3;
    const rest = uri[start..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return rest[0..end];
}

fn refuse(request: ?*anyopaque, message: [*:0]const u8) void {
    respond.refuse(request, message);
}

test "every request path the bridge answers is compiled" {
    // Zig analyses only what is referenced: `answerInvoke` once carried a field the
    // struct did not have and every test still passed, because nothing reached it. The
    // first real build of a project failed instead. This reference makes the test build
    // compile the whole request path. Only where the engine is linked: a native build
    // has no WebKit symbols to resolve these against.
    if (comptime !@import("root.zig").is_available()) return error.SkipZigTest;
    std.testing.refAllDecls(Bridge);
    _ = &Bridge.answer;
    _ = &Bridge.answerInvoke;
    _ = &Bridge.finishLater;
    _ = &Bridge.answerFromRecording;
    _ = &Bridge.pageReplayPassed;
    _ = &Bridge.answerEvents;
    _ = &Bridge.answerRegion;
    _ = &Bridge.published;
    _ = &Bridge.emit;
    _ = &Bridge.deliver;
}

test "a bridge answers the body it was given" {
    var bridge = Bridge{};
    bridge.setBody("lepton-core", "text/plain");

    // The counters are the observable part that does not need the engine.
    try std.testing.expectEqual(@as(usize, 11), bridge.body_len);
    try std.testing.expectEqualStrings("lepton-core", bridge.body[0..bridge.body_len]);
    try std.testing.expectEqualStrings("text/plain", bridge.content_type[0..bridge.content_type_len]);
}

test "a body larger than the buffer is truncated rather than overrunning it" {
    var bridge = Bridge{};
    const too_long: [9000]u8 = @splat('x');
    bridge.setBody(&too_long, "text/plain");

    // Truncated to the buffer, and the part that fit is exactly the front of the input —
    // a copy that shortened without preserving its beginning would answer the page with a
    // document that starts in the middle of nothing.
    try std.testing.expectEqual(bridge.body.len, bridge.body_len);
    try std.testing.expectEqualStrings(&@as([64]u8, @splat('x')), bridge.body[0..64]);
    try std.testing.expectEqualStrings(&@as([64]u8, @splat('x')), bridge.body[bridge.body.len - 64 ..]);
}

test "a bridge starts with nothing to say" {
    const bridge = Bridge{};
    try std.testing.expectEqual(@as(usize, 0), bridge.body_len);
    try std.testing.expectEqual(@as(u32, 0), bridge.counters.requests);
    try std.testing.expectEqual(@as(u32, 0), bridge.counters.refused);
}

test "an empty body is refused rather than answered as an empty document" {
    var bridge = Bridge{};
    bridge.setBody("", "text/plain");
    try std.testing.expectEqual(@as(usize, 0), bridge.body_len);
}
test "the frontend host is told apart from the channel" {
    try std.testing.expectEqualStrings("localhost", hostOf("lepton://localhost/assets/a.js"));
    try std.testing.expectEqualStrings("check", hostOf("lepton://check/storage/kept"));
    try std.testing.expectEqualStrings("localhost", hostOf("lepton://localhost"));
    try std.testing.expectEqualStrings("", hostOf("not a uri"));
}
