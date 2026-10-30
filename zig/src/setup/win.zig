//! The Windows calls setup.exe makes: paths, files, the registry, known folders and the
//! Start menu shortcut. Everything is UTF-16 and absolute; files are reached through
//! `\\?\` so a deep `share\` tree is not cut at `MAX_PATH`.

const std = @import("std");
pub const c = @import("c_setup");

/// UTF-16 from a literal, NUL-terminated.
pub const W = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Error = error{ Windows, TooLong, InUse };

/// The last Win32 error, kept for the message the window shows.
pub var last_error: c.DWORD = 0;

fn fail() Error {
    last_error = c.GetLastError();
    return switch (last_error) {
        c.ERROR_SHARING_VIOLATION, c.ERROR_LOCK_VIOLATION, c.ERROR_ACCESS_DENIED => error.InUse,
        else => error.Windows,
    };
}

fn failed(status: c.LONG) Error {
    last_error = @intCast(status);
    return error.Windows;
}

/// An absolute path behind `\\?\`, NUL-terminated. 2048 units: past `MAX_PATH`, and small
/// enough that a tree walked by recursion stays inside a thread's stack.
pub const Path = struct {
    buf: [4 + max]u16 = undefined,
    len: usize = 0,

    const prefix = W("\\\\?\\");
    pub const max = 2048;

    pub fn of(text: []const u16) Error!Path {
        var path: Path = .{};
        @memcpy(path.buf[0..prefix.len], prefix);
        path.len = prefix.len;
        try path.add(text);
        return path;
    }

    pub fn add(path: *Path, text: []const u16) Error!void {
        if (path.len + text.len + 1 > path.buf.len) return error.TooLong;
        @memcpy(path.buf[path.len..][0..text.len], text);
        path.len += text.len;
        path.buf[path.len] = 0;
    }

    /// `\` and then `name` (UTF-8, `/` becoming `\`).
    pub fn join(path: Path, name: []const u8) Error!Path {
        var out = path;
        try out.add(W("\\"));
        var units: [max]u16 = undefined;
        const count = std.unicode.utf8ToUtf16Le(&units, name) catch return error.TooLong;
        for (units[0..count]) |*unit| if (unit.* == '/') {
            unit.* = '\\';
        };
        try out.add(units[0..count]);
        return out;
    }

    pub fn withSuffix(path: Path, suffix: []const u16) Error!Path {
        var out = path;
        try out.add(suffix);
        return out;
    }

    /// For file calls.
    pub fn long(path: *const Path) [*:0]const u16 {
        return path.buf[0..path.len :0].ptr;
    }

    /// For the registry and the shortcut, which store the path as the user sees it.
    pub fn plain(path: *const Path) [:0]const u16 {
        return path.buf[prefix.len..path.len :0];
    }

    pub fn parent(path: Path) Path {
        var out = path;
        while (out.len > prefix.len and out.buf[out.len - 1] != '\\') out.len -= 1;
        if (out.len > prefix.len) out.len -= 1;
        out.buf[out.len] = 0;
        return out;
    }
};

/// A known folder (`FOLDERID_*`).
pub fn knownFolder(id: *const c.GUID) Error!Path {
    var out: c.PWSTR = null;
    if (c.SHGetKnownFolderPath(id, 0, null, &out) != c.S_OK or out == null) {
        last_error = c.ERROR_PATH_NOT_FOUND;
        return error.Windows;
    }
    defer c.CoTaskMemFree(out);
    return Path.of(std.mem.span(@as([*:0]const u16, @ptrCast(out.?))));
}

/// `%LOCALAPPDATA%\Programs`, the MSI's per-user folder too.
pub const folder_user_programs = guid(0x5CD7AEE2, 0x2219, 0x4A67, .{ 0xB8, 0x5D, 0x6C, 0x9C, 0xE1, 0x56, 0x60, 0xCB });
/// The Start menu's Programs, for this user.
pub const folder_programs = guid(0xA77F5D77, 0x2E2B, 0x44C3, .{ 0xA6, 0xA2, 0xAB, 0xA6, 0x01, 0x05, 0x4A, 0x51 });
pub const folder_local_app_data = guid(0xF1B32785, 0x6FBA, 0x4FCF, .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 });
pub const folder_roaming_app_data = guid(0x3EB685DB, 0x65F9, 0x4CF6, .{ 0xA0, 0x3A, 0xE3, 0xEF, 0x65, 0x72, 0x9F, 0x3D });

pub fn guid(a: u32, b: u16, d: u16, e: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

/// This program's own file.
pub fn ownPath() Error!Path {
    var units: [Path.max]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &units, units.len);
    if (len == 0 or len >= units.len) return fail();
    // Already `\\?\` when started through one.
    const text = units[0..len];
    if (std.mem.startsWith(u16, text, Path.prefix)) return Path.of(text[Path.prefix.len..]);
    return Path.of(text);
}

/// A file mapped for reading, for as long as the program runs.
pub fn mapFile(path: *const Path) Error![]const u8 {
    const file = c.CreateFileW(path.long(), c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_DELETE, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return fail();
    defer _ = c.CloseHandle(file);
    var size: c.LARGE_INTEGER = undefined;
    if (c.GetFileSizeEx(file, &size) == 0) return fail();
    const mapping = c.CreateFileMappingW(file, null, c.PAGE_READONLY, 0, 0, null) orelse return fail();
    defer _ = c.CloseHandle(mapping);
    const view = c.MapViewOfFile(mapping, c.FILE_MAP_READ, 0, 0, 0) orelse return fail();
    return @as([*]const u8, @ptrCast(view))[0..@intCast(size.QuadPart)];
}

pub fn exists(path: *const Path) bool {
    return c.GetFileAttributesW(path.long()) != c.INVALID_FILE_ATTRIBUTES;
}

/// The directory and every one above it that is missing.
pub fn createDirs(path: *const Path) Error!void {
    if (c.CreateDirectoryW(path.long(), null) != 0) return;
    switch (c.GetLastError()) {
        c.ERROR_ALREADY_EXISTS => return,
        c.ERROR_PATH_NOT_FOUND => {
            const up = path.parent();
            if (up.len == path.len) return fail();
            try createDirs(&up);
            if (c.CreateDirectoryW(path.long(), null) == 0 and c.GetLastError() != c.ERROR_ALREADY_EXISTS) return fail();
        },
        else => return fail(),
    }
}

pub fn writeFile(path: *const Path, bytes: []const u8) Error!void {
    const file = c.CreateFileW(path.long(), c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return fail();
    defer _ = c.CloseHandle(file);
    var rest = bytes;
    while (rest.len > 0) {
        const chunk: c.DWORD = @intCast(@min(rest.len, 1 << 30));
        var written: c.DWORD = 0;
        if (c.WriteFile(file, rest.ptr, chunk, &written, null) == 0) return fail();
        rest = rest[written..];
    }
}

/// Reads a small file whole (the installed `.lepton-setup` and file list).
pub fn readFile(path: *const Path, out: []u8) Error![]u8 {
    const file = c.CreateFileW(path.long(), c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return fail();
    defer _ = c.CloseHandle(file);
    var used: usize = 0;
    while (used < out.len) {
        var got: c.DWORD = 0;
        if (c.ReadFile(file, out[used..].ptr, @intCast(@min(out.len - used, 1 << 30)), &got, null) == 0) return fail();
        if (got == 0) break;
        used += got;
    }
    if (used == out.len) return error.TooLong;
    return out[0..used];
}

pub fn rename(from: *const Path, to: *const Path) Error!void {
    if (c.MoveFileExW(from.long(), to.long(), 0) == 0) return fail();
}

pub fn deleteFile(path: *const Path) Error!void {
    if (c.DeleteFileW(path.long()) != 0) return;
    if (c.GetLastError() == c.ERROR_FILE_NOT_FOUND or c.GetLastError() == c.ERROR_PATH_NOT_FOUND) return;
    return fail();
}

/// Removes an empty directory; one that is not empty, or gone, is left as it is.
pub fn removeEmptyDir(path: *const Path) void {
    _ = c.RemoveDirectoryW(path.long());
}

/// Removes `path` and everything under it.
pub fn deleteTree(path: *const Path) Error!void {
    const attributes = c.GetFileAttributesW(path.long());
    if (attributes == c.INVALID_FILE_ATTRIBUTES) return;
    // A link or junction is removed itself, never followed.
    if (attributes & c.FILE_ATTRIBUTE_DIRECTORY == 0 or attributes & c.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
        if (attributes & c.FILE_ATTRIBUTE_READONLY != 0) _ = c.SetFileAttributesW(path.long(), c.FILE_ATTRIBUTE_NORMAL);
        if (attributes & c.FILE_ATTRIBUTE_DIRECTORY != 0) {
            if (c.RemoveDirectoryW(path.long()) == 0) return fail();
            return;
        }
        return deleteFile(path);
    }
    var pattern = try path.join("*");
    var found: c.WIN32_FIND_DATAW = undefined;
    const search = c.FindFirstFileW(pattern.long(), &found);
    if (search != c.INVALID_HANDLE_VALUE) {
        defer _ = c.FindClose(search);
        while (true) {
            const name = std.mem.sliceTo(&found.cFileName, 0);
            if (!std.mem.eql(u16, name, W(".")) and !std.mem.eql(u16, name, W(".."))) {
                var child = path.*;
                try child.add(W("\\"));
                try child.add(name);
                try deleteTree(&child);
            }
            if (c.FindNextFileW(search, &found) == 0) break;
        }
    }
    if (c.RemoveDirectoryW(path.long()) == 0) return fail();
}

// The registry. `HKEY_CURRENT_USER` is `(HKEY)0x80000001`, which no Zig `HKEY` may hold (it
// must be aligned): the calls are declared with keys as the integers they are.
const hkey_current_user: usize = 0x80000001;
extern "advapi32" fn RegCreateKeyExW(key: usize, sub_key: [*:0]const u16, reserved: c.DWORD, class: ?[*:0]const u16, options: c.DWORD, access: c.DWORD, security: ?*anyopaque, result: *usize, disposition: ?*c.DWORD) callconv(.winapi) c.LONG;
extern "advapi32" fn RegOpenKeyExW(key: usize, sub_key: [*:0]const u16, options: c.DWORD, access: c.DWORD, result: *usize) callconv(.winapi) c.LONG;
extern "advapi32" fn RegSetValueExW(key: usize, name: ?[*:0]const u16, reserved: c.DWORD, kind: c.DWORD, data: [*]const u8, size: c.DWORD) callconv(.winapi) c.LONG;
extern "advapi32" fn RegQueryValueExW(key: usize, name: ?[*:0]const u16, reserved: ?*c.DWORD, kind: ?*c.DWORD, data: ?[*]u8, size: *c.DWORD) callconv(.winapi) c.LONG;
extern "advapi32" fn RegDeleteTreeW(key: usize, sub_key: ?[*:0]const u16) callconv(.winapi) c.LONG;
extern "advapi32" fn RegCloseKey(key: usize) callconv(.winapi) c.LONG;

/// A key under `HKEY_CURRENT_USER`, opened for writing (created when missing).
pub const Key = struct {
    handle: usize,

    pub fn create(sub_key: [:0]const u16) Error!Key {
        var handle: usize = 0;
        const status = RegCreateKeyExW(hkey_current_user, sub_key.ptr, 0, null, 0, c.KEY_WRITE | c.KEY_READ, null, &handle, null);
        if (status != c.ERROR_SUCCESS) return failed(status);
        return .{ .handle = handle };
    }

    pub fn open(sub_key: [:0]const u16) ?Key {
        var handle: usize = 0;
        if (RegOpenKeyExW(hkey_current_user, sub_key.ptr, 0, c.KEY_READ, &handle) != c.ERROR_SUCCESS) return null;
        return .{ .handle = handle };
    }

    pub fn close(key: Key) void {
        _ = RegCloseKey(key.handle);
    }

    /// `name` null is the key's default value.
    pub fn setText(key: Key, name: ?[*:0]const u16, value: []const u16) Error!void {
        var units: [4096]u16 = undefined;
        if (value.len + 1 > units.len) return error.TooLong;
        @memcpy(units[0..value.len], value);
        units[value.len] = 0;
        const bytes = std.mem.sliceAsBytes(units[0 .. value.len + 1]);
        const status = RegSetValueExW(key.handle, name, 0, c.REG_SZ, bytes.ptr, @intCast(bytes.len));
        if (status != c.ERROR_SUCCESS) return failed(status);
    }

    pub fn setNumber(key: Key, name: [*:0]const u16, value: u32) Error!void {
        const bytes = std.mem.asBytes(&value);
        const status = RegSetValueExW(key.handle, name, 0, c.REG_DWORD, bytes, bytes.len);
        if (status != c.ERROR_SUCCESS) return failed(status);
    }

    /// A text value, without its NUL; null when missing or not text.
    pub fn text(key: Key, name: ?[*:0]const u16, out: []u16) ?[]const u16 {
        var kind: c.DWORD = 0;
        var size: c.DWORD = @intCast(out.len * 2);
        if (RegQueryValueExW(key.handle, name, null, &kind, @ptrCast(out.ptr), &size) != c.ERROR_SUCCESS) return null;
        if (kind != c.REG_SZ) return null;
        var units = out[0 .. size / 2];
        while (units.len > 0 and units[units.len - 1] == 0) units = units[0 .. units.len - 1];
        return units;
    }
};

/// Removes a key under `HKEY_CURRENT_USER` and everything below it; a missing one is fine.
/// Given a sub key, `RegDeleteTreeW` removes that key too, not only what is under it.
pub fn deleteKey(sub_key: [:0]const u16) void {
    _ = RegDeleteTreeW(hkey_current_user, sub_key.ptr);
}

/// UTF-16 of `text` into `out`, NUL-terminated.
pub fn wide(out: []u16, text: []const u8) Error![:0]u16 {
    if (out.len == 0) return error.TooLong;
    const count = std.unicode.utf8ToUtf16Le(out[0 .. out.len - 1], text) catch return error.TooLong;
    out[count] = 0;
    return out[0..count :0];
}

/// Concatenates UTF-16 pieces into `out`, NUL-terminated.
pub fn concat(out: []u16, pieces: []const []const u16) Error![:0]u16 {
    var used: usize = 0;
    for (pieces) |piece| {
        if (used + piece.len + 1 > out.len) return error.TooLong;
        @memcpy(out[used..][0..piece.len], piece);
        used += piece.len;
    }
    out[used] = 0;
    return out[0..used :0];
}

// The shortcut: `IShellLinkW`, saved through `IPersistFile`, with `PKEY_AppUserModel_ID`
// set through `IPropertyStore` as the MSI's `MsiShortcutProperty` sets it.
const clsid_shell_link = guid(0x00021401, 0x0000, 0x0000, .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_shell_link = guid(0x000214F9, 0x0000, 0x0000, .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_persist_file = guid(0x0000010B, 0x0000, 0x0000, .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const iid_property_store = guid(0x886D8EEB, 0x8CF2, 0x4446, .{ 0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99 });
const pkey_app_user_model_id: c.PROPERTYKEY = .{
    .fmtid = guid(0x9F4C2855, 0x9F79, 0x4B39, .{ 0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3 }),
    .pid = 5,
};

/// `PROPVARIANT` holding a `VT_LPWSTR`: its layout on x64, written out, since the header's
/// nested unions translate under generated names.
const TextVariant = extern struct {
    vt: u16 = c.VT_LPWSTR,
    reserved: [3]u16 = .{ 0, 0, 0 },
    text: [*:0]const u16,
    rest: usize = 0,
};

pub const Shortcut = struct {
    file: *const Path,
    target: [:0]const u16,
    directory: [:0]const u16,
    description: [:0]const u16,
    icon: ?[:0]const u16,
    app_id: [:0]const u16,
};

pub fn writeShortcut(shortcut: Shortcut) Error!void {
    var link: ?*c.IShellLinkW = null;
    if (c.CoCreateInstance(&clsid_shell_link, null, c.CLSCTX_INPROC_SERVER, &iid_shell_link, @ptrCast(&link)) != c.S_OK) return comFailed();
    const it = link.?;
    defer _ = it.lpVtbl.*.Release.?(it);
    const v = it.lpVtbl.*;
    if (v.SetPath.?(it, shortcut.target.ptr) != c.S_OK) return comFailed();
    if (v.SetWorkingDirectory.?(it, shortcut.directory.ptr) != c.S_OK) return comFailed();
    if (v.SetDescription.?(it, shortcut.description.ptr) != c.S_OK) return comFailed();
    if (shortcut.icon) |icon| _ = v.SetIconLocation.?(it, icon.ptr, 0);

    var store: ?*c.IPropertyStore = null;
    if (v.QueryInterface.?(it, &iid_property_store, @ptrCast(&store)) != c.S_OK) return comFailed();
    defer _ = store.?.lpVtbl.*.Release.?(store.?);
    const value: TextVariant = .{ .text = shortcut.app_id.ptr };
    if (store.?.lpVtbl.*.SetValue.?(store.?, &pkey_app_user_model_id, @ptrCast(&value)) != c.S_OK) return comFailed();
    if (store.?.lpVtbl.*.Commit.?(store.?) != c.S_OK) return comFailed();

    var persist: ?*c.IPersistFile = null;
    if (v.QueryInterface.?(it, &iid_persist_file, @ptrCast(&persist)) != c.S_OK) return comFailed();
    defer _ = persist.?.lpVtbl.*.Release.?(persist.?);
    if (persist.?.lpVtbl.*.Save.?(persist.?, shortcut.file.plain().ptr, c.TRUE) != c.S_OK) return comFailed();
}

fn comFailed() Error {
    last_error = c.ERROR_CAN_NOT_COMPLETE;
    return error.Windows;
}

comptime {
    std.debug.assert(@sizeOf(TextVariant) == 24);
}

/// Windows' own text for `last_error`, in the user's language, into `out`.
pub fn errorText(code: c.DWORD, out: []u16) []const u16 {
    const len = c.FormatMessageW(c.FORMAT_MESSAGE_FROM_SYSTEM | c.FORMAT_MESSAGE_IGNORE_INSERTS, null, code, 0, out.ptr, @intCast(out.len), null);
    var text = out[0..len];
    while (text.len > 0 and (text[text.len - 1] == '\n' or text[text.len - 1] == '\r' or text[text.len - 1] == ' ' or text[text.len - 1] == '.')) text = text[0 .. text.len - 1];
    return text;
}
