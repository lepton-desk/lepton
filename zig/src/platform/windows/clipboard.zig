//! The Windows clipboard as text (`CF_UNICODETEXT`), for `core.webviewClipboard` and so for
//! `@lepton-desk/plugin-clipboard`.
//!
//! A write needs an owner window: after `OpenClipboard(NULL)`, `EmptyClipboard` leaves the
//! clipboard ownerless and `SetClipboardData` fails (Microsoft Learn, `OpenClipboard`). A
//! hidden message-only window is made for that on first use. Another application may hold
//! the clipboard open for a moment, so opening is retried briefly before giving up.

const std = @import("std");
const windows = std.os.windows;

const HWND = ?*anyopaque;
extern "user32" fn OpenClipboard(owner: HWND) callconv(.winapi) windows.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) windows.BOOL;
extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetClipboardData(format: u32, data: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) windows.BOOL;
extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) u32;
extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class: [*:0]const u16,
    name: [*:0]const u16,
    style: u32,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: HWND,
    menu: ?*anyopaque,
    instance: ?*anyopaque,
    param: ?*anyopaque,
) callconv(.winapi) HWND;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(memory: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GlobalSize(memory: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const cf_unicodetext: u32 = 13;
const gmem_moveable: u32 = 0x0002;
/// `HWND_MESSAGE`: a window that only receives messages, never shown.
const hwnd_message: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

pub const Error = error{ Failed, TooLarge };

var owner: HWND = null;

fn ownerWindow() HWND {
    if (owner == null) {
        // The predefined "STATIC" class: no window procedure of our own to register.
        owner = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 0, 0, hwnd_message, null, null, null);
    }
    return owner;
}

fn open(window: HWND) bool {
    var attempt: u32 = 0;
    while (attempt < 10) : (attempt += 1) {
        if (OpenClipboard(window) != .FALSE) return true;
        Sleep(10);
    }
    return false;
}

/// How many times the clipboard has changed this session (`GetClipboardSequenceNumber`).
pub fn changeCount() i64 {
    return GetClipboardSequenceNumber();
}

/// The clipboard's text as UTF-8 into the front of `out`; 0 bytes when it holds no text.
pub fn readText(out: []u8) Error!usize {
    if (IsClipboardFormatAvailable(cf_unicodetext) == .FALSE) return 0;
    if (!open(ownerWindow())) return error.Failed;
    defer _ = CloseClipboard();
    const handle = GetClipboardData(cf_unicodetext) orelse return 0;
    const locked = GlobalLock(handle) orelse return error.Failed;
    defer _ = GlobalUnlock(handle);
    const capacity = GlobalSize(handle) / 2;
    const units: [*]const u16 = @ptrCast(@alignCast(locked));
    const text = std.mem.sliceTo(units[0..capacity], 0);
    // At most three UTF-8 bytes per UTF-16 unit.
    var written: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(text);
    while (it.nextCodepoint() catch return error.Failed) |codepoint| {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch return error.Failed;
        if (written + len > out.len) return error.TooLarge;
        @memcpy(out[written..][0..len], bytes[0..len]);
        written += len;
    }
    return written;
}

/// Puts `text` (UTF-8, no NUL) on the clipboard, for this application and every other.
pub fn writeText(text: []const u8) Error!void {
    const units = std.unicode.calcUtf16LeLen(text) catch return error.Failed;
    const memory = GlobalAlloc(gmem_moveable, (units + 1) * 2) orelse return error.Failed;
    {
        const locked = GlobalLock(memory) orelse {
            _ = GlobalFree(memory);
            return error.Failed;
        };
        const wide: [*]u16 = @ptrCast(@alignCast(locked));
        _ = std.unicode.utf8ToUtf16Le(wide[0..units], text) catch {
            _ = GlobalUnlock(memory);
            _ = GlobalFree(memory);
            return error.Failed;
        };
        wide[units] = 0;
        _ = GlobalUnlock(memory);
    }
    if (!open(ownerWindow())) {
        _ = GlobalFree(memory);
        return error.Failed;
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    // On success the system owns the memory; only a refused one is ours to free.
    if (SetClipboardData(cf_unicodetext, memory) == null) {
        _ = GlobalFree(memory);
        return error.Failed;
    }
}

test "text round-trips through the system clipboard" {
    const before = changeCount();
    try writeText("lepton · pano ✓");
    try std.testing.expect(changeCount() != before);
    var out: [64]u8 = undefined;
    const len = try readText(&out);
    try std.testing.expectEqualStrings("lepton · pano ✓", out[0..len]);
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.TooLarge, readText(&tiny));
}
