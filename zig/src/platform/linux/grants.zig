//! Paths the user chose in a file dialog, granted to the application at run time and
//! remembered: a folder opened as a notes vault reopens next time without asking.
//!
//! Only native code adds to it — `@lepton-desk/plugin-dialog`, after the desktop's portal
//! returned what the user picked. A page cannot: it can only open a dialog, and the user
//! decides. `@lepton-desk/plugin-fs` consults it only when the application opted in
//! (`"plugins": { "fs": { "chosen": true } }`); otherwise its scope is the fixed one.
//!
//! A chosen folder grants what is below it; a chosen file grants that file alone. The list
//! is kept in `<application data>/lepton-grants`, `0600`, one `d <path>` or `f <path>` per
//! line.

const std = @import("std");
const paths = @import("paths.zig");

pub const Kind = enum { directory, file };

pub const Grant = struct {
    kind: Kind,
    path: []const u8,
};

/// At most this many remembered: a dialog's choices, not a filesystem index.
pub const capacity = 64;
/// The longest path kept. A dialog's choice beyond it is not granted (not cut: a cut
/// path would grant its parent).
pub const max_path = 1024;

/// The grants of one application, in memory.
pub const List = struct {
    storage: [capacity][max_path]u8 = undefined,
    kinds: [capacity]Kind = undefined,
    lens: [capacity]usize = @splat(0),
    count: usize = 0,

    pub fn get(self: *const List, index: usize) Grant {
        return .{ .kind = self.kinds[index], .path = self.storage[index][0..self.lens[index]] };
    }

    /// Adds `path` (absolute, as the portal returned it). An existing grant is kept once;
    /// when full, the oldest is forgotten.
    pub fn add(self: *List, kind: Kind, path: []const u8) void {
        if (path.len == 0 or path[0] != '/' or path.len > max_path) return;
        if (std.mem.indexOfScalar(u8, path, '\n') != null) return;
        for (0..self.count) |index| {
            const grant = self.get(index);
            if (grant.kind == kind and std.mem.eql(u8, grant.path, path)) return;
        }
        if (self.count == capacity) {
            std.mem.copyForwards([max_path]u8, self.storage[0 .. capacity - 1], self.storage[1..capacity]);
            std.mem.copyForwards(Kind, self.kinds[0 .. capacity - 1], self.kinds[1..capacity]);
            std.mem.copyForwards(usize, self.lens[0 .. capacity - 1], self.lens[1..capacity]);
            self.count -= 1;
        }
        @memcpy(self.storage[self.count][0..path.len], path);
        self.kinds[self.count] = kind;
        self.lens[self.count] = path.len;
        self.count += 1;
    }

    /// The grant that covers `path`: a folder it is in (or is), or the file it is.
    /// Matched by whole words, so `/home/u/notes` does not cover `/home/u/notes2`.
    pub fn covering(self: *const List, path: []const u8) ?Grant {
        for (0..self.count) |index| {
            const grant = self.get(index);
            switch (grant.kind) {
                .file => if (std.mem.eql(u8, grant.path, path)) return grant,
                .directory => {
                    if (!std.mem.startsWith(u8, path, grant.path)) continue;
                    if (path.len == grant.path.len or path[grant.path.len] == '/') return grant;
                },
            }
        }
        return null;
    }

    /// `d <path>` / `f <path>` lines, as the file keeps them.
    pub fn parse(text: []const u8) List {
        var list: List = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len < 3 or line[1] != ' ') continue;
            const kind: Kind = switch (line[0]) {
                'd' => .directory,
                'f' => .file,
                else => continue,
            };
            list.add(kind, line[2..]);
        }
        return list;
    }

    pub fn write(self: *const List, out: []u8) error{NoSpaceLeft}![]const u8 {
        var used: usize = 0;
        for (0..self.count) |index| {
            const grant = self.get(index);
            const line = try std.fmt.bufPrint(out[used..], "{c} {s}\n", .{ @as(u8, if (grant.kind == .directory) 'd' else 'f'), grant.path });
            used += line.len;
        }
        return out[0..used];
    }
};

// ── One process's list, loaded from and saved to the application's data directory ──

var loaded: List = .{};
var loaded_for: [256]u8 = undefined;
var loaded_for_len: usize = 0;
var is_loaded = false;
/// The file's text, read or about to be written: static, as it is too large for the stack
/// of the GLib callback that adds a grant.
var file_text: [capacity * (max_path + 3)]u8 = undefined;

fn fileOf(identifier: []const u8, out: []u8) ?[:0]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const directory = paths.resolve(.app_data, identifier, &directory_buffer, &scratch) catch return null;
    var made: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (directory.len + 1 > made.len) return null;
    @memcpy(made[0..directory.len], directory);
    made[directory.len] = 0;
    _ = paths.makePrivate(made[0..directory.len :0]);
    return std.fmt.bufPrintZ(out, "{s}/lepton-grants", .{directory}) catch null;
}

fn listFor(identifier: []const u8) *List {
    if (is_loaded and std.mem.eql(u8, loaded_for[0..loaded_for_len], identifier)) return &loaded;
    is_loaded = true;
    loaded = .{};
    const kept = @min(identifier.len, loaded_for.len);
    @memcpy(loaded_for[0..kept], identifier[0..kept]);
    loaded_for_len = kept;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = fileOf(identifier, &path_buffer) orelse return &loaded;
    const fd = std.c.open(file.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return &loaded;
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, &file_text, file_text.len);
    if (read > 0) loaded = List.parse(file_text[0..@intCast(read)]);
    return &loaded;
}

/// Grants `path` to application `identifier` and remembers it. Native code only: the
/// path must be one the user chose in a dialog.
pub fn add(identifier: []const u8, kind: Kind, path: []const u8) void {
    const list = listFor(identifier);
    list.add(kind, path);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = fileOf(identifier, &path_buffer) orelse return;
    const bytes = list.write(&file_text) catch return;
    const fd = std.c.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.fchmod(fd, 0o600);
    var sent: usize = 0;
    while (sent < bytes.len) {
        const wrote = std.c.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (wrote <= 0) return;
        sent += @intCast(wrote);
    }
}

/// The grant of application `identifier` that covers `path`, if any.
pub fn covering(identifier: []const u8, path: []const u8) ?Grant {
    return listFor(identifier).covering(path);
}

test "a chosen folder covers what is below it; a chosen file only itself" {
    var list: List = .{};
    list.add(.directory, "/home/u/Notlar");
    list.add(.file, "/home/u/Belgeler/rapor.md");
    list.add(.directory, "/home/u/Notlar");
    try std.testing.expectEqual(@as(usize, 2), list.count);
    try std.testing.expect(list.covering("/home/u/Notlar") != null);
    try std.testing.expect(list.covering("/home/u/Notlar/günlük/a.md") != null);
    try std.testing.expect(list.covering("/home/u/Notlar2/a.md") == null);
    try std.testing.expect(list.covering("/home/u") == null);
    try std.testing.expect(list.covering("/home/u/Belgeler/rapor.md") != null);
    try std.testing.expect(list.covering("/home/u/Belgeler/diğer.md") == null);
    // Not an absolute path, or one that would break a line of the file: never added.
    list.add(.directory, "relative/path");
    list.add(.directory, "/tmp/a\nd /etc");
    try std.testing.expectEqual(@as(usize, 2), list.count);
}

test "the list round-trips through its file format and forgets the oldest when full" {
    var list: List = .{};
    list.add(.directory, "/home/u/Notlar");
    list.add(.file, "/home/u/a b.md");
    var out: [512]u8 = undefined;
    const text = try list.write(&out);
    try std.testing.expectEqualStrings("d /home/u/Notlar\nf /home/u/a b.md\n", text);
    var with_junk: [600]u8 = undefined;
    @memcpy(with_junk[0..text.len], text);
    const junk = "x junk\n\n";
    @memcpy(with_junk[text.len..][0..junk.len], junk);
    const back = List.parse(with_junk[0 .. text.len + junk.len]);
    try std.testing.expectEqual(@as(usize, 2), back.count);
    try std.testing.expectEqualStrings("/home/u/a b.md", back.get(1).path);

    var full: List = .{};
    var name: [32]u8 = undefined;
    for (0..capacity + 1) |index| full.add(.directory, try std.fmt.bufPrint(&name, "/d{d}", .{index}));
    try std.testing.expectEqual(@as(usize, capacity), full.count);
    try std.testing.expect(full.covering("/d0") == null);
    try std.testing.expect(full.covering("/d64") != null);
}
