//! The system clipboard as text, for `@lepton-desk/plugin-clipboard`.
//!
//! The calls live in the core, not in the plugin: a plugin is compiled into every
//! application that installs it, native ones included, and a native build links no WPE.
//! Here the WPE calls are only analysed when the build has the 2.54 platform ABI; anywhere
//! else both functions answer `Failed`, and the page gets `failed` rather than a link
//! error at build time.
//!
//! The clipboard is the default display's (`wpe_display_get_clipboard`), which on Wayland
//! is `WPEClipboardWayland`: `wl_data_device` underneath, so what is written here is what
//! other applications paste, and what they copy is read here. Both directions are
//! synchronous in WPE (`WPEClipboard.h`, 2.54). The compositor only tells a focused client
//! about the selection, so an unfocused window reads what it last saw.

const std = @import("std");
const build_options = @import("build_options");
const registry = @import("registry.zig");

const HandlerError = registry.HandlerError;

/// Whether this build can reach the clipboard at all.
pub const available = build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render;

/// Text formats in the order they are asked for. Wayland applications offer several;
/// `text/plain` without a charset is not guaranteed to be UTF-8, so it comes second.
pub const text_formats = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT" };

// WPEDisplay.h / WPEClipboard.h, 2.54. Analysed only through `readText`/`writeText` when
// `available`, so a build without WPE never references them.
const e_display_get_default = @extern(*const fn () callconv(.c) ?*anyopaque, .{ .name = "wpe_display_get_default" });
const e_display_get_clipboard = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "wpe_display_get_clipboard" });
const e_clipboard_get_formats = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:null]const ?[*:0]const u8, .{ .name = "wpe_clipboard_get_formats" });
const e_clipboard_read_text = @extern(*const fn (?*anyopaque, [*:0]const u8, ?*usize) callconv(.c) ?[*]u8, .{ .name = "wpe_clipboard_read_text" });
const e_clipboard_get_change_count = @extern(*const fn (?*anyopaque) callconv(.c) i64, .{ .name = "wpe_clipboard_get_change_count" });
const e_clipboard_set_content = @extern(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, .{ .name = "wpe_clipboard_set_content" });
const e_content_new = @extern(*const fn () callconv(.c) ?*anyopaque, .{ .name = "wpe_clipboard_content_new" });
const e_content_set_text = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, .{ .name = "wpe_clipboard_content_set_text" });
const e_content_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "wpe_clipboard_content_unref" });
const e_strndup = @extern(*const fn ([*]const u8, usize) callconv(.c) ?[*:0]u8, .{ .name = "g_strndup" });
const e_free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_free" });

fn clipboard() ?*anyopaque {
    const display = e_display_get_default() orelse return null;
    return e_display_get_clipboard(display);
}

/// How many times the clipboard has changed, as WPE counts; -1 without a clipboard.
pub fn changeCount() i64 {
    if (comptime !available) return -1;
    const board = clipboard() orelse return -1;
    return e_clipboard_get_change_count(board);
}

/// The first of [`text_formats`] that `offered` contains, as the offered string.
pub fn chooseFormat(offered: []const []const u8) ?[]const u8 {
    for (text_formats) |wanted| {
        for (offered) |format| {
            if (std.mem.eql(u8, format, wanted)) return format;
        }
    }
    return null;
}

/// The clipboard's text, written into the front of `out`; 0 bytes when it holds no text.
pub fn readText(out: []u8) HandlerError!usize {
    if (comptime !available) return error.Failed;
    const board = clipboard() orelse return error.Failed;
    const formats = e_clipboard_get_formats(board) orelse return 0;
    var offered: [32][]const u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (formats[index]) |format| : (index += 1) {
        if (count == offered.len) break;
        offered[count] = std.mem.span(format);
        count += 1;
    }
    const format = chooseFormat(offered[0..count]) orelse return 0;
    // `format` is one of the clipboard's own NUL-terminated strings, so its pointer is
    // still a C string.
    var size: usize = 0;
    const text = e_clipboard_read_text(board, @ptrCast(format.ptr), &size) orelse return 0;
    defer e_free(text);
    if (size > out.len) return error.TooLarge;
    @memcpy(out[0..size], text[0..size]);
    return size;
}

/// Puts `text` on the clipboard, for this application and every other.
pub fn writeText(text: []const u8) HandlerError!void {
    if (comptime !available) return error.Failed;
    // The page's text may hold a NUL; the clipboard's C string would end there silently.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Failed;
    if (!std.unicode.utf8ValidateSlice(text)) return error.Failed;
    const board = clipboard() orelse return error.Failed;
    const copy = e_strndup(text.ptr, text.len) orelse return error.Failed;
    defer e_free(copy);
    const content = e_content_new() orelse return error.Failed;
    defer e_content_unref(content);
    e_content_set_text(content, copy);
    e_clipboard_set_content(board, content);
}

test "the first text format the clipboard offers in the preferred order" {
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", chooseFormat(&.{ "text/html", "text/plain", "text/plain;charset=utf-8" }).?);
    try std.testing.expectEqualStrings("text/plain", chooseFormat(&.{ "UTF8_STRING", "text/plain" }).?);
    try std.testing.expect(chooseFormat(&.{ "image/png", "text/html" }) == null);
    try std.testing.expect(chooseFormat(&.{}) == null);
}

test "both directions are compiled in this build" {
    // Zig analyses only what is referenced: without this a native build would never see
    // the gate, and a webview build would never type-check the WPE calls.
    _ = &readText;
    _ = &writeText;
    if (comptime !available) {
        var out: [4]u8 = undefined;
        try std.testing.expectError(error.Failed, readText(&out));
        try std.testing.expectError(error.Failed, writeText("x"));
    }
}

test "text the clipboard could not carry is refused before WPE is asked" {
    if (comptime !available) return error.SkipZigTest;
    try std.testing.expectError(error.Failed, writeText("a\x00b"));
    try std.testing.expectError(error.Failed, writeText("\xff"));
}
