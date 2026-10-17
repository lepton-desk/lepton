//! Recording the page's invoke traffic: every request frame and its reply, with the time
//! each happened, appended to a file as it passes — `LEPTON_RECORD=<file>`.
//!
//! The frames are recorded as they crossed the bridge, byte for byte, because `wire`
//! frames have fixed layouts: a recording replays exactly (`replay.zig`) without parsing
//! anything the page wrote. Each record is written the moment it exists, so a crash
//! leaves every request before it in the file.
//!
//! A command marked `private` (a file's bytes, the clipboard, a chosen path) keeps its
//! `wire.Request` / `wire.Reply` — command, status and lengths — but not the bytes after
//! them; `LEPTON_RECORD_UNMASKED=1` records those too. The file is created `0600`.
//!
//! Layout, little-endian: a [`FileHeader`], then records, each an [`Entry`] followed by
//! `Entry.len` bytes of frame.

const std = @import("std");
const report = @import("../../report.zig");
const wire = @import("../../ipc/wire.zig");

pub const magic = "LEPTONRC".*;
/// Raised when a record's meaning changes; a reader refuses any other.
pub const format: u32 = 1;

pub const FileHeader = extern struct {
    magic: [8]u8 = magic,
    format: u32 = format,
    /// `wire.version` of the core that recorded: frames of another version would not
    /// decode the same.
    wire_version: u32 = wire.version,
};

pub const Kind = enum(u8) {
    /// A request frame as the page sent it.
    request = 1,
    /// The reply sent at once, after the request it answers.
    reply = 2,
    /// The reply to a deferred request (`invoke.takeLater`), whenever it came.
    late_reply = 3,
    /// An event the core sent the page: a `notice` frame as `/__lepton/events` serves it.
    event = 4,
    _,
};

pub const Flags = packed struct(u8) {
    /// The bytes after the frame's fixed structs were left out.
    masked: bool = false,
    /// A request the command took to answer later; its reply is a `late_reply`.
    deferred: bool = false,
    /// An event emitted while a command ran: it belongs to the request recorded next,
    /// and a page replay that answers that request from the recording sends it again.
    during: bool = false,
    _pad: u5 = 0,
};

pub const Entry = extern struct {
    kind: Kind,
    flags: Flags,
    reserved: u16 = 0,
    /// Bytes of frame that follow.
    len: u32,
    /// Nanoseconds since the recording began, on the monotonic clock.
    at_ns: u64,
};

comptime {
    std.debug.assert(@sizeOf(FileHeader) == 16);
    std.debug.assert(@sizeOf(Entry) == 16);
}

/// How much of `frame` a masked record keeps: the `wire` header and the request's or
/// reply's fixed struct, whose lengths still say how large the left-out bytes were; for
/// an event, its name too.
pub fn maskedLength(kind: Kind, frame: []const u8) usize {
    const fixed: usize = wire.header_bytes + @as(usize, switch (kind) {
        .request => @sizeOf(wire.Request),
        .event => @sizeOf(wire.Notice),
        else => @sizeOf(wire.Reply),
    });
    if (kind == .event and frame.len >= fixed) {
        const notice = wire.readPayload(wire.Notice, frame[wire.header_bytes..]) catch return fixed;
        return @min(fixed + notice.name_len, frame.len);
    }
    return @min(fixed, frame.len);
}

/// The command a request frame names, masked or not; null for anything else.
pub fn commandOf(frame: []const u8) ?u32 {
    // Not `payloadOf`: a masked frame is shorter than its header says.
    const header = wire.readHeader(frame) catch return null;
    if (header.kind != .request) return null;
    const asked = wire.readPayload(wire.Request, frame[wire.header_bytes..]) catch return null;
    return asked.command;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Appends records to an open file.
pub const Recorder = struct {
    fd: std.c.fd_t,
    unmasked: bool,
    started: std.Io.Clock.Timestamp,
    /// Set by the first write that failed; nothing more is written after it, so the
    /// file never holds a record with a hole in it.
    broken: bool = false,

    /// Creates (or empties) `path`, `0600`, and writes the file header.
    pub fn create(path: [*:0]const u8, unmasked: bool) ?Recorder {
        const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return null;
        // An existing file keeps its mode through `O_CREAT`; a recording is private either way.
        _ = std.c.fchmod(fd, 0o600);
        var recorder: Recorder = .{ .fd = fd, .unmasked = unmasked, .started = std.Io.Clock.Timestamp.now(io(), .awake) };
        const header: FileHeader = .{};
        if (!recorder.writeAll(std.mem.asBytes(&header))) {
            recorder.close();
            return null;
        }
        return recorder;
    }

    /// `LEPTON_RECORD=<file>` (and `LEPTON_RECORD_UNMASKED=1`), or null when unset or
    /// the file cannot be created — which is said on stderr, since the user asked.
    pub fn fromEnvironment() ?Recorder {
        const path = std.c.getenv("LEPTON_RECORD") orelse return null;
        if (path[0] == 0) return null;
        const unmasked = if (std.c.getenv("LEPTON_RECORD_UNMASKED")) |value| std.mem.eql(u8, std.mem.span(value), "1") else false;
        const recorder = create(path, unmasked) orelse {
            report.fact("record", .bad, "cannot create {s}", .{path});
            return null;
        };
        report.fact("record", .good, "{s}{s}", .{ path, if (unmasked) " (unmasked: private bytes included)" else "" });
        return recorder;
    }

    /// Nanoseconds since the recording began.
    pub fn now(self: *const Recorder) u64 {
        const elapsed = self.started.durationTo(std.Io.Clock.Timestamp.now(io(), .awake)).raw.nanoseconds;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }

    /// Appends one frame. `private` masks it unless the recording is unmasked.
    pub fn add(self: *Recorder, kind: Kind, frame: []const u8, private: bool, deferred: bool, at_ns: u64) void {
        self.addFlagged(kind, frame, private, .{ .deferred = deferred }, at_ns);
    }

    /// Appends an event. An application's event data is its own to say, so it is masked
    /// like a private command's unless the recording is unmasked; its name is kept. The
    /// core's own `window.*` events carry no user data and are kept whole.
    pub fn addEvent(self: *Recorder, name: []const u8, frame: []const u8, during: bool) void {
        const private = !std.mem.startsWith(u8, name, "window.");
        self.addFlagged(.event, frame, private, .{ .during = during }, self.now());
    }

    fn addFlagged(self: *Recorder, kind: Kind, frame: []const u8, private: bool, flags: Flags, at_ns: u64) void {
        if (self.broken) return;
        const masked = private and !self.unmasked;
        const kept = if (masked) frame[0..maskedLength(kind, frame)] else frame;
        var marked = flags;
        marked.masked = masked;
        const entry: Entry = .{
            .kind = kind,
            .flags = marked,
            .len = @intCast(kept.len),
            .at_ns = at_ns,
        };
        if (!self.writeAll(std.mem.asBytes(&entry)) or !self.writeAll(kept)) self.broken = true;
    }

    fn writeAll(self: *Recorder, bytes: []const u8) bool {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const wrote = std.c.write(self.fd, bytes[sent..].ptr, bytes.len - sent);
            if (wrote <= 0) return false;
            sent += @intCast(wrote);
        }
        return true;
    }

    pub fn close(self: *Recorder) void {
        _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

pub const Record = struct {
    kind: Kind,
    flags: Flags,
    at_ns: u64,
    frame: []const u8,
};

pub const ReadError = error{
    NotARecording,
    /// Written by a core with another record format or `wire` version.
    OtherVersion,
    /// The last record stops part-way: the process ended while writing it.
    Truncated,
};

/// Walks a recording held in memory.
pub const Reader = struct {
    bytes: []const u8,
    at: usize = @sizeOf(FileHeader),

    pub fn init(bytes: []const u8) ReadError!Reader {
        if (bytes.len < @sizeOf(FileHeader)) return error.NotARecording;
        const header: FileHeader = @bitCast(bytes[0..@sizeOf(FileHeader)].*);
        if (!std.mem.eql(u8, &header.magic, &magic)) return error.NotARecording;
        if (header.format != format or header.wire_version != wire.version) return error.OtherVersion;
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Reader) ReadError!?Record {
        if (self.at == self.bytes.len) return null;
        if (self.bytes.len - self.at < @sizeOf(Entry)) return error.Truncated;
        const entry: Entry = @bitCast(self.bytes[self.at..][0..@sizeOf(Entry)].*);
        const start = self.at + @sizeOf(Entry);
        if (self.bytes.len - start < entry.len) return error.Truncated;
        self.at = start + entry.len;
        return .{ .kind = entry.kind, .flags = entry.flags, .at_ns = entry.at_ns, .frame = self.bytes[start..][0..entry.len] };
    }
};

const invoke = @import("invoke.zig");

test "a recording reads back frame for frame, private bytes left out" {
    const name = "record-test.lrec";
    defer _ = std.c.unlink(name);
    var request_buffer: [128]u8 = undefined;
    var reply_buffer: [128]u8 = undefined;
    const request = try invoke.request(&request_buffer, 7, 1000, "secret path");
    const reply = try invoke.reply(&reply_buffer, 7, .ok, "secret bytes");

    var recorder = Recorder.create(name, false) orelse return error.CannotCreate;
    recorder.add(.request, request, false, false, 5);
    recorder.add(.reply, reply, false, false, 9);
    recorder.add(.request, request, true, true, 12);
    recorder.add(.late_reply, reply, true, false, 40);
    recorder.close();

    const linux = std.os.linux;
    var info: linux.Statx = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.statx(linux.AT.FDCWD, name, 0, .{ .MODE = true }, &info));
    try std.testing.expectEqual(@as(u16, 0o600), info.mode & 0o777);

    var bytes: [1024]u8 = undefined;
    const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &bytes, bytes.len);
    try std.testing.expect(read > 0);
    const recording = bytes[0..@intCast(read)];
    try std.testing.expect(std.mem.indexOf(u8, recording, "secret") != null);

    var reader = try Reader.init(recording);
    const first = (try reader.next()).?;
    try std.testing.expectEqual(Kind.request, first.kind);
    try std.testing.expectEqualSlices(u8, request, first.frame);
    try std.testing.expectEqual(@as(u64, 5), first.at_ns);
    const second = (try reader.next()).?;
    try std.testing.expectEqualSlices(u8, reply, second.frame);
    const third = (try reader.next()).?;
    try std.testing.expect(third.flags.masked and third.flags.deferred);
    try std.testing.expectEqual(wire.header_bytes + @sizeOf(wire.Request), third.frame.len);
    // The fixed struct still says how long the left-out argument was.
    const asked = try wire.readPayload(wire.Request, third.frame[wire.header_bytes..]);
    try std.testing.expectEqual(@as(u32, "secret path".len), asked.argument_len);
    const fourth = (try reader.next()).?;
    try std.testing.expectEqual(Kind.late_reply, fourth.kind);
    try std.testing.expect(std.mem.indexOf(u8, fourth.frame, "secret") == null);
    try std.testing.expect(try reader.next() == null);

    // Only the unmasked records hold the private words: twice, never four times.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, recording, "secret"));

    // A process that died mid-record leaves a tail the reader names.
    var cut = try Reader.init(recording[0 .. recording.len - 3]);
    _ = try cut.next();
    _ = try cut.next();
    _ = try cut.next();
    try std.testing.expectError(error.Truncated, cut.next());
}

test "a file that is not a recording, or of another version, is refused" {
    try std.testing.expectError(error.NotARecording, Reader.init("short"));
    try std.testing.expectError(error.NotARecording, Reader.init("NOTLEPTN" ++ [_]u8{0} ** 8));
    var other: FileHeader = .{};
    other.format = format + 1;
    try std.testing.expectError(error.OtherVersion, Reader.init(std.mem.asBytes(&other)));
}

test "an unmasked recording keeps private bytes" {
    const name = "record-unmasked-test.lrec";
    defer _ = std.c.unlink(name);
    var buffer: [128]u8 = undefined;
    const request = try invoke.request(&buffer, 1, 1000, "kept");
    var recorder = Recorder.create(name, true) orelse return error.CannotCreate;
    recorder.add(.request, request, true, false, 0);
    recorder.close();
    var bytes: [256]u8 = undefined;
    const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &bytes, bytes.len);
    var reader = try Reader.init(bytes[0..@intCast(read)]);
    const record = (try reader.next()).?;
    try std.testing.expect(!record.flags.masked);
    try std.testing.expectEqualSlices(u8, request, record.frame);
}

test "an event keeps its name and, masked, not its data" {
    var log: @import("events.zig").Log = .{};
    _ = try log.emit("notes.saved", "my secret note");
    var buffer: [512]u8 = undefined;
    const frame = try log.writeSince(0, &buffer);
    const kept = maskedLength(.event, frame);
    try std.testing.expectEqualStrings("notes.saved", frame[kept - "notes.saved".len .. kept]);
    try std.testing.expect(std.mem.indexOf(u8, frame[0..kept], "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "secret") != null);
}

test "the core's window events are recorded whole, an application's masked" {
    const name = "record-events-test.lrec";
    defer _ = std.c.unlink(name);
    var log: @import("events.zig").Log = .{};
    var buffer: [512]u8 = undefined;
    var recorder = Recorder.create(name, false) orelse return error.CannotCreate;
    _ = try log.emit("window.state", "\x02\x00\x00\x00");
    recorder.addEvent("window.state", try log.writeSince(0, &buffer), false);
    _ = try log.emit("notes.saved", "my secret note");
    recorder.addEvent("notes.saved", try log.writeSince(1, &buffer), true);
    recorder.close();
    var bytes: [1024]u8 = undefined;
    const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &bytes, bytes.len);
    var reader = try Reader.init(bytes[0..@intCast(read)]);
    const window = (try reader.next()).?;
    try std.testing.expect(!window.flags.masked and !window.flags.during);
    const app = (try reader.next()).?;
    try std.testing.expect(app.flags.masked and app.flags.during);
    try std.testing.expect(std.mem.indexOf(u8, bytes[0..@intCast(read)], "secret") == null);
}
