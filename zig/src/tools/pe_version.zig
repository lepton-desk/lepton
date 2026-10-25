//! `pe-version <in.exe> <out.exe> <major> <minor>`: a copy of a Windows program whose PE
//! header names `major.minor` as the oldest Windows it runs on.
//!
//! Zig writes 6.0 (Vista) into every Windows program, whatever the build's oldest Windows
//! is (measured with Zig 0.16 for `win7` through `win11_dt`), and offers no option for it
//! (`--subsystem` takes `windows` or `console` only). A web view needs WebView2, which
//! Windows 7 and 8.1 do not have current, so the template's `build.zig` runs this on a
//! web view program with 10.0: Windows' loader refuses a program whose subsystem version
//! is newer than itself, so the program says so at once instead of starting and failing
//! where WebView2 should be.
//!
//! The four fields are `MajorOperatingSystemVersion`, `MinorOperatingSystemVersion`,
//! `MajorSubsystemVersion` and `MinorSubsystemVersion` of the optional header (PE format,
//! Microsoft Learn). The header's `CheckSum` is left as it is: Zig writes 0, and the loader
//! checks it only for drivers and a few system DLLs.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.next();
    const from = args.next() orelse return usage();
    const to = args.next() orelse return usage();
    const major = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();
    const minor = std.fmt.parseInt(u16, args.next() orelse return usage(), 10) catch return usage();

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(init.io, from, arena, .limited(1 << 30));
    setVersion(bytes, major, minor) catch |err| {
        std.debug.print("pe-version: {s} is not a PE32+ program ({t})\n", .{ from, err });
        return err;
    };
    // Executable, as an installed artifact is: a package made on Linux takes the mode
    // from the file, and a 0644 program was the one difference left between it and the
    // package made on Windows (measured).
    try cwd.writeFile(init.io, .{ .sub_path = to, .data = bytes, .flags = .{ .permissions = .executable_file } });
}

fn usage() error{Usage} {
    std.debug.print("usage: pe-version <in.exe> <out.exe> <major> <minor>\n", .{});
    return error.Usage;
}

pub const Error = error{ NotPe, NotPe32Plus };

/// Writes `major.minor` into the operating system and subsystem version fields of the
/// PE32+ image in `bytes`.
pub fn setVersion(bytes: []u8, major: u16, minor: u16) Error!void {
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotPe;
    const pe = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    // "PE\0\0", the 20-byte COFF header, then the optional header.
    const optional = @as(usize, pe) + 4 + 20;
    if (optional + 52 > bytes.len or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    if (std.mem.readInt(u16, bytes[optional..][0..2], .little) != 0x20b) return error.NotPe32Plus;
    std.mem.writeInt(u16, bytes[optional + 40 ..][0..2], major, .little);
    std.mem.writeInt(u16, bytes[optional + 42 ..][0..2], minor, .little);
    std.mem.writeInt(u16, bytes[optional + 48 ..][0..2], major, .little);
    std.mem.writeInt(u16, bytes[optional + 50 ..][0..2], minor, .little);
}
