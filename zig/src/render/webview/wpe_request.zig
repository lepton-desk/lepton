//! One `lepton://` request as WebKit hands it over: a `WebKitURISchemeRequest`.
//!
//! The engine half of the bridge for WPE. `bridge.zig` decides what to answer; this file
//! reads the request and answers it with the engine's own calls, through `request.zig`.
//! WebView2's counterpart is `webview2/request.zig`.
//!
//! Declared rather than imported: GLib's headers expand to `_Pragma`, which translate-c
//! cannot read, and every signature below is transcribed from the installed header.

const std = @import("std");
const respond_wpe = @import("respond_wpe.zig");

const e_register_scheme = @extern(
    *const fn (?*anyopaque, [*:0]const u8, SchemeCallback, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_web_context_register_uri_scheme" },
);
const e_request_uri = @extern(
    *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    .{ .name = "webkit_uri_scheme_request_get_uri" },
);
const e_request_path = @extern(
    *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    .{ .name = "webkit_uri_scheme_request_get_path" },
);
const e_security_manager = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_web_context_get_security_manager" },
);
const e_register_secure = @extern(
    *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    .{ .name = "webkit_security_manager_register_uri_scheme_as_secure" },
);
const e_register_cors_enabled = @extern(
    *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    .{ .name = "webkit_security_manager_register_uri_scheme_as_cors_enabled" },
);
// `invoke` reads the request body (WPE 2.40+; transfer full, nullable).
const e_request_method = @extern(
    *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    .{ .name = "webkit_uri_scheme_request_get_http_method" },
);
const e_request_body = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_uri_scheme_request_get_http_body" },
);
const e_stream_read_all = @extern(
    *const fn (?*anyopaque, [*]u8, usize, *usize, ?*anyopaque, ?*?*anyopaque) callconv(.c) c_int,
    .{ .name = "g_input_stream_read_all" },
);
// The request's headers (WPE 2.36+; transfer none) and one of them by name (libsoup 3).
const e_request_headers = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_uri_scheme_request_get_http_headers" },
);
const e_header_one = @extern(
    *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?[*:0]const u8,
    .{ .name = "soup_message_headers_get_one" },
);
const e_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_object_unref" });
const e_ref = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "g_object_ref" });
const e_free_error = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_error_free" });
/// One-shot: the callback returns 0. (A repeating timeout added mid-dispatch was seen not
/// to re-arm — `wpe_abi.zig`; a page replay's delayed answer fires once.)
const e_timeout_add = @extern(
    *const fn (c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_uint,
    .{ .name = "g_timeout_add" },
);

const SchemeCallback = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const Request = ?*anyopaque;
pub const BodyError = error{ Missing, Unreadable };

pub fn uri(request: Request) []const u8 {
    return if (e_request_uri(request)) |raw| std.mem.span(raw) else "";
}

pub fn path(request: Request) ?[]const u8 {
    return if (e_request_path(request)) |raw| std.mem.span(raw) else null;
}

pub fn method(request: Request) []const u8 {
    return if (e_request_method(request)) |raw| std.mem.span(raw) else "";
}

/// One request header by name, or null when the request carries none.
pub fn header(request: Request, name: [*:0]const u8) ?[]const u8 {
    const headers = e_request_headers(request) orelse return null;
    return if (e_header_one(headers, name)) |raw| std.mem.span(raw) else null;
}

/// Reads the request body into `into`; the count may exceed nothing — `read_all` stops at
/// `into.len`, and the caller sizes `into` one past its limit to tell "more" apart.
pub fn body(request: Request, into: []u8) BodyError!usize {
    const stream = e_request_body(request) orelse return error.Missing;
    defer e_unref(stream);
    var read: usize = 0;
    var failure: ?*anyopaque = null;
    if (e_stream_read_all(stream, into.ptr, into.len, &read, null, &failure) == 0) {
        if (failure) |owned| e_free_error(owned);
        return error.Unreadable;
    }
    return read;
}

/// Keeps `request` past the callback that delivered it, for a later answer.
pub fn ref(request: Request) Request {
    return e_ref(request);
}

pub fn unref(request: Request) void {
    e_unref(request);
}

pub const bytes = respond_wpe.bytes;
pub const refuse = respond_wpe.refuse;
/// WebKit's scheme handler fails a request with an error, not a status.
pub const missing = respond_wpe.refuse;

/// Calls `callback(data)` once after `ms`, on the engine's loop.
pub fn timeoutOnce(ms: c_uint, callback: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) void {
    _ = e_timeout_add(ms, callback, data);
}

/// Registers `scheme` against `context` for `bridge`, whose `deliver` answers each request.
///
/// `context` is the one the *view* uses rather than the default: a view carries its own
/// context, and a scheme registered only on the default would leave this view unable to
/// resolve it.
pub fn attach(comptime Bridge: type, bridge: *Bridge, context: ?*anyopaque, scheme: [*:0]const u8) void {
    const handler = struct {
        fn onRequest(request: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
            const target: *Bridge = @ptrCast(@alignCast(user_data orelse return));
            target.deliver(request);
        }
    };
    e_register_scheme(context, scheme, &handler.onRequest, bridge, null);
    // A secure, CORS-enabled scheme is what lets a document *served* from it be a real
    // origin: secure-context APIs, module scripts with `crossorigin`, and `fetch` back to
    // the core. The earlier finding "no API makes a custom scheme local or secure"
    // searched `web_context`/`web_view`/`website_data_manager` only; the API lives on
    // `WebKitSecurityManager` (`WebKitSecurityManager.h`, WPE 2.54.1).
    if (e_security_manager(context)) |manager| {
        e_register_secure(manager, scheme);
        e_register_cors_enabled(manager, scheme);
    }
}
