//! The page's dialog request, decoded. No core import: tested alone with
//! `zig test zig/request.zig`.
//!
//! `[flags u8][title][accept label][current name][current folder][filter count u8]
//!  { [name][pattern count u8] { [pattern] } }`, each string `[length u16 LE][UTF-8]`.

const std = @import("std");

pub const Flag = struct {
    pub const multiple: u8 = 1;
    pub const directory: u8 = 2;
};

pub const max_filters = 16;
pub const max_patterns = 16;

pub const Filter = struct {
    name: []const u8,
    patterns: []const []const u8,
};

pub const Request = struct {
    multiple: bool,
    directory: bool,
    title: []const u8,
    accept_label: []const u8,
    current_name: []const u8,
    current_folder: []const u8,
    filters: []const Filter,
};

/// Where the decoded slices live: they point into the argument, the arrays are here.
pub const Storage = struct {
    filters: [max_filters]Filter = undefined,
    patterns: [max_filters][max_patterns][]const u8 = undefined,
};

pub const Error = error{Malformed};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(reader: *Reader) Error!u8 {
        if (reader.at >= reader.bytes.len) return error.Malformed;
        reader.at += 1;
        return reader.bytes[reader.at - 1];
    }

    fn string(reader: *Reader) Error![]const u8 {
        if (reader.at + 2 > reader.bytes.len) return error.Malformed;
        const len = std.mem.readInt(u16, reader.bytes[reader.at..][0..2], .little);
        reader.at += 2;
        if (reader.at + len > reader.bytes.len) return error.Malformed;
        const text = reader.bytes[reader.at..][0..len];
        reader.at += len;
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Malformed;
        if (!std.unicode.utf8ValidateSlice(text)) return error.Malformed;
        return text;
    }
};

pub fn decode(argument: []const u8, storage: *Storage) Error!Request {
    var reader: Reader = .{ .bytes = argument };
    const flags = try reader.byte();
    const request: Request = .{
        .multiple = flags & Flag.multiple != 0,
        .directory = flags & Flag.directory != 0,
        .title = try reader.string(),
        .accept_label = try reader.string(),
        .current_name = try reader.string(),
        .current_folder = try reader.string(),
        .filters = &.{},
    };
    const filter_count = try reader.byte();
    if (filter_count > max_filters) return error.Malformed;
    for (0..filter_count) |index| {
        const name = try reader.string();
        const pattern_count = try reader.byte();
        if (pattern_count == 0 or pattern_count > max_patterns) return error.Malformed;
        for (0..pattern_count) |at| storage.patterns[index][at] = try reader.string();
        storage.filters[index] = .{ .name = name, .patterns = storage.patterns[index][0..pattern_count] };
    }
    if (reader.at != argument.len) return error.Malformed;
    if (request.current_folder.len > 0 and request.current_folder[0] != '/') return error.Malformed;
    var decoded = request;
    decoded.filters = storage.filters[0..filter_count];
    return decoded;
}

fn put(out: []u8, at: *usize, text: []const u8) void {
    std.mem.writeInt(u16, out[at.*..][0..2], @intCast(text.len), .little);
    @memcpy(out[at.* + 2 ..][0..text.len], text);
    at.* += 2 + text.len;
}

test "a request with filters decodes to what the page sent" {
    var bytes: [256]u8 = undefined;
    var at: usize = 0;
    bytes[at] = Flag.multiple;
    at += 1;
    put(&bytes, &at, "Notları aç");
    put(&bytes, &at, "");
    put(&bytes, &at, "");
    put(&bytes, &at, "/home/u/Belgeler");
    bytes[at] = 2;
    at += 1;
    put(&bytes, &at, "Metin");
    bytes[at] = 2;
    at += 1;
    put(&bytes, &at, "*.txt");
    put(&bytes, &at, "*.md");
    put(&bytes, &at, "Hepsi");
    bytes[at] = 1;
    at += 1;
    put(&bytes, &at, "*");

    var storage: Storage = .{};
    const request = try decode(bytes[0..at], &storage);
    try std.testing.expect(request.multiple and !request.directory);
    try std.testing.expectEqualStrings("Notları aç", request.title);
    try std.testing.expectEqualStrings("/home/u/Belgeler", request.current_folder);
    try std.testing.expectEqual(@as(usize, 2), request.filters.len);
    try std.testing.expectEqualStrings("Metin", request.filters[0].name);
    try std.testing.expectEqualStrings("*.md", request.filters[0].patterns[1]);
    try std.testing.expectEqualStrings("*", request.filters[1].patterns[0]);

    // Short, trailing bytes, a relative folder, a filter with no pattern: all refused.
    try std.testing.expectError(error.Malformed, decode(bytes[0 .. at - 1], &storage));
    var longer: [257]u8 = undefined;
    @memcpy(longer[0..at], bytes[0..at]);
    longer[at] = 0;
    try std.testing.expectError(error.Malformed, decode(longer[0 .. at + 1], &storage));
    var relative: [64]u8 = undefined;
    var used: usize = 0;
    relative[used] = 0;
    used += 1;
    put(&relative, &used, "");
    put(&relative, &used, "");
    put(&relative, &used, "");
    put(&relative, &used, "Belgeler");
    relative[used] = 0;
    used += 1;
    try std.testing.expectError(error.Malformed, decode(relative[0..used], &storage));
}
