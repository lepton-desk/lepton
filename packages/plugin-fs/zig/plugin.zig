//! `@lepton-desk/plugin-fs`, the core side: files inside the directories the application
//! allowed in `lepton.config.json` → `"plugins": { "fs": { "scope": [...] } }`.
//!
//! Each scope entry is a base directory, optionally followed by a path below it:
//! `"$APPDATA"`, `"$DOCUMENT/notes"`. No wildcards, no `..`, no absolute paths — checked
//! here at compile time, so a mistyped scope is a build error rather than a directory that
//! silently stays closed. With no scope every path is `denied`.
//!
//! Every command's argument starts with the same header:
//! `[base u8][flags u8][path length u16 LE][path UTF-8]`, then the command's body. `base`
//! is `core.paths.Base` (0: the path is absolute); otherwise the path is relative to it.

const std = @import("std");
const core = @import("lepton_core");
const fs = @import("fs.zig");

const Registry = core.webviewRegistry;
const Base = core.paths.Base;
const config = @import("lepton_plugin_config").text;

pub const commands = [_]Registry.PluginCommand{
    .{ .name = "fs.read_file", .run = &readFile },
    .{ .name = "fs.write_file", .run = &writeFile },
    .{ .name = "fs.read_dir", .run = &readDir },
    .{ .name = "fs.mkdir", .run = &mkdir },
    .{ .name = "fs.remove", .run = &remove },
    .{ .name = "fs.stat", .run = &stat },
    .{ .name = "fs.exists", .run = &exists },
    .{ .name = "fs.rename", .run = &rename },
    .{ .name = "fs.watch", .run = &watchPath },
    .{ .name = "fs.unwatch", .run = &unwatchPath },
};

/// What a watch reports: `u32` watch number (LE), one `fs.Change` byte, then the name of
/// the entry that changed (empty for the watched path itself).
pub const events = .{"fs.changed"};

/// Paths and file contents are the user's own: a recording keeps their sizes, not their bytes.
pub const private = .{ "fs.read_file", "fs.write_file", "fs.read_dir", "fs.mkdir", "fs.remove", "fs.stat", "fs.exists", "fs.rename", "fs.watch", "fs.unwatch" };

/// `flags` bits.
pub const Flag = struct {
    /// `fs.write_file`: add to the end instead of replacing.
    pub const append: u8 = 1;
    /// `fs.mkdir`: make missing parents; an existing directory is fine. `fs.remove`: a
    /// directory with everything in it.
    pub const recursive: u8 = 1;
    /// `fs.read_file`: the body is a `u64` offset (LE); the reply is as much of the file
    /// from there as fits one reply — how a file larger than that is read.
    pub const ranged: u8 = 2;
};

/// `"plugins": { "fs": { "chosen": true } }`: what the user picks in a file dialog
/// (`@lepton-desk/plugin-dialog`) joins the scope and is remembered (`core.grants`).
const chosen = std.mem.eql(u8, core.pluginConfig.value(config, "fs.chosen") orelse "false", "true");

comptime {
    if (chosen and !@hasDecl(core, "grants")) @compileError("fs chosen: this project's core predates chosen paths; recreate it with a current `lepton new`");
}

const Entry = struct { base: Base, below: []const u8 };

const identifier: []const u8 = core.pluginConfig.value(config, "app.identifier") orelse "";

/// The scope, parsed and checked at compile time.
const scope: []const Entry = blk: {
    var entries: []const Entry = &.{};
    for (core.pluginConfig.values(config, "fs.scope")) |text| entries = entries ++ .{parseEntry(text)};
    break :blk entries;
};

fn parseEntry(comptime text: []const u8) Entry {
    const refuse = "fs scope \"" ++ text ++ "\": ";
    if (text.len == 0 or text[0] != '$') @compileError(refuse ++ "must start with a base directory such as $APPDATA or $DOCUMENT");
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse text.len;
    const base = Base.fromVariable(text[0..slash]) orelse
        @compileError(refuse ++ "unknown base directory; use $APPDATA $APPCONFIG $APPCACHE $HOME $DOCUMENT $DOWNLOAD $DESKTOP $PICTURE $MUSIC $VIDEO");
    const below = if (slash == text.len) "" else text[slash + 1 ..];
    if (std.mem.indexOfAny(u8, text, "*?[")) |_| @compileError(refuse ++ "wildcards are not allowed; name the directory");
    if (slash != text.len) {
        var words = std.mem.splitScalar(u8, below, '/');
        while (words.next()) |word| {
            if (word.len == 0 or std.mem.eql(u8, word, ".") or std.mem.eql(u8, word, ".."))
                @compileError(refuse ++ "the path below the base must be plain names, without \"..\", \".\" or empty parts");
        }
    }
    if (base.isOwn() and identifier.len == 0) @compileError(refuse ++ "needs the application's identifier (app.identifier), which lepton passes");
    return .{ .base = base, .below = below };
}

const Request = struct {
    base: Base,
    flags: u8,
    path: []const u8,
    body: []const u8,
};

fn parse(argument: []const u8) Registry.HandlerError!Request {
    if (argument.len < 4) return error.Failed;
    const base = std.enums.fromInt(Base, argument[0]) orelse return error.Failed;
    const path_len = std.mem.readInt(u16, argument[2..4], .little);
    if (argument.len < 4 + path_len) return error.Failed;
    const path = argument[4..][0..path_len];
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.Failed;
    return .{ .base = base, .flags = argument[1], .path = path, .body = argument[4 + path_len ..] };
}

fn mapPaths(err: core.paths.Error) Registry.HandlerError {
    return switch (err) {
        error.Unavailable => error.Failed,
        error.TooLong => error.TooLarge,
    };
}

fn mapFs(err: fs.Error) Registry.HandlerError {
    return switch (err) {
        error.Denied => error.Denied,
        error.Failed => error.Failed,
        error.TooLarge => error.TooLarge,
    };
}

/// An open root and the path below it, for one request.
const Target = struct {
    root_fd: fs.Handle,
    relative: [:0]const u8,
    relative_buffer: [path_max]u8,

    fn close(target: *const Target) void {
        fs.close(target.root_fd);
    }
};

/// The longest absolute path handled. Not `std.fs.max_path_bytes`: on Windows that is
/// 96 KiB, and a request holds several such buffers on the stack.
const path_max = 4096;
const windows = @import("builtin").os.tag == .windows;
/// What joins a base directory and the path below it.
const separator = if (windows) '\\' else '/';

fn open(request: Request, target: *Target) Registry.HandlerError!void {
    var scratch: [4096]u8 = undefined;
    var absolute_buffer: [path_max]u8 = undefined;
    const absolute = switch (request.base) {
        .none => request.path,
        else => blk: {
            // Below the base: not absolute (`/…`, on Windows also `\…`). A colon on Windows
            // (`C:\…`, `notes.md:hidden`) is left to `fs.locate`, which denies it.
            if (request.path.len > 0 and (request.path[0] == '/' or (windows and request.path[0] == '\\'))) return error.Failed;
            const dir = core.paths.resolve(request.base, identifier, &absolute_buffer, &scratch) catch |err| return mapPaths(err);
            if (request.path.len == 0) break :blk dir;
            if (dir.len + 1 + request.path.len > absolute_buffer.len) return error.TooLarge;
            absolute_buffer[dir.len] = separator;
            @memcpy(absolute_buffer[dir.len + 1 ..][0..request.path.len], request.path);
            break :blk absolute_buffer[0 .. dir.len + 1 + request.path.len];
        },
    };
    var root_buffer: [path_max]u8 = undefined;
    inline for (scope) |entry| {
        if (rootOf(entry, &root_buffer, &scratch)) |root| {
            if (fs.locate(&.{root}, absolute, &target.relative_buffer)) |located| {
                target.relative = located.relative;
                target.root_fd = fs.openRoot(located.root) catch |err| return mapFs(err);
                return;
            } else |_| {}
        } else |_| {}
    }
    if (comptime chosen) {
        const grant = core.grants.covering(identifier, absolute) orelse return error.Denied;
        // A chosen file: its folder is the root, and only the file itself is reachable.
        const root_path = switch (grant.kind) {
            .directory => grant.path,
            .file => std.fs.path.dirname(grant.path) orelse return error.Denied,
        };
        const located = fs.locate(&.{.{ .path = root_path }}, absolute, &target.relative_buffer) catch |err| return mapFs(err);
        if (grant.kind == .file and !std.mem.eql(u8, located.relative, std.fs.path.basename(grant.path))) return error.Denied;
        target.relative = located.relative;
        target.root_fd = fs.openRoot(located.root) catch |err| return mapFs(err);
        return;
    }
    return error.Denied;
}

fn rootOf(comptime entry: Entry, buffer: []u8, scratch: []u8) core.paths.Error!fs.Root {
    const dir = try core.paths.resolve(entry.base, identifier, buffer, scratch);
    if (entry.below.len == 0) return .{ .path = dir, .create = entry.base.isOwn() };
    if (dir.len + 1 + entry.below.len > buffer.len) return error.TooLong;
    buffer[dir.len] = separator;
    @memcpy(buffer[dir.len + 1 ..][0..entry.below.len], entry.below);
    return .{ .path = buffer[0 .. dir.len + 1 + entry.below.len], .create = entry.base.isOwn() };
}

fn readFile(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    const request = try parse(argument);
    var target: Target = undefined;
    try open(request, &target);
    defer target.close();
    if (request.flags & Flag.ranged != 0) {
        if (request.body.len != 8) return error.Failed;
        const offset = std.mem.readInt(u64, request.body[0..8], .little);
        return fs.readRange(target.root_fd, target.relative, offset, out) catch |err| mapFs(err);
    }
    return fs.readFile(target.root_fd, target.relative, out) catch |err| mapFs(err);
}

fn writeFile(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    const request = try parse(argument);
    var target: Target = undefined;
    try open(request, &target);
    defer target.close();
    fs.writeFile(target.root_fd, target.relative, request.body, request.flags & Flag.append != 0) catch |err| return mapFs(err);
    return 0;
}

fn readDir(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
    return fs.readDirectory(target.root_fd, target.relative, out) catch |err| mapFs(err);
}

fn mkdir(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    const request = try parse(argument);
    var target: Target = undefined;
    try open(request, &target);
    defer target.close();
    fs.makeDirectory(target.root_fd, target.relative, request.flags & Flag.recursive != 0) catch |err| return mapFs(err);
    return 0;
}

fn remove(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    const request = try parse(argument);
    var target: Target = undefined;
    try open(request, &target);
    defer target.close();
    if (request.flags & Flag.recursive != 0) {
        fs.removeTree(target.root_fd, target.relative) catch |err| return mapFs(err);
    } else {
        fs.remove(target.root_fd, target.relative) catch |err| return mapFs(err);
    }
    return 0;
}

/// `fs.rename`: the body is the new path, with the same base. Both must be in one scope
/// directory: a move between two is a copy and a removal, which the page can do itself.
fn rename(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    const request = try parse(argument);
    if (request.body.len == 0 or std.mem.indexOfScalar(u8, request.body, 0) != null) return error.Failed;
    var from: Target = undefined;
    try open(request, &from);
    defer from.close();
    var to: Target = undefined;
    try open(.{ .base = request.base, .flags = 0, .path = request.body, .body = &.{} }, &to);
    defer to.close();
    // Same root: the same directory opened twice compares equal (device and inode; on
    // Windows volume and file id).
    if (!fs.sameDirectory(from.root_fd, to.root_fd)) return error.Denied;
    fs.rename(from.root_fd, from.relative, to.relative) catch |err| return mapFs(err);
    return 0;
}

fn stat(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
    return fs.stat(target.root_fd, target.relative, out) catch |err| mapFs(err);
}

fn exists(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    if (out.len < 1) return error.TooLarge;
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
    out[0] = @intFromBool(fs.exists(target.root_fd, target.relative) catch |err| return mapFs(err));
    return 1;
}

/// `fs.watch`: the usual path request; answers the watch's `u32` number (LE). Changes
/// arrive as `fs.changed` events, read on every turn of the loop (`tick`). Linux only for
/// now: Windows answers `failed`.
fn watchPath(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    if (out.len < 4) return error.TooLarge;
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
    const number = fs.watch(target.root_fd, target.relative) catch |err| return mapFs(err);
    std.mem.writeInt(u32, out[0..4], number, .little);
    return 4;
}

/// `fs.unwatch`: a `u32` watch number (LE).
fn unwatchPath(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    if (argument.len != 4) return error.Failed;
    fs.unwatch(std.mem.readInt(u32, argument[0..4], .little));
    return 0;
}

/// Called by the application's loop on every turn: emits the changes waiting.
pub fn tick(bridge: anytype) void {
    fs.drainWatch(bridge, struct {
        fn report(target: @TypeOf(bridge), number: u32, change: fs.Change, name: []const u8) void {
            var data: [core.webviewEvents.max_data]u8 = undefined;
            std.mem.writeInt(u32, data[0..4], number, .little);
            data[4] = @intFromEnum(change);
            const kept = @min(name.len, data.len - 5);
            @memcpy(data[5..][0..kept], name[0..kept]);
            _ = target.emit("fs.changed", data[0 .. 5 + kept]) catch {};
        }
    }.report);
}
