//! The Win32 window: the one a WebView2 controller is hosted in, and the one the native
//! render path draws into (Linux's counterpart is `window/linux/`).
//!
//! Windows draws the frame (title bar, borders, snap) itself; what is hosted fills the
//! client area. The window procedure forwards what its owner needs — size, activation,
//! close, moves — to an `Owner` stored in the window's user data, so the procedure stays
//! a plain function and knows nothing of what fills the window.

const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;
const W = win32.W;

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
    /// No title bar: the page draws its own (`window.decorations: false`). The window
    /// keeps its resize borders, shadow, snap and taskbar button.
    frameless: bool = false,
};

const class_name = W("LeptonWindow");

/// `MAKEINTRESOURCE(1)` is an odd integer posing as a string pointer, which a typed
/// `LPCWSTR` cannot hold, so the resource id is passed as the integer it is.
extern "user32" fn LoadIconW(instance: c.HINSTANCE, id: usize) callconv(.winapi) c.HICON;
/// Declared returning `HICON` (it is only ever asked for an icon here): a handle is not a
/// pointer, its value need not be aligned, and `@alignCast` of one panicked in a Debug
/// build (`lepton run`, measured) — Release builds skip the check, so it never showed.
extern "user32" fn LoadImageW(instance: c.HINSTANCE, id: usize, kind: c.UINT, width: c_int, height: c_int, flags: c.UINT) callconv(.winapi) c.HICON;
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
            // The executable's first icon resource (the template's build embeds the
            // project's icon, or Lepton's): the taskbar and Alt+Tab take the large one,
            // the title bar the small one, each drawn from its own frame rather than
            // scaled down from 32 px.
            .hIcon = LoadIconW(instance, 1),
            .hCursor = c.LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = LoadImageW(instance, 1, c.IMAGE_ICON, c.GetSystemMetrics(c.SM_CXSMICON), c.GetSystemMetrics(c.SM_CYSMICON), 0),
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
    setClientSize(window, width, height, false);
    return window;
}

/// Sizes the window so its client area is `width` × `height` logical pixels at the
/// window's own DPI, then places it with [`place`]: never larger than the monitor's work
/// area, and centred on a small screen.
pub fn setClientSize(window: c.HWND, width: u32, height: u32, frameless: bool) void {
    const dpi = dpiOf(window);
    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = @intCast(@as(u64, width) * dpi / 96),
        .bottom = @intCast(@as(u64, height) * dpi / 96),
    };
    _ = c.AdjustWindowRectEx(&rect, c.WS_OVERLAPPEDWINDOW, c.FALSE, 0);
    // Frameless: the client area starts at the window's top edge (`WM_NCCALCSIZE`).
    if (frameless) rect.top = 0;
    const outer_width = rect.right - rect.left;
    const outer_height = rect.bottom - rect.top;
    const screen = screenOf(window) orelse {
        _ = c.SetWindowPos(window, null, 0, 0, outer_width, outer_height, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        return;
    };
    const at = place(outer_width, outer_height, screen, isSmall(screen, dpi));
    const keep: c.UINT = if (at.move) 0 else c.SWP_NOMOVE;
    _ = c.SetWindowPos(window, null, at.x, at.y, at.width, at.height, keep | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The monitor a window is on: all of it, and the part the taskbar leaves (physical pixels).
pub const Screen = struct { full: c.RECT, work: c.RECT };

pub fn screenOf(window: c.HWND) ?Screen {
    const monitor = c.MonitorFromWindow(window, c.MONITOR_DEFAULTTOPRIMARY) orelse return null;
    var info: c.MONITORINFO = undefined;
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &info) == 0) return null;
    return .{ .full = info.rcMonitor, .work = info.rcWork };
}

/// The largest screen counted small: what fits on it is what a laptop of the low end
/// shows (1366 × 768 is small by its height).
pub const small_screen = [2]i32{ 1280, 800 };

/// A screen 1280 × 800 or less in either direction, in logical pixels — what the page
/// has room for, so a 1920 × 1080 screen at 150 % (1280 × 720) is small too.
pub fn isSmall(screen: Screen, dpi: u32) bool {
    const width = @divTrunc(@as(i64, screen.full.right - screen.full.left) * 96, dpi);
    const height = @divTrunc(@as(i64, screen.full.bottom - screen.full.top) * 96, dpi);
    return width <= small_screen[0] or height <= small_screen[1];
}

pub const Placement = struct { x: i32 = 0, y: i32 = 0, width: i32, height: i32, move: bool };

/// Where a window of `width` × `height` (outer, physical) goes: cut to the work area so
/// no edge is off screen or under the taskbar, and centred in it when the screen is
/// small or the window had to be cut. Otherwise Windows' own placement stays (`move`
/// false).
pub fn place(width: i32, height: i32, screen: Screen, small: bool) Placement {
    const work_width = screen.work.right - screen.work.left;
    const work_height = screen.work.bottom - screen.work.top;
    const fitted_width = @min(width, work_width);
    const fitted_height = @min(height, work_height);
    const cut = fitted_width != width or fitted_height != height;
    if (!small and !cut) return .{ .width = width, .height = height, .move = false };
    return .{
        .x = screen.work.left + @divTrunc(work_width - fitted_width, 2),
        .y = screen.work.top + @divTrunc(work_height - fitted_height, 2),
        .width = fitted_width,
        .height = fitted_height,
        .move = true,
    };
}

/// Starts moving the window with the mouse, as a press on a title bar does: how a page
/// that draws its own title bar lets the user drag the window. Posted, not sent: the
/// move is a modal loop, and the command runs inside WebView2's request handler, where
/// a nested loop is not allowed. The button is still down when the message arrives.
pub fn startDrag(window: c.HWND) bool {
    _ = c.ReleaseCapture();
    return c.PostMessageW(window, c.WM_NCLBUTTONDOWN, c.HTCAPTION, 0) != 0;
}

/// Turns the title bar off or on (`Owner.frameless`); the frame is recomputed at once.
pub fn setFrameless(window: c.HWND, frameless: bool) void {
    const owner = ownerOf(window) orelse return;
    owner.frameless = frameless;
    _ = c.SetWindowPos(window, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The resize border's height at the window's DPI: a maximised window's frame lies
/// that far outside the monitor, so a frameless one moves its client area in by it.
fn frameHeight(window: c.HWND) c_int {
    const dpi = dpiOf(window);
    const user32 = c.GetModuleHandleW(W("user32.dll")) orelse return c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
    const symbol = c.GetProcAddress(user32, "GetSystemMetricsForDpi") orelse return c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
    const metric: *const fn (c_int, c.UINT) callconv(.winapi) c_int = @ptrCast(symbol);
    return metric(c.SM_CYFRAME, dpi) + metric(c.SM_CXPADDEDBORDER, dpi);
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
        c.WM_NCCALCSIZE => if (owner.frameless and wparam != 0) {
            // Windows computes the frame as usual, then the client area takes the title
            // bar's place: left, right and bottom keep the (invisible) resize borders, so
            // the window still resizes, snaps and casts its shadow. Windows Terminal's way.
            const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @intCast(lparam)));
            const top = params.rgrc[0].top;
            const result = c.DefWindowProcW(window, message, wparam, lparam);
            params.rgrc[0].top = top;
            if (c.IsZoomed(window) != 0) params.rgrc[0].top += frameHeight(window);
            return result;
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

fn box(left: i32, top: i32, right: i32, bottom: i32) c.RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

test "a small screen is 1280 x 800 or less either way, in logical pixels" {
    const laptop: Screen = .{ .full = box(0, 0, 1366, 768), .work = box(0, 0, 1366, 728) };
    const desktop: Screen = .{ .full = box(0, 0, 1920, 1080), .work = box(0, 0, 1920, 1040) };
    const narrow: Screen = .{ .full = box(0, 0, 1280, 1024), .work = box(0, 0, 1280, 984) };
    try std.testing.expect(isSmall(laptop, 96));
    try std.testing.expect(isSmall(narrow, 96));
    try std.testing.expect(!isSmall(desktop, 96));
    // 1920 x 1080 at 150 % leaves the page 1280 x 720.
    try std.testing.expect(isSmall(desktop, 144));
}

test "a window is cut to the work area and centred on a small screen" {
    const laptop: Screen = .{ .full = box(0, 0, 1366, 768), .work = box(0, 0, 1366, 728) };
    // 1200 x 800 of client is taller than what the taskbar leaves: cut, and centred.
    const at = place(1216, 839, laptop, true);
    try std.testing.expect(at.move);
    try std.testing.expectEqual(@as(i32, 1216), at.width);
    try std.testing.expectEqual(@as(i32, 728), at.height);
    try std.testing.expectEqual(@as(i32, 75), at.x);
    try std.testing.expectEqual(@as(i32, 0), at.y);
    // A smaller window on a small screen: centred, its size kept.
    const small = place(800, 600, laptop, true);
    try std.testing.expectEqual(@as(i32, 283), small.x);
    try std.testing.expectEqual(@as(i32, 64), small.y);
    try std.testing.expectEqual(@as(i32, 800), small.width);
    // A large screen with room to spare: Windows places it.
    const desktop: Screen = .{ .full = box(0, 0, 1920, 1080), .work = box(0, 0, 1920, 1040) };
    try std.testing.expect(!place(1216, 839, desktop, false).move);
    // A secondary monitor to the left: centred in its own work area.
    const left: Screen = .{ .full = box(-1280, 0, 0, 800), .work = box(-1280, 0, 0, 760) };
    try std.testing.expectEqual(@as(i32, -1280 + 240), place(800, 600, left, true).x);
}
