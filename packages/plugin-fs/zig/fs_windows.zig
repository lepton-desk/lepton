//! The Windows half of `fs.zig`: every path below a root is opened by one `NtCreateFile`
//! with the root's handle as `RootDirectory` and `OBJ_DONT_REPARSE`, so the kernel refuses
//! any name that would pass through a junction or a symbolic link (see `fs.zig`). The root
//! itself is opened by its full name, links included: it is the application's or the
//! user's choice. No Win32 path layer: names are given to the kernel as they are, after
//! `fs.locate` refused what Win32 would read differently (streams, devices, trailing dots).

const std = @import("std");
const w = std.os.windows;
const fs = @import("fs.zig");

const Error = fs.Error;
const Root = fs.Root;
const Kind = fs.Kind;
const stat_bytes = fs.stat_bytes;

/// An open directory or file: an NT handle.
pub const Handle = w.HANDLE;

/// The longest path below a root, in UTF-16 units.
const wide_max = 4096;
/// One name, in UTF-16 units (NTFS's limit).
const name_max = 255;

const status_reparse_point_encountered: u32 = 0xC000050B;
const status_object_name_collision: u32 = 0xC0000035;
const status_end_of_file: u32 = 0xC0000011;
const status_no_more_files: u32 = 0x80000006;

/// `FILE_INFORMATION_CLASS` values std leaves unnamed.
const Class = struct {
    const rename: w.FILE.INFORMATION_CLASS = @enumFromInt(10);
    const attribute_tag: w.FILE.INFORMATION_CLASS = @enumFromInt(35);
    const id: w.FILE.INFORMATION_CLASS = @enumFromInt(59);
    const disposition_ex: w.FILE.INFORMATION_CLASS = @enumFromInt(64);
};

fn check(status: w.NTSTATUS) Error!void {
    return switch (@intFromEnum(status)) {
        0 => {},
        // A junction or a symbolic link on the way: a way out of the root, or not, refused.
        status_reparse_point_encountered => error.Denied,
        else => error.Failed,
    };
}

pub fn close(handle: Handle) void {
    _ = w.ntdll.NtClose(handle);
}

/// `relative` as the kernel reads it: UTF-16, `\` between words.
fn wideOf(relative: []const u8, out: []u16) Error![]u16 {
    if (relative.len > out.len) return error.TooLarge;
    const len = std.unicode.utf8ToUtf16Le(out, relative) catch return error.Failed;
    for (out[0..len]) |*unit| {
        if (unit.* == '/') unit.* = '\\';
    }
    return out[0..len];
}

const Open = struct {
    access: w.ACCESS_MASK,
    disposition: w.FILE.CREATE_DISPOSITION = .OPEN,
    options: w.FILE.MODE = .{ .IO = .SYNCHRONOUS_NONALERT },
    /// Open a link as itself rather than refusing it: how a link is removed or renamed
    /// without touching what it points to. Links earlier in the path are still refused.
    link_itself: bool = false,
};

fn openRelative(directory: Handle, name: []const u16, how: Open) Error!Handle {
    var text: w.UNICODE_STRING = .{ .Length = @intCast(name.len * 2), .MaximumLength = @intCast(name.len * 2), .Buffer = @constCast(name.ptr) };
    var attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = directory, .ObjectName = &text, .Attributes = .{ .DONT_REPARSE = true } };
    var access = how.access;
    access.STANDARD.SYNCHRONIZE = true;
    var options = how.options;
    options.IO = .SYNCHRONOUS_NONALERT;
    options.OPEN_REPARSE_POINT = how.link_itself;
    var io: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    try check(w.ntdll.NtCreateFile(&handle, access, &attributes, &io, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, how.disposition, options, null, 0));
    return handle;
}

/// Opens `relative` beneath `root`; the kernel refuses anything that would leave it.
fn beneath(root: Handle, relative: []const u8, how: Open) Error!Handle {
    var words = std.mem.splitScalar(u8, relative, '/');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, "..")) return error.Denied;
    }
    var wide: [wide_max]u16 = undefined;
    return openRelative(root, try wideOf(relative, &wide), how);
}

const read_access: w.ACCESS_MASK = .{ .SPECIFIC = .{ .FILE = .{ .READ_DATA = true, .READ_ATTRIBUTES = true } } };
const attributes_access: w.ACCESS_MASK = .{ .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } } };
const list_access: w.ACCESS_MASK = .{ .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .TRAVERSE = true, .READ_ATTRIBUTES = true } } };
const delete_access: w.ACCESS_MASK = .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true } }, .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true } } };

/// The root as a directory handle, created first (with its parents) when it may be.
pub fn openRoot(root: Root) Error!Handle {
    const prefix = [_]u16{ '\\', '?', '?', '\\' };
    var wide: [wide_max]u16 = undefined;
    @memcpy(wide[0..prefix.len], &prefix);
    const path = try wideOf(root.path, wide[prefix.len..]);
    const full = wide[0 .. prefix.len + path.len];
    if (root.create) {
        // Each ancestor in turn, as `mkdir -p` would, from the first one below the drive.
        var at: usize = prefix.len + 3;
        while (at <= full.len) : (at += 1) {
            if (at != full.len and full[at] != '\\') continue;
            const made = openAbsolute(full[0..at], .{ .access = attributes_access, .disposition = .OPEN_IF, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } }) catch |err| switch (err) {
                error.Denied => return error.Denied,
                else => return error.Failed,
            };
            close(made);
        }
    }
    return openAbsolute(full, .{ .access = list_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } });
}

fn openAbsolute(name: []const u16, how: Open) Error!Handle {
    var text: w.UNICODE_STRING = .{ .Length = @intCast(name.len * 2), .MaximumLength = @intCast(name.len * 2), .Buffer = @constCast(name.ptr) };
    var attributes: w.OBJECT.ATTRIBUTES = .{ .ObjectName = &text };
    var access = how.access;
    access.STANDARD.SYNCHRONIZE = true;
    var options = how.options;
    options.IO = .SYNCHRONOUS_NONALERT;
    var io: w.IO_STATUS_BLOCK = undefined;
    var handle: w.HANDLE = undefined;
    try check(w.ntdll.NtCreateFile(&handle, access, &attributes, &io, null, .{}, .{ .READ = true, .WRITE = true, .DELETE = true }, how.disposition, options, null, 0));
    return handle;
}

/// The directory holding `relative` (the root's own handle when it is directly in it,
/// `owned` false) and its last word.
const Parent = struct {
    handle: Handle,
    owned: bool,
    name: []const u8,

    fn release(parent: Parent) void {
        if (parent.owned) close(parent.handle);
    }
};

fn parentOf(root: Handle, relative: []const u8) Error!Parent {
    if (relative.len == 0) return error.Denied; // the root itself is not removed or made
    const slash = std.mem.lastIndexOfScalar(u8, relative, '/') orelse return .{ .handle = root, .owned = false, .name = relative };
    const handle = try beneath(root, relative[0..slash], .{ .access = list_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } });
    return .{ .handle = handle, .owned = true, .name = relative[slash + 1 ..] };
}

/// Reads into `out` from `offset` (or the current position); 0 at the end.
fn readSome(handle: Handle, out: []u8, offset: ?u64) Error!usize {
    var io: w.IO_STATUS_BLOCK = undefined;
    var at: w.LARGE_INTEGER = @intCast(offset orelse 0);
    const status = w.ntdll.NtReadFile(handle, null, null, null, &io, out.ptr, @intCast(@min(out.len, std.math.maxInt(u32))), if (offset != null) &at else null, null);
    if (@intFromEnum(status) == status_end_of_file) return 0;
    try check(status);
    return io.Information;
}

/// The file's bytes, written into the front of `out`.
pub fn readFile(root: Handle, relative: [:0]const u8, out: []u8) Error!usize {
    if (relative.len == 0) return error.Failed;
    const handle = try beneath(root, relative, .{ .access = read_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .NON_DIRECTORY_FILE = true } });
    defer close(handle);
    var len: usize = 0;
    while (true) {
        if (len == out.len) {
            var probe: [1]u8 = undefined;
            if (try readSome(handle, &probe, null) != 0) return error.TooLarge;
            return len;
        }
        const got = try readSome(handle, out[len..], null);
        if (got == 0) return len;
        len += got;
    }
}

/// Up to `out.len` bytes of the file from `offset`; fewer only at its end.
pub fn readRange(root: Handle, relative: [:0]const u8, offset: u64, out: []u8) Error!usize {
    if (relative.len == 0) return error.Failed;
    // A page passes the offset; past what the read takes is past every file's end.
    if (offset > std.math.maxInt(i64) - out.len) return 0;
    const handle = try beneath(root, relative, .{ .access = read_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .NON_DIRECTORY_FILE = true } });
    defer close(handle);
    var len: usize = 0;
    while (len < out.len) {
        const got = try readSome(handle, out[len..], offset + len);
        if (got == 0) break;
        len += got;
    }
    return len;
}

/// `FILE_RENAME_INFORMATION` with room for one name: the target is named relative to
/// `root_directory`, so it stays below the root it was located in.
const RenameInformation = extern struct {
    replace_if_exists: u32,
    root_directory: ?Handle,
    name_bytes: u32,
    name: [name_max]u16,
};

/// Renames `from` to `to`, both below the same root; replaces an existing file at `to`
/// in one step, which is how a file written in pieces under a temporary name is saved.
pub fn rename(root: Handle, from: [:0]const u8, to: [:0]const u8) Error!void {
    if (from.len == 0 or to.len == 0) return error.Denied;
    const source = try beneath(root, from, .{ .access = delete_access, .link_itself = true });
    defer close(source);
    const target = try parentOf(root, to);
    defer target.release();
    var information: RenameInformation = .{ .replace_if_exists = 1, .root_directory = target.handle, .name_bytes = 0, .name = undefined };
    const name = try wideOf(target.name, &information.name);
    information.name_bytes = @intCast(name.len * 2);
    var io: w.IO_STATUS_BLOCK = undefined;
    try check(w.ntdll.NtSetInformationFile(source, &io, &information, @intCast(@offsetOf(RenameInformation, "name") + name.len * 2), Class.rename));
}

/// Marks the open file or directory deleted. POSIX semantics: its name is gone at once,
/// so a directory emptied this way can be removed right after.
fn deleteOpen(handle: Handle) Error!void {
    var flags: u32 = 0x1 | 0x2; // FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS
    var io: w.IO_STATUS_BLOCK = undefined;
    try check(w.ntdll.NtSetInformationFile(handle, &io, &flags, @sizeOf(u32), Class.disposition_ex));
}

const AttributeTag = extern struct { attributes: w.FILE.ATTRIBUTE, reparse_tag: u32 };

fn attributesOf(handle: Handle) Error!AttributeTag {
    var tag: AttributeTag = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    try check(w.ntdll.NtQueryInformationFile(handle, &io, &tag, @sizeOf(AttributeTag), Class.attribute_tag));
    return tag;
}

/// How deep `removeTree` goes before refusing.
const max_depth = 32;

/// Removes `relative` and, for a directory, everything in it. A link is removed as a
/// link: nothing it points to is touched, inside the root or out.
pub fn removeTree(root: Handle, relative: [:0]const u8) Error!void {
    if (relative.len == 0) return error.Denied;
    const handle = try beneath(root, relative, .{ .access = delete_access, .link_itself = true });
    defer close(handle);
    try removeOpen(handle, 0);
}

fn removeOpen(handle: Handle, depth: usize) Error!void {
    const tag = try attributesOf(handle);
    if (tag.attributes.DIRECTORY and !tag.attributes.REPARSE_POINT) {
        if (depth == max_depth) return error.TooLarge;
        var records: [8192]u8 align(8) = undefined;
        // Scans from the start until one finds nothing: names leave the listing as they go.
        while (true) {
            var io: w.IO_STATUS_BLOCK = undefined;
            const status = w.ntdll.NtQueryDirectoryFile(handle, null, null, null, &io, &records, records.len, .Directory, .FALSE, null, .TRUE);
            if (@intFromEnum(status) == status_no_more_files) break;
            try check(status);
            var removed_any = false;
            var at: usize = 0;
            while (true) {
                const entry: *align(1) const w.FILE_DIRECTORY_INFORMATION = @ptrCast(&records[at]);
                const name = entryName(records[at..], @offsetOf(w.FILE_DIRECTORY_INFORMATION, "FileName"), entry.FileNameLength);
                if (!isDots(name)) {
                    const child = try openRelative(handle, name, .{ .access = delete_access, .link_itself = true });
                    defer close(child);
                    try removeOpen(child, depth + 1);
                    removed_any = true;
                }
                if (entry.NextEntryOffset == 0) break;
                at += entry.NextEntryOffset;
            }
            if (!removed_any) break;
        }
    }
    try deleteOpen(handle);
}

fn entryName(record: []const u8, offset: usize, bytes: u32) []const u16 {
    const start: [*]align(1) const u16 = @ptrCast(record[offset..].ptr);
    return @as([*]const u16, @ptrCast(@alignCast(start)))[0 .. bytes / 2];
}

fn isDots(name: []const u16) bool {
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

/// Writes `data` to the file, creating it; replaces its contents unless `append`.
pub fn writeFile(root: Handle, relative: [:0]const u8, data: []const u8, append: bool) Error!void {
    if (relative.len == 0) return error.Failed;
    const access: w.ACCESS_MASK = .{ .SPECIFIC = .{ .FILE = if (append) .{ .APPEND_DATA = true } else .{ .WRITE_DATA = true } } };
    const handle = try beneath(root, relative, .{ .access = access, .disposition = if (append) .OPEN_IF else .OVERWRITE_IF, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .NON_DIRECTORY_FILE = true } });
    defer close(handle);
    var done: usize = 0;
    while (done < data.len) {
        var io: w.IO_STATUS_BLOCK = undefined;
        const chunk: u32 = @intCast(@min(data.len - done, std.math.maxInt(u32)));
        try check(w.ntdll.NtWriteFile(handle, null, null, null, &io, data[done..].ptr, chunk, null, null));
        if (io.Information == 0) return error.Failed;
        done += io.Information;
    }
}

/// Makes the directory; with `recursive`, its missing parents too, and an existing one is
/// not an error.
pub fn makeDirectory(root: Handle, relative: [:0]const u8, recursive: bool) Error!void {
    if (!recursive) return makeOne(root, relative, false);
    var at: usize = 0;
    while (at <= relative.len) : (at += 1) {
        if (at != relative.len and relative[at] != '/') continue;
        try makeOne(root, relative[0..at], true);
    }
}

fn makeOne(root: Handle, relative: []const u8, existing_ok: bool) Error!void {
    if (relative.len == 0) return error.Denied;
    const handle = beneath(root, relative, .{ .access = attributes_access, .disposition = .CREATE, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } }) catch |err| {
        if (err == error.Failed and existing_ok) {
            // `CREATE` refuses an existing name; a directory there is what was asked for.
            const existing = try beneath(root, relative, .{ .access = attributes_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } });
            close(existing);
            return;
        }
        return err;
    };
    close(handle);
}

/// Removes a file, a link (not what it points to) or an empty directory.
pub fn remove(root: Handle, relative: [:0]const u8) Error!void {
    if (relative.len == 0) return error.Denied;
    const handle = try beneath(root, relative, .{ .access = delete_access, .link_itself = true });
    defer close(handle);
    try deleteOpen(handle);
}

/// Whether something is there. Outside the roots is `Denied`, never `false`.
pub fn exists(root: Handle, relative: [:0]const u8) Error!bool {
    if (relative.len == 0) return true;
    const handle = beneath(root, relative, .{ .access = attributes_access }) catch |err| switch (err) {
        error.Denied => return error.Denied,
        else => return false,
    };
    close(handle);
    return true;
}

/// 100 ns ticks from 1601 to 1970.
const epoch_difference: i64 = 116_444_736_000_000_000;

/// Writes [`stat_bytes`] into `out`.
pub fn stat(root: Handle, relative: [:0]const u8, out: []u8) Error!usize {
    if (out.len < stat_bytes) return error.TooLarge;
    const handle = if (relative.len == 0) root else try beneath(root, relative, .{ .access = attributes_access });
    defer if (relative.len != 0) close(handle);
    var basic: w.FILE.BASIC_INFORMATION = undefined;
    var standard: w.FILE.STANDARD_INFORMATION = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    try check(w.ntdll.NtQueryInformationFile(handle, &io, &basic, @sizeOf(w.FILE.BASIC_INFORMATION), .Basic));
    try check(w.ntdll.NtQueryInformationFile(handle, &io, &standard, @sizeOf(w.FILE.STANDARD_INFORMATION), .Standard));
    out[0] = @intFromEnum(if (standard.Directory.toBool()) Kind.directory else Kind.file);
    std.mem.writeInt(u64, out[1..9], if (standard.Directory.toBool()) 0 else @intCast(standard.EndOfFile), .little);
    std.mem.writeInt(i64, out[9..17], @divTrunc(basic.LastWriteTime - epoch_difference, 10_000), .little);
    return stat_bytes;
}

/// A junction's or symbolic link's tag has this bit: it names another place.
const name_surrogate: u32 = 0x2000_0000;

/// The directory's entries, without `.` and `..`, each `[kind u8][name length u16][name]`.
pub fn readDirectory(root: Handle, relative: [:0]const u8, out: []u8) Error!usize {
    const handle = if (relative.len == 0) root else try beneath(root, relative, .{ .access = list_access, .options = .{ .IO = .SYNCHRONOUS_NONALERT, .DIRECTORY_FILE = true } });
    defer if (relative.len != 0) close(handle);
    var records: [8192]u8 align(8) = undefined;
    var len: usize = 0;
    var restart = true;
    while (true) {
        var io: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtQueryDirectoryFile(handle, null, null, null, &io, &records, records.len, .BothDirectory, .FALSE, null, if (restart) .TRUE else .FALSE);
        restart = false;
        if (@intFromEnum(status) == status_no_more_files) return len;
        try check(status);
        var at: usize = 0;
        while (true) {
            const entry: *align(1) const w.FILE_BOTH_DIR_INFORMATION = @ptrCast(&records[at]);
            const wide = entryName(records[at..], @offsetOf(w.FILE_BOTH_DIR_INFORMATION, "FileName"), entry.FileNameLength);
            if (!isDots(wide)) {
                var name: [name_max * 3]u8 = undefined;
                const name_len = std.unicode.wtf16LeToWtf8(&name, wide);
                if (len + 3 + name_len > out.len) return error.TooLarge;
                // For a reparse point the listing carries its tag where the EA size would be.
                const kind: Kind = if (entry.FileAttributes.REPARSE_POINT and entry.EaSize & name_surrogate != 0)
                    .symlink
                else if (entry.FileAttributes.DIRECTORY) .directory else .file;
                out[len] = @intFromEnum(kind);
                std.mem.writeInt(u16, out[len + 1 ..][0..2], @intCast(name_len), .little);
                @memcpy(out[len + 3 ..][0..name_len], name[0..name_len]);
                len += 3 + name_len;
            }
            if (entry.NextEntryOffset == 0) break;
            at += entry.NextEntryOffset;
        }
    }
}

/// Whether two handles are the same directory: by volume and file id.
pub fn sameDirectory(a: Handle, b: Handle) bool {
    const Id = extern struct { volume: u64, file: [16]u8 };
    var first: Id = undefined;
    var second: Id = undefined;
    var io: w.IO_STATUS_BLOCK = undefined;
    if (w.ntdll.NtQueryInformationFile(a, &io, &first, @sizeOf(Id), Class.id) != .SUCCESS) return false;
    if (w.ntdll.NtQueryInformationFile(b, &io, &second, @sizeOf(Id), Class.id) != .SUCCESS) return false;
    return first.volume == second.volume and std.mem.eql(u8, &first.file, &second.file);
}

// ---------------------------------------------------------------------------------------
// Tests: a real directory tree under %TEMP%, with a junction planted to escape it
// (`mklink /J`, which needs no privilege; a symbolic link does, and takes the same path).

const Tree = struct {
    base: [512]u8 = undefined,
    base_len: usize = 0,

    fn path(tree: *const Tree) []const u8 {
        return tree.base[0..tree.base_len];
    }

    fn make() !Tree {
        var tree: Tree = .{};
        const temp = std.mem.span(std.c.getenv("TEMP") orelse return error.NoTemp);
        const written = try std.fmt.bufPrint(&tree.base, "{s}\\lepton-fs-test-{d}", .{ temp, w.GetCurrentProcessId() });
        tree.base_len = written.len;
        tree.remove();
        var buffer: [600]u8 = undefined;
        const root_fd = try openRoot(.{ .path = try tree.at(&buffer, "root\\sub"), .create = true });
        close(root_fd);
        const outside_fd = try openRoot(.{ .path = try tree.at(&buffer, "outside"), .create = true });
        defer close(outside_fd);
        try writeFile(outside_fd, "secret.txt", "secret\n", false);
        const base_fd = try openRoot(.{ .path = tree.path() });
        defer close(base_fd);
        try writeFile(base_fd, "root/sub/in.txt", "inside\n", false);
        try tree.junction("root\\escape", "outside");
        try tree.junction("root\\inlink", "root\\sub");
        return tree;
    }

    fn at(tree: *const Tree, buffer: []u8, tail: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ tree.path(), tail });
    }

    fn junction(tree: *const Tree, link: []const u8, target: []const u8) !void {
        var link_buffer: [600]u8 = undefined;
        var target_buffer: [600]u8 = undefined;
        try run(&.{ "cmd", "/c", "mklink", "/J", try tree.at(&link_buffer, link), try tree.at(&target_buffer, target) });
    }

    fn remove(tree: *const Tree) void {
        // `rmdir /s` removes a junction as a link, never what it points to.
        run(&.{ "cmd", "/c", "if", "exist", tree.path(), "rmdir", "/s", "/q", tree.path() }) catch {};
    }

    fn root(tree: *const Tree, buffer: []u8, tail: []const u8, create: bool) !Root {
        return .{ .path = try tree.at(buffer, tail), .create = create };
    }
};

fn run(argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

test "junctions that leave the root are refused by the kernel, and removed as links" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [600]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer close(root_fd);
    var out: [64]u8 = undefined;

    try std.testing.expectEqualStrings("inside\n", out[0..try readFile(root_fd, "sub/in.txt", &out)]);
    try std.testing.expectEqualStrings("inside\n", out[0..try readFile(root_fd, "SUB/IN.TXT", &out)]);
    try std.testing.expectError(error.Denied, readFile(root_fd, "escape/secret.txt", &out));
    try std.testing.expectError(error.Denied, writeFile(root_fd, "escape/planted.txt", "x", false));
    try std.testing.expectError(error.Denied, exists(root_fd, "escape/secret.txt"));
    try std.testing.expectError(error.Denied, stat(root_fd, "escape", &out));
    try std.testing.expectError(error.Denied, readDirectory(root_fd, "escape", &out));
    try std.testing.expectError(error.Denied, makeDirectory(root_fd, "escape/new", false));
    try std.testing.expectError(error.Denied, readFile(root_fd, "../outside/secret.txt", &out));
    // Stricter than Linux: a junction that stays inside the root is refused too.
    try std.testing.expectError(error.Denied, readFile(root_fd, "inlink/in.txt", &out));
    try std.testing.expectError(error.Failed, readFile(root_fd, "missing.txt", &out));
    // Listed as a link; removing it removes the link, never what it points to.
    var listing: [256]u8 = undefined;
    const listed = listing[0..try readDirectory(root_fd, "", &listing)];
    try std.testing.expect(std.mem.indexOf(u8, listed, "\x03\x06\x00escape") != null);
    try remove(root_fd, "escape");
    try std.testing.expect(!try exists(root_fd, "escape"));
    var check_buffer: [600]u8 = undefined;
    const outside_fd = try openRoot(try tree.root(&check_buffer, "outside", false));
    defer close(outside_fd);
    try std.testing.expect(try exists(outside_fd, "secret.txt"));
}

test "write, read, append, list, stat, make and remove inside a root" {
    const tree = try Tree.make();
    defer tree.remove();
    var root_buffer: [600]u8 = undefined;
    // An application's own directory does not exist yet; it is made on first use.
    const root_fd = try openRoot(try tree.root(&root_buffer, "app\\data", true));
    defer close(root_fd);

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
    var root_buffer: [600]u8 = undefined;
    const root_fd = try openRoot(try tree.root(&root_buffer, "root", false));
    defer close(root_fd);

    var piece: [65_536]u8 = undefined;
    for (&piece, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);
    try writeFile(root_fd, "big.md", "old", false);
    var written: usize = 0;
    while (written < 200_000) {
        const size = @min(piece.len, 200_000 - written);
        try writeFile(root_fd, "big.md.lepton-save", piece[0..size], written != 0);
        written += size;
    }
    try rename(root_fd, "big.md.lepton-save", "big.md");
    try std.testing.expect(!try exists(root_fd, "big.md.lepton-save"));
    var out: [65_536]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const got = try readRange(root_fd, "big.md", total, &out);
        if (got == 0) break;
        try std.testing.expectEqual(@as(u8, @intCast('a' + (total % piece.len) % 26)), out[0]);
        total += got;
        if (got < out.len) break;
    }
    try std.testing.expectEqual(@as(usize, 200_000), total);

    // Renaming out of the root, or through a link that leaves it, is refused.
    try std.testing.expectError(error.Denied, rename(root_fd, "big.md", "escape/taken.md"));
    try std.testing.expectError(error.Denied, rename(root_fd, "../outside/secret.txt", "stolen.txt"));
    // Into a folder below the root, and back.
    try rename(root_fd, "big.md", "sub/big.md");
    try std.testing.expect(try exists(root_fd, "sub/big.md"));

    // A folder of notes with a junction out of the root inside it: the folder goes, the
    // junction goes, what it pointed to stays.
    try makeDirectory(root_fd, "vault/daily/2026", true);
    try writeFile(root_fd, "vault/daily/2026/10-16.md", "bugün", false);
    try writeFile(root_fd, "vault/index.md", "# Kasa", false);
    try tree.junction("root\\vault\\out", "outside");
    try removeTree(root_fd, "vault");
    try std.testing.expect(!try exists(root_fd, "vault"));
    var check_buffer: [600]u8 = undefined;
    const outside_fd = try openRoot(try tree.root(&check_buffer, "outside", false));
    defer close(outside_fd);
    try std.testing.expect(try exists(outside_fd, "secret.txt"));
    try std.testing.expectError(error.Denied, removeTree(root_fd, ""));
    try std.testing.expectError(error.Denied, removeTree(root_fd, "escape/secret.txt"));

    // The same root opened twice is the same directory; another is not.
    const again = try openRoot(try tree.root(&root_buffer, "root", false));
    defer close(again);
    try std.testing.expect(sameDirectory(root_fd, again));
    try std.testing.expect(!sameDirectory(root_fd, outside_fd));
}
