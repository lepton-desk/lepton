//! The Win32 window a WebView2 controller is hosted in.
//!
//! Windows draws the frame (title bar, borders, snap) itself; the controller fills the
//! client area. The window procedure forwards what the view needs — size, activation,
//! close, moves — to an `Owner` stored in the window's user data, so the procedure stays
//! a plain function and the view stays the one place that knows about WebView2.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const W = wv.W;

/// What the window tells its owner. Every callback runs on the window's thread.
pub const Owner = struct {
    context: *anyopaque,
    /// The client area changed size (physical pixels), or the window was minimised,
    /// maximised or restored.
    resized: *const fn (context: *anyopaque, width: u32, height: u32) void,
    /// Activation or the maximised state changed.
    state_changed: *const fn (context: *anyopaque) void,
    /// The user asked to close (title bar, Alt+F4, taskbar). The window stays until the
    /// owner destroys it.
    close_requested: *const fn (context: *anyopaque) void,
    /// The window moved: popups the engine draws (`<select>`, menus) follow it.
    moved: *const fn (context: *anyopaque) void,
};

const class_name = W("LeptonWindow");

/// `MAKEINTRESOURCE(1)` is an odd integer posing as a string pointer, which a typed
/// `LPCWSTR` cannot hold, so the resource id is passed as the integer it is.
extern "user32" fn LoadIconW(instance: c.HINSTANCE, id: usize) callconv(.winapi) c.HICON;
var class_registered = false;

/// Per-monitor DPI awareness (v2), before the first window: without it Windows scales a
/// 96-DPI bitmap of the page up on a high-DPI screen and the text is blurred. The call is
/// Windows 10 1703+, looked up rather than linked so an older user32 still loads.
pub fn becomeDpiAware() void {
    const user32 = c.GetModuleHandleW(W("user32.dll")) orelse return;
    const symbol = c.GetProcAddress(user32, "SetProcessDpiAwarenessContext") orelse return;
    const set: *const fn (?*anyopaque) callconv(.winapi) c.BOOL = @ptrCast(symbol);
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the handle value -4.
    _ = set(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));
}

/// Opens a hidden window whose *client area* is `width` × `height` logical pixels on the
/// primary monitor's scale. Shown by `show`.
pub fn open(width: u32, height: u32) ?c.HWND {
    const instance = c.GetModuleHandleW(null);
    if (!class_registered) {
        const class: c.WNDCLASSEXW = .{
            .cbSize = @sizeOf(c.WNDCLASSEXW),
            .style = c.CS_HREDRAW | c.CS_VREDRAW,
            .lpfnWndProc = procedure,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            // The executable's first icon resource, when it has one.
            .hIcon = LoadIconW(instance, 1),
            .hCursor = c.LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (c.RegisterClassExW(&class) == 0) return null;
        class_registered = true;
    }
    const window = c.CreateWindowExW(
        0,
        class_name,
        W(""),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        @intCast(width),
        @intCast(height),
        null,
        null,
        instance,
        null,
    ) orelse return null;
    setClientSize(window, width, height);
    return window;
}

/// Sizes the window so its client area is `width` × `height` logical pixels at the
/// window's own DPI.
pub fn setClientSize(window: c.HWND, width: u32, height: u32) void {
    const dpi = dpiOf(window);
    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(@as(u64, width) * dpi / 96),
        .bottom = @intCast(@as(u64, height) * dpi / 96),
    };
    _ = c.AdjustWindowRectEx(&rect, c.WS_OVERLAPPEDWINDOW, c.FALSE, 0);
    _ = c.SetWindowPos(window, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The window's DPI (96 = 100 %), 96 when the system cannot say.
pub fn dpiOf(window: c.HWND) u32 {
    const user32 = c.GetModuleHandleW(W("user32.dll")) orelse return 96;
    const symbol = c.GetProcAddress(user32, "GetDpiForWindow") orelse return 96;
    const get: *const fn (c.HWND) callconv(.winapi) c.UINT = @ptrCast(symbol);
    const dpi = get(window);
    return if (dpi == 0) 96 else dpi;
}

pub fn attach(window: c.HWND, owner: *Owner) void {
    _ = c.SetWindowLongPtrW(window, c.GWLP_USERDATA, @intCast(@intFromPtr(owner)));
}

pub fn show(window: c.HWND) void {
    _ = c.ShowWindow(window, c.SW_SHOW);
    _ = c.UpdateWindow(window);
}

pub fn setTitle(window: c.HWND, title: []const u8) void {
    var wide: [512:0]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], title[0..@min(title.len, 170)]) catch return;
    wide[units] = 0;
    _ = c.SetWindowTextW(window, &wide);
}

/// `invoke.WindowState` bits: maximised and active (fullscreen is the view's own flag).
pub fn stateOf(window: c.HWND) u32 {
    var bits: u32 = 0;
    if (c.IsZoomed(window) != 0) bits |= 1 << 1;
    if (c.GetForegroundWindow() == window) bits |= 1 << 2;
    return bits;
}

/// The client area in logical pixels, as the page's `innerWidth`/`innerHeight` count them.
pub fn logicalClientSize(window: c.HWND) [2]u32 {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(window, &rect) == 0) return .{ 0, 0 };
    const dpi = dpiOf(window);
    return .{
        @intCast(@divTrunc(@as(i64, @max(rect.right - rect.left, 0)) * 96, dpi)),
        @intCast(@divTrunc(@as(i64, @max(rect.bottom - rect.top, 0)) * 96, dpi)),
    };
}

fn ownerOf(window: c.HWND) ?*Owner {
    const raw = c.GetWindowLongPtrW(window, c.GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

fn procedure(window: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const owner = ownerOf(window) orelse return c.DefWindowProcW(window, message, wparam, lparam);
    switch (message) {
        c.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xffff);
            const height: u32 = @intCast((lparam >> 16) & 0xffff);
            owner.resized(owner.context, width, height);
        },
        c.WM_ACTIVATE => owner.state_changed(owner.context),
        c.WM_MOVE, c.WM_MOVING => owner.moved(owner.context),
        c.WM_CLOSE => {
            owner.close_requested(owner.context);
            return 0;
        },
        c.WM_DPICHANGED => {
            // Windows suggests the rectangle that keeps the window's logical size on the
            // new monitor; taking it is what per-monitor awareness asks of a window.
            const suggested: *const c.RECT = @ptrFromInt(@as(usize, @intCast(lparam)));
            _ = c.SetWindowPos(window, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(window, message, wparam, lparam);
}
