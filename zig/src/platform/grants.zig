//! Paths the user chose in a file dialog, granted to the application at run time and
//! remembered: a folder opened as a notes vault reopens next time without asking.
//!
//! Only native code adds to it — `@lepton-desk/plugin-dialog`, after the desktop's dialog
//! returned what the user picked. A page cannot: it can only open a dialog, and the user
//! decides. `@lepton-desk/plugin-fs` consults it only when the application opted in
//! (`"plugins": { "fs": { "chosen": true } }`); otherwise its scope is the fixed one.
//!
//! A chosen folder grants what is below it; a chosen file grants that file alone. The list
//! is kept in the application's state directory, `~/.local/state/<id>/lepton-grants`
//! (`0600`) on Linux and `%LOCALAPPDATA%\<id>\State\lepton-grants` on Windows — never
//! under an `fs` base: kept in `$APPDATA`, a page with that scope could write grants into
//! it. One `d <path>` or `f <path>` per line.
//!
//! Paths are compared as the host writes them: on Windows `C:\Users\u\Notlar` covers
//! `c:/users/u/notlar/a.md` — either separator, letters without case, as NTFS compares.

const std = @import("std");
const builtin = @import("builtin");
const windows = builtin.os.tag == .windows;
const paths = if (windows) @import("windows/paths.zig") else @import("linux/paths.zig");

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

/// How paths are written: the host's, unless a test says otherwise.
pub const Style = enum {
    posix,
    windows,

    pub const host: Style = if (windows) .windows else .posix;

    fn isSeparator(style: Style, ch: u8) bool {
        return ch == '/' or (style == .windows and ch == '\\');
    }

    fn isAbsolute(style: Style, path: []const u8) bool {
        return switch (style) {
            .posix => path.len > 0 and path[0] == '/',
            .windows => path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and style.isSeparator(path[2]),
        };
    }

    /// Whether `a` and `b` name the same path.
    fn same(style: Style, a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            const equal = switch (style) {
                .posix => x == y,
                .windows => (style.isSeparator(x) and style.isSeparator(y)) or std.ascii.toLower(x) == std.ascii.toLower(y),
            };
            if (!equal) return false;
        }
        return true;
    }
};

/// Whether a folder grant of `path` would cover the whole home folder `home`: the root,
/// home itself, or a folder above it.
pub fn tooBroad(style: Style, path: []const u8, home: []const u8) bool {
    var folder = path;
    while (folder.len > 1 and style.isSeparator(folder[folder.len - 1])) folder = folder[0 .. folder.len - 1];
    const root_len: usize = if (style == .windows) 3 else 1;
    if (folder.len <= root_len) return true;
    if (home.len == 0) return false;
    var own = home;
    while (own.len > 1 and style.isSeparator(own[own.len - 1])) own = own[0 .. own.len - 1];
    if (folder.len > own.len) return false;
    if (!style.same(folder, own[0..folder.len])) return false;
    return folder.len == own.len or style.isSeparator(own[folder.len]);
}

test "the home folder, the root and what is above home are never granted" {
    try std.testing.expect(tooBroad(.posix, "/", "/home/u"));
    try std.testing.expect(tooBroad(.posix, "/home", "/home/u"));
    try std.testing.expect(tooBroad(.posix, "/home/u", "/home/u"));
    try std.testing.expect(tooBroad(.posix, "/home/u/", "/home/u"));
    try std.testing.expect(!tooBroad(.posix, "/home/u/Notlar", "/home/u"));
    try std.testing.expect(!tooBroad(.posix, "/home/user2", "/home/u"));
    try std.testing.expect(!tooBroad(.posix, "/srv/notes", "/home/u"));
    try std.testing.expect(tooBroad(.windows, "C:\\", "C:\\Users\\u"));
    try std.testing.expect(tooBroad(.windows, "c:/users/U", "C:\\Users\\u"));
    try std.testing.expect(!tooBroad(.windows, "C:\\Users\\u\\Notlar", "C:\\Users\\u"));
}

/// The grants of one application, in memory.
pub const List = struct {
    style: Style = .host,
    storage: [capacity][max_path]u8 = undefined,
    kinds: [capacity]Kind = undefined,
    lens: [capacity]usize = @splat(0),
    count: usize = 0,

    pub fn get(self: *const List, index: usize) Grant {
        return .{ .kind = self.kinds[index], .path = self.storage[index][0..self.lens[index]] };
    }

    /// Adds `path` (absolute, as the dialog returned it). An existing grant is kept once;
    /// when full, the oldest is forgotten.
    pub fn add(self: *List, kind: Kind, path: []const u8) void {
        if (!self.style.isAbsolute(path) or path.len > max_path) return;
        if (std.mem.indexOfAny(u8, path, "\r\n") != null) return;
        for (0..self.count) |index| {
            const grant = self.get(index);
            if (grant.kind == kind and self.style.same(grant.path, path)) return;
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
                .file => if (self.style.same(grant.path, path)) return grant,
                .directory => {
                    if (path.len < grant.path.len or !self.style.same(grant.path, path[0..grant.path.len])) continue;
                    if (path.len == grant.path.len or self.style.isSeparator(path[grant.path.len])) return grant;
                },
            }
        }
        return null;
    }

    /// `d <path>` / `f <path>` lines, as the file keeps them.
    pub fn parse(text: []const u8) List {
        return parseAs(.host, text);
    }

    pub fn parseAs(style: Style, text: []const u8) List {
        var list: List = .{ .style = style };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            // A file edited on Windows may end its lines with CR LF.
            const line = std.mem.trimEnd(u8, raw, "\r");
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
/// of the callback that adds a grant.
var file_text: [capacity * (max_path + 3)]u8 = undefined;

/// Not `std.fs.max_path_bytes`: on Windows that is 96 KiB, too much for a callback's stack.
const path_max = 4096;

fn fileOf(identifier: []const u8, out: []u8) ?[:0]const u8 {
    var directory_buffer: [path_max]u8 = undefined;
    // Not `$APPDATA`: that is an `fs` scope base, and a page whose scope included it wrote
    // `d /home/<user>` into this file and gained the whole home directory (found by audit,
    // 2026-10-20). The state directory is outside every base short of `$HOME`.
    const directory = paths.stateDirectory(identifier, &directory_buffer) catch return null;
    var made: [path_max + 1]u8 = undefined;
    if (directory.len + 1 > made.len) return null;
    @memcpy(made[0..directory.len], directory);
    made[directory.len] = 0;
    _ = paths.makePrivate(made[0..directory.len :0]);
    return std.fmt.bufPrintZ(out, "{s}{c}lepton-grants", .{ directory, @as(u8, if (windows) '\\' else '/') }) catch null;
}

fn listFor(identifier: []const u8) *List {
    if (is_loaded and std.mem.eql(u8, loaded_for[0..loaded_for_len], identifier)) return &loaded;
    is_loaded = true;
    loaded = .{};
    const kept = @min(identifier.len, loaded_for.len);
    @memcpy(loaded_for[0..kept], identifier[0..kept]);
    loaded_for_len = kept;
    var path_buffer: [path_max]u8 = undefined;
    const file = fileOf(identifier, &path_buffer) orelse return &loaded;
    const read = store.read(file, &file_text);
    if (read > 0) loaded = List.parse(file_text[0..read]);
    return &loaded;
}

/// The list's file, read whole and written whole.
const store = if (windows) struct {
    const generic_read: u32 = 0x8000_0000;
    const generic_write: u32 = 0x4000_0000;
    const open_existing: u32 = 3;
    const create_always: u32 = 2;
    const invalid: usize = std.math.maxInt(usize);
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?*anyopaque) callconv(.winapi) usize;
    extern "kernel32" fn ReadFile(file: usize, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(file: usize, buffer: [*]const u8, len: u32, wrote: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(file: usize) callconv(.winapi) c_int;

    fn open(path: [:0]const u8, access: u32, disposition: u32) ?usize {
        var wide: [path_max:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide, path) catch return null;
        wide[len] = 0;
        const handle = CreateFileW(wide[0..len :0], access, 0, null, disposition, 0, null);
        return if (handle == invalid) null else handle;
    }

    fn read(path: [:0]const u8, out: []u8) usize {
        const file = open(path, generic_read, open_existing) orelse return 0;
        defer _ = CloseHandle(file);
        var got: u32 = 0;
        if (ReadFile(file, out.ptr, @intCast(out.len), &got, null) == 0) return 0;
        return got;
    }

    fn write(path: [:0]const u8, bytes: []const u8) void {
        const file = open(path, generic_write, create_always) orelse return;
        defer _ = CloseHandle(file);
        var wrote: u32 = 0;
        _ = WriteFile(file, bytes.ptr, @intCast(bytes.len), &wrote, null);
    }

    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) c_int;

    /// The test's file and its directory, removed.
    fn removeTestFile(identifier: []const u8) void {
        var path_buffer: [path_max]u8 = undefined;
        const file = fileOf(identifier, &path_buffer) orelse return;
        var wide: [path_max:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide, file) catch return;
        wide[len] = 0;
        _ = DeleteFileW(wide[0..len :0]);
        const slash = std.mem.lastIndexOfScalar(u16, wide[0..len], '\\') orelse return;
        wide[slash] = 0;
        _ = RemoveDirectoryW(wide[0..slash :0]);
    }
} else struct {
    fn read(path: [:0]const u8, out: []u8) usize {
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return 0;
        defer _ = std.c.close(fd);
        const got = std.c.read(fd, out.ptr, out.len);
        return if (got > 0) @intCast(got) else 0;
    }

    fn write(path: [:0]const u8, bytes: []const u8) void {
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
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

    /// The test's file and its directory, removed.
    fn removeTestFile(identifier: []const u8) void {
        var path_buffer: [path_max]u8 = undefined;
        const file = fileOf(identifier, &path_buffer) orelse return;
        _ = std.c.unlink(file.ptr);
        const slash = std.mem.lastIndexOfScalar(u8, file, '/') orelse return;
        var directory: [path_max]u8 = undefined;
        @memcpy(directory[0..slash], file[0..slash]);
        directory[slash] = 0;
        _ = std.c.rmdir(directory[0..slash :0]);
    }
};

/// Grants `path` to application `identifier` and remembers it. Native code only: the
/// path must be one the user chose in a dialog.
pub fn add(identifier: []const u8, kind: Kind, path: []const u8) void {
    // A page sets a dialog's title, button and starting folder; one click on "Continue"
    // in the home folder granted all of it for good (audit, 2026-10-20). The home folder,
    // the root and every folder above home are not granted; a folder inside them is.
    if (kind == .directory) {
        var home_buffer: [path_max]u8 = undefined;
        var scratch: [4096]u8 = undefined;
        const home = paths.resolve(.home, identifier, &home_buffer, &scratch) catch "";
        if (tooBroad(.host, path, home)) return;
    }
    const list = listFor(identifier);
    list.add(kind, path);
    var path_buffer: [path_max]u8 = undefined;
    const file = fileOf(identifier, &path_buffer) orelse return;
    const bytes = list.write(&file_text) catch return;
    store.write(file, bytes);
}

/// The grant of application `identifier` that covers `path`, if any.
pub fn covering(identifier: []const u8, path: []const u8) ?Grant {
    return listFor(identifier).covering(path);
}

test "a chosen folder covers what is below it; a chosen file only itself" {
    var list: List = .{ .style = .posix };
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
    try std.testing.expect(list.covering("/home/u/notlar/a.md") == null);
    // Not an absolute path, or one that would break a line of the file: never added.
    list.add(.directory, "relative/path");
    list.add(.directory, "/tmp/a\nd /etc");
    try std.testing.expectEqual(@as(usize, 2), list.count);
}

test "on Windows the same folder is matched by either separator and any case" {
    var list: List = .{ .style = .windows };
    list.add(.directory, "C:\\Users\\u\\Notlar");
    list.add(.file, "C:\\Users\\u\\Documents\\rapor.md");
    list.add(.directory, "c:/users/U/notlar");
    try std.testing.expectEqual(@as(usize, 2), list.count);
    try std.testing.expect(list.covering("c:\\users\\u\\notlar\\günlük\\a.md") != null);
    try std.testing.expect(list.covering("C:/Users/u/Notlar/a.md") != null);
    try std.testing.expect(list.covering("C:\\Users\\u\\Notlar2\\a.md") == null);
    try std.testing.expect(list.covering("C:\\Users\\u\\DOCUMENTS\\RAPOR.MD") != null);
    try std.testing.expect(list.covering("D:\\Users\\u\\Notlar\\a.md") == null);
    list.add(.directory, "\\\\server\\share");
    list.add(.directory, "/home/u");
    try std.testing.expectEqual(@as(usize, 2), list.count);
    const back = List.parseAs(.windows, "d C:\\Users\\u\\Kasa\r\nf C:\\a.md\r\n");
    try std.testing.expectEqual(@as(usize, 2), back.count);
    try std.testing.expectEqualStrings("C:\\Users\\u\\Kasa", back.get(0).path);
}

test "the list round-trips through its file format and forgets the oldest when full" {
    var list: List = .{ .style = .posix };
    list.add(.directory, "/home/u/Notlar");
    list.add(.file, "/home/u/a b.md");
    var out: [512]u8 = undefined;
    const text = try list.write(&out);
    try std.testing.expectEqualStrings("d /home/u/Notlar\nf /home/u/a b.md\n", text);
    var with_junk: [600]u8 = undefined;
    @memcpy(with_junk[0..text.len], text);
    const junk = "x junk\n\n";
    @memcpy(with_junk[text.len..][0..junk.len], junk);
    const back = List.parseAs(.posix, with_junk[0 .. text.len + junk.len]);
    try std.testing.expectEqual(@as(usize, 2), back.count);
    try std.testing.expectEqualStrings("/home/u/a b.md", back.get(1).path);

    var full: List = .{ .style = .posix };
    var name: [32]u8 = undefined;
    for (0..capacity + 1) |index| full.add(.directory, try std.fmt.bufPrint(&name, "/d{d}", .{index}));
    try std.testing.expectEqual(@as(usize, capacity), full.count);
    try std.testing.expect(full.covering("/d0") == null);
    try std.testing.expect(full.covering("/d64") != null);
}

test "a grant is remembered in the application's state directory and read back" {
    var identifier_buffer: [64]u8 = undefined;
    const pid = if (windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    const identifier = try std.fmt.bufPrint(&identifier_buffer, "com.lepton.grants-test-{d}", .{pid});
    defer store.removeTestFile(identifier);
    const chosen = if (windows) "C:\\Users\\u\\Notlar" else "/home/u/Notlar";
    add(identifier, .directory, chosen);
    // Read back from the file, not from memory: forget what this process loaded.
    is_loaded = false;
    try std.testing.expect(covering(identifier, if (windows) "c:/users/u/notlar/a.md" else "/home/u/Notlar/a.md") != null);
    var path_buffer: [path_max]u8 = undefined;
    const file = fileOf(identifier, &path_buffer) orelse return error.NoFile;
    var text: [256]u8 = undefined;
    const got = store.read(file, &text);
    try std.testing.expectEqualStrings("d " ++ chosen ++ "\n", text[0..got]);
    // Never under `$APPDATA`, which a page's `fs` scope may name.
    var data_buffer: [path_max]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const data = try paths.resolve(.app_data, identifier, &data_buffer, &scratch);
    try std.testing.expect(!std.mem.startsWith(u8, file, data));
}
