//! Files inside the directories an application allowed, for `@lepton-desk/plugin-fs`.
//! No core import: tested alone with `zig test zig/fs.zig -lc`, on the real filesystem.
//!
//! **The boundary.** A path is first matched, by its words, to one allowed root: it must
//! be absolute, contain no `..`, and lie at or under the root. That only decides which
//! root to open. Every operation then opens the rest relative to the root's handle, and
//! the kernel refuses any resolution that leaves it — so a link planted inside an allowed
//! directory is not a way out of it, and there is no window between a check and the use
//! the check was for.
//!
//! - Linux (`fs_linux.zig`): `openat2(root, relative, RESOLVE_BENEATH |
//!   RESOLVE_NO_MAGICLINKS)`. Measured before it was written: `..`, a symbolic link to
//!   `../outside`, a link to an absolute path and an absolute path all fail with `EXDEV`,
//!   and a link inside the root still works.
//! - Windows (`fs_windows.zig`): `NtCreateFile` with the root as `RootDirectory` and
//!   `OBJ_DONT_REPARSE`. Measured on Windows 10 22H2: a junction inside the root pointing
//!   outside opens without the flag and fails with it (`STATUS_REPARSE_POINT_ENCOUNTERED`);
//!   `..` is refused by the kernel itself (`STATUS_OBJECT_NAME_INVALID`). Stricter than
//!   Linux: every link (junction, symbolic link) is refused, also one that stays inside —
//!   the flag cannot tell them apart. A link is still listed, and removed as a link.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    /// Outside every allowed root.
    Denied,
    /// The operation failed: missing file, not a directory, no permission, …
    Failed,
    /// The answer does not fit the space it was given.
    TooLarge,
};

/// One allowed directory, absolute and in plain words (no `..`, no trailing separator).
pub const Root = struct {
    path: []const u8,
    /// Created (mode 0700 on Linux, with its parents) on first use: the application's own
    /// directories, which do not exist until it stores something.
    create: bool = false,
};

/// What `read_dir` and `stat` report an entry to be.
pub const Kind = enum(u8) { other = 0, file = 1, directory = 2, symlink = 3 };

/// A path matched to its root: `relative` is "" for the root itself, its words joined by `/`.
pub const Located = struct {
    root: Root,
    relative: [:0]const u8,
};

/// `stat`'s reply: kind, size in bytes, modification time in milliseconds since 1970.
pub const stat_bytes = 1 + 8 + 8;

/// How paths are written: `/home/u/notes` or `C:\Users\u\notes` (either separator,
/// letters compared without case, as NTFS compares them).
pub const Style = enum {
    posix,
    windows,

    pub const host: Style = if (builtin.os.tag == .windows) .windows else .posix;

    fn isSeparator(style: Style, ch: u8) bool {
        return ch == '/' or (style == .windows and ch == '\\');
    }
};

/// The operations, on the host's kernel. Each takes the root's handle and the `relative`
/// a [`locate`] gave.
pub const ops = if (builtin.os.tag == .windows) @import("fs_windows.zig") else @import("fs_linux.zig");
pub const Handle = ops.Handle;
pub const openRoot = ops.openRoot;
pub const close = ops.close;
pub const sameDirectory = ops.sameDirectory;
pub const readFile = ops.readFile;
pub const readRange = ops.readRange;
pub const rename = ops.rename;
pub const removeTree = ops.removeTree;
pub const writeFile = ops.writeFile;
pub const makeDirectory = ops.makeDirectory;
pub const remove = ops.remove;
pub const exists = ops.exists;
pub const stat = ops.stat;
pub const readDirectory = ops.readDirectory;
pub const Change = ops.Change;
pub const watch = ops.watch;
pub const unwatch = ops.unwatch;
pub const drainWatch = ops.drainWatch;

/// Matches `path` to the first root it lies in, writing the part below the root into
/// `buffer`. Only words are compared here; the kernel enforces the boundary later.
pub fn locate(roots: []const Root, path: []const u8, buffer: []u8) Error!Located {
    return locateAs(.host, roots, path, buffer);
}

pub fn locateAs(style: Style, roots: []const Root, path: []const u8, buffer: []u8) Error!Located {
    if (!isAbsolute(style, path)) return error.Denied;
    // The drive (`C:`) is the only place a colon may be; past it, a colon names an
    // alternate data stream (`notes.txt:hidden`), which the kernel would open.
    const words_start: usize = if (style == .windows) 2 else 0;
    var parts = std.mem.tokenizeAny(u8, path[words_start..], if (style == .windows) "/\\" else "/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.Denied;
        if (style == .windows and !std.mem.eql(u8, part, ".") and !windowsName(part)) return error.Denied;
    }
    for (roots) |root| {
        if (under(style, root.path, path)) |rest| {
            var len: usize = 0;
            var words = std.mem.tokenizeAny(u8, rest, if (style == .windows) "/\\" else "/");
            while (words.next()) |word| {
                if (std.mem.eql(u8, word, ".")) continue;
                const extra = word.len + @intFromBool(len > 0);
                if (len + extra + 1 > buffer.len) return error.TooLarge;
                if (len > 0) {
                    buffer[len] = '/';
                    len += 1;
                }
                @memcpy(buffer[len..][0..word.len], word);
                len += word.len;
            }
            buffer[len] = 0;
            return .{ .root = root, .relative = buffer[0..len :0] };
        }
    }
    return error.Denied;
}

/// `/…`, or on Windows a drive and a separator (`C:\…`). A UNC share (`\\server\…`) is
/// not one: a root is a directory on this machine.
fn isAbsolute(style: Style, path: []const u8) bool {
    return switch (style) {
        .posix => path.len > 0 and path[0] == '/',
        .windows => path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and style.isSeparator(path[2]),
    };
}

/// A name Windows can hold and give back: none of `<>:"/\|?*` or control characters, not
/// ending in a dot or a space (stored as written, then unreachable by its name through
/// Win32), and not a device (`CON`, `NUL`, `COM1`, … with any extension).
pub fn windowsName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| {
        if (ch < 0x20 or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", ch) != null) return false;
    }
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    }
    if (stem.len == 4 and std.ascii.isDigit(stem[3])) {
        if (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")) return false;
    }
    return true;
}

/// The rest of `path` when it is `root` or under it at a separator; null otherwise.
fn under(style: Style, root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len < root.len) return null;
    for (root, path[0..root.len]) |a, b| {
        const same = switch (style) {
            .posix => a == b,
            .windows => (style.isSeparator(a) and style.isSeparator(b)) or std.ascii.toLower(a) == std.ascii.toLower(b),
        };
        if (!same) return null;
    }
    const rest = path[root.len..];
    if (rest.len == 0) return rest;
    if (style.isSeparator(rest[0])) return rest[1..];
    if (style.isSeparator(root[root.len - 1])) return rest; // the root is `/` or `C:\`
    return null;
}

test "paths are matched to a root by their words, and never by `..`" {
    const roots = [_]Root{ .{ .path = "/home/u/.local/share/app" }, .{ .path = "/home/u/Belgeler/notlar" } };
    var buffer: [256]u8 = undefined;
    const doc = try locateAs(.posix, &roots, "/home/u/Belgeler/notlar/a//./b.txt", &buffer);
    try std.testing.expectEqualStrings("/home/u/Belgeler/notlar", doc.root.path);
    try std.testing.expectEqualStrings("a/b.txt", doc.relative);
    try std.testing.expectEqualStrings("", (try locateAs(.posix, &roots, "/home/u/.local/share/app", &buffer)).relative);
    try std.testing.expectError(error.Denied, locateAs(.posix, &roots, "/home/u/Belgeler/notlarX/a", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.posix, &roots, "/home/u/Belgeler/notlar/../secret", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.posix, &roots, "relative/path", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.posix, &roots, "/etc/passwd", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.posix, &.{}, "/home/u/Belgeler/notlar/a", &buffer));
    // A backslash is a character of a Linux name, not a separator.
    try std.testing.expectEqualStrings("a\\b", (try locateAs(.posix, &roots, "/home/u/Belgeler/notlar/a\\b", &buffer)).relative);
}

test "Windows paths: either separator, any case, no streams, devices or `..`" {
    const roots = [_]Root{ .{ .path = "C:\\Users\\u\\AppData\\Roaming\\app" }, .{ .path = "C:\\Users\\u\\Documents\\Notlar" } };
    var buffer: [256]u8 = undefined;
    const doc = try locateAs(.windows, &roots, "c:/users/U/documents/notlar\\günlük//./a.md", &buffer);
    try std.testing.expectEqualStrings("C:\\Users\\u\\Documents\\Notlar", doc.root.path);
    try std.testing.expectEqualStrings("günlük/a.md", doc.relative);
    try std.testing.expectEqualStrings("", (try locateAs(.windows, &roots, "C:\\Users\\u\\AppData\\Roaming\\app\\", &buffer)).relative);
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "C:\\Users\\u\\Documents\\NotlarX\\a", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "C:\\Users\\u\\Documents\\Notlar\\..\\secret", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "C:\\Users\\u\\Documents\\Notlar\\a.md:hidden", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "C:\\Users\\u\\Documents\\Notlar\\CON.txt", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "C:\\Users\\u\\Documents\\Notlar\\a.md.", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "\\\\server\\share\\Notlar", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "Users\\u\\Documents\\Notlar", &buffer));
    try std.testing.expectError(error.Denied, locateAs(.windows, &roots, "D:\\Users\\u\\Documents\\Notlar", &buffer));
    const drive = [_]Root{.{ .path = "D:\\" }};
    try std.testing.expectEqualStrings("Kasa/a.md", (try locateAs(.windows, &drive, "D:\\Kasa\\a.md", &buffer)).relative);
}

test "Windows names" {
    try std.testing.expect(windowsName("notlar.md"));
    try std.testing.expect(windowsName("COM10"));
    try std.testing.expect(windowsName("console.log"));
    try std.testing.expect(!windowsName("lpt1.txt"));
    try std.testing.expect(!windowsName("nul"));
    try std.testing.expect(!windowsName("a?b"));
    try std.testing.expect(!windowsName("trailing "));
    try std.testing.expect(!windowsName(""));
}

test {
    _ = ops;
}
