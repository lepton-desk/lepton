//! One webview, and the engine's lifecycle around it.
//!
//! ## What this path can and cannot do today
//!
//! It opens a platform backend, wraps it, creates a view, loads pages into it and
//! reports what the engine says about itself. It presents nothing, and it does not
//! pretend to.
//!
//! That limit is in WPE, not here, and it is worth stating precisely because the whole
//! point of a Zero-Copy framework is to want the opposite. `struct
//! wpe_view_backend_interface` — the entire surface an embedder implements, at
//! `view-backend.h:63-75` — has four members: `create`, `destroy`, `initialize`,
//! `get_renderer_host_fd`. There is no render target in it. The engine composites the
//! page inside the platform backend it loaded, and the embedder learns that a frame
//! happened through `wpe_view_backend_dispatch_frame_displayed`, which carries no
//! pixels.
//!
//! `wpe_view_render_buffer` looks like the door out, and it is not: at
//! `WPEView.h:131` it takes five arguments including a damage array and a `GError**`,
//! and its `FALSE` return means `WPE_VIEW_ERROR_RENDER_FAILED` (`WPEView.h:83-91`) —
//! not "busy", which is what a plausible reading of the name suggests. It is how a
//! backend offers a buffer *to* a view, not how an embedder offers one *to* the engine.
//!
//! Reaching pixels therefore means one of two real projects, neither of which is
//! plumbing:
//!
//! 1. **Write a WPE platform backend.** Implement
//!    `wpe_view_backend_create_with_backend_interface` with a `create` that brings up
//!    EGL on the fd from `wpe_view_backend_get_renderer_host_fd`, and composites into
//!    the frame the window layer already owns. That is the correct path, it is what
//!    `wpebackend-fdo` does, and it is a component in its own right.
//! 2. **Use the headless display.** `wpe_display_headless_new()` renders off-screen.
//!    Whether its output can be read back cheaply is not established, and guessing at
//!    it is the mistake this file is written to avoid.
//!
//! Until one of those exists, `webview_check` reports engine state and refuses to
//! claim a frame it never saw.

const std = @import("std");

const abi = @import("wpe_abi.zig");
const platform_abi = @import("wpe_platform_abi.zig");
const bridge_mod = @import("bridge.zig");
const invoke = @import("invoke.zig");
const events = @import("events.zig");
const transport = @import("transport.zig");

pub const Error = error{
    /// The build found no WPE, so this module was compiled without an engine.
    NotBuilt,
    /// The loader could not bring up the requested platform backend. Distinct from
    /// `NoDisplay` because the remedy differs: this one is a missing or mismatched
    /// backend library, that one is a backend that loaded and then failed to start.
    NoBackendLibrary,
    /// No platform backend could be started. On a machine with no usable backend this
    /// is the ordinary outcome, which is why it has its own case rather than being
    /// folded into a generic failure.
    NoDisplay,
    /// libwpe loaded a backend but WebKit refused to wrap it, or refused to make a
    /// view from the wrapper. The two are separated because they fail for different
    /// reasons and a caller may be able to act on one.
    NoView,
};

/// The library the loader opens, as the build's `pkg-config` probe reported it.
///
/// `libwpe`'s loader passes this name straight to `dlopen`
/// (`wpe/loader.h:78`), and the file it must open is named after the backend's ABI
/// rather than its release version — libwpe 1.16.3 and its fdo backend 1.16.1 both
/// ship `libWPEBackend-fdo-1.0.so`. Writing that name here would make a constant that
/// is right until libwpe 2.0, and wrong in exactly the way a missing backend is
/// wrong, so the build reads it from `wpebackend-fdo.pc` instead.
///
/// Empty when no platform backend is installed, which is a state the check tool
/// reports rather than one it works around.
/// Long enough for any name the packaging can produce and bounded on purpose: a
/// buffer with room to spare is a buffer that can hide a mistake, and the only
/// acceptable failure here is a name that cannot fit at all.
const library_name_capacity = 96;

pub fn backendLibraryName() []const u8 {
    return @import("build_options").wpe_backend_library;
}

/// Runs one turn of GLib's default main context, the engine's event loop.
///
/// Returns whether any source was dispatched. Non-blocking on purpose: the engine's
/// events and this framework's own timeouts have to share one thread, and a blocking
/// iteration would make the loop's responsiveness a function of whether the engine
/// happened to be busy.
///
/// Skipping this is not a performance choice. WPE hangs its Wayland connection and its
/// channel to the network process off this context, so a caller that never iterates it
/// sees a view that never maps and a page that never leaves `WEBKIT_LOADING` — states
/// that look exactly like a broken engine and are not one.
pub fn pump() bool {
    const context = abi.g_main_context_default() orelse return false;
    return abi.g_main_context_iteration(context, 0) != 0;
}

/// Runs one iteration of the engine's loop, **sleeping** until something is due.
///
/// `pump` never blocks, so a loop built on it spins a core at 100% while the page sits
/// idle. This is the loop a program should run; pair it with `wakeEvery` when it has
/// work of its own on a schedule, so the sleep is bounded by that schedule.
pub fn pumpBlocking() bool {
    const context = abi.g_main_context_default() orelse return false;
    return abi.g_main_context_iteration(context, 1) != 0;
}

/// `gulong g_signal_connect_data(gpointer, const gchar *, GCallback, gpointer,
/// GClosureNotify, GConnectFlags)` — gobject/gsignal.h.
const e_event_type = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_event_get_event_type" });
const e_signal_connect = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    .{ .name = "g_signal_connect_data" },
);
// The window, for `window.*` commands and events (`WPEView.h`, `WPEToplevel.h`, 2.54).
const e_view_get_toplevel = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "wpe_view_get_toplevel" });
const e_view_get_toplevel_state = @extern(*const fn (?*anyopaque) callconv(.c) u32, .{ .name = "wpe_view_get_toplevel_state" });
const e_view_get_width = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_view_get_width" });
const e_view_get_height = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_view_get_height" });
const e_toplevel_minimize = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_toplevel_minimize" });
const e_toplevel_maximize = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_toplevel_maximize" });
const e_toplevel_unmaximize = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "wpe_toplevel_unmaximize" });
const e_toplevel_set_title = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, .{ .name = "wpe_toplevel_set_title" });
const e_web_view_get_title = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_web_view_get_title" });

/// `void g_main_context_wakeup(GMainContext *)` — glib/gmain.h.
const e_context_wakeup = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_main_context_wakeup" });

const e_timeout_add = @extern(
    *const fn (u32, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) u32,
    .{ .name = "g_timeout_add" },
);

/// Keeps the timer source (`G_SOURCE_CONTINUE`). Its only job is to end the wait.
fn onWake(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

/// Makes `pumpBlocking` return at least every `interval_ms`, so a caller's own periodic
/// work runs on time without the loop polling. Returns the GLib source id (0 = refused).
pub fn wakeEvery(interval_ms: u32) u32 {
    return e_timeout_add(interval_ms, &onWake, null);
}

/// The backend implementation the loader actually brought up, or null before it has.
///
/// Read from the loader rather than echoed back from `backendLibraryName`: the header
/// is explicit that the loaded name is not guaranteed to equal the requested one, and
/// a check that printed the request would be printing an intention.
/// Where the engine should keep local storage and IndexedDB, if the caller has an opinion.
///
/// WebKitWPE 2.54 has no setter for this. `get_base_data_directory` is exported but faults
/// when no data manager exists, and the location it would report is `$XDG_DATA_HOME/wpe` —
/// measured, by pointing `XDG_DATA_HOME` elsewhere and finding the storage written there.
///
/// The variable is therefore the only handle there is. It is **not** set silently: a
/// library that quietly replaced the caller's `XDG_DATA_HOME` would move every other
/// program's data too, which is a far worse failure than sharing a storage directory with
/// another WPE application. A packaged build asks for it explicitly.
/// libc's `setenv`, declared rather than reached through `std`.
///
/// Zig 0.16 exposes no way to change this process's environment — `std.process.Environ`
/// describes a map rather than the live environment — and the alternative was to move the
/// call into the application, which would put framework policy in every generated project.
pub const setenv = @extern(
    *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    .{ .name = "setenv" },
);

var data_directory: [std.fs.max_path_bytes:0]u8 = undefined;
var cache_directory: [std.fs.max_path_bytes:0]u8 = undefined;
var directories_set = false;

/// Gives this application's web data its own directories: storage (localStorage,
/// IndexedDB, cookies) under `$APPDATA` and caches under `$APPCACHE` — the same
/// `~/.local/share/<identifier>` that `plugin-fs` calls `$APPDATA`. Call before `open`.
///
/// Measured before this existed: every Lepton application stored its data in one
/// `~/lepton/wpe/storage` (the old code appended a fixed `lepton`, and without
/// `XDG_DATA_HOME` put it straight into the home directory), and a second application
/// read the first one's `localStorage` — all of them serve the page from the same
/// origin, `lepton://localhost`. Returns false when the directories cannot be named
/// (no `HOME`); the engine then uses its own default.
pub fn useApplicationDirectories(identifier: []const u8) bool {
    const paths = @import("../../platform/linux/paths.zig");
    var scratch: [4096]u8 = undefined;
    const data = paths.resolve(.app_data, identifier, data_directory[0 .. data_directory.len - 1], &scratch) catch return false;
    data_directory[data.len] = 0;
    const cache = paths.resolve(.app_cache, identifier, cache_directory[0 .. cache_directory.len - 1], &scratch) catch return false;
    cache_directory[cache.len] = 0;
    // Made here, 0700, before the engine makes them 0755 (measured: it does). Web storage
    // and cookies are the user's private data.
    if (!paths.makePrivate(data_directory[0..data.len :0])) return false;
    if (!paths.makePrivate(cache_directory[0..cache.len :0])) return false;
    directories_set = true;
    if (!comptime @import("build_options").wpe_platform_abi) {
        // The legacy engine has no session object; its only handle is the environment.
        paths.rememberDataHome();
        _ = setenv("XDG_DATA_HOME", data_directory[0..data.len :0].ptr, 1);
    }
    return true;
}

pub fn setDataDirectory(path: [*:0]const u8) void {
    // After this the environment no longer says where the user's data lives; plugins
    // resolving `$APPDATA` need the value from before.
    @import("../../platform/linux/paths.zig").rememberDataHome();
    _ = setenv("XDG_DATA_HOME", path, 1);
}

pub fn loadedBackend() ?[]const u8 {
    // There is no loader on the 2.54 platform ABI and nothing for it to report: the
    // platform implementation is chosen inside the engine, so asking for the library
    // name of a backend that was never loaded would be asking about a mechanism this
    // build does not use. Null means "no loader", not "no backend".
    if (comptime @import("build_options").wpe_platform_abi) return null;
    const raw = abi.wpe_loader_get_loaded_implementation_library_name() orelse return null;
    return std.mem.span(raw);
}

/// One webview, owned by this framework and destroyed with it.
///
/// The three pointers are three libraries' objects in a fixed ownership order:
/// `backend` belongs to libwpe, `web_backend` is WebKit's wrapper around it, and
/// `web_view` owns the `view` inside it. Releasing them out of that order leaves the
/// engine holding pointers into memory this framework has already returned, which is
/// a crash in someone else's address space rather than a diagnosable one here.
pub const View = struct {
    web_view: *abi.WebKitWebView,
    view: *abi.WPEView,

    /// The core's end of the page conversation, on the 2.54 ABI.
    ///
    /// Held here rather than created on demand because WebKit keeps the callback pointer
    /// until the context is dropped, so the bridge has to live at least that long. A
    /// bridge on the stack would answer the next page load from a returned frame.
    bridge: bridge_mod.Bridge = .{},

    /// Set when the window was closed by the user (`WPEView::closed`) or by the page
    /// (`window.close()` → `WebKitWebView::close`). The owner's loop reads it and ends.
    closed: bool = false,

    /// The application's title, shown while the page has none of its own (`setTitle`).
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    title_watched: bool = false,

    /// Opens a view on whichever engine ABI this build detected.
    ///
    /// Both are kept because both exist in the wild and neither can be assumed. The
    /// 2.54 platform ABI is the default because staying on the legacy one by accident
    /// means the next WebKit update breaks this build with no change on this side; the
    /// legacy path remains reachable with `-Dwpe-abi=legacy` for machines still on 2.52.
    pub fn open() Error!View {
        if (comptime @import("build_options").wpe_platform_abi) return platformOpen();
        return legacyOpen();
    }

    /// Opens a view over the engine's default display, on the pre-2.54 ABI.
    ///
    /// The order is not interchangeable and each step depends on the previous one: a
    /// platform backend has to exist before WebKit can wrap it, and the wrapper before
    /// a view can be made from it. `wpe_display_get_default` is not consulted
    /// separately because asking it for a display is itself what starts a backend.
    fn legacyOpen() Error!View {
        // The loader is initialised first and with an explicit library name, because
        // `wpe_display_get_default` would otherwise ask for `libWPEBackend-default.so`
        // and abort the process inside `dlopen` when it found no such library. Failing
        // before that happens is the difference between a check that reports a missing
        // backend and a check that takes the whole process down.
        const library = backendLibraryName();
        if (library.len == 0) return Error.NoBackendLibrary;
        var name_buffer: [library_name_capacity]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buffer, "{s}", .{library}, 0) catch
            return Error.NoBackendLibrary;

        if (!abi.wpe_loader_init(name)) return Error.NoBackendLibrary;

        if (abi.wpe_display_get_default() == null) return Error.NoDisplay;

        const web_view = abi.webkit_web_view_new(null) orelse return Error.NoView;
        const view = abi.webkit_web_view_get_wpe_view(web_view) orelse return Error.NoView;

        return View{ .web_view = web_view, .view = view };
    }

    /// Keeps the session's cookies in `cookies.sqlite` in the application's data folder. A
    /// network session given a data directory still keeps cookies in memory only until it
    /// is told a file (measured: a cookie the dev server's page wrote was gone at the next
    /// start, while `localStorage` beside it lasted, and no cookie file was ever written).
    fn keepCookies(session: *anyopaque) void {
        const manager = platform_abi.webkit_network_session_get_cookie_manager(session) orelse return;
        var path: [std.fs.max_path_bytes:0]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&path, "{s}/cookies.sqlite", .{std.mem.sliceTo(&data_directory, 0)}, 0) catch return;
        platform_abi.webkit_cookie_manager_set_persistent_storage(manager, file.ptr, platform_abi.cookie_storage_sqlite);
    }

    /// Opens a view on the ABI WebKit 2.54 introduced.
    ///
    /// There is no loader to initialise and no display to construct, because the platform
    /// integration now lives inside the engine. The engine builds the view, the platform
    /// view comes back out of it, and which platform implementation is behind that is
    /// `WPE_PLATFORM`'s business rather than this call's.
    ///
    /// The short version of what 2.54 changed: before it an embedder loaded a backend,
    /// built a view backend and wrapped it before a view could exist, and that assembly
    /// had to be a GObject registered as a GIO extension point — which is what
    /// `WPELeptonDisplay` is. None of it is needed here, which is why nothing in this
    /// function has a counterpart in `legacyOpen` beyond the view itself.
    fn platformOpen() Error!View {
        // Both are opaque handles from the new ABI's declarations, and both are the same
        // C types the legacy path has always held — only the spelling differs.
        const created = if (directories_set) blk: {
            const session = platform_abi.webkit_network_session_new(&data_directory, &cache_directory) orelse return Error.NoView;
            keepCookies(session);
            // The view takes its own reference (construct-only, transfer none).
            defer abi.g_object_unref(session);
            break :blk platform_abi.g_object_new_with(platform_abi.webkit_web_view_get_type(), "network-session", session, @as(?*anyopaque, null));
        } else platform_abi.g_object_new(platform_abi.webkit_web_view_get_type(), null);
        const web_view: *abi.WebKitWebView = @ptrCast(created orelse return Error.NoView);
        const view: *abi.WPEView = @ptrCast(
            platform_abi.webkit_web_view_get_wpe_view(web_view) orelse return Error.NoView,
        );

        @import("features.zig").apply(web_view);
        const opened = View{ .web_view = web_view, .view = view };
        // Registered against the view's *own* context, not the process default: a view
        // carries a context of its own and a scheme registered only on the default would
        // leave this view unable to resolve it — indistinguishable, from the page's side,
        // from a bridge that never arrives.
        return opened;
    }

    /// Registers the core's bridge against this view's context.
    ///
    /// Separate from `open`, and it has to be. WebKit keeps the callback pointer until the
    /// context is dropped, so it must be the address of a `View` that lives where it will
    /// still live — and `open` returns by value, so a bridge registered inside it would be
    /// registered against the address of a returned local. This is the third time this
    /// exact mistake has been made in this codebase (the others: the Wayland listener
    /// tables, and `Bridge.register`), and the symptom is always the same: a callback that
    /// is installed, never fires, and reports zero.
    pub fn startBridge(self: *View) void {
        if (!comptime @import("build_options").wpe_platform_abi) return;
        const context = platform_abi.webkit_web_view_get_context(self.web_view) orelse return;
        self.bridge.attach(context);
        // `LEPTON_RECORD=<file>`: `lepton record`, or anyone reproducing a bug.
        self.bridge.recorder = @import("record.zig").Recorder.fromEnvironment();
        self.bridge.page_replay = @import("page_replay.zig").fromEnvironment();
        if (self.bridge.page_replay) |*script| script.closeWhenDone(&self.bridge.close_requested);
        @import("downloads.zig").watch(self.web_view, &self.bridge);
        @import("permissions.zig").watch(self.web_view, &self.bridge);
        // The window the page's `window.*` commands act on, and the two changes it is
        // told about as events. `self` is the pointer GLib keeps, as in `watchClose`.
        self.bridge.window = .{ .context = self, .act = &windowAct, .state = &windowState, .permission = &@import("permissions.zig").answer };
        _ = e_signal_connect(@ptrCast(self.view), "toplevel-state-changed", @ptrCast(&onToplevelState), self, null, 0);
        _ = e_signal_connect(@ptrCast(self.view), "resized", @ptrCast(&onResized), self, null, 0);
        // Every input event passes here before WebKit's: a press marks the user acting.
        _ = e_signal_connect(@ptrCast(self.view), "event", @ptrCast(&onInput), null, null, 0);
        // The default context only when it is a different object: a view built on the
        // default context would otherwise register the scheme twice, which WebKit
        // reports as CRITICAL ("Cannot register URI scheme lepton more than once").
        if (platform_abi.webkit_web_context_get_default()) |fallback| {
            if (fallback != context) self.bridge.attach(fallback);
        }
    }

    fn windowAct(data: ?*anyopaque, action: invoke.WindowAction) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        const toplevel = e_view_get_toplevel(@ptrCast(self.view)) orelse return false;
        return switch (action) {
            .minimize => e_toplevel_minimize(toplevel),
            .maximize => e_toplevel_maximize(toplevel),
            .unmaximize => e_toplevel_unmaximize(toplevel),
        } != 0;
    }

    fn windowState(data: ?*anyopaque) ?u32 {
        const self: *View = @ptrCast(@alignCast(data orelse return null));
        return e_view_get_toplevel_state(@ptrCast(self.view));
    }

    /// `WPEView::toplevel-state-changed(previous_state)`: the page gets `window.state`
    /// with the new bits as a little-endian `u32`.
    fn onToplevelState(view: ?*anyopaque, _: u32, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data orelse return));
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, e_view_get_toplevel_state(view), .little);
        _ = self.bridge.emit(events.window_state, &bytes) catch {};
    }

    /// `WPEView::event`: notes a press, then lets the event go on to the page (FALSE).
    fn onInput(_: ?*anyopaque, event: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        // `WPEEventType` (WPEEvent.h): POINTER_DOWN = 1, KEYBOARD_KEY_DOWN = 7, TOUCH_DOWN = 9.
        switch (e_event_type(event)) {
            1, 7, 9 => @import("activation.zig").press(),
            else => {},
        }
        return 0;
    }

    /// `WPEView::resized`: the page gets `window.resized` with width and height, each a
    /// little-endian `u32`, in logical pixels as WPE reports them.
    fn onResized(view: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data orelse return));
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], @intCast(@max(e_view_get_width(view), 0)), .little);
        std.mem.writeInt(u32, bytes[4..8], @intCast(@max(e_view_get_height(view), 0)), .little);
        _ = self.bridge.emit(events.window_resized, &bytes) catch {};
    }

    /// Titles the window `title` — the application's name, which docks, window switchers
    /// and task managers show — and from then on follows the page's `document.title`,
    /// falling back to `title` whenever the page has none. Takes `self` by pointer: GLib
    /// keeps it for the signal's lifetime.
    pub fn setTitle(self: *View, title: []const u8) void {
        const kept = fitTitle(title, self.title.len - 1);
        @memcpy(self.title[0..kept.len], kept);
        self.title[kept.len] = 0;
        self.title_len = kept.len;
        if (!comptime @import("build_options").wpe_platform_abi) return;
        if (!self.title_watched) {
            self.title_watched = true;
            _ = e_signal_connect(@ptrCast(self.web_view), "notify::title", @ptrCast(&onTitle), self, null, 0);
        }
        self.showTitle();
    }

    fn showTitle(self: *View) void {
        const toplevel = e_view_get_toplevel(@ptrCast(self.view)) orelse return;
        const page = if (e_web_view_get_title(@ptrCast(self.web_view))) |raw| std.mem.span(raw) else "";
        if (page.len != 0) {
            e_toplevel_set_title(toplevel, e_web_view_get_title(@ptrCast(self.web_view)).?);
        } else {
            e_toplevel_set_title(toplevel, self.title[0..self.title_len :0]);
        }
    }

    fn onTitle(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data orelse return));
        self.showTitle();
    }

    /// Watches for the window going away, so the owner's loop can end.
    ///
    /// Without it, closing the window left the process running with nothing on screen —
    /// measured: the loop only ended on `/__lepton/close`. Takes `self` by pointer for the
    /// same reason as `startBridge`: GLib keeps the pointer for the signal's lifetime.
    pub fn watchClose(self: *View) void {
        _ = e_signal_connect(@ptrCast(self.view), "closed", @ptrCast(&onClosed), self, null, 0);
        _ = e_signal_connect(@ptrCast(self.web_view), "close", @ptrCast(&onClosed), self, null, 0);
    }

    fn onClosed(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *View = @ptrCast(@alignCast(data orelse return));
        self.closed = true;
        // Wake the blocking pump, which may otherwise sleep until the next timer tick.
        if (abi.g_main_context_default()) |context| e_context_wakeup(context);
    }

    /// Injects `globalThis.__lepton` for every document this view loads, sized for a ring
    /// of `region_len` bytes. Returns whether the engine accepted the script.
    pub fn injectTransport(self: *View, region_len: usize) bool {
        if (!comptime @import("build_options").wpe_platform_abi) return false;
        var source: [16384]u8 = undefined;
        const text = transport.script(&source, region_len, &self.bridge.registry, self.bridge.pageOrigin()) catch return false;
        return transport.inject(@ptrCast(self.web_view), text);
    }

    /// Tells the engine the view is `width` by `height`.
    ///
    /// Only the view is told, and it is the only addressable end: the backend client
    /// that `wpe_view_backend_dispatch_set_size` would reach belongs to a
    /// `wpe_view_backend` this framework does not hold, because the platform created
    /// it. See the note on `open` for why that is not a gap this path can close.
    pub fn resized(self: *View, width: i32, height: i32) void {
        abi.wpe_view_resized(self.view, width, height);
    }

    /// Makes the view visible and maps it.
    ///
    /// Separate from `open` because a view must be sized before it is mapped, and
    /// because a caller that wants to inspect the engine before committing to a
    /// visible surface needs a chance to.
    /// `window.decorations: false`. Not on WPE yet: its title bar is the compositor's
    /// (xdg-decoration), and WPE 2.54's `WPEToplevel` offers no call to decline it. The
    /// page can still draw its own bar inside; `window.start_drag` answers `failed`.
    pub fn setDecorations(self: *View, decorated: bool) void {
        _ = self;
        _ = decorated;
    }

    pub fn map(self: *View) void {
        abi.wpe_view_set_visible(self.view, 1);
        abi.wpe_view_map(self.view);
    }

    /// Reports whether the view has been mapped.
    pub fn isMapped(self: *const View) bool {
        return abi.wpe_view_get_mapped(self.view) != 0;
    }

    /// Reports whether a load is in flight.
    pub fn isLoading(self: *const View) bool {
        return abi.webkit_web_view_is_loading(self.web_view) != 0;
    }

    /// Loads `uri`, which must be NUL-terminated.
    ///
    /// `webkit_web_view_load_uri` returns nothing and there is no error to collect:
    /// a load that fails is visible through `isLoading` going false with no progress
    /// behind it, which is what `check` below watches for.
    /// Loads `html` as a document with `base` as its origin.
    ///
    /// The base URI is not a formality: a document loaded from a `data:` URL has an opaque
    /// origin and cannot fetch a registered custom scheme from it, so the request never
    /// reaches the handler and a bridge looks silent. `http://` is what a real frontend
    /// arrives over — the dev server, or the packaged bundle served locally — and it is
    /// the only base under which the page can actually reach the core.
    pub fn loadHtml(self: *View, html: [:0]const u8, base: [:0]const u8) void {
        if (comptime @import("build_options").wpe_platform_abi) {
            platform_abi.webkit_web_view_load_html(self.web_view, html, base);
        } else {
            abi.webkit_web_view_load_html(self.web_view, html, base);
        }
    }

    pub fn load(self: *View, location: [:0]const u8) void {
        abi.webkit_web_view_load_uri(self.web_view, location.ptr);
    }

    /// The URI the engine settled on, after redirects, or null if it has none.
    pub fn uri(self: *const View) ?[]const u8 {
        const raw = abi.webkit_web_view_get_uri(self.web_view) orelse return null;
        return std.mem.span(raw);
    }

    /// Releases what this framework owns.
    ///
    /// One reference, on the `WebKitWebView`. Nothing else was ever taken: the display
    /// and the view backend behind it belong to the loader, which outlives any view
    /// and is not this framework's to destroy. Unreffing the view is enough for it to
    /// be collected, and unrefing anything else would be releasing a reference the
    /// loader still holds.
    pub fn close(self: *View) void {
        // Dialogs the page opened would otherwise stay on screen after the window.
        @import("../../platform/linux/portal.zig").closeAll();
        if (self.bridge.recorder) |*recorder| recorder.close();
        abi.g_object_unref(self.web_view);
        self.* = undefined;
    }
};

/// Whether this build contains the webview path.
///
/// The build probes for WPE and records the answer here, so a machine without it
/// compiles and runs the native path rather than failing to build.
pub fn is_available() bool {
    return @import("build_options").have_wpe;
}

test "the window commands and events path is compiled" {
    // Referenced so the test build analyses it: nothing in a test opens a view, and code
    // Zig never analyses can be wrong while every test passes (see `bridge.zig`).
    if (comptime !(@import("build_options").wpe_platform_abi and @import("root.zig").is_available())) return error.SkipZigTest;
    _ = &View.startBridge;
    _ = &View.setTitle;
    _ = &View.windowAct;
    _ = &View.windowState;
    _ = &View.onToplevelState;
    _ = &View.onResized;
}

test "each application's web data is named after it, under the user's data directory" {
    if (comptime !(@import("build_options").wpe_platform_abi and @import("root.zig").is_available())) return error.SkipZigTest;
    _ = &View.platformOpen;
    try std.testing.expect(useApplicationDirectories("style.lepton.directory-test"));
    const data = std.mem.sliceTo(&data_directory, 0);
    const cache = std.mem.sliceTo(&cache_directory, 0);
    try std.testing.expect(std.mem.endsWith(u8, data, "/style.lepton.directory-test"));
    try std.testing.expect(std.mem.endsWith(u8, cache, "/style.lepton.directory-test"));
    try std.testing.expect(!std.mem.eql(u8, data, cache));
    // Never the old shared place.
    try std.testing.expect(std.mem.indexOf(u8, data, "/lepton/") == null);
    directories_set = false;
    // Made for real (0700) in the user's own directories; empty, so removed again.
    const linux = std.os.linux;
    var info: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, &data_directory, 0, .{ .MODE = true }, &info);
    try std.testing.expectEqual(@as(u16, 0o700), info.mode & 0o777);
    _ = linux.unlinkat(linux.AT.FDCWD, &data_directory, linux.AT.REMOVEDIR);
    _ = linux.unlinkat(linux.AT.FDCWD, &cache_directory, linux.AT.REMOVEDIR);
}

/// The longest prefix of `title` that fits `limit` bytes without splitting a UTF-8
/// character: a title cut mid-character is not valid UTF-8, which GLib rejects.
fn fitTitle(title: []const u8, limit: usize) []const u8 {
    if (title.len <= limit) return title;
    var end = limit;
    while (end > 0 and (title[end] & 0xC0) == 0x80) end -= 1;
    return title[0..end];
}

test "a long title is cut on a character boundary" {
    try std.testing.expectEqualStrings("Notlar", fitTitle("Notlar", 255));
    // "ş" is two bytes: a limit landing inside it keeps the character out.
    try std.testing.expectEqualStrings("Ba", fitTitle("Baş", 3));
    try std.testing.expectEqualStrings("Baş", fitTitle("Baş", 4));
}
