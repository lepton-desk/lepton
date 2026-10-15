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
};

/// `flags` bits.
pub const Flag = struct {
    /// `fs.write_file`: add to the end instead of replacing.
    pub const append: u8 = 1;
    /// `fs.mkdir`: make missing parents; an existing directory is fine.
    pub const recursive: u8 = 1;
};

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
    root_fd: i32,
    relative: [:0]const u8,
    relative_buffer: [std.fs.max_path_bytes]u8,

    fn close(target: *const Target) void {
        _ = std.os.linux.close(target.root_fd);
    }
};

fn open(request: Request, target: *Target) Registry.HandlerError!void {
    var scratch: [4096]u8 = undefined;
    var absolute_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = switch (request.base) {
        .none => request.path,
        else => blk: {
            if (request.path.len > 0 and request.path[0] == '/') return error.Failed;
            const dir = core.paths.resolve(request.base, identifier, &absolute_buffer, &scratch) catch |err| return mapPaths(err);
            if (request.path.len == 0) break :blk dir;
            if (dir.len + 1 + request.path.len > absolute_buffer.len) return error.TooLarge;
            absolute_buffer[dir.len] = '/';
            @memcpy(absolute_buffer[dir.len + 1 ..][0..request.path.len], request.path);
            break :blk absolute_buffer[0 .. dir.len + 1 + request.path.len];
        },
    };
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    inline for (scope) |entry| {
        if (rootOf(entry, &root_buffer, &scratch)) |root| {
            if (fs.locate(&.{root}, absolute, &target.relative_buffer)) |located| {
                target.relative = located.relative;
                target.root_fd = fs.openRoot(located.root) catch |err| return mapFs(err);
                return;
            } else |_| {}
        } else |_| {}
    }
    return error.Denied;
}

fn rootOf(comptime entry: Entry, buffer: []u8, scratch: []u8) core.paths.Error!fs.Root {
    const dir = try core.paths.resolve(entry.base, identifier, buffer, scratch);
    if (entry.below.len == 0) return .{ .path = dir, .create = entry.base.isOwn() };
    if (dir.len + 1 + entry.below.len > buffer.len) return error.TooLong;
    buffer[dir.len] = '/';
    @memcpy(buffer[dir.len + 1 ..][0..entry.below.len], entry.below);
    return .{ .path = buffer[0 .. dir.len + 1 + entry.below.len], .create = entry.base.isOwn() };
}

fn readFile(argument: []const u8, out: []u8) Registry.HandlerError!usize {
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
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
    var target: Target = undefined;
    try open(try parse(argument), &target);
    defer target.close();
    fs.remove(target.root_fd, target.relative) catch |err| return mapFs(err);
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
