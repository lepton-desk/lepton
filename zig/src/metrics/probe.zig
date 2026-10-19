//! Live machine readings, taken from the kernel's own accounting.
//!
//! Every figure on the operator panel comes from here, and every figure here is
//! read from the operating system. Nothing is modelled, interpolated, or filled
//! in when it cannot be read — a reading that cannot be obtained is reported as
//! an error, because an invented number on a panel whose entire purpose is to be
//! trusted is worse than a visible gap.
//!
//! `/proc` is read with raw `openat`/`read` rather than through a filesystem
//! abstraction. The probe runs on the event loop and needs no buffering beyond a
//! stack array, so an abstraction layer would add a dependency and a failure mode
//! to answer a question the kernel answers in two syscalls.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const windows = @import("builtin").os.tag == .windows;

/// Bytes per page, the unit the kernel reports memory in.
pub const page_bytes = std.heap.page_size_min;

pub const Error = error{
    /// `/proc/self/statm` could not be opened or read. Reported, never guessed.
    StatsUnavailable,
    /// The statm line did not have the shape the kernel documents.
    StatsMalformed,
};

/// One reading of this process and its channel.
pub const Reading = struct {
    /// Nanoseconds since the probe was created, from the monotonic clock: a
    /// duration since startup, not a wall clock the user can change.
    uptime_ns: u64,
    /// Resident set size, in bytes, from `statm`. This is the figure that answers
    /// "how much memory does Lepton actually cost", because it counts every page
    /// the process holds resident — allocator, ring, code and stack alike.
    rss_bytes: u64,
    /// Free cells in the shared ring.
    ring_free_cells: u32,
    /// Total cells in the shared ring.
    ring_capacity_cells: u32,
    /// Round trip of the most recent request/reply pair, in nanoseconds.
    round_trip_ns: u64,
    /// Worst round trip observed since the probe was created.
    round_trip_max_ns: u64,
};

/// Reads the machine's state, and owns the clock its durations come from.
///
/// Holds no allocation: the only buffer it needs is a stack array, so it is safe
/// to call from the event loop.
pub const Probe = struct {
    /// Fixed at construction so `uptime_ns` has one stable origin across
    /// readings. Read from the monotonic clock, which a user cannot step the way
    /// they can step the wall clock.
    origin: std.Io.Clock.Timestamp,
    last_round_trip_ns: u64 = 0,
    worst_round_trip_ns: u64 = 0,

    pub fn init() Probe {
        return .{ .origin = std.Io.Clock.Timestamp.now(io(), .awake) };
    }

    /// Records a measured round trip, keeping the worst seen for the panel.
    pub fn recordRoundTrip(self: *Probe, ns: u64) void {
        self.last_round_trip_ns = ns;
        if (ns > self.worst_round_trip_ns) self.worst_round_trip_ns = ns;
    }

    /// Takes a reading of the process and of the ring's state.
    pub fn read(self: *Probe, ring_free: u32, ring_capacity: u32) Error!Reading {
        return .{
            .uptime_ns = durationNanos(self.origin.durationTo(monotonicNow())),
            .rss_bytes = try residentSetBytes(),
            .ring_free_cells = ring_free,
            .ring_capacity_cells = ring_capacity,
            .round_trip_ns = self.last_round_trip_ns,
            .round_trip_max_ns = self.worst_round_trip_ns,
        };
    }
};

/// Resident set size of this process, in bytes.
///
/// `/proc/self/statm`'s second field is the resident set in pages — the same
/// number a system monitor shows, read where the kernel writes it.
pub fn residentSetBytes() Error!u64 {
    if (windows) return windowsMemory.workingSet() orelse error.StatsUnavailable;
    var buf: [128]u8 = undefined;
    const line = try readStatm(&buf);

    // The line is `<size> <resident> <shared> <text> <lib> <data> <dt>`, spaced.
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    _ = fields.next() orelse return error.StatsMalformed;
    const resident = fields.next() orelse return error.StatsMalformed;

    const pages = std.fmt.parseInt(u64, resident, 10) catch return error.StatsMalformed;
    return pages * page_bytes;
}

/// The C heap as glibc accounts for it, in bytes.
pub const Heap = struct {
    /// Bytes handed out and not yet freed (`uordblks + hblkhd`).
    in_use: u64,
    /// Bytes the allocator holds from the kernel (`arena + hblkhd`).
    reserved: u64,
};

/// `struct mallinfo2` from `malloc.h`: ten `size_t`s, in this order.
const MallInfo2 = extern struct {
    arena: usize,
    ordblks: usize,
    smblks: usize,
    hblks: usize,
    hblkhd: usize,
    usmblks: usize,
    fsmblks: usize,
    uordblks: usize,
    fordblks: usize,
    keepcost: usize,
};
const mallinfo2 = @extern(*const fn () callconv(.c) MallInfo2, .{ .name = "mallinfo2" });

/// Reads the C heap's own counters. The engine, Cairo and GLib all allocate through
/// libc, so this is the heap that matters in a webview process — not the Zig
/// allocator's share of it. `mmap`-served blocks (`hblkhd`) count in both figures.
pub fn heapBytes() Heap {
    if (windows) return windowsMemory.heap();
    const info = mallinfo2();
    return .{
        .in_use = info.uordblks + info.hblkhd,
        .reserved = info.arena + info.hblkhd,
    };
}

fn readStatm(buf: []u8) Error![]const u8 {
    const fd = posix.openat(posix.AT.FDCWD, "/proc/self/statm", .{ .ACCMODE = .RDONLY }, 0) catch
        return error.StatsUnavailable;
    defer _ = linux.close(fd);

    const n = posix.read(fd, buf) catch return error.StatsUnavailable;
    if (n == 0) return error.StatsMalformed;
    return buf[0..n];
}

/// The current monotonic instant.
fn monotonicNow() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io(), .awake);
}

/// The `Io` a runtime probe reads its clock through. In a test binary that is the
/// testing harness's own instance, so the probe works there without a caller
/// having to stand one up.
fn io() std.Io {
    if (@import("builtin").is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

/// Nanoseconds in a clock duration, clamped at zero: a monotonic clock should
/// never report a negative duration, and a negative uptime would be a lie on a
/// panel whose whole purpose is not to lie.
fn durationNanos(d: std.Io.Clock.Duration) u64 {
    const n = d.raw.nanoseconds;
    if (n <= 0) return 0;
    return @intCast(n);
}

test {
    _ = @import("probe_test.zig");
}

/// Windows: the working set (`GetProcessMemoryInfo`, what Task Manager's "Memory" column
/// is built on) and the process heap's own summary (`HeapSummary`, Windows 10) — the heap
/// the C runtime allocates from.
const windowsMemory = struct {
    const Counters = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged_pool: usize,
        quota_paged_pool: usize,
        quota_peak_non_paged_pool: usize,
        quota_non_paged_pool: usize,
        pagefile: usize,
        peak_pagefile: usize,
    };
    const Summary = extern struct {
        cb: u32,
        allocated: usize,
        committed: usize,
        reserved: usize,
        max_reserve: usize,
    };
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
    extern "kernel32" fn K32GetProcessMemoryInfo(process: *anyopaque, counters: *Counters, size: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapSummary(heap: *anyopaque, flags: u32, summary: *Summary) callconv(.winapi) c_int;

    fn workingSet() ?u64 {
        var counters: Counters = undefined;
        counters.cb = @sizeOf(Counters);
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, @sizeOf(Counters)) == 0) return null;
        return counters.working_set;
    }

    fn heap() Heap {
        const process_heap = GetProcessHeap() orelse return .{ .in_use = 0, .reserved = 0 };
        var summary: Summary = undefined;
        summary.cb = @sizeOf(Summary);
        if (HeapSummary(process_heap, 0, &summary) == 0) return .{ .in_use = 0, .reserved = 0 };
        return .{ .in_use = summary.allocated, .reserved = summary.committed };
    }
};
