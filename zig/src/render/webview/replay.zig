//! Replaying a recording (`record.zig`) against this core, without a window: every
//! recorded request goes to the real `invoke.handle` with the application's own registry,
//! and the reply is compared with the recorded one byte for byte —
//! `LEPTON_REPLAY=<file>`, run by `lepton replay`.
//!
//! Some requests are not run again, and the recorded reply stands ("kept"):
//! - a masked one: its argument was left out, so there is nothing to run;
//! - a deferred one (a file dialog): it waited for the user, and a replay must not;
//! - a window command: there is no window, and closing or resizing one is not the
//!   application's logic.
//!
//! A replay also times every request it runs, beside the time it took when recorded, so
//! the same recording compares two builds.

const std = @import("std");
const wire = @import("../../ipc/wire.zig");
const invoke = @import("invoke.zig");
const record = @import("record.zig");

pub const Summary = struct {
    same: u32 = 0,
    differs: u32 = 0,
    kept: u32 = 0,
    /// Nanoseconds the requests that ran took when recorded, and in this replay.
    recorded_ns: u64 = 0,
    replayed_ns: u64 = 0,
    /// The recording stops part-way through its last record.
    truncated: bool = false,

    pub fn passed(self: Summary) bool {
        return self.differs == 0;
    }
};

pub const Error = record.ReadError || error{ NoSpaceLeft, WriteFailed };

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Why a request is not run again, or null when it is.
fn keptBecause(request: record.Record) ?[]const u8 {
    if (request.flags.masked) return "private, recorded without its bytes";
    if (request.flags.deferred) return "answered later; the recorded answer stands";
    const command = record.commandOf(request.frame) orelse return null;
    return switch (@as(invoke.Command, @enumFromInt(command))) {
        .window_close, .window_minimize, .window_maximize, .window_unmaximize, .window_state => "needs the window",
        else => null,
    };
}

fn statusOf(frame: []const u8) ?invoke.Status {
    if (frame.len < wire.header_bytes) return null;
    const answer = wire.readPayload(wire.Reply, frame[wire.header_bytes..]) catch return null;
    return @enumFromInt(answer.status);
}

/// The reply recorded right after a request; `late_reply`s that came in between belong
/// to other requests.
fn replyAfter(reader: *record.Reader) record.ReadError!?record.Record {
    while (try reader.next()) |next| {
        switch (next.kind) {
            .reply => return next,
            .late_reply => continue,
            else => return null,
        }
    }
    return null;
}

/// Replays `bytes` against `registry`, one report line per request that was kept or
/// differs, then a summary line.
pub fn run(bytes: []const u8, registry: *const invoke.Registry, report: *std.Io.Writer, out: []u8) Error!Summary {
    var reader = try record.Reader.init(bytes);
    var summary: Summary = .{};
    while (true) {
        const request = reader.next() catch |err| switch (err) {
            error.Truncated => {
                summary.truncated = true;
                break;
            },
            else => return err,
        } orelse break;
        if (request.kind != .request) continue;
        const name = if (record.commandOf(request.frame)) |id| registry.nameOf(id) orelse "unknown command" else "malformed request";

        if (keptBecause(request)) |why| {
            summary.kept += 1;
            try report.print("kept     {s}: {s}\n", .{ name, why });
            if (!request.flags.deferred) {
                // Its reply was recorded right after it; step over it.
                const before = reader;
                if ((replyAfter(&reader) catch null) == null) reader = before;
            }
            continue;
        }

        const recorded = replyAfter(&reader) catch |err| switch (err) {
            error.Truncated => null,
            else => return err,
        } orelse {
            // The process ended before it answered: nothing to compare.
            summary.kept += 1;
            summary.truncated = true;
            try report.print("kept     {s}: no reply was recorded\n", .{name});
            break;
        };

        var effects: invoke.Effects = .{};
        const started = std.Io.Clock.Timestamp.now(io(), .awake);
        const replayed = try invoke.handle(request.frame, registry, .{}, &effects, out);
        const took = started.durationTo(std.Io.Clock.Timestamp.now(io(), .awake)).raw.nanoseconds;
        summary.replayed_ns += if (took < 0) 0 else @intCast(took);
        summary.recorded_ns += recorded.at_ns -| request.at_ns;

        if (std.mem.eql(u8, replayed, recorded.frame)) {
            summary.same += 1;
            continue;
        }
        summary.differs += 1;
        const was = statusOf(recorded.frame) orelse .malformed;
        const now = statusOf(replayed) orelse .malformed;
        if (was != now) {
            try report.print("differs  {s}: recorded {t}, now {t}\n", .{ name, was, now });
        } else {
            try report.print("differs  {s}: same status ({t}), other result ({d} bytes recorded, {d} now)\n", .{
                name, was, recorded.frame.len -| wire.header_bytes -| @sizeOf(wire.Reply), replayed.len -| wire.header_bytes -| @sizeOf(wire.Reply),
            });
        }
    }
    try report.print("replay   {d} same, {d} differ, {d} kept{s}; {d} µs recorded, {d} µs now\n", .{
        summary.same,
        summary.differs,
        summary.kept,
        if (summary.truncated) " (the recording ends part-way)" else "",
        summary.recorded_ns / std.time.ns_per_us,
        summary.replayed_ns / std.time.ns_per_us,
    });
    return summary;
}

/// The file `LEPTON_REPLAY` names, or null when this run is not a replay.
pub fn requested() ?[*:0]const u8 {
    const path = std.c.getenv("LEPTON_REPLAY") orelse return null;
    return if (path[0] == 0) null else path;
}

/// Replays the file `LEPTON_REPLAY` names against `registry`, prints the report on
/// stderr and ends the process: 0 when every request that ran matched, 1 when one
/// differs, 2 when the file could not be replayed at all.
pub fn runFromEnvironment(allocator: std.mem.Allocator, registry: *const invoke.Registry) noreturn {
    const path = requested() orelse std.process.exit(2);
    const bytes = readWhole(allocator, path) orelse {
        std.debug.print("replay   cannot read {s}\n", .{path});
        std.process.exit(2);
    };
    defer allocator.free(bytes);
    const out = allocator.alloc(u8, invoke.max_reply) catch std.process.exit(2);
    defer allocator.free(out);
    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    const summary = run(bytes, registry, &report.writer, out) catch |err| {
        std.debug.print("{s}replay   {s}: {t}\n", .{ report.written(), path, err });
        std.process.exit(2);
    };
    std.debug.print("{s}", .{report.written()});
    std.process.exit(if (summary.passed()) 0 else 1);
}

pub fn readWhole(allocator: std.mem.Allocator, path: [*:0]const u8) ?[]u8 {
    const linux = std.os.linux;
    var info: linux.Statx = undefined;
    if (linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true }, &info) != 0) return null;
    const bytes = allocator.alloc(u8, @intCast(info.size)) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) {
        allocator.free(bytes);
        return null;
    }
    defer _ = std.c.close(fd);
    var got: usize = 0;
    while (got < bytes.len) {
        const read = std.c.read(fd, bytes[got..].ptr, bytes.len - got);
        if (read <= 0) {
            allocator.free(bytes);
            return null;
        }
        got += @intCast(read);
    }
    return bytes;
}

const registry_mod = @import("registry.zig");

const Tally = struct { calls: u32 = 0 };

fn upper(_: *Tally, argument: []const u8, out: []u8) registry_mod.HandlerError!usize {
    if (argument.len > out.len) return error.TooLarge;
    for (argument, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return argument.len;
}

/// Answers how many times it ran: the same recording gives another answer when the
/// state it ran against was different.
fn count(state: *Tally, _: []const u8, out: []u8) registry_mod.HandlerError!usize {
    state.calls += 1;
    if (out.len < 4) return error.TooLarge;
    std.mem.writeInt(u32, out[0..4], state.calls, .little);
    return 4;
}

const test_commands = registry_mod.checked(Tally, &.{
    .{ .name = "text.upper", .run = &upper },
    .{ .name = "tally.count", .run = &count },
    .{ .name = "text.secret", .run = &upper, .private = true },
}, registry_mod.permissionList("core.ping,text.upper,tally.count,text.secret,window.close"));

/// Records `requests` the way the bridge does — the real `handle`, request then reply —
/// into `file`, and returns the recording's bytes.
fn recordSession(file: [*:0]const u8, registry: *const invoke.Registry, requests: []const []const u8, into: []u8) ![]const u8 {
    var recorder = record.Recorder.create(file, false) orelse return error.CannotCreate;
    var out: [256]u8 = undefined;
    for (requests) |request| {
        const begun = recorder.now();
        var effects: invoke.Effects = .{};
        const answer = try invoke.handle(request, registry, .{}, &effects, &out);
        const id = record.commandOf(request).?;
        recorder.add(.request, request, registry.isPrivate(id), false, begun);
        recorder.add(.reply, answer, registry.isPrivate(id), false, recorder.now());
    }
    recorder.close();
    const fd = std.c.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, into.ptr, into.len);
    if (read <= 0) return error.Unreadable;
    return into[0..@intCast(read)];
}

test "the replay entry point is compiled" {
    _ = &runFromEnvironment;
}

test "a replay against the same core matches, and a changed state is caught" {
    const file = "replay-test.lrec";
    defer _ = std.c.unlink(file);
    var frames: [5][96]u8 = undefined;
    const requests = [_][]const u8{
        try invoke.request(&frames[0], 1, 1, "ping"),
        try invoke.request(&frames[1], 2, registry_mod.first_app_id, "abc"),
        try invoke.request(&frames[2], 3, registry_mod.first_app_id + 1, ""),
        try invoke.request(&frames[3], 4, registry_mod.first_app_id + 2, "my diary"),
        try invoke.request(&frames[4], 5, @intFromEnum(invoke.Command.window_close), ""),
    };
    var recorded_tally: Tally = .{};
    const recording_registry = test_commands.bind(&recorded_tally);
    var bytes: [4096]u8 = undefined;
    const recording = try recordSession(file, &recording_registry, &requests, &bytes);
    try std.testing.expect(std.mem.indexOf(u8, recording, "my diary") == null);

    var out: [256]u8 = undefined;
    var report_buffer: [1024]u8 = undefined;

    // The same starting state: everything that ran matches.
    var fresh: Tally = .{};
    const same_registry = test_commands.bind(&fresh);
    var report: std.Io.Writer = .fixed(&report_buffer);
    const matched = try run(recording, &same_registry, &report, &out);
    try std.testing.expectEqual(@as(u32, 3), matched.same);
    try std.testing.expectEqual(@as(u32, 0), matched.differs);
    try std.testing.expectEqual(@as(u32, 2), matched.kept);
    try std.testing.expect(matched.passed());
    const said = report.buffered();
    try std.testing.expect(std.mem.indexOf(u8, said, "kept     text.secret: private") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "kept     window.close: needs the window") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "3 same, 0 differ, 2 kept") != null);

    // Another starting state: the counting command answers differently.
    var moved: Tally = .{ .calls = 5 };
    const moved_registry = test_commands.bind(&moved);
    report = .fixed(&report_buffer);
    const caught = try run(recording, &moved_registry, &report, &out);
    try std.testing.expectEqual(@as(u32, 1), caught.differs);
    try std.testing.expect(!caught.passed());
    try std.testing.expect(std.mem.indexOf(u8, report.buffered(), "differs  tally.count: same status (ok), other result") != null);

    // A core that no longer grants a command answers `denied`, and the replay says so.
    const narrowed = comptime registry_mod.checked(Tally, &.{
        .{ .name = "text.upper", .run = &upper },
        .{ .name = "tally.count", .run = &count },
        .{ .name = "text.secret", .run = &upper, .private = true },
    }, registry_mod.permissionList("core.ping,tally.count,text.secret,window.close"));
    var again: Tally = .{};
    const narrowed_registry = narrowed.bind(&again);
    report = .fixed(&report_buffer);
    const refused = try run(recording, &narrowed_registry, &report, &out);
    try std.testing.expectEqual(@as(u32, 1), refused.differs);
    try std.testing.expect(std.mem.indexOf(u8, report.buffered(), "differs  text.upper: recorded ok, now denied") != null);

    // A recording cut mid-record still replays what it holds.
    report = .fixed(&report_buffer);
    var cut_tally: Tally = .{};
    const cut_registry = test_commands.bind(&cut_tally);
    const cut = try run(recording[0 .. recording.len - 2], &cut_registry, &report, &out);
    try std.testing.expect(cut.truncated);
    try std.testing.expect(std.mem.indexOf(u8, report.buffered(), "ends part-way") != null);
}
