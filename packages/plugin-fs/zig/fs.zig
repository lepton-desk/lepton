//! Files inside the directories an application allowed, for `@lepton-desk/plugin-fs`.
//! No core import: tested alone with `zig test zig/fs.zig -lc`, on the real filesystem.
//!
//! **The boundary.** A path is first matched, by its words, to one allowed root: it must
//! be absolute, contain no `..`, and lie at or under the root. That only decides which
//! root to open. Every operation then goes through `openat2(root, relative,
//! RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS)`, in which the kernel refuses any resolution
//! that leaves the root — measured on this machine before this file was written: `..`,
//! a symbolic link to `../outside`, a link to an absolute path, and an absolute path all
//! fail with `EXDEV`, and a link inside the root still works. So a link planted inside an
//! allowed directory is not a way out of it, and there is no window between a check and
//! the use the check was for.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    /// Outside every allowed root.
    Denied,
    /// The operation failed: missing file, not a directory, no permission, …
    Failed,
    /// The answer does not fit the space it was given.
    TooLarge,
};

/// One allowed directory, absolute and in plain words (no `..`, no trailing `/`).
pub const Root = struct {
    path: []const u8,
    /// Created (mode 0700, with its parents) on first use: the application's own
    /// directories, which do not exist until it stores something.
    create: bool = false,
};

/// What `read_dir` and `stat` report an entry to be.
pub const Kind = enum(u8) { other = 0, file = 1, directory = 2, symlink = 3 };

/// A path matched to its root: `relative` is "" for the root itself.
pub const Located = struct {
    root: Root,
    relative: [:0]const u8,
};

/// Matches `path` to the first root it lies in, writing the part below the root into
/// `buffer`. Only words are compared here; the kernel enforces the boundary later.
pub fn locate(roots: []const Root, path: []const u8, buffer: []u8) Error!Located {
    if (path.len == 0 or path[0] != '/') return error.Denied;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.Denied;
    }
    for (roots) |root| {
        if (under(root.path, path)) |rest| {
            var len: usize = 0;
            var words = std.mem.splitScalar(u8, rest, '/');
            while (words.next()) |word| {
                if (word.len == 0 or std.mem.eql(u8, word, ".")) continue;
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

/// The rest of `path` when it is `root` or under it at a `/`; null otherwise.
fn under(root: []const u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, root)) return null;
    const rest = path[root.len..];
    if (rest.len == 0) return rest;
    if (rest[0] == '/') return rest[1..];
    if (root.len == 1) return rest; // the root is "/"
    return null;
}

/// `struct open_how` (linux/openat2.h).
const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
const resolve_no_magiclinks: u64 = 0x02;
const resolve_beneath: u64 = 0x08;

fn check(result: usize) Error!usize {
    return switch (linux.errno(result)) {
        .SUCCESS => result,
        // Leaving the root — by `..`, an absolute link or a link pointing outside.
        .XDEV => error.Denied,
        else => error.Failed,
    };
}

/// Opens `relative` beneath `root_fd`; the kernel refuses anything that would leave it.
fn beneath(root_fd: i32, relative: [*:0]const u8, flags: linux.O, mode: u32) Error!i32 {
    const path: [*:0]const u8 = if (relative[0] == 0) "." else relative;
    var how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = mode,
        .resolve = resolve_beneath | resolve_no_magiclinks,
    };
    const result = linux.syscall4(.openat2, @bitCast(@as(isize, root_fd)), @intFromPtr(path), @intFromPtr(&how), @sizeOf(OpenHow));
    return @intCast(try check(result));
}

/// The root as a directory handle, created first when it may be.
pub fn openRoot(root: Root) Error!i32 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (root.path.len + 1 > buffer.len) return error.TooLarge;
    @memcpy(buffer[0..root.path.len], root.path);
    buffer[root.path.len] = 0;
    if (root.create) {
        // Each ancestor in turn, as `mkdir -p` would; existing ones are fine.
        var at: usize = 1;
        while (at <= root.path.len) : (at += 1) {
            if (at != root.path.len and buffer[at] != '/') continue;
            const saved = buffer[at];
            buffer[at] = 0;
            const made = linux.mkdirat(linux.AT.FDCWD, buffer[0..at :0], 0o700);
            buffer[at] = saved;
            switch (linux.errno(made)) {
                .SUCCESS, .EXIST => {},
                else => return error.Failed,
            }
        }
    }
    const opened = linux.openat(linux.AT.FDCWD, buffer[0..root.path.len :0], .{ .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0);
    return @intCast(try check(opened));
}

/// The directory holding `relative` and its last word, both beneath `root_fd`.
fn parentOf(root_fd: i32, relative: [:0]const u8, buffer: []u8) Error!struct { fd: i32, name: [:0]const u8 } {
    if (relative.len == 0) return error.Denied; // the root itself is not removed or made
    const slash = std.mem.lastIndexOfScalar(u8, relative, '/');
    const dir_len = slash orelse 0;
    if (dir_len + 1 > buffer.len) return error.TooLarge;
    @memcpy(buffer[0..dir_len], relative[0..dir_len]);
    buffer[dir_len] = 0;
    const fd = try beneath(root_fd, buffer[0..dir_len :0], .{ .DIRECTORY = true, .PATH = true, .CLOEXEC = true }, 0);
    const name_start = if (slash) |at| at + 1 else 0;
    return .{ .fd = fd, .name = relative[name_start..] };
}

/// The file's bytes, written into the front of `out`.
pub fn readFile(root_fd: i32, relative: [:0]const u8, out: []u8) Error!usize {
    const fd = try beneath(root_fd, relative, .{ .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (true) {
        if (len == out.len) {
            var probe: [1]u8 = undefined;
            const more = try check(linux.read(fd, &probe, 1));
            if (more != 0) return error.TooLarge;
            return len;
        }
        const got = try check(linux.read(fd, out[len..].ptr, out.len - len));
        if (got == 0) return len;
        len += got;
    }
}

/// Writes `data` to the file, creating it; replaces its contents unless `append`.
pub fn writeFile(root_fd: i32, relative: [:0]const u8, data: []const u8, append: bool) Error!void {
    if (relative.len == 0) return error.Failed;
    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    if (append) flags.APPEND = true else flags.TRUNC = true;
    const fd = try beneath(root_fd, relative, flags, 0o644);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < data.len) {
        done += try check(linux.write(fd, data[done..].ptr, data.len - done));
    }
}

/// Makes the directory; with `recursive`, its missing parents too, and an existing one is
/// not an error.
pub fn makeDirectory(root_fd: i32, relative: [:0]const u8, recursive: bool) Error!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (!recursive) return makeOne(root_fd, relative, &buffer, false);
    var at: usize = 0;
    while (at <= relative.len) : (at += 1) {
        if (at != relative.len and relative[at] != '/') continue;
        var prefix: [std.fs.max_path_bytes]u8 = undefined;
        if (at + 1 > prefix.len) return error.TooLarge;
        @memcpy(prefix[0..at], relative[0..at]);
        prefix[at] = 0;
        try makeOne(root_fd, prefix[0..at :0], &buffer, true);
    }
}

fn makeOne(root_fd: i32, relative: [:0]const u8, buffer: []u8, existing_ok: bool) Error!void {
    const parent = try parentOf(root_fd, relative, buffer);
    defer _ = linux.close(parent.fd);
    const made = linux.mkdirat(parent.fd, parent.name.ptr, 0o755);
    if (existing_ok and linux.errno(made) == .EXIST) return;
    _ = try check(made);
}

/// Removes a file, a symbolic link (not what it points to) or an empty directory.
pub fn remove(root_fd: i32, relative: [:0]const u8) Error!void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try parentOf(root_fd, relative, &buffer);
    defer _ = linux.close(parent.fd);
    const unlinked = linux.unlinkat(parent.fd, parent.name.ptr, 0);
    if (linux.errno(unlinked) == .ISDIR) {
        _ = try check(linux.unlinkat(parent.fd, parent.name.ptr, linux.AT.REMOVEDIR));
        return;
    }
    _ = try check(unlinked);
}

/// Whether something is there. Outside the roots is `Denied`, never `false`: the answer
/// would otherwise tell the page what exists where it may not look.
pub fn exists(root_fd: i32, relative: [:0]const u8) Error!bool {
    const fd = beneath(root_fd, relative, .{ .PATH = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.Denied => return error.Denied,
        else => return false,
    };
    _ = linux.close(fd);
    return true;
}

/// `stat`'s reply: kind, size in bytes, modification time in milliseconds since 1970.
pub const stat_bytes = 1 + 8 + 8;

/// Writes [`stat_bytes`] into `out`. Symbolic links inside the root are followed.
pub fn stat(root_fd: i32, relative: [:0]const u8, out: []u8) Error!usize {
    if (out.len < stat_bytes) return error.TooLarge;
    const fd = try beneath(root_fd, relative, .{ .PATH = true, .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);
    var info: linux.Statx = undefined;
    _ = try check(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &info));
    out[0] = @intFromEnum(kindOfMode(info.mode));
    std.mem.writeInt(u64, out[1..9], info.size, .little);
    const ms = info.mtime.sec * 1000 + @divTrunc(@as(i64, info.mtime.nsec), 1_000_000);
    std.mem.writeInt(i64, out[9..17], ms, .little);
    return stat_bytes;
}

fn kindOfMode(mode: u16) Kind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .directory,
        linux.S.IFLNK => .symlink,
        else => .other,
    };
}

/// The directory's entries, without `.` and `..`, each `[kind u8][name length u16][name]`.
pub fn readDirectory(root_fd: i32, relative: [:0]const u8, out: []u8) Error!usize {
    const fd = try beneath(root_fd, relative, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);
    var records: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    var len: usize = 0;
    while (true) {
        const got = try check(linux.getdents64(fd, &records, records.len));
        if (got == 0) return len;
        var at: usize = 0;
        while (at < got) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&records[at]);
            const name_ptr: [*:0]const u8 = @ptrCast(&records[at + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            at += entry.reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (len + 3 + name.len > out.len) return error.TooLarge;
            out[len] = @intFromEnum(kindOfEntry(entry.type));
            std.mem.writeInt(u16, out[len + 1 ..][0..2], @intCast(name.len), .little);
            @memcpy(out[len + 3 ..][0..name.len], name);
            len += 3 + name.len;
        }
    }
}

fn kindOfEntry(dt: u8) Kind {
    return switch (dt) {
        linux.DT.REG => .file,
        linux.DT.DIR => .directory,
        linux.DT.LNK => .symlink,
        else => .other,
    };
}

// ---------------------------------------------------------------------------------------
// Tests: a real directory tree under /tmp, with links planted to escape it.

const Tree = struct {
    base: [128]u8 = undefined,
    base_len: usize = 0,

    fn path(tree: *const Tree) []const u8 {
        return tree.base[0..tree.base_len];
    }

    fn make() !Tree {
        var tree: Tree = .{};
        const written = try std.fmt.bufPrint(&tree.base, "/tmp/lepton-fs-test-{d}", .{linux.getpid()});
        tree.base_len = written.len;
        try tree.shell("rm -rf {0s} && mkdir -p {0s}/root/sub {0s}/outside && echo secret > {0s}/outside/secret.txt && echo inside > {0s}/root/sub/in.txt && ln -s ../outside {0s}/root/escape && ln -s /etc {0s}/root/absolute && ln -s sub/in.txt {0s}/root/inlink");
        return tree;
    }

    fn shell(tree: *const Tree, comptime format: []const u8) !void {
        var command: [1024]u8 = undefined;
        const text = try std.fmt.bufPrintZ(&command, format, .{tree.path()});
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", text.ptr };
        const pid = linux.fork();
        if (pid == 0) {
            _ = linux.execve("/bin/sh", &argv, @ptrCast(std.c.environ));
            linux.exit(127);
        }
        var status: u32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        if (status != 0) return error.ShellFailed;
    }

    fn remove(tree: *const Tree) void {
        tree.shell("rm -rf {0s}") catch {};
    }

    fn root(tree: *const Tree, buffer: []u8, tail: []const u8, create: bool) !Root {
        return .{ .path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ tree.path(), tail }), .create = create };
    }
};

test "paths are matched to a root by their words, and never by `..`" {
    const roots = [_]Root{ .{ .path = "/home/u/.local/share/app" }, .{ .path = "/home/u/Belgeler/notlar" } };
    var buffer: [256]u8 = undefined;
    const doc = try locate(&roots, "/home/u/Belgeler/notlar/a//./b.txt", &buffer);
    try std.testing.expectEqualStrings("/home/u/Belgeler/notlar", doc.root.path);
    try std.testing.expectEqualStrings("a/b.txt", doc.relative);
    try std.testing.expectEqualStrings("", (try locate(&roots, "/home/u/.local/share/app", &buffer)).relative);
    try std.testing.expectError(error.Denied, locate(&roots, "/home/u/Belgeler/notlarX/a", &buffer));
    try std.testing.expectError(error.Denied, locate(&roots, "/home/u/Belgeler/notlar/../secret", &buffer));
    try std.testing.expectError(error.Denied, locate(&roots, "relative/path", &buffer));
    try std.testing.expectError(error.Denied, locate(&roots, "/etc/passwd", &buffer));
    try std.testing.expectError(error.Denied, locate(&.{}, "/home/u/Belgeler/notlar/a", &buffer));
}

test "links that leave the root are refused by the kernel; links inside it work" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [256]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer _ = linux.close(root_fd);
    var out: [64]u8 = undefined;

    try std.testing.expectEqualStrings("inside\n", out[0..try readFile(root_fd, "sub/in.txt", &out)]);
    try std.testing.expectEqualStrings("inside\n", out[0..try readFile(root_fd, "inlink", &out)]);
    try std.testing.expectError(error.Denied, readFile(root_fd, "escape/secret.txt", &out));
    try std.testing.expectError(error.Denied, readFile(root_fd, "absolute/hostname", &out));
    try std.testing.expectError(error.Denied, writeFile(root_fd, "escape/planted.txt", "x", false));
    try std.testing.expectError(error.Denied, exists(root_fd, "escape/secret.txt"));
    try std.testing.expectError(error.Denied, stat(root_fd, "escape", &out));
    try std.testing.expectError(error.Denied, readDirectory(root_fd, "escape", &out));
    try std.testing.expectError(error.Denied, makeDirectory(root_fd, "escape/new", false));
    try std.testing.expectError(error.Failed, readFile(root_fd, "missing.txt", &out));
    // Removing a link removes the link, never what it points to.
    try remove(root_fd, "escape");
    var check_buffer: [256]u8 = undefined;
    const outside = try tree.root(&check_buffer, "outside", false);
    const outside_fd = try openRoot(outside);
    defer _ = linux.close(outside_fd);
    try std.testing.expect(try exists(outside_fd, "secret.txt"));
}

test "write, read, append, list, stat, make and remove inside a root" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [256]u8 = undefined;
    // An application's own directory does not exist yet; it is made on first use.
    const root_fd = try openRoot(try tree.root(&root_buffer, "app/data", true));
    defer _ = linux.close(root_fd);

    try writeFile(root_fd, "notes.txt", "bir", false);
    try writeFile(root_fd, "notes.txt", " iki", true);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("bir iki", out[0..try readFile(root_fd, "notes.txt", &out)]);
    try writeFile(root_fd, "notes.txt", "üç", false);
    try std.testing.expectEqualStrings("üç", out[0..try readFile(root_fd, "notes.txt", &out)]);
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.TooLarge, readFile(root_fd, "notes.txt", &tiny));

    try std.testing.expectError(error.Failed, makeDirectory(root_fd, "a/b/c", false));
    try makeDirectory(root_fd, "a/b/c", true);
    try makeDirectory(root_fd, "a/b/c", true);
    try std.testing.expectError(error.Failed, makeDirectory(root_fd, "a", false));
    try std.testing.expect(try exists(root_fd, "a/b/c"));
    try std.testing.expect(!try exists(root_fd, "a/b/d"));

    const stat_len = try stat(root_fd, "notes.txt", &out);
    try std.testing.expectEqual(stat_bytes, stat_len);
    try std.testing.expectEqual(@intFromEnum(Kind.file), out[0]);
    try std.testing.expectEqual(@as(u64, "üç".len), std.mem.readInt(u64, out[1..9], .little));
    try std.testing.expect(std.mem.readInt(i64, out[9..17], .little) > 1_700_000_000_000);
    _ = try stat(root_fd, "", &out);
    try std.testing.expectEqual(@intFromEnum(Kind.directory), out[0]);

    const listed = out[0..try readDirectory(root_fd, "", &out)];
    var names: [2][]const u8 = undefined;
    var kinds: [2]u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at < listed.len) : (count += 1) {
        const name_len = std.mem.readInt(u16, listed[at + 1 ..][0..2], .little);
        kinds[count] = listed[at];
        names[count] = listed[at + 3 ..][0..name_len];
        at += 3 + name_len;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    for (names[0..count], kinds[0..count]) |name, kind| {
        if (std.mem.eql(u8, name, "a")) try std.testing.expectEqual(@intFromEnum(Kind.directory), kind) else {
            try std.testing.expectEqualStrings("notes.txt", name);
            try std.testing.expectEqual(@intFromEnum(Kind.file), kind);
        }
    }

    try std.testing.expectError(error.Failed, remove(root_fd, "a/b"));
    try remove(root_fd, "a/b/c");
    try remove(root_fd, "notes.txt");
    try std.testing.expect(!try exists(root_fd, "notes.txt"));
    try std.testing.expectError(error.Denied, remove(root_fd, ""));
}
