//! The typed channel: one shared region, a ring per direction, one frame grammar.
//!
//! `Channel` is the only way into the shared memory. It owns the region, keeps
//! the handshake the two endpoints must agree on before any frame is exchanged,
//! and hands out typed sends and receives.
//!
//! The region holds **two** rings, not one. A single shared queue would be
//! ambiguous the moment both sides speak: the window's own `hello` would sit in
//! the queue the window also reads, and each side would spend its time
//! discarding its own traffic. One ring per direction makes the producer of a
//! frame and its consumer unambiguous, so `receive` returns only what the peer
//! sent. The cost is one extra ring header in a region that is mapped once.
//!
//! Which ring a `Channel` writes to and reads from follows from its role:
//!
//! * `Channel.create` is the window side. It owns the region and writes
//!   `to_webview`, reading `to_window`.
//! * `Channel.attach` is the webview side, and does the opposite.
//!
//! Lifecycle, in order:
//!
//! 1. The window side calls `create`, which makes the region and initialises
//!    both rings.
//! 2. The webview side calls `attach` and sends `hello`.
//! 3. The window side receives it and sends `hello` back. Only then does the
//!    channel report `isEstablished`, because a frame sent before the webview
//!    can decode it is a frame nobody reads.

const std = @import("std");
const ownership = @import("ownership.zig");
const shm = @import("shm.zig");
const ring = @import("ring.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

/// `ownership.Held` is part of this set and means a live process already owns this
/// channel name. It is deliberately not renamed on the way out: it is the one error in
/// the set that is an answer rather than a fault, and a second name for it would give a
/// caller two words for the same fact.
/// `ownership.Held` is part of this set and means a live process already owns this
/// channel name. It is deliberately not renamed on the way out: it is the one error in
/// the set that is an answer rather than a fault, and a second name for it would give a
/// caller two words for the same fact.
pub const Error = shm.Error || ring.Error || wire.DecodeError || ownership.Error || error{
    /// The payload would not fit the cell. The caller decides whether to trim
    /// the payload or drop the frame; the channel never silently truncates.
    PayloadTooLarge,
    /// A frame arrived whose kind this build cannot decode. Reported rather than
    /// guessed at, because acting on a frame whose meaning is unknown is how a
    /// protocol turns into a memory bug.
    UnknownFrameKind,
    /// The ring was not in the state the caller required.
    HandshakeIncomplete,
    /// The ring's cell geometry disagrees with the wire header size, so a frame
    /// could not be composed. This is a build-time invariant that failed at
    /// runtime, and it is reported rather than worked around.
    CellGeometryMismatch,
};

/// Ring geometry. The defaults are sized for a control channel: frames are
/// small and frequent, and a large ring would only delay the evidence that a
/// consumer has stopped draining.
pub const Geometry = struct {
    /// Cells per direction. Must be a power of two of at least two.
    cell_count: u32 = 64,
    payload_capacity: u32 = 4096,
};

/// Which side of the conversation a channel is.
pub const Role = enum {
    /// The process that owns the window. Creates the region.
    window,
    /// The process hosting the web content. Attaches to the region.
    webview,

    /// The ring this side writes into.
    fn outgoing(self: Role) Direction {
        return switch (self) {
            .window => .to_webview,
            .webview => .to_window,
        };
    }

    /// The ring this side reads from.
    fn incoming(self: Role) Direction {
        return switch (self) {
            .window => .to_window,
            .webview => .to_webview,
        };
    }
};

/// The two rings a region contains.
pub const Direction = enum {
    to_window,
    to_webview,
};

/// Bytes a frame of `T` occupies, header included.
pub fn frameSize(comptime T: type) usize {
    return wire.header_bytes + @sizeOf(T);
}

/// Total mapping size for a region holding both directions.
pub fn regionSize(geometry: Geometry) usize {
    const one = ring.regionSize(geometry.cell_count, geometry.payload_capacity);
    return one * 2;
}

/// Creates the region, as the window side. Only one side may do this.
pub fn create(allocator: Allocator, name: []const u8, geometry: Geometry) Error!Channel {
    return Channel.create(allocator, name, geometry);
}

/// Attaches to a region the window side created, as the webview.
pub fn attach(allocator: Allocator, name: []const u8) Error!Channel {
    return Channel.attach(allocator, name);
}

pub const Channel = struct {
    region: shm.Region,
    /// The ownership record, held for exactly as long as the ring and released with it.
    ///
    /// Null on the webview side, which attaches and never claims: a second record would
    /// be a lie about who owns what.
    claim: ?ownership.Claim = null,
    role: Role,
    /// The ring this side writes into.
    out: ring.Ring,
    /// The ring this side reads from.
    in: ring.Ring,
    /// Next sequence number to stamp on an outgoing frame. Atomic because the
    /// ring underneath is multi-producer: two producers on different threads must
    /// not stamp the same sequence, or a reply could match the wrong request.
    next_sequence: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Set once this side has sent its hello.
    hello_sent: bool = false,
    /// Set once both endpoints have said hello.
    established: bool = false,
    /// The peer's hello, once received.
    peer: ?wire.Hello = null,
    /// Frames received, for the operator panel's throughput figure.
    consumed_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Frames composed into the mapping by this side.
    produced_frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Creates the region and both rings, as the window side.
    ///
    /// Ownership is claimed before the ring exists, and that order is what makes taking
    /// over safe. Two processes may both conclude the previous owner is dead; only one
    /// wins the exclusive create on the ownership record, and the loser is told the name
    /// is held instead of deleting a ring the winner is about to use. Once the claim is
    /// held, any ring under this name provably belongs to a dead process — there is no
    /// live one, by definition of the claim — so clearing it is not the dangerous act it
    /// would otherwise be.
    pub fn create(allocator: Allocator, name: []const u8, geometry: Geometry) Error!Channel {
        var claim = try ownership.acquire(allocator, name);
        errdefer claim.deinit(allocator);

        // The previous owner's ring, if any. Gone now; `NotFound` is the ordinary
        // first-launch case rather than something to report.
        shm.unlink(allocator, name) catch |e| switch (e) {
            error.NotFound => {},
            else => return e,
        };

        const region_bytes = regionSize(geometry);
        var region = try shm.create(allocator, name, region_bytes);
        errdefer region.deinit(allocator);

        // Laid down back to back, each ring aligned to its own header, so the two
        // never share a cache line holding their cursors.
        const to_webview = ring.init(region.bytes, geometry.cell_count, geometry.payload_capacity) catch |e| return e;
        const second_at = ring.regionSize(geometry.cell_count, geometry.payload_capacity);
        const to_window = ring.init(region.bytes[second_at..], geometry.cell_count, geometry.payload_capacity) catch |e| return e;

        return .{
            .region = region,
            .claim = claim,
            .role = .window,
            .out = to_webview,
            .in = to_window,
        };
    }

    /// Attaches to a region the window side created, as the webview.
    pub fn attach(allocator: Allocator, name: []const u8) Error!Channel {
        var region = try shm.attach(allocator, name);
        errdefer region.deinit(allocator);

        const to_webview = try ring.attach(region.bytes);
        const second_at = ring.regionSize(to_webview.capacity(), to_webview.payload_capacity);
        if (region.bytes.len < second_at * 2) return error.RegionTooSmall;
        const to_window = try ring.attach(region.bytes[second_at..]);

        return .{
            .region = region,
            .role = .webview,
            .out = to_window,
            .in = to_webview,
        };
    }

    /// Unmaps, closes, and removes the region when this side created it.
    pub fn deinit(self: *Channel, allocator: Allocator) void {
        self.region.deinit(allocator);
        if (self.claim) |*held| held.deinit(allocator);
        self.claim = null;
        self.out = undefined;
        self.in = undefined;
    }

    /// The shared mapping, for a caller that needs to hand the ring's memory to
    /// another process or to check its residency.
    pub fn mapping(self: *const Channel) []u8 {
        return self.region.bytes;
    }

    /// The bytes of the ring this side writes into: header and every cell, nothing of
    /// the other direction. What a snapshot reader is given, so it cannot read — or be
    /// confused by — the frames travelling the other way.
    pub fn outboundRegion(self: *const Channel) []const u8 {
        const half = self.region.bytes.len / 2;
        return switch (self.role) {
            .window => self.region.bytes[0..half],
            .webview => self.region.bytes[half..],
        };
    }

    /// Which side this channel is.
    pub fn side(self: *const Channel) Role {
        return self.role;
    }

    /// True once this side has both sent and received a hello.
    pub fn isEstablished(self: *const Channel) bool {
        return self.established;
    }

    /// Occupancy of the ring this side reads from. Sampled, never a correctness
    /// input.
    pub fn occupancy(self: *Channel) u32 {
        return self.in.occupancy();
    }

    /// Cells in the ring this side reads from.
    pub fn capacity(self: *Channel) u32 {
        return self.in.capacity();
    }

    /// Free cells in the ring this side writes into.
    pub fn freeCells(self: *Channel) u32 {
        return self.out.capacity() - self.out.occupancy();
    }

    /// Builds the hello this build announces, describing the render path the
    /// window side will actually use.
    pub fn localHello(mode: wire.Mode, capabilities: u64) wire.Hello {
        return .{ .build = build_id, .mode = @intFromEnum(mode), .capabilities = capabilities };
    }

    /// Sends `hello` and marks this side half-established.
    pub fn sendHello(self: *Channel, mode: wire.Mode, capabilities: u64) Error!void {
        const payload = localHello(mode, capabilities);
        _ = try self.send(.hello, &payload, .{});
        self.hello_sent = true;
        self.updateEstablished();
    }

    /// A channel is established once this side has both spoken and heard the
    /// peer. Recomputed on each of the two events rather than set by whichever
    /// happened to come second, because either side may send first and neither
    /// should have to know in advance which will.
    fn updateEstablished(self: *Channel) void {
        self.established = self.hello_sent and self.peer != null;
    }

    /// Frames received since this channel was created.
    pub fn received(self: *Channel) u64 {
        return self.consumed_frames.load(.monotonic);
    }

    /// Frames sent since this channel was created.
    pub fn sent(self: *Channel) u64 {
        return self.produced_frames.load(.monotonic);
    }

    /// Receives the next frame from the peer, if any, and returns it zero-copy.
    ///
    /// The returned `Frame` still owns its ring cell: its payload points into the
    /// shared mapping, and the cell is not reusable until `release`. Use
    /// `receiveScoped` for the common case, where the borrow ends at a scope.
    pub fn receive(self: *Channel) Error!?Frame {
        var slot = self.in.claimOldest() catch |e| switch (e) {
            error.Empty => return null,
            else => |other| return other,
        };
        // Every failure path from here has to return the cell: the consumer cursor
        // has already moved past it, so an unreleased cell would wedge the ring.
        errdefer self.in.release(&slot);

        const h = try wire.readHeader(slot.bytes());
        // A kind this build cannot decode is refused rather than acted on, so an
        // older core never mistakes a newer frame's bytes for something it
        // knows. The frame's `payload_len` still lets the ring advance past it.
        if (h.kind.isSkippable()) return error.UnknownFrameKind;

        _ = self.consumed_frames.fetchAdd(1, .monotonic);
        return .{
            .channel = self,
            .slot = slot,
            .header = h,
            .payload = try wire.payloadOf(slot.bytes(), h),
        };
    }

    /// Runs `body` on the next frame, if any, and releases the cell afterwards.
    ///
    /// This is the shape almost every caller wants: read what is needed inside a
    /// scope, then let the ring have the cell back. `body` returning `false` means
    /// "not for me", which is how a caller filters without holding cells.
    pub fn receiveScoped(
        self: *Channel,
        comptime body: fn (*Channel, Frame) anyerror!bool,
    ) Error!bool {
        var frame = (try self.receive()) orelse return false;
        defer frame.release();
        return try body(self, frame);
    }

    /// Reads the peer's hello and marks the channel established.
    ///
    /// Separate from `receive` because the handshake is the one place where a
    /// frame's meaning is checked before it is acted on.
    pub fn receiveHello(self: *Channel) Error!bool {
        var frame = (try self.receive()) orelse return false;
        defer frame.release();
        if (frame.header.kind != .hello) return error.HandshakeIncomplete;
        self.peer = try wire.readPayload(wire.Hello, frame.payload);
        self.updateEstablished();
        return true;
    }

    /// Sends a fixed-layout payload. One copy into the cell, no allocation.
    ///
    /// `kind` is comptime, so a payload's type is checked against its kind at the
    /// call site rather than asserted somewhere else.
    pub fn send(
        self: *Channel,
        comptime kind: wire.Kind,
        payload: *const wire.PayloadFor(kind),
        opts: SendOptions,
    ) Error!u64 {
        return self.sendBytes(kind, std.mem.asBytes(payload), opts);
    }

    pub const SendOptions = struct {
        reply: bool = false,
        fragment: bool = false,
        /// Explicit sequence, for a reply that must echo a request. Zero means
        /// "stamp this channel's own counter".
        sequence: u64 = 0,
    };

    /// Sends a byte payload, header included, in one pass through the cell.
    ///
    /// The frame is composed straight into the cell's mapping: header then
    /// payload, no staging buffer, no allocation on the event loop.
    pub fn sendBytes(
        self: *Channel,
        kind: wire.Kind,
        payload: []const u8,
        opts: SendOptions,
    ) Error!u64 {
        const sequence = if (opts.sequence != 0) opts.sequence else self.nextSequence();
        const h = wire.header(kind, @intCast(payload.len), sequence, .{
            .reply = opts.reply,
            .fragment = opts.fragment,
        });
        if (wire.header_bytes + payload.len > self.out.payload_capacity) return error.PayloadTooLarge;

        var slot = try self.out.claim();
        errdefer self.out.abandon(slot);

        var w = slot.writer();
        // `extern struct` is exactly its own bytes, so this lays the header down
        // in place rather than re-encoding it.
        w.writeAll(std.mem.asBytes(&h)) catch return error.CellGeometryMismatch;
        if (payload.len != 0) w.writeAll(payload) catch return error.CellGeometryMismatch;

        self.out.publish(slot, wire.header_bytes + payload.len);
        _ = self.produced_frames.fetchAdd(1, .monotonic);
        return sequence;
    }

    /// Publishes a frame for a reader that wants the *latest* value, not every value.
    ///
    /// A snapshot reader — the webview transport copies the mapping and reads the newest
    /// published cell — never consumes, so a queueing send would report `Full` after
    /// `cell_count` frames and the page would read a frozen past forever. Here a full
    /// ring gives up its oldest frame, and the send is retried once: the ring stays a
    /// window over the newest `cell_count` frames, in order. A second `Full` means
    /// another consumer holds every cell, and that is reported rather than looped on.
    pub fn publishLatest(
        self: *Channel,
        comptime kind: wire.Kind,
        payload: *const wire.PayloadFor(kind),
    ) Error!u64 {
        return self.send(kind, payload, .{}) catch |failure| switch (failure) {
            error.Full => {
                var oldest = try self.out.claimOldest();
                self.out.release(&oldest);
                return self.send(kind, payload, .{});
            },
            else => failure,
        };
    }

    /// Claims the next sequence number. Relaxed is sufficient: the value only has
    /// to be unique and increasing, and no other memory is published through it.
    fn nextSequence(self: *Channel) u64 {
        // Wrapping is fine: sequence orders frames within a session, and a reader
        // sees the wrap as a lower number rather than as corruption.
        return self.next_sequence.fetchAdd(1, .monotonic);
    }
};

/// A received frame that still owns its ring cell.
///
/// The payload points into the shared mapping, which is what makes the read
/// zero-copy: there is no copy out of shared memory anywhere on this path. The
/// price is that the cell stays claimed until `release`, because a producer is
/// entitled to overwrite the bytes the moment they are handed back.
pub const Frame = struct {
    channel: *Channel,
    slot: ring.Ring.Consumer,
    header: wire.Header,
    payload: []const u8,

    /// Typed read of the payload. Zero-copy: the value is read out of the mapped
    /// bytes, not parsed into an owned object.
    pub fn as(self: Frame, comptime T: type) Error!T {
        return wire.readPayload(T, self.payload);
    }

    /// Hands the cell back to the ring. Idempotent, so a `defer` here is safe
    /// even when an inner path already released it.
    pub fn release(self: *Frame) void {
        self.channel.in.release(&self.slot);
    }
};

/// Identifies this build to the peer.
///
/// Derived from the wire version so a protocol mismatch surfaces at the
/// handshake, where the message can name itself, rather than later as a frame
/// whose fields quietly mean something else.
pub const build_id: u64 = @as(u64, wire.version);
