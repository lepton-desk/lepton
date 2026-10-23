//! A WebView2 view in a Win32 window: Windows' counterpart of `wpe_view.zig`.
//!
//! The same surface the template's `main.zig` drives on Linux — `open`, `resized`, `map`,
//! `setTitle`, `startBridge`, `watchClose`, `injectTransport`, `load`, `close`, the
//! `bridge` and the `closed` flag — so one entry point runs on both engines.
//!
//! ## The core's origin
//!
//! WebKit takes a custom scheme (`lepton://`); WebView2 registers schemes only through
//! environment options this loader-free start does not pass. The page is instead served
//! from `http://lepton.localhost/`: requests to that host are filtered
//! (`AddWebResourceRequestedFilter`) and answered by the bridge, so nothing reaches the
//! network. `*.localhost` is a secure context in Chromium and never resolves off the
//! machine (RFC 6761), and `transport.core_origin` names it on Windows.
//!
//! ## Start-up
//!
//! The environment and the controller arrive through completion handlers on the window's
//! thread. `open` runs the message loop until both have (or one failed), so the caller
//! gets a ready view the way `wpe_view.open` returns one — the same shape, measured to
//! take ~0.8 s warm on this machine (`webview2-check`).

const std = @import("std");
const builtin = @import("builtin");
const wv = @import("c.zig");
const c = wv.c;
const W = wv.W;
const runtime = @import("runtime.zig");
const window = @import("../../../window/windows/window.zig");
const request = @import("request.zig");
const bridge_mod = @import("../bridge.zig");
const transport = @import("../transport.zig");
const events = @import("../events.zig");
const invoke = @import("../invoke.zig");
const features = @import("../features.zig");
const permissions = @import("permissions.zig");
const downloads = @import("downloads.zig");
const popup = @import("popup.zig");
const chrome_mod = @import("chrome.zig");

pub const Error = error{ NoRuntime, NoWindow, Com, Environment, Controller, Timeout };

/// The host the page and the core share (`http://lepton.localhost/`).
pub const host = "lepton.localhost";

/// How long `open` waits for the engine before giving up.
const start_timeout_ms = 30_000;

// --- the process's engine state ------------------------------------------------------------

var data_directory: [c.MAX_PATH:0]u16 = undefined;
var data_set = false;
var version_text: [64]u8 = undefined;
var version_len: usize = 0;

/// Puts this application's web data (storage, cookies, caches) in
/// `%LOCALAPPDATA%\<identifier>`, the counterpart of `~/.local/share/<identifier>`: every
/// Lepton page has the same origin, so a shared folder would share storage. Call before
/// `open`. False when `LOCALAPPDATA` is not set.
/// `shobjidl.h`; declared here rather than pulling that header into the translation.
extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(id: [*:0]const u16) callconv(.winapi) c.HRESULT;

pub fn useApplicationDirectories(identifier: []const u8) bool {
    var name: [256]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], identifier[0..@min(identifier.len, 80)]) catch return false;
    name[units] = 0;
    // The same identifier as the installer's Start menu shortcut (`PKEY_AppUserModel_ID`,
    // `lepton package` MSI): the taskbar groups this process's windows under it. Before
    // any window, as Windows requires.
    _ = SetCurrentProcessExplicitAppUserModelID(name[0..units :0]);
    var base: [c.MAX_PATH]u16 = undefined;
    const got = c.GetEnvironmentVariableW(W("LOCALAPPDATA"), &base, base.len);
    if (got == 0 or got >= base.len) return false;
    if (got + 1 + units >= data_directory.len) return false;
    @memcpy(data_directory[0..got], base[0..got]);
    data_directory[got] = '\\';
    @memcpy(data_directory[got + 1 ..][0..units], name[0..units]);
    data_directory[got + 1 + units] = 0;
    _ = c.CreateDirectoryW(&data_directory, null);
    data_set = true;
    return true;
}

/// An explicit data folder (UTF-8 path), for a caller with its own opinion.
pub fn setDataDirectory(path: [*:0]const u8) void {
    const text = std.mem.span(path);
    const units = std.unicode.utf8ToUtf16Le(data_directory[0 .. data_directory.len - 1], text[0..@min(text.len, c.MAX_PATH / 3)]) catch return;
    data_directory[units] = 0;
    data_set = true;
}

/// "WebView2 <version>", once a view has opened.
pub fn loadedBackend() ?[]const u8 {
    if (version_len == 0) return null;
    return version_text[0..version_len];
}

/// Dispatches every message waiting; never sleeps. True when there was one.
pub fn pump() bool {
    var message: c.MSG = undefined;
    var any = false;
    while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
        any = true;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    return any;
}

/// Sleeps until a message arrives, dispatches it and whatever else is waiting.
pub fn pumpBlocking() bool {
    var message: c.MSG = undefined;
    if (c.GetMessageW(&message, null, 0, 0) <= 0) return false;
    _ = c.TranslateMessage(&message);
    _ = c.DispatchMessageW(&message);
    _ = pump();
    return true;
}

/// Ends `pumpBlocking`'s wait at least every `interval_ms`: a thread timer posts
/// `WM_TIMER` to this thread's queue. Returns the timer id (0 = refused).
pub fn wakeEvery(interval_ms: u32) u32 {
    return @truncate(c.SetTimer(null, 0, interval_ms, null));
}

// --- start-up handlers --------------------------------------------------------------------

const Startup = struct {
    environment: ?*c.ICoreWebView2Environment = null,
    controller: ?*c.ICoreWebView2Controller = null,
    failed: ?c.HRESULT = null,
};
var startup: Startup = .{};

fn environmentReady(
    _: [*c]c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
    hr: c.HRESULT,
    environment: [*c]c.ICoreWebView2Environment,
) callconv(.winapi) c.HRESULT {
    if (!wv.ok(hr) or environment == null) {
        startup.failed = hr;
        return c.S_OK;
    }
    _ = environment.*.lpVtbl.*.AddRef.?(environment);
    startup.environment = environment;
    return c.S_OK;
}

fn controllerReady(
    _: [*c]c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    hr: c.HRESULT,
    controller: [*c]c.ICoreWebView2Controller,
) callconv(.winapi) c.HRESULT {
    if (!wv.ok(hr) or controller == null) {
        startup.failed = hr;
        return c.S_OK;
    }
    _ = controller.*.lpVtbl.*.AddRef.?(controller);
    startup.controller = controller;
    return c.S_OK;
}

const EnvironmentDone = wv.Handler(
    c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
    c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl,
    &c.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
    environmentReady,
);
const ControllerDone = wv.Handler(
    c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl,
    &c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    controllerReady,
);
var environment_done = EnvironmentDone.make();
var controller_done = ControllerDone.make();

/// Runs the message loop until `done` says so, the start-up failed, or time ran out.
fn waitFor(comptime done: fn () bool) Error!void {
    const deadline = c.GetTickCount64() + start_timeout_ms;
    const timer = c.SetTimer(null, 0, 100, null);
    defer _ = c.KillTimer(null, timer);
    while (!done()) {
        if (startup.failed != null) return error.Environment;
        if (c.GetTickCount64() > deadline) return error.Timeout;
        if (!pumpBlocking()) return error.Environment;
    }
}

fn environmentArrived() bool {
    return startup.environment != null;
}

fn controllerArrived() bool {
    return startup.controller != null;
}

// --- the view ------------------------------------------------------------------------------

pub const View = struct {
    /// The requests a view hands to the bridge: everything on the core's host.
    pub const filter = W("http://lepton.localhost/*");

    window: c.HWND,
    environment: *c.ICoreWebView2Environment,
    controller: *c.ICoreWebView2Controller,
    webview: *c.ICoreWebView2,

    bridge: bridge_mod.Bridge = .{},
    /// Set when the user closed the window or the page called `window.close()`.
    closed: bool = false,

    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    /// The page's element is fullscreen: the window is borderless over its monitor.
    fullscreen: bool = false,
    restore_placement: c.WINDOWPLACEMENT = undefined,
    /// The ring's size the transport was injected for; 0 before `injectTransport`.
    transport_len: usize = 0,
    last_state: u32 = 0,

    /// No title bar: the page draws its own (`setDecorations(false)`).
    frameless: bool = false,
    chrome: chrome_mod.Chrome = .{},

    owner: window.Owner = undefined,
    owned: bool = false,
    resources: c.ICoreWebView2WebResourceRequestedEventHandler = Resources.make(),
    titles: c.ICoreWebView2DocumentTitleChangedEventHandler = Titles.make(),
    close_requests: c.ICoreWebView2WindowCloseRequestedEventHandler = CloseRequests.make(),
    new_windows: c.ICoreWebView2NewWindowRequestedEventHandler = NewWindows.make(),
    navigations: c.ICoreWebView2NavigationStartingEventHandler = Navigations.make(),
    fullscreens: c.ICoreWebView2ContainsFullScreenElementChangedEventHandler = Fullscreens.make(),
    script_added: c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = ScriptAdded.make(),
    permission_requests: c.ICoreWebView2PermissionRequestedEventHandler = permissions.Handler.make(),
    downloads_starting: c.ICoreWebView2DownloadStartingEventHandler = downloads.Handler.make(),

    /// Finds the runtime, opens a hidden window and brings the engine up in it.
    pub fn open() Error!View {
        window.becomeDpiAware();
        const com = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
        if (com != c.S_OK and com != c.S_FALSE) return error.Com;

        var dir_buffer: [c.MAX_PATH]u16 = undefined;
        const dir = runtime.directory(&dir_buffer) orelse return error.NoRuntime;
        const create = runtime.load(dir) orelse return error.NoRuntime;
        var version: [96]u8 = undefined;
        const named = std.fmt.bufPrint(&version_text, "WebView2 {s}", .{runtime.version(dir, &version)}) catch "WebView2";
        version_len = named.len;

        const hwnd = window.open(800, 600) orelse return error.NoWindow;
        errdefer _ = c.DestroyWindow(hwnd);

        startup = .{};
        const folder: ?[*:0]const u16 = if (data_set) &data_directory else null;
        if (!wv.ok(create(true, 0, folder, null, &environment_done))) return error.Environment;
        try waitFor(environmentArrived);
        const environment = startup.environment.?;
        errdefer _ = environment.lpVtbl.*.Release.?(environment);

        if (!wv.ok(environment.lpVtbl.*.CreateCoreWebView2Controller.?(environment, hwnd, &controller_done))) return error.Controller;
        waitFor(controllerArrived) catch return error.Controller;
        const controller = startup.controller.?;
        errdefer _ = controller.lpVtbl.*.Release.?(controller);

        var core: [*c]c.ICoreWebView2 = null;
        if (!wv.ok(controller.lpVtbl.*.get_CoreWebView2.?(controller, &core)) or core == null) return error.Controller;
        configure(core);
        return .{ .window = hwnd, .environment = environment, .controller = controller, .webview = core };
    }

    /// Developer tools, the default context menu and the browser's own keys (F5, Ctrl+F,
    /// Ctrl+P) in Debug builds only — WPE draws no context menu and binds no key, and a
    /// shipped application is not a browser. The status bar (a link's URL at the bottom)
    /// never.
    pub fn configure(core: *c.ICoreWebView2) void {
        var settings: [*c]c.ICoreWebView2Settings = null;
        if (!wv.ok(core.lpVtbl.*.get_Settings.?(core, &settings)) or settings == null) return;
        defer _ = settings.*.lpVtbl.*.Release.?(settings);
        const debug: c.BOOL = if (builtin.mode == std.builtin.OptimizeMode.Debug) c.TRUE else c.FALSE;
        _ = settings.*.lpVtbl.*.put_AreDevToolsEnabled.?(settings, debug);
        _ = settings.*.lpVtbl.*.put_AreDefaultContextMenusEnabled.?(settings, debug);
        _ = settings.*.lpVtbl.*.put_IsStatusBarEnabled.?(settings, c.FALSE);
        var third: ?*c.ICoreWebView2Settings3 = null;
        if (wv.ok(settings.*.lpVtbl.*.QueryInterface.?(settings, &c.IID_ICoreWebView2Settings3, @ptrCast(&third)))) {
            if (third) |keys| {
                _ = keys.lpVtbl.*.put_AreBrowserAcceleratorKeysEnabled.?(keys, debug);
                _ = keys.lpVtbl.*.Release.?(keys);
            }
        }
    }

    /// Hands the window's events to this view. `self` is the address the window keeps.
    fn own(self: *View) void {
        if (self.owned) return;
        self.owned = true;
        self.owner = .{
            .context = self,
            .resized = &onResized,
            .state_changed = &onStateChanged,
            .close_requested = &onCloseRequested,
            .moved = &onMoved,
        };
        window.attach(self.window, &self.owner);
        // The title bar takes the page's `theme-color` and `color-scheme` (`chrome.zig`).
        self.chrome.followTheme(self.window, self.webview, &self.bridge);
    }

    /// Sizes the window's client area to `width` × `height` logical pixels.
    pub fn resized(self: *View, width: i32, height: i32) void {
        window.setClientSize(self.window, @intCast(@max(width, 1)), @intCast(@max(height, 1)), self.frameless);
        self.fitController();
    }

    pub fn map(self: *View) void {
        self.own();
        window.show(self.window);
        _ = self.controller.lpVtbl.*.put_IsVisible.?(self.controller, c.TRUE);
        self.fitController();
        _ = self.controller.lpVtbl.*.MoveFocus.?(self.controller, c.COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }

    fn fitController(self: *View) void {
        var rect: c.RECT = undefined;
        if (c.GetClientRect(self.window, &rect) != 0) _ = self.controller.lpVtbl.*.put_Bounds.?(self.controller, rect);
    }

    /// Titles the window `title`, then follows the page's `document.title`, falling back
    /// to `title` whenever the page has none.
    pub fn setTitle(self: *View, title: []const u8) void {
        const kept = title[0..@min(title.len, self.title.len - 1)];
        @memcpy(self.title[0..kept.len], kept);
        self.title_len = kept.len;
        self.own();
        var token: c.EventRegistrationToken = undefined;
        _ = self.webview.lpVtbl.*.add_DocumentTitleChanged.?(self.webview, &self.titles, &token);
        self.showTitle();
    }

    fn showTitle(self: *View) void {
        var wide: c.LPWSTR = null;
        var page_buffer: [768]u8 = undefined;
        const page = if (wv.ok(self.webview.lpVtbl.*.get_DocumentTitle.?(self.webview, &wide))) wv.takeString(wide, &page_buffer) else "";
        // A page without `<title>` reads back as its address (WebView2 fills one in);
        // that is not a name the window should carry.
        const own_title = page.len == 0 or std.mem.startsWith(u8, page, "http://") or std.mem.startsWith(u8, page, "https://") or
            std.mem.startsWith(u8, page, "about:") or std.mem.startsWith(u8, page, host);
        window.setTitle(self.window, if (own_title) self.title[0..self.title_len] else page);
    }

    /// Answers `http://lepton.localhost/*` from the bridge, and wires the window's
    /// commands and events to it.
    pub fn startBridge(self: *View) void {
        self.own();
        _ = self.webview.lpVtbl.*.AddWebResourceRequestedFilter.?(self.webview, View.filter, c.COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
        var token: c.EventRegistrationToken = undefined;
        _ = self.webview.lpVtbl.*.add_WebResourceRequested.?(self.webview, &self.resources, &token);
        _ = self.webview.lpVtbl.*.add_NewWindowRequested.?(self.webview, &self.new_windows, &token);
        _ = self.webview.lpVtbl.*.add_NavigationStarting.?(self.webview, &self.navigations, &token);
        _ = self.webview.lpVtbl.*.add_ContainsFullScreenElementChanged.?(self.webview, &self.fullscreens, &token);
        self.bridge.recorder = @import("../record.zig").Recorder.fromEnvironment();
        self.bridge.page_replay = @import("../page_replay.zig").fromEnvironment();
        if (self.bridge.page_replay) |*script| script.closeWhenDone(&self.bridge.close_requested);
        permissions.watch(self.webview, &self.bridge, &self.permission_requests);
        downloads.watch(self.webview, &self.bridge, &self.downloads_starting);
        self.bridge.window = .{ .context = self, .act = &windowAct, .state = &windowState, .permission = &permissions.answer, .start_drag = &windowDrag, .menu = &windowMenu };
        self.last_state = self.stateBits();
    }

    /// The window going away — the user, or the page's `window.close()` — ends the run.
    pub fn watchClose(self: *View) void {
        self.own();
        var token: c.EventRegistrationToken = undefined;
        _ = self.webview.lpVtbl.*.add_WindowCloseRequested.?(self.webview, &self.close_requests, &token);
    }

    /// `globalThis.__lepton` before every document's own scripts, sized for the ring.
    pub fn injectTransport(self: *View, region_len: usize) bool {
        self.transport_len = region_len;
        return self.addTransportTo(self.webview);
    }

    /// The same transport for another view of this application (`popup.zig`).
    pub fn addTransportTo(self: *View, core: *c.ICoreWebView2) bool {
        if (self.transport_len == 0) return false;
        var source: [16384]u8 = undefined;
        const text = transport.script(&source, self.transport_len, &self.bridge.registry, self.bridge.pageOrigin()) catch return false;
        var wide: [16384:0]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], text) catch return false;
        wide[units] = 0;
        return wv.ok(core.lpVtbl.*.AddScriptToExecuteOnDocumentCreated.?(core, &wide, &self.script_added));
    }

    pub fn load(self: *View, location: [:0]const u8) void {
        var wide: [4096:0]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], location) catch return;
        wide[units] = 0;
        _ = self.webview.lpVtbl.*.Navigate.?(self.webview, &wide);
    }

    pub fn close(self: *View) void {
        popup.closeAll();
        if (self.bridge.recorder) |*recorder| recorder.close();
        _ = self.controller.lpVtbl.*.Close.?(self.controller);
        _ = self.webview.lpVtbl.*.Release.?(self.webview);
        _ = self.controller.lpVtbl.*.Release.?(self.controller);
        _ = self.environment.lpVtbl.*.Release.?(self.environment);
        _ = c.DestroyWindow(self.window);
        self.* = undefined;
    }

    // --- window commands and events ---------------------------------------------------------

    fn stateBits(self: *View) u32 {
        var bits = window.stateOf(self.window);
        if (self.fullscreen) bits |= invoke.WindowState.fullscreen;
        return bits;
    }

    fn windowAct(data: ?*anyopaque, action: invoke.WindowAction) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        const show: c_int = switch (action) {
            .minimize => c.SW_MINIMIZE,
            .maximize => c.SW_MAXIMIZE,
            .unmaximize => c.SW_RESTORE,
        };
        _ = c.ShowWindow(self.window, show);
        return true;
    }

    fn windowDrag(data: ?*anyopaque) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        return window.startDrag(self.window);
    }

    fn windowMenu(data: ?*anyopaque, menu: []const u8, later: invoke.Later) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        return chrome_mod.showMenu(self.window, menu, later);
    }

    /// With `false` the window has no title bar and the page draws its own: it keeps the
    /// resize borders, shadow and snap, and drags the window with `window.start_drag` or
    /// CSS `app-region: drag`. Call before `resized`, which sizes the client area for it.
    pub fn setDecorations(self: *View, decorated: bool) void {
        self.frameless = !decorated;
        self.own();
        window.setFrameless(self.window, self.frameless);
        if (self.frameless) _ = chrome_mod.allowDragRegions(self.webview);
    }

    fn windowState(data: ?*anyopaque) ?u32 {
        const self: *View = @ptrCast(@alignCast(data orelse return null));
        return self.stateBits();
    }

    fn onResized(context: *anyopaque, _: u32, _: u32) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.fitController();
        const size = window.logicalClientSize(self.window);
        if (size[0] != 0 and size[1] != 0) {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, bytes[0..4], size[0], .little);
            std.mem.writeInt(u32, bytes[4..8], size[1], .little);
            _ = self.bridge.emit(events.window_resized, &bytes) catch {};
        }
        onStateChanged(context);
    }

    fn onStateChanged(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        const bits = self.stateBits();
        if (bits == self.last_state) return;
        self.last_state = bits;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, bits, .little);
        _ = self.bridge.emit(events.window_state, &bytes) catch {};
    }

    fn onCloseRequested(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        self.closed = true;
        // Wakes `pumpBlocking`, which may be asleep until the next timer.
        _ = c.PostMessageW(self.window, c.WM_NULL, 0, 0);
    }

    fn onMoved(context: *anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context));
        _ = self.controller.lpVtbl.*.NotifyParentWindowPositionChanged.?(self.controller);
    }

    /// The page's element went fullscreen or back: the window follows, borderless over
    /// its monitor, and `window.state` says so.
    fn setFullscreen(self: *View, on: bool) void {
        if (on == self.fullscreen) return;
        self.fullscreen = on;
        if (on) {
            self.restore_placement.length = @sizeOf(c.WINDOWPLACEMENT);
            _ = c.GetWindowPlacement(self.window, &self.restore_placement);
            const monitor = c.MonitorFromWindow(self.window, c.MONITOR_DEFAULTTONEAREST);
            var info: c.MONITORINFO = undefined;
            info.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(monitor, &info) == 0) return;
            const style = c.GetWindowLongW(self.window, c.GWL_STYLE);
            _ = c.SetWindowLongW(self.window, c.GWL_STYLE, style & ~@as(c_long, c.WS_OVERLAPPEDWINDOW));
            const r = info.rcMonitor;
            _ = c.SetWindowPos(self.window, c.HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_FRAMECHANGED | c.SWP_NOOWNERZORDER);
        } else {
            const style = c.GetWindowLongW(self.window, c.GWL_STYLE);
            _ = c.SetWindowLongW(self.window, c.GWL_STYLE, style | @as(c_long, c.WS_OVERLAPPEDWINDOW));
            _ = c.SetWindowPlacement(self.window, &self.restore_placement);
            _ = c.SetWindowPos(self.window, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
        }
        onStateChanged(self);
    }
};

// --- event handlers, each embedded in the view and finding it by field -------------------

fn viewOf(comptime field: []const u8, pointer: anytype) *View {
    const typed: *@FieldType(View, field) = @ptrCast(pointer);
    return @alignCast(@fieldParentPtr(field, typed));
}

fn onResource(
    this: [*c]c.ICoreWebView2WebResourceRequestedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2WebResourceRequestedEventArgs,
) callconv(.winapi) c.HRESULT {
    const self = viewOf("resources", this);
    const pending = request.begin(self.environment, args) orelse return c.S_OK;
    self.bridge.deliver(pending);
    // The event's own reference: a request the bridge kept (`ref`) lives on.
    request.unref(pending);
    return c.S_OK;
}

fn onTitle(this: [*c]c.ICoreWebView2DocumentTitleChangedEventHandler, _: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    viewOf("titles", this).showTitle();
    return c.S_OK;
}

fn onCloseRequest(this: [*c]c.ICoreWebView2WindowCloseRequestedEventHandler, _: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    View.onCloseRequested(viewOf("close_requests", this));
    return c.S_OK;
}

/// Links that leave the application open in the user's browser, as on Linux
/// (`features.isExternal`); anything else stays in this window.
fn openExternally(uri: []const u8) void {
    // `ShellExecuteW` runs whatever handler a scheme has: only the web and mail.
    if (!features.mayOpenOutside(uri)) return;
    var wide: [4096:0]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], uri[0..@min(uri.len, 4000)]) catch return;
    wide[units] = 0;
    _ = c.ShellExecuteW(null, W("open"), &wide, null, null, c.SW_SHOWNORMAL);
}

fn onNewWindow(this: [*c]c.ICoreWebView2NewWindowRequestedEventHandler, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) c.HRESULT {
    var wide: c.LPWSTR = null;
    var buffer: [4096 * 3]u8 = undefined;
    const uri = if (wv.ok(args.*.lpVtbl.*.get_Uri.?(args, &wide))) wv.takeString(wide, &buffer) else "";
    // Never WebView2's own browser window: it would have no channel to the core. The
    // application's pages open in a window of its own (`popup.zig`), the web in the
    // user's browser.
    _ = args.*.lpVtbl.*.put_Handled.?(args, c.TRUE);
    if (!features.isOwnPage(uri)) {
        openExternally(uri);
    } else {
        _ = popup.open(viewOf("new_windows", this), args);
    }
    return c.S_OK;
}

fn onNavigation(_: [*c]c.ICoreWebView2NavigationStartingEventHandler, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) c.HRESULT {
    var wide: c.LPWSTR = null;
    var buffer: [4096 * 3]u8 = undefined;
    const uri = if (wv.ok(args.*.lpVtbl.*.get_Uri.?(args, &wide))) wv.takeString(wide, &buffer) else "";
    // Any way the window's document leaves the application — a link, a script setting
    // `location`, a form — ends here: `NavigationStarting` is the top document's.
    if (!features.isOwnPage(uri)) {
        _ = args.*.lpVtbl.*.put_Cancel.?(args, c.TRUE);
        openExternally(uri);
    }
    return c.S_OK;
}

fn onFullscreen(this: [*c]c.ICoreWebView2ContainsFullScreenElementChangedEventHandler, sender: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    var contains: c.BOOL = c.FALSE;
    _ = sender.*.lpVtbl.*.get_ContainsFullScreenElement.?(sender, &contains);
    viewOf("fullscreens", this).setFullscreen(contains != c.FALSE);
    return c.S_OK;
}

fn onScriptAdded(_: [*c]c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, _: c.HRESULT, _: c.LPCWSTR) callconv(.winapi) c.HRESULT {
    return c.S_OK;
}

const Resources = wv.Handler(c.ICoreWebView2WebResourceRequestedEventHandler, c.ICoreWebView2WebResourceRequestedEventHandlerVtbl, &c.IID_ICoreWebView2WebResourceRequestedEventHandler, onResource);
const Titles = wv.Handler(c.ICoreWebView2DocumentTitleChangedEventHandler, c.ICoreWebView2DocumentTitleChangedEventHandlerVtbl, &c.IID_ICoreWebView2DocumentTitleChangedEventHandler, onTitle);
const CloseRequests = wv.Handler(c.ICoreWebView2WindowCloseRequestedEventHandler, c.ICoreWebView2WindowCloseRequestedEventHandlerVtbl, &c.IID_ICoreWebView2WindowCloseRequestedEventHandler, onCloseRequest);
const NewWindows = wv.Handler(c.ICoreWebView2NewWindowRequestedEventHandler, c.ICoreWebView2NewWindowRequestedEventHandlerVtbl, &c.IID_ICoreWebView2NewWindowRequestedEventHandler, onNewWindow);
const Navigations = wv.Handler(c.ICoreWebView2NavigationStartingEventHandler, c.ICoreWebView2NavigationStartingEventHandlerVtbl, &c.IID_ICoreWebView2NavigationStartingEventHandler, onNavigation);
const Fullscreens = wv.Handler(c.ICoreWebView2ContainsFullScreenElementChangedEventHandler, c.ICoreWebView2ContainsFullScreenElementChangedEventHandlerVtbl, &c.IID_ICoreWebView2ContainsFullScreenElementChangedEventHandler, onFullscreen);
const ScriptAdded = wv.Handler(c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl, &c.IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, onScriptAdded);

/// Whether this build contains the WebView2 path.
pub fn is_available() bool {
    return @import("build_options").have_webview2;
}
