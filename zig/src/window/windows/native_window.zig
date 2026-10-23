//! The native render path's window on Windows: the Win32 window (`window.zig`) the WebView2
//! path hosts in, given pixels instead of a controller. It answers the calls Linux's
//! `linux/wayland_window.zig` and `linux/x11_window.zig` answer (`window/window.zig`,
//! `Backend`), so the layer above draws the same way on every system.
//!
//! Sizes are physical pixels, as the rest of the layer counts them; the size a window is
//! opened at is logical, scaled by the monitor's DPI as the WebView2 window's is, so the
//! same `window.width` in `lepton.config.json` makes the same window on both paths.
//!
//! Frames reach the screen with `SetDIBitsToDevice` from a top-down 32-bit DIB: the
//! framebuffer's bytes are blue, green, red, alpha (`PixelFormat.pixelWord`), the order a
//! `BI_RGB` DIB reads, so no conversion happens on the way.

const std = @import("std");
const layer = @import("../window.zig");
const window = @import("window.zig");
const win32 = @import("win32.zig");
const theme = @import("theme.zig");
const c = win32.c;

const Size = layer.Size;

/// `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` (synchapi.h, Windows 10 1803+), named here
/// because older headers do not define it.
const create_waitable_timer_high_resolution: c.DWORD = 0x2;
const Configure = layer.Configure;
const Request = layer.Request;

pub const OpenError = error{
    /// Windows refused to create the window (`CreateWindowExW` returned null).
    WindowRefused,
};

pub const NativeWindow = struct {
    hwnd: c.HWND,
    /// What the window procedure calls back; lives here so its address is stable for as
    /// long as the window does.
    owner: window.Owner,
    /// The client area, physical pixels: the size a frame must have.
    size: Size,
    /// The configure not yet taken. An empty size is the window closing, as on Linux.
    pending: ?Configure = null,
    /// What `wait` sleeps on: a high-resolution waitable timer (Windows 10 1803+), else an
    /// ordinary one. A plain timeout is rounded to the system tick (15.625 ms): `wait(16)`
    /// slept two ticks and the window drew 32 frames a second instead of 60 (measured).
    timer: ?c.HANDLE = null,
    /// When the current wait period ends (performance-counter ticks), so `wait(16)` paces
    /// frames 16 ms apart however long the frame took to draw. Sleeping 16 ms after each
    /// frame drew 50 frames a second, the drawing's own time added to every period.
    deadline: i64 = 0,
    /// The GPU path's swap chain signal (`render/gpu/d3d11.zig`, `frameWait`): set, `wait`
    /// sleeps on it instead of the timer, and frames follow the display's refresh.
    frame_wait: ?c.HANDLE = null,

    /// Paces `wait` by the swap chain's frame-latency object (null: the timer again).
    pub fn setFrameWait(self: *NativeWindow, handle: ?*anyopaque) void {
        self.frame_wait = handle;
    }

    /// Opens the window in place: `self` is the owner the window procedure reaches, so it
    /// must already be where it will stay.
    pub fn open(self: *NativeWindow, request: Request) OpenError!void {
        window.becomeDpiAware();
        const hwnd = window.open(request.size.width, request.size.height) orelse return error.WindowRefused;
        self.* = .{
            .hwnd = hwnd,
            .owner = .{
                .context = self,
                .resized = &onResized,
                .state_changed = &ignore,
                .close_requested = &onCloseRequested,
                .moved = &ignore,
            },
            .size = clientSize(hwnd),
            .timer = c.CreateWaitableTimerExW(null, null, create_waitable_timer_high_resolution, c.TIMER_ALL_ACCESS) orelse
                c.CreateWaitableTimerExW(null, null, 0, c.TIMER_ALL_ACCESS),
        };
        window.attach(hwnd, &self.owner);
        window.setTitle(hwnd, request.title);
        if (request.mapped) window.show(hwnd);
        if (request.title_colour) |rgb| theme.apply(hwnd, .{ .color = rgb });
        // The size Windows gave (cut to a small screen, scaled by DPI) is the first
        // configure, so the caller's first frame is the window's size, not the request's.
        self.size = clientSize(hwnd);
        self.pending = .{ .size = self.size };
    }

    pub fn close(self: *NativeWindow) void {
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
        if (self.timer) |timer| _ = c.CloseHandle(timer);
    }

    /// Sets the client area to `size`. Windows answers with `WM_SIZE`, which becomes the
    /// next configure; asking for the size the window already has does nothing.
    pub fn resize(self: *NativeWindow, size: Size) layer.Error!void {
        if (size.isEmpty()) return error.SizeRefused;
        if (size.width == self.size.width and size.height == self.size.height) return;
        // The frame's thickness is whatever the window has now: measured from its own
        // rectangles rather than recomputed, so it is right at any DPI.
        var outer: c.RECT = undefined;
        var inner: c.RECT = undefined;
        if (c.GetWindowRect(self.hwnd, &outer) == 0 or c.GetClientRect(self.hwnd, &inner) == 0) return error.DisplayLost;
        const frame_width = (outer.right - outer.left) - (inner.right - inner.left);
        const frame_height = (outer.bottom - outer.top) - (inner.bottom - inner.top);
        const width = std.math.cast(i32, size.width) orelse return error.SizeRefused;
        const height = std.math.cast(i32, size.height) orelse return error.SizeRefused;
        if (c.SetWindowPos(self.hwnd, null, 0, 0, width + frame_width, height + frame_height, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) {
            return error.SizeRefused;
        }
    }

    /// Handles what Windows has queued, waiting up to `timeout_ms` (negative: forever) for
    /// something to arrive first. Messages already in the queue end the wait at once
    /// (`MWMO_INPUTAVAILABLE`).
    pub fn wait(self: *NativeWindow, timeout_ms: i32) layer.Error!void {
        const woke = if (timeout_ms > 0 and self.frame_wait != null)
            // The swap chain says when the next frame may be drawn; `timeout_ms` is only
            // the longest this waits if it never does.
            c.MsgWaitForMultipleObjectsEx(1, &self.frame_wait.?, @intCast(timeout_ms * 4), c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE)
        else if (timeout_ms > 0 and self.timer != null) timed: {
            var frequency: c.LARGE_INTEGER = undefined;
            var now: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceFrequency(&frequency);
            _ = c.QueryPerformanceCounter(&now);
            const period = @divTrunc(frequency.QuadPart * timeout_ms, 1000);
            // The next period starts once this one has ended; a message that woke the last
            // wait early leaves the deadline where it was. Behind by a whole period (the
            // first wait, a stall): start again from now rather than drawing the missed
            // frames back to back.
            if (now.QuadPart >= self.deadline) {
                self.deadline += period;
                if (self.deadline <= now.QuadPart) self.deadline = now.QuadPart + period;
            }
            const remaining = self.deadline - now.QuadPart;
            // Relative due time: negative, in 100 ns units. A one-shot synchronization
            // timer, reset by the wait that it ends; set again on each call.
            const due: c.LARGE_INTEGER = .{ .QuadPart = -@divTrunc(remaining * 10_000_000, frequency.QuadPart) };
            if (c.SetWaitableTimer(self.timer.?, &due, 0, null, null, c.FALSE) == 0) return error.DisplayLost;
            break :timed c.MsgWaitForMultipleObjectsEx(1, &self.timer.?, c.INFINITE, c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE);
        } else c.MsgWaitForMultipleObjectsEx(0, null, if (timeout_ms < 0) c.INFINITE else 0, c.QS_ALLINPUT, c.MWMO_INPUTAVAILABLE);
        if (woke == c.WAIT_FAILED) return error.DisplayLost;
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
    }

    /// Puts one frame of `frame` on the window. A frame smaller than it claims is refused,
    /// as on Linux: truncated, it would look like a drawing bug.
    pub fn presentPixels(self: *NativeWindow, pixels: []const u8, frame: Size, format: layer.PixelFormat) layer.Error!void {
        if (frame.isEmpty()) return error.SizeRefused;
        const width = std.math.cast(i32, frame.width) orelse return error.SizeRefused;
        const height = std.math.cast(i32, frame.height) orelse return error.SizeRefused;
        if (pixels.len < frame.frameBytes(format)) return error.FrameTruncated;

        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        // Negative: a top-down DIB, row 0 at the top, as the framebuffer is laid out.
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = @intCast(layer.PixelFormat.bits_per_pixel);
        info.bmiHeader.biCompression = c.BI_RGB;

        const dc = c.GetDC(self.hwnd) orelse return error.DisplayLost;
        defer _ = c.ReleaseDC(self.hwnd, dc);
        const lines = c.SetDIBitsToDevice(dc, 0, 0, @intCast(width), @intCast(height), 0, 0, 0, @intCast(height), pixels.ptr, &info, c.DIB_RGB_COLORS);
        if (lines == 0) return error.DisplayLost;
    }

    pub fn takeConfigure(self: *NativeWindow) ?Configure {
        defer self.pending = null;
        return self.pending;
    }

    fn onResized(context: *anyopaque, width: u32, height: u32) void {
        const self: *NativeWindow = @ptrCast(@alignCast(context));
        // A minimised window reports 0 × 0; that is not the window closing, and the frame
        // keeps its size until the window is restored.
        if (width == 0 or height == 0) return;
        self.size = .{ .width = width, .height = height };
        self.pending = .{ .size = self.size };
    }

    fn onCloseRequested(context: *anyopaque) void {
        const self: *NativeWindow = @ptrCast(@alignCast(context));
        self.pending = .{ .size = .{ .width = 0, .height = 0 } };
    }

    fn ignore(_: *anyopaque) void {}
};

fn clientSize(hwnd: c.HWND) Size {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &rect) == 0) return .{ .width = 0, .height = 0 };
    return .{ .width = @intCast(@max(rect.right - rect.left, 0)), .height = @intCast(@max(rect.bottom - rect.top, 0)) };
}

// What `window/window.zig`'s `Backend` calls, as Linux's backends export it.

pub fn resize(handle: *anyopaque, size: Size) layer.Error!void {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    return self.resize(size);
}

pub fn setTitle(handle: *anyopaque, text: []const u8) layer.Error!void {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    window.setTitle(self.hwnd, text);
}

pub fn currentSize(handle: *anyopaque) Size {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    return self.size;
}

pub fn wait(handle: *anyopaque, timeout_ms: i32) layer.Error!void {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    return self.wait(timeout_ms);
}

pub fn presentPixels(handle: *anyopaque, pixels: []const u8, frame: Size, format: layer.PixelFormat) layer.Error!void {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    return self.presentPixels(pixels, frame, format);
}

pub fn takeConfigure(handle: *anyopaque) ?Configure {
    const self: *NativeWindow = @ptrCast(@alignCast(handle));
    return self.takeConfigure();
}
