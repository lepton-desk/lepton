//! Page replay: the application opens as usual and the page runs live, but every call it
//! makes is answered from a recording — `LEPTON_REPLAY_PAGE=<file>`, run by
//! `lepton replay --page`. It reproduces what the user saw (a bug report) with the
//! answers they got, and it notices when the page asks something else.
//!
//! The page's Nth call of a command gets the recorded Nth call's answer. A call is run
//! live instead when the recording cannot answer it:
//! - a window command: there is a window, and the call is what moves it;
//! - a masked call: its bytes were left out;
//! - a call with another argument than recorded, or one more than recorded: the page
//!   diverged, which the verdict reports.
//! Events a command emitted while it ran are sent again when its call is answered from
//! the recording; a deferred call (a file dialog) is answered after its recorded delay.
//!
//! This file decides; `bridge.zig` answers.

const std = @import("std");
const wire = @import("../../ipc/wire.zig");
const invoke = @import("invoke.zig");
const record = @import("record.zig");

pub const Answer = struct {
    status: invoke.Status,
    result: []const u8,
    /// How long after the request it was answered: what a deferred call waits again.
    delay_ns: u64,
};

pub const Event = struct {
    name: []const u8,
    /// Null when the recording left it out.
    data: ?[]const u8,
};

pub const Call = struct {
    command: u32,
    sequence: u64,
    /// Null when masked.
    argument: ?[]const u8,
    /// Null when masked, or when the process ended before it answered.
    answer: ?Answer = null,
    deferred: bool,
    /// The events emitted while it ran: `Script.events[events_from..events_to]`.
    events_from: usize,
    events_to: usize,
    used: bool = false,
};

pub const Live = enum { window, masked, other_argument, unrecorded };

pub const Decision = union(enum) {
    recorded: *const Call,
    live: Live,
};

fn isWindowCommand(command: u32) bool {
    return switch (@as(invoke.Command, @enumFromInt(command))) {
        // A permission answer settles a request the live engine raised in this run.
        .window_close, .window_minimize, .window_maximize, .window_unmaximize, .window_state, .permission_respond => true,
        else => false,
    };
}

/// The argument of an unmasked request frame.
pub fn argumentOf(frame: []const u8) ?[]const u8 {
    const header = wire.readHeader(frame) catch return null;
    const payload = wire.payloadOf(frame, header) catch return null;
    const asked = wire.readPayload(wire.Request, payload) catch return null;
    const end = std.math.add(usize, asked.argument_off, asked.argument_len) catch return null;
    if (asked.argument_off < @sizeOf(wire.Request) or end > payload.len) return null;
    return payload[asked.argument_off..end];
}

fn answerOf(frame: []const u8, delay_ns: u64) ?Answer {
    const header = wire.readHeader(frame) catch return null;
    const payload = wire.payloadOf(frame, header) catch return null;
    const replied = wire.readPayload(wire.Reply, payload) catch return null;
    const end = std.math.add(usize, replied.result_off, replied.result_len) catch return null;
    if (end > payload.len) return null;
    return .{ .status = @enumFromInt(replied.status), .result = payload[replied.result_off..end], .delay_ns = delay_ns };
}

fn eventOf(frame: []const u8, masked: bool) ?Event {
    if (frame.len < wire.header_bytes) return null;
    const notice = wire.readPayload(wire.Notice, frame[wire.header_bytes..]) catch return null;
    const name_at = wire.header_bytes + @sizeOf(wire.Notice);
    if (frame.len < name_at + notice.name_len) return null;
    const name = frame[name_at..][0..notice.name_len];
    if (masked) return .{ .name = name, .data = null };
    if (frame.len < name_at + notice.name_len + notice.data_len) return null;
    return .{ .name = name, .data = frame[name_at + notice.name_len ..][0..notice.data_len] };
}

pub const Script = struct {
    allocator: std.mem.Allocator,
    /// The recording; every slice below points into it.
    bytes: []const u8,
    calls: []Call,
    events: []Event,
    from_recording: u32 = 0,
    live: u32 = 0,
    diverged: u32 = 0,

    /// Reads a recording. `bytes` must outlive the script.
    pub fn load(allocator: std.mem.Allocator, bytes: []const u8) (record.ReadError || std.mem.Allocator.Error)!Script {
        var reader = try record.Reader.init(bytes);
        var calls: std.ArrayList(Call) = .empty;
        errdefer calls.deinit(allocator);
        var events: std.ArrayList(Event) = .empty;
        errdefer events.deinit(allocator);
        var pending_from: usize = 0;
        // The request a `reply` record answers: the one recorded just before it.
        var awaiting: ?struct { index: usize, at_ns: u64 } = null;
        var requested_at: std.ArrayList(u64) = .empty;
        defer requested_at.deinit(allocator);

        while (true) {
            const next = reader.next() catch |err| switch (err) {
                error.Truncated => break,
                else => return err,
            } orelse break;
            switch (next.kind) {
                .event => {
                    if (!next.flags.during) continue;
                    if (eventOf(next.frame, next.flags.masked)) |event| try events.append(allocator, event);
                },
                .request => {
                    const command = record.commandOf(next.frame) orelse continue;
                    const header = wire.readHeader(next.frame) catch continue;
                    try calls.append(allocator, .{
                        .command = command,
                        .sequence = header.sequence,
                        .argument = if (next.flags.masked) null else argumentOf(next.frame),
                        .deferred = next.flags.deferred,
                        .events_from = pending_from,
                        .events_to = events.items.len,
                    });
                    try requested_at.append(allocator, next.at_ns);
                    pending_from = events.items.len;
                    awaiting = if (next.flags.deferred) null else .{ .index = calls.items.len - 1, .at_ns = next.at_ns };
                },
                .reply => {
                    const owner = awaiting orelse continue;
                    awaiting = null;
                    if (!next.flags.masked) calls.items[owner.index].answer = answerOf(next.frame, next.at_ns -| owner.at_ns);
                },
                .late_reply => {
                    if (next.flags.masked) continue;
                    const header = wire.readHeader(next.frame) catch continue;
                    for (calls.items, 0..) |*call, index| {
                        if (call.deferred and call.answer == null and call.sequence == header.sequence) {
                            call.answer = answerOf(next.frame, next.at_ns -| requested_at.items[index]);
                            break;
                        }
                    }
                },
                _ => {},
            }
        }
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .calls = try calls.toOwnedSlice(allocator),
            .events = try events.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Script) void {
        self.allocator.free(self.calls);
        self.allocator.free(self.events);
    }

    /// How to answer the page's call of `command` with `argument`.
    pub fn decide(self: *Script, command: u32, argument: []const u8) Decision {
        const call = for (self.calls) |*call| {
            if (!call.used and call.command == command) break call;
        } else null;
        if (isWindowCommand(command)) {
            if (call) |found| found.used = true;
            self.live += 1;
            return .{ .live = .window };
        }
        const found = call orelse {
            self.live += 1;
            self.diverged += 1;
            return .{ .live = .unrecorded };
        };
        found.used = true;
        const recorded_argument = found.argument orelse {
            self.live += 1;
            return .{ .live = .masked };
        };
        if (found.answer == null) {
            self.live += 1;
            return .{ .live = .masked };
        }
        if (!std.mem.eql(u8, recorded_argument, argument)) {
            self.live += 1;
            self.diverged += 1;
            return .{ .live = .other_argument };
        }
        self.from_recording += 1;
        return .{ .recorded = found };
    }

    pub fn eventsOf(self: *const Script, call: *const Call) []const Event {
        return self.events[call.events_from..call.events_to];
    }

    /// Recorded calls the page never made.
    pub fn missing(self: *const Script) u32 {
        var count: u32 = 0;
        for (self.calls) |call| count += @intFromBool(!call.used);
        return count;
    }

    pub fn passed(self: *const Script) bool {
        return self.diverged == 0 and self.missing() == 0;
    }

    /// The verdict, with the name of every recorded call the page never made.
    pub fn report(self: *const Script, registry: *const invoke.Registry, out: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.calls) |call| {
            if (!call.used) try out.print("missing  {s}: recorded, never called\n", .{registry.nameOf(call.command) orelse "unknown command"});
        }
        try out.print("page     {d} from the recording, {d} live, {d} diverged, {d} missing\n", .{
            self.from_recording, self.live, self.diverged, self.missing(),
        });
    }
};

/// `LEPTON_REPLAY_PAGE=<file>`, loaded; null when unset or unreadable (said on stderr).
/// Kept for the process's lifetime, as the bridge that answers from it is.
pub fn fromEnvironment() ?Script {
    const path = std.c.getenv("LEPTON_REPLAY_PAGE") orelse return null;
    if (path[0] == 0) return null;
    const allocator = std.heap.page_allocator;
    const bytes = @import("replay.zig").readWhole(allocator, path) orelse {
        std.debug.print("page     cannot read {s}\n", .{path});
        return null;
    };
    const script = Script.load(allocator, bytes) catch |err| {
        std.debug.print("page     {s}: {t}\n", .{ path, err });
        return null;
    };
    std.debug.print("page     replaying {s}: {d} recorded calls\n", .{ path, script.calls.len });
    return script;
}

const registry_mod = @import("registry.zig");
const events_mod = @import("events.zig");

test "a page replay answers from the recording and notices a page that diverged" {
    const file = "page-replay-test.lrec";
    defer _ = std.c.unlink(file);
    var recorder = record.Recorder.create(file, false) orelse return error.CannotCreate;
    var request_buffer: [128]u8 = undefined;
    var reply_buffer: [128]u8 = undefined;
    var event_buffer: [512]u8 = undefined;
    const first = registry_mod.first_app_id;

    // notes.save("a") emits notes.saved while it runs and answers "ok".
    var log: events_mod.Log = .{};
    _ = try log.emit("notes.saved", "a");
    var unmasked = record.Recorder{ .fd = recorder.fd, .unmasked = true, .started = recorder.started };
    unmasked.addEvent("notes.saved", try log.writeSince(0, &event_buffer), true);
    recorder.add(.request, try invoke.request(&request_buffer, 1, first, "a"), false, false, 10);
    recorder.add(.reply, try invoke.reply(&reply_buffer, 1, .ok, "ok"), false, false, 20);
    // fs.read_file is private: masked.
    recorder.add(.request, try invoke.request(&request_buffer, 2, first + 1, "diary.txt"), true, false, 30);
    recorder.add(.reply, try invoke.reply(&reply_buffer, 2, .ok, "secret"), true, false, 40);
    // dialog.open answers 4 ms later.
    recorder.add(.request, try invoke.request(&request_buffer, 3, first + 2, ""), false, true, 50);
    recorder.add(.late_reply, try invoke.reply(&reply_buffer, 3, .ok, "/home/u/a.txt"), false, false, 4_000_050);
    recorder.add(.request, try invoke.request(&request_buffer, 4, @intFromEnum(invoke.Command.window_close), ""), false, false, 60);
    recorder.add(.reply, try invoke.reply(&reply_buffer, 4, .ok, ""), false, false, 61);
    // A second notes.save the page will not make.
    recorder.add(.request, try invoke.request(&request_buffer, 5, first, "b"), false, false, 70);
    recorder.add(.reply, try invoke.reply(&reply_buffer, 5, .ok, "ok"), false, false, 71);
    recorder.close();

    var bytes: [2048]u8 = undefined;
    const fd = std.c.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &bytes, bytes.len);
    try std.testing.expect(read > 0);

    var script = try Script.load(std.testing.allocator, bytes[0..@intCast(read)]);
    defer script.deinit();
    try std.testing.expectEqual(@as(usize, 5), script.calls.len);

    const saved = script.decide(first, "a");
    try std.testing.expectEqualStrings("ok", saved.recorded.answer.?.result);
    const emitted = script.eventsOf(saved.recorded);
    try std.testing.expectEqual(@as(usize, 1), emitted.len);
    try std.testing.expectEqualStrings("notes.saved", emitted[0].name);
    try std.testing.expectEqualStrings("a", emitted[0].data.?);

    try std.testing.expectEqual(Live.masked, script.decide(first + 1, "diary.txt").live);

    const chosen = script.decide(first + 2, "").recorded.answer.?;
    try std.testing.expectEqualStrings("/home/u/a.txt", chosen.result);
    try std.testing.expectEqual(@as(u64, 4_000_000), chosen.delay_ns);

    try std.testing.expectEqual(Live.window, script.decide(@intFromEnum(invoke.Command.window_close), "").live);
    try std.testing.expect(script.passed() == false); // the second notes.save is still owed
    try std.testing.expectEqual(@as(u32, 1), script.missing());

    // The page saves something else, then one more time than recorded.
    try std.testing.expectEqual(Live.other_argument, script.decide(first, "c").live);
    try std.testing.expectEqual(Live.unrecorded, script.decide(first, "d").live);
    try std.testing.expectEqual(@as(u32, 0), script.missing());
    try std.testing.expectEqual(@as(u32, 2), script.diverged);
    try std.testing.expectEqual(@as(u32, 2), script.from_recording);
    try std.testing.expect(!script.passed());
}

test "a page that makes exactly the recorded calls passes" {
    const file = "page-replay-pass-test.lrec";
    defer _ = std.c.unlink(file);
    var recorder = record.Recorder.create(file, false) orelse return error.CannotCreate;
    var request_buffer: [128]u8 = undefined;
    var reply_buffer: [128]u8 = undefined;
    recorder.add(.request, try invoke.request(&request_buffer, 1, registry_mod.first_app_id, "x"), false, false, 1);
    recorder.add(.reply, try invoke.reply(&reply_buffer, 1, .failed, ""), false, false, 2);
    recorder.close();
    var bytes: [512]u8 = undefined;
    const fd = std.c.open(file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &bytes, bytes.len);
    var script = try Script.load(std.testing.allocator, bytes[0..@intCast(read)]);
    defer script.deinit();
    // A recorded failure is answered as a failure: the page sees what the user saw.
    try std.testing.expectEqual(invoke.Status.failed, script.decide(registry_mod.first_app_id, "x").recorded.answer.?.status);
    try std.testing.expect(script.passed());
}
