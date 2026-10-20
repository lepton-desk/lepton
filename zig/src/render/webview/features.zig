//! What the engine offers a page beyond drawing it, switched on and answered here:
//! developer tools, permission requests, new windows and navigation, media settings.
//!
//! Each was measured missing before it was added (a probe page reported through
//! `lepton record`, PRODUCT.md): notification/camera/location requests
//! denied without asking anyone, `window.open` answering `null`. WebKit's defaults are
//! an embedder's to change — with no handler, it refuses.
//!
//! Not switched on: the `WebGPU` feature (status `UNSTABLE` on 2.54.1). Switched on, it
//! makes `"gpu" in navigator` true while `navigator.gpu` is `null` — measured alone, with
//! `UseGPUProcessForWebGL` (the GPU process then starts) and with
//! `UseGPUProcessForDOMRendering`, on a Radeon R7 240 that has Vulkan 1.3. No WPE binary
//! links Vulkan or Dawn: this build carries WebGPU's IPC but no backend, so the card is
//! not what is missing. A page testing `"gpu" in navigator` would take a path that fails.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const e_get_settings = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_web_view_get_settings" });
const e_set_developer_extras = @extern(*const fn (?*anyopaque, c_int) callconv(.c) void, .{ .name = "webkit_settings_set_enable_developer_extras" });
const e_set_console_to_stdout = @extern(*const fn (?*anyopaque, c_int) callconv(.c) void, .{ .name = "webkit_settings_set_enable_write_console_messages_to_stdout" });
const e_toggle_inspector = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_web_view_toggle_inspector" });
const e_get_wpe_view = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_web_view_get_wpe_view" });
const e_event_type = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_event_get_event_type" });
const e_event_modifiers = @extern(*const fn (?*anyopaque) callconv(.c) u32, .{ .name = "wpe_event_get_modifiers" });
const e_event_keyval = @extern(*const fn (?*anyopaque) callconv(.c) c_uint, .{ .name = "wpe_event_keyboard_get_keyval" });
const e_signal_connect = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    .{ .name = "g_signal_connect_data" },
);

// Links and new windows (`WebKitWebView.h`, `WebKitNavigationAction.h`, 2.54).
const e_decision_action = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_navigation_policy_decision_get_navigation_action" });
const e_action_request = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_navigation_action_get_request" });
const e_action_type = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_navigation_action_get_navigation_type" });
const e_request_uri = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_uri_request_get_uri" });
const e_decision_ignore = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_policy_decision_ignore" });
const e_get_user_content_manager = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_web_view_get_user_content_manager" });
const e_web_view_type = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_web_view_get_type" });
const e_object_new = @extern(*const fn (usize, ?[*:0]const u8, ...) callconv(.c) ?*anyopaque, .{ .name = "g_object_new" });
const e_object_ref = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "g_object_ref" });
const e_object_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_object_unref" });
const e_view_width = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_view_get_width" });
const e_view_height = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_view_get_height" });
const e_view_resized = @extern(*const fn (?*anyopaque, c_int, c_int) callconv(.c) void, .{ .name = "wpe_view_resized" });
const e_view_set_visible = @extern(*const fn (?*anyopaque, c_int) callconv(.c) void, .{ .name = "wpe_view_set_visible" });
const e_view_map = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "wpe_view_map" });
const e_view_unmap = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "wpe_view_unmap" });
const e_try_close = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_web_view_try_close" });
const e_view_toplevel = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "wpe_view_get_toplevel" });
const e_toplevel_set_title = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, .{ .name = "wpe_toplevel_set_title" });
const e_web_view_title = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_web_view_get_title" });

// The response decision (`WebKitResponsePolicyDecision.h`, 2.54): the main frame's
// document can be refused before it is committed, so none of its script runs.
const e_response_request = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_response_policy_decision_get_request" });
const e_response_is_main = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_response_policy_decision_is_main_frame_main_resource" });

const decision_navigation: c_int = 0;
const decision_new_window: c_int = 1;
const decision_response: c_int = 2;
const navigation_link_clicked: c_int = 0;

// `WPEEvent.h` / `WPEKeysyms.h`, 2.54.
const event_key_down: c_int = 7;
const modifier_control: u32 = 1 << 0;
const modifier_shift: u32 = 1 << 1;
const key_f12: c_uint = 0xffc9;
const key_i_upper: c_uint = 0x0049;
const key_i_lower: c_uint = 0x0069;

/// F12, or Ctrl+Shift+I — the browsers' keys for the inspector.
pub fn isInspectorShortcut(keyval: c_uint, modifiers: u32) bool {
    if (keyval == key_f12) return true;
    const both = modifier_control | modifier_shift;
    return (modifiers & both) == both and (keyval == key_i_upper or keyval == key_i_lower);
}

/// Whether this build carries the Web Inspector: a developer's build (`lepton dev`,
/// `lepton run`), never a release (`lepton build`, `lepton package`).
pub const developer_tools = builtin.mode == std.builtin.OptimizeMode.Debug;

/// Applies the build's settings to a new view, and answers its links and new windows.
pub fn apply(web_view: *anyopaque) void {
    _ = e_signal_connect(web_view, "decide-policy", @ptrCast(&onDecide), null, null, 0);
    _ = e_signal_connect(web_view, "create", @ptrCast(&onCreate), null, null, 0);
    const settings = e_get_settings(web_view) orelse return;
    if (developer_tools) {
        e_set_developer_extras(settings, 1);
        // The page's `console.*` and uncaught errors in the terminal `lepton dev`/`run`
        // started from: without it a page that threw left a blank window and no word why.
        e_set_console_to_stdout(settings, 1);
        // WPE draws no context menu and binds no key to the inspector: both are the
        // embedder's (measured: right-click and Ctrl+Shift+I did nothing).
        if (e_get_wpe_view(web_view)) |view| _ = e_signal_connect(view, "event", @ptrCast(&onEvent), web_view, null, 0);
    }
}

/// A link to the web goes to the desktop's handler (the browser, the mail client) and the
/// page stays; the application's own pages open in it. (`window.open` does not come here:
/// WebKit asks `create` first, and the new window then loads with type "other" —
/// measured: example.org opened inside a second Lepton window. `onCreate` decides it.) A script that sets `location` to a web address is
/// left alone: an embedded frame's navigation arrives the same way, and it must load.
fn onDecide(_: ?*anyopaque, decision: ?*anyopaque, kind: c_int, _: ?*anyopaque) callconv(.c) c_int {
    if (kind == decision_response) return onResponse(decision);
    if (kind != decision_navigation and kind != decision_new_window) return 0;
    const action = e_decision_action(decision) orelse return 0;
    const uri = e_request_uri(e_action_request(action)) orelse return 0;
    if (!isExternal(std.mem.span(uri))) return 0;
    if (kind == decision_navigation and e_action_type(action) != navigation_link_clicked) return 0;
    openOutside(uri);
    e_decision_ignore(decision);
    return 1;
}

/// The window's own document leaving the application — a script setting `location`, a
/// form, a meta refresh, a redirect — is refused before it is committed, and the address
/// goes to the desktop. Before, only a clicked link left: a script's `location` loaded the
/// web inside the window and its script ran (measured: the page fetched `/ran`). Not
/// `load-changed`: at `LOAD_STARTED` the view still names the old address (measured), and
/// at `COMMITTED` the document is already in. Embedded frames' documents are not the main
/// frame's main resource and load.
fn onResponse(decision: ?*anyopaque) c_int {
    if (e_response_is_main(decision) == 0) return 0;
    const uri = e_request_uri(e_response_request(decision)) orelse return 0;
    if (isOwnPage(std.mem.span(uri))) return 0;
    e_decision_ignore(decision);
    openOutside(uri);
    return 1;
}

fn openOutside(uri: [*:0]const u8) void {
    if (!mayOpenOutside(std.mem.span(uri))) return;
    if (!@import("../../platform/linux/portal.zig").openUri(uri)) {
        std.debug.print("link         no desktop portal to open {s}\n", .{uri});
    }
}

/// `window.open` of the application's own page: a second window on the same engine
/// process and the same script (so the page reaches the core), sized like the first.
fn onCreate(parent: ?*anyopaque, action: ?*anyopaque, _: ?*anyopaque) callconv(.c) ?*anyopaque {
    // A web address leaves the application here, before any window exists.
    if (e_request_uri(e_action_request(action))) |uri| {
        if (!isOwnPage(std.mem.span(uri))) {
            openOutside(uri);
            return null;
        }
    }
    const content = e_get_user_content_manager(parent);
    const created = e_object_new(e_web_view_type(), "related-view", parent, "user-content-manager", content, @as(?*anyopaque, null)) orelse return null;
    apply(created);
    @import("permissions.zig").watchView(created);
    // WebKit takes the reference returned here; this one keeps the window until it closes.
    _ = e_object_ref(created);
    _ = e_signal_connect(created, "ready-to-show", @ptrCast(&onReadyToShow), parent, null, 0);
    _ = e_signal_connect(created, "close", @ptrCast(&onPopupClose), null, null, 0);
    _ = e_signal_connect(created, "notify::title", @ptrCast(&onPopupTitle), null, null, 0);
    // The window's own close button: asks the page (`beforeunload`), which then closes it.
    if (e_get_wpe_view(created)) |view| _ = e_signal_connect(view, "closed", @ptrCast(&onPopupClosed), created, null, 0);
    return created;
}

fn onReadyToShow(created: ?*anyopaque, parent: ?*anyopaque) callconv(.c) void {
    const view = e_get_wpe_view(created) orelse return;
    const parent_view = e_get_wpe_view(parent);
    const width = if (parent_view) |p| e_view_width(p) else 800;
    const height = if (parent_view) |p| e_view_height(p) else 600;
    e_view_resized(view, if (width > 0) width else 800, if (height > 0) height else 600);
    e_view_set_visible(view, 1);
    e_view_map(view);
}

fn onPopupClosed(_: ?*anyopaque, created: ?*anyopaque) callconv(.c) void {
    e_try_close(created);
}

/// The page closed (or agreed to close): the window goes, and the reference taken in
/// `onCreate` with it.
fn onPopupClose(created: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (e_get_wpe_view(created)) |view| {
        e_view_set_visible(view, 0);
        e_view_unmap(view);
    }
    e_object_unref(created);
}

fn onPopupTitle(created: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const view = e_get_wpe_view(created) orelse return;
    const toplevel = e_view_toplevel(view) orelse return;
    e_toplevel_set_title(toplevel, e_web_view_title(created) orelse "");
}

fn onEvent(_: ?*anyopaque, event: ?*anyopaque, web_view: ?*anyopaque) callconv(.c) c_int {
    if (e_event_type(event) != event_key_down) return 0;
    if (!isInspectorShortcut(e_event_keyval(event), e_event_modifiers(event))) return 0;
    e_toggle_inspector(web_view);
    return 1;
}

test "the inspector opens on F12 and Ctrl+Shift+I only" {
    try std.testing.expect(isInspectorShortcut(key_f12, 0));
    try std.testing.expect(isInspectorShortcut(key_i_upper, modifier_control | modifier_shift));
    try std.testing.expect(isInspectorShortcut(key_i_lower, modifier_control | modifier_shift));
    try std.testing.expect(!isInspectorShortcut(key_i_lower, modifier_control));
    try std.testing.expect(!isInspectorShortcut(key_i_lower, 0));
}

/// WebKit is linked: the webview builds.
const available = build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render;

test "the engine callbacks are compiled" {
    // Referenced so the webview test build analyses them; a native build links no WebKit.
    if (comptime !available) return error.SkipZigTest;
    _ = &apply;
    _ = &onEvent;
    _ = &onDecide;
    _ = &onCreate;
}

test "the inspector is a debug build's only" {
    try std.testing.expectEqual(builtin.mode == std.builtin.OptimizeMode.Debug, developer_tools);
}

/// Whether `uri` belongs outside the application: a web address that is not this
/// machine's (the dev server is `127.0.0.1`), or a scheme the engine does not show
/// (`mailto:`, `tel:`, …). The application's own pages (`lepton:`), `about:`, `data:`,
/// `blob:`, `file:` and `javascript:` stay.
pub fn isExternal(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    var scheme_buffer: [16]u8 = undefined;
    if (colon > scheme_buffer.len) return true;
    const scheme = std.ascii.lowerString(&scheme_buffer, uri[0..colon]);
    const inside = [_][]const u8{ "lepton", "about", "data", "blob", "file", "javascript" };
    for (inside) |kept| {
        if (std.mem.eql(u8, scheme, kept)) return false;
    }
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return true;
    const rest = uri[colon + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return true;
    const authority_end = std.mem.indexOfAny(u8, rest[2..], "/?#") orelse rest.len - 2;
    const authority = rest[2..][0..authority_end];
    const after_user = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    const host = if (std.mem.startsWith(u8, after_user, "["))
        after_user[0 .. (std.mem.indexOfScalar(u8, after_user, ']') orelse after_user.len - 1) + 1]
    else
        after_user[0 .. std.mem.indexOfScalar(u8, after_user, ':') orelse after_user.len];
    const local = [_][]const u8{ "localhost", "127.0.0.1", "[::1]" };
    for (local) |name| {
        if (std.ascii.eqlIgnoreCase(host, name)) return false;
    }
    // `*.localhost` is this machine too (RFC 6761) — `lepton.localhost`, the page's own
    // host on Windows, among them.
    if (host.len > ".localhost".len and std.ascii.endsWithIgnoreCase(host, ".localhost")) return false;
    return true;
}

/// The dev server's origin while the page is served from it (`Bridge.allowOriginOf`), or
/// empty: the one origin besides the core's that is the application's own page.
var page_origin_buffer: [256]u8 = undefined;
var page_origin_len: usize = 0;

pub fn setPageOrigin(origin: []const u8) void {
    page_origin_len = @min(origin.len, page_origin_buffer.len);
    @memcpy(page_origin_buffer[0..page_origin_len], origin[0..page_origin_len]);
}

/// Whether `uri` begins with `origin` and nothing but a path, query or fragment follows:
/// `http://127.0.0.1:5173` is not `http://127.0.0.1:51730`.
fn underOrigin(uri: []const u8, origin: []const u8) bool {
    if (origin.len == 0 or !std.ascii.startsWithIgnoreCase(uri, origin)) return false;
    return uri.len == origin.len or std.mem.indexOfScalar(u8, "/?#", uri[origin.len]) != null;
}

/// Whether a window may show `uri` as its document: the core's own origin, the dev
/// server's while it serves the page, or `about:blank`/`about:srcdoc`. Any other address —
/// another port on this machine included — is not the application's.
pub fn isOwnPage(uri: []const u8) bool {
    if (underOrigin(uri, @import("transport.zig").core_origin)) return true;
    if (underOrigin(uri, page_origin_buffer[0..page_origin_len])) return true;
    return std.mem.eql(u8, uri, "about:blank") or std.mem.eql(u8, uri, "about:srcdoc");
}

test "a window keeps only the application's own pages" {
    setPageOrigin("");
    try std.testing.expect(isOwnPage("lepton://localhost/"));
    try std.testing.expect(isOwnPage("lepton://localhost/settings.html?x=1"));
    try std.testing.expect(!isOwnPage("lepton://localhost.evil/"));
    try std.testing.expect(!isOwnPage("http://127.0.0.1:5173/"));
    try std.testing.expect(!isOwnPage("https://example.org/"));
    try std.testing.expect(!isOwnPage("file:///etc/passwd"));
    try std.testing.expect(isOwnPage("about:blank"));
    setPageOrigin("http://127.0.0.1:5173");
    defer setPageOrigin("");
    try std.testing.expect(isOwnPage("http://127.0.0.1:5173/"));
    try std.testing.expect(isOwnPage("http://127.0.0.1:5173"));
    try std.testing.expect(!isOwnPage("http://127.0.0.1:51730/"));
    try std.testing.expect(!isOwnPage("http://127.0.0.1:8765/"));
}

/// What may be handed to the desktop: web addresses and mail, nothing else. Every other
/// scheme reaches a handler the user never chose for this page (Windows: `search-ms:`,
/// `ms-msdt:` and the like, the `openExternal` pattern behind Electron RCEs; the OpenURI
/// portal hands unknown schemes to their handlers too), so it stays unopened (audit,
/// 2026-10-20).
pub fn mayOpenOutside(uri: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, uri, ':') orelse return false;
    const scheme = uri[0..colon];
    for ([_][]const u8{ "http", "https", "mailto" }) |allowed| {
        if (std.ascii.eqlIgnoreCase(scheme, allowed)) return true;
    }
    return false;
}

test "only web addresses and mail go to the desktop" {
    try std.testing.expect(mayOpenOutside("https://github.com/lepton-desk/lepton"));
    try std.testing.expect(mayOpenOutside("HTTP://example.org"));
    try std.testing.expect(mayOpenOutside("mailto:someone@example.org"));
    try std.testing.expect(!mayOpenOutside("search-ms:query=x&crumb=location:\\\\evil\\share"));
    try std.testing.expect(!mayOpenOutside("ms-msdt:/id PCWDiagnostic"));
    try std.testing.expect(!mayOpenOutside("file:///etc/passwd"));
    try std.testing.expect(!mayOpenOutside("tel:+905550000000"));
    try std.testing.expect(!mayOpenOutside("no scheme"));
}

test "web addresses leave the application, its own pages stay" {
    try std.testing.expect(isExternal("https://github.com/lepton-desk/lepton"));
    try std.testing.expect(isExternal("HTTP://example.org"));
    try std.testing.expect(isExternal("mailto:someone@example.org"));
    try std.testing.expect(isExternal("tel:+905550000000"));
    try std.testing.expect(isExternal("https://user@evil.example:8080/x"));
    // A host that merely starts like a local one is not local.
    try std.testing.expect(isExternal("http://localhost.evil.example/"));
    try std.testing.expect(!isExternal("lepton://localhost/settings.html"));
    try std.testing.expect(!isExternal("http://127.0.0.1:5173/"));
    try std.testing.expect(!isExternal("http://localhost:5173/page?x=1"));
    try std.testing.expect(!isExternal("http://[::1]:5173/"));
    try std.testing.expect(!isExternal("about:blank"));
    try std.testing.expect(!isExternal("blob:lepton://localhost/1234"));
    try std.testing.expect(!isExternal("data:text/html,hi"));
}
