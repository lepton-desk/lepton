//! The user's base directories — `$APPDATA`, `$DOCUMENT`, … — as Windows places them, for
//! plugins that are given a directory rather than a path. The Linux half is
//! `platform/linux/paths.zig`; the names a configuration uses (`Base`) are shared.
//!
//! Every directory is a Known Folder (`SHGetKnownFolderPath`), never an environment
//! variable or a guessed `%USERPROFILE%\Documents`: a user's Documents may be redirected
//! (OneDrive moves it to `%USERPROFILE%\OneDrive\Belgeler`), and the shell knows where.
//!
//! The application's own directories follow Tauri's, so an application moving from it
//! finds its files: data and configuration in `%APPDATA%\<identifier>` (roaming), the cache
//! in `%LOCALAPPDATA%\<identifier>\Cache`. Not `%LOCALAPPDATA%\<identifier>` itself, as Tauri
//! has it: that is WebView2's user data folder (`webview2/view.zig`), whose `EBWebView`
//! holds the page's cookies and storage, and a page given `$APPCACHE` must not reach it.

const std = @import("std");
const shared = @import("../linux/paths.zig");

pub const Base = shared.Base;
pub const Error = shared.Error;

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

fn guid(comptime text: []const u8) Guid {
    // `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`
    const hex = struct {
        fn of(comptime digits: []const u8, comptime T: type) T {
            return std.fmt.parseInt(T, digits, 16) catch @compileError("bad GUID " ++ text);
        }
    };
    var d: [8]u8 = undefined;
    d[0] = hex.of(text[20..22], u8);
    d[1] = hex.of(text[22..24], u8);
    for (0..6) |i| d[2 + i] = hex.of(text[25 + 2 * i ..][0..2], u8);
    return .{ .a = hex.of(text[1..9], u32), .b = hex.of(text[10..14], u16), .c = hex.of(text[15..19], u16), .d = d };
}

const folders = struct {
    const profile = guid("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
    const roaming_app_data = guid("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}");
    const local_app_data = guid("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}");
    const documents = guid("{FDD39AD0-238F-46AF-ADB4-6C85480369C7}");
    const downloads = guid("{374DE290-123F-4565-9164-39C4925E467B}");
    const desktop = guid("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}");
    const pictures = guid("{33E28130-4E1E-4676-835A-98395C3BC3BB}");
    const music = guid("{4BD8D571-6D19-48D3-BE97-422220080E43}");
    const videos = guid("{18989B1D-99B5-455B-841C-AB7C74E4DDFC}");
};

extern "shell32" fn SHGetKnownFolderPath(id: *const Guid, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
const error_already_exists = 183;

/// Nothing to keep: WebView2 is given its folder directly, the environment is not changed.
pub fn rememberDataHome() void {}

/// The Known Folder `id`, in UTF-8, into `out`.
fn known(id: *const Guid, out: []u8) Error![]const u8 {
    var wide: ?[*:0]u16 = null;
    defer CoTaskMemFree(wide);
    if (SHGetKnownFolderPath(id, 0, null, &wide) != 0) return error.Unavailable;
    const path = std.mem.span(wide orelse return error.Unavailable);
    if (path.len * 3 > out.len) return error.TooLong;
    return out[0..std.unicode.wtf16LeToWtf8(out, path)];
}

fn join(out: []u8, at: usize, tail: []const u8) Error![]const u8 {
    if (at + 1 + tail.len > out.len) return error.TooLong;
    out[at] = '\\';
    @memcpy(out[at + 1 ..][0..tail.len], tail);
    return out[0 .. at + 1 + tail.len];
}

/// The directory `base` names for the application `identifier`, written into `out`.
/// `scratch` is unused here (Linux reads `user-dirs.dirs` into it).
pub fn resolve(base: Base, identifier: []const u8, out: []u8, scratch: []u8) Error![]const u8 {
    _ = scratch;
    switch (base) {
        .none => return error.Unavailable,
        .app_data, .app_config, .app_cache => {
            if (!usableIdentifier(identifier)) return error.Unavailable;
            if (base == .app_cache) {
                const local = try known(&folders.local_app_data, out);
                const own = try join(out, local.len, identifier);
                return join(out, own.len, "Cache");
            }
            const roaming = try known(&folders.roaming_app_data, out);
            return join(out, roaming.len, identifier);
        },
        .home => return known(&folders.profile, out),
        .document => return known(&folders.documents, out),
        .download => return known(&folders.downloads, out),
        .desktop => return known(&folders.desktop, out),
        .picture => return known(&folders.pictures, out),
        .music => return known(&folders.music, out),
        .video => return known(&folders.videos, out),
    }
}

/// An identifier that names one folder: not empty, no separator or drive, not `.` or `..`.
fn usableIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or std.mem.indexOfAny(u8, identifier, "/\\:") != null) return false;
    return !std.mem.eql(u8, identifier, ".") and !std.mem.eql(u8, identifier, "..");
}

/// The application's own state, `%LOCALAPPDATA%\<identifier>\State`: where the core keeps
/// what a page must never write, such as the dialog grants (`platform/grants.zig`). No
/// `fs` base names it (`$APPCACHE` is the sibling `Cache`, `$APPDATA` is roaming), so no
/// scope short of `$HOME` reaches it.
pub fn stateDirectory(identifier: []const u8, out: []u8) Error![]const u8 {
    if (!usableIdentifier(identifier)) return error.Unavailable;
    const local = try known(&folders.local_app_data, out);
    const own = try join(out, local.len, identifier);
    return join(out, own.len, "State");
}

/// Creates `path` and any missing parents. A folder under the user's profile is the
/// user's alone by its inherited permissions, so nothing more is set. False when one
/// cannot be made.
/// The application's own directory: on Windows the same as `makePrivate` (its folders
/// inherit the user profile's access list).
pub fn makeOwnPrivate(path: [:0]const u8) bool {
    return makePrivate(path);
}

pub fn makePrivate(path: [:0]const u8) bool {
    var wide: [4096:0]u16 = undefined;
    if (path.len >= wide.len) return false;
    const len = std.unicode.utf8ToUtf16Le(&wide, path) catch return false;
    if (len < 3 or wide[1] != ':') return false;
    var at: usize = 3;
    while (at <= len) : (at += 1) {
        if (at != len and wide[at] != '\\' and wide[at] != '/') continue;
        const saved = wide[at];
        wide[at] = 0;
        const made = CreateDirectoryW(wide[0..at :0], null) != 0 or GetLastError() == error_already_exists;
        wide[at] = saved;
        if (!made) return false;
    }
    return true;
}

test "this machine's own directories resolve to Known Folders" {
    var out: [1024]u8 = undefined;
    var scratch: [16]u8 = undefined;
    const profile = std.mem.span(std.c.getenv("USERPROFILE") orelse return error.NoProfile);
    try std.testing.expectEqualStrings(profile, try resolve(.home, "", &out, &scratch));
    const appdata = std.mem.span(std.c.getenv("APPDATA") orelse return error.NoAppData);
    var expected: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}\\com.example.notes", .{appdata}), try resolve(.app_data, "com.example.notes", &out, &scratch));
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}\\com.example.notes", .{appdata}), try resolve(.app_config, "com.example.notes", &out, &scratch));
    const local = std.mem.span(std.c.getenv("LOCALAPPDATA") orelse return error.NoLocalAppData);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{s}\\com.example.notes\\Cache", .{local}), try resolve(.app_cache, "com.example.notes", &out, &scratch));
    const documents = try resolve(.document, "", &out, &scratch);
    try std.testing.expect(documents.len > 3 and documents[1] == ':');
    try std.testing.expectError(error.Unavailable, resolve(.app_data, "a\\..\\b", &out, &scratch));
    try std.testing.expectError(error.Unavailable, resolve(.none, "x", &out, &scratch));
}

test "Known Folder ids are parsed as the SDK writes them" {
    const documents = folders.documents;
    try std.testing.expectEqual(@as(u32, 0xFDD39AD0), documents.a);
    try std.testing.expectEqual(@as(u16, 0x238F), documents.b);
    try std.testing.expectEqual(@as(u16, 0x46AF), documents.c);
    try std.testing.expectEqualSlices(u8, &.{ 0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7 }, &documents.d);
}
