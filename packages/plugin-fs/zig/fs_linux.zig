//! The Linux half of `fs.zig`: every operation through `openat2(root, relative,
//! RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS)`, so the kernel refuses any resolution that
//! leaves the root (see `fs.zig`).

const std = @import("std");
const linux = std.os.linux;
const fs = @import("fs.zig");

const Error = fs.Error;
const Root = fs.Root;
const Kind = fs.Kind;
const stat_bytes = fs.stat_bytes;

/// An open directory or file: a Linux file descriptor.
pub const Handle = i32;

pub fn close(handle: Handle) void {
    _ = linux.close(handle);
}

/// Whether two handles are the same directory: by device and inode.
pub fn sameDirectory(a: Handle, b: Handle) bool {
    var first: linux.Statx = undefined;
    var second: linux.Statx = undefined;
    if (linux.statx(a, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &first) != 0) return false;
    if (linux.statx(b, "", linux.AT.EMPTY_PATH, .{ .INO = true }, &second) != 0) return false;
    return first.ino == second.ino and first.dev_major == second.dev_major and first.dev_minor == second.dev_minor;
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

// --- Watching ------------------------------------------------------------------------

/// What `drainWatch` reports for one change.
pub const Change = enum(u8) { created = 1, modified = 2, removed = 3, renamed_from = 4, renamed_to = 5, gone = 6 };

/// The process's one inotify descriptor, made on the first watch.
var inotify_fd: i32 = -1;

/// One inotify watch: the user's watch it belongs to (`number`, the root's own watch
/// descriptor) and its directory below that watch's path, `/`-ended ("" for the path
/// itself). A recursive watch is one of these per directory.
const Sub = struct {
    wd: i32,
    number: u32,
    recursive: bool,
    prefix_len: u16,
    prefix: [max_prefix]u8,
};
const max_prefix = 512;
/// Directories watched in all, across every watch: inotify's own default limit per user
/// is 8192 (`max_user_watches` is often far higher); a note vault has a few hundred.
const max_subs = 2048;
var subs: [max_subs]Sub = undefined;
var sub_count: usize = 0;

/// A recursive watch's path, kept open (`O_PATH`) so a directory created inside it later
/// is opened beneath it like everything else.
const Rooted = struct { number: u32, fd: i32 };
var roots: [64]Rooted = undefined;
var root_count: usize = 0;

const watch_mask: u32 = linux.IN.CREATE | linux.IN.CLOSE_WRITE | linux.IN.DELETE | linux.IN.MOVED_FROM |
    linux.IN.MOVED_TO | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

/// Watches `fd`'s file or directory through `/proc/self/fd/N`: inotify takes a path, and
/// this one names exactly what was opened beneath the root.
fn addWatch(fd: i32) Error!i32 {
    var through: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&through, "/proc/self/fd/{d}", .{fd}, 0) catch return error.Failed;
    return @intCast(try check(linux.inotify_add_watch(inotify_fd, path.ptr, watch_mask)));
}

fn register(wd: i32, number: u32, recursive: bool, prefix: []const u8) Error!void {
    if (prefix.len > max_prefix) return error.TooLarge;
    for (subs[0..sub_count]) |*sub| {
        // The same directory reached twice (a hard-linked tree cannot happen for
        // directories, but two watches on one path can): the first registration stays.
        if (sub.wd == wd) return;
    }
    if (sub_count == max_subs) return error.TooLarge;
    var sub: Sub = .{ .wd = wd, .number = number, .recursive = recursive, .prefix_len = @intCast(prefix.len), .prefix = undefined };
    @memcpy(sub.prefix[0..prefix.len], prefix);
    subs[sub_count] = sub;
    sub_count += 1;
}

fn subOf(wd: i32) ?*Sub {
    for (subs[0..sub_count]) |*sub| if (sub.wd == wd) return sub;
    return null;
}

fn dropSub(wd: i32) void {
    for (subs[0..sub_count], 0..) |sub, index| {
        if (sub.wd != wd) continue;
        subs[index] = subs[sub_count - 1];
        sub_count -= 1;
        return;
    }
}

/// Watches `relative` (a directory: its entries; a file: itself) and returns the watch's
/// number. With `recursive`, every directory below it too, and any made there later;
/// names then come relative to `relative` ("notes/a.md"). Everything is opened beneath the
/// root before it is watched, so a link planted in the tree cannot lead a watch out of the
/// scope: links are not followed into.
pub fn watch(root_fd: i32, relative: [:0]const u8, recursive: bool) Error!u32 {
    if (inotify_fd < 0) {
        const made = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        inotify_fd = @intCast(try check(made));
    }
    const fd = try beneath(root_fd, relative, .{ .PATH = true, .CLOEXEC = true }, 0);
    var keep_fd = false;
    defer if (!keep_fd) {
        _ = linux.close(fd);
    };
    const wd = try addWatch(fd);
    const number: u32 = @intCast(wd);
    errdefer unwatch(number);
    try register(wd, number, recursive, "");
    if (recursive) {
        if (root_count == roots.len) return error.TooLarge;
        roots[root_count] = .{ .number = number, .fd = fd };
        root_count += 1;
        keep_fd = true;
        try watchBelow(fd, number, "", 0);
    }
    return number;
}

/// Watches every directory under `dir_path` (beneath `root_fd`, the watch's own path),
/// depth first, to `max_depth`.
fn watchBelow(root_fd: i32, number: u32, prefix: []const u8, depth: usize) Error!void {
    if (depth == max_depth) return error.TooLarge;
    var path_buffer: [max_prefix + 1]u8 = undefined;
    if (prefix.len > max_prefix) return error.TooLarge;
    @memcpy(path_buffer[0..prefix.len], prefix);
    path_buffer[prefix.len] = 0;
    const dir_fd = beneath(root_fd, path_buffer[0..prefix.len :0], .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |err| switch (err) {
        // Not a directory (a file watched recursively): nothing below it.
        error.Failed => return,
        else => return err,
    };
    defer _ = linux.close(dir_fd);
    var records: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const got = try check(linux.getdents64(dir_fd, &records, records.len));
        if (got == 0) return;
        var at: usize = 0;
        while (at < got) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&records[at]);
            at += entry.reclen;
            if (entry.type != linux.DT.DIR) continue;
            const child = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
            try watchChild(root_fd, number, prefix, child, depth);
        }
    }
}

/// Watches the directory `prefix ++ name` below a recursive watch's path, and what is in it.
fn watchChild(root_fd: i32, number: u32, prefix: []const u8, name: []const u8, depth: usize) Error!void {
    var child_prefix: [max_prefix + 1]u8 = undefined;
    const joined = std.fmt.bufPrint(&child_prefix, "{s}{s}/", .{ prefix, name }) catch return error.TooLarge;
    child_prefix[joined.len - 1] = 0;
    const child_fd = beneath(root_fd, child_prefix[0 .. joined.len - 1 :0], .{ .PATH = true, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return;
    defer _ = linux.close(child_fd);
    child_prefix[joined.len - 1] = '/';
    const wd = try addWatch(child_fd);
    try register(wd, number, true, joined);
    try watchBelow(root_fd, number, joined, depth + 1);
}

fn rootFd(number: u32) ?i32 {
    for (roots[0..root_count]) |entry| if (entry.number == number) return entry.fd;
    return null;
}

/// Stops the watch `number` and, for a recursive one, every directory below it.
pub fn unwatch(number: u32) void {
    if (inotify_fd < 0) return;
    var index: usize = 0;
    while (index < sub_count) {
        if (subs[index].number == number) {
            _ = linux.inotify_rm_watch(inotify_fd, subs[index].wd);
            subs[index] = subs[sub_count - 1];
            sub_count -= 1;
        } else index += 1;
    }
    for (roots[0..root_count], 0..) |entry, at| {
        if (entry.number != number) continue;
        _ = linux.close(entry.fd);
        roots[at] = roots[root_count - 1];
        root_count -= 1;
        break;
    }
}

/// Calls `report(context, number, change, name)` for every change waiting; never blocks.
/// A directory made inside a recursive watch is watched before its own events can be
/// missed for long; one already filled when it arrived (moved in) is walked whole.
pub fn drainWatch(context: anytype, report: fn (@TypeOf(context), u32, Change, []const u8) void) void {
    if (inotify_fd < 0) return;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const got = linux.read(inotify_fd, &buffer, buffer.len);
        if (linux.errno(got) != .SUCCESS or got == 0) return;
        var at: usize = 0;
        while (at + @sizeOf(linux.inotify_event) <= got) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
            at += @sizeOf(linux.inotify_event) + event.len;
            const name_bytes = buffer[at - event.len ..][0..event.len];
            const name = std.mem.sliceTo(name_bytes, 0);
            const mask = event.mask;
            if (mask & linux.IN.IGNORED != 0) {
                dropSub(event.wd);
                continue;
            }
            const sub = subOf(event.wd) orelse continue;
            const is_root = sub.prefix_len == 0;
            const change: ?Change = if (mask & linux.IN.CREATE != 0) .created else if (mask & linux.IN.CLOSE_WRITE != 0) .modified else if (mask & linux.IN.DELETE != 0) .removed else if (mask & linux.IN.MOVED_FROM != 0) .renamed_from else if (mask & linux.IN.MOVED_TO != 0) .renamed_to else if (mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0 and is_root) .gone else null;
            const which = change orelse continue;
            var full: [max_prefix + 256]u8 = undefined;
            const path = std.fmt.bufPrint(&full, "{s}{s}", .{ sub.prefix[0..sub.prefix_len], name }) catch continue;
            if (sub.recursive and mask & linux.IN.ISDIR != 0 and (which == .created or which == .renamed_to)) {
                if (rootFd(sub.number)) |root| watchChild(root, sub.number, sub.prefix[0..sub.prefix_len], name, 0) catch {};
            }
            report(context, sub.number, which, path);
        }
    }
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

/// A parent directory opened beneath the root, and the last name in it.
const Parent = struct { fd: i32, name: [:0]const u8 };

/// The directory holding `relative` and its last word, both beneath `root_fd`.
fn parentOf(root_fd: i32, relative: [:0]const u8, buffer: []u8) Error!Parent {
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

/// Up to `out.len` bytes of the file from `offset`; fewer only at its end. A file larger
/// than one `invoke` reply is read in such pieces.
pub fn readRange(root_fd: i32, relative: [:0]const u8, offset: u64, out: []u8) Error!usize {
    // A page passes the offset; past what `pread` takes is past every file's end.
    if (offset > std.math.maxInt(i64) - out.len) return 0;
    const fd = try beneath(root_fd, relative, .{ .CLOEXEC = true }, 0);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < out.len) {
        const got = try check(linux.pread(fd, out[len..].ptr, out.len - len, @intCast(offset + len)));
        if (got == 0) break;
        len += got;
    }
    return len;
}

/// Renames `from` to `to`, both below the same root; replaces an existing file at `to`
/// in one step, which is how a file written in pieces under a temporary name is saved.
pub fn rename(root_fd: i32, from: [:0]const u8, to: [:0]const u8) Error!void {
    if (from.len == 0 or to.len == 0) return error.Denied;
    var from_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source = try parentOf(root_fd, from, &from_buffer);
    defer _ = linux.close(source.fd);
    const target = try parentOf(root_fd, to, &to_buffer);
    defer _ = linux.close(target.fd);
    if (std.mem.endsWith(u8, from, saving_suffix)) keepMode(source, target);
    _ = try check(linux.renameat(source.fd, source.name.ptr, target.fd, target.name.ptr));
}

/// The name `@lepton-desk/plugin-fs` writes a large file under before renaming it over
/// the old one (`savingSuffix` in `src/index.ts`).
const saving_suffix = ".lepton-save";

/// A file saved in pieces keeps the old file's permissions: it is created owner-only
/// (`writeFile`), and a file that was 0600 must not come back 0644. A new file gets the
/// mode `writeFile` gives any other.
fn keepMode(source: Parent, target: Parent) void {
    var info: linux.Statx = undefined;
    const mode: u32 = if (linux.statx(target.fd, target.name.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .MODE = true }, &info) == 0)
        info.mode & 0o7777
    else
        new_file_mode;
    _ = linux.fchmodat(source.fd, source.name.ptr, mode);
}

/// What a new file is created with, before the umask.
const new_file_mode = 0o644;

/// How deep `removeTree` goes before refusing: a note vault is not that deep, and a
/// bound keeps a malicious tree from exhausting the stack.
const max_depth = 32;

/// Removes `relative` and, for a directory, everything in it. A symbolic link is removed
/// as a link: nothing it points to is touched, inside the root or out.
pub fn removeTree(root_fd: i32, relative: [:0]const u8) Error!void {
    if (relative.len == 0) return error.Denied;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = try parentOf(root_fd, relative, &buffer);
    defer _ = linux.close(parent.fd);
    try removeIn(parent.fd, parent.name, 0);
}

fn removeIn(dir_fd: i32, name: [:0]const u8, depth: usize) Error!void {
    const unlinked = linux.unlinkat(dir_fd, name.ptr, 0);
    if (linux.errno(unlinked) != .ISDIR) {
        _ = try check(unlinked);
        return;
    }
    if (depth == max_depth) return error.TooLarge;
    // `NOFOLLOW`: `unlinkat` said a directory, and a link swapped in since must not be
    // followed out of the root.
    const fd = try check(linux.openat(dir_fd, name.ptr, .{ .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0));
    defer _ = linux.close(@intCast(fd));
    var records: [8192]u8 align(@alignOf(linux.dirent64)) = undefined;
    // Passes over the directory until one removes nothing: `.` and `..` are always
    // listed, so an empty directory never reads as zero bytes after a rewind.
    var removed_any = true;
    while (removed_any) {
        removed_any = false;
        const got = try check(linux.getdents64(@intCast(fd), &records, records.len));
        if (got == 0) break;
        var at: usize = 0;
        while (at < got) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&records[at]);
            at += entry.reclen;
            const child = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            if (std.mem.eql(u8, child, ".") or std.mem.eql(u8, child, "..")) continue;
            var child_buffer: [256]u8 = undefined;
            @memcpy(child_buffer[0..child.len], child);
            child_buffer[child.len] = 0;
            try removeIn(@intCast(fd), child_buffer[0..child.len :0], depth + 1);
            removed_any = true;
        }
        // Entries were removed while reading: start over until the directory is empty.
        _ = linux.lseek(@intCast(fd), 0, linux.SEEK.SET);
    }
    _ = try check(linux.unlinkat(dir_fd, name.ptr, linux.AT.REMOVEDIR));
}

/// Writes `data` to the file, creating it; replaces its contents unless `append`.
pub fn writeFile(root_fd: i32, relative: [:0]const u8, data: []const u8, append: bool) Error!void {
    if (relative.len == 0) return error.Failed;
    var flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    if (append) flags.APPEND = true else flags.TRUNC = true;
    const mode: u32 = if (std.mem.endsWith(u8, relative, saving_suffix)) 0o600 else new_file_mode;
    const fd = try beneath(root_fd, relative, flags, mode);
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
        const text = try std.fmt.bufPrintSentinel(&command, format, .{tree.path()}, 0);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", text.ptr };
        const pid = linux.fork();
        if (pid == 0) {
            _ = linux.execve("/bin/sh", &argv, @ptrCast(std.c.environ));
            linux.exit(127);
        }
        // libc's `waitpid`: its status is a `c_int` in every Zig, where `linux.wait4`'s
        // pointer type changed between 0.16 and 0.17.
        var status: c_int = 0;
        _ = std.c.waitpid(@intCast(pid), &status, 0);
        if (status != 0) return error.ShellFailed;
    }

    fn remove(tree: *const Tree) void {
        tree.shell("rm -rf {0s}") catch {};
    }

    fn root(tree: *const Tree, buffer: []u8, tail: []const u8, create: bool) !Root {
        return .{ .path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ tree.path(), tail }), .create = create };
    }
};

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

test "large files are read in ranges, saved by renaming, and trees removed without following links" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [256]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer _ = linux.close(root_fd);

    // 200 000 bytes, three times what one reply carries: written in pieces under a
    // temporary name, then renamed over the old file in one step.
    var piece: [65_536]u8 = undefined;
    for (&piece, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    try writeFile(root_fd, "big.md", "old", false);
    _ = linux.fchmodat(root_fd, "big.md", 0o600);
    var written: usize = 0;
    while (written < 200_000) {
        const size = @min(piece.len, 200_000 - written);
        try writeFile(root_fd, "big.md.lepton-save", piece[0..size], written != 0);
        written += size;
    }
    try rename(root_fd, "big.md.lepton-save", "big.md");
    try std.testing.expect(!try exists(root_fd, "big.md.lepton-save"));
    // The saved file keeps the old one's owner-only mode.
    var info: linux.Statx = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.statx(root_fd, "big.md", 0, .{ .MODE = true }, &info));
    try std.testing.expectEqual(@as(u32, 0o600), info.mode & 0o7777);
    // An offset past what `pread` takes reads nothing rather than stopping the core.
    var tail: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try readRange(root_fd, "big.md", std.math.maxInt(u64), &tail));
    var out: [65_536]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const got = try readRange(root_fd, "big.md", total, &out);
        if (got == 0) break;
        // Each piece was written from its own start, so the pattern restarts every piece.
        try std.testing.expectEqual(@as(u8, @intCast('a' + (total % piece.len) % 26)), out[0]);
        total += got;
        if (got < out.len) break;
    }
    try std.testing.expectEqual(@as(usize, 200_000), total);

    // Renaming out of the root, or through a link that leaves it, is refused.
    try std.testing.expectError(error.Denied, rename(root_fd, "big.md", "escape/taken.md"));
    try std.testing.expectError(error.Denied, rename(root_fd, "../outside/secret.txt", "stolen.txt"));

    // A folder of notes with a link out of the root inside it: the folder goes, the
    // link goes, what it pointed to stays.
    try makeDirectory(root_fd, "vault/daily/2026", true);
    try writeFile(root_fd, "vault/daily/2026/10-16.md", "bugün", false);
    try writeFile(root_fd, "vault/index.md", "# Kasa", false);
    try tree.shell("ln -s ../../outside {0s}/root/vault/out");
    try removeTree(root_fd, "vault");
    try std.testing.expect(!try exists(root_fd, "vault"));
    var check_buffer: [256]u8 = undefined;
    const outside_fd = try openRoot(try tree.root(&check_buffer, "outside", false));
    defer _ = linux.close(outside_fd);
    try std.testing.expect(try exists(outside_fd, "secret.txt"));
    try std.testing.expectError(error.Denied, removeTree(root_fd, ""));
    try std.testing.expectError(error.Denied, removeTree(root_fd, "escape/secret.txt"));
}

test "a watched directory reports its entries' changes, and its number is the watch's" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [256]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer _ = linux.close(root_fd);

    const number = try watch(root_fd, "", false);
    defer unwatch(number);
    try writeFile(root_fd, "note.md", "x", false);
    try remove(root_fd, "note.md");

    const Seen = struct {
        changes: [8]Change = undefined,
        count: usize = 0,
        number: u32,
        fn note(self: *@This(), from: u32, change: Change, name: []const u8) void {
            if (from != self.number or !std.mem.eql(u8, name, "note.md") or self.count == self.changes.len) return;
            self.changes[self.count] = change;
            self.count += 1;
        }
    };
    var seen: Seen = .{ .number = number };
    drainWatch(&seen, Seen.note);
    try std.testing.expectEqualSlices(Change, &.{ .created, .modified, .removed }, seen.changes[0..seen.count]);
    // A path that leaves the root is refused before anything is watched.
    try std.testing.expectError(error.Denied, watch(root_fd, "../outside", false));
}

test "a recursive watch sees every directory below it, and those made later" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [256]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer _ = linux.close(root_fd);
    try makeDirectory(root_fd, "notes/2026", true);

    const number = try watch(root_fd, "", true);
    defer unwatch(number);
    try writeFile(root_fd, "notes/2026/a.md", "x", false);
    try makeDirectory(root_fd, "later", false);

    const Seen = struct {
        names: [16][64]u8 = undefined,
        lens: [16]usize = undefined,
        count: usize = 0,
        number: u32,
        fn note(self: *@This(), from: u32, change: Change, name: []const u8) void {
            if (from != self.number or change != .created or self.count == self.names.len) return;
            @memcpy(self.names[self.count][0..name.len], name);
            self.lens[self.count] = name.len;
            self.count += 1;
        }
        fn saw(self: *const @This(), name: []const u8) bool {
            for (0..self.count) |i| if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return true;
            return false;
        }
    };
    var seen: Seen = .{ .number = number };
    drainWatch(&seen, Seen.note);
    try std.testing.expect(seen.saw("notes/2026/a.md"));
    try std.testing.expect(seen.saw("later"));
    // `later` is watched now: a file made in it arrives with its path.
    try writeFile(root_fd, "later/b.md", "y", false);
    drainWatch(&seen, Seen.note);
    try std.testing.expect(seen.saw("later/b.md"));
}
