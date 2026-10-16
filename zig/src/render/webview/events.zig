//! Events for the page: a bounded, numbered log the core appends to and the page reads
//! from by sequence.
//!
//! The page asks `/__lepton/events?after=N` and gets every event numbered above `N`, as
//! `wire` frames of kind `notice` — header (`sequence` = the event's number), `Notice`,
//! name, data — back to back. Nothing is pushed into the outbound ring: that ring keeps
//! only the newest frame for the measures panel, and an event a newer sample replaced
//! would be lost without a trace. Here an event survives until [`capacity`] newer ones
//! have been written, and a reader that fell further behind sees the gap in the numbers.
//!
//! Pure: the bridge does the waiting and the answering; this file is tested alone.

const std = @import("std");
const wire = @import("../../ipc/wire.zig");
const registry = @import("registry.zig");

/// The events the core itself emits. The only place their names are spelled: the view
/// emits these constants and the SDK's `BuiltinEvents` type is generated from this list.
pub const window_state = "window.state";
pub const window_resized = "window.resized";
pub const download_started = "download.started";
pub const download_progress = "download.progress";
pub const download_finished = "download.finished";
pub const download_failed = "download.failed";
pub const permission_request = "permission.request";
pub const builtin = [_][]const u8{ window_state, window_resized, download_started, download_progress, download_finished, download_failed, permission_request };

/// The events an application emits, declared once in its `main.zig`:
///
///     pub const events = core.webviewEvents.Declared(&.{ "notes.saved" });
///     _ = try events.emit(&view.bridge, "notes.saved", bytes);
///
/// `emit` takes the name at compile time, so an event that was not declared — a typo —
/// is a build error, and the declared list is what the page's TypeScript is generated
/// from (`src/lepton-commands.d.ts`, `AppEvents`).
pub fn Declared(comptime names: []const []const u8) type {
    comptime {
        for (names, 0..) |name, index| {
            if (!registry.validName(name)) @compileError("event name \"" ++ name ++ "\" is not `<group>.<name>` in lowercase");
            if (name.len > max_name) @compileError("event name \"" ++ name ++ "\" is longer than the log keeps");
            for (builtin) |own| {
                if (std.mem.eql(u8, own, name)) @compileError("\"" ++ name ++ "\" is a built-in event; choose another name");
            }
            for (names[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, name)) @compileError("event \"" ++ name ++ "\" is declared twice");
            }
        }
    }
    return struct {
        pub const list = names;

        /// Publishes `name` with `data` to the page through `bridge` (a `*Bridge`).
        pub fn emit(bridge: anytype, comptime name: []const u8, data: []const u8) EmitError!u64 {
            comptime {
                for (names) |declared| {
                    if (std.mem.eql(u8, declared, name)) break;
                } else @compileError("event \"" ++ name ++ "\" is not declared in this application's `events`");
            }
            return bridge.emit(name, data);
        }
    };
}

/// Where the page asks for events, on the core's origin.
pub const path = "/__lepton/events";

/// How long the page keeps one request open before asking again, in milliseconds. The
/// page enforces it (an aborted fetch); the core never runs a timer for it, and releases
/// a still-held request when the next one arrives.
pub const hold_ms: u32 = 25_000;

/// Events kept. A page polls continuously, so this is the burst it may miss while busy.
pub const capacity = 64;
pub const max_name = 64;
pub const max_data = 256;

/// The largest response: every kept event at its largest.
pub const max_response = capacity * (wire.header_bytes + @sizeOf(wire.Notice) + max_name + max_data);

const Entry = struct {
    sequence: u64 = 0,
    name: [max_name]u8 = undefined,
    name_len: u8 = 0,
    data: [max_data]u8 = undefined,
    data_len: u16 = 0,
};

pub const EmitError = error{ NameTooLong, DataTooLarge };

pub const Log = struct {
    entries: [capacity]Entry = @splat(.{}),
    /// The number of the newest event; 0 before the first.
    latest: u64 = 0,

    /// Appends an event and returns its number. Numbers start at 1 and never repeat.
    pub fn emit(self: *Log, name: []const u8, data: []const u8) EmitError!u64 {
        if (name.len > max_name) return error.NameTooLong;
        if (data.len > max_data) return error.DataTooLarge;
        self.latest += 1;
        const entry = &self.entries[@intCast(self.latest % capacity)];
        entry.sequence = self.latest;
        @memcpy(entry.name[0..name.len], name);
        entry.name_len = @intCast(name.len);
        @memcpy(entry.data[0..data.len], data);
        entry.data_len = @intCast(data.len);
        return self.latest;
    }

    /// Whether an event numbered above `after` is kept.
    pub fn hasAfter(self: *const Log, after: u64) bool {
        return self.latest > after;
    }

    /// Writes every kept event numbered above `after`, oldest first.
    pub fn writeSince(self: *const Log, after: u64, out: []u8) error{NoSpaceLeft}![]const u8 {
        const oldest = if (self.latest > capacity) self.latest - capacity + 1 else 1;
        var number = @max(after + 1, oldest);
        var used: usize = 0;
        while (number <= self.latest) : (number += 1) {
            const entry = &self.entries[@intCast(number % capacity)];
            const payload_len = @sizeOf(wire.Notice) + entry.name_len + entry.data_len;
            const total = wire.header_bytes + payload_len;
            if (used + total > out.len) return error.NoSpaceLeft;
            const head = wire.header(.notice, @intCast(payload_len), entry.sequence, .{});
            @memcpy(out[used..][0..wire.header_bytes], std.mem.asBytes(&head));
            used += wire.header_bytes;
            const notice: wire.Notice = .{ .name_len = entry.name_len, .reserved = 0, .data_len = entry.data_len };
            @memcpy(out[used..][0..@sizeOf(wire.Notice)], std.mem.asBytes(&notice));
            used += @sizeOf(wire.Notice);
            @memcpy(out[used..][0..entry.name_len], entry.name[0..entry.name_len]);
            used += entry.name_len;
            @memcpy(out[used..][0..entry.data_len], entry.data[0..entry.data_len]);
            used += entry.data_len;
        }
        return out[0..used];
    }
};

/// The `after` of `/__lepton/events?after=N`; 0 when absent or not a number.
pub fn afterOf(uri: []const u8) u64 {
    const query = uri[(std.mem.indexOfScalar(u8, uri, '?') orelse return 0) + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "after=")) {
            return std.fmt.parseInt(u64, pair["after=".len..], 10) catch 0;
        }
    }
    return 0;
}

/// Whether the query is `after=latest`: the page asking where the log stands, answered
/// at once with the newest number as a little-endian `u64`, so that listening starts at
/// "now" — neither replaying the kept events nor missing one written in between.
pub fn wantsLatest(uri: []const u8) bool {
    const query = uri[(std.mem.indexOfScalar(u8, uri, '?') orelse return false) + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (std.mem.eql(u8, pair, "after=latest")) return true;
    }
    return false;
}

/// A decoded frame, for the tests.
const Decoded = struct { sequence: u64, name: []const u8, data: []const u8, len: usize };

fn decode(bytes: []const u8) !Decoded {
    const h = try wire.readHeader(bytes);
    const payload = try wire.payloadOf(bytes, h);
    const notice = try wire.readPayload(wire.Notice, payload);
    const rest = payload[@sizeOf(wire.Notice)..];
    return .{
        .sequence = h.sequence,
        .name = rest[0..notice.name_len],
        .data = rest[notice.name_len..][0..notice.data_len],
        .len = wire.header_bytes + h.payload_len,
    };
}

const Recorder = struct {
    log: Log = .{},
    fn emit(self: *Recorder, name: []const u8, data: []const u8) EmitError!u64 {
        return self.log.emit(name, data);
    }
};

test "a declared event is emitted through whatever the application hands it" {
    const Mine = Declared(&.{ "notes.saved", "notes.deleted" });
    var recorder: Recorder = .{};
    try std.testing.expectEqual(@as(u64, 1), try Mine.emit(&recorder, "notes.saved", "a.md"));
    try std.testing.expectEqual(@as(usize, 2), Mine.list.len);
}

test "events come back after a number, oldest first, as notice frames" {
    var log: Log = .{};
    _ = try log.emit("window.state", &.{ 2, 0, 0, 0 });
    _ = try log.emit("notes.saved", "draft.md");
    try std.testing.expectEqual(@as(u64, 2), log.latest);
    var out: [1024]u8 = undefined;
    const bytes = try log.writeSince(0, &out);
    const first = try decode(bytes);
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expectEqualStrings("window.state", first.name);
    const second = try decode(bytes[first.len..]);
    try std.testing.expectEqualStrings("notes.saved", second.name);
    try std.testing.expectEqualStrings("draft.md", second.data);
    try std.testing.expectEqual(bytes.len, first.len + second.len);

    try std.testing.expectEqual(@as(usize, 0), (try log.writeSince(2, &out)).len);
    try std.testing.expect(!log.hasAfter(2));
    try std.testing.expect(log.hasAfter(1));
}

test "a reader that fell behind gets the kept events and sees the gap in the numbers" {
    var log: Log = .{};
    var i: usize = 0;
    while (i < capacity + 10) : (i += 1) _ = try log.emit("tick.n", "");
    var out: [max_response]u8 = undefined;
    const bytes = try log.writeSince(0, &out);
    const first = try decode(bytes);
    try std.testing.expectEqual(@as(u64, 11), first.sequence);
    try std.testing.expectEqual(capacity * (wire.header_bytes + @sizeOf(wire.Notice) + "tick.n".len), bytes.len);
}

test "oversized events are refused, not truncated" {
    var log: Log = .{};
    const long: [max_name + 1]u8 = @splat('a');
    try std.testing.expectError(error.NameTooLong, log.emit(&long, ""));
    const big: [max_data + 1]u8 = @splat(0);
    try std.testing.expectError(error.DataTooLarge, log.emit("a.b", &big));
    try std.testing.expectEqual(@as(u64, 0), log.latest);
}

test "the query's after is read, and anything else is zero" {
    try std.testing.expectEqual(@as(u64, 42), afterOf("lepton://localhost/__lepton/events?after=42"));
    try std.testing.expectEqual(@as(u64, 7), afterOf("lepton://localhost/__lepton/events?x=1&after=7"));
    try std.testing.expectEqual(@as(u64, 0), afterOf("lepton://localhost/__lepton/events"));
    try std.testing.expectEqual(@as(u64, 0), afterOf("lepton://localhost/__lepton/events?after=-1"));
    try std.testing.expect(wantsLatest("lepton://localhost/__lepton/events?after=latest"));
    try std.testing.expect(!wantsLatest("lepton://localhost/__lepton/events?after=3"));
}
