//! The window's chrome on Windows, beyond what `window.zig` draws by default:
//!
//! - **A title bar that follows the page.** The page says what it looks like —
//!   `<meta name="theme-color">` and CSS `color-scheme` — and the native title bar takes
//!   it: dark or light on Windows 10, the page's own colour on Windows 11
//!   (`DWMWA_CAPTION_COLOR`). Nothing to configure: a page that declares neither keeps
//!   Windows' default. A small script reads both (the colour resolved by the engine, so
//!   any CSS colour works) and posts them whenever they change; only the application's
//!   own page is listened to.
//! - **No title bar** (`window.decorations: false`): the page draws its own, drags the
//!   window with `window.start_drag` or CSS `app-region: drag`, and keeps the resize
//!   borders, shadow and snap.
//! - **Native menus** (`window.menu`): the system's own popup menu at the pointer.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const W = wv.W;
const window = @import("../../../window/windows/window.zig");
const invoke = @import("../invoke.zig");
const menu_mod = @import("../menu.zig");
const Bridge = @import("../bridge.zig").Bridge;

extern "dwmapi" fn DwmSetWindowAttribute(window: c.HWND, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) c.HRESULT;

/// `DWMWA_USE_IMMERSIVE_DARK_MODE`: 20 from Windows 10 20H1, 19 before it.
const dwmwa_dark = [_]u32{ 20, 19 };
/// Windows 11 (22000+); Windows 10 refuses them, which changes nothing.
const dwmwa_caption_color: u32 = 35;
const dwmwa_text_color: u32 = 36;

/// What the page asked for, as the script reports it.
pub const Theme = struct {
    dark: ?bool = null,
    /// The page's `theme-color`, resolved to RGB.
    color: ?[3]u8 = null,
};

/// `lepton-theme:<d>:<r>,<g>,<b>` — `d` is `1` dark, `0` light, `-` unsaid; the colour
/// part is empty when the page names none. Anything else is not a theme message.
pub fn parseTheme(message: []const u8) ?Theme {
    const prefix = "lepton-theme:";
    if (!std.mem.startsWith(u8, message, prefix)) return null;
    var parts = std.mem.splitScalar(u8, message[prefix.len..], ':');
    const dark_part = parts.next() orelse return null;
    const color_part = parts.next() orelse return null;
    if (parts.next() != null) return null;
    var theme: Theme = .{};
    if (std.mem.eql(u8, dark_part, "1")) theme.dark = true else if (std.mem.eql(u8, dark_part, "0")) theme.dark = false else if (!std.mem.eql(u8, dark_part, "-")) return null;
    if (color_part.len != 0) {
        var channels = std.mem.splitScalar(u8, color_part, ',');
        var rgb: [3]u8 = undefined;
        for (&rgb) |*channel| channel.* = std.fmt.parseInt(u8, channels.next() orelse return null, 10) catch return null;
        if (channels.next() != null) return null;
        theme.color = rgb;
    }
    return theme;
}

/// Whether `rgb` is dark enough for white text: relative luminance (sRGB, WCAG) under
/// the point where white and black text contrast equally (0.179).
pub fn isDark(rgb: [3]u8) bool {
    var linear: [3]f64 = undefined;
    for (rgb, 0..) |channel, index| {
        const value = @as(f64, @floatFromInt(channel)) / 255.0;
        linear[index] = if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
    }
    const luminance = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
    return luminance < 0.179;
}

/// Gives the window's title bar `theme`. The colour decides dark or light when the page
/// named one, so the title's text stays readable on it.
pub fn applyTheme(hwnd: c.HWND, theme: Theme) void {
    const dark = if (theme.color) |rgb| isDark(rgb) else theme.dark orelse return;
    const flag: c.BOOL = if (dark) c.TRUE else c.FALSE;
    for (dwmwa_dark) |attribute| {
        if (wv.ok(DwmSetWindowAttribute(hwnd, attribute, &flag, @sizeOf(c.BOOL)))) break;
    }
    if (theme.color) |rgb| {
        const caption: u32 = @as(u32, rgb[0]) | (@as(u32, rgb[1]) << 8) | (@as(u32, rgb[2]) << 16);
        const text: u32 = if (dark) 0x00FFFFFF else 0x00000000;
        _ = DwmSetWindowAttribute(hwnd, dwmwa_caption_color, &caption, @sizeOf(u32));
        _ = DwmSetWindowAttribute(hwnd, dwmwa_text_color, &text, @sizeOf(u32));
    }
    // Windows 10 draws the new frame only when the title bar next changes activation:
    // measured, an active window kept its light bar until it lost and regained focus
    // (`SWP_FRAMECHANGED` alone did not repaint it). So the bar is drawn inactive, then
    // as it is.
    const active: c.WPARAM = if (c.GetActiveWindow() == hwnd) c.TRUE else c.FALSE;
    _ = c.DefWindowProcW(hwnd, c.WM_NCACTIVATE, if (active == c.TRUE) c.FALSE else c.TRUE, 0);
    _ = c.DefWindowProcW(hwnd, c.WM_NCACTIVATE, active, 0);
}

/// Reads the page's `theme-color` (the first whose `media` matches) and `color-scheme`,
/// and posts them when they change: on load, when `<head>` or `<html>`'s attributes
/// change, and when the system switches between light and dark.
const theme_script = blk: {
    // The script is converted to UTF-16 at compile time, a branch per character.
    @setEvalBranchQuota(20_000);
    break :blk W(
        \\(() => {
        \\  const view = window.chrome && window.chrome.webview;
        \\  if (!view || window.top !== window) return;
        \\  const system = matchMedia("(prefers-color-scheme: dark)");
        \\  let last = "";
        \\  let queued = false;
        \\  const resolve = (text) => {
        \\    const probe = document.createElement("i");
        \\    probe.style.color = text;
        \\    if (probe.style.color === "") return "";
        \\    probe.style.display = "none";
        \\    document.documentElement.appendChild(probe);
        \\    const rgb = getComputedStyle(probe).color.match(/\d+/g);
        \\    probe.remove();
        \\    return rgb && rgb.length >= 3 ? rgb.slice(0, 3).join(",") : "";
        \\  };
        \\  const send = () => {
        \\    queued = false;
        \\    let color = "";
        \\    for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
        \\      if (meta.media && !matchMedia(meta.media).matches) continue;
        \\      color = resolve(meta.content);
        \\      break;
        \\    }
        \\    const scheme = getComputedStyle(document.documentElement).colorScheme || "";
        \\    const darkOk = /\bdark\b/.test(scheme), lightOk = /\blight\b/.test(scheme);
        \\    const dark = darkOk && lightOk ? (system.matches ? "1" : "0") : darkOk ? "1" : lightOk ? "0" : "-";
        \\    const message = "lepton-theme:" + dark + ":" + color;
        \\    if (message !== last) { last = message; view.postMessage(message); }
        \\  };
        \\  const soon = () => { if (!queued) { queued = true; requestAnimationFrame(send); } };
        \\  const watch = () => {
        \\    const observer = new MutationObserver(soon);
        \\    observer.observe(document.head, { subtree: true, childList: true, attributes: true });
        \\    observer.observe(document.documentElement, { attributes: true });
        \\    soon();
        \\  };
        \\  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watch, { once: true });
        \\  else watch();
        \\  system.addEventListener("change", soon);
        \\})();
    );
};

/// The view's chrome: lives inside the view, at the address WebView2 holds its handlers.
pub const Chrome = struct {
    hwnd: c.HWND = null,
    /// Where the one other origin the page may come from is kept (`lepton dev`'s server):
    /// read when a message arrives, as it is set after the chrome starts.
    bridge: ?*const Bridge = null,
    messages: c.ICoreWebView2WebMessageReceivedEventHandler = Messages.make(),
    script_added: c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = ScriptAdded.make(),

    /// Starts following the page's theme.
    pub fn followTheme(self: *Chrome, hwnd: c.HWND, core: *c.ICoreWebView2, bridge: *const Bridge) void {
        self.hwnd = hwnd;
        self.bridge = bridge;
        var token: c.EventRegistrationToken = undefined;
        _ = core.lpVtbl.*.add_WebMessageReceived.?(core, &self.messages, &token);
        _ = core.lpVtbl.*.AddScriptToExecuteOnDocumentCreated.?(core, theme_script, &self.script_added);
    }

    fn fromOwn(page: []const u8, dev_origin: []const u8) bool {
        if (std.mem.startsWith(u8, page, "http://lepton.localhost/")) return true;
        if (dev_origin.len == 0 or !std.mem.startsWith(u8, page, dev_origin)) return false;
        return page.len == dev_origin.len or page[dev_origin.len] == '/';
    }
};

const Messages = wv.Handler(c.ICoreWebView2WebMessageReceivedEventHandler, c.ICoreWebView2WebMessageReceivedEventHandlerVtbl, &c.IID_ICoreWebView2WebMessageReceivedEventHandler, onMessage);
const ScriptAdded = wv.Handler(c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandlerVtbl, &c.IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, onScriptAdded);

fn onMessage(this: [*c]c.ICoreWebView2WebMessageReceivedEventHandler, _: [*c]c.ICoreWebView2, args: [*c]c.ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) c.HRESULT {
    const self: *Chrome = @fieldParentPtr("messages", @as(*c.ICoreWebView2WebMessageReceivedEventHandler, @ptrCast(this)));
    const received = args orelse return c.S_OK;
    var source_wide: c.LPWSTR = null;
    if (!wv.ok(received.*.lpVtbl.*.get_Source.?(received, &source_wide))) return c.S_OK;
    var source_buffer: [2048]u8 = undefined;
    const dev_origin = if (self.bridge) |bridge| bridge.devOrigin() else "";
    if (!Chrome.fromOwn(wv.takeString(source_wide, &source_buffer), dev_origin)) return c.S_OK;
    var text_wide: c.LPWSTR = null;
    if (!wv.ok(received.*.lpVtbl.*.TryGetWebMessageAsString.?(received, &text_wide))) return c.S_OK;
    var text_buffer: [128]u8 = undefined;
    const theme = parseTheme(wv.takeString(text_wide, &text_buffer)) orelse return c.S_OK;
    if (self.hwnd) |hwnd| applyTheme(hwnd, theme);
    return c.S_OK;
}

fn onScriptAdded(_: [*c]c.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, _: c.HRESULT, _: c.LPCWSTR) callconv(.winapi) c.HRESULT {
    return c.S_OK;
}

/// Lets the page's CSS `app-region: drag` move the window (WebView2's non-client region
/// support, `ICoreWebView2Settings9`). False on a runtime without it.
pub fn allowDragRegions(core: *c.ICoreWebView2) bool {
    var settings: [*c]c.ICoreWebView2Settings = null;
    if (!wv.ok(core.lpVtbl.*.get_Settings.?(core, &settings)) or settings == null) return false;
    defer _ = settings.*.lpVtbl.*.Release.?(settings);
    var ninth: ?*c.ICoreWebView2Settings9 = null;
    if (!wv.ok(settings.*.lpVtbl.*.QueryInterface.?(settings, &c.IID_ICoreWebView2Settings9, @ptrCast(&ninth)))) return false;
    const regions = ninth orelse return false;
    defer _ = regions.lpVtbl.*.Release.?(regions);
    return wv.ok(regions.lpVtbl.*.put_IsNonClientRegionSupportEnabled.?(regions, c.TRUE));
}

// --- native menus ----------------------------------------------------------------------

/// One menu at a time: a second waits for nothing, it is refused (a menu is modal).
const Pending = struct {
    later: ?invoke.Later = null,
    hwnd: c.HWND = null,
    timer: usize = 0,
    bytes: [1 + menu_mod.max_items * (5 + menu_mod.max_label)]u8 = undefined,
    len: usize = 0,
};
var pending: Pending = .{};

/// Shows `menu` (already `menu_mod.valid`) at the pointer once the request handler has
/// returned, and finishes `later` with the chosen id. The menu is modal and has its own
/// loop, which WebView2's request handler must not run, hence the zero-delay timer.
pub fn showMenu(hwnd: c.HWND, menu: []const u8, later: invoke.Later) bool {
    if (pending.later != null or menu.len > pending.bytes.len) return false;
    @memcpy(pending.bytes[0..menu.len], menu);
    pending.len = menu.len;
    pending.hwnd = hwnd;
    pending.timer = c.SetTimer(null, 0, 0, &onMenuTimer);
    if (pending.timer == 0) return false;
    pending.later = later;
    return true;
}

fn onMenuTimer(_: c.HWND, _: c.UINT, id: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
    _ = c.KillTimer(null, id);
    if (id != pending.timer) return;
    const later = pending.later orelse return;
    const chosen = track(pending.hwnd, pending.bytes[0..pending.len]);
    pending.later = null;
    var reply: [2]u8 = undefined;
    std.mem.writeInt(u16, &reply, chosen orelse 0, .little);
    if (chosen == null) return later.finish(.failed, &.{});
    later.finish(.ok, &reply);
}

/// The id chosen, 0 when dismissed; null when the menu could not be made.
fn track(hwnd: c.HWND, bytes: []const u8) ?u16 {
    const menu = c.CreatePopupMenu() orelse return null;
    defer _ = c.DestroyMenu(menu);
    var items = menu_mod.items(bytes);
    while (items.next()) |item| {
        if (item.isSeparator()) {
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
            continue;
        }
        var label: [menu_mod.max_label + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(&label, item.label) catch return null;
        label[units] = 0;
        var flags: c.UINT = c.MF_STRING;
        if (item.flags & menu_mod.Flag.disabled != 0) flags |= c.MF_GRAYED;
        if (item.flags & menu_mod.Flag.checked != 0) flags |= c.MF_CHECKED;
        if (c.AppendMenuW(menu, flags, item.id, @ptrCast(&label)) == 0) return null;
    }
    var at: c.POINT = undefined;
    if (c.GetCursorPos(&at) == 0) return null;
    // Without the window in front, the menu does not close when the user clicks away.
    _ = c.SetForegroundWindow(hwnd);
    const chosen = c.TrackPopupMenuEx(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY, at.x, at.y, hwnd, null);
    return @intCast(@as(u32, @bitCast(chosen)) & 0xffff);
}

test "theme messages are read, and nothing else is" {
    const dark = parseTheme("lepton-theme:1:") orelse return error.Missing;
    try std.testing.expectEqual(@as(?bool, true), dark.dark);
    try std.testing.expect(dark.color == null);
    const colour = parseTheme("lepton-theme:-:27,29,28") orelse return error.Missing;
    try std.testing.expect(colour.dark == null);
    try std.testing.expectEqualSlices(u8, &.{ 27, 29, 28 }, &(colour.color orelse return error.Missing));
    try std.testing.expect(parseTheme("lepton-theme:2:") == null);
    try std.testing.expect(parseTheme("lepton-theme:1:300,0,0") == null);
    try std.testing.expect(parseTheme("lepton-theme:1:1,2") == null);
    try std.testing.expect(parseTheme("lepton-theme:1:1,2,3:x") == null);
    try std.testing.expect(parseTheme("hello") == null);
}

test "a dark colour gets a dark title bar, a light one a light one" {
    try std.testing.expect(isDark(.{ 0x1b, 0x1d, 0x1c }));
    try std.testing.expect(isDark(.{ 0xa3, 0x2b, 0x17 }));
    try std.testing.expect(!isDark(.{ 0xd5, 0xd8, 0xd0 }));
    try std.testing.expect(!isDark(.{ 0xff, 0xff, 0xff }));
    try std.testing.expect(!isDark(.{ 0xff, 0xd7, 0x00 }));
}

test "only the application's own page is listened to" {
    try std.testing.expect(Chrome.fromOwn("http://lepton.localhost/index.html", ""));
    try std.testing.expect(Chrome.fromOwn("http://127.0.0.1:5173/", "http://127.0.0.1:5173"));
    try std.testing.expect(!Chrome.fromOwn("http://127.0.0.1:51730/", "http://127.0.0.1:5173"));
    try std.testing.expect(!Chrome.fromOwn("https://example.com/", "http://127.0.0.1:5173"));
    try std.testing.expect(!Chrome.fromOwn("http://lepton.localhost.example.com/", ""));
}
