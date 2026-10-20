//! Files the page downloads: written to the user's download directory (`XDG_DOWNLOAD_DIR`,
//! `~/İndirilenler` on a Turkish desktop) under the name the server suggested, made safe
//! and unique, and reported to the page as events (user's decision, 2026-10-16).
//!
//! Before this nothing listened, and WebKit had nowhere to put a download.
//!
//! Events, each starting with the download's `u32` id (little-endian):
//! - `download.started`: then the file's name, UTF-8;
//! - `download.progress`: then `u32` 0, `u64` bytes received, `u64` bytes expected (0 when
//!   the server did not say) — at most four a second, so a large file cannot push every
//!   other event out of the 64-entry log;
//! - `download.finished`: then the file's full path, UTF-8;
//! - `download.failed`: then WebKit's message, UTF-8.

const std = @import("std");
const build_options = @import("build_options");
const events = @import("events.zig");

const started = events.download_started;
const progress = events.download_progress;
const finished = events.download_finished;
const failed = events.download_failed;

/// The longest name kept, in bytes, cut on a character boundary.
const max_name = 200;

/// A file name from the server's suggestion: its last path element, without control
/// characters, never empty, `.` or `..`, and never hidden (a leading `.` becomes `_`).
pub fn safeName(suggested: []const u8, out: []u8) []const u8 {
    const base = if (std.mem.lastIndexOfAny(u8, suggested, "/\\")) |slash| suggested[slash + 1 ..] else suggested;
    var used: usize = 0;
    for (base) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        if (used == out.len) break;
        out[used] = ch;
        used += 1;
    }
    var name = out[0..used];
    if (name.len > max_name) {
        var end: usize = max_name;
        while (end > 0 and (name[end] & 0xC0) == 0x80) end -= 1;
        name = name[0..end];
    }
    const trimmed = std.mem.trim(u8, name, " ");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) {
        const fallback = "download";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    const start = @intFromPtr(trimmed.ptr) - @intFromPtr(out.ptr);
    if (trimmed[0] == '.') out[start] = '_';
    return out[start..][0..trimmed.len];
}

fn exists(path: [:0]const u8) bool {
    return std.c.access(path.ptr, 0) == 0;
}

/// `directory/name`, or `directory/stem (n).ext` with the first free `n`, NUL-terminated.
pub fn uniquePath(directory: []const u8, name: []const u8, out: []u8) error{NoSpaceLeft}![:0]const u8 {
    const first = try std.fmt.bufPrintSentinel(out, "{s}/{s}", .{ directory, name }, 0);
    if (!exists(first)) return first;
    // The extension is what follows the last dot, unless the dot starts the name.
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const split = if (dot) |at| (if (at == 0) name.len else at) else name.len;
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const candidate = try std.fmt.bufPrintSentinel(out, "{s}/{s} ({d}){s}", .{ directory, name[0..split], n, name[split..] }, 0);
        if (!exists(candidate)) return candidate;
    }
    return error.NoSpaceLeft;
}

/// Whether enough time passed since the last progress event to send another.
pub fn progressDue(last_ns: ?u64, now_ns: u64) bool {
    const last = last_ns orelse return true;
    return now_ns -| last >= std.time.ns_per_s / 4;
}

/// `download.progress`'s payload.
pub fn progressPayload(id: u32, received: u64, expected: u64) [24]u8 {
    var bytes: [24]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], id, .little);
    std.mem.writeInt(u64, bytes[8..16], received, .little);
    std.mem.writeInt(u64, bytes[16..24], expected, .little);
    return bytes;
}

/// An id and text, for the other three events; the text is cut to fit an event.
pub fn textPayload(id: u32, text: []const u8, out: *[events.max_data]u8) []const u8 {
    std.mem.writeInt(u32, out[0..4], id, .little);
    const room = out.len - 4;
    var length = @min(text.len, room);
    while (length < text.len and length > 0 and (text[length] & 0xC0) == 0x80) length -= 1;
    @memcpy(out[4..][0..length], text[0..length]);
    return out[0 .. 4 + length];
}

const Bridge = @import("bridge.zig").Bridge;
const paths = @import("../../platform/linux/paths.zig");

const e_signal_connect = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    .{ .name = "g_signal_connect_data" },
);
const e_network_session = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_web_view_get_network_session" });
const e_set_destination = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, .{ .name = "webkit_download_set_destination" });
const e_get_destination = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_download_get_destination" });
const e_received = @extern(*const fn (?*anyopaque) callconv(.c) u64, .{ .name = "webkit_download_get_received_data_length" });
const e_response = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_download_get_response" });
const e_content_length = @extern(*const fn (?*anyopaque) callconv(.c) u64, .{ .name = "webkit_uri_response_get_content_length" });

/// `GError`'s layout (glib/gerror.h): the message is what the page is told.
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

/// One download in flight. A static table: GLib keeps each entry's address as signal data.
const Active = struct {
    download: ?*anyopaque = null,
    bridge: ?*Bridge = null,
    id: u32 = 0,
    last_progress_ns: ?u64 = null,
    failed: bool = false,
};
var active: [16]Active = @splat(.{});
var next_id: u32 = 1;
var started_at: ?std.Io.Clock.Timestamp = null;

fn nowNs() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const origin = started_at orelse blk: {
        started_at = now;
        break :blk now;
    };
    const elapsed = origin.durationTo(now).raw.nanoseconds;
    return if (elapsed < 0) 0 else @intCast(elapsed);
}

/// Takes this view's downloads. `bridge` must outlive the view (it is the view's own).
pub fn watch(web_view: *anyopaque, bridge: *Bridge) void {
    const session = e_network_session(web_view) orelse return;
    _ = e_signal_connect(session, "download-started", @ptrCast(&onStarted), bridge, null, 0);
}

fn onStarted(_: ?*anyopaque, download: ?*anyopaque, bridge: ?*anyopaque) callconv(.c) void {
    const slot = for (&active) |*entry| {
        if (entry.download == null) break entry;
    } else return; // Sixteen at once: the rest go where WebKit puts them, unreported.
    slot.* = .{ .download = download, .bridge = @ptrCast(@alignCast(bridge)), .id = next_id };
    next_id +%= 1;
    _ = e_signal_connect(download, "decide-destination", @ptrCast(&onDecideDestination), slot, null, 0);
    _ = e_signal_connect(download, "received-data", @ptrCast(&onReceived), slot, null, 0);
    _ = e_signal_connect(download, "failed", @ptrCast(&onFailed), slot, null, 0);
    _ = e_signal_connect(download, "finished", @ptrCast(&onFinished), slot, null, 0);
}

fn onDecideDestination(download: ?*anyopaque, suggested: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) c_int {
    const slot: *Active = @ptrCast(@alignCast(data orelse return 0));
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const directory = paths.resolve(.download, "", &directory_buffer, &scratch) catch return 0;
    // The directory exists on a desktop; when it does not, it is made private.
    var made: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(made[0..directory.len], directory);
    made[directory.len] = 0;
    _ = paths.makePrivate(made[0..directory.len :0]);
    var name_buffer: [256]u8 = undefined;
    const name = safeName(if (suggested) |raw| std.mem.span(raw) else "", &name_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = uniquePath(directory, name, &path_buffer) catch return 0;
    e_set_destination(download, path.ptr);
    var payload: [events.max_data]u8 = undefined;
    if (slot.bridge) |bridge| _ = bridge.emit(started, textPayload(slot.id, std.fs.path.basename(path), &payload)) catch {};
    return 1;
}

fn onReceived(download: ?*anyopaque, _: u64, data: ?*anyopaque) callconv(.c) void {
    const slot: *Active = @ptrCast(@alignCast(data orelse return));
    const now = nowNs();
    if (!progressDue(slot.last_progress_ns, now)) return;
    slot.last_progress_ns = now;
    const expected = if (e_response(download)) |response| e_content_length(response) else 0;
    const bytes = progressPayload(slot.id, e_received(download), expected);
    if (slot.bridge) |bridge| _ = bridge.emit(progress, &bytes) catch {};
}

fn onFailed(_: ?*anyopaque, failure: ?*const GError, data: ?*anyopaque) callconv(.c) void {
    const slot: *Active = @ptrCast(@alignCast(data orelse return));
    slot.failed = true;
    const message = if (failure) |err| if (err.message) |raw| std.mem.span(raw) else "failed" else "failed";
    var payload: [events.max_data]u8 = undefined;
    if (slot.bridge) |bridge| _ = bridge.emit(failed, textPayload(slot.id, message, &payload)) catch {};
}

/// After `failed` too, by WebKit's order: then only the slot is freed.
fn onFinished(download: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const slot: *Active = @ptrCast(@alignCast(data orelse return));
    if (!slot.failed) {
        const path = if (e_get_destination(download)) |raw| std.mem.span(raw) else "";
        var payload: [events.max_data]u8 = undefined;
        if (slot.bridge) |bridge| _ = bridge.emit(finished, textPayload(slot.id, path, &payload)) catch {};
    }
    slot.* = .{};
}

test "a suggested name is made safe" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("report.pdf", safeName("report.pdf", &out));
    try std.testing.expectEqualStrings("passwd", safeName("../../etc/passwd", &out));
    try std.testing.expectEqualStrings("evil.exe", safeName("C:\\temp\\evil.exe", &out));
    try std.testing.expectEqualStrings("download", safeName("..", &out));
    try std.testing.expectEqualStrings("download", safeName("", &out));
    try std.testing.expectEqualStrings("download", safeName("dir/", &out));
    try std.testing.expectEqualStrings("_bashrc", safeName(".bashrc", &out));
    try std.testing.expectEqualStrings("ab", safeName("a\nb", &out));
    try std.testing.expectEqualStrings("Rapor şubat.txt", safeName("Rapor şubat.txt", &out));
    const long = comptime blk: {
        var bytes: [300]u8 = undefined;
        for (0..150) |at| @memcpy(bytes[at * 2 ..][0..2], "ş");
        break :blk bytes;
    }; // 300 bytes
    const cut = safeName(&long, &out);
    try std.testing.expect(cut.len <= max_name);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "a name already taken gets the first free number" {
    var name_buffer: [96]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&name_buffer, "/tmp/lepton-downloads-test-{d}", .{std.c.getpid()}, 0);
    _ = std.c.mkdir(directory.ptr, 0o700);
    var path: [256]u8 = undefined;
    defer {
        for ([_][]const u8{ "a.txt", "a (1).txt", ".hidden" }) |file| {
            const full = std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ directory, file }, 0) catch continue;
            _ = std.c.unlink(full.ptr);
        }
        _ = std.c.rmdir(directory.ptr);
    }
    var out: [256]u8 = undefined;
    const free = try uniquePath(directory, "a.txt", &out);
    try std.testing.expect(std.mem.endsWith(u8, free, "/a.txt"));
    for ([_][]const u8{ "a.txt", "a (1).txt", ".hidden" }) |file| {
        const full = try std.fmt.bufPrintSentinel(&path, "{s}/{s}", .{ directory, file }, 0);
        const fd = std.c.open(full.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        _ = std.c.close(fd);
    }
    try std.testing.expect(std.mem.endsWith(u8, try uniquePath(directory, "a.txt", &out), "/a (2).txt"));
    try std.testing.expect(std.mem.endsWith(u8, try uniquePath(directory, ".hidden", &out), "/.hidden (1)"));
}

test "progress is sent at most four times a second" {
    try std.testing.expect(progressDue(null, 0));
    try std.testing.expect(!progressDue(1_000, 1_000 + std.time.ns_per_s / 5));
    try std.testing.expect(progressDue(1_000, 1_000 + std.time.ns_per_s / 4));
    const bytes = progressPayload(7, 1024, 4096);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u64, 4096), std.mem.readInt(u64, bytes[16..24], .little));
    var out: [events.max_data]u8 = undefined;
    const text = textPayload(3, "/home/u/İndirilenler/a.txt", &out);
    try std.testing.expectEqualStrings("/home/u/İndirilenler/a.txt", text[4..]);
}

test "the download callbacks are compiled" {
    if (comptime !(build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render)) return error.SkipZigTest;
    _ = &watch;
}
