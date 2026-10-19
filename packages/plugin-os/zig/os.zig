//! Facts about the machine, for `@lepton-desk/plugin-os`. No core import: every function
//! here is tested alone with `zig test zig/os.zig -lc`, against the system's own answers.
//!
//! Linux answers from `uname` and the POSIX locale variables; Windows from the kernel's
//! own version (`RtlGetVersion`: `GetVersionEx` reports 6.2 to an unmanifested program),
//! the DNS host name and the user's locale, which Windows already names in BCP 47.

const std = @import("std");
const builtin = @import("builtin");

/// `linux`, `windows`, `macos`, … — the target the application was built for.
pub fn platform() []const u8 {
    return @tagName(builtin.os.tag);
}

/// `x86_64`, `aarch64`, …
pub fn arch() []const u8 {
    return @tagName(builtin.cpu.arch);
}

/// `unix` or `windows`.
pub fn family() []const u8 {
    return if (builtin.os.tag == .windows) "windows" else "unix";
}

/// `.exe` on Windows, empty elsewhere.
pub fn exeExtension() []const u8 {
    return if (builtin.os.tag == .windows) ".exe" else "";
}

const windows = builtin.os.tag == .windows;

/// The kernel release (`uname -r`; on Windows `10.0.19045`), copied into `out`.
pub fn version(out: []u8) error{TooLarge}![]const u8 {
    if (windows) {
        var info: win.OsVersionInfo = .{};
        if (win.RtlGetVersion(&info) != 0) return out[0..0];
        return std.fmt.bufPrint(out, "{d}.{d}.{d}", .{ info.major, info.minor, info.build }) catch error.TooLarge;
    }
    const names = std.posix.uname();
    return copy(std.mem.sliceTo(&names.release, 0), out);
}

/// The host name (`uname -n`; on Windows the DNS host name), copied into `out`.
pub fn hostname(out: []u8) error{TooLarge}![]const u8 {
    if (windows) {
        var wide: [256]u16 = undefined;
        var len: u32 = wide.len;
        if (win.GetComputerNameExW(win.computer_name_dns_hostname, &wide, &len) == 0) return out[0..0];
        return utf16(wide[0..len], out);
    }
    const names = std.posix.uname();
    return copy(std.mem.sliceTo(&names.nodename, 0), out);
}

/// The user's locale as a BCP 47 tag (`tr_TR.UTF-8` → `tr-TR`), from `LC_ALL`, then
/// `LC_MESSAGES`, then `LANG`, as POSIX orders them. Empty when unset or `C`/`POSIX`.
/// On Windows the user's locale (`GetUserDefaultLocaleName`), already a BCP 47 tag.
pub fn locale(out: []u8) error{TooLarge}![]const u8 {
    if (windows) {
        var wide: [win.locale_name_max]u16 = undefined;
        const len = win.GetUserDefaultLocaleName(&wide, wide.len);
        if (len <= 1) return out[0..0];
        return utf16(wide[0..@intCast(len - 1)], out);
    }
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const value = std.c.getenv(name) orelse continue;
        const text = std.mem.span(value);
        if (text.len == 0) continue;
        return bcp47(text, out);
    }
    return out[0..0];
}

/// `language[_TERRITORY][.codeset][@modifier]` → `language[-TERRITORY]`.
pub fn bcp47(posix: []const u8, out: []u8) error{TooLarge}![]const u8 {
    const end = std.mem.indexOfAny(u8, posix, ".@") orelse posix.len;
    const tag = posix[0..end];
    if (std.mem.eql(u8, tag, "C") or std.mem.eql(u8, tag, "POSIX")) return out[0..0];
    const written = try copy(tag, out);
    for (written) |*ch| {
        if (ch.* == '_') ch.* = '-';
    }
    return written;
}

fn utf16(wide: []const u16, out: []u8) error{TooLarge}![]const u8 {
    var text: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&text, wide) catch return out[0..0];
    return copy(text[0..len], out);
}

const win = struct {
    const OsVersionInfo = extern struct {
        size: u32 = @sizeOf(OsVersionInfo),
        major: u32 = 0,
        minor: u32 = 0,
        build: u32 = 0,
        platform: u32 = 0,
        service_pack: [128]u16 = @splat(0),
    };
    const computer_name_dns_hostname: c_int = 1;
    const locale_name_max = 85;
    extern "ntdll" fn RtlGetVersion(info: *OsVersionInfo) callconv(.winapi) i32;
    extern "kernel32" fn GetComputerNameExW(kind: c_int, buffer: [*]u16, len: *u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetUserDefaultLocaleName(buffer: [*]u16, len: c_int) callconv(.winapi) c_int;
};

fn copy(text: []const u8, out: []u8) error{TooLarge}![]u8 {
    if (text.len > out.len) return error.TooLarge;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

test "the build target's names" {
    try std.testing.expectEqualStrings(if (windows) "windows" else "linux", platform());
    try std.testing.expect(arch().len > 0);
    try std.testing.expectEqualStrings(if (windows) "windows" else "unix", family());
    try std.testing.expectEqualStrings(if (windows) ".exe" else "", exeExtension());
}

test "kernel release and host name are the system's" {
    var buffer: [256]u8 = undefined;
    const release = try version(&buffer);
    try std.testing.expect(release.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, release, '.') != null);
    var name: [256]u8 = undefined;
    const host = try hostname(&name);
    try std.testing.expect(host.len > 0);
    if (windows) {
        // The system's own answers: `ver`'s build and `COMPUTERNAME` (its NetBIOS form,
        // upper case, at most 15 characters of the DNS name).
        try std.testing.expect(std.mem.startsWith(u8, release, "10.") or std.mem.startsWith(u8, release, "11."));
        const netbios = std.mem.span(std.c.getenv("COMPUTERNAME") orelse return error.NoComputerName);
        try std.testing.expect(std.ascii.startsWithIgnoreCase(host, netbios[0..@min(netbios.len, host.len)]));
        var tag: [32]u8 = undefined;
        const language = try locale(&tag);
        try std.testing.expect(language.len >= 2 and std.mem.indexOfScalar(u8, language, '_') == null);
    }
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(error.TooLarge, version(&tiny));
}

test "POSIX locales become BCP 47 tags" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("tr-TR", try bcp47("tr_TR.UTF-8", &out));
    try std.testing.expectEqualStrings("de-DE", try bcp47("de_DE@euro", &out));
    try std.testing.expectEqualStrings("en", try bcp47("en", &out));
    try std.testing.expectEqualStrings("", try bcp47("C.UTF-8", &out));
    try std.testing.expectEqualStrings("", try bcp47("POSIX", &out));
}
