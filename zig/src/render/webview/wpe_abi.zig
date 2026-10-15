//! The WPE ABI this framework calls, declared by hand.
//!
//! ## Why this file exists instead of an `@cImport`
//!
//! Zig 0.16.0's C translator cannot process GLib, and every WebKit header is built on
//! GLib. Two independent defects, both measured rather than assumed:
//!
//! 1. **`_Pragma`.** `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` (`glib/gmacros.h:753-778`)
//!    expands to `_Pragma` in every branch but the last. The translator reports
//!    `unknown type name 'pragma'` at `glib/gutils.h:327`. The branch that avoids it is
//!    chosen by `G_GNUC_CHECK_VERSION`, which `gmacros.h:48` defines itself, so no `-D`
//!    can redirect it.
//!
//! 2. **Dangling `else` in a translated macro.** `g_string_free`
//!    (`glib/gstring.h:73-79`) is a function-like macro over nested ternaries, which the
//!    translator lowers to `if (a) if (b) x else y else z;` — not valid Zig, because an
//!    `if` whose body is another `if/else` needs braces. Translating GLib through it
//!    produces 58.210 lines of Zig containing this, and compiling that output dies with
//!    a segmentation fault rather than a diagnostic.
//!
//! Defect 2 is the one that decides the approach, because no amount of preprocessing
//! removes it: rewriting GLib's headers to strip `_Pragma` gets past defect 1 and
//! straight into defect 2. That path was built, measured and removed — it cost a
//! fragile copy of a system header tree on every build and solved nothing.
//!
//! ## What replaces it
//!
//! `@extern`, which binds a symbol by name and reads no header at all. Every
//! declaration below is transcribed from an installed header and carries its source.
//! None of it is inferred from a translation's guess: an earlier attempt did exactly
//! that and produced four wrong signatures, including a two-argument call to a
//! five-argument function.
//!
//! The cost, stated plainly: a signature that drifts from the installed headers will
//! not be caught at compile time. Only running against the real engine catches it,
//! which is what `zig build webview-check` is for.

// ── GLib ─────────────────────────────────────────────────────────────────────────

/// `gpointer` is `void *` and `gboolean` is `gint`, which is `int` on every ABI this
/// framework targets. Spelled out rather than aliased to `c_int` so a reader can check
/// them against `glib/gtypes.h` without leaving this file.
pub const Gpointer = ?*anyopaque;
pub const Gboolean = c_int;

/// `void g_object_unref(gpointer object)` — glib/gobject/gobject.h:515
pub const g_object_unref = @extern(*const fn (Gpointer) callconv(.c) void, .{
    .name = "g_object_unref",
});

/// `struct _GMainContext` — glib/gmain.h
pub const GMainContext = opaque {};

/// `GMainContext *g_main_context_default(void)` — glib/gmain.h:500
///
/// Borrowed, never owned: the context belongs to GLib for the life of the process, and
/// this framework only ever iterates it.
pub const g_main_context_default = @extern(
    *const fn () callconv(.c) ?*GMainContext,
    .{ .name = "g_main_context_default" },
);

/// `gboolean g_main_context_iteration(GMainContext *context, gboolean may_block)`
/// — glib/gmain.h:503
///
/// Not optional to this path, and not a convenience. WPE hangs its Wayland connection
/// and its channel to the network process off the default context, and nothing
/// dispatches them unless something iterates it. Measured: with the loop running, the
/// view maps on turn 38 and the load settles; without it, the view never maps and the
/// page stays in `WEBKIT_LOADING` until the wait expires — states that look exactly
/// like a broken engine and are not one.
pub const g_main_context_iteration = @extern(
    *const fn (?*GMainContext, Gboolean) callconv(.c) Gboolean,
    .{ .name = "g_main_context_iteration" },
);

// ── Opaque WPE and WebKit objects ───────────────────────────────────────────────
// Each is a `G_DECLARE_FINAL_TYPE` or an incomplete struct: the headers never define
// them, so there is no layout to get wrong and `opaque` is the honest declaration.

/// `struct _WPEDisplay` — wpe-platform/wpe/WPEDisplay.h:45
pub const WPEDisplay = opaque {};
/// `struct _WPEView` — wpe-platform/wpe/WPEView.h:51
pub const WPEView = opaque {};
/// `struct _WebKitWebView` — wpe/WebKitWebView.h
pub const WebKitWebView = opaque {};

// ── libwpe: choosing the platform backend ───────────────────────────────────────

/// `bool wpe_loader_init(const char *impl_library_name)` — wpe/loader.h:78
///
/// How the platform backend gets chosen, and why this framework chooses it rather than
/// letting the default happen. `wpe_display_get_default` initialises the loader with
/// the name `default` when nothing has initialised it, `dlopen` fails, and libwpe
/// aborts the process with a loader fatal error — on a correctly installed system,
/// because the shipped backend is named after the backend it implements
/// (`libWPEBackend-fdo-1.0.so`) and no distribution ships a `default` one.
///
/// The argument is a **library file name**, not a backend name: the loader passes it
/// straight to `dlopen`, so `fdo` fails with `cannot open shared object file` while
/// `libWPEBackend-fdo-1.0.so` loads. Both were run to establish this. The name itself is
/// read from `wpebackend-fdo-1.0.pc` at build time, because the ABI version in it is
/// not the release version — libwpe 1.16.3 and its fdo backend 1.16.1 both ship
/// `1.0` — and a hardcoded one would be wrong in exactly the way a missing backend is
/// wrong, which is to say invisibly.
pub const wpe_loader_init = @extern(
    *const fn ([*:0]const u8) callconv(.c) bool,
    .{ .name = "wpe_loader_init" },
);

/// `const char *wpe_loader_get_loaded_implementation_library_name(void)` — wpe/loader.h:92
///
/// Which implementation actually loaded. Read rather than assumed: the header is
/// explicit that the result is not guaranteed to equal what was requested, so the only
/// trustworthy answer to "which backend is running" comes from the loader itself.
pub const wpe_loader_get_loaded_implementation_library_name = @extern(
    *const fn () callconv(.c) ?[*:0]const u8,
    .{ .name = "wpe_loader_get_loaded_implementation_library_name" },
);

// ── WPEPlatform: the display and the view ───────────────────────────────────────

/// `WPEDisplay *wpe_display_get_default(void)` — WPEDisplay.h:102
///
/// Returns null when no platform backend could be started. The header does not mark it
/// `_Nullable`, so that nullability is this declaration's claim rather than the
/// header's — and it is checked anyway because a null here is the ordinary outcome on a
/// machine with no usable backend, not an exceptional one.
pub const wpe_display_get_default = @extern(
    *const fn () callconv(.c) ?*WPEDisplay,
    .{ .name = "wpe_display_get_default" },
);

/// `void wpe_view_map(WPEView *)` — WPEView.h:113
pub const wpe_view_map = @extern(
    *const fn (*WPEView) callconv(.c) void,
    .{ .name = "wpe_view_map" },
);

/// `gboolean wpe_view_get_mapped(WPEView *)` — WPEView.h:112
pub const wpe_view_get_mapped = @extern(
    *const fn (*WPEView) callconv(.c) Gboolean,
    .{ .name = "wpe_view_get_mapped" },
);

/// `void wpe_view_set_visible(WPEView *, gboolean)` — WPEView.h:110
pub const wpe_view_set_visible = @extern(
    *const fn (*WPEView, Gboolean) callconv(.c) void,
    .{ .name = "wpe_view_set_visible" },
);

/// `void wpe_view_resized(WPEView *, int width, int height)` — WPEView.h:105
pub const wpe_view_resized = @extern(
    *const fn (*WPEView, c_int, c_int) callconv(.c) void,
    .{ .name = "wpe_view_resized" },
);

// ── WebKit: the view and the page ───────────────────────────────────────────────

/// `WebKitWebView *webkit_web_view_new(WebKitWebViewBackend *backend)` — WebKitWebView.h:365
///
/// The backend argument is passed as null, and that is not a shortcut — it is the only
/// path that works. A view backend is something the *platform* creates for its own use;
/// an embedder does not assemble one and hand it over. The functions that appear to do
/// that (`wpe_view_backend_create` at view-backend.h:85, then
/// `webkit_web_view_backend_new` at WebKitWebViewBackend.h:40) form a dead end: the
/// first returns null on a correctly installed fdo backend, and the second would wrap a
/// backend the engine never chose. Null attaches the view to the backend the display
/// has already brought up.
pub const webkit_web_view_new = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*WebKitWebView,
    .{ .name = "webkit_web_view_new" },
);

/// `WPEDisplay *wpe_display_headless_new(void)` — wpe/headless/WPEDisplayHeadless.h:38
///
/// The cheapest display this framework can construct itself, and the reference for
/// what "a display I own" looks like from the outside. Off-screen, so it needs neither a
/// compositor nor a DRM device. It still exposes no way to read its output, which is
/// why it is a probe and not a renderer.
pub const wpe_display_headless_new = @extern(
    *const fn () callconv(.c) ?*anyopaque,
    .{ .name = "wpe_display_headless_new" },
);

/// `void wpe_display_set_primary(WPEDisplay *)` — WPEDisplay.h:104
///
/// Looks like the hook that would let this framework hand WebKit its own display. It is
/// not: measured, a display set as primary is *not* what `wpe_display_get_default`
/// then returns. `primary` and `default` are separate, and the engine reads `default`.
pub const wpe_display_set_primary = @extern(
    *const fn (Gpointer) callconv(.c) void,
    .{ .name = "wpe_display_set_primary" },
);

/// `WPEDisplay *wpe_display_get_primary(void)` — WPEDisplay.h:103
pub const wpe_display_get_primary = @extern(
    *const fn () callconv(.c) Gpointer,
    .{ .name = "wpe_display_get_primary" },
);

/// `const char *g_type_name_from_instance(gpointer)` — gobject/gtype.h
///
/// The GObject type name of a live instance. `g_type_from_instance` is a macro, not an
/// exported symbol, which is why this exists: it is the only way to learn *which*
/// implementation `wpe_display_get_default` built, and knowing that is the difference
/// between "the engine picked something" and "the engine picked Wayland and we have no
/// say".
pub const g_type_name_from_instance = @extern(
    *const fn (Gpointer) callconv(.c) ?[*:0]const u8,
    .{ .name = "g_type_name_from_instance" },
);

/// `struct wpe_view_backend *wpe_view_backend_create(void)` — view-backend.h:85
///
/// Declared for the integration test that pins down why `webkit_web_view_new` is given
/// null, not because anything in the core calls it. Returns null on a correctly
/// installed fdo backend, which is the first half of that dead end.
pub const wpe_view_backend_create = @extern(
    *const fn () callconv(.c) Gpointer,
    .{ .name = "wpe_view_backend_create" },
);

/// `WebKitWebViewBackend *webkit_web_view_backend_new(struct wpe_view_backend *,
/// GDestroyNotify, gpointer)` — WebKitWebViewBackend.h:40-42
///
/// The second half of the same dead end, and the source of the trap documented on
/// `webkit_web_view_backend_new`'s result: it returns a `WebKitWebViewBackend *`, which
/// is a different struct from `struct wpe_view_backend *`.
pub const webkit_web_view_backend_new = @extern(
    *const fn (Gpointer, Gpointer, Gpointer) callconv(.c) Gpointer,
    .{ .name = "webkit_web_view_backend_new" },
);

/// `WPEView *wpe_view_new(WPEDisplay *)` — WPEView.h:97
///
/// Public, and the reason a platform display can answer `create_view` at all. The view
/// itself belongs to the engine; a platform supplies the display, the toplevel and the
/// buffer negotiation around it.
pub const wpe_view_new = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "wpe_view_new" },
);

/// `WPEView *webkit_web_view_get_wpe_view(WebKitWebView *)` — WebKitWebView.h:375
///
/// The view inside the `WebKitWebView`. Everything on the WPEPlatform side is
/// addressed to this, everything on the WebKit side to its container.
pub const webkit_web_view_get_wpe_view = @extern(
    *const fn (*WebKitWebView) callconv(.c) ?*WPEView,
    .{ .name = "webkit_web_view_get_wpe_view" },
);

/// `WPEDisplay *webkit_web_view_get_display(WebKitWebView *)` — WebKitWebView.h:377-378
///
/// Measured, not decoration: a view built while no display exists answers `0x0` here,
/// and a `WPEView` is built from the display. Reading this is how the "no display, no
/// view" case tells itself apart from a load that simply has not started.
pub const webkit_web_view_get_display = @extern(
    *const fn (*WebKitWebView) callconv(.c) Gpointer,
    .{ .name = "webkit_web_view_get_display" },
);

/// `void webkit_web_view_load_uri(WebKitWebView *, const gchar *uri)` — WebKitWebView.h:397-398
///
/// Two arguments: there is no cancellable in this signature. A load that goes wrong is
/// visible through `isLoading` going false with no progress behind it, which is what
/// the check tool watches for.
pub const webkit_web_view_load_uri = @extern(
    *const fn (*WebKitWebView, [*c]const u8) callconv(.c) void,
    .{ .name = "webkit_web_view_load_uri" },
);

/// `gboolean webkit_web_view_is_loading(WebKitWebView *)` — WebKitWebView.h:428
pub const webkit_web_view_is_loading = @extern(
    *const fn (*WebKitWebView) callconv(.c) Gboolean,
    .{ .name = "webkit_web_view_is_loading" },
);

/// `const gchar *webkit_web_view_get_uri(WebKitWebView *)` — WebKitWebView.h:474
///
/// The URI the engine settled on, after redirects. A `data:` URL round-trips through
/// this, which makes it usable evidence that a load was real rather than requested.
pub const webkit_web_view_get_uri = @extern(
    *const fn (*WebKitWebView) callconv(.c) ?[*:0]const u8,
    .{ .name = "webkit_web_view_get_uri" },
);

// ── Paths this framework proved closed ──────────────────────────────────────────

// Recorded here because each was tried and each failed, and re-deriving that costs a
// build cycle. Full consequences in `PRODUCT.md`.
//
// `struct wpe_view_backend_interface` (view-backend.h:63-75) is the entire surface an
// embedder implements: `create`, `destroy`, `initialize`, `get_renderer_host_fd`. There
// is no render target in it, so no buffer can be handed to the engine. The engine
// composites inside the platform backend it loaded.
//
// The backend-client notifications are closed for the same reason, one step further
// out. `struct wpe_view_backend_client` (view-backend.h:195-202) carries `set_size`,
// `frame_displayed`, `activity_state_changed`, `get_accessible`,
// `set_device_scale_factor` and `target_refresh_rate_changed`; installing it needs
// `wpe_view_backend_set_backend_client` (view-backend.h:97), which needs a
// `struct wpe_view_backend *`. That pointer is the platform's. So `frame_displayed`
// cannot be reached either — not only are there no pixels, there is not even a
// notification that pixels happened.
//
// The way out is to implement the interface: `wpe_view_backend_create_with_backend_interface`
// (view-backend.h:89) with a `create` that brings up EGL on the descriptor from
// `wpe_view_backend_get_renderer_host_fd` (view-backend.h:187) and composites into the
// frame the window layer already owns. That is a component in its own right — it is
// what `wpebackend-fdo` is — and it is the only route to Zero-Copy that WPE offers.
//
// **Measured:** libwpe accepts such an interface. A four-member table whose `create`
// returns null still yields a live `struct wpe_view_backend*`, and
// `wpe_view_backend_get_renderer_host_fd` on it answers `-1` — no renderer, because
// none was brought up. So the entry point works and the entry point is not the hard
// part; what remains is EGL on the host descriptor, compositing, and reading the
// result back out. Nothing above that has been written.
//
// The struct's layout, for whoever writes it. `view-backend.h:63-75`, seven members
// in order, the last three reserved:
//
//     const Interface = extern struct {
//         create: ?*const fn (?*anyopaque, *WPEViewBackend) callconv(.c) ?*anyopaque,
//         destroy: ?*const fn (?*anyopaque) callconv(.c) void,
//         initialize: ?*const fn (?*anyopaque) callconv(.c) void,
//         get_renderer_host_fd: ?*const fn (?*anyopaque) callconv(.c) c_int,
//         _reserved0: ?*const fn (?*anyopaque) callconv(.c) void,
//         _reserved1: ?*const fn (?*anyopaque) callconv(.c) void,
//         _reserved2: ?*const fn (?*anyopaque) callconv(.c) void,
//     };
//
// Written as a comment rather than declared, because this file declares only what it
// calls. A second unused copy of the layout is a second thing to keep right, and
// nothing in the core needs it yet.

// ── The door that was missed: an offscreen target is host-side ──────────────────
//
// The notes above describe the route as "write a platform backend". Reading the
// renderer headers shows a second door, and it is the better one. Three interfaces,
// all implemented by the *embedder*, all in `wpe-1.0/wpe`:
//
//   `wpe_renderer_host_interface`            renderer-host.h:49-56
//       create(), destroy(), create_client() -> int, and three reserved slots.
//       `create_client` returning an `int` is an fd: this is where the renderer
//       process is reached, and it is the value a backend's `get_renderer_host_fd`
//       would hand over.
//
//   `wpe_renderer_backend_egl_offscreen_target_interface`
//       renderer-backend-egl.h:117-126
//       create(), destroy(), initialize(target, renderer), get_native_window(),
//       and four reserved slots. **No window handle and no fd** — that is what
//       "offscreen" means here, and it is the part that matters.
//
//   `wpe_renderer_backend_egl_target_client`  renderer-backend-egl.h:203-208
//       frame_complete(), and three reserved slots. How the embedder is told a frame
//       landed, with no pixels in the message.
//
// So the engine renders into a surface this framework owns and is called back when a
// frame completes. That is the Zero-Copy path this project exists for, and it does not
// require a compositor, a Wayland surface, or a second window.
//
// **What is measured:** that libwpe accepts a `wpe_view_backend_interface` table from
// this framework and answers `-1` for `get_renderer_host_fd` on a backend with no
// renderer.
//
// **What is only read:** every signature above. Which of the two interfaces the host
// is expected to install, and in what order the renderer calls `initialize` and
// `get_native_window`, is not established — the headers document the shapes and not the
// sequence. Guessing at that order is what produced four wrong signatures earlier in
// this file's history, so it is left as the next thing to establish from WPE's own
// backend sources rather than inferred here.

// ── Measured: the exportable path reaches a real WebView ────────────────────────
//
// `wpebackend-fdo` ships its own embedder door (`/usr/include/wpe-fdo-1.0/wpe/`), and it
// is a smaller and better-shaped one than writing a backend from scratch:
//
//   `wpe_view_backend_exportable_fdo_create(client, data, width, height)`
//   `wpe_view_backend_exportable_fdo_get_view_backend(exportable)`
//   `wpe_view_backend_exportable_fdo_dispatch_frame_complete(exportable)`
//
// `view-backend-exportable.h:56-59` gives the three callbacks an embedder installs:
// `export_buffer_resource`, `export_dmabuf_resource` and `export_shm_buffer`. The last
// one is the one this framework wants — `wpe_fdo_shm_exported_buffer_get_shm_buffer`
// (`exported-buffer-shm.h:44`) hands back a `wl_shm_buffer`, which is ordinary shared
// memory that can be mapped and read. `exported-image-egl.h` is the EGL equivalent for
// hardware paths.
//
// **Run, in order:**
//
//     wpe_loader_init("libWPEBackend-fdo-1.0.so")            -> true
//     wpe_view_backend_exportable_fdo_create(...)            -> exportable
//     wpe_view_backend_exportable_fdo_get_view_backend(...)  -> struct wpe_view_backend *
//     webkit_web_view_backend_new(backend, null, null)       -> WebKitWebViewBackend *
//     webkit_web_view_new(wrapper)                           -> WebKitWebView *
//
// **One trap, measured.** Passing the bare `struct wpe_view_backend *` straight to
// `webkit_web_view_new` segfaults inside libwpe. `WebKitWebViewBackend` is a *different*
// struct (`view-backend.h:64`), so the pointer must be wrapped first. Same class of
// mistake as the four wrong signatures above, and the same reason to read the header.
//
// **Where it stops, and why the door is shut.** Not a hang and not a crash: with the
// view constructed, `webkit_web_view_get_wpe_view` returns **null**, the `if` binding it
// sits in is skipped, and `main` returns cleanly. Printing the pointer settled it —
// `wpe_view_get *exportable.WpeView@0`.
//
// The cause is one rule, and the rule is WebKit's own assertion:
//
//     webkit_web_view_new(WebKitWebViewBackend *):
//     assertion '!backend || !WKWPE::isUsingWPEPlatformAPI()' failed
//
// Read it as a prohibition: while the WPE Platform API is in use, the `backend`
// argument must be null. Both failures above are the same rule seen from two sides.
// With a backend supplied and no display yet created, the platform API is not yet in
// use, so the view is built — and `webkit_web_view_get_display` answers `0x0`, so no
// `WPEView` is ever created from it. Calling `wpe_display_get_default()` first puts the
// platform API in use, and then the same call asserts and returns null. There is no
// ordering that gets both a display and an injected backend.
//
// So this door is shut on this build, not merely unwritten. Recorded because it looked
// like the cheap way in, and closing it by measurement is cheaper than a rewrite.

// ── Where the pixels actually come from: the platform layer ────────────────────
//
// Four doors tried, four closed by measurement:
//
// | Door | Result |
// |---|---|
// | `wpe_view_backend_interface` | libwpe accepts the table, but owning one obliges owning the display |
// | `wpebackend-fdo` exportable | shut by the assertion above |
// | `wpe_display_headless_new` | WPEDisplayHeadless.h declares only `new`; no read-back |
// | `wpe_view_render_buffer`, `frame_displayed` | the embedder submits buffers; none are returned |
//
// The reason all four fail is one fact about the ownership of buffers, and it is
// visible in the class tables. `WPEView` has `buffers_changed` and `render_buffer`
// (WPEView.h), but those are the *platform's* implementations of the view — the engine
// calls them. No callback anywhere delivers a buffer to an embedder. Pixels leave only
// to whoever owns the display, which means:
//
//   WPEDisplay   12 members   connect, create_view, get_egl_display, get_keymap,
//                             get_clipboard, get_preferred_buffer_formats, get_n_screens,
//                             get_screen, get_drm_device, use_explicit_sync,
//                             create_input_method_context, create_toplevel,
//                             create_gamepad_manager
//   WPEToplevel   6 members   set_title, get_screen, resize, set_fullscreen,
//                             set_maximized, set_minimized, get_preferred_buffer_formats
//   WPEView       8 members   buffers_changed, render_buffer, lock_pointer,
//                             unlock_pointer, set_cursor_from_name,
//                             set_cursor_from_bytes, set_opaque_rectangles,
//                             can_be_mapped, get_accessible
//
// **26 virtual members across three GObject classes**, then EGL, then the buffer
// handshake itself. So the component to build is `wpe-platform-lepton`, not
// `wpebackend-lepton` — a name I had wrong for the better part of this search, and the
// kind of wrong that costs days if it survives into a plan.
//
// Two API facts make the shape of that work concrete, both read from headers:
//
// - `WPEBuffer` has `wpe_buffer_import_to_pixels (...) -> GBytes *` (WPEBuffer.h:78).
//   That is a public read-back, and it is the *only* one in the tree. Whoever owns the
//   display can turn a rendered buffer into pixels without a compositor.
// - `WPEBufferFormatsBuilder` (WPEBufferFormats.h) is how a display states what it can
//   hand over, grouped by usage — `RENDERING`, `MAPPING`, `SCANOUT`. `MAPPING` is the
//   group that means "read me", which is the one a shared-memory platform answers.
//
// Nothing above has been written. What is established is the size and shape of the
// component, and that it is reachable.

// ── The measurement that settles it ───────────────────────────────────────────
//
// The remaining question after all four doors closed was whether the display this
// framework owns can be handed to WebKit. Upstream's architecture page answers the
// shape of the question — "an integrator can provide a custom WPEPlatform
// implementation by subclassing `WPEDisplay`" — but not the hook, and on this build the
// hook is what is missing. So it was measured, by pointer comparison rather than by
// reading names:
//
//   wpe_display_headless_new()            -> a display this process owns
//   wpe_display_set_primary(owned)        -> primary = owned
//   wpe_display_get_primary()             -> owned          (as expected)
//   wpe_display_get_default()             -> WPEDisplayWayland   (not owned)
//   webkit_web_view_new(NULL)             -> a real view
//   webkit_web_view_get_display(view)     -> the same WPEDisplayWayland
//
//     owned == the view's display    false
//     primary == the view's display  false
//     default == the view's display  true
//
// So the engine reads `default`, and `primary` is a different thing. There is no
// `wpe_display_set_default` in WPEDisplay.h, and the platform implementations are
// compiled into libWPEWebKit rather than loaded from a path — the three exported
// constructors are `wpe_display_wayland_new`, `wpe_display_drm_new` and
// `wpe_display_headless_new`, and `WPE_PLATFORM` chooses among exactly those three.
//
// `caps.zig` re-runs exactly this measurement at run time, because the answer is a
// property of the installed WebKit and not of this framework: a different version may
// answer differently, and hardcoding an answer is how a framework ends up wrong on
// somebody else's machine.
//
// ── Which was wrong, and what the hook actually is ──────────────────────────────
//
// The measurement above is correct and the conclusion drawn from it here was not. There
// is no need for a change inside WebKit, and `LD_PRELOAD` was never on the table — the
// hook exists and is public. What was missed is that `wpe_display_get_default` does not
// construct a display at all; it asks a GIO extension point for one:
//
//     auto* extensionPoint = g_io_extension_point_lookup(WPE_DISPLAY_EXTENSION_POINT_NAME);
//     for (auto* i = g_io_extension_point_get_extensions(extensionPoint); i; i = g_list_next(i))
//         if (wpe_display_connect(g_object_new(g_io_extension_get_type(extension), nullptr), nullptr))
//             s_defaultDisplay = display;   /* and return */
//
// `wpeEnsureExtensionPointsLoaded()` fills that point by `dlopen`-ing every module under
// `WPE_PLATFORMS_PATH` (colon-separated) plus `WPE_PLATFORM_MODULE_DIR`, and
// `WPE_PLATFORM=<name>` — or `WPE_DISPLAY=wpe-display-<name>` — selects one by extension
// name. The point is named by `WPE_DISPLAY_EXTENSION_POINT_NAME`, which is the string
// "wpe-platform-display" and has been in the public header all along at WPEDisplay.h:48.
//
// So a display is supplied by registering a GType against that point. The three built-in
// implementations are registered statically, which is why the extension point was
// invisible from the symbol table: `wpe_display_wayland_new` and friends exist as
// constructors, and nothing in the exported API hinted that a fourth could arrive by
// module.
//
// `platform/lepton_display.zig` does that, and the measurement is now:
//
//     zig build platform-check
//     module       loaded and held
//     platform     lepton
//     default      WPELeptonDisplay
//
// The WebKit version is 2.52.6 and needs no modification.

// ── Measured: the engine renders a page on Lepton's display ────────────────────
//
// With the display module loaded and `WPE_PLATFORM=lepton`, a full page load runs on a
// display this framework owns:
//
//     display      WPELeptonDisplay
//     requested    900x640
//     mapped       yes, after 23 turns
//     loading      settled
//     uri          data:text/html,<title>lepton</title>...
//     platform     views 1, buffers_changed 1, render_buffer 0, mapped-asked 1
//                 buffers_allocated 0, frames_read_back 0
//
// `buffers_changed 1` is the line that matters. It is the engine handing this framework
// the buffer formats it can render into — the negotiation that used to be unreachable
// behind a display chosen by the engine — and it arrives on a view this framework created.
//
// Three things had to be got right, and each was measured rather than reasoned about:
//
// 1. **`create_view` must build a `WPEView` subclass.** `wpe_view_new(display)` looks like
//    the obvious call and is the *public* entry that asks the display for a view, so
//    calling it from `create_view` recurses until the stack is gone — `wpe_view_new` →
//    `createView` → `wpe_view_new`, visible directly in a backtrace. The base `WPEView` is
//    derivable and not instantiable; each platform supplies its own.
//
// 2. **The view needs its display at construction.** A view built with no properties gets
//    as far as `wpe_input_method_context_new` and faults on a null display. The
//    `display` construct property is declared in a private header, so `WPEView.h` does not
//    document it — which is why this was found by running the journey and reading the
//    fault rather than by reading the header.
//
// 3. **`can_be_mapped` has to answer.** Returning false makes `wpe_view_map` a no-op, and
//    every later measurement would be of a view that never appeared.
//
// ABI measured with the same C probe as the display table, and asserted at compile time in
// the module: `sizeof(WPEView)` 32, `sizeof(WPEViewClass)` 464, and `buffers_changed` 136,
// `render_buffer` 144, `can_be_mapped` 192, `get_accessible` 200.
//
// **What is not yet true.** `buffers_allocated 0` and `frames_read_back 0`. The formats
// arrived and this framework has not built a buffer from them, so no pixel exists yet.
// `wpe_buffer_shm_new(WPEDisplay *, int, int, WPEPixelFormat, GBytes *, guint)`
// (WPEBufferSHM.h) takes the bytes rather than allocating them — this framework supplies
// the memory, the engine renders into it, and `wpe_buffer_shm_get_data` reads it straight
// back. `WPEPixelFormat` has exactly one member, `WPE_PIXEL_FORMAT_ARGB8888`, so there is
// nothing to negotiate and nothing to choose.

// ── Measured: buffers flow, pixels do not ──────────────────────────────────────
//
// The engine hands this framework its own buffers, and accepts a render request into
// them. Neither of those means a pixel was produced, and the third measurement is the
// one that settles it:
//
//     [lepton] buffers_changed n=2 first=... 900x640
//     [lepton] render_buffer accepted=1 error=0x0
//     [lepton] pixels 2304000 bytes 900x640 first=0x0 non_zero=0/576000
//
// 2304000 is 900 x 640 x 4 — exactly ARGB8888 at the requested size, so the buffer is
// the right one and `wpe_buffer_import_to_pixels` answered. Every one of its 576000
// pixels is zero. `render_buffer` returning true means the request was accepted, not
// that anything was drawn.
//
// **The size check would have lied.** "2304000 bytes read back" reads like success and is
// what an unwritten allocation looks like: right size, no content. `pixels_non_zero` in
// `platform/counters.zig` exists because of this, and it is the number that has to move.
//
// **Where to look next, and why.** `wpe_display_get_egl_display` (WPEDisplay.cpp) calls
// the display's `get_egl_display` vfunc and, when it is absent, fails with
// `WPE_DISPLAY_ERROR_NOT_SUPPORTED` before `eglInitialize` is ever reached. This
// framework's display does not implement it. Without an EGL display there is no GL
// context for the engine to render through, which is the most likely reason an accepted
// render request produces an empty buffer.
//
// That is a hypothesis with a mechanism behind it, not a measurement, and it is recorded
// as one. The way to tell is to implement `get_egl_display` and re-run this same
// measurement: `non_zero` either stops being zero or it does not.
//
// Two signatures here were wrong when first written and are now transcribed from
// WPEView.h:53-66 rather than from a summary — `buffers_changed` takes
// `(view, WPEBuffer **, guint)`, not a `WPEBufferFormats *`, and it is told about
// *buffers*, which is what flipped the assumed direction of the whole protocol. And
// `render_buffer` takes five arguments, the last being `GError **`; dropping it works on
// x86-64 because the spare register is ignored, which is how a wrong signature survives
// until it does not.

// ── Two hypotheses, both measured, both wrong ───────────────────────────────────
//
// **EGL was not the reason.** `get_egl_display` was implemented — surfaceless first,
// GBM on `/dev/dri/renderD128` as the fallback, both platforms confirmed present by
// `eglinfo` before being relied on — and the counter came back `egl_displays 0`. The
// engine never asked for an EGL display at all on this path. So "no GL context" was not
// why the buffer was empty. The code is left in place because it is required by the API
// and will be used; the *explanation* is what was wrong.
//
// **The render call was self-inflicted and mistimed.** `render_buffer_calls` reaching 1
// was read as "the engine called our vfunc". It had not. The only caller was this
// framework's own `wpe_view_render_buffer`, made from inside `buffers_changed` — and
// `wpe_view_render_buffer` routes back into the `render_buffer` vfunc, so the count was
// measuring our own request. Removing the call took the count to 0, which is what a real
// engine-initiated render would have looked like all along.
//
// Worse, the call was mistimed even as a request. `buffers_changed` fires when the engine
// creates its buffer pool, which is before the page has painted; asking for a render then
// asks for a frame of nothing. `accepted=1` and `non_zero=0` together are exactly that:
// a well-formed request for content that did not exist yet.
//
// **What the protocol therefore is, as measured.** The engine allocates the buffers and
// names them in `buffers_changed`; this framework is expected to drive rendering from its
// own frame loop by calling `wpe_view_render_buffer` on a buffer it was given, and to
// read the result afterwards. `render_buffer` on the class is the engine-side handler that
// a *remote* view would receive, which is why calling it in-process turned out to be a
// loop with ourselves.
//
// So the next step is not EGL and not a new vfunc: it is to stop rendering from inside
// `buffers_changed`, hold the buffers, and drive `wpe_view_render_buffer` from a frame
// loop that runs after the load settles. Whether that produces pixels without an EGL
// context is still open — `get_egl_display` has never been reached, so it has never been
// shown to be unnecessary either.

// ── The repaint loop, and the two faults that hid it ───────────────────────────
//
// Driving `wpe_view_render_buffer` from a frame loop instead of from `buffers_changed`
// works, and getting there took two faults that both looked like "no frames":
//
// **The check stopped pumping the moment the load settled.** The repaint timer only runs
// while the engine's main loop runs, and the check broke out of its settle loop on
// `!isLoading` — taking the engine away in the middle of the first frame. Added a bounded
// drain phase (30 turns, ~half a second) after the settle loop, deliberately outside it:
// the settle loop's question is "did the engine take the page", and it should not also
// decide when rendering gets a chance.
//
// **A timeout added during a dispatch is not re-armed.** `g_timeout_add` called from inside
// `buffers_changed` — which is itself running inside `g_main_context_iteration` — fired
// exactly once. Its callback returned "keep", the interval was shortened to 1 ms, and it
// still never fired again. Adding a second, unrelated source alongside it made the first
// one fire normally, which located the fault precisely enough to name it. The repaint
// timer is now installed from a `g_idle_add`, so the context is not mid-dispatch when it
// is created. That is not a guess: it is the difference between one tick and many.
//
// **Measured, and still no pixels:**
//
//     render_requests 3, refusals 0, frames_read_back 3, pixels_non_zero 0
//
// Three render requests, none refused, three buffers of the correct size read back, every
// pixel still zero — now with the timing right and the request coming after the page had
// settled. So neither "too early" nor "the engine refused" explains it.
//
// And `egl_displays 0` throughout: `get_egl_display` is implemented and never called. So
// the engine is willing to accept render requests with no GL context, and produces nothing
// with them. Whether that is because it needs one it never asked for, or because rendering
// needs a step this platform has not taken, is not established — and the next measurement
// has to distinguish those two, not assume one of them.

// ── What kind of buffer this is, and why that settles a question ────────────────
//
// The engine's buffers are shared memory, not GPU memory:
//
//     buffer type WPEBufferSHM stride=3600 shm=true
//
// stride 3600 is 900 x 4, exactly ARGB8888 at the width requested. The library confirms
// the origin: `AcceleratedBackingStore_DidCreateSHMBuffer` is in the binary, so these are
// WebKit's accelerated backing store handing out shared memory for the platform to fill.
//
// That closes one door. The suspicion had been that `wpe_buffer_import_to_pixels` was
// returning nothing because the pixels live on a GPU it cannot map — true for DMABUF, and
// it would have been the wrong theory here. Reading the shared memory *directly*, through
// `wpe_buffer_shm_get_data`, with no import step in the path at all, gives zero non-zero
// pixels out of 576000.
//
// So, all four measured, and none of them the explanation:
//
//   - the render request is accepted (`refusals 0`);
//   - the buffer is the right type and the right size;
//   - the frame is requested after the page settled, from a loop that demonstrably runs;
//   - and the buffer's own memory is untouched.
//
// What is left is that nothing ever drew into it. `get_egl_display` remains uncalled, and
// the accelerated backing store is a GL path — so the question worth asking next is whether
// that path needs a context from `wpe_display_get_egl_display` on a platform whose
// `connect` succeeds without one. This is not yet established, and it is a question about
// WebKit's WPE accelerated backing store rather than about this framework, so the answer
// belongs in that source and not in a guess written here.
