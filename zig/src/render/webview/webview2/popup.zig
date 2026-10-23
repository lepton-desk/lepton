//! `window.open` of the application's own pages: a second window with its own WebView2,
//! reaching the same core — the counterpart of Linux's related view (`features.zig`).
//!
//! WebView2 asks through `NewWindowRequested`; the request is deferred while a controller
//! is made in a new window from the same environment, then handed back with
//! `put_NewWindow`, so the opener gets a working `WindowProxy`. The new view gets the same
//! settings, the same `__lepton` transport and the same request filter, answered by the
//! main view's bridge. Up to four at once; a fifth is refused.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const window = @import("../../../window/windows/window.zig");
const request = @import("request.zig");
const View = @import("view.zig").View;
const permissions = @import("permissions.zig");
const downloads = @import("downloads.zig");

const Popup = struct {
    used: bool = false,
    host: ?*View = null,
    hwnd: c.HWND = null,
    controller: ?*c.ICoreWebView2Controller = null,
    webview: ?*c.ICoreWebView2 = null,
    args: ?*c.ICoreWebView2NewWindowRequestedEventArgs = null,
    deferral: ?*c.ICoreWebView2Deferral = null,
    owner: window.Owner = undefined,
    created: c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = Created.make(),
    resources: c.ICoreWebView2WebResourceRequestedEventHandler = Resources.make(),
    titles: c.ICoreWebView2DocumentTitleChangedEventHandler = Titles.make(),
    closes: c.ICoreWebView2WindowCloseRequestedEventHandler = Closes.make(),
};
var popups: [4]Popup = @splat(.{});

/// Opens the requested page in a new window of this application. False when there is no
/// room or the window could not be made; the caller then leaves the request handled.
pub fn open(host: *View, args: *c.ICoreWebView2NewWindowRequestedEventArgs) bool {
    const slot = for (&popups) |*entry| {
        if (!entry.used) break entry;
    } else return false;
    const hwnd = window.open(900, 700) orelse return false;
    var deferral: [*c]c.ICoreWebView2Deferral = null;
    if (!wv.ok(args.lpVtbl.*.GetDeferral.?(args, &deferral)) or deferral == null) {
        _ = c.DestroyWindow(hwnd);
        return false;
    }
    _ = args.lpVtbl.*.AddRef.?(args);
    slot.* = .{ .used = true, .host = host, .hwnd = hwnd, .args = args, .deferral = deferral };
    slot.owner = .{ .context = slot, .resized = &onResized, .state_changed = &onState, .close_requested = &onClose, .moved = &onMoved };
    window.attach(hwnd, &slot.owner);
    const environment = host.environment;
    if (!wv.ok(environment.lpVtbl.*.CreateCoreWebView2Controller.?(environment, hwnd, &slot.created))) {
        finishRequest(slot);
        close(slot);
        return false;
    }
    return true;
}

fn slotOf(comptime field: []const u8, handler: anytype) *Popup {
    const typed: *@FieldType(Popup, field) = @ptrCast(handler);
    return @alignCast(@fieldParentPtr(field, typed));
}

/// Completes the opener's request (with or without a new window) and drops it.
fn finishRequest(slot: *Popup) void {
    if (slot.deferral) |deferral| {
        _ = deferral.lpVtbl.*.Complete.?(deferral);
        _ = deferral.lpVtbl.*.Release.?(deferral);
    }
    if (slot.args) |args| _ = args.lpVtbl.*.Release.?(args);
    slot.deferral = null;
    slot.args = null;
}

fn onCreated(
    this: [*c]c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    hr: c.HRESULT,
    controller: [*c]c.ICoreWebView2Controller,
) callconv(.winapi) c.HRESULT {
    const slot = slotOf("created", this);
    const host = slot.host orelse return c.S_OK;
    if (!wv.ok(hr) or controller == null) {
        finishRequest(slot);
        close(slot);
        return c.S_OK;
    }
    _ = controller.*.lpVtbl.*.AddRef.?(controller);
    slot.controller = controller;
    var core: [*c]c.ICoreWebView2 = null;
    if (!wv.ok(controller.*.lpVtbl.*.get_CoreWebView2.?(controller, &core)) or core == null) {
        finishRequest(slot);
        close(slot);
        return c.S_OK;
    }
    slot.webview = core;
    View.configure(core);
    _ = host.addTransportTo(core);
    var token: c.EventRegistrationToken = undefined;
    _ = core.*.lpVtbl.*.AddWebResourceRequestedFilter.?(core, View.filter, c.COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    _ = core.*.lpVtbl.*.add_WebResourceRequested.?(core, &slot.resources, &token);
    _ = core.*.lpVtbl.*.add_DocumentTitleChanged.?(core, &slot.titles, &token);
    _ = core.*.lpVtbl.*.add_WindowCloseRequested.?(core, &slot.closes, &token);
    // The same rule as the main window: a popup that navigates off the application's own
    // pages is stopped and the address goes to the browser. Without it `window.open` of
    // `about:blank` could then be sent anywhere (audit, 2026-10-20). The handler reads only
    // its arguments, so the main view's serves.
    _ = core.*.lpVtbl.*.add_NavigationStarting.?(core, &host.navigations, &token);
    _ = core.*.lpVtbl.*.add_NewWindowRequested.?(core, &host.new_windows, &token);
    // `webPermissions` and downloads, as in the main window: a popup asked the engine for a
    // camera or saved a file past the application's policy (`docs/durum.md`). Both
    // handlers read only their arguments and the one bridge, so the main view's serve.
    permissions.watch(core, &host.bridge, &host.permission_requests);
    downloads.watch(core, &host.bridge, &host.downloads_starting);
    if (slot.args) |args| _ = args.lpVtbl.*.put_NewWindow.?(args, core);
    finishRequest(slot);
    window.show(slot.hwnd);
    _ = controller.*.lpVtbl.*.put_IsVisible.?(controller, c.TRUE);
    fit(slot);
    return c.S_OK;
}

fn fit(slot: *Popup) void {
    const controller = slot.controller orelse return;
    var rect: c.RECT = undefined;
    if (c.GetClientRect(slot.hwnd, &rect) != 0) _ = controller.lpVtbl.*.put_Bounds.?(controller, rect);
}

fn close(slot: *Popup) void {
    if (slot.controller) |controller| {
        _ = controller.lpVtbl.*.Close.?(controller);
        _ = controller.lpVtbl.*.Release.?(controller);
    }
    if (slot.webview) |core| _ = core.lpVtbl.*.Release.?(core);
    if (slot.hwnd != null) _ = c.DestroyWindow(slot.hwnd);
    slot.* = .{};
}

/// Closes every popup, before the main view goes.
pub fn closeAll() void {
    for (&popups) |*slot| {
        if (slot.used) {
            finishRequest(slot);
            close(slot);
        }
    }
}

fn onResized(context: *anyopaque, _: u32, _: u32) void {
    fit(@ptrCast(@alignCast(context)));
}

fn onState(_: *anyopaque) void {}

fn onClose(context: *anyopaque) void {
    close(@ptrCast(@alignCast(context)));
}

fn onMoved(context: *anyopaque) void {
    const slot: *Popup = @ptrCast(@alignCast(context));
    if (slot.controller) |controller| _ = controller.lpVtbl.*.NotifyParentWindowPositionChanged.?(controller);
}

fn onResource(
    this: [*c]c.ICoreWebView2WebResourceRequestedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2WebResourceRequestedEventArgs,
) callconv(.winapi) c.HRESULT {
    const slot = slotOf("resources", this);
    const host = slot.host orelse return c.S_OK;
    const pending = request.begin(host.environment, args) orelse return c.S_OK;
    host.bridge.deliver(pending);
    request.unref(pending);
    return c.S_OK;
}

fn onTitle(this: [*c]c.ICoreWebView2DocumentTitleChangedEventHandler, sender: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    const slot = slotOf("titles", this);
    var wide: c.LPWSTR = null;
    var text: [768]u8 = undefined;
    const title = if (wv.ok(sender.*.lpVtbl.*.get_DocumentTitle.?(sender, &wide))) wv.takeString(wide, &text) else "";
    window.setTitle(slot.hwnd, title);
    return c.S_OK;
}

fn onCloseRequest(this: [*c]c.ICoreWebView2WindowCloseRequestedEventHandler, _: [*c]c.ICoreWebView2, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    close(slotOf("closes", this));
    return c.S_OK;
}

const Created = wv.Handler(c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl, &c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, onCreated);
const Resources = wv.Handler(c.ICoreWebView2WebResourceRequestedEventHandler, c.ICoreWebView2WebResourceRequestedEventHandlerVtbl, &c.IID_ICoreWebView2WebResourceRequestedEventHandler, onResource);
const Titles = wv.Handler(c.ICoreWebView2DocumentTitleChangedEventHandler, c.ICoreWebView2DocumentTitleChangedEventHandlerVtbl, &c.IID_ICoreWebView2DocumentTitleChangedEventHandler, onTitle);
const Closes = wv.Handler(c.ICoreWebView2WindowCloseRequestedEventHandler, c.ICoreWebView2WindowCloseRequestedEventHandlerVtbl, &c.IID_ICoreWebView2WindowCloseRequestedEventHandler, onCloseRequest);
