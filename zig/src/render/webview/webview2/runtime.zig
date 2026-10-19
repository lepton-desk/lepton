//! The installed WebView2 runtime, found and started without Microsoft's loader.
//!
//! `WebView2Loader.dll` is not shipped. The runtime's directory is the `EBWebView` value
//! under `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{F3017226-…}` (the stable channel,
//! 32-bit registry view, machine-wide then per-user), and its
//! `EBWebView\x64\EmbeddedBrowserWebView.dll` exports
//! `CreateWebViewEnvironmentWithOptionsInternal` — measured on 155.0.4283.62 by
//! `zig build webview2-check`, which this file was lifted from.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const W = wv.W;

const client_state = W("SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}");

/// `CreateWebViewEnvironmentWithOptionsInternal`: the first argument is always `true` in
/// the open-source loaders, the second is the runtime kind (0 = installed, 1 = embedded).
pub const CreateInternal = *const fn (
    bool,
    c_int,
    ?[*:0]const u16,
    ?*c.IUnknown,
    ?*c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
) callconv(.winapi) c.HRESULT;

/// The predefined roots are pseudo-handles (`0x80000001`, `0x80000002`) that no aligned
/// `HKEY` can hold — translate-c refuses them — so `RegGetValueW` is declared here with the
/// root as the pointer-sized integer it is.
extern "advapi32" fn RegGetValueW(
    root: usize,
    sub_key: c.LPCWSTR,
    value: c.LPCWSTR,
    flags: c.DWORD,
    kind: ?*c.DWORD,
    data: ?*anyopaque,
    size: ?*c.DWORD,
) callconv(.winapi) c.LSTATUS;

const hkey_current_user: usize = 0x80000001;
const hkey_local_machine: usize = 0x80000002;

/// The runtime's directory (`…\EdgeWebView\Application\<version>`), or null when no
/// runtime is registered.
pub fn directory(buffer: *[c.MAX_PATH]u16) ?[]const u16 {
    for ([_]usize{ hkey_local_machine, hkey_current_user }) |root| {
        var size: c.DWORD = @sizeOf(@TypeOf(buffer.*));
        const status = RegGetValueW(
            root,
            client_state,
            W("EBWebView"),
            c.RRF_RT_REG_SZ | c.RRF_SUBKEY_WOW6432KEY,
            null,
            buffer,
            &size,
        );
        if (status == c.ERROR_SUCCESS and size > 2) return buffer[0 .. size / 2 - 1];
    }
    return null;
}

/// The runtime's version: the last component of its directory.
pub fn version(dir: []const u16, out: []u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u16, dir, '\\') orelse return "";
    const tail = dir[slash + 1 ..];
    if (tail.len * 3 > out.len) return "";
    const len = std.unicode.utf16LeToUtf8(out, tail) catch return "";
    return out[0..len];
}

/// Loads the runtime's client DLL and returns its environment factory.
pub fn load(dir: []const u16) ?CreateInternal {
    const tail = W("\\EBWebView\\x64\\EmbeddedBrowserWebView.dll");
    var path: [c.MAX_PATH:0]u16 = undefined;
    if (dir.len + tail.len >= path.len) return null;
    @memcpy(path[0..dir.len], dir);
    @memcpy(path[dir.len..][0..tail.len], tail);
    path[dir.len + tail.len] = 0;
    const library = c.LoadLibraryW(&path) orelse return null;
    const symbol = c.GetProcAddress(library, "CreateWebViewEnvironmentWithOptionsInternal") orelse return null;
    return @ptrCast(symbol);
}

test "the version is the runtime directory's last component" {
    var out: [64]u8 = undefined;
    const dir = W("C:\\Program Files (x86)\\Microsoft\\EdgeWebView\\Application\\155.0.4283.62");
    try std.testing.expectEqualStrings("155.0.4283.62", version(dir, &out));
}
