//! Opens the native render path's Win32 window and measures it from outside: what the
//! screen shows after a frame is presented, that a resize comes back as a configure, and
//! that a close request does. Each fact is printed; a mismatch exits 1.
//!
//! The screen is read with `GetPixel` on the screen's DC — what Windows composed, not the
//! frame's own bytes — so a wrong byte order or a frame that never reached the window
//! shows as a wrong colour.
//!
//! Run with `zig build win32-window-check` (Windows only).

const std = @import("std");
const layer = @import("lepton_window").window;
const native = layer.win32;
const c = @import("c_windows");

/// Three colours: top-left, the right half, bottom-left. A swapped red/blue, a mirrored or
/// an upside-down frame reads wrong.
const left_word: u32 = 0xFF_20_60_A0; // a, r, g, b
const right_word: u32 = 0xFF_E0_B0_30;
const bottom_word: u32 = 0xFF_40_C0_60;

var failed = false;

fn fact(comptime label: []const u8, comptime format: []const u8, args: anytype) void {
    std.debug.print("{s:<12} " ++ format ++ "\n", .{label} ++ args);
}

fn expect(ok: bool, comptime label: []const u8, comptime format: []const u8, args: anytype) void {
    if (!ok) failed = true;
    std.debug.print("{s} {s:<12} " ++ format ++ "\n", .{ if (ok) "ok  " else "FAIL", label } ++ args);
}

fn paint(pixels: []u8, size: layer.Size) void {
    const words = std.mem.bytesAsSlice(u32, pixels);
    for (0..size.height) |y| {
        for (0..size.width) |x| {
            words[y * size.width + x] = if (x >= size.width / 2) right_word else if (y < size.height / 2) left_word else bottom_word;
        }
    }
}

/// The colour on screen at a point of the window's client area, as `0xRRGGBB`.
fn screenAt(hwnd: c.HWND, x: i32, y: i32) u32 {
    var point: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &point);
    const dc = c.GetDC(null) orelse return 0xFFFF_FFFF;
    defer _ = c.ReleaseDC(null, dc);
    const colour: u32 = c.GetPixel(dc, point.x, point.y); // 0x00BBGGRR
    return ((colour & 0xFF) << 16) | (colour & 0xFF00) | ((colour >> 16) & 0xFF);
}

fn pump(w: *native.NativeWindow, milliseconds: u64) !void {
    const until = c.GetTickCount64() + milliseconds;
    while (c.GetTickCount64() < until) try w.wait(16);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton win32 window check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    _ = c.SetForegroundWindow(w.hwnd);

    const first = w.takeConfigure() orelse {
        expect(false, "configure", "none after open", .{});
        std.process.exit(1);
    };
    fact("dpi", "{d}", .{c.GetDpiForWindow(w.hwnd)});
    expect(!first.size.isEmpty(), "opened", "client {d}x{d}", .{ first.size.width, first.size.height });

    var size = first.size;
    var pixels = try allocator.alloc(u8, size.frameBytes(.argb8888));
    defer allocator.free(pixels);
    paint(pixels, size);
    try w.presentPixels(pixels, size, .argb8888);
    try pump(&w, 500);
    try w.presentPixels(pixels, size, .argb8888);
    try pump(&w, 200);

    const left = screenAt(w.hwnd, @intCast(size.width / 4), @intCast(size.height / 4));
    const right = screenAt(w.hwnd, @intCast(size.width * 3 / 4), @intCast(size.height / 2));
    const bottom = screenAt(w.hwnd, @intCast(size.width / 4), @intCast(size.height * 3 / 4));
    expect(left == left_word & 0xFFFFFF, "top-left", "screen #{x:0>6}, frame #{x:0>6}", .{ left, left_word & 0xFFFFFF });
    expect(right == right_word & 0xFFFFFF, "right half", "screen #{x:0>6}, frame #{x:0>6}", .{ right, right_word & 0xFFFFFF });
    expect(bottom == bottom_word & 0xFFFFFF, "bottom-left", "screen #{x:0>6}, frame #{x:0>6}", .{ bottom, bottom_word & 0xFFFFFF });

    const short = pixels[0 .. pixels.len - 4];
    expect(w.presentPixels(short, size, .argb8888) == error.FrameTruncated, "short frame", "refused", .{});

    const wanted: layer.Size = .{ .width = size.width + 120, .height = size.height + 80 };
    try w.resize(wanted);
    try pump(&w, 300);
    const resized = w.takeConfigure();
    const got = if (resized) |r| r.size else size;
    expect(got.width == wanted.width and got.height == wanted.height, "resize", "asked {d}x{d}, configure {d}x{d}", .{ wanted.width, wanted.height, got.width, got.height });

    size = got;
    pixels = try allocator.realloc(pixels, size.frameBytes(.argb8888));
    paint(pixels, size);
    try w.presentPixels(pixels, size, .argb8888);
    try pump(&w, 200);
    const corner = screenAt(w.hwnd, @intCast(size.width - 4), @intCast(size.height - 4));
    expect(corner == right_word & 0xFFFFFF, "after resize", "bottom-right #{x:0>6}", .{corner});

    _ = c.ShowWindow(w.hwnd, c.SW_MINIMIZE);
    try pump(&w, 300);
    const minimised = w.takeConfigure();
    expect(minimised == null, "minimise", "{s}", .{if (minimised == null) "no configure (not a close)" else "a configure"});
    _ = c.ShowWindow(w.hwnd, c.SW_RESTORE);
    try pump(&w, 300);
    _ = w.takeConfigure();

    // `wait(16)` with nothing to handle sleeps one refresh (`DwmFlush`), not the system tick
    // rounded up: the loop it paces draws at the display's rate, not 32 frames a second.
    try pump(&w, 300);
    var frequency: c.LARGE_INTEGER = undefined;
    var started: c.LARGE_INTEGER = undefined;
    var ended: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceFrequency(&frequency);
    _ = c.QueryPerformanceCounter(&started);
    const waits = 30;
    for (0..waits) |_| try w.wait(16);
    _ = c.QueryPerformanceCounter(&ended);
    const average_us = @divTrunc((ended.QuadPart - started.QuadPart) * 1_000_000, frequency.QuadPart * waits);
    expect(average_us >= 15_000 and average_us <= 24_000, "wait(16)", "{d} us on average over {d}", .{ average_us, waits });

    // What `DwmFlush` waits for: after a frame, idle, and minimised — the CPU path's pacing
    // follows it only where it waits about one refresh and never hangs.
    inline for (.{ .{ "dwm frame", true, false }, .{ "dwm idle", false, false }, .{ "dwm hidden", true, true } }) |case| {
        if (case[2]) _ = c.ShowWindow(w.hwnd, c.SW_MINIMIZE);
        try pump(&w, 300);
        var longest: i64 = 0;
        _ = c.QueryPerformanceCounter(&started);
        for (0..waits) |_| {
            if (case[1]) try w.presentPixels(pixels, size, .argb8888);
            var before: c.LARGE_INTEGER = undefined;
            var after: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceCounter(&before);
            _ = c.DwmFlush();
            _ = c.QueryPerformanceCounter(&after);
            longest = @max(longest, @divTrunc((after.QuadPart - before.QuadPart) * 1_000_000, frequency.QuadPart));
        }
        _ = c.QueryPerformanceCounter(&ended);
        const each = @divTrunc((ended.QuadPart - started.QuadPart) * 1_000_000, frequency.QuadPart * waits);
        fact(case[0], "{d} us a frame on average, longest DwmFlush {d} us", .{ each, longest });
        if (case[2]) _ = c.ShowWindow(w.hwnd, c.SW_RESTORE);
    }
    try pump(&w, 300);
    _ = w.takeConfigure();

    _ = c.PostMessageW(w.hwnd, c.WM_CLOSE, 0, 0);
    try pump(&w, 200);
    const closing = w.takeConfigure();
    expect(closing != null and closing.?.size.isEmpty(), "close", "{s}", .{if (closing != null and closing.?.size.isEmpty()) "empty configure" else "no empty configure"});
    expect(c.IsWindow(w.hwnd) != 0, "still open", "the window waits for the owner to close it", .{});

    if (failed) std.process.exit(1);
    std.debug.print("all checks passed\n", .{});
}
