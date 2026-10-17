//! The glyph atlas: one coverage texture every glyph of a frame is drawn from.
//!
//! A glyph is rasterised once (`glyph_text.zig`, FreeType) into a free spot here and stays; a
//! frame that shows the same text again uploads nothing. Spots are packed in shelves —
//! rows as tall as their tallest glyph — with a pixel of space around each so linear
//! sampling never bleeds a neighbour in. What changed since the last upload is kept as one
//! rectangle (`takeDirty`), which a backend sends with one sub-image upload.
//!
//! Pure memory, no GPU and no FreeType, so packing is tested anywhere.

const std = @import("std");

/// Side of the square atlas, in pixels: 1 MiB of coverage, room for thousands of glyphs
/// at UI sizes.
pub const side = 1024;
const gap = 1;

pub const Key = struct {
    font: u32,
    glyph: u32,
    /// Pixel size the glyph was rasterised at.
    size: u32,
};

pub const Slot = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    /// From the pen position to the bitmap's left edge, and up to its top edge.
    left: i16,
    top: i16,

    /// u0, v0, u1, v1 in 0..1.
    pub fn uv(self: Slot) [4]f32 {
        const s: f32 = side;
        return .{
            @as(f32, @floatFromInt(self.x)) / s,
            @as(f32, @floatFromInt(self.y)) / s,
            @as(f32, @floatFromInt(@as(u32, self.x) + self.width)) / s,
            @as(f32, @floatFromInt(@as(u32, self.y) + self.height)) / s,
        };
    }
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Atlas = struct {
    /// Row-major coverage, `side * side` bytes, top row first.
    pixels: []u8,
    slots: std.AutoHashMapUnmanaged(Key, Slot) = .empty,
    shelf_x: u32 = gap,
    shelf_y: u32 = gap,
    shelf_height: u32 = 0,
    dirty: ?Region = null,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Atlas {
        const pixels = try allocator.alloc(u8, side * side);
        @memset(pixels, 0);
        return .{ .pixels = pixels };
    }

    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        allocator.free(self.pixels);
    }

    pub fn find(self: *const Atlas, key: Key) ?Slot {
        return self.slots.get(key);
    }

    /// Copies a `width`×`height` coverage bitmap (`pitch` bytes a row) into a free spot
    /// and remembers it under `key`. Null when the atlas is full.
    pub fn put(
        self: *Atlas,
        allocator: std.mem.Allocator,
        key: Key,
        width: u32,
        height: u32,
        pitch: usize,
        bitmap: []const u8,
        left: i32,
        top: i32,
    ) std.mem.Allocator.Error!?Slot {
        if (width + 2 * gap > side or height + 2 * gap > side) return null;
        if (self.shelf_x + width + gap > side) {
            self.shelf_y += self.shelf_height + gap;
            self.shelf_x = gap;
            self.shelf_height = 0;
        }
        if (self.shelf_y + height + gap > side) return null;
        const x = self.shelf_x;
        const y = self.shelf_y;
        for (0..height) |row| {
            const from = bitmap[row * pitch ..][0..width];
            @memcpy(self.pixels[(y + row) * side + x ..][0..width], from);
        }
        self.shelf_x += width + gap;
        self.shelf_height = @max(self.shelf_height, height);
        self.markDirty(.{ .x = x, .y = y, .width = width, .height = height });

        const slot: Slot = .{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(width),
            .height = @intCast(height),
            .left = @intCast(left),
            .top = @intCast(top),
        };
        try self.slots.put(allocator, key, slot);
        return slot;
    }

    fn markDirty(self: *Atlas, region: Region) void {
        if (region.width == 0 or region.height == 0) return;
        const old = self.dirty orelse {
            self.dirty = region;
            return;
        };
        const x0 = @min(old.x, region.x);
        const y0 = @min(old.y, region.y);
        const x1 = @max(old.x + old.width, region.x + region.width);
        const y1 = @max(old.y + old.height, region.y + region.height);
        self.dirty = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }

    /// What changed since the last call, to upload; null when nothing did.
    pub fn takeDirty(self: *Atlas) ?Region {
        defer self.dirty = null;
        return self.dirty;
    }
};

fn solid(buffer: []u8, value: u8) []const u8 {
    @memset(buffer, value);
    return buffer;
}

test "glyphs never overlap and keep a gap" {
    var atlas = try Atlas.init(std.testing.allocator);
    defer atlas.deinit(std.testing.allocator);
    var bitmap: [40 * 30]u8 = undefined;
    var placed: [200]Slot = undefined;
    for (&placed, 0..) |*slot, index| {
        const w: u32 = 10 + @as(u32, @intCast(index % 30));
        const h: u32 = 8 + @as(u32, @intCast(index % 22));
        slot.* = (try atlas.put(std.testing.allocator, .{ .font = 0, .glyph = @intCast(index), .size = 14 }, w, h, w, solid(bitmap[0 .. w * h], 1), 0, 0)).?;
    }
    for (placed, 0..) |a, i| {
        for (placed[i + 1 ..]) |b| {
            const apart = @as(u32, a.x) + a.width + gap <= b.x or @as(u32, b.x) + b.width + gap <= a.x or
                @as(u32, a.y) + a.height + gap <= b.y or @as(u32, b.y) + b.height + gap <= a.y;
            try std.testing.expect(apart);
        }
    }
}

test "a glyph's bytes land at its slot and mark that region dirty" {
    var atlas = try Atlas.init(std.testing.allocator);
    defer atlas.deinit(std.testing.allocator);
    const bitmap = [_]u8{ 1, 2, 3, 0xff, 4, 5, 6, 0xff }; // 3×2, pitch 4
    const slot = (try atlas.put(std.testing.allocator, .{ .font = 1, .glyph = 7, .size = 12 }, 3, 2, 4, &bitmap, 1, 9)).?;
    try std.testing.expectEqual(@as(u8, 5), atlas.pixels[(@as(usize, slot.y) + 1) * side + slot.x + 1]);
    try std.testing.expectEqual(slot, atlas.find(.{ .font = 1, .glyph = 7, .size = 12 }).?);
    const dirty = atlas.takeDirty().?;
    try std.testing.expectEqual(Region{ .x = slot.x, .y = slot.y, .width = 3, .height = 2 }, dirty);
    try std.testing.expectEqual(@as(?Region, null), atlas.takeDirty());
}

test "a full atlas says so instead of overwriting" {
    var atlas = try Atlas.init(std.testing.allocator);
    defer atlas.deinit(std.testing.allocator);
    const big = try std.testing.allocator.alloc(u8, 500 * 500);
    defer std.testing.allocator.free(big);
    @memset(big, 0);
    var fitted: u32 = 0;
    for (0..10) |index| {
        if (try atlas.put(std.testing.allocator, .{ .font = 0, .glyph = @intCast(index), .size = 1 }, 500, 500, 500, big, 0, 0) != null) fitted += 1;
    }
    try std.testing.expectEqual(@as(u32, 4), fitted);
}
