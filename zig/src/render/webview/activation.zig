//! Whether the person at the machine has just used this window: a key or button pressed
//! within the last `window_ms`.
//!
//! What lets a command such as `clipboard.read_text` answer only right after the user acts,
//! as a browser lets a page read the clipboard only during a gesture. The page cannot
//! fake it: the page's scripts all hold the transport and its key (`secret.zig`), so a
//! check made in the page would be one a script injected there skips. The time comes from
//! the engine's input as the core sees it — WPE's view `event` signal (`wpe_view.zig`),
//! Servo's input the core forwards itself (`servo/view.zig`) — and on Windows, where the
//! input goes to WebView2's own window, from `GetLastInputInfo` while one of this process's
//! windows is in front.

const std = @import("std");
const builtin = @import("builtin");

/// How long after a press the user counts as acting: a browser's transient activation
/// lasts about as long (Chromium: 5 s).
pub const window_ms: u64 = 5000;

var last_press_ms: std.atomic.Value(u64) = .init(0);

fn nowMs() u64 {
    if (builtin.os.tag == .windows) return windows.GetTickCount64();
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

/// A key or button went down in this window.
pub fn press() void {
    last_press_ms.store(nowMs(), .seq_cst);
}

/// Whether a press came within the last `window_ms`.
pub fn recent() bool {
    if (builtin.os.tag == .windows) return windows.recent();
    return within(last_press_ms.load(.seq_cst), nowMs());
}

fn within(pressed_ms: u64, now_ms: u64) bool {
    return pressed_ms != 0 and now_ms -| pressed_ms <= window_ms;
}

const windows = struct {
    const LastInputInfo = extern struct { size: u32, time: u32 };
    extern "user32" fn GetLastInputInfo(info: *LastInputInfo) callconv(.winapi) i32;
    extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetWindowThreadProcessId(window: ?*anyopaque, process: ?*u32) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount() callconv(.winapi) u32;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

    /// The system's last input, counted only while a window of this process is in front:
    /// input to another application is not this user acting here. `GetLastInputInfo` counts
    /// in `GetTickCount`'s 32-bit milliseconds, so the difference is taken there.
    fn recent() bool {
        var owner: u32 = 0;
        _ = GetWindowThreadProcessId(GetForegroundWindow(), &owner);
        if (owner != GetCurrentProcessId()) return false;
        var info: LastInputInfo = .{ .size = @sizeOf(LastInputInfo), .time = 0 };
        if (GetLastInputInfo(&info) == 0) return false;
        return GetTickCount() -% info.time <= window_ms;
    }
};

test "a press counts for the window and not after" {
    try std.testing.expect(!within(0, 10_000));
    try std.testing.expect(within(10_000, 10_000 + window_ms));
    try std.testing.expect(!within(10_000, 10_001 + window_ms));
    last_press_ms.store(0, .seq_cst);
    try std.testing.expect(!recent());
    press();
    try std.testing.expect(recent());
    last_press_ms.store(0, .seq_cst);
}
