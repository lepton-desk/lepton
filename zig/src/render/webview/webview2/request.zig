//! One request to the core as WebView2 hands it over: a `WebResourceRequested` event.
//!
//! The view filters `http://lepton.localhost/*` (`view.zig`); each matching request
//! becomes a `Pending` here, and its pointer is the opaque request the bridge works with
//! (`request.zig`). The event is answered later through a deferral — the bridge holds
//! the events and region reads until there is something new, and a file dialog's
//! command answers when the user closes it — so a `Pending` is counted the way the
//! bridge expects a GObject to be: `ref` keeps it, `unref` drops it, and the last
//! `unref` completes the deferral and frees it.
//!
//! Everything runs on the window's thread: WebView2 raises the event there and accepts
//! the deferral's completion only there.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;

pub const Request = ?*anyopaque;
pub const BodyError = error{ Missing, Unreadable };

/// The longest URL kept; a longer one is refused rather than cut.
const max_uri = 4096;

pub const Pending = struct {
    refs: u32 = 1,
    answered: bool = false,
    args: *c.ICoreWebView2WebResourceRequestedEventArgs,
    deferral: *c.ICoreWebView2Deferral,
    request: *c.ICoreWebView2WebResourceRequest,
    environment: *c.ICoreWebView2Environment,
    uri_buffer: [max_uri]u8 = undefined,
    uri_len: usize = 0,
    method_buffer: [16]u8 = undefined,
    method_len: usize = 0,

    fn url(self: *const Pending) []const u8 {
        return self.uri_buffer[0..self.uri_len];
    }
};

/// Takes the event's request and a deferral; null when WebView2 refuses either, and the
/// event then completes as if unhandled.
pub fn begin(environment: *c.ICoreWebView2Environment, args: *c.ICoreWebView2WebResourceRequestedEventArgs) ?*Pending {
    var request: [*c]c.ICoreWebView2WebResourceRequest = null;
    if (!wv.ok(args.lpVtbl.*.get_Request.?(args, &request)) or request == null) return null;
    var deferral: [*c]c.ICoreWebView2Deferral = null;
    if (!wv.ok(args.lpVtbl.*.GetDeferral.?(args, &deferral)) or deferral == null) {
        _ = request.*.lpVtbl.*.Release.?(request);
        return null;
    }
    const raw = std.c.malloc(@sizeOf(Pending)) orelse {
        _ = deferral.*.lpVtbl.*.Complete.?(deferral);
        _ = deferral.*.lpVtbl.*.Release.?(deferral);
        _ = request.*.lpVtbl.*.Release.?(request);
        return null;
    };
    const pending: *Pending = @ptrCast(@alignCast(raw));
    pending.* = .{ .args = args, .deferral = deferral, .request = request, .environment = environment };
    _ = args.lpVtbl.*.AddRef.?(args);
    _ = environment.lpVtbl.*.AddRef.?(environment);

    var wide: c.LPWSTR = null;
    if (wv.ok(request.*.lpVtbl.*.get_Uri.?(request, &wide))) {
        pending.uri_len = wv.takeString(wide, &pending.uri_buffer).len;
    }
    var verb: c.LPWSTR = null;
    if (wv.ok(request.*.lpVtbl.*.get_Method.?(request, &verb))) {
        pending.method_len = wv.takeString(verb, &pending.method_buffer).len;
    }
    return pending;
}

fn of(request: Request) *Pending {
    return @ptrCast(@alignCast(request.?));
}

pub fn uri(request: Request) []const u8 {
    return of(request).url();
}

/// The path of the URL, without query or fragment, still percent-encoded (as WebKit's is;
/// `assets.resolve` decodes).
pub fn path(request: Request) ?[]const u8 {
    return pathOf(of(request).url());
}

pub fn pathOf(text: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, text, "://") orelse return null;
    const rest = text[scheme_end + 3 ..];
    const start = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    const tail = rest[start..];
    const end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    return tail[0..end];
}

pub fn method(request: Request) []const u8 {
    const pending = of(request);
    return pending.method_buffer[0..pending.method_len];
}

pub fn body(request: Request, into: []u8) BodyError!usize {
    const pending = of(request);
    var stream: [*c]c.IStream = null;
    if (!wv.ok(pending.request.lpVtbl.*.get_Content.?(pending.request, &stream)) or stream == null) return error.Missing;
    defer _ = stream.*.lpVtbl.*.Release.?(stream);
    var total: usize = 0;
    while (total < into.len) {
        var got: c.ULONG = 0;
        const asked: c.ULONG = @intCast(@min(into.len - total, std.math.maxInt(c.ULONG)));
        const hr = stream.*.lpVtbl.*.Read.?(stream, into.ptr + total, asked, &got);
        if (!wv.ok(hr)) return error.Unreadable;
        if (got == 0) break;
        total += got;
    }
    return total;
}

pub fn ref(request: Request) Request {
    of(request).refs += 1;
    return request;
}

/// Drops one reference; the last one completes the deferral (unanswered, the request then
/// goes on to the network and fails there) and frees the request.
pub fn unref(request: Request) void {
    const pending = of(request);
    pending.refs -= 1;
    if (pending.refs != 0) return;
    if (!pending.answered) {
        _ = pending.deferral.lpVtbl.*.Complete.?(pending.deferral);
    }
    _ = pending.deferral.lpVtbl.*.Release.?(pending.deferral);
    _ = pending.request.lpVtbl.*.Release.?(pending.request);
    _ = pending.args.lpVtbl.*.Release.?(pending.args);
    _ = pending.environment.lpVtbl.*.Release.?(pending.environment);
    std.c.free(pending);
}

/// The longest header block: content type and the one allowed origin, with names.
const max_headers = 512;

/// Answers with `len` bytes at `data`, copied into a memory stream (so `destroy` runs at
/// once). Returns false when no response could be made.
pub fn bytes(
    request: Request,
    data: [*]const u8,
    len: usize,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    content_type: [*:0]const u8,
    allow_origin: [:0]const u8,
) bool {
    const pending = of(request);
    defer if (destroy) |free| free(@ptrCast(@constCast(data)));
    if (pending.answered) return false;

    var text: [max_headers]u8 = undefined;
    const headers = headerBlock(&text, std.mem.span(content_type), allow_origin) catch return false;
    var wide: [max_headers:0]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(&wide, headers) catch return false;
    wide[units] = 0;

    const stream = c.SHCreateMemStream(data, @intCast(len)) orelse return false;
    defer _ = stream.*.lpVtbl.*.Release.?(stream);
    return finish(pending, stream, 200, wv.W("OK"), &wide);
}

/// Refuses with a 500 and `message` as its text. WebKit fails the fetch outright; a
/// WebView2 response cannot, so the page sees `!response.ok` — which every reader in
/// `transport.zig` and `@lepton-desk/api` already treats as the failure.
pub fn refuse(request: Request, message: [*:0]const u8) void {
    answerText(request, message, 500, wv.W("Refused"));
}

/// No such file: a 404, so a page's `<link rel=icon>` or a missing asset reads as
/// absent rather than as the core failing (measured: `favicon.ico` showed as a 500).
/// `/favicon.ico` is the exception: WebView2 asks for it on every page load whether the
/// page names one or not (WPE does not), and its 404 was the one console error every new
/// project showed (measured on all five Astro, Next and Angular templates). An empty 204
/// is just as absent and logs nothing.
pub fn missing(request: Request, message: [*:0]const u8) void {
    if (isFavicon(path(request))) {
        answerText(request, "", 204, wv.W("No Content"));
        return;
    }
    answerText(request, message, 404, wv.W("Not Found"));
}

fn isFavicon(asked: ?[]const u8) bool {
    return std.mem.eql(u8, asked orelse return false, "/favicon.ico");
}

test "only the root favicon is answered empty" {
    try std.testing.expect(isFavicon(pathOf("http://lepton.localhost/favicon.ico?v=2")));
    try std.testing.expect(!isFavicon(pathOf("http://lepton.localhost/img/favicon.ico")));
    try std.testing.expect(!isFavicon(pathOf("http://lepton.localhost/app.js")));
    try std.testing.expect(!isFavicon(null));
}

fn answerText(request: Request, message: [*:0]const u8, status: c_int, reason: [*:0]const u16) void {
    const pending = of(request);
    if (pending.answered) return;
    const text = std.mem.span(message);
    const stream = c.SHCreateMemStream(text.ptr, @intCast(text.len)) orelse return;
    defer _ = stream.*.lpVtbl.*.Release.?(stream);
    _ = finish(pending, stream, status, reason, wv.W("Content-Type: text/plain\r\nCache-Control: no-store"));
}

fn finish(pending: *Pending, stream: *c.IStream, status: c_int, reason: [*:0]const u16, headers: [*:0]const u16) bool {
    var response: [*c]c.ICoreWebView2WebResourceResponse = null;
    const environment = pending.environment;
    if (!wv.ok(environment.lpVtbl.*.CreateWebResourceResponse.?(environment, stream, status, reason, headers, &response)) or response == null) return false;
    defer _ = response.*.lpVtbl.*.Release.?(response);
    if (!wv.ok(pending.args.lpVtbl.*.put_Response.?(pending.args, response))) return false;
    pending.answered = true;
    _ = pending.deferral.lpVtbl.*.Complete.?(pending.deferral);
    return true;
}

fn headerBlock(out: []u8, content_type: []const u8, allow_origin: []const u8) error{NoSpaceLeft}![]const u8 {
    if (allow_origin.len == 0) {
        return std.fmt.bufPrint(out, "Content-Type: {s}\r\nCache-Control: no-store", .{content_type});
    }
    return std.fmt.bufPrint(
        out,
        "Content-Type: {s}\r\nAccess-Control-Allow-Origin: {s}\r\nVary: Origin\r\nCache-Control: no-store",
        .{ content_type, allow_origin },
    );
}

// --- one-shot timers, the counterpart of `g_timeout_add` returning 0 ----------------------

const Timer = struct {
    id: usize = 0,
    callback: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    data: ?*anyopaque = null,
};
var timers: [16]Timer = @splat(.{});

fn onTimer(_: c.HWND, _: c.UINT, id: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
    _ = c.KillTimer(null, id);
    for (&timers) |*timer| {
        if (timer.id != id) continue;
        const callback = timer.callback orelse return;
        const data = timer.data;
        timer.* = .{};
        _ = callback(data);
        return;
    }
}

/// Calls `callback(data)` once after `ms`, from the window thread's message loop.
pub fn timeoutOnce(ms: c_uint, callback: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) void {
    for (&timers) |*timer| {
        if (timer.callback != null) continue;
        const id = c.SetTimer(null, 0, ms, onTimer);
        if (id == 0) return;
        timer.* = .{ .id = id, .callback = callback, .data = data };
        return;
    }
}

test "the path is read from the URL without its query" {
    try std.testing.expectEqualStrings("/__lepton/events", pathOf("http://lepton.localhost/__lepton/events?after=3").?);
    try std.testing.expectEqualStrings("/", pathOf("http://lepton.localhost").?);
    try std.testing.expectEqualStrings("/a%20b.js", pathOf("http://lepton.localhost/a%20b.js#x").?);
    try std.testing.expect(pathOf("not a url") == null);
}

test "an answer names one origin, never a wildcard" {
    var out: [max_headers]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Content-Type: text/html\r\nCache-Control: no-store",
        try headerBlock(&out, "text/html", ""),
    );
    const cross = try headerBlock(&out, "application/octet-stream", "http://127.0.0.1:5173");
    try std.testing.expect(std.mem.indexOf(u8, cross, "Access-Control-Allow-Origin: http://127.0.0.1:5173\r\n") != null);
}
