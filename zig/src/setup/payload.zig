//! What `setup.exe` carries after its own program: the application as a `.zip` that
//! `lepton package` wrote (`crates/cli/src/commands/zip.rs`), every entry under one top
//! directory, with `.lepton-setup` beside `bin\` and `share\` saying what is installed.
//!
//! The zip is read here from the bytes of the whole file, not through `std.zip`: its
//! offsets count from the zip's own start while the file starts with the program, and
//! `std.zip` checks no CRC (`verify_checksums` is a `@panic` in 0.16 and 0.17). The base is
//! where the central directory says it should be minus where it is, as self-extracting
//! archives have always been read. Only what `zip.rs` writes is accepted: stored or
//! deflated, no ZIP64, no encryption, names that stay inside the install directory.
//!
//! Nothing here touches Windows, so it is tested on every platform.

const std = @import("std");

pub const Error = error{
    NoArchive,
    Damaged,
    BadName,
    Unsupported,
    CrcMismatch,
    NoManifest,
    BadManifest,
};

const end_signature = 0x06054b50;
const central_signature = 0x02014b50;
const local_signature = 0x04034b50;
const end_len = 22;

const stored = 0;
const deflated = 8;

/// The archive at the end of `bytes`.
pub const Archive = struct {
    bytes: []const u8,
    /// Where the zip starts in `bytes`.
    base: usize,
    central: []const u8,
    count: u16,
    /// The one top directory every entry is under, with its slash.
    top: []const u8,

    pub fn open(bytes: []const u8) Error!Archive {
        if (bytes.len < end_len) return error.NoArchive;
        // `zip.rs` writes no comment, but a reader looks as far back as one could reach.
        const earliest = bytes.len -| (end_len + 0xffff);
        var at = bytes.len - end_len;
        const end = while (true) : (at -= 1) {
            if (read32(bytes, at) == end_signature and at + end_len + read16(bytes, at + 20) == bytes.len) break at;
            if (at == earliest) return error.NoArchive;
        };
        if (read16(bytes, end + 4) != 0 or read16(bytes, end + 6) != 0) return error.Unsupported;
        const count = read16(bytes, end + 10);
        const size = read32(bytes, end + 12);
        const offset = read32(bytes, end + 16);
        if (count == 0xffff or size == 0xffffffff or offset == 0xffffffff) return error.Unsupported;
        if (size > end) return error.Damaged;
        const central_at = end - size;
        if (offset > central_at) return error.Damaged;
        var archive: Archive = .{
            .bytes = bytes,
            .base = central_at - offset,
            .central = bytes[central_at..end],
            .count = count,
            .top = "",
        };
        var entries = archive.rawIterator();
        const first = (try entries.next()) orelse return error.Damaged;
        const full = if (first.directory) first.name.ptr[0 .. first.name.len + 1] else first.name;
        const slash = std.mem.findScalar(u8, full, '/') orelse return error.BadName;
        archive.top = full[0 .. slash + 1];
        return archive;
    }

    /// The entries, their names without the top directory; the top directory itself is
    /// left out.
    pub fn iterator(archive: *const Archive) Iterator {
        return .{ .raw = archive.rawIterator(), .top = archive.top };
    }

    fn rawIterator(archive: *const Archive) RawIterator {
        return .{ .archive = archive };
    }

    /// The entry named `name` (below the top directory).
    pub fn find(archive: *const Archive, name: []const u8) Error!?Entry {
        var entries = archive.iterator();
        while (try entries.next()) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// One file or directory.
pub const Entry = struct {
    /// Forward slashes, no trailing one; checked to stay inside the install directory.
    name: []const u8,
    directory: bool,
    method: u16,
    crc: u32,
    size: u32,
    data: []const u8,

    /// Unpacks into `out` (exactly `size` bytes) and checks the CRC-32.
    pub fn unpack(entry: Entry, out: []u8) Error!void {
        if (out.len != entry.size) return error.Damaged;
        switch (entry.method) {
            stored => {
                if (entry.data.len != entry.size) return error.Damaged;
                @memcpy(out, entry.data);
            },
            deflated => {
                var input: std.Io.Reader = .fixed(entry.data);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var inflate: std.compress.flate.Decompress = .init(&input, .raw, &window);
                inflate.reader.readSliceAll(out) catch return error.Damaged;
            },
            else => return error.Unsupported,
        }
        if (std.hash.Crc32.hash(out) != entry.crc) return error.CrcMismatch;
    }
};

const RawIterator = struct {
    archive: *const Archive,
    index: u16 = 0,
    at: usize = 0,

    fn next(it: *RawIterator) Error!?Entry {
        if (it.index == it.archive.count) return null;
        const central = it.archive.central;
        const bytes = it.archive.bytes;
        if (it.at + 46 > central.len or read32(central, it.at) != central_signature) return error.Damaged;
        const flags = read16(central, it.at + 8);
        // Bit 0: encrypted; bit 3: sizes after the data. `zip.rs` sets neither.
        if (flags & 0b1001 != 0) return error.Unsupported;
        const method = read16(central, it.at + 10);
        const crc = read32(central, it.at + 16);
        const packed_size = read32(central, it.at + 20);
        const size = read32(central, it.at + 24);
        const name_len = read16(central, it.at + 28);
        const extra_len = read16(central, it.at + 30);
        const comment_len = read16(central, it.at + 32);
        const local = it.archive.base + @as(usize, read32(central, it.at + 42));
        const name_at = it.at + 46;
        if (name_at + name_len > central.len) return error.Damaged;
        const name = central[name_at..][0..name_len];
        it.at = name_at + name_len + extra_len + comment_len;
        it.index += 1;

        if (local + 30 > bytes.len or read32(bytes, local) != local_signature) return error.Damaged;
        const data_at = local + 30 + @as(usize, read16(bytes, local + 26)) + read16(bytes, local + 28);
        if (data_at + packed_size > bytes.len) return error.Damaged;
        try checkName(name);
        const directory = name[name.len - 1] == '/';
        if (directory and size != 0) return error.Damaged;
        return .{
            .name = if (directory) name[0 .. name.len - 1] else name,
            .directory = directory,
            .method = method,
            .crc = crc,
            .size = size,
            .data = bytes[data_at..][0..packed_size],
        };
    }
};

pub const Iterator = struct {
    raw: RawIterator,
    top: []const u8,

    pub fn next(it: *Iterator) Error!?Entry {
        while (try it.raw.next()) |entry| {
            const full = if (entry.directory) entry.name.ptr[0 .. entry.name.len + 1] else entry.name;
            if (!std.mem.startsWith(u8, full, it.top)) return error.BadName;
            if (full.len == it.top.len) continue;
            var inner = entry;
            inner.name = entry.name[it.top.len..];
            return inner;
        }
        return null;
    }
};

/// A name `zip.rs` would write: relative, forward slashes, no `.` or `..` part, nothing
/// Windows reads as a drive, a stream or a device path.
fn checkName(name: []const u8) Error!void {
    if (name.len == 0 or name[0] == '/') return error.BadName;
    for (name) |byte| switch (byte) {
        '\\', ':', 0...0x1f, '<', '>', '"', '|', '?', '*' => return error.BadName,
        else => {},
    };
    const trimmed = if (name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    var parts = std.mem.splitScalar(u8, trimmed, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.BadName;
        // Windows drops a trailing dot or space, so `a.` would land on `a`.
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.BadName;
    }
}

fn read16(bytes: []const u8, at: usize) u16 {
    if (at + 2 > bytes.len) return 0;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn read32(bytes: []const u8, at: usize) u32 {
    if (at + 4 > bytes.len) return 0;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// The file beside `bin\` and `share\` that says what is installed.
pub const manifest_name = ".lepton-setup";

/// `.lepton-setup`: UTF-8 lines of `key=value`, written by `lepton package`
/// (`crates/cli/src/commands/setup.rs`). `scheme` may repeat; unknown keys are skipped, so a
/// newer CLI can add some.
pub const Manifest = struct {
    identifier: []const u8 = "",
    product: []const u8 = "",
    version: []const u8 = "",
    publisher: []const u8 = "",
    /// `bin/notes.exe`.
    program: []const u8 = "",
    /// `share/notes/icon.ico`, when the bundle has one.
    icon: []const u8 = "",
    /// The text the schemes are read from again (`schemes()`).
    text: []const u8 = "",

    pub fn parse(text: []const u8) Error!Manifest {
        var manifest: Manifest = .{ .text = text };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const equals = std.mem.findScalar(u8, line, '=') orelse return error.BadManifest;
            const key = line[0..equals];
            const value = line[equals + 1 ..];
            if (std.mem.eql(u8, key, "identifier")) manifest.identifier = value;
            if (std.mem.eql(u8, key, "product")) manifest.product = value;
            if (std.mem.eql(u8, key, "version")) manifest.version = value;
            if (std.mem.eql(u8, key, "publisher")) manifest.publisher = value;
            if (std.mem.eql(u8, key, "program")) manifest.program = value;
            if (std.mem.eql(u8, key, "icon")) manifest.icon = value;
        }
        if (!identifierOk(manifest.identifier)) return error.BadManifest;
        if (!productOk(manifest.product)) return error.BadManifest;
        _ = Version.parse(manifest.version) orelse return error.BadManifest;
        checkName(manifest.program) catch return error.BadManifest;
        if (manifest.icon.len > 0) checkName(manifest.icon) catch return error.BadManifest;
        var each = manifest.schemes();
        while (each.next()) |scheme| if (!schemeOk(scheme)) return error.BadManifest;
        return manifest;
    }

    pub fn schemes(manifest: Manifest) Schemes {
        return .{ .lines = std.mem.splitScalar(u8, manifest.text, '\n') };
    }

    pub const Schemes = struct {
        lines: std.mem.SplitIterator(u8, .scalar),

        pub fn next(it: *Schemes) ?[]const u8 {
            while (it.lines.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                if (std.mem.startsWith(u8, line, "scheme=")) return line["scheme=".len..];
            }
            return null;
        }
    };
};

/// `lepton.config.json`'s identifier: `[A-Za-z0-9.-]`, as the CLI checks it; it names
/// registry keys, so nothing else is let through.
fn identifierOk(text: []const u8) bool {
    if (text.len == 0 or text.len > 200) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// The product names a folder and a shortcut: no character Windows refuses in a file name,
/// no trailing dot or space, not empty.
fn productOk(text: []const u8) bool {
    if (text.len == 0 or text.len > 120) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| switch (byte) {
        0...0x1f, '<', '>', ':', '"', '/', '\\', '|', '?', '*' => return false,
        else => {},
    };
    return text[text.len - 1] != '.' and text[text.len - 1] != ' ' and text[0] != ' ';
}

/// RFC 3986's scheme: a letter, then letters, digits, `+`, `-`, `.`.
fn schemeOk(text: []const u8) bool {
    if (text.len == 0 or text.len > 64 or !std.ascii.isAlphabetic(text[0])) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// A SemVer 2.0 version, enough to tell an upgrade from a downgrade.
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// After `-`, before any `+`; empty for a release.
    pre: []const u8,

    pub fn parse(text: []const u8) ?Version {
        const core_end = std.mem.findAny(u8, text, "-+") orelse text.len;
        const build_at = std.mem.findScalar(u8, text, '+') orelse text.len;
        var parts = std.mem.splitScalar(u8, text[0..core_end], '.');
        var numbers: [3]u64 = undefined;
        for (&numbers) |*number| {
            const part = parts.next() orelse return null;
            number.* = numeric(part) orelse return null;
        }
        if (parts.next() != null) return null;
        const pre = if (core_end < build_at and text[core_end] == '-') text[core_end + 1 .. build_at] else "";
        if (core_end < build_at and pre.len == 0) return null;
        return .{ .major = numbers[0], .minor = numbers[1], .patch = numbers[2], .pre = pre };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |field| {
            const by = std.math.order(@field(a, field), @field(b, field));
            if (by != .eq) return by;
        }
        // A release is above its pre-releases.
        if (a.pre.len == 0 or b.pre.len == 0) return std.math.order(@intFromBool(a.pre.len == 0), @intFromBool(b.pre.len == 0));
        var left = std.mem.splitScalar(u8, a.pre, '.');
        var right = std.mem.splitScalar(u8, b.pre, '.');
        while (true) {
            const l = left.next() orelse return if (right.next() == null) .eq else .lt;
            const r = right.next() orelse return .gt;
            const by = if (numeric(l)) |ln| (if (numeric(r)) |rn| std.math.order(ln, rn) else .lt) else if (numeric(r) != null) .gt else std.mem.order(u8, l, r);
            if (by != .eq) return by;
        }
    }

    fn numeric(text: []const u8) ?u64 {
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }
};

/// The image in an `.ico` closest to `size` pixels, the smallest one at least that large if
/// there is one: what `CreateIconFromResourceEx` takes (PNG or DIB, as the file holds it).
/// `lepton icon` writes PNG entries from 16 to 256.
pub fn iconImage(ico: []const u8, size: u32) ?[]const u8 {
    if (ico.len < 6 or read16(ico, 0) != 0 or read16(ico, 2) != 1) return null;
    const count = read16(ico, 4);
    var best: ?[]const u8 = null;
    var best_side: u32 = 0;
    for (0..count) |index| {
        const at = 6 + index * 16;
        if (at + 16 > ico.len) return best;
        // 0 stands for 256.
        const side: u32 = if (ico[at] == 0) 256 else ico[at];
        const len = read32(ico, at + 8);
        const offset = read32(ico, at + 12);
        if (@as(u64, offset) + len > ico.len or len == 0) continue;
        const better = if (best == null)
            true
        else if (best_side >= size)
            side >= size and side < best_side
        else
            side > best_side;
        if (better) {
            best = ico[offset..][0..len];
            best_side = side;
        }
    }
    return best;
}

const testing = std.testing;

/// A zip laid out as `zip.rs` writes it (one top directory, no extra fields or comment):
/// `app/.lepton-setup` stored, `app/bin/notes.exe` deflated as one stored block. The
/// archive `zip.rs` itself writes is installed from on Windows in CI (`windows.yml`).
fn sample(allocator: std.mem.Allocator, manifest: []const u8, program: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(allocator);
    const Item = struct { name: []const u8, data: []const u8, deflate: bool };
    const items = [_]Item{
        .{ .name = "app/", .data = "", .deflate = false },
        .{ .name = "app/.lepton-setup", .data = manifest, .deflate = false },
        .{ .name = "app/bin/", .data = "", .deflate = false },
        .{ .name = "app/bin/notes.exe", .data = program, .deflate = true },
    };
    for (items) |item| {
        var packed_bytes: std.ArrayList(u8) = .empty;
        defer packed_bytes.deinit(allocator);
        if (item.deflate) {
            // Stored deflate blocks: BFINAL=1, BTYPE=00, LEN, NLEN, the bytes.
            try packed_bytes.append(allocator, 1);
            const len: u16 = @intCast(item.data.len);
            try packed_bytes.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, len)));
            try packed_bytes.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~len)));
            try packed_bytes.appendSlice(allocator, item.data);
        } else try packed_bytes.appendSlice(allocator, item.data);
        const offset: u32 = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(item.data);
        const method: u16 = if (item.deflate) deflated else stored;
        try put(allocator, &out, &.{ 0x04034b50, 20, 0, method, 0, 0, crc, packed_bytes.items.len, item.data.len, item.name.len, 0 }, &.{ 4, 2, 2, 2, 2, 2, 4, 4, 4, 2, 2 });
        try out.appendSlice(allocator, item.name);
        try out.appendSlice(allocator, packed_bytes.items);
        try put(allocator, &central, &.{ 0x02014b50, 0x31e, 20, 0, method, 0, 0, crc, packed_bytes.items.len, item.data.len, item.name.len, 0, 0, 0, 0, 0, offset }, &.{ 4, 2, 2, 2, 2, 2, 2, 4, 4, 4, 2, 2, 2, 2, 2, 4, 4 });
        try central.appendSlice(allocator, item.name);
    }
    const central_at = out.items.len;
    try out.appendSlice(allocator, central.items);
    try put(allocator, &out, &.{ 0x06054b50, 0, 0, items.len, items.len, central.items.len, central_at, 0 }, &.{ 4, 2, 2, 2, 2, 4, 4, 2 });
    return out.toOwnedSlice(allocator);
}

fn put(allocator: std.mem.Allocator, out: *std.ArrayList(u8), values: []const u64, sizes: []const u8) !void {
    for (values, sizes) |value, size| switch (size) {
        2 => try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(value)))),
        4 => try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(value)))),
        else => unreachable,
    };
}

const sample_manifest = "identifier=dev.example.notes\nproduct=Notes\nversion=1.2.0-beta.3\npublisher=Example\nprogram=bin/notes.exe\nscheme=notes\nscheme=notes-dev\n";

test "the zip after the program is found, its names below the top directory" {
    const zip = try sample(testing.allocator, sample_manifest, "MZ the program");
    defer testing.allocator.free(zip);
    const stub = "MZ setup's own program, any length";
    const whole = try std.mem.concat(testing.allocator, u8, &.{ stub, zip });
    defer testing.allocator.free(whole);

    const archive = try Archive.open(whole);
    try testing.expectEqual(stub.len, archive.base);
    try testing.expectEqualStrings("app/", archive.top);
    var names: [3][]const u8 = undefined;
    var count: usize = 0;
    var entries = archive.iterator();
    while (try entries.next()) |entry| : (count += 1) names[count] = entry.name;
    try testing.expectEqual(3, count);
    try testing.expectEqualStrings(".lepton-setup", names[0]);
    try testing.expectEqualStrings("bin", names[1]);
    try testing.expectEqualStrings("bin/notes.exe", names[2]);

    const program = (try archive.find("bin/notes.exe")).?;
    var out: [14]u8 = undefined;
    try program.unpack(&out);
    try testing.expectEqualStrings("MZ the program", &out);
}

test "a changed byte fails the CRC" {
    const zip = try sample(testing.allocator, sample_manifest, "MZ the program");
    defer testing.allocator.free(zip);
    const at = std.mem.find(u8, zip, "MZ the program").?;
    zip[at + 3] ^= 1;
    const archive = try Archive.open(zip);
    const program = (try archive.find("bin/notes.exe")).?;
    var out: [14]u8 = undefined;
    try testing.expectError(error.CrcMismatch, program.unpack(&out));
}

test "a name that leaves the install directory is refused" {
    for ([_][]const u8{ "../x", "a/../b", "/x", "a\\b", "c:x", "a./b", "a/b ", "a//b" }) |name| {
        try testing.expectError(error.BadName, checkName(name));
    }
    try checkName("share/notes/dist/index.html");
}

test "the manifest's fields and schemes" {
    const manifest = try Manifest.parse(sample_manifest);
    try testing.expectEqualStrings("dev.example.notes", manifest.identifier);
    try testing.expectEqualStrings("Notes", manifest.product);
    try testing.expectEqualStrings("bin/notes.exe", manifest.program);
    try testing.expectEqualStrings("", manifest.icon);
    var schemes = manifest.schemes();
    try testing.expectEqualStrings("notes", schemes.next().?);
    try testing.expectEqualStrings("notes-dev", schemes.next().?);
    try testing.expectEqual(null, schemes.next());

    try testing.expectError(error.BadManifest, Manifest.parse("identifier=a\\b\nproduct=N\nversion=1.0.0\nprogram=bin/n.exe\n"));
    try testing.expectError(error.BadManifest, Manifest.parse("identifier=a\nproduct=N:\nversion=1.0.0\nprogram=bin/n.exe\n"));
    try testing.expectError(error.BadManifest, Manifest.parse("identifier=a\nproduct=N\nversion=1.0\nprogram=bin/n.exe\n"));
    try testing.expectError(error.BadManifest, Manifest.parse("identifier=a\nproduct=N\nversion=1.0.0\nprogram=../n.exe\n"));
}

test "versions order as SemVer orders them" {
    const ordered = [_][]const u8{ "0.1.9-alpha", "0.1.9-beta.2", "0.1.9-beta.3", "0.1.9-beta.11", "0.1.9-rc.1", "0.1.9", "0.2.0", "1.0.0+build.5" };
    for (ordered[0 .. ordered.len - 1], ordered[1..]) |low, high| {
        const a = Version.parse(low).?;
        const b = Version.parse(high).?;
        try testing.expectEqual(std.math.Order.lt, a.order(b));
        try testing.expectEqual(std.math.Order.gt, b.order(a));
    }
    try testing.expectEqual(std.math.Order.eq, Version.parse("1.0.0+a").?.order(Version.parse("1.0.0+b").?));
    for ([_][]const u8{ "1.0", "01.0.0", "1.0.0-", "1.0.0.0", "a.b.c" }) |bad| try testing.expectEqual(null, Version.parse(bad));
}

test "the icon image closest to the size asked for" {
    // Three entries, 16, 48 and 256 (written as 0), each one byte long.
    var ico: [6 + 3 * 16 + 3]u8 = @splat(0);
    ico[2] = 1;
    ico[4] = 3;
    for ([_]u8{ 16, 48, 0 }, 0..) |side, index| {
        const at = 6 + index * 16;
        ico[at] = side;
        ico[at + 8] = 1;
        ico[at + 12] = @intCast(54 + index);
        ico[54 + index] = @intCast(index + 1);
    }
    try testing.expectEqual(2, iconImage(&ico, 32).?[0]);
    try testing.expectEqual(2, iconImage(&ico, 48).?[0]);
    try testing.expectEqual(3, iconImage(&ico, 64).?[0]);
    try testing.expectEqual(1, iconImage(&ico, 8).?[0]);
    try testing.expectEqual(null, iconImage("not an icon", 32));
}
