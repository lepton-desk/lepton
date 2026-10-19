//! Process identity on Linux: a pid plus the kernel's start time, read from `/proc`.
//!
//! Split out of `ownership.zig` so the Windows build has its own (`process_windows.zig`);
//! the reasoning about pid reuse and zombies is unchanged.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});

/// Identifies one process, unambiguously.
pub const Identity = struct {
    pid: u32,
    /// The kernel's start time for `pid`, in clock ticks since boot. Zero means "could
    /// not be read", and every comparison treats zero as a mismatch rather than a match:
    /// an identity that cannot be established must never prove liveness.
    start_ticks: u64,
};

/// This process's pid, for names that must not collide between test runs.
pub fn currentPid() u32 {
    return @intCast(c.getpid());
}

/// This process's own identity, or null when it cannot be established.
pub fn identity() ?Identity {
    // `getpid` cannot fail and cannot be wrong, so there is nothing to check beyond
    // the sign.
    const raw = c.getpid();
    if (raw <= 0) return null;

    const pid: u32 = @intCast(raw);
    return .{
        .pid = pid,
        // Read best-effort. A zero here makes this process fail its own liveness check
        // later, which is the safe direction: a process that cannot prove it is alive
        // must not be able to block others by looking alive when it is not.
        .start_ticks = startTicks(pid) orelse 0,
    };
}

/// Whether an identity still refers to a running process.
///
/// Two questions, not one, and the second is the one that matters. "Does this pid
/// exist" is answered by signal 0; "is it the same process that wrote the record" is
/// answered by comparing the kernel's start time, and only that comparison makes a
/// reused pid read as dead.
pub fn alive(who: Identity) bool {
    // Signal 0, never a named signal. `kill` with 0 performs the permission and
    // existence checks and delivers nothing, which is the only way to ask "is this
    // process there" without touching it. Writing `.KILL` here instead produces a
    // working liveness check that kills the caller's own process the first time it
    // runs, so the number is spelled `0` and never taken from `signal.h`.
    const status = c.kill(@intCast(who.pid), 0);
    if (status != 0) {
        return switch (posix.errno(status)) {
            // The one answer that means gone. `ESRCH` is specifically "no such process"
            // and is the only errno here that means it.
            .SRCH => false,
            // `EPERM` means the process exists and belongs to someone else. Reporting
            // that as dead would let a second window destroy a running one's channel.
            else => true,
        };
    }

    // Reachable only for a process we may signal, so its `/proc` entry is readable too.
    // A pid that has since been reused passes the check above and fails this one.
    const stat = readStat(who.pid) orelse return false;
    return stat.running() and stat.start_ticks == who.start_ticks;
}

/// The kernel's start time for `pid`, in clock ticks since boot.
///
/// Read from `/proc/<pid>/stat` field 22. The file's second field is the executable
/// name in parentheses and may itself contain spaces and parentheses, so the fields
/// after it are counted from the *last* `)` rather than by splitting the whole line — a
/// command called `sh -c 'echo ) hi'` would otherwise shift every field after it.
fn startTicks(pid: u32) ?u64 {
    const stat = readStat(pid) orelse return null;
    return stat.start_ticks;
}

/// The two fields of `/proc/<pid>/stat` this file reads.
pub const Stat = struct {
    /// `R`, `S`, `D`, … — `Z` for a zombie (exited, not yet reaped by its parent) and
    /// `X` for a dead one.
    state: u8,
    start_ticks: u64,

    /// Whether the process still runs. A zombie keeps its pid and start time, so the
    /// identity check alone read one as live — measured: `lepton run` had not reaped an
    /// application whose pipes a browser it launched held open, and the next start was
    /// refused with `Held`.
    pub fn running(self: Stat) bool {
        return self.state != 'Z' and self.state != 'X';
    }
};

fn readStat(pid: u32) ?Stat {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;

    const file = c.fopen(path.ptr, "r") orelse return null;
    defer _ = c.fclose(file);

    // One line, well under a kilobyte even for a process with thousands of threads. A
    // line that does not fit is not a case worth handling more carefully than refusing
    // to answer.
    var line: [1024]u8 = undefined;
    const read = c.fread(&line, 1, line.len, file);
    if (read == 0) return null;

    return parseStat(line[0..read]);
}

/// Reads `state` and `starttime` from a `/proc/<pid>/stat` line.
pub fn parseStat(text: []const u8) ?Stat {
    const close_at = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close_at + 2 >= text.len) return null;

    // Field 3 (`state`) is the first after the name; `starttime` is field 22, so it is
    // the twentieth of them.
    var fields = std.mem.tokenizeScalar(u8, text[close_at + 2 ..], ' ');
    var seen: usize = 0;
    var state: u8 = 0;
    while (fields.next()) |field| : (seen += 1) {
        if (seen == 0) state = field[0];
        if (seen != 19) continue;
        const ticks = std.fmt.parseInt(u64, field, 10) catch return null;
        return .{ .state = state, .start_ticks = ticks };
    }

    return null;
}

test "a zombie with the same start time is not a live owner" {
    // Lines in `/proc/<pid>/stat` form, written for the test: a sleeping process, and a
    // zombie like the one that held a channel (its state field read `Z` in `ps`).
    const sleeping = "36905 (lepton) S 36904 36904 6984 0 -1 4194560 2716 0 0 0 23 7 0 0 20 0 4 0 568000 1 2 3";
    const zombie = "37090 (rec-notes) Z 36905 36904 6984 0 -1 4227084 0 0 0 0 0 0 0 0 20 0 1 0 568034 0 0 0";
    const awake = parseStat(sleeping).?;
    try testing.expect(awake.running());
    try testing.expectEqual(@as(u64, 568000), awake.start_ticks);
    const dead = parseStat(zombie).?;
    try testing.expect(!dead.running());
    try testing.expectEqual(@as(u64, 568034), dead.start_ticks);
    // A name with spaces and parentheses does not shift the fields.
    const odd = parseStat("7 (sh -c ) x) Z 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 99 0 0 0").?;
    try testing.expectEqual(@as(u8, 'Z'), odd.state);
    try testing.expectEqual(@as(u64, 99), odd.start_ticks);
}
