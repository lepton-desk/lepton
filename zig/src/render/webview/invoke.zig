//! `invoke`: a request from the page and the core's reply, as `wire` frames.
//!
//! The page POSTs one frame to `/__lepton/invoke` — a `wire.Header` of kind `request`, a
//! `wire.Request` naming the command, and the argument bytes — and the response body is
//! one frame back: a `wire.Header` of kind `reply` with the request's sequence, a
//! `wire.Reply` with the status, and the result bytes. No JSON on either side: the page
//! builds and reads these with a `DataView` at offsets taken from the structs here
//! (`transport.zig` hands them over), and the core decodes them in place.
//!
//! This file is the pure half — frames in, frames out, effects recorded — so every rule
//! is tested without a window; `bridge.zig` does the I/O.

const std = @import("std");
const wire = @import("../../ipc/wire.zig");
const registry_mod = @import("registry.zig");
pub const Registry = registry_mod.Registry;

// The page's address for this is `transport.zig`'s, under the run's key (`secret.zig`).

/// The largest request frame the core reads. A request is a command and its argument,
/// not a file transfer; larger data goes through the shared ring.
pub const max_request: usize = 64 * 1024;
/// The largest reply frame the core writes.
pub const max_reply: usize = 64 * 1024;

/// Built-in commands. The page addresses them by name; the names and ids reach it from
/// this enum at compile time, so a renamed command cannot leave a stale id in the SDK.
pub const Command = enum(u32) {
    /// Returns its argument unchanged — the round trip with nothing else in it.
    ping = 1,
    /// Returns the wire protocol version as a little-endian `u32`.
    protocol = 2,
    /// Asks the application to close, as the titlebar's close button does.
    window_close = 3,
    /// Minimizes the window. There is no un-minimize: on Wayland only the user restores.
    window_minimize = 4,
    window_maximize = 5,
    window_unmaximize = 6,
    /// Returns the window's state bits (`WindowState`) as a little-endian `u32`.
    window_state = 7,
    /// The page's answer to a `permission.request` event: `u32` id (LE), then one byte,
    /// 1 to allow. `failed` when that id is not waiting (`permissions.zig`).
    permission_respond = 8,
    _,

    /// The name the page uses: `<group>.<name>`.
    pub fn publicName(comptime command: Command) []const u8 {
        return switch (command) {
            .ping => "core.ping",
            .protocol => "core.protocol",
            .window_close => "window.close",
            .window_minimize => "window.minimize",
            .window_maximize => "window.maximize",
            .window_unmaximize => "window.unmaximize",
            .window_state => "window.state",
            .permission_respond => "permission.respond",
            _ => @compileError("a command without a public name cannot reach the page"),
        };
    }
};

/// The named commands, for code generated from them.
pub const commands = [_]Command{ .ping, .protocol, .window_close, .window_minimize, .window_maximize, .window_unmaximize, .window_state, .permission_respond };

/// What the window commands ask the platform to do.
pub const WindowAction = enum { minimize, maximize, unmaximize };

/// The state bits `window.state` answers and the `window.state` event carries — WPE's
/// `WPEToplevelState` (`WPEToplevel.h`, 2.54), passed through unchanged.
pub const WindowState = struct {
    pub const fullscreen: u32 = 1 << 0;
    pub const maximized: u32 = 1 << 1;
    pub const active: u32 = 1 << 2;
};

/// The window the commands act on, supplied by whoever owns it. Empty in a process with
/// no window: the commands then answer `failed`.
pub const Window = struct {
    context: ?*anyopaque = null,
    /// Returns whether the platform accepted the action.
    act: ?*const fn (context: ?*anyopaque, action: WindowAction) bool = null,
    state: ?*const fn (context: ?*anyopaque) ?u32 = null,
    /// Settles a permission request the page was asked about.
    permission: ?*const fn (id: u32, allow: bool) bool = null,

    fn perform(self: Window, action: WindowAction) bool {
        const act = self.act orelse return false;
        return act(self.context, action);
    }
};

/// `wire.Reply.status`. Zero is success, as `wire.Reply` documents.
pub const Status = enum(u32) {
    ok = 0,
    /// The frame was not a well-formed `request`.
    malformed = 1,
    /// No such command in this core.
    unknown_command = 2,
    /// The result does not fit a reply.
    too_large = 3,
    /// The command exists but `permissions` does not list it.
    denied = 4,
    /// An application command ran and refused.
    failed = 5,
    _,
};

/// What a request asked the application to do beyond its reply.
pub const Effects = struct {
    close_requested: bool = false,
    /// Set by the bridge when it can hold this request open: a command that answers
    /// later takes it (`takeLater`) instead of replying now.
    later: ?Later = null,
    /// The command took `later`: no reply now; the bridge keeps the request until
    /// `Later.finish`.
    deferred: bool = false,
};

/// A reply owed to a held request — what a command that answers later (a file dialog,
/// which waits for the user) keeps until it has the answer. Exactly one `finish` per
/// `Later`; a second, or one after the page went away, is ignored by the bridge.
pub const Later = struct {
    context: ?*anyopaque,
    finish_fn: *const fn (context: ?*anyopaque, slot: u16, generation: u32, sequence: u64, status: Status, result: []const u8) void,
    slot: u16,
    generation: u32,
    sequence: u64 = 0,

    /// Answers the held request: `ok` with `result`, or a failure status with nothing.
    pub fn finish(later: Later, status: Status, result: []const u8) void {
        later.finish_fn(later.context, later.slot, later.generation, later.sequence, status, result);
    }
};

/// The request being handled, while an application or plugin command runs. One at a
/// time: requests are handled on the engine's main loop, never concurrently.
var running: ?*Effects = null;

/// For a command that will answer later: takes the request's `Later` and tells the
/// bridge to hold the request. Null when the bridge has no room to hold another (eight
/// at once) or outside a command — the command should then answer `failed`. Whatever the
/// command returns after taking it is ignored.
pub fn takeLater() ?Later {
    const effects = running orelse return null;
    const later = effects.later orelse return null;
    effects.deferred = true;
    effects.later = null;
    return later;
}

/// Handles one request frame and writes the reply frame into `out`.
///
/// Always produces a reply when `out` can hold an empty one: a malformed request gets
/// `malformed` rather than a dropped connection, so the page's promise always settles.
pub fn handle(frame: []const u8, registry: *const Registry, window: Window, effects: *Effects, out: []u8) error{NoSpaceLeft}![]const u8 {
    const request_header = wire.readHeader(frame) catch return reply(out, 0, .malformed, &.{});
    if (request_header.kind != .request) return reply(out, request_header.sequence, .malformed, &.{});
    const payload = wire.payloadOf(frame, request_header) catch return reply(out, request_header.sequence, .malformed, &.{});
    const asked = wire.readPayload(wire.Request, payload) catch return reply(out, request_header.sequence, .malformed, &.{});

    const start: usize = asked.argument_off;
    const end = std.math.add(usize, start, asked.argument_len) catch return reply(out, request_header.sequence, .malformed, &.{});
    if (start < @sizeOf(wire.Request) or end > payload.len) return reply(out, request_header.sequence, .malformed, &.{});
    const argument = payload[start..end];

    const sequence = request_header.sequence;
    // Unknown before denied: a page asking for a command this core lacks learns that,
    // and one asking for a real command it was not granted learns it was refused.
    const name = registry.nameOf(asked.command) orelse return reply(out, sequence, .unknown_command, &.{});
    if (!registry.allows(name)) return reply(out, sequence, .denied, &.{});

    if (registry.appCommand(asked.command)) |command| {
        const result_at = wire.header_bytes + @sizeOf(wire.Reply);
        if (out.len < result_at) return error.NoSpaceLeft;
        if (effects.later) |*later| later.sequence = sequence;
        running = effects;
        defer running = null;
        const result = command.run(registry.context, argument, out[result_at..]);
        if (effects.deferred) return out[0..0];
        const written = result catch |err| return switch (err) {
            error.Failed => reply(out, sequence, .failed, &.{}),
            error.TooLarge => reply(out, sequence, .too_large, &.{}),
            error.Denied => reply(out, sequence, .denied, &.{}),
        };
        if (written > out.len - result_at) return reply(out, sequence, .too_large, &.{});
        return replyInPlace(out, sequence, .ok, written);
    }

    return switch (@as(Command, @enumFromInt(asked.command))) {
        .ping => reply(out, sequence, .ok, argument) catch reply(out, sequence, .too_large, &.{}),
        .protocol => blk: {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, wire.version, .little);
            break :blk reply(out, sequence, .ok, &bytes);
        },
        .window_close => blk: {
            effects.close_requested = true;
            break :blk reply(out, sequence, .ok, &.{});
        },
        .window_minimize => windowReply(out, sequence, window.perform(.minimize)),
        .window_maximize => windowReply(out, sequence, window.perform(.maximize)),
        .window_unmaximize => windowReply(out, sequence, window.perform(.unmaximize)),
        .window_state => blk: {
            const query = window.state orelse break :blk reply(out, sequence, .failed, &.{});
            const bits = query(window.context) orelse break :blk reply(out, sequence, .failed, &.{});
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, bits, .little);
            break :blk reply(out, sequence, .ok, &bytes);
        },
        .permission_respond => blk: {
            if (argument.len != 5) break :blk reply(out, sequence, .malformed, &.{});
            const settle = window.permission orelse break :blk reply(out, sequence, .failed, &.{});
            const id = std.mem.readInt(u32, argument[0..4], .little);
            break :blk reply(out, sequence, if (settle(id, argument[4] == 1)) .ok else .failed, &.{});
        },
        _ => reply(out, sequence, .unknown_command, &.{}),
    };
}

fn windowReply(out: []u8, sequence: u64, accepted: bool) error{NoSpaceLeft}![]const u8 {
    return reply(out, sequence, if (accepted) .ok else .failed, &.{});
}

/// Writes the headers of a reply whose `result_len` result bytes are already in place
/// after them — an application command writes straight into the reply.
fn replyInPlace(out: []u8, sequence: u64, status: Status, result_len: usize) error{NoSpaceLeft}![]const u8 {
    const payload_len = @sizeOf(wire.Reply) + result_len;
    const total = wire.header_bytes + payload_len;
    if (total > out.len or payload_len > std.math.maxInt(u32)) return error.NoSpaceLeft;
    const head = wire.header(.reply, @intCast(payload_len), sequence, .{ .reply = true });
    @memcpy(out[0..wire.header_bytes], std.mem.asBytes(&head));
    const body: wire.Reply = .{
        .request_sequence = sequence,
        .status = @intFromEnum(status),
        .reserved = 0,
        .result_len = @intCast(result_len),
        .result_off = @sizeOf(wire.Reply),
        ._pad = 0,
    };
    @memcpy(out[wire.header_bytes..][0..@sizeOf(wire.Reply)], std.mem.asBytes(&body));
    return out[0..total];
}

/// Writes a reply frame: header, `wire.Reply`, result.
pub fn reply(out: []u8, sequence: u64, status: Status, result: []const u8) error{NoSpaceLeft}![]const u8 {
    const payload_len = @sizeOf(wire.Reply) + result.len;
    const total = wire.header_bytes + payload_len;
    if (total > out.len or payload_len > std.math.maxInt(u32)) return error.NoSpaceLeft;

    const head = wire.header(.reply, @intCast(payload_len), sequence, .{ .reply = true });
    @memcpy(out[0..wire.header_bytes], std.mem.asBytes(&head));
    const body: wire.Reply = .{
        .request_sequence = sequence,
        .status = @intFromEnum(status),
        .reserved = 0,
        .result_len = @intCast(result.len),
        .result_off = @sizeOf(wire.Reply),
        ._pad = 0,
    };
    @memcpy(out[wire.header_bytes..][0..@sizeOf(wire.Reply)], std.mem.asBytes(&body));
    @memcpy(out[wire.header_bytes + @sizeOf(wire.Reply) ..][0..result.len], result);
    return out[0..total];
}

/// Builds a request frame — what the page does, here so the tests speak the same bytes.
pub fn request(out: []u8, sequence: u64, command: u32, argument: []const u8) error{NoSpaceLeft}![]const u8 {
    const payload_len = @sizeOf(wire.Request) + argument.len;
    const total = wire.header_bytes + payload_len;
    if (total > out.len) return error.NoSpaceLeft;
    const head = wire.header(.request, @intCast(payload_len), sequence, .{});
    @memcpy(out[0..wire.header_bytes], std.mem.asBytes(&head));
    const body: wire.Request = .{
        .command = command,
        .argument_len = @intCast(argument.len),
        .argument_off = @sizeOf(wire.Request),
        .reserved = 0,
    };
    @memcpy(out[wire.header_bytes..][0..@sizeOf(wire.Request)], std.mem.asBytes(&body));
    @memcpy(out[wire.header_bytes + @sizeOf(wire.Request) ..][0..argument.len], argument);
    return out[0..total];
}

/// Every built-in granted: what the handler tests below exercise.
const NoState = struct {};
const everything = registry_mod.checked(NoState, &.{}, registry_mod.permissionList("core.ping,core.protocol,window.close,window.minimize,window.maximize,window.unmaximize,window.state")).unbound;

fn decodeReply(frame: []const u8) !struct { header: wire.Header, reply: wire.Reply, result: []const u8 } {
    const h = try wire.readHeader(frame);
    const payload = try wire.payloadOf(frame, h);
    const r = try wire.readPayload(wire.Reply, payload);
    return .{ .header = h, .reply = r, .result = payload[r.result_off..][0..r.result_len] };
}

test "ping returns its argument under the request's sequence" {
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};
    const frame = try request(&in, 41, @intFromEnum(Command.ping), "lepton");
    const answer = try decodeReply(try handle(frame, &everything, .{}, &effects, &out));
    try std.testing.expectEqual(wire.Kind.reply, answer.header.kind);
    try std.testing.expect(wire.flagOf(answer.header, .reply));
    try std.testing.expectEqual(@as(u64, 41), answer.header.sequence);
    try std.testing.expectEqual(@as(u64, 41), answer.reply.request_sequence);
    try std.testing.expectEqual(@as(u32, 0), answer.reply.status);
    try std.testing.expectEqualStrings("lepton", answer.result);
    try std.testing.expect(!effects.close_requested);
}

test "protocol answers the wire version and window.close records the effect" {
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};
    const version = try decodeReply(try handle(try request(&in, 1, @intFromEnum(Command.protocol), ""), &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@as(u32, wire.version), std.mem.readInt(u32, version.result[0..4], .little));

    const closed = try decodeReply(try handle(try request(&in, 2, @intFromEnum(Command.window_close), ""), &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@as(u32, 0), closed.reply.status);
    try std.testing.expect(effects.close_requested);
}

test "an unknown command and a malformed frame still get a reply" {
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};
    const unknown = try decodeReply(try handle(try request(&in, 7, 999, ""), &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.unknown_command), unknown.reply.status);
    try std.testing.expectEqual(@as(u64, 7), unknown.reply.request_sequence);

    const short = try decodeReply(try handle("not a frame", &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.malformed), short.reply.status);

    // An argument that claims to run past the payload.
    const frame = try request(&in, 8, @intFromEnum(Command.ping), "abc");
    var forged: [256]u8 = undefined;
    @memcpy(forged[0..frame.len], frame);
    std.mem.writeInt(u32, forged[wire.header_bytes + @offsetOf(wire.Request, "argument_len") ..][0..4], 1000, .little);
    const lying = try decodeReply(try handle(forged[0..frame.len], &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.malformed), lying.reply.status);

    // A reply frame sent as a request.
    const backwards = try reply(&forged, 9, .ok, "");
    const refused = try decodeReply(try handle(backwards, &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.malformed), refused.reply.status);
}

test "an echo that cannot fit the reply is too_large, not truncated" {
    var in: [512]u8 = undefined;
    var out: [128]u8 = undefined;
    var effects: Effects = .{};
    const big: [200]u8 = @splat('x');
    const frame = try request(&in, 3, @intFromEnum(Command.ping), &big);
    const answer = try decodeReply(try handle(frame, &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.too_large), answer.reply.status);
    try std.testing.expectEqual(@as(u32, 0), answer.reply.result_len);
}

fn shout(_: *NoState, argument: []const u8, out: []u8) registry_mod.HandlerError!usize {
    if (argument.len > out.len) return error.TooLarge;
    for (argument, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return argument.len;
}

fn broken(_: *NoState, _: []const u8, _: []u8) registry_mod.HandlerError!usize {
    return error.Failed;
}

fn outOfScope(_: *NoState, _: []const u8, _: []u8) registry_mod.HandlerError!usize {
    return error.Denied;
}

test "a granted command refusing this use of it answers denied" {
    const app = [_]registry_mod.Command(NoState){.{ .name = "files.read", .run = &outOfScope }};
    var state: NoState = .{};
    const granted = (comptime registry_mod.checked(NoState, &app, registry_mod.permissionList("files.read"))).bind(&state);
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};
    const refused = try decodeReply(try handle(try request(&in, 1, registry_mod.first_app_id, "/etc/shadow"), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.denied), refused.reply.status);
    try std.testing.expectEqual(@as(u32, 0), refused.reply.result_len);
}

test "an application command answers in place; ungranted and failing ones are named" {
    const app = [_]registry_mod.Command(NoState){
        .{ .name = "text.shout", .run = &shout },
        .{ .name = "text.broken", .run = &broken },
        .{ .name = "text.secret", .run = &shout },
    };
    var state: NoState = .{};
    const granted = (comptime registry_mod.checked(NoState, &app, registry_mod.permissionList("text.shout,text.broken"))).bind(&state);
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};

    const shouted = try decodeReply(try handle(try request(&in, 1, registry_mod.first_app_id, "lepton"), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@as(u32, 0), shouted.reply.status);
    try std.testing.expectEqualStrings("LEPTON", shouted.result);

    const failed = try decodeReply(try handle(try request(&in, 2, registry_mod.first_app_id + 1, ""), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.failed), failed.reply.status);

    const secret = try decodeReply(try handle(try request(&in, 3, registry_mod.first_app_id + 2, "x"), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.denied), secret.reply.status);

    // A built-in that is not listed is denied too; one that does not exist is unknown.
    const close = try decodeReply(try handle(try request(&in, 4, @intFromEnum(Command.window_close), ""), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.denied), close.reply.status);
    try std.testing.expect(!effects.close_requested);
    const missing = try decodeReply(try handle(try request(&in, 5, registry_mod.first_app_id + 9, ""), &granted, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.unknown_command), missing.reply.status);

    // A result larger than the reply's room is too_large.
    var small: [wire.header_bytes + @sizeOf(wire.Reply) + 3]u8 = undefined;
    const big = try decodeReply(try handle(try request(&in, 6, registry_mod.first_app_id, "lepton"), &granted, .{}, &effects, &small));
    try std.testing.expectEqual(@intFromEnum(Status.too_large), big.reply.status);
}

const FakeWindow = struct {
    last: ?WindowAction = null,
    bits: u32 = WindowState.active,

    fn act(context: ?*anyopaque, action: WindowAction) bool {
        const self: *FakeWindow = @ptrCast(@alignCast(context.?));
        self.last = action;
        if (action == .maximize) self.bits |= WindowState.maximized;
        if (action == .unmaximize) self.bits &= ~WindowState.maximized;
        return true;
    }

    fn state(context: ?*anyopaque) ?u32 {
        const self: *FakeWindow = @ptrCast(@alignCast(context.?));
        return self.bits;
    }
};

test "window commands reach the window, and answer failed without one" {
    var recorder: FakeWindow = .{};
    const window: Window = .{ .context = &recorder, .act = &FakeWindow.act, .state = &FakeWindow.state };
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var effects: Effects = .{};

    const maximized = try decodeReply(try handle(try request(&in, 1, @intFromEnum(Command.window_maximize), ""), &everything, window, &effects, &out));
    try std.testing.expectEqual(@as(u32, 0), maximized.reply.status);
    try std.testing.expectEqual(WindowAction.maximize, recorder.last.?);
    const state = try decodeReply(try handle(try request(&in, 2, @intFromEnum(Command.window_state), ""), &everything, window, &effects, &out));
    try std.testing.expectEqual(WindowState.active | WindowState.maximized, std.mem.readInt(u32, state.result[0..4], .little));

    const headless = try decodeReply(try handle(try request(&in, 3, @intFromEnum(Command.window_minimize), ""), &everything, .{}, &effects, &out));
    try std.testing.expectEqual(@intFromEnum(Status.failed), headless.reply.status);
}

var kept: ?Later = null;

fn answersLater(_: *NoState, _: []const u8, _: []u8) registry_mod.HandlerError!usize {
    kept = takeLater() orelse return error.Failed;
    return 0;
}

const Finished = struct {
    var count: u32 = 0;
    var sequence: u64 = 0;
    var slot: u16 = 0;
    var status: Status = .ok;
    var result: [16]u8 = undefined;
    var result_len: usize = 0;

    fn finish(_: ?*anyopaque, held: u16, _: u32, owed: u64, answered: Status, bytes: []const u8) void {
        count += 1;
        sequence = owed;
        slot = held;
        status = answered;
        @memcpy(result[0..bytes.len], bytes);
        result_len = bytes.len;
    }
};

test "a command can answer later: no reply now, the request's own sequence when it does" {
    const app = [_]registry_mod.Command(NoState){.{ .name = "dialog.wait", .run = &answersLater }};
    var state: NoState = .{};
    const granted = (comptime registry_mod.checked(NoState, &app, registry_mod.permissionList("dialog.wait"))).bind(&state);
    var in: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    var effects: Effects = .{ .later = .{ .context = null, .finish_fn = &Finished.finish, .slot = 3, .generation = 0 } };
    const now = try handle(try request(&in, 42, registry_mod.first_app_id, ""), &granted, .{}, &effects, &out);
    try std.testing.expectEqual(@as(usize, 0), now.len);
    try std.testing.expect(effects.deferred);
    try std.testing.expect(takeLater() == null); // only while the command runs

    kept.?.finish(.ok, "picked");
    try std.testing.expectEqual(@as(u32, 1), Finished.count);
    try std.testing.expectEqual(@as(u64, 42), Finished.sequence);
    try std.testing.expectEqual(@as(u16, 3), Finished.slot);
    try std.testing.expectEqualStrings("picked", Finished.result[0..Finished.result_len]);

    // With no room to hold the request the command cannot take it and answers now.
    var full: Effects = .{};
    const refused = try decodeReply(try handle(try request(&in, 43, registry_mod.first_app_id, ""), &granted, .{}, &full, &out));
    try std.testing.expectEqual(@intFromEnum(Status.failed), refused.reply.status);
    try std.testing.expect(!full.deferred);
}

var settled_for_test: ?struct { id: u32, allow: bool } = null;
fn settleForTest(id: u32, allow: bool) bool {
    settled_for_test = .{ .id = id, .allow = allow };
    return id == 9;
}

test "permission.respond hands the page's answer to the window's owner" {
    const registry: Registry = .{ .allowed = &.{"permission.respond"} };
    const window: Window = .{ .permission = &settleForTest };
    var request_buffer: [64]u8 = undefined;
    var out: [128]u8 = undefined;
    var effects: Effects = .{};
    var argument: [5]u8 = undefined;
    std.mem.writeInt(u32, argument[0..4], 9, .little);
    argument[4] = 1;
    const asked = try request(&request_buffer, 1, @intFromEnum(Command.permission_respond), &argument);
    const ok = try handle(asked, &registry, window, &effects, &out);
    const ok_reply = try wire.readPayload(wire.Reply, ok[wire.header_bytes..]);
    try std.testing.expectEqual(@as(u32, @intFromEnum(Status.ok)), ok_reply.status);
    try std.testing.expectEqual(@as(u32, 9), settled_for_test.?.id);
    try std.testing.expect(settled_for_test.?.allow);

    // An id that is not waiting is `failed`; a short argument is `malformed`.
    std.mem.writeInt(u32, argument[0..4], 4, .little);
    const stale = try handle(try request(&request_buffer, 2, @intFromEnum(Command.permission_respond), &argument), &registry, window, &effects, &out);
    try std.testing.expectEqual(@as(u32, @intFromEnum(Status.failed)), (try wire.readPayload(wire.Reply, stale[wire.header_bytes..])).status);
    const short = try handle(try request(&request_buffer, 3, @intFromEnum(Command.permission_respond), argument[0..4]), &registry, window, &effects, &out);
    try std.testing.expectEqual(@as(u32, @intFromEnum(Status.malformed)), (try wire.readPayload(wire.Reply, short[wire.header_bytes..])).status);
}
