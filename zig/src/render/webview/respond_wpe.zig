//! Answering one `lepton://` request on WPE, with the engine's ownership rules kept.
//!
//! `WPEWebKit-2.0.gir` (2.54.1) is explicit about who owns what, and the bridge's first
//! version followed none of it:
//!
//! * `webkit_uri_scheme_request_finish` takes the stream **transfer none** — the caller
//!   still holds its reference. It was never dropped, so every answer leaked its
//!   `GMemoryInputStream`, and an asset's `malloc` buffer (freed only when the stream is
//!   finalised) leaked with it. The page refreshes its ring four times a second.
//! * `webkit_uri_scheme_request_finish_error` takes the `GError` transfer none: never freed.
//! * `webkit_uri_scheme_response_set_http_headers` takes the headers **transfer full**:
//!   they must *not* be freed here.
//!
//! An answer may carry `Access-Control-Allow-Origin` for exactly one origin. In
//! development the page is served by Vite at `http://127.0.0.1:<port>` and fetches the
//! ring from `lepton://localhost`, a cross-origin read the engine allows only when the
//! response names the page's origin. One origin, never `*`.

const std = @import("std");

const e_memory_stream = @extern(
    *const fn (?*const anyopaque, usize, ?*const anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "g_memory_input_stream_new_from_data" },
);
const e_object_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_object_unref" });
const e_request_finish = @extern(
    *const fn (?*anyopaque, ?*anyopaque, i64, [*:0]const u8) callconv(.c) void,
    .{ .name = "webkit_uri_scheme_request_finish" },
);
const e_request_finish_error = @extern(
    *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_uri_scheme_request_finish_error" },
);
const e_response_new = @extern(
    *const fn (?*anyopaque, i64) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_uri_scheme_response_new" },
);
const e_response_content_type = @extern(
    *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    .{ .name = "webkit_uri_scheme_response_set_content_type" },
);
const e_response_headers = @extern(
    *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_uri_scheme_response_set_http_headers" },
);
const e_request_finish_response = @extern(
    *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_uri_scheme_request_finish_with_response" },
);
const e_headers_new = @extern(*const fn (c_int) callconv(.c) ?*anyopaque, .{ .name = "soup_message_headers_new" });
const e_headers_append = @extern(
    *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void,
    .{ .name = "soup_message_headers_append" },
);
const e_quark = @extern(*const fn ([*:0]const u8) callconv(.c) u32, .{ .name = "g_quark_from_static_string" });
const e_error_new_literal = @extern(
    *const fn (u32, c_int, [*:0]const u8) callconv(.c) ?*anyopaque,
    .{ .name = "g_error_new_literal" },
);
const e_error_free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_error_free" });

/// `SOUP_MESSAGE_HEADERS_RESPONSE` (`soup-message-headers.h`, libsoup 3.8).
const soup_headers_response: c_int = 1;

/// Answers `request` with `len` bytes at `data`.
///
/// `destroy` is called on `data` when the engine is done with the stream (`null` for
/// memory the caller keeps alive, such as the channel mapping). `allow_origin` is a
/// NUL-terminated origin or empty for a same-origin answer. Returns false when no stream
/// could be made — and then `destroy` has already been applied to `data`.
pub fn bytes(
    request: ?*anyopaque,
    data: [*]const u8,
    len: usize,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
    content_type: [*:0]const u8,
    allow_origin: [:0]const u8,
) bool {
    const stream = e_memory_stream(data, len, destroy) orelse {
        if (destroy) |free| free(@ptrCast(@constCast(data)));
        return false;
    };
    defer e_object_unref(stream);

    if (allow_origin.len == 0) {
        e_request_finish(request, stream, @intCast(len), content_type);
        return true;
    }

    const response = e_response_new(stream, @intCast(len)) orelse {
        e_request_finish(request, stream, @intCast(len), content_type);
        return true;
    };
    defer e_object_unref(response);
    e_response_content_type(response, content_type);
    if (e_headers_new(soup_headers_response)) |headers| {
        e_headers_append(headers, "Access-Control-Allow-Origin", allow_origin.ptr);
        e_headers_append(headers, "Vary", "Origin");
        e_headers_append(headers, "Cache-Control", "no-store");
        e_response_headers(response, headers); // transfer full: the response owns them now
    }
    e_request_finish_response(request, response);
    return true;
}

/// Refuses `request` with `message`; the page sees a failed fetch it can report.
pub fn refuse(request: ?*anyopaque, message: [*:0]const u8) void {
    const failure = e_error_new_literal(e_quark("lepton-bridge"), 1, message) orelse return;
    e_request_finish_error(request, failure);
    e_error_free(failure);
}
