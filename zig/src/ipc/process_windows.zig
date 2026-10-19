//! Process identity on Windows: a pid plus the process's creation time.
//!
//! The counterpart of `process_linux.zig`. A pid is reused on Windows too, so the pid
//! alone is not an identity; the creation time (`GetProcessTimes`, 100 ns since 1601) is
//! the kernel's record of when that process began, and a reused pid carries another.
//! A process that has exited but whose object is still referenced keeps both, so
//! liveness also asks for its exit code — the counterpart of Linux's zombie check.

const std = @import("std");
const windows = std.os.windows;

/// Identifies one process, unambiguously.
pub const Identity = struct {
    pid: u32,
    /// The creation time as a `FILETIME` read as one number. Zero means "could not be
    /// read" and never matches.
    start_ticks: u64,
};

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, pid: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, code: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetProcessTimes(
    process: windows.HANDLE,
    creation: *windows.FILETIME,
    exit: *windows.FILETIME,
    kernel: *windows.FILETIME,
    user: *windows.FILETIME,
) callconv(.winapi) windows.BOOL;

/// `PROCESS_QUERY_LIMITED_INFORMATION`: enough for times and exit code, granted for
/// other users' processes too (Vista+).
const query_limited: windows.DWORD = 0x1000;
const still_active: windows.DWORD = 259;
const error_access_denied: windows.DWORD = 5;

pub fn currentPid() u32 {
    return GetCurrentProcessId();
}

/// This process's own identity, or null when it cannot be established.
pub fn identity() ?Identity {
    const pid = GetCurrentProcessId();
    if (pid == 0) return null;
    return .{ .pid = pid, .start_ticks = creationOf(GetCurrentProcess()) orelse 0 };
}

/// Whether an identity still refers to a running process.
pub fn alive(who: Identity) bool {
    if (who.pid == 0) return false;
    const handle = OpenProcess(query_limited, .FALSE, who.pid) orelse {
        // The process exists but is not ours to query (another user, a protected
        // process): reading that as dead would let a second window take a live one's
        // channel, the same choice `EPERM` makes on Linux.
        return GetLastError() == error_access_denied;
    };
    defer _ = CloseHandle(handle);
    var code: windows.DWORD = 0;
    if (GetExitCodeProcess(handle, &code) == .FALSE or code != still_active) return false;
    const started = creationOf(handle) orelse return false;
    return who.start_ticks != 0 and started == who.start_ticks;
}

fn creationOf(handle: windows.HANDLE) ?u64 {
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (GetProcessTimes(handle, &creation, &exit, &kernel, &user) == .FALSE) return null;
    const value = (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
    return if (value == 0) null else value;
}
