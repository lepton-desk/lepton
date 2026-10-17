//! The draw command list every GPU backend reads: one fixed 64-byte record per shape.
//!
//! The native path today paints the whole frame on the CPU and uploads it as a texture
//! every frame (`gpu/gl_renderer.zig`): 1200×800 is 3.84 MB per frame. Here a frame is a
//! list of shapes — rectangles with rounded corners and borders, and soft shadows — that
//! the GPU draws itself, in one instanced draw, from a signed distance in the fragment
//! shader. What crosses to the GPU per frame is `instances.len * 64` bytes.
//!
//! The record is backend-neutral: GLES 3 (`gpu/gles3.zig`) reads it as per-instance vertex
//! attributes, and the Vulkan path will bind the same bytes as an instance buffer. Images
//! and glyphs (the atlas) join as new `Kind`s with the same layout.
//!
//! Coordinates are pixels, origin top left. Colours are straight (not premultiplied)
//! RGBA in 0..1; the shader premultiplies.

const std = @import("std");

pub const Kind = enum(u32) {
    /// A filled rectangle; `radius` rounds its corners, `border` draws a band inside its
    /// edge in `border_colour`.
    rect = 0,
    /// A soft shadow of a rounded rectangle: opaque inside, fading over `blur` pixels
    /// either side of the edge.
    shadow = 1,
    /// A glyph from the atlas (`atlas.zig`): `fill` tinted by the atlas coverage at the
    /// rectangle `border_colour` holds as u0, v0, u1, v1.
    glyph = 2,
};

pub const Colour = [4]f32;

/// `0xRRGGBBAA` as a colour.
pub fn rgba(hex: u32) Colour {
    return .{
        @as(f32, @floatFromInt((hex >> 24) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((hex >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xff)) / 255.0,
    };
}

/// One shape, as the GPU reads it. `extern` so its layout is the attribute layout.
pub const Instance = extern struct {
    /// x, y, width, height.
    rect: [4]f32,
    fill: Colour,
    /// For a glyph, the atlas rectangle u0, v0, u1, v1 instead.
    border_colour: Colour,
    /// radius, border width, blur, kind.
    params: [4]f32,
};

comptime {
    // The layout the shaders and attribute pointers are written for.
    std.debug.assert(@sizeOf(Instance) == 64);
    std.debug.assert(@offsetOf(Instance, "fill") == 16);
    std.debug.assert(@offsetOf(Instance, "border_colour") == 32);
    std.debug.assert(@offsetOf(Instance, "params") == 48);
}

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Box = struct {
    fill: Colour,
    radius: f32 = 0,
    border: f32 = 0,
    border_colour: Colour = .{ 0, 0, 0, 0 },
};

/// A frame's shapes, drawn in order (later on top).
pub const List = struct {
    instances: std.ArrayList(Instance) = .empty,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        self.instances.deinit(allocator);
    }

    /// Empties the list for the next frame, keeping its memory.
    pub fn clear(self: *List) void {
        self.instances.clearRetainingCapacity();
    }

    /// A rectangle. A radius larger than half the shorter side is clamped to it.
    pub fn rect(self: *List, allocator: std.mem.Allocator, at: Rect, box: Box) std.mem.Allocator.Error!void {
        const radius = @min(@max(box.radius, 0), @min(at.width, at.height) / 2);
        try self.instances.append(allocator, .{
            .rect = .{ at.x, at.y, at.width, at.height },
            .fill = box.fill,
            .border_colour = box.border_colour,
            .params = .{ radius, @max(box.border, 0), 0, @floatFromInt(@intFromEnum(Kind.rect)) },
        });
    }

    /// A soft shadow of the rounded rectangle `at`, drawn before the shape it is under.
    pub fn shadow(self: *List, allocator: std.mem.Allocator, at: Rect, radius: f32, blur: f32, colour: Colour) std.mem.Allocator.Error!void {
        try self.instances.append(allocator, .{
            .rect = .{ at.x, at.y, at.width, at.height },
            .fill = colour,
            .border_colour = .{ 0, 0, 0, 0 },
            .params = .{ @min(@max(radius, 0), @min(at.width, at.height) / 2), 0, @max(blur, 0), @floatFromInt(@intFromEnum(Kind.shadow)) },
        });
    }

    /// A glyph: the atlas rectangle `uv` (u0, v0, u1, v1) drawn at `at` in `colour`.
    pub fn glyph(self: *List, allocator: std.mem.Allocator, at: Rect, uv: [4]f32, colour: Colour) std.mem.Allocator.Error!void {
        try self.instances.append(allocator, .{
            .rect = .{ at.x, at.y, at.width, at.height },
            .fill = colour,
            .border_colour = uv,
            .params = .{ 0, 0, 0, @floatFromInt(@intFromEnum(Kind.glyph)) },
        });
    }

    /// The bytes a backend uploads for this frame.
    pub fn bytes(self: *const List) []const u8 {
        return std.mem.sliceAsBytes(self.instances.items);
    }
};

test "a frame of shapes is 64 bytes a shape, whatever the window's size" {
    var list: List = .{};
    defer list.deinit(std.testing.allocator);
    try list.shadow(std.testing.allocator, .{ .x = 10, .y = 10, .width = 200, .height = 100 }, 8, 12, rgba(0x00000060));
    try list.rect(std.testing.allocator, .{ .x = 10, .y = 10, .width = 200, .height = 100 }, .{
        .fill = rgba(0xffffffff),
        .radius = 8,
        .border = 1,
        .border_colour = rgba(0xd0d0d0ff),
    });
    try std.testing.expectEqual(@as(usize, 128), list.bytes().len);
    try std.testing.expectEqual(@as(f32, 1), list.instances.items[0].params[3]);
    try std.testing.expectEqual(@as(f32, 0), list.instances.items[1].params[3]);
}

test "a radius past half the shorter side is clamped" {
    var list: List = .{};
    defer list.deinit(std.testing.allocator);
    try list.rect(std.testing.allocator, .{ .x = 0, .y = 0, .width = 40, .height = 20 }, .{ .fill = rgba(0xff0000ff), .radius = 99 });
    try std.testing.expectEqual(@as(f32, 10), list.instances.items[0].params[0]);
}

test "hex colours become 0..1 channels" {
    const colour = rgba(0x3366ccff);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), colour[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), colour[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), colour[2], 0.001);
    try std.testing.expectEqual(@as(f32, 1), colour[3]);
}
