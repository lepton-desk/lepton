//! A polite end on Windows: Ctrl+C, Ctrl+Break, the console closing, the user signing
//! off and the system shutting down become a request the loop sees — the counterpart of
//! SIGTERM/SIGINT/SIGHUP in `platform/linux/termination.zig`.
//!
//! The handler runs on a thread the system creates for it. It stores the event and wakes
//! the window's thread; returning TRUE says the event is handled, so the default action
//! (ending the process at once) does not run and the loop leaves through its `defer`s.
//! For `CTRL_CLOSE_EVENT` and the shutdown events the system still ends the process when
//! the handler returns, so the handler waits — bounded — for the loop to finish first.

const std = @import("std");
const windows = std.os.windows;

var requested_by: std.atomic.Value(u32) = .init(0);
var finished: std.atomic.Value(bool) = .init(false);
var loop_thread: windows.DWORD = 0;

extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL, add: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) windows.DWORD;
extern "kernel32" fn Sleep(ms: windows.DWORD) callconv(.winapi) void;
extern "user32" fn PostThreadMessageW(thread: windows.DWORD, message: u32, wparam: usize, lparam: isize) callconv(.winapi) windows.BOOL;

/// `CTRL_C_EVENT` … `CTRL_SHUTDOWN_EVENT`, plus one so zero means "none".
pub const Cause = enum(u32) { ctrl_c = 1, ctrl_break = 2, close = 3, logoff = 6, shutdown = 7, _ };

/// How long a closing console waits for the loop (the system allows about 5 s).
const close_wait_ms = 4000;

fn handle(event: windows.DWORD) callconv(.winapi) windows.BOOL {
    if (requested_by.swap(event + 1, .seq_cst) != 0 and event <= 1) {
        // A second Ctrl+C before the loop ended: the polite way is stuck.
        std.process.exit(130);
    }
    // WM_NULL wakes a `GetMessageW` that may be asleep until the next timer.
    if (loop_thread != 0) _ = PostThreadMessageW(loop_thread, 0, 0, 0);
    if (event >= 2) {
        var waited: u32 = 0;
        while (!finished.load(.seq_cst) and waited < close_wait_ms) : (waited += 50) Sleep(50);
    }
    return .TRUE;
}

/// Installs the handler. Call once, before the loop, on the loop's thread.
pub fn catchSignals() void {
    loop_thread = GetCurrentThreadId();
    _ = SetConsoleCtrlHandler(&handle, .TRUE);
}

/// Whether the console or the session asked the process to end.
pub fn requested() bool {
    return requested_by.load(.seq_cst) != 0;
}

/// The event that asked; null when none did.
pub fn cause() ?Cause {
    const number = requested_by.load(.seq_cst);
    return if (number == 0) null else @enumFromInt(number);
}

/// The loop has ended: a handler waiting on a closing console may return.
pub fn done() void {
    finished.store(true, .seq_cst);
}
