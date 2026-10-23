//! The page's `new Notification(…)` as a Windows notification from the application itself.
//!
//! Left to WebView2, a notification the policy allows appears in WebView2's own popup,
//! headed by the core's origin — "lepton.localhost" (measured, 2026-10-23) — not the
//! application. So the view takes it (`ICoreWebView2_24::add_NotificationReceived`,
//! `put_Handled`) and shows it through Windows' toast notifier under the process's
//! AppUserModelID (the identifier, `view.useApplicationDirectories`), whose name Windows
//! reads from `HKCU\Software\Classes\AppUserModelId\<id>` → `DisplayName` (the product).
//! A toast that cannot be made is left to WebView2, which then shows its own.
//!
//! Windows' events arrive on another thread and WebView2 is called on its own only: they are
//! posted to a message-only window of this thread, which reports them to the page
//! (`ReportClicked`, `ReportClosed`). `notification.close()` hides the toast.
//!
//! WinRT is reached by its ABI from the Windows SDK's `windows.ui.notifications.h` and
//! `windows.data.xml.dom.h` (10.0.26100): the interface ids and the order of each vtable
//! below are copied from there. combase.dll is loaded at run time.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const policy = @import("../permissions.zig");

pub const Handler = wv.Handler(
    c.ICoreWebView2NotificationReceivedEventHandler,
    c.ICoreWebView2NotificationReceivedEventHandlerVtbl,
    &c.IID_ICoreWebView2NotificationReceivedEventHandler,
    onReceived,
);

const CloseRequested = wv.Handler(
    c.ICoreWebView2NotificationCloseRequestedEventHandler,
    c.ICoreWebView2NotificationCloseRequestedEventHandlerVtbl,
    &c.IID_ICoreWebView2NotificationCloseRequestedEventHandler,
    onCloseRequested,
);

/// Takes this view's notifications (`ICoreWebView2_24`, runtime 1.0.2739+); without it,
/// WebView2 keeps showing its own.
pub fn watch(webview: *c.ICoreWebView2, handler: *c.ICoreWebView2NotificationReceivedEventHandler) void {
    var later: ?*c.ICoreWebView2_24 = null;
    if (!wv.ok(webview.lpVtbl.*.QueryInterface.?(webview, &c.IID_ICoreWebView2_24, @ptrCast(&later)))) return;
    const view = later orelse return;
    defer _ = view.lpVtbl.*.Release.?(view);
    var token: c.EventRegistrationToken = undefined;
    _ = view.lpVtbl.*.add_NotificationReceived.?(view, handler, &token);
}

// ── WinRT, by its ABI ─────────────────────────────────────────────────────────────────

const HString = ?*opaque {};
const Hresult = c.HRESULT;

fn guid(comptime text: *const [36]u8) c.GUID {
    const hex = struct {
        fn value(comptime s: []const u8) u64 {
            return std.fmt.parseInt(u64, s, 16) catch @compileError("bad guid");
        }
    }.value;
    return comptime blk: {
        var tail: [8]u8 = undefined;
        for (0..2) |at| tail[at] = @intCast(hex(text[19 + at * 2 ..][0..2]));
        for (0..6) |at| tail[2 + at] = @intCast(hex(text[24 + at * 2 ..][0..2]));
        break :blk .{ .Data1 = @intCast(hex(text[0..8])), .Data2 = @intCast(hex(text[9..13])), .Data3 = @intCast(hex(text[14..18])), .Data4 = tail };
    };
}

const iid_manager_statics = guid("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
const iid_toast_factory = guid("04124b20-82c6-4229-b109-fd9ed4662b53");
const iid_xml_document = guid("f7f3a506-1e87-42d6-bcfb-b8c809fa5494");
const iid_xml_document_io = guid("6cd0e74e-ee65-4489-9ebf-ca43e87ba637");
/// `TypedEventHandler<ToastNotification, Object>` (Activated) and
/// `TypedEventHandler<ToastNotification, ToastDismissedEventArgs>` (Dismissed).
const iid_activated = guid("ab54de2d-97d9-5528-b6ad-105afe156530");
const iid_dismissed = guid("61c2402f-0ed0-5a18-ab69-59f4aa99a368");
const iid_unknown = guid("00000000-0000-0000-c000-000000000046");
const iid_agile = guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");

/// `IInspectable`'s six slots, ahead of every WinRT interface's own.
const Inspectable = extern struct {
    query: *const fn (*anyopaque, *const c.GUID, *?*anyopaque) callconv(.winapi) Hresult,
    add_ref: *const fn (*anyopaque) callconv(.winapi) u32,
    release: *const fn (*anyopaque) callconv(.winapi) u32,
    get_iids: *const anyopaque,
    get_runtime_class_name: *const anyopaque,
    get_trust_level: *const anyopaque,
};

fn Object(comptime Vtbl: type) type {
    return extern struct { vtbl: *const Vtbl };
}

const ManagerStatics = Object(extern struct {
    base: Inspectable,
    create_toast_notifier: *const anyopaque,
    create_toast_notifier_with_id: *const fn (*anyopaque, HString, *?*Notifier) callconv(.winapi) Hresult,
    get_template_content: *const anyopaque,
});
const Notifier = Object(extern struct {
    base: Inspectable,
    show: *const fn (*anyopaque, *Toast) callconv(.winapi) Hresult,
    hide: *const fn (*anyopaque, *Toast) callconv(.winapi) Hresult,
});
const ToastFactory = Object(extern struct {
    base: Inspectable,
    create_toast_notification: *const fn (*anyopaque, *anyopaque, *?*Toast) callconv(.winapi) Hresult,
});
const Toast = Object(extern struct {
    base: Inspectable,
    get_content: *const anyopaque,
    put_expiration_time: *const anyopaque,
    get_expiration_time: *const anyopaque,
    add_dismissed: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) Hresult,
    remove_dismissed: *const anyopaque,
    add_activated: *const fn (*anyopaque, *anyopaque, *i64) callconv(.winapi) Hresult,
    remove_activated: *const anyopaque,
});
const XmlDocumentIo = Object(extern struct {
    base: Inspectable,
    load_xml: *const fn (*anyopaque, HString) callconv(.winapi) Hresult,
});

fn release(object: anytype) void {
    _ = object.vtbl.base.release(@ptrCast(object));
}

/// combase.dll's string and activation calls, loaded once.
const Ro = struct {
    create_string: *const fn ([*]const u16, u32, *HString) callconv(.winapi) Hresult,
    delete_string: *const fn (HString) callconv(.winapi) Hresult,
    get_factory: *const fn (HString, *const c.GUID, *?*anyopaque) callconv(.winapi) Hresult,
    activate: *const fn (HString, *?*anyopaque) callconv(.winapi) Hresult,

    var loaded: ?Ro = null;
    var tried = false;

    fn get() ?Ro {
        if (tried) return loaded;
        tried = true;
        const library = c.LoadLibraryW(wv.W("combase.dll")) orelse return null;
        loaded = .{
            .create_string = @ptrCast(c.GetProcAddress(library, "WindowsCreateString") orelse return null),
            .delete_string = @ptrCast(c.GetProcAddress(library, "WindowsDeleteString") orelse return null),
            .get_factory = @ptrCast(c.GetProcAddress(library, "RoGetActivationFactory") orelse return null),
            .activate = @ptrCast(c.GetProcAddress(library, "RoActivateInstance") orelse return null),
        };
        return loaded;
    }

    fn string(self: Ro, units: []const u16) ?HString {
        var made: HString = null;
        if (self.create_string(units.ptr, @intCast(units.len), &made) < 0) return null;
        return made;
    }
};

// ── One notification on screen ───────────────────────────────────────────────────────

/// Windows' Activated or Dismissed for one slot: a delegate object of our own, posted on.
const Delegate = extern struct {
    vtbl: *const Vtbl,
    slot: u8,
    event: u16,

    const Vtbl = extern struct {
        query: *const fn (*Delegate, *const c.GUID, *?*anyopaque) callconv(.winapi) Hresult,
        add_ref: *const fn (*Delegate) callconv(.winapi) u32,
        release: *const fn (*Delegate) callconv(.winapi) u32,
        invoke: *const fn (*Delegate, ?*anyopaque, ?*anyopaque) callconv(.winapi) Hresult,
    };
    const vtbl_value: Vtbl = .{ .query = query, .add_ref = addRef, .release = releaseDelegate, .invoke = invoke };

    fn query(self: *Delegate, iid: *const c.GUID, out: *?*anyopaque) callconv(.winapi) Hresult {
        const wanted = if (self.event == activated_message) iid_activated else iid_dismissed;
        if (same(iid, &wanted) or same(iid, &iid_unknown) or same(iid, &iid_agile)) {
            out.* = self;
            return c.S_OK;
        }
        out.* = null;
        return c.E_NOINTERFACE;
    }
    // Static objects, one pair per slot: counting would free nothing.
    fn addRef(_: *Delegate) callconv(.winapi) u32 {
        return 1;
    }
    fn releaseDelegate(_: *Delegate) callconv(.winapi) u32 {
        return 1;
    }
    fn invoke(self: *Delegate, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) Hresult {
        if (message_window) |window| _ = c.PostMessageW(window, self.event, self.slot, 0);
        return c.S_OK;
    }
};

fn same(a: *const c.GUID, b: *const c.GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// `WM_APP` + 1 and + 2: posted from Windows' threads to `message_window`. Not 0x81/0x82,
/// which are `WM_NCCREATE`/`WM_NCDESTROY`: the window refused to be made (measured).
const activated_message: u16 = c.WM_APP + 1;
const dismissed_message: u16 = c.WM_APP + 2;

const Slot = struct {
    notification: ?*c.ICoreWebView2Notification = null,
    toast: ?*Toast = null,
    /// The toast's XML document, released with it (`Made`).
    content: ?*anyopaque = null,
    activated: Delegate,
    dismissed: Delegate,
    close_requested: c.ICoreWebView2NotificationCloseRequestedEventHandler = CloseRequested.make(),
};

var slots: [8]Slot = blk: {
    var made: [8]Slot = undefined;
    for (&made, 0..) |*slot, index| slot.* = .{
        .activated = .{ .vtbl = &Delegate.vtbl_value, .slot = index, .event = activated_message },
        .dismissed = .{ .vtbl = &Delegate.vtbl_value, .slot = index, .event = dismissed_message },
    };
    break :blk made;
};
var next_slot: usize = 0;
var notifier: ?*Notifier = null;
var message_window: c.HWND = null;

fn onReceived(
    _: [*c]c.ICoreWebView2NotificationReceivedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2NotificationReceivedEventArgs,
) callconv(.winapi) c.HRESULT {
    var got: [*c]c.ICoreWebView2Notification = null;
    if (!wv.ok(args.*.lpVtbl.*.get_Notification.?(args, &got)) or got == null) return c.S_OK;
    const notification: *c.ICoreWebView2Notification = got;
    if (show(notification)) {
        // Taken first, then reported: reported while WebView2 still owned it, the page's
        // `onshow` never ran (measured).
        _ = args.*.lpVtbl.*.put_Handled.?(args, c.TRUE);
        _ = notification.lpVtbl.*.ReportShown.?(notification);
    } else {
        _ = notification.lpVtbl.*.Release.?(notification);
    }
    return c.S_OK;
}

/// Shows `notification` as a toast; false (and nothing kept) when Windows refused a step.
fn show(notification: *c.ICoreWebView2Notification) bool {
    const ro = Ro.get() orelse return false;
    const toasts = toastNotifier(ro) orelse return false;
    if (!ensureMessageWindow()) return false;

    var title_wide: c.LPWSTR = null;
    var body_wide: c.LPWSTR = null;
    _ = notification.lpVtbl.*.get_Title.?(notification, &title_wide);
    _ = notification.lpVtbl.*.get_Body.?(notification, &body_wide);
    var title: [512]u8 = undefined;
    var body: [2048]u8 = undefined;
    var xml: [8192]u8 = undefined;
    const text = toastXml(&xml, wv.takeString(title_wide, &title), wv.takeString(body_wide, &body)) orelse return false;
    const made = makeToast(ro, text) orelse return false;
    const toast = made.toast;

    // The oldest slot makes room: its toast is hidden and the page told it closed.
    const index = next_slot;
    next_slot = (next_slot + 1) % slots.len;
    finish(index, true);
    const slot = &slots[index];
    var token: i64 = 0;
    _ = toast.vtbl.add_activated(@ptrCast(toast), @ptrCast(&slot.activated), &token);
    _ = toast.vtbl.add_dismissed(@ptrCast(toast), @ptrCast(&slot.dismissed), &token);
    slot.toast = toast;
    slot.content = made.content;
    if (toasts.vtbl.show(@ptrCast(toasts), toast) < 0) {
        finish(index, false);
        return false;
    }
    slot.notification = notification;
    var close_token: c.EventRegistrationToken = undefined;
    _ = notification.lpVtbl.*.add_CloseRequested.?(notification, &slot.close_requested, &close_token);
    return true;
}

/// `<toast>` with the title and the body, escaped; null when it does not fit.
fn toastXml(out: []u8, title: []const u8, body: []const u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(out);
    writer.writeAll("<toast><visual><binding template=\"ToastGeneric\"><text>") catch return null;
    escape(&writer, title) catch return null;
    writer.writeAll("</text><text>") catch return null;
    escape(&writer, body) catch return null;
    writer.writeAll("</text></binding></visual></toast>") catch return null;
    return writer.buffered();
}

fn escape(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |char| switch (char) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(char),
    };
}

/// The notifier for this process's AppUserModelID, made once; its `DisplayName` registered
/// first, which is what Windows shows as the sender of an application with no shortcut.
fn toastNotifier(ro: Ro) ?*Notifier {
    if (notifier) |made| return made;
    var aumid: [*:0]u16 = undefined;
    if (GetCurrentProcessExplicitAppUserModelID(&aumid) < 0) return null;
    defer c.CoTaskMemFree(aumid);
    const id = std.mem.span(aumid);
    registerName(id);
    const class = ro.string(wv.W("Windows.UI.Notifications.ToastNotificationManager")) orelse return null;
    defer _ = ro.delete_string(class);
    var raw: ?*anyopaque = null;
    if (ro.get_factory(class, &iid_manager_statics, &raw) < 0 or raw == null) return null;
    const statics: *ManagerStatics = @ptrCast(@alignCast(raw.?));
    defer release(statics);
    const name = ro.string(id) orelse return null;
    defer _ = ro.delete_string(name);
    var made: ?*Notifier = null;
    if (statics.vtbl.create_toast_notifier_with_id(@ptrCast(statics), name, &made) < 0) return null;
    notifier = made;
    return made;
}

/// `HKCU\Software\Classes\AppUserModelId\<id>` → `DisplayName` = the product's name.
fn registerName(id: []const u16) void {
    const product = std.mem.span(policy.application().product);
    if (product.len == 0) return;
    var key: [300]u16 = undefined;
    const prefix = wv.W("Software\\Classes\\AppUserModelId\\");
    if (prefix.len + id.len + 1 > key.len) return;
    @memcpy(key[0..prefix.len], prefix);
    @memcpy(key[prefix.len..][0..id.len], id);
    key[prefix.len + id.len] = 0;
    var name: [256]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], product) catch return;
    name[units] = 0;
    _ = RegSetKeyValueW(hkey_current_user, @ptrCast(&key), wv.W("DisplayName"), c.REG_SZ, &name, @intCast((units + 1) * 2));
}

/// A toast and the XML document it was made from. The document is kept as long as the
/// toast: released at once, the notification platform crashed in msxml6 reading it while
/// `Show` ran (measured; keeping this one reference was enough).
const Made = struct { toast: *Toast, content: *anyopaque };

fn makeToast(ro: Ro, xml: []const u8) ?Made {
    var wide: [8192]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(&wide, xml) catch return null;
    const document_class = ro.string(wv.W("Windows.Data.Xml.Dom.XmlDocument")) orelse return null;
    defer _ = ro.delete_string(document_class);
    var document: ?*anyopaque = null;
    if (ro.activate(document_class, &document) < 0 or document == null) return null;
    const inspectable: *Object(Inspectable) = @ptrCast(@alignCast(document.?));
    defer _ = inspectable.vtbl.release(document.?);
    var io_raw: ?*anyopaque = null;
    if (inspectable.vtbl.query(document.?, &iid_xml_document_io, &io_raw) < 0 or io_raw == null) return null;
    const io: *XmlDocumentIo = @ptrCast(@alignCast(io_raw.?));
    defer release(io);
    const text = ro.string(wide[0..units]) orelse return null;
    defer _ = ro.delete_string(text);
    if (io.vtbl.load_xml(@ptrCast(io), text) < 0) return null;
    var xml_document: ?*anyopaque = null;
    if (inspectable.vtbl.query(document.?, &iid_xml_document, &xml_document) < 0 or xml_document == null) return null;
    errdefer _ = inspectable.vtbl.release(xml_document.?);

    const toast_class = ro.string(wv.W("Windows.UI.Notifications.ToastNotification")) orelse return null;
    defer _ = ro.delete_string(toast_class);
    var factory_raw: ?*anyopaque = null;
    if (ro.get_factory(toast_class, &iid_toast_factory, &factory_raw) < 0 or factory_raw == null) return null;
    const factory: *ToastFactory = @ptrCast(@alignCast(factory_raw.?));
    defer release(factory);
    var toast: ?*Toast = null;
    if (factory.vtbl.create_toast_notification(@ptrCast(factory), xml_document.?, &toast) < 0 or toast == null) {
        _ = inspectable.vtbl.release(xml_document.?);
        return null;
    }
    return .{ .toast = toast.?, .content = xml_document.? };
}

/// Lets go of a slot: its toast hidden first when `hide`, the page told it closed.
fn finish(index: usize, hide: bool) void {
    const slot = &slots[index];
    if (slot.toast) |toast| {
        if (hide) if (notifier) |toasts| {
            _ = toasts.vtbl.hide(@ptrCast(toasts), toast);
        };
        release(toast);
        slot.toast = null;
    }
    if (slot.content) |content| {
        const document: *Object(Inspectable) = @ptrCast(@alignCast(content));
        _ = document.vtbl.release(content);
        slot.content = null;
    }
    if (slot.notification) |notification| {
        _ = notification.lpVtbl.*.ReportClosed.?(notification);
        _ = notification.lpVtbl.*.Release.?(notification);
        slot.notification = null;
    }
}

fn onCloseRequested(
    _: [*c]c.ICoreWebView2NotificationCloseRequestedEventHandler,
    sender: [*c]c.ICoreWebView2Notification,
    _: [*c]c.IUnknown,
) callconv(.winapi) c.HRESULT {
    for (&slots, 0..) |*slot, index| {
        if (slot.notification != null and slot.notification.? == @as(*c.ICoreWebView2Notification, sender)) finish(index, true);
    }
    return c.S_OK;
}

// ── Windows' events, back on this thread ─────────────────────────────────────────────

fn ensureMessageWindow() bool {
    if (message_window != null) return true;
    const class_name = wv.W("LeptonNotifications");
    var class = std.mem.zeroes(c.WNDCLASSEXW);
    class.cbSize = @sizeOf(c.WNDCLASSEXW);
    class.lpfnWndProc = procedure;
    class.hInstance = c.GetModuleHandleW(null);
    class.lpszClassName = class_name;
    _ = c.RegisterClassExW(&class);
    // `HWND_MESSAGE` is `(HWND)-3`, an address no Zig `HWND` may hold: the call is declared
    // with the parent as the integer it is.
    message_window = CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, std.math.maxInt(usize) - 2, null, class.hInstance, null);
    return message_window != null;
}

extern "user32" fn CreateWindowExW(ex: c.DWORD, class: [*:0]const u16, name: [*:0]const u16, style: c.DWORD, x: c_int, y: c_int, w: c_int, h: c_int, parent: usize, menu: c.HMENU, instance: c.HINSTANCE, param: ?*anyopaque) callconv(.winapi) c.HWND;
/// `HKEY_CURRENT_USER` is `(HKEY)0x80000001`, which no Zig `HKEY` may hold (it must be
/// aligned): the call is declared with the key as the integer it is.
const hkey_current_user: usize = 0x80000001;
extern "advapi32" fn RegSetKeyValueW(key: usize, sub_key: [*:0]const u16, value: [*:0]const u16, kind: c.DWORD, data: *const anyopaque, size: c.DWORD) callconv(.winapi) c.LONG;
extern "shell32" fn GetCurrentProcessExplicitAppUserModelID(id: *[*:0]u16) callconv(.winapi) c.HRESULT;

fn procedure(window: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const index: usize = @intCast(wparam);
    switch (message) {
        activated_message => if (index < slots.len) {
            if (slots[index].notification) |notification| _ = notification.lpVtbl.*.ReportClicked.?(notification);
            finish(index, false);
            return 0;
        },
        dismissed_message => if (index < slots.len) {
            finish(index, false);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(window, message, wparam, lparam);
}

test "a toast's text is escaped into its template" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "<toast><visual><binding template=\"ToastGeneric\"><text>Saved &amp; synced</text><text>&lt;b&gt;3&lt;/b&gt; &quot;files&quot;</text></binding></visual></toast>",
        toastXml(&out, "Saved & synced", "<b>3</b> \"files\"").?,
    );
}

test "the WinRT ids are the SDK's" {
    const id = guid("50ac103f-d235-4598-bbef-98fe4d1a3ad4");
    try std.testing.expectEqual(@as(c_ulong, 0x50ac103f), id.Data1);
    try std.testing.expectEqual(@as(c_ushort, 0xd235), id.Data2);
    try std.testing.expectEqual(@as(c_ushort, 0x4598), id.Data3);
    try std.testing.expectEqualSlices(u8, &.{ 0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4 }, &id.Data4);
}
