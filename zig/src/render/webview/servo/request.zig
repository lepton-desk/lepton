//! One request on the app's scheme as Servo hands it over: a `LeptonServoRequest` from the
//! bridge (`servo/lepton_servo.h`).
//!
//! The engine half of the bridge for Servo, beside `wpe_request.zig` and
//! `webview2/request.zig`; `request.zig` chooses one. The bridge's request is counted like
//! a GObject — `ref`, `unref`, the last `unref` of one never answered answers 500 — so
//! `bridge.zig` holds and answers it as it holds WebKit's.

const std = @import("std");
const c = @import("c.zig").c;

pub const Request = ?*anyopaque;
pub const BodyError = error{ Missing, Unreadable };

fn of(request: Request) ?*c.LeptonServoRequest {
    return @ptrCast(request);
}

/// The bytes a `lepton_servo_request_*` call points at. The call runs first and its length
/// is passed after: an argument list is evaluated left to right, and passing the pointer
/// beside the call read it before the call set it (measured in `servo-window-check`).
fn part(request: Request, comptime read: anytype) []const u8 {
    const held = of(request) orelse return "";
    var pointer: [*c]const u8 = null;
    const len = read(held, &pointer);
    if (len == 0 or pointer == null) return "";
    return pointer[0..len];
}

pub fn uri(request: Request) []const u8 {
    return part(request, c.lepton_servo_request_url);
}

pub fn path(request: Request) ?[]const u8 {
    return pathOf(uri(request));
}

/// The path of an absolute URL, without query or fragment; "/" for none.
pub fn pathOf(text: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, text, "://") orelse return null;
    const rest = text[scheme_end + 3 ..];
    const start = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    const after = rest[start..];
    const end = std.mem.indexOfAny(u8, after, "?#") orelse after.len;
    return after[0..end];
}

pub fn method(request: Request) []const u8 {
    return part(request, c.lepton_servo_request_method);
}

/// The request body into `into`, as `read_all` gives WebKit's: at most `into.len` bytes,
/// so the caller sizes `into` one past its limit to tell "more" apart.
pub fn body(request: Request, into: []u8) BodyError!usize {
    if (of(request) == null) return error.Missing;
    const bytes_read = part(request, c.lepton_servo_request_body);
    const n = @min(bytes_read.len, into.len);
    @memcpy(into[0..n], bytes_read[0..n]);
    return n;
}

pub fn ref(request: Request) Request {
    if (of(request)) |held| c.lepton_servo_request_ref(held);
    return request;
}

pub fn unref(request: Request) void {
    if (of(request)) |held| c.lepton_servo_request_unref(held);
}

fn answer(request: Request, status: u16, content_type: []const u8, allow_origin: []const u8, data: []const u8) void {
    const held = of(request) orelse return;
    c.lepton_servo_request_respond(held, status, content_type.ptr, content_type.len, allow_origin.ptr, allow_origin.len, data.ptr, data.len);
}

/// Answers with `len` bytes at `data`. The bridge copies them, so `destroy` runs at once.
pub fn bytes(
    request: Request,
    data: [*]const u8,
    len: usize,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    content_type: [*:0]const u8,
    allow_origin: [:0]const u8,
) bool {
    defer if (destroy) |free| free(@ptrCast(@constCast(data)));
    if (of(request) == null) return false;
    answer(request, 200, std.mem.span(content_type), allow_origin, data[0..len]);
    return true;
}

/// Refused: a 500 with `message`, which every reader in `transport.zig` and
/// `@lepton-desk/api` treats as the failure (`!response.ok`), as on WebView2.
pub fn refuse(request: Request, message: [*:0]const u8) void {
    answer(request, 500, "text/plain; charset=utf-8", "", std.mem.span(message));
}

/// No such file: a 404, so a missing asset reads as absent rather than as the core failing.
pub fn missing(request: Request, message: [*:0]const u8) void {
    answer(request, 404, "text/plain; charset=utf-8", "", std.mem.span(message));
}

/// Calls `callback(data)` once after `ms`, from the view's loop (`view.zig`).
pub const timeoutOnce = @import("view.zig").timeoutOnce;

test "the path is read from the URL without its query" {
    try std.testing.expectEqualStrings("/__lepton/events", pathOf("lepton://localhost/__lepton/events?after=3").?);
    try std.testing.expectEqualStrings("/", pathOf("lepton://localhost").?);
    try std.testing.expectEqualStrings("/", pathOf("lepton://localhost/").?);
    try std.testing.expectEqualStrings("/a%20b.js", pathOf("lepton://localhost/a%20b.js#x").?);
    try std.testing.expect(pathOf("not a url") == null);
}
