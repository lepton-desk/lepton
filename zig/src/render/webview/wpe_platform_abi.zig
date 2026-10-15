//! The engine ABI that WPE WebKit 2.54 introduced, declared rather than imported.
//!
//! ## Why these few calls are all of it
//!
//! Before 2.54 an embedder assembled the rendering stack itself: initialise the loader
//! with a backend library name, take a display, build a view backend, wrap that in a
//! `WebKitWebViewBackend`, and pass the wrapper to `webkit_web_view_new`. `WPELeptonDisplay`
//! exists because that assembly had to be a GObject type registered as a GIO extension
//! point before the engine would speak to it at all.
//!
//! Since 2.54 the platform integration moved inside WebKit, `libwpe` and the external
//! backends are deprecated, and `webkit_web_view_new` is gone. A view is now constructed
//! on its own and the platform view is read back out of it:
//!
//! ```c
//! WebKitWebView *view = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, nullptr));
//! WPEView       *wpe  = webkit_web_view_get_wpe_view(view);
//! ```
//!
//! No loader, no display to construct, no backend to wrap. Which platform implementation
//! backs that view is WebKit's business, chosen through `WPE_PLATFORM` or by itself.
//!
//! ## Who owns the window
//!
//! `WPEDisplayWayland` is `G_DECLARE_FINAL_TYPE` and `wpe_display_wayland_new` takes no
//! arguments, so an application cannot hand the engine its own `wl_surface` on this path.
//! The engine creates the surface and publishes it; `wpe_view_wayland_get_wl_surface` is
//! how the application reads it back. That is the single behavioural difference from the
//! legacy path and it is not a detail — it decides who owns the window.
//!
//! ## Declared, not imported
//!
//! `@cImport` cannot read GLib: `_GLIB_EXTERN` expands `_Pragma`, which translate-c
//! rejects outright. Every symbol below is transcribed from the installed header, and
//! each one is checked to be exported by `libWPEWebKit-2.0.so` before being relied on.

const std = @import("std");

/// `GType` is a pointer-sized value, and `webkit_web_view_get_type` is the exported
/// way to reach `WEBKIT_TYPE_WEB_VIEW` without transcribing its numeric value.
pub const webkit_web_view_get_type = @extern(
    *const fn () callconv(.c) usize,
    .{ .name = "webkit_web_view_get_type" },
);

/// `g_object_new(GType, ...)` is variadic and is the only way to construct a GObject
/// with a null property list from outside the type system. Declared with a single
/// trailing pointer because the terminating null is the only argument this passes, and
/// on this ABI that is the one slot a variadic call needs for it.
pub const g_object_new = @extern(
    *const fn (usize, ?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "g_object_new" },
);

/// `g_object_new(GType, "network-session", session, NULL)`: the same variadic function,
/// declared variadic so the property list reaches it as C passes one.
pub const g_object_new_with = @extern(
    *const fn (usize, ?[*:0]const u8, ...) callconv(.c) ?*anyopaque,
    .{ .name = "g_object_new" },
);

/// `WebKitNetworkSession *webkit_network_session_new(const char *data_directory,
/// const char *cache_directory)` — WebKitNetworkSession.h:45 (2.40).
pub const webkit_network_session_new = @extern(
    *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_network_session_new" },
);

/// `WPEView *webkit_web_view_get_wpe_view(WebKitWebView *)` — WebKitWebView.h:367.
pub const webkit_web_view_get_wpe_view = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_web_view_get_wpe_view" },
);

/// `WebKitWebContext *webkit_web_view_get_context(WebKitWebView *)` — WebKitWebView.h.
///
/// The context a view actually uses, which is not the process default and not always the
/// same one for two views. A custom URI scheme has to be registered on this one.
pub const webkit_web_view_get_context = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_web_view_get_context" },
);

/// `WebKitWebContext *webkit_web_context_get_default(void)` — WebKitWebContext.h:78.
pub const webkit_web_context_get_default = @extern(
    *const fn () callconv(.c) ?*anyopaque,
    .{ .name = "webkit_web_context_get_default" },
);

/// `void webkit_web_view_load_html(WebKitWebView *, const gchar *content, const gchar
/// *base_uri)` — WebKitWebView.h.
pub const webkit_web_view_load_html = @extern(
    *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void,
    .{ .name = "webkit_web_view_load_html" },
);

/// `struct wl_surface *wpe_view_wayland_get_wl_surface(WPEViewWayland *)` —
/// wayland/WPEViewWayland.h:43.
pub const wpe_view_wayland_get_wl_surface = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "wpe_view_wayland_get_wl_surface" },
);

/// What a platform view hands back, and what the legacy path could not offer.
///
/// The handle is the engine's own `wl_surface`. It is published rather than supplied:
/// `WPEDisplayWayland` cannot be subclassed and its constructor takes nothing, so there
/// is no call anywhere in this ABI that hands a surface in.
pub const Surface = struct {
    wl_surface: ?*anyopaque,

    /// Reports whether the engine gave back a surface at all.
    ///
    /// A null surface is not a failure to assert about: a platform selected that is not
    /// Wayland — headless, or DRM/KMS — has no `wl_surface` to publish, and asking for
    /// one there is a question about the wrong platform rather than a fault.
    pub fn isWayland(self: Surface) bool {
        return self.wl_surface != null;
    }
};

/// Builds the surface description for `wpe_view`.
///
/// Returns null when `wpe_view` is not a `WPEViewWayland`, which is the honest answer
/// on a non-Wayland platform and is left to the caller to interpret rather than turned
/// into an error here, because which platforms exist is the engine's decision.
pub fn surfaceOf(wpe_view: ?*anyopaque) ?Surface {
    const view = wpe_view orelse return null;
    const handle = wpe_view_wayland_get_wl_surface(view);
    if (handle == null) return null;
    return Surface{ .wl_surface = handle };
}

test "a surface reports the handle it was given" {
    const pointer: *anyopaque = @ptrFromInt(0x1000);
    const surface = Surface{ .wl_surface = pointer };
    try std.testing.expect(surface.isWayland());
    try std.testing.expectEqual(pointer, surface.wl_surface.?);
}

test "no surface is reported rather than invented" {
    const empty = Surface{ .wl_surface = null };
    try std.testing.expect(!empty.isWayland());
}

test "a null platform view yields no surface instead of a fault" {
    try std.testing.expect(surfaceOf(null) == null);
}