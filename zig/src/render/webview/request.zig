//! The engine's request object, as the bridge sees it: one interface, two engines.
//!
//! `bridge.zig` decides what every request to the core is answered with — the bundled
//! frontend, `invoke`, events, the ring. What a request *is* differs per engine: WebKit
//! hands over a `WebKitURISchemeRequest` (`wpe_request.zig`), WebView2 a
//! `WebResourceRequested` event's arguments with a deferral (`webview2/request.zig`).
//! Both are an opaque pointer here, kept with `ref` and dropped with `unref`, the GObject
//! rules the bridge was written against.

const builtin = @import("builtin");

const engine = if (builtin.os.tag == .windows)
    @import("webview2/request.zig")
else if (@import("build_options").have_servo)
    @import("servo/request.zig")
else
    @import("wpe_request.zig");

pub const Request = engine.Request;
pub const BodyError = engine.BodyError;

/// The request's full URL, or "" when the engine gives none.
pub const uri = engine.uri;
/// The URL's path, without query or fragment.
pub const path = engine.path;
/// `GET`, `POST`, …, or "".
pub const method = engine.method;
/// One request header by name (`Origin`, `Referer`), or null.
pub const header = engine.header;
/// The request body into a caller's buffer.
pub const body = engine.body;
pub const ref = engine.ref;
pub const unref = engine.unref;
pub const bytes = engine.bytes;
pub const refuse = engine.refuse;
pub const missing = engine.missing;
/// Calls a function once after a delay, on the engine's loop (a page replay's late answer).
pub const timeoutOnce = engine.timeoutOnce;
/// WPE only: the scheme is registered on a web context. WebView2's view filters its
/// requests itself (`webview2/view.zig`) and has nothing to attach.
pub const attach = if (@hasDecl(engine, "attach")) engine.attach else {};
