//! The user's base directories — `$APPDATA`, `$DOCUMENT`, … — as the XDG specifications
//! place them, for plugins that are given a directory rather than a path.
//!
//! One trap is specific to this framework: the webview build sets `XDG_DATA_HOME` to
//! `<data home>/lepton` for the engine (`View.setDataDirectory`), because WebKit offers no
//! other handle on its storage. After that the environment no longer says where the
//! user's data lives, so [`rememberDataHome`] keeps the value from before the change and
//! the data directory is computed from that.
//!
//! The user directories (`$DOCUMENT`, `$DOWNLOAD`, …) come from `user-dirs.dirs`, written
//! by `xdg-user-dirs-update`: they are localised (`~/Belgeler`), so a guessed `~/Documents`
//! would be a different directory on this very machine.

const std = @import("std");
const compat = @import("../../compat.zig");
const linux = std.os.linux;

/// The directories a page may name instead of a path.
pub const Base = enum(u8) {
    /// No base: the path is absolute.
    none = 0,
    /// `$XDG_DATA_HOME/<identifier>`
    app_data = 1,
    /// `$XDG_CONFIG_HOME/<identifier>`
    app_config = 2,
    /// `$XDG_CACHE_HOME/<identifier>`
    app_cache = 3,
    home = 4,
    document = 5,
    download = 6,
    desktop = 7,
    picture = 8,
    music = 9,
    video = 10,

    /// The `$NAME` an application's configuration uses for it.
    pub fn variable(base: Base) []const u8 {
        return switch (base) {
            .none => "",
            .app_data => "$APPDATA",
            .app_config => "$APPCONFIG",
            .app_cache => "$APPCACHE",
            .home => "$HOME",
            .document => "$DOCUMENT",
            .download => "$DOWNLOAD",
            .desktop => "$DESKTOP",
            .picture => "$PICTURE",
            .music => "$MUSIC",
            .video => "$VIDEO",
        };
    }

    pub fn fromVariable(name: []const u8) ?Base {
        inline for (comptime compat.enumValues(Base)) |value| {
            const base: Base = @enumFromInt(value);
            if (base != .none and std.mem.eql(u8, name, base.variable())) return base;
        }
        return null;
    }

    /// Whether the directory belongs to this application, and may be created on demand.
    pub fn isOwn(base: Base) bool {
        return base == .app_data or base == .app_config or base == .app_cache;
    }

    /// The `user-dirs.dirs` key, for the user directories.
    fn userDirKey(base: Base) ?[]const u8 {
        return switch (base) {
            .document => "XDG_DOCUMENTS_DIR",
            .download => "XDG_DOWNLOAD_DIR",
            .desktop => "XDG_DESKTOP_DIR",
            .picture => "XDG_PICTURES_DIR",
            .music => "XDG_MUSIC_DIR",
            .video => "XDG_VIDEOS_DIR",
            else => null,
        };
    }
};

pub const Error = error{
    /// The environment does not say where it is: no `HOME`, or no `user-dirs.dirs` entry.
    Unavailable,
    TooLong,
};

/// Where the inputs come from: the process in [`resolve`], fixed values in the tests.
pub const Sources = struct {
    home: ?[]const u8,
    data_home: ?[]const u8,
    config_home: ?[]const u8,
    cache_home: ?[]const u8,
    /// The contents of `<config home>/user-dirs.dirs`, if there is one.
    user_dirs: ?[]const u8,
};

var remembered_buffer: [std.fs.max_path_bytes]u8 = undefined;
var remembered: ?[]const u8 = null;
var remembered_once = false;

/// Keeps `XDG_DATA_HOME` as it was before this process changes it. Call before every
/// `setenv("XDG_DATA_HOME", …)`; only the first call records anything.
pub fn rememberDataHome() void {
    if (remembered_once) return;
    remembered_once = true;
    const value = std.mem.span(std.c.getenv("XDG_DATA_HOME") orelse return);
    if (value.len > remembered_buffer.len) return;
    @memcpy(remembered_buffer[0..value.len], value);
    remembered = remembered_buffer[0..value.len];
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

/// The directory `base` names for the application `identifier`, written into `out`.
/// `scratch` holds `user-dirs.dirs` while it is read.
pub fn resolve(base: Base, identifier: []const u8, out: []u8, scratch: []u8) Error![]const u8 {
    var config_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var sources: Sources = .{
        .home = env("HOME"),
        .data_home = if (remembered_once) remembered else env("XDG_DATA_HOME"),
        .config_home = env("XDG_CONFIG_HOME"),
        .cache_home = env("XDG_CACHE_HOME"),
        .user_dirs = null,
    };
    if (base.userDirKey() != null) {
        const config = try xdgHome(sources.config_home, sources.home, ".config", &config_buffer);
        const suffix = "/user-dirs.dirs";
        if (config.len + suffix.len + 1 > config_buffer.len) return error.TooLong;
        @memcpy(config_buffer[config.len..][0..suffix.len], suffix);
        config_buffer[config.len + suffix.len] = 0;
        sources.user_dirs = readSmall(config_buffer[0 .. config.len + suffix.len :0], scratch);
    }
    return resolveFrom(base, identifier, sources, out);
}

/// [`resolve`] over given inputs.
pub fn resolveFrom(base: Base, identifier: []const u8, sources: Sources, out: []u8) Error![]const u8 {
    const home = sources.home orelse return error.Unavailable;
    if (home.len == 0 or home[0] != '/') return error.Unavailable;
    switch (base) {
        .none => return error.Unavailable,
        .home => return copy(home, out),
        .app_data, .app_config, .app_cache => {
            if (!usableIdentifier(identifier)) return error.Unavailable;
            const parent = switch (base) {
                .app_data => try xdgHome(sources.data_home, home, ".local/share", out),
                .app_config => try xdgHome(sources.config_home, home, ".config", out),
                else => try xdgHome(sources.cache_home, home, ".cache", out),
            };
            return join(out, parent.len, identifier);
        },
        else => {
            const key = base.userDirKey() orelse return error.Unavailable;
            const value = userDir(sources.user_dirs orelse return error.Unavailable, key) orelse return error.Unavailable;
            if (std.mem.startsWith(u8, value, "$HOME/")) {
                const at = try copy(home, out);
                return join(out, at.len, value["$HOME/".len..]);
            }
            if (std.mem.eql(u8, value, "$HOME")) return copy(home, out);
            if (value.len == 0 or value[0] != '/') return error.Unavailable;
            return copy(value, out);
        },
    }
}

/// An identifier that names one directory: not empty, no `/`, and not `.` or `..`, which
/// would make `$APPDATA` the parent of every application's data (`~/.local`).
fn usableIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or std.mem.indexOfScalar(u8, identifier, '/') != null) return false;
    return !std.mem.eql(u8, identifier, ".") and !std.mem.eql(u8, identifier, "..");
}

/// The application's own state, `$XDG_STATE_HOME/<identifier>` (`~/.local/state/…`):
/// where the core keeps what a page must never write, such as the dialog grants
/// (`platform/grants.zig`). No `fs` base names it, so no scope short of `$HOME` reaches
/// it — and a page with `$HOME` in scope can already write everything under it.
pub fn stateDirectory(identifier: []const u8, out: []u8) Error![]const u8 {
    return stateFrom(identifier, env("HOME"), env("XDG_STATE_HOME"), out);
}

fn stateFrom(identifier: []const u8, home: ?[]const u8, state_home: ?[]const u8, out: []u8) Error![]const u8 {
    const own_home = home orelse return error.Unavailable;
    if (own_home.len == 0 or own_home[0] != '/') return error.Unavailable;
    if (!usableIdentifier(identifier)) return error.Unavailable;
    const parent = try xdgHome(state_home, own_home, ".local/state", out);
    return join(out, parent.len, identifier);
}

/// `$XDG_*_HOME` when it is set to an absolute path (the specification says to ignore a
/// relative one), else `<home>/<fallback>`.
fn xdgHome(value: ?[]const u8, home: ?[]const u8, fallback: []const u8, out: []u8) Error![]const u8 {
    if (value) |set| {
        if (set.len > 0 and set[0] == '/') return copy(set, out);
    }
    const at = try copy(home orelse return error.Unavailable, out);
    return join(out, at.len, fallback);
}

/// Creates `path` and any missing parents with mode 0700, as the XDG Base Directory
/// specification asks for directories it creates. Existing directories keep the mode
/// they have — the user may have chosen it. Returns false when one cannot be made.
pub fn makePrivate(path: [:0]const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 1 > buffer.len) return false;
    @memcpy(buffer[0 .. path.len + 1], path[0 .. path.len + 1]);
    var at: usize = 1;
    while (at <= path.len) : (at += 1) {
        if (at != path.len and buffer[at] != '/') continue;
        const saved = buffer[at];
        buffer[at] = 0;
        const made = linux.mkdirat(linux.AT.FDCWD, buffer[0..at :0], 0o700);
        buffer[at] = saved;
        switch (linux.errno(made)) {
            .SUCCESS, .EXIST => {},
            else => return false,
        }
    }
    return true;
}

/// The value of `KEY="..."` in a `user-dirs.dirs` text; `#` lines are comments.
pub fn userDir(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key) or line.len < key.len + 3) continue;
        if (line[key.len] != '=') continue;
        const value = line[key.len + 1 ..];
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
        return value[1 .. value.len - 1];
    }
    return null;
}

fn copy(text: []const u8, out: []u8) Error![]const u8 {
    if (text.len > out.len) return error.TooLong;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// `out[0..len] ++ "/" ++ tail`, without a doubled separator.
fn join(out: []u8, len: usize, tail: []const u8) Error![]const u8 {
    var at = len;
    while (at > 1 and out[at - 1] == '/') at -= 1;
    if (at + 1 + tail.len > out.len) return error.TooLong;
    out[at] = '/';
    @memcpy(out[at + 1 ..][0..tail.len], tail);
    return out[0 .. at + 1 + tail.len];
}

/// Reads a small file into `buffer`; null when it cannot be read or does not fit.
fn readSmall(path: [*:0]const u8, buffer: []u8) ?[]const u8 {
    const opened = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    var len: usize = 0;
    while (len < buffer.len) {
        const got = linux.read(fd, buffer[len..].ptr, buffer.len - len);
        if (linux.errno(got) != .SUCCESS) return null;
        if (got == 0) return buffer[0..len];
        len += got;
    }
    return null;
}

const sample_user_dirs =
    \\# This file is written by xdg-user-dirs-update
    \\XDG_DESKTOP_DIR="$HOME/Masaüstü"
    \\XDG_DOCUMENTS_DIR="$HOME/Belgeler"
    \\XDG_MUSIC_DIR="/srv/music"
    \\XDG_VIDEOS_DIR="$HOME"
    \\
;

test "application directories follow XDG, with the specification's fallbacks" {
    var out: [256]u8 = undefined;
    const set: Sources = .{ .home = "/home/u", .data_home = "/data", .config_home = "/conf/", .cache_home = null, .user_dirs = null };
    try std.testing.expectEqualStrings("/data/style.app", try resolveFrom(.app_data, "style.app", set, &out));
    try std.testing.expectEqualStrings("/conf/style.app", try resolveFrom(.app_config, "style.app", set, &out));
    try std.testing.expectEqualStrings("/home/u/.cache/style.app", try resolveFrom(.app_cache, "style.app", set, &out));
    // A relative XDG value is ignored, as the specification says.
    const relative: Sources = .{ .home = "/home/u", .data_home = "data", .config_home = null, .cache_home = null, .user_dirs = null };
    try std.testing.expectEqualStrings("/home/u/.local/share/style.app", try resolveFrom(.app_data, "style.app", relative, &out));
    try std.testing.expectEqualStrings("/home/u", try resolveFrom(.home, "style.app", relative, &out));
    // No home, or an identifier that would leave the directory: no answer.
    const homeless: Sources = .{ .home = null, .data_home = "/data", .config_home = null, .cache_home = null, .user_dirs = null };
    try std.testing.expectError(error.Unavailable, resolveFrom(.app_data, "style.app", homeless, &out));
    try std.testing.expectError(error.Unavailable, resolveFrom(.app_data, "../x", set, &out));
    try std.testing.expectError(error.Unavailable, resolveFrom(.app_data, "..", set, &out));
    try std.testing.expectError(error.Unavailable, resolveFrom(.app_config, ".", set, &out));
    try std.testing.expectError(error.Unavailable, resolveFrom(.app_data, "", set, &out));
}

test "user directories come from user-dirs.dirs, localised" {
    var out: [256]u8 = undefined;
    const sources: Sources = .{ .home = "/home/u", .data_home = null, .config_home = null, .cache_home = null, .user_dirs = sample_user_dirs };
    try std.testing.expectEqualStrings("/home/u/Belgeler", try resolveFrom(.document, "a", sources, &out));
    try std.testing.expectEqualStrings("/home/u/Masaüstü", try resolveFrom(.desktop, "a", sources, &out));
    try std.testing.expectEqualStrings("/srv/music", try resolveFrom(.music, "a", sources, &out));
    try std.testing.expectEqualStrings("/home/u", try resolveFrom(.video, "a", sources, &out));
    try std.testing.expectError(error.Unavailable, resolveFrom(.download, "a", sources, &out));
    const none: Sources = .{ .home = "/home/u", .data_home = null, .config_home = null, .cache_home = null, .user_dirs = null };
    try std.testing.expectError(error.Unavailable, resolveFrom(.document, "a", none, &out));
}

test "configuration names map to bases and back" {
    try std.testing.expectEqual(Base.app_data, Base.fromVariable("$APPDATA").?);
    try std.testing.expectEqual(Base.document, Base.fromVariable("$DOCUMENT").?);
    try std.testing.expect(Base.fromVariable("$NOPE") == null);
    try std.testing.expect(Base.fromVariable("") == null);
    try std.testing.expect(Base.app_cache.isOwn() and !Base.home.isOwn());
}

test "this machine's own directories resolve" {
    // This machine's XDG directories; the Windows half has its own (`windows/paths.zig`).
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const home = try resolve(.home, "style.lepton.test", &out, &scratch);
    try std.testing.expect(home.len > 1 and home[0] == '/');
    const data = try resolve(.app_data, "style.lepton.test", &out, &scratch);
    try std.testing.expect(std.mem.endsWith(u8, data, "/style.lepton.test"));
}

test "missing directories are made 0700, existing ones keep their mode" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var name: [96]u8 = undefined;
    const base = try std.fmt.bufPrintSentinel(&name, "/tmp/lepton-paths-test-{d}", .{linux.getpid()}, 0);
    var deep: [160]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&deep, "{s}/a/b", .{base}, 0);
    try std.testing.expect(makePrivate(target));
    var info: linux.Statx = undefined;
    for ([_][:0]const u8{ base, target }) |path| {
        _ = linux.statx(linux.AT.FDCWD, path, 0, .{ .MODE = true }, &info);
        try std.testing.expectEqual(@as(u16, 0o700), info.mode & 0o777);
    }
    _ = linux.fchmodat(linux.AT.FDCWD, target, 0o755);
    try std.testing.expect(makePrivate(target));
    _ = linux.statx(linux.AT.FDCWD, target, 0, .{ .MODE = true }, &info);
    try std.testing.expectEqual(@as(u16, 0o755), info.mode & 0o777);
    try std.testing.expect(!makePrivate("relative/path"));
    var middle: [128]u8 = undefined;
    _ = linux.unlinkat(linux.AT.FDCWD, target, linux.AT.REMOVEDIR);
    _ = linux.unlinkat(linux.AT.FDCWD, try std.fmt.bufPrintSentinel(&middle, "{s}/a", .{base}, 0), linux.AT.REMOVEDIR);
    _ = linux.unlinkat(linux.AT.FDCWD, base, linux.AT.REMOVEDIR);
}

test "the state directory is outside every fs base" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/.local/state/style.app", try stateFrom("style.app", "/home/u", null, &out));
    try std.testing.expectEqualStrings("/state/style.app", try stateFrom("style.app", "/home/u", "/state", &out));
    // A relative XDG_STATE_HOME is ignored, as the specification says.
    try std.testing.expectEqualStrings("/home/u/.local/state/style.app", try stateFrom("style.app", "/home/u", "rel", &out));
    try std.testing.expectError(error.Unavailable, stateFrom("..", "/home/u", null, &out));
    try std.testing.expectError(error.Unavailable, stateFrom("a/b", "/home/u", null, &out));
    try std.testing.expectError(error.Unavailable, stateFrom("style.app", null, null, &out));
}
