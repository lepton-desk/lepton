//! Answering one `lepton://` request: the engine's half lives in `respond_wpe.zig`
//! (WebKit) or `webview2/request.zig` (WebView2), chosen by `request.zig`.
//!
//! An answer may carry `Access-Control-Allow-Origin` for exactly one origin. In
//! development the page is served by Vite at `http://127.0.0.1:<port>` and fetches the
//! ring from the core's origin, a cross-origin read the engine allows only when the
//! response names the page's origin. One origin, never `*`.

const std = @import("std");
const request = @import("request.zig");

/// The longest origin kept: scheme, host and port, NUL included.
pub const max_origin = 256;

/// Answers `request` with `len` bytes at `data`.
///
/// `destroy` is called on `data` when the engine is done with it (`null` for memory the
/// caller keeps alive, such as the channel mapping). `allow_origin` is a NUL-terminated
/// origin or empty for a same-origin answer. Returns false when no answer could be made —
/// and then `destroy` has already been applied to `data`.
pub const bytes = request.bytes;

/// Refuses `request` with `message`; the page sees a failed fetch it can report.
pub const refuse = request.refuse;

/// Answers that the frontend has no such file: a 404 where the engine has statuses
/// (WebView2), the same failure as `refuse` where it has not (WebKit's scheme handler).
pub const missing = request.missing;

/// The origin of an absolute URL — `scheme://host[:port]` — into `out`, NUL-terminated.
///
/// The dev server's address is a URL (`http://127.0.0.1:5173/`); the header wants the
/// origin alone, and a path or query in it would never match the page's `Origin`.
pub fn originOf(url: []const u8, out: []u8) ?[:0]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    if (scheme_end == 0) return null;
    const rest = url[scheme_end + 3 ..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (host_end == 0) return null;
    const origin = url[0 .. scheme_end + 3 + host_end];
    if (origin.len + 1 > out.len) return null;
    @memcpy(out[0..origin.len], origin);
    out[origin.len] = 0;
    return out[0..origin.len :0];
}

test "a dev server URL yields its origin and nothing else" {
    var buffer: [max_origin]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", originOf("http://127.0.0.1:5173", &buffer).?);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", originOf("http://127.0.0.1:5173/", &buffer).?);
    try std.testing.expectEqualStrings("http://localhost:4321", originOf("http://localhost:4321/src/main.ts?x#y", &buffer).?);
}

test "something that is not an absolute URL has no origin" {
    var buffer: [max_origin]u8 = undefined;
    try std.testing.expect(originOf("127.0.0.1:5173", &buffer) == null);
    try std.testing.expect(originOf("http:///path", &buffer) == null);
    try std.testing.expect(originOf("://host", &buffer) == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(originOf("http://127.0.0.1:5173", &tiny) == null);
}
