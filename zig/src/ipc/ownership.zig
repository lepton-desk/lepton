//! Ownership records: which process owns a shared-memory name, and whether it is
//! still there.
//!
//! ## Why this file exists
//!
//! A POSIX shared-memory object outlives the process that created it. `Channel.create`
//! uses `O_EXCL` so two windows can never silently share a ring they did not negotiate
//! — the right choice, with a consequence: a window that is killed leaves its name
//! behind and every later launch fails with `AlreadyExists` forever. Measured, not
//! theorised — a `timeout`-killed scaffold binary leaves `/dev/shm/lepton-ledger`
//! present and the next start is refused.
//!
//! Unlinking the name from a tool fixes the symptom and destroys a live peer's ring
//! the moment two instances overlap. Correctness needs to know whether the previous
//! owner is still running, which is the only question this file answers.
//!
//! ## How
//!
//! A second, tiny shared-memory segment per channel: `<name>.owner`. Deliberately not
//! a field in the ring's header — `HEADER_BYTES` and every offset after it are
//! mirrored by name in `assets/lepton.ts`, and changing the layout would mean changing
//! two languages at once for a field only this file reads.
//!
//! The record names the owner by `(pid, start_ticks)`. The pid alone is not an
//! identity: a killed window's number can be handed to an unrelated process, and the
//! name then looks live forever. `start_ticks` is the kernel's own record of when that
//! process began, so a reused pid carries a different value and reads as dead.
//!
//! The segment is created with `O_EXCL`, which is what makes taking over safe: when two
//! processes both decide the previous owner is dead, exactly one wins the exclusive
//! create and the other is told the name is held. There is no window in which both
//! believe they own it.

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const shm = @import("shm.zig");

const c = @cImport({
    @cInclude("signal.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});

/// Suffix appended to a channel name to form its ownership segment.
pub const suffix = ".owner";

pub const Error = error{
    /// A live process already owns this name. Not a fault: it is the correct answer to
    /// "may I start", and the caller turns it into a refusal rather than a retry.
    Held,
    /// Two processes kept displacing each other's ownership records. Bounded on
    /// purpose — an unbounded retry is an application that never starts and never says
    /// why.
    Contended,
    /// This process could not establish its own identity, so it cannot claim anything.
    /// Refusing beats claiming under a name nothing can verify.
    NoSelfIdentity,
} || shm.Error;

/// Identifies one process, unambiguously.
pub const Identity = struct {
    pid: u32,
    /// The kernel's start time for `pid`, in clock ticks since boot. Zero means "could
    /// not be read", and every comparison treats zero as a mismatch rather than a match:
    /// an identity that cannot be established must never prove liveness.
    start_ticks: u64,
};

/// What is written into the ownership segment.
///
/// Laid out so a zeroed segment — what a fresh file reads as before anyone writes, and
/// what a torn write leaves — has `pid == 0`, and pid 0 is never a real owner. `magic`
/// is a second, independent way to recognise the same thing, so neither check has to be
/// trusted alone.
const Record = extern struct {
    magic: u64,
    version: u32,
    pid: u32,
    start_ticks: u64,
};

const magic: u64 = 0x4C50_4F57_4E5F_3031; // "LP_OWN_01"
const version: u32 = 1;

/// The ownership segment, held for as long as this process owns the name.
pub const Claim = struct {
    region: shm.Region,

    /// Unmaps and removes the segment. A window that exits cleanly leaves nothing
    /// behind, so the next launch never has to reason about a corpse.
    pub fn deinit(self: *Claim, allocator: Allocator) void {
        self.region.deinit(allocator);
        self.* = undefined;
    }
};

/// Takes ownership of `name`, or reports that a live process already has it.
///
/// The one function callers need. Every branch either returns a claim this process
/// holds or refuses; there is no state in which it returns without saying which.
pub fn acquire(allocator: Allocator, name: []const u8) Error!Claim {
    const owner_name = try ownerName(allocator, name);
    defer allocator.free(owner_name);

    const me = identity() orelse return Error.NoSelfIdentity;

    // Bounded because a correct algorithm still has a loser: both processes may read
    // "dead", and only one may win the exclusive create. Four is far more than two
    // racing starters need, and a number that cannot spin forever.
    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        if (shm.create(allocator, owner_name, @sizeOf(Record))) |region| {
            const claim = Claim{ .region = region };
            writeRecord(claim.region.bytes, me);
            return claim;
        } else |failure| switch (failure) {
            error.AlreadyExists => {},
            else => return failure,
        }

        // Someone holds the record. The only question that matters is whether they are
        // still there.
        //
        // `name`, not `owner_name`: `inspect` appends the suffix itself. Passing the
        // already-suffixed name looks for `.owner.owner`, finds nothing, reports
        // `absent`, and this loop then deletes a live owner's own record.
        switch (try inspect(allocator, name)) {
            .live => return error.Held,
            .stale, .absent => {
                // Removing the corpse's record is what lets the next attempt win it. If
                // it is already gone, another process got there first, which is exactly
                // the race this loop is written for.
                shm.unlink(allocator, owner_name) catch |e| switch (e) {
                    error.NotFound => {},
                    else => return e,
                };
            },
        }
    }

    return error.Contended;
}

/// What a peek at an ownership record found.
pub const Liveness = enum {
    /// The named process exists and is the one that wrote the record.
    live,
    /// The record names a process that is gone, or names nothing.
    stale,
    /// No record exists. The name's previous owner died before it wrote one.
    absent,
};

/// Reads `name`'s ownership record and decides whether its owner is still running.
///
/// Separate from `acquire` because "is the previous owner alive" is a question worth
/// asking without claiming anything — a tool deciding whether to offer a reset wants
/// to know before it destroys anything.
pub fn inspect(allocator: Allocator, name: []const u8) Error!Liveness {
    const owner_name = try ownerName(allocator, name);
    defer allocator.free(owner_name);

    var region = shm.attach(allocator, owner_name) catch |e| switch (e) {
        error.NotFound => return .absent,
        else => return e,
    };
    // `deinit` rather than `close` plus a manual free: an attached region has
    // `owner == false`, so this unmaps and releases the name without unlinking a record
    // that belongs to whichever process wrote it.
    defer region.deinit(allocator);

    if (region.bytes.len < @sizeOf(Record)) return .stale;

    const record: *align(1) const Record = @ptrCast(region.bytes.ptr);
    if (record.magic != magic or record.version != version) return .stale;
    if (record.pid == 0) return .stale;

    return if (alive(.{ .pid = record.pid, .start_ticks = record.start_ticks })) .live else .stale;
}

/// This process's own identity, or null when it cannot be established.
fn identity() ?Identity {
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
fn alive(who: Identity) bool {
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

fn writeRecord(bytes: []u8, who: Identity) void {
    const record: *align(1) Record = @ptrCast(bytes.ptr);
    record.* = .{
        .magic = magic,
        .version = version,
        .pid = who.pid,
        .start_ticks = who.start_ticks,
    };
}

/// The ownership segment's name for a channel.
///
/// Built here rather than by the caller so exactly one place knows the suffix, and so a
/// channel name that already ends in it cannot be confused with its own record.
fn ownerName(allocator: Allocator, name: []const u8) Error![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ name, suffix }, 0);
}

// ── Tests ───────────────────────────────────────────────────────────────────────
//
// Everything below runs against real kernel objects and this process's real identity.
// There is no simulation here because there is nothing to simulate: the question is
// whether `/proc` says what this file claims it says.

test "this process's identity reads back the same way twice" {
    // The whole design rests on one assumption: a pid plus a start time identifies a
    // process, and this process can read its own. If the field offset were wrong, every
    // later check would compare two wrong numbers and agree with itself forever.
    const first = identity() orelse return error.NoSelfIdentity;
    const second = identity() orelse return error.NoSelfIdentity;

    try testing.expectEqual(first.pid, second.pid);
    try testing.expectEqual(first.start_ticks, second.start_ticks);

    // And it must agree with what `alive` concludes about that same identity, which is
    // the only consumer of the number.
    try testing.expect(alive(first));

    // A pid that cannot exist must not read as alive. 0 is never a process.
    try testing.expect(!alive(.{ .pid = 0, .start_ticks = 0 }));
}

test "a start time is not interchangeable with any other" {
    const me = identity() orelse return error.NoSelfIdentity;

    // Exactly what pid reuse looks like from here: the pid is right, the process it
    // named is not. Reporting this as live is what would make a name look held forever.
    try testing.expect(!alive(.{
        .pid = me.pid,
        .start_ticks = me.start_ticks + 1,
    }));
}

test "a record naming this process is held, and a clean release leaves nothing" {
    var buffered: [96]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buffered, "/lepton-own-live-{d}", .{c.getpid()}) catch unreachable;
    defer _ = shm.unlink(testing.allocator, name) catch {};

    var first = try acquire(testing.allocator, name);
    try testing.expectEqual(Liveness.live, try inspect(testing.allocator, name));

    // The refusal is the point: a second window must not take a name a running one is
    // publishing into.
    try testing.expectError(error.Held, acquire(testing.allocator, name));

    first.deinit(testing.allocator);

    // And a clean exit must leave nothing behind, or the next launch inherits a corpse
    // it has to reason about.
    try testing.expectEqual(Liveness.absent, try inspect(testing.allocator, name));
}

test "a record naming a process that is not this one is taken over" {
    var buffered: [96]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buffered, "/lepton-own-reused-{d}", .{c.getpid()}) catch unreachable;

    const owner = try ownerName(testing.allocator, name);
    defer testing.allocator.free(owner);

    const me = identity() orelse return error.NoSelfIdentity;
    const region = try shm.create(testing.allocator, owner, @sizeOf(Record));
    var corpse = Claim{ .region = region };

    // This process, with a start time that is not its own: the exact on-disk state a
    // killed window leaves once the kernel has handed its number to someone else. The
    // pid alone cannot tell those apart, which is what the start time is for.
    writeRecord(corpse.region.bytes, .{
        .pid = me.pid,
        .start_ticks = me.start_ticks + 1,
    });

    // Closed but deliberately not unlinked: the name must survive long enough to be
    // inspected, and `acquire` below is what removes it. Freeing the mapping does not
    // free the kernel object, which is the whole reason a corpse outlives its process.
    corpse.region.close();
    testing.allocator.free(@constCast(corpse.region.name));
    defer _ = shm.unlink(testing.allocator, owner) catch {};

    try testing.expectEqual(Liveness.stale, try inspect(testing.allocator, name));

    // Taken over, because the process it names is not the one that wrote it.
    var taken = try acquire(testing.allocator, name);
    taken.deinit(testing.allocator);
}

test "a zeroed record is stale, not a live process named zero" {
    var buffered: [96]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buffered, "/lepton-own-zero-{d}", .{c.getpid()}) catch unreachable;

    const owner = try ownerName(testing.allocator, name);
    defer testing.allocator.free(owner);

    const region = try shm.create(testing.allocator, owner, @sizeOf(Record));
    var empty = Claim{ .region = region };
    defer empty.deinit(testing.allocator);

    // Exactly what a fresh segment reads as. Calling that a live owner named pid 0
    // would make every first launch wait for a process that does not exist.
    @memset(empty.region.bytes, 0);
    try testing.expectEqual(Liveness.stale, try inspect(testing.allocator, name));
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
