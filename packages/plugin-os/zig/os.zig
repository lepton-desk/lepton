//! Facts about the machine, for `@lepton-desk/plugin-os`. No core import: every function
//! here is tested alone with `zig test zig/os.zig`, against the system's own answers.

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

/// The kernel release (`uname -r`), copied into `out`.
pub fn version(out: []u8) error{TooLarge}![]const u8 {
    const names = std.posix.uname();
    return copy(std.mem.sliceTo(&names.release, 0), out);
}

/// The host name (`uname -n`), copied into `out`.
pub fn hostname(out: []u8) error{TooLarge}![]const u8 {
    const names = std.posix.uname();
    return copy(std.mem.sliceTo(&names.nodename, 0), out);
}

/// The user's locale as a BCP 47 tag (`tr_TR.UTF-8` → `tr-TR`), from `LC_ALL`, then
/// `LC_MESSAGES`, then `LANG`, as POSIX orders them. Empty when unset or `C`/`POSIX`.
pub fn locale(out: []u8) error{TooLarge}![]const u8 {
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

fn copy(text: []const u8, out: []u8) error{TooLarge}![]u8 {
    if (text.len > out.len) return error.TooLarge;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

test "the build target's names" {
    try std.testing.expectEqualStrings("linux", platform());
    try std.testing.expect(arch().len > 0);
    try std.testing.expectEqualStrings("unix", family());
    try std.testing.expectEqualStrings("", exeExtension());
}

test "kernel release and host name are the system's" {
    var buffer: [256]u8 = undefined;
    const release = try version(&buffer);
    try std.testing.expect(release.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, release, '.') != null);
    var name: [256]u8 = undefined;
    try std.testing.expect((try hostname(&name)).len > 0);
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
