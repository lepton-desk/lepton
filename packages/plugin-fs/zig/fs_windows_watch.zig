//! `fs.watch` on Windows: `ReadDirectoryChangesW` on a directory opened beneath the root
//! (`fs_windows.beneath`, so with `OBJ_DONT_REPARSE`: a watch cannot be pointed out of the
//! root through a link). Each watch keeps one overlapped read outstanding; the
//! application's loop calls [`drainWatch`] every turn, which takes what has completed
//! without waiting and starts the next read. The kernel keeps collecting changes between
//! two reads once the first one was made, so nothing is lost in between.
//!
//! Against Linux (`fs_linux.zig`, inotify): a recursive watch is one read
//! (`bWatchSubtree`), and directories made later are inside it without being added. A
//! file is watched through its directory, reporting only that name (as "", the watched
//! path itself, as on Linux). Windows reports a write as one or more `MODIFIED`; the
//! repeats that arrive together are reported once. A watched directory that is renamed
//! is not reported (Windows says nothing to the directory's own handle); one that is
//! removed is reported `gone`.

const std = @import("std");
const w = std.os.windows;
const fs = @import("fs.zig");
const nt = @import("fs_windows.zig");

const Error = fs.Error;

pub const Change = enum(u8) { created = 1, modified = 2, removed = 3, renamed_from = 4, renamed_to = 5, gone = 6 };

const Overlapped = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    event: ?w.HANDLE = null,
};

extern "kernel32" fn ReadDirectoryChangesW(directory: w.HANDLE, buffer: [*]u8, len: u32, subtree: c_int, filter: u32, returned: ?*u32, overlapped: *Overlapped, completion: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetOverlappedResult(file: w.HANDLE, overlapped: *Overlapped, transferred: *u32, wait: c_int) callconv(.winapi) c_int;
extern "kernel32" fn CancelIoEx(file: w.HANDLE, overlapped: ?*Overlapped) callconv(.winapi) c_int;
extern "kernel32" fn CreateEventW(security: ?*anyopaque, manual_reset: c_int, initial: c_int, name: ?[*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn CloseHandle(handle: w.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const error_io_incomplete = 996;
/// More changes than the buffer holds: they are lost, and the read says so with 0 bytes.
const filter_names_and_writes: u32 = 0x1 | 0x2 | 0x10; // FILE_NAME | DIR_NAME | LAST_WRITE

const Watch = struct {
    number: u32 = 0,
    directory: ?w.HANDLE = null,
    overlapped: Overlapped = .{},
    recursive: bool = false,
    /// Watching a file: its name in the watched directory; only it is reported, as "".
    only: [255]u16 = undefined,
    only_len: usize = 0,
    buffer: [16 * 1024]u8 align(8) = undefined,

    fn read(self: *Watch) bool {
        const directory = self.directory orelse return false;
        const event = self.overlapped.event;
        self.overlapped = .{ .event = event };
        return ReadDirectoryChangesW(directory, &self.buffer, self.buffer.len, @intFromBool(self.recursive), filter_names_and_writes, null, &self.overlapped, null) != 0;
    }

    fn release(self: *Watch) void {
        if (self.directory) |directory| {
            _ = CancelIoEx(directory, &self.overlapped);
            var transferred: u32 = 0;
            // The cancelled read must finish before its buffer and event are given back.
            _ = GetOverlappedResult(directory, &self.overlapped, &transferred, 1);
            nt.close(directory);
        }
        if (self.overlapped.event) |event| _ = CloseHandle(event);
        self.* = .{};
    }
};

/// Watches open at once, across the application.
const max_watches = 32;
var watches: [max_watches]Watch = @splat(.{});
var next_number: u32 = 1;

/// Watches `relative` (a directory: its entries, with `recursive` everything below; a
/// file: itself) and returns the watch's number, which every change it reports carries.
pub fn watch(root: nt.Handle, relative: [:0]const u8, recursive: bool) Error!u32 {
    const slot = for (&watches) |*candidate| {
        if (candidate.number == 0) break candidate;
    } else return error.TooLarge;
    var words = std.mem.splitScalar(u8, relative, '/');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "..")) return error.Denied;
    }

    const how: nt.Open = .{ .access = nt.list_access, .options = .{ .IO = .ASYNCHRONOUS, .DIRECTORY_FILE = true }, .asynchronous = true };
    var only: [255]u16 = undefined;
    var only_len: usize = 0;
    const directory = nt.beneath(root, relative, how) catch |err| blk: {
        // Not a directory: a file, watched through the directory it is in.
        if (err != error.Failed or relative.len == 0) return err;
        const exists = try nt.exists(root, relative);
        if (!exists) return error.Failed;
        const slash = std.mem.lastIndexOfScalar(u8, relative, '/');
        const name = relative[if (slash) |at| at + 1 else 0..];
        if (name.len > only.len) return error.TooLarge;
        only_len = std.unicode.utf8ToUtf16Le(&only, name) catch return error.Failed;
        break :blk try nt.beneath(root, relative[0 .. slash orelse 0], how);
    };
    errdefer nt.close(directory);
    const event = CreateEventW(null, 1, 0, null) orelse return error.Failed;
    errdefer _ = CloseHandle(event);

    slot.* = .{ .number = next_number, .directory = directory, .overlapped = .{ .event = event }, .recursive = recursive and only_len == 0, .only = only, .only_len = only_len };
    if (!slot.read()) {
        slot.* = .{};
        return error.Failed;
    }
    next_number +%= 1;
    if (next_number == 0) next_number = 1;
    return slot.number;
}

/// Stops the watch `number`.
pub fn unwatch(number: u32) void {
    for (&watches) |*slot| {
        if (slot.number == number and number != 0) return slot.release();
    }
}

/// `FILE_NOTIFY_INFORMATION`'s fixed part; the name (UTF-16) follows it.
const Notify = extern struct { next: u32, action: u32, name_bytes: u32 };

fn changeOf(action: u32) ?Change {
    return switch (action) {
        1 => .created, // FILE_ACTION_ADDED
        2 => .removed, // FILE_ACTION_REMOVED
        3 => .modified, // FILE_ACTION_MODIFIED
        4 => .renamed_from, // FILE_ACTION_RENAMED_OLD_NAME
        5 => .renamed_to, // FILE_ACTION_RENAMED_NEW_NAME
        else => null,
    };
}

fn sameName(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lower_x = if (x < 128) std.ascii.toLower(@intCast(x)) else x;
        const lower_y = if (y < 128) std.ascii.toLower(@intCast(y)) else y;
        if (lower_x != lower_y) return false;
    }
    return true;
}

/// Reports every change that has arrived, without waiting, as `report(context, number,
/// change, name)` — `name` below the watched path, `/` between words, "" for the path
/// itself.
pub fn drainWatch(context: anytype, report: fn (@TypeOf(context), u32, Change, []const u8) void) void {
    for (&watches) |*slot| {
        if (slot.number == 0) continue;
        const directory = slot.directory orelse continue;
        var transferred: u32 = 0;
        if (GetOverlappedResult(directory, &slot.overlapped, &transferred, 0) == 0) {
            if (GetLastError() == error_io_incomplete) continue;
            // The directory went away (removed with its handle open): the watch is over.
            const number = slot.number;
            slot.release();
            report(context, number, .gone, "");
            continue;
        }
        var last_change: ?Change = null;
        var last_name: [1024]u8 = undefined;
        var last_len: usize = 0;
        var at: usize = 0;
        while (transferred != 0 and at + @sizeOf(Notify) <= transferred) {
            const notify: *align(1) const Notify = @ptrCast(&slot.buffer[at]);
            const units: [*]align(1) const u16 = @ptrCast(&slot.buffer[at + @sizeOf(Notify)]);
            var wide: [512]u16 = undefined;
            const count = @min(notify.name_bytes / 2, wide.len);
            for (0..count) |index| wide[index] = units[index];
            const step = notify.next;
            defer at = if (step == 0) transferred else at + step;
            var change = changeOf(notify.action) orelse continue;
            if (slot.only_len != 0) {
                if (!sameName(wide[0..count], slot.only[0..slot.only_len])) continue;
                change = switch (change) {
                    .modified => .modified,
                    .removed, .renamed_from => .gone,
                    else => continue,
                };
            }
            var name: [1024]u8 = undefined;
            const name_len = if (slot.only_len != 0) 0 else std.unicode.wtf16LeToWtf8(&name, wide[0..count]);
            for (name[0..name_len]) |*byte| {
                if (byte.* == '\\') byte.* = '/';
            }
            // Windows reports one write as several `MODIFIED`: the ones together are one.
            if (last_change == change and change == .modified and std.mem.eql(u8, last_name[0..last_len], name[0..name_len])) continue;
            last_change = change;
            @memcpy(last_name[0..name_len], name[0..name_len]);
            last_len = name_len;
            report(context, slot.number, change, name[0..name_len]);
        }
        if (!slot.read()) {
            const number = slot.number;
            slot.release();
            report(context, number, .gone, "");
        }
    }
}

// ---------------------------------------------------------------------------------------
// Tests: a real directory under %TEMP%; changes are waited for, as they arrive on their own.

extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const Seen = struct {
    number: u32,
    changes: [32]Change = undefined,
    names: [32][64]u8 = undefined,
    lens: [32]usize = undefined,
    count: usize = 0,

    fn note(self: *Seen, from: u32, change: Change, name: []const u8) void {
        if (from != self.number or self.count == self.changes.len or name.len > 64) return;
        self.changes[self.count] = change;
        @memcpy(self.names[self.count][0..name.len], name);
        self.lens[self.count] = name.len;
        self.count += 1;
    }

    /// Drains for up to a second, until `wanted` changes were seen.
    fn waitFor(self: *Seen, wanted: usize) void {
        var turns: usize = 0;
        while (self.count < wanted and turns < 50) : (turns += 1) {
            drainWatch(self, note);
            if (self.count < wanted) Sleep(20);
        }
        // Whatever else arrives with them.
        Sleep(50);
        drainWatch(self, note);
    }

    fn of(self: *const Seen, name: []const u8) [8]?Change {
        var found: [8]?Change = @splat(null);
        var used: usize = 0;
        for (0..self.count) |index| {
            if (used == found.len or !std.mem.eql(u8, self.names[index][0..self.lens[index]], name)) continue;
            found[used] = self.changes[index];
            used += 1;
        }
        return found;
    }
};

fn testRoot(buffer: []u8, tail: []const u8) !nt.Handle {
    const temp = std.mem.span(std.c.getenv("TEMP") orelse return error.NoTemp);
    const path = try std.fmt.bufPrint(buffer, "{s}\\lepton-watch-test-{d}\\{s}", .{ temp, w.GetCurrentProcessId(), tail });
    return nt.openRoot(.{ .path = path, .create = true });
}

fn removeTestRoot() void {
    var buffer: [600]u8 = undefined;
    const temp = std.mem.span(std.c.getenv("TEMP") orelse return);
    const path = std.fmt.bufPrint(&buffer, "{s}\\lepton-watch-test-{d}", .{ temp, w.GetCurrentProcessId() }) catch return;
    const result = std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "cmd", "/c", "rmdir", "/s", "/q", path } }) catch return;
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
}

test "a watched directory reports its entries' changes, and its number is the watch's" {
    defer removeTestRoot();
    var buffer: [600]u8 = undefined;
    const root = try testRoot(&buffer, "root");
    defer nt.close(root);

    const number = try watch(root, "", false);
    defer unwatch(number);
    try nt.writeFile(root, "note.md", "x", false);
    try nt.rename(root, "note.md", "renamed.md");
    try nt.remove(root, "renamed.md");

    var seen: Seen = .{ .number = number };
    seen.waitFor(4);
    try std.testing.expectEqualSlices(?Change, &.{ .created, .modified, .renamed_from, null }, seen.of("note.md")[0..4]);
    try std.testing.expectEqualSlices(?Change, &.{ .renamed_to, .removed, null }, seen.of("renamed.md")[0..3]);
    // A path that leaves the root is refused before anything is watched.
    try std.testing.expectError(error.Denied, watch(root, "../outside", false));
}

test "a recursive watch sees every directory below it, and those made later" {
    defer removeTestRoot();
    var buffer: [600]u8 = undefined;
    const root = try testRoot(&buffer, "root");
    defer nt.close(root);
    try nt.makeDirectory(root, "notes/2026", true);

    const number = try watch(root, "", true);
    defer unwatch(number);
    try nt.writeFile(root, "notes/2026/a.md", "x", false);
    try nt.makeDirectory(root, "later", false);
    var seen: Seen = .{ .number = number };
    seen.waitFor(2);
    try std.testing.expectEqual(@as(?Change, .created), seen.of("notes/2026/a.md")[0]);
    try std.testing.expectEqual(@as(?Change, .created), seen.of("later")[0]);
    try nt.writeFile(root, "later/b.md", "y", false);
    seen.waitFor(seen.count + 1);
    try std.testing.expectEqual(@as(?Change, .created), seen.of("later/b.md")[0]);

    // A junction planted in the tree to a directory outside it: what changes out there
    // does not reach the watch, and the junction cannot be watched.
    var outside_buffer: [600]u8 = undefined;
    const outside = try testRoot(&outside_buffer, "outside");
    defer nt.close(outside);
    const temp = std.mem.span(std.c.getenv("TEMP") orelse return error.NoTemp);
    var junction: [600]u8 = undefined;
    var target: [600]u8 = undefined;
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{
        "cmd",                                                                                                        "/c",                                                                                                     "mklink", "/J",
        try std.fmt.bufPrint(&junction, "{s}\\lepton-watch-test-{d}\\root\\out", .{ temp, w.GetCurrentProcessId() }), try std.fmt.bufPrint(&target, "{s}\\lepton-watch-test-{d}\\outside", .{ temp, w.GetCurrentProcessId() }),
    } });
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    const before = seen.count;
    try nt.writeFile(outside, "secret.md", "dışarıda", false);
    seen.waitFor(before + 2);
    for (before..seen.count) |index| {
        try std.testing.expect(!std.mem.startsWith(u8, seen.names[index][0..seen.lens[index]], "out/"));
    }
    try std.testing.expectError(error.Denied, watch(root, "out", false));
}

test "a watched file reports itself, and a watched directory that is removed is gone" {
    defer removeTestRoot();
    var buffer: [600]u8 = undefined;
    const root = try testRoot(&buffer, "root");
    defer nt.close(root);
    try nt.makeDirectory(root, "box", false);
    try nt.writeFile(root, "box/one.md", "1", false);
    try nt.writeFile(root, "box/other.md", "1", false);

    const file = try watch(root, "box/one.md", false);
    defer unwatch(file);
    try nt.writeFile(root, "box/other.md", "2", false);
    try nt.writeFile(root, "box/ONE.md", "2", false);
    var seen: Seen = .{ .number = file };
    seen.waitFor(1);
    try std.testing.expectEqualSlices(?Change, &.{ .modified, null }, seen.of("")[0..2]);
    try nt.remove(root, "box/one.md");
    seen.waitFor(seen.count + 1);
    try std.testing.expectEqual(@as(?Change, .gone), seen.of("")[1]);

    try nt.makeDirectory(root, "doomed", false);
    const directory = try watch(root, "doomed", false);
    defer unwatch(directory);
    try nt.remove(root, "doomed");
    var gone: Seen = .{ .number = directory };
    gone.waitFor(1);
    try std.testing.expectEqual(@as(?Change, .gone), gone.of("")[0]);
}
