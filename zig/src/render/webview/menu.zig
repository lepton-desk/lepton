//! The items of a native menu the page asks for (`window.menu`): what each platform's
//! menu is built from. Pure, so both the check and the reading are tested anywhere.
//!
//! `[count u8]` then each item: `[id u16 LE][flags u8][label length u16 LE][label UTF-8]`.
//! An id is what the reply names when that item is chosen, so it is never 0 (0 is
//! "dismissed") — except for a separator, which has no id and no label.

const std = @import("std");

pub const max_items = 64;
pub const max_label = 256;

pub const Flag = struct {
    pub const separator: u8 = 1;
    pub const disabled: u8 = 2;
    pub const checked: u8 = 4;
};

pub const Item = struct {
    id: u16,
    flags: u8,
    label: []const u8,

    pub fn isSeparator(item: Item) bool {
        return item.flags & Flag.separator != 0;
    }
};

pub const Items = struct {
    bytes: []const u8,
    at: usize = 1,
    left: usize,

    pub fn next(self: *Items) ?Item {
        if (self.left == 0) return null;
        self.left -= 1;
        const id = std.mem.readInt(u16, self.bytes[self.at..][0..2], .little);
        const flags = self.bytes[self.at + 2];
        const len = std.mem.readInt(u16, self.bytes[self.at + 3 ..][0..2], .little);
        const label = self.bytes[self.at + 5 ..][0..len];
        self.at += 5 + len;
        return .{ .id = id, .flags = flags, .label = label };
    }
};

/// The items of a menu that passed [`valid`].
pub fn items(menu: []const u8) Items {
    return .{ .bytes = menu, .left = menu[0] };
}

/// Whether `menu` is a well-formed list: 1 to `max_items` items, every byte accounted
/// for, labels UTF-8 without NUL and at most `max_label` bytes, ids not 0.
pub fn valid(menu: []const u8) bool {
    if (menu.len < 1 or menu[0] == 0 or menu[0] > max_items) return false;
    var at: usize = 1;
    for (0..menu[0]) |_| {
        if (at + 5 > menu.len) return false;
        const id = std.mem.readInt(u16, menu[at..][0..2], .little);
        const flags = menu[at + 2];
        const len = std.mem.readInt(u16, menu[at + 3 ..][0..2], .little);
        at += 5;
        if (len > max_label or at + len > menu.len) return false;
        const label = menu[at..][0..len];
        at += len;
        if (flags & ~(Flag.separator | Flag.disabled | Flag.checked) != 0) return false;
        if (flags & Flag.separator != 0) {
            if (id != 0 or len != 0) return false;
            continue;
        }
        if (id == 0 or len == 0) return false;
        if (std.mem.indexOfScalar(u8, label, 0) != null or !std.unicode.utf8ValidateSlice(label)) return false;
    }
    return at == menu.len;
}

fn put(out: []u8, at: *usize, id: u16, flags: u8, label: []const u8) void {
    std.mem.writeInt(u16, out[at.*..][0..2], id, .little);
    out[at.* + 2] = flags;
    std.mem.writeInt(u16, out[at.* + 3 ..][0..2], @intCast(label.len), .little);
    @memcpy(out[at.* + 5 ..][0..label.len], label);
    at.* += 5 + label.len;
}

test "a menu is read back as it was written, separators included" {
    var bytes: [128]u8 = undefined;
    bytes[0] = 3;
    var at: usize = 1;
    put(&bytes, &at, 7, 0, "Kopyala");
    put(&bytes, &at, 0, Flag.separator, "");
    put(&bytes, &at, 9, Flag.disabled | Flag.checked, "Satır sonu: ✓");
    try std.testing.expect(valid(bytes[0..at]));
    var each = items(bytes[0..at]);
    const first = each.next() orelse return error.Missing;
    try std.testing.expectEqual(@as(u16, 7), first.id);
    try std.testing.expectEqualStrings("Kopyala", first.label);
    try std.testing.expect((each.next() orelse return error.Missing).isSeparator());
    const third = each.next() orelse return error.Missing;
    try std.testing.expectEqual(Flag.disabled | Flag.checked, third.flags);
    try std.testing.expect(each.next() == null);
}

test "a malformed menu is refused" {
    var bytes: [64]u8 = undefined;
    var at: usize = 1;
    bytes[0] = 1;
    put(&bytes, &at, 0, 0, "kimliksiz");
    try std.testing.expect(!valid(bytes[0..at])); // id 0 is "dismissed"
    at = 1;
    put(&bytes, &at, 3, 0, "fazla");
    try std.testing.expect(!valid(bytes[0 .. at - 1])); // cut short
    bytes[at] = 0;
    try std.testing.expect(!valid(bytes[0 .. at + 1])); // a byte too many
    at = 1;
    put(&bytes, &at, 3, 8, "bilinmeyen bayrak");
    try std.testing.expect(!valid(bytes[0..at]));
    at = 1;
    put(&bytes, &at, 3, 0, "a\x00b");
    try std.testing.expect(!valid(bytes[0..at]));
    try std.testing.expect(!valid(&.{0}));
    try std.testing.expect(!valid(&.{}));
}
