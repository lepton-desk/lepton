//! The core's `invoke` handler, outside a window, for the SDK's tests.
//!
//! `lepton-invoke-check layout` prints the layout object the page receives as
//! `__lepton.layout`. `lepton-invoke-check serve` reads request frames from stdin —
//! each preceded by its length as a little-endian `u32` — and answers each with the
//! reply frame `invoke.handle` writes, framed the same way. The SDK's tests drive this
//! with frames built by `@lepton-desk/api/core`, so both ends of a test are the shipped
//! code: no stand-in for the core.

const std = @import("std");
const core = @import("lepton_core");
const invoke = core.webviewInvoke;
const registry = core.webviewRegistry;

/// Every built-in granted, plus one application command, so the SDK's tests reach the
/// built-ins, an application command, and a denial.
const Calls = struct { count: u32 = 0 };
const app = [_]registry.Command(Calls){
    .{ .name = "test.reverse", .run = &reverse },
    .{ .name = "test.ungranted", .run = &reverse },
    .{ .name = "test.count", .run = &count },
};
const registered = registry.checked(Calls, &app, registry.permissionList("core.ping,core.protocol,window.close,test.reverse,test.count"));
var calls: Calls = .{};

fn reverse(_: *Calls, argument: []const u8, out: []u8) registry.HandlerError!usize {
    if (argument.len > out.len) return error.TooLarge;
    for (argument, 0..) |byte, i| out[argument.len - 1 - i] = byte;
    return argument.len;
}

/// Counts its own calls in the bound state and answers the count as a `u32` LE: the
/// SDK's test sees state survive between requests.
fn count(state: *Calls, _: []const u8, out: []u8) registry.HandlerError!usize {
    if (out.len < 4) return error.TooLarge;
    state.count += 1;
    std.mem.writeInt(u32, out[0..4], state.count, .little);
    return 4;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const granted = registered.bind(&calls);
    var args = init.args.iterate();
    _ = args.next();
    const mode = args.next() orelse return usage();
    if (std.mem.eql(u8, mode, "layout")) {
        try writeAll(core.webviewTransport.layout_object);
        try writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, mode, "app-commands")) {
        var table: [1024]u8 = undefined;
        try writeAll(try registry.writeAppTable(&granted, &table));
        try writeAll("\n");
        return;
    }
    if (std.mem.eql(u8, mode, "types")) {
        try writeAll(core.webviewTransport.command_types);
        return;
    }
    if (std.mem.eql(u8, mode, "app-types")) {
        try writeAll(comptime core.webviewDeclarations.file(registered, core.webviewEvents.Declared(&.{ "test.saved", "test.deleted" })));
        return;
    }
    if (std.mem.eql(u8, mode, "events")) {
        // Two events through the real log, as the bridge would answer `after=0`.
        var log: core.webviewEvents.Log = .{};
        var bits: [4]u8 = undefined;
        std.mem.writeInt(u32, &bits, 6, .little);
        _ = try log.emit("window.state", &bits);
        _ = try log.emit("notes.saved", "draft.md");
        var out: [1024]u8 = undefined;
        try writeAll(try log.writeSince(0, &out));
        return;
    }
    if (!std.mem.eql(u8, mode, "serve")) return usage();

    var request: [invoke.max_request]u8 = undefined;
    var reply: [invoke.max_reply]u8 = undefined;
    while (true) {
        var length_bytes: [4]u8 = undefined;
        if (!try readExactly(&length_bytes)) return;
        const length = std.mem.readInt(u32, &length_bytes, .little);
        if (length > request.len) return error.RequestTooLarge;
        if (!try readExactly(request[0..length])) return error.TruncatedRequest;

        var effects: invoke.Effects = .{};
        const frame = try invoke.handle(request[0..length], &granted, .{}, &effects, &reply);
        var out_length: [4]u8 = undefined;
        std.mem.writeInt(u32, &out_length, @intCast(frame.len), .little);
        try writeAll(&out_length);
        try writeAll(frame);
    }
}

fn usage() error{Usage}!void {
    std.debug.print("usage: lepton-invoke-check layout | app-commands | types | app-types | events | serve\n", .{});
    return error.Usage;
}

/// Fills `buffer` from stdin; false on a clean end of input before the first byte.
fn readExactly(buffer: []u8) error{ ReadFailed, TruncatedRequest }!bool {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const got = std.c.read(0, buffer[filled..].ptr, buffer.len - filled);
        if (got < 0) return error.ReadFailed;
        if (got == 0) {
            if (filled == 0) return false;
            return error.TruncatedRequest;
        }
        filled += @intCast(got);
    }
    return true;
}

fn writeAll(bytes: []const u8) error{WriteFailed}!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const wrote = std.c.write(1, bytes[sent..].ptr, bytes.len - sent);
        if (wrote <= 0) return error.WriteFailed;
        sent += @intCast(wrote);
    }
}
