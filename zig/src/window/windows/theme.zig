//! The system title bar's look: dark or light on Windows 10, a colour of its own on
//! Windows 11. Shared by the WebView2 window (which takes it from the page, `chrome.zig`)
//! and the native one (which takes it from `window.Request.title_colour`).

const std = @import("std");
const win32 = @import("win32.zig");
const c = win32.c;

extern "dwmapi" fn DwmSetWindowAttribute(window: c.HWND, attribute: u32, value: *const anyopaque, size: u32) callconv(.winapi) c.HRESULT;

/// `DWMWA_USE_IMMERSIVE_DARK_MODE`: 20 from Windows 10 20H1, 19 before it.
const dwmwa_dark = [_]u32{ 20, 19 };
/// Windows 11 (22000+); Windows 10 refuses them, which changes nothing.
const dwmwa_caption_color: u32 = 35;
const dwmwa_text_color: u32 = 36;

/// What the title bar should look like.
pub const Theme = struct {
    dark: ?bool = null,
    /// The bar's colour, RGB.
    color: ?[3]u8 = null,
};

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

/// Gives the window's title bar `theme`. The colour decides dark or light when one is
/// named, so the title's text stays readable on it.
pub fn apply(hwnd: c.HWND, theme: Theme) void {
    const dark = if (theme.color) |rgb| isDark(rgb) else theme.dark orelse return;
    const flag: c.BOOL = if (dark) c.TRUE else c.FALSE;
    for (dwmwa_dark) |attribute| {
        if (DwmSetWindowAttribute(hwnd, attribute, &flag, @sizeOf(c.BOOL)) >= 0) break;
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
