//! The core's `invoke` handler, outside a window, for the SDK's tests.
//!
//! `lepton-invoke-check layout` prints the layout object the page receives as
//! `__lepton.layout`, `app …` the `__lepton.app` object for the given values.
//! `lepton-invoke-check serve` reads request frames from stdin —
//! each preceded by its length as a little-endian `u32` — and answers each with the
//! reply frame `invoke.handle` writes, framed the same way. The SDK's tests drive this
//! with frames built by `@lepton-desk/api/core`, so both ends of a test are the shipped
//! code: no stand-in for the core.

const std = @import("std");
const builtin = @import("builtin");
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
    // Windows has no argv to borrow: its command line is decoded into a buffer.
    var args = try init.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
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
    if (std.mem.eql(u8, mode, "app")) {
        // `__lepton.app` for a name, version, identifier and title given here.
        const given = core.webviewTransport.Application{
            .name = args.next() orelse return usage(),
            .version = args.next() orelse return usage(),
            .identifier = args.next() orelse return usage(),
            .title = args.next() orelse return usage(),
        };
        var object: [8192]u8 = undefined;
        try writeAll(try core.webviewTransport.writeApplication(&object, given));
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
    if (std.mem.eql(u8, mode, "download-events")) {
        // A download's four events, with the core's own payloads.
        const downloads = core.webviewDownloads;
        var log: core.webviewEvents.Log = .{};
        var text: [core.webviewEvents.max_data]u8 = undefined;
        _ = try log.emit("download.started", downloads.textPayload(7, "rapor şubat.pdf", &text));
        const bytes = downloads.progressPayload(7, 1024, 4096);
        _ = try log.emit("download.progress", &bytes);
        _ = try log.emit("download.finished", downloads.textPayload(7, "/home/u/İndirilenler/rapor şubat.pdf", &text));
        _ = try log.emit("download.failed", downloads.textPayload(8, "Connection refused", &text));
        var out: [2048]u8 = undefined;
        try writeAll(try log.writeSince(0, &out));
        return;
    }
    if (std.mem.eql(u8, mode, "permission-events")) {
        // A camera-and-microphone request as the page is asked it.
        var log: core.webviewEvents.Log = .{};
        var payload: [core.webviewEvents.max_data]u8 = undefined;
        _ = try log.emit("permission.request", core.webviewPermissions.requestPayload(5, &.{ .camera, .microphone }, &payload));
        var out: [512]u8 = undefined;
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
    std.debug.print("usage: lepton-invoke-check layout | app-commands | app <name> <version> <identifier> <title> | types | app-types | events | download-events | permission-events | serve\n", .{});
    return error.Usage;
}

/// Fills `buffer` from stdin; false on a clean end of input before the first byte.
fn readExactly(buffer: []u8) error{ ReadFailed, TruncatedRequest }!bool {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const got = try readSome(buffer[filled..]);
        if (got == 0) {
            if (filled == 0) return false;
            return error.TruncatedRequest;
        }
        filled += got;
    }
    return true;
}

fn writeAll(bytes: []const u8) error{WriteFailed}!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += try writeSome(bytes[sent..]);
    }
}

// stdin and stdout as raw bytes. On Windows the C runtime's descriptors are in text mode
// (a 0x0A byte in a frame would gain a 0x0D), so the handles are read and written directly.
const windows = builtin.os.tag == .windows;
extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadFile(file: ?*anyopaque, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(file: ?*anyopaque, buffer: [*]const u8, len: u32, wrote: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
const std_input: u32 = @bitCast(@as(i32, -10));
const std_output: u32 = @bitCast(@as(i32, -11));
const error_broken_pipe = 109;

/// Bytes read into `buffer`; 0 at the end of input.
fn readSome(buffer: []u8) error{ReadFailed}!usize {
    if (windows) {
        var got: u32 = 0;
        const asked: u32 = @intCast(@min(buffer.len, std.math.maxInt(u32)));
        if (ReadFile(GetStdHandle(std_input), buffer.ptr, asked, &got, null) == 0) {
            // A pipe whose writer closed reports the end as an error.
            if (GetLastError() == error_broken_pipe) return 0;
            return error.ReadFailed;
        }
        return got;
    }
    const got = std.c.read(0, buffer.ptr, buffer.len);
    if (got < 0) return error.ReadFailed;
    return @intCast(got);
}

fn writeSome(bytes: []const u8) error{WriteFailed}!usize {
    if (windows) {
        var wrote: u32 = 0;
        const asked: u32 = @intCast(@min(bytes.len, std.math.maxInt(u32)));
        if (WriteFile(GetStdHandle(std_output), bytes.ptr, asked, &wrote, null) == 0 or wrote == 0) return error.WriteFailed;
        return wrote;
    }
    const wrote = std.c.write(1, bytes.ptr, bytes.len);
    if (wrote <= 0) return error.WriteFailed;
    return @intCast(wrote);
}
