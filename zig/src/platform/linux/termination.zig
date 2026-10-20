//! A polite end: SIGTERM, SIGINT and SIGHUP become a request the loop sees, so the core
//! leaves through its `defer`s instead of dying where it stands.
//!
//! Measured before this: with no handler the default action killed the core outright, no
//! `defer` ran, and each application stopped by a signal — `lepton run`'s Ctrl+C, a
//! session ending, `lepton package --verify`'s SIGTERM — left its channel in `/dev/shm`
//! (`lepton-<id>`, `-rtt`, and both `.owner` records). Six applications' worth had piled
//! up on the development machine.
//!
//! The handler only stores a flag (all a signal handler may safely do). The loop wakes on
//! its own timer at least every 250 ms, and a signal also interrupts the engine's `poll`,
//! so the next turn sees the request at once. A second signal a second or more after the
//! first means the polite way is stuck: the process ends there, as it would have without
//! this. One sooner is the same request arriving twice: Ctrl+C in a terminal reaches the
//! application and `lepton dev`/`run`, which then sends SIGTERM too. Ending on that one
//! left the channel behind (measured: SIGINT then SIGTERM left all four files; either
//! alone left none).

const std = @import("std");
const posix = std.posix;

var requested_by: std.atomic.Value(u8) = .init(0);
/// When the first signal arrived, in monotonic nanoseconds.
var first_at: std.atomic.Value(u64) = .init(0);

/// How long after the first signal a second one is still the same request.
const same_request_ns: u64 = std.time.ns_per_s;

/// Monotonic now; `clock_gettime` is async-signal-safe.
fn monotonicNs() u64 {
    var now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

const caught = [_]posix.SIG{ .TERM, .INT, .HUP };

fn handle(signal: posix.SIG) callconv(.c) void {
    const number: u8 = @intCast(@intFromEnum(signal));
    const now = monotonicNs();
    // The time first, so a second signal that interrupts this handler never reads it unset.
    _ = first_at.cmpxchgStrong(0, now, .seq_cst, .seq_cst);
    if (requested_by.cmpxchgStrong(0, number, .seq_cst, .seq_cst) == null) return;
    if (now -| first_at.load(.seq_cst) >= same_request_ns) {
        // 128 + the signal, the status a shell reports for a process the signal ended.
        std.c._exit(128 + @as(c_int, number));
    }
}

/// Installs the handler. Call once, before the loop.
pub fn catchSignals() void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handle },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    for (caught) |signal| posix.sigaction(signal, &action, null);
}

/// Whether a termination signal has arrived: the loop's cue to end.
pub fn requested() bool {
    return requested_by.load(.seq_cst) != 0;
}

/// The signal that asked, for a closing line; null when none did.
pub fn cause() ?posix.SIG {
    const number = requested_by.load(.seq_cst);
    return if (number == 0) null else @enumFromInt(number);
}

test "a termination signal is a request, not an end" {
    var previous: [caught.len]posix.Sigaction = undefined;
    for (caught, 0..) |each, index| posix.sigaction(each, null, &previous[index]);
    defer for (caught, 0..) |each, index| posix.sigaction(each, &previous[index], null);
    defer requested_by.store(0, .seq_cst);
    defer first_at.store(0, .seq_cst);

    catchSignals();
    try std.testing.expect(!requested());
    // Still running after the kernel delivered it: the default action would have ended
    // the test runner here.
    _ = std.c.raise(.INT);
    try std.testing.expect(requested());
    try std.testing.expectEqual(posix.SIG.INT, cause().?);
    // Ctrl+C reaches the app and `lepton dev`, which sends SIGTERM at once: still the
    // same request, so the loop still ends politely (here: the runner keeps running).
    _ = std.c.raise(.TERM);
    try std.testing.expectEqual(posix.SIG.INT, cause().?);
}
