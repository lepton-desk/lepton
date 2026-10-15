//! Tests for the frame the render layer draws into.
//!
//! Real buffers in the testing allocator, and real writes: the failure this guards is
//! a heap overflow, and a mock frame that is smaller than the code thinks it is would
//! hide exactly that.

const std = @import("std");
const surface = @import("surface.zig");
const window = @import("../window/window.zig");

const Surface = surface.Surface;
const Colour = surface.Colour;

test "a surface is exactly as large as one frame of its size" {
    const size = window.Size{ .width = 320, .height = 200 };
    var frame = try Surface.init(std.testing.allocator, size, .argb8888);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 320 * 4 * 200), frame.pixels.len);
    try std.testing.expectEqual(size, frame.size);
    try std.testing.expectEqual(@as(usize, 320 * 4), frame.stride);
}

test "a zero dimension is refused rather than allocating nothing" {
    // A window reports zero while a compositor is still deciding its size. Allocating
    // for that would produce a frame nothing can be drawn into, and the first write
    // would be out of bounds.
    const zero_sized = [_]window.Size{
        .{ .width = 0, .height = 200 },
        .{ .width = 320, .height = 0 },
        .{ .width = 0, .height = 0 },
    };

    for (zero_sized) |size| {
        const outcome = Surface.init(std.testing.allocator, size, .argb8888);
        try std.testing.expectError(surface.Error.InvalidSize, outcome);
    }
}

test "an opaque format still occupies four bytes a pixel" {
    // Both formats are 32-bit. A 24-bit "optimisation" would make the stride a
    // function of the format and every offset calculation a second opinion.
    try std.testing.expectEqual(@as(usize, 4), window.PixelFormat.xrgb8888.bytesPerPixel());
    try std.testing.expectEqual(@as(usize, 4), window.PixelFormat.argb8888.bytesPerPixel());
}

test "a stride is rounded up to the format's alignment" {
    // A width that is not a multiple of the alignment is the normal case, not an edge
    // case: any odd window width produces one.
    const size = window.Size{ .width = 101, .height = 3 };

    try std.testing.expectEqual(@as(usize, 404), size.stride(.argb8888));
    try std.testing.expectEqual(@as(usize, 404 * 3), size.frameBytes(.argb8888));
}

test "a pixel written is the pixel read back" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 8, .height = 4 }, .argb8888);
    defer frame.deinit();

    const wanted = Colour.rgb(0x12, 0x34, 0x56);
    try frame.setPixel(3, 2, wanted);

    const read = frame.pixelAt(3, 2) orelse return error.MissingPixel;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56 }, &[_]u8{ read.r, read.g, read.b });
    try std.testing.expectEqual(@as(u8, 0xFF), read.a);
}

test "a pixel outside the frame has no offset and no value" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 4, .height = 4 }, .argb8888);
    defer frame.deinit();

    try std.testing.expect(frame.offsetOf(4, 0) == null);
    try std.testing.expect(frame.offsetOf(0, 4) == null);
    try std.testing.expect(frame.pixelAt(9, 9) == null);

    // And the last pixel inside is exactly one pixel before the end.
    const last = frame.offsetOf(3, 3) orelse return error.MissingOffset;
    try std.testing.expectEqual(frame.pixels.len - 4, last);
}

test "writing outside the frame is refused rather than truncating a pointer" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 4, .height = 4 }, .argb8888);
    defer frame.deinit();

    // Coordinates are unsigned, so the only way out is past an edge — which is
    // exactly the way a panel's rectangle arithmetic goes wrong.
    try std.testing.expectError(surface.Error.InvalidSize, frame.setPixel(4, 0, Colour.rgb(1, 2, 3)));
    try std.testing.expectError(surface.Error.InvalidSize, frame.setPixel(0, 4, Colour.rgb(1, 2, 3)));
    try std.testing.expectError(
        surface.Error.InvalidSize,
        frame.setPixel(std.math.maxInt(u32), std.math.maxInt(u32), Colour.rgb(1, 2, 3)),
    );
}

test "fill covers every pixel of the frame" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 5, .height = 3 }, .argb8888);
    defer frame.deinit();

    const bed = Colour.rgb(0x14, 0x18, 0x1C);
    frame.fill(bed);

    // Every pixel, not a sample: a fill that missed a row would show as a band of the
    // initial state, and the initial state is whatever was in the reused buffer.
    for (0..5) |x| {
        for (0..3) |y| {
            const read = frame.pixelAt(@intCast(x), @intCast(y)) orelse return error.MissingPixel;
            try std.testing.expectEqualSlices(
                u8,
                &[_]u8{ 0x14, 0x18, 0x1C },
                &[_]u8{ read.r, read.g, read.b },
            );
        }
    }
}

test "a fill covers the whole buffer and no more" {
    // With the 32-bit formats this layer supports there is never stride padding, so
    // the buffer is exactly the frame. That is worth asserting: a format with a wider
    // alignment would make the two differ, and a fill that assumed they were the same
    // would paint past the last pixel rather than under one.
    var frame = try Surface.init(std.testing.allocator, .{ .width = 5, .height = 4 }, .argb8888);
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 5 * 4), frame.stride);
    try std.testing.expectEqual(frame.stride * 4, frame.pixels.len);

    @memset(frame.pixels, 0xEE);
    frame.fill(Colour.rgb(0x10, 0x20, 0x30));

    // Every byte of the buffer, including the alpha bytes the fill writes. The order
    // within a pixel is blue, green, red, alpha: the word is stored little-endian and
    // the display server reads it in that order, which `PixelFormat.pixelWord`
    // documents. Asserted byte by byte rather than word by word because the word is
    // what the code writes and the bytes are what the server receives.
    for (frame.pixels, 0..) |byte, index| {
        const wanted: u8 = switch (index % 4) {
            0 => 0x30,
            1 => 0x20,
            2 => 0x10,
            else => 0xFF,
        };
        try std.testing.expectEqualSlices(u8, &[_]u8{wanted}, &[_]u8{byte});
    }
}

test "a rectangle is clipped to the frame on every side" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 10, .height = 10 }, .argb8888);
    defer frame.deinit();

    // Starts left of and above, ends right of and below: the clip has to handle all
    // four at once, which is the case a panel running off a resized window produces.
    const clipped = surface.clip(frame, -4, -6, 8, 9) orelse return error.NotClipped;

    try std.testing.expectEqual(@as(u32, 0), clipped.x);
    try std.testing.expectEqual(@as(u32, 0), clipped.y);
    try std.testing.expectEqual(@as(u32, 4), clipped.width);
    try std.testing.expectEqual(@as(u32, 3), clipped.height);
}

test "a rectangle entirely outside is dropped rather than clamped to the edge" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 10, .height = 10 }, .argb8888);
    defer frame.deinit();

    try std.testing.expect(surface.clip(frame, 20, 0, 5, 5) == null);
    try std.testing.expect(surface.clip(frame, 0, -30, 5, 5) == null);
    try std.testing.expect(surface.clip(frame, 0, 0, 0, 5) == null);
    try std.testing.expect(surface.clip(frame, 0, 0, 5, -1) == null);
}

test "a rectangle whose coordinates would overflow is clipped, not wrapped" {
    // `x + width` with both near the top of the range wraps to negative, and a naive
    // clamp would then read as "entirely off the left" and drop a rectangle that is
    // plainly on screen.
    var frame = try Surface.init(std.testing.allocator, .{ .width = 8, .height = 8 }, .argb8888);
    defer frame.deinit();

    const clipped = surface.clip(frame, 4, 4, std.math.maxInt(i32), std.math.maxInt(i32)) orelse
        return error.NotClipped;

    try std.testing.expectEqual(@as(u32, 4), clipped.width);
    try std.testing.expectEqual(@as(u32, 4), clipped.height);
}

test "a filled rectangle covers exactly the clipped area" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 6, .height = 6 }, .argb8888);
    defer frame.deinit();
    frame.fill(Colour.rgb(0, 0, 0));

    frame.fillRect(2, 2, 2, 2, Colour.rgb(0xFF, 0xFF, 0xFF));

    const inside = frame.pixelAt(2, 2) orelse return error.MissingPixel;
    const outside = frame.pixelAt(1, 2) orelse return error.MissingPixel;
    try std.testing.expectEqual(@as(u8, 0xFF), inside.r);
    try std.testing.expectEqual(@as(u8, 0x00), outside.r);
}

test "rules are one pixel thick" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 6, .height = 6 }, .argb8888);
    defer frame.deinit();
    frame.fill(Colour.rgb(0, 0, 0));

    frame.hLine(0, 1, 6, Colour.rgb(0xFF, 0xFF, 0xFF));
    frame.vLine(1, 0, 6, Colour.rgb(0xFF, 0xFF, 0xFF));

    const on_rule = frame.pixelAt(5, 1) orelse return error.MissingPixel;
    const beside_rule = frame.pixelAt(5, 2) orelse return error.MissingPixel;
    try std.testing.expectEqual(@as(u8, 0xFF), on_rule.r);
    try std.testing.expectEqual(@as(u8, 0x00), beside_rule.r);
}

test "a stroke draws four edges and leaves the inside alone" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 5, .height = 5 }, .argb8888);
    defer frame.deinit();
    frame.fill(Colour.rgb(0, 0, 0));

    frame.strokeRect(0, 0, 5, 5, Colour.rgb(0xFF, 0xFF, 0xFF));

    for ([_][2]u32{
        .{ 0, 0 },
        .{ 4, 0 },
        .{ 0, 4 },
        .{ 4, 4 },
    }) |corner| {
        const pixel = frame.pixelAt(corner[0], corner[1]) orelse return error.MissingPixel;
        try std.testing.expectEqual(@as(u8, 0xFF), pixel.r);
    }

    const middle = frame.pixelAt(2, 2) orelse return error.MissingPixel;
    try std.testing.expectEqual(@as(u8, 0x00), middle.r);
}

test "a resize that fits keeps the same allocation" {
    // A window being dragged sends a configure every frame. Reallocating per frame
    // would put the allocator back on the path between an event and a pixel.
    var frame = try Surface.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .argb8888);
    defer frame.deinit();

    const before = frame.pixels.ptr;

    try frame.resize(.{ .width = 50, .height = 50 });

    try std.testing.expectEqual(before, frame.pixels.ptr);

    // The buffer is not shrunk either. Shrinking would mean reallocating on the way
    // back up, which is the churn the reuse was for: a window dragged smaller and
    // then larger again would allocate on every frame.
    try std.testing.expectEqual(@as(usize, 100 * 4 * 100), frame.pixels.len);
    try std.testing.expectEqual(@as(usize, 50 * 4), frame.stride);
    try std.testing.expectEqual(@as(u32, 50), frame.size.width);

    // And the frame it describes still fits inside the buffer it kept.
    const corner = frame.offsetOf(49, 49) orelse return error.MissingOffset;
    try std.testing.expect(corner + 4 <= frame.pixels.len);
}

test "a resize that does not fit reallocates and still holds a whole frame" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 10, .height = 10 }, .argb8888);
    defer frame.deinit();

    try frame.resize(.{ .width = 40, .height = 30 });

    try std.testing.expectEqual(@as(usize, 40 * 4 * 30), frame.pixels.len);
    // The far corner has to be inside the new buffer, which is the assertion that
    // matters: a length right and a stride wrong would still pass a length check.
    const corner = frame.offsetOf(39, 29) orelse return error.MissingOffset;
    try std.testing.expect(corner + 4 <= frame.pixels.len);
}

test "a resize to nothing is refused and leaves the surface as it was" {
    var frame = try Surface.init(std.testing.allocator, .{ .width = 10, .height = 10 }, .argb8888);
    defer frame.deinit();

    try std.testing.expectError(
        surface.Error.InvalidSize,
        frame.resize(.{ .width = 0, .height = 10 }),
    );
    try std.testing.expectEqual(@as(u32, 10), frame.size.width);
}

test "an opaque colour packs a zero alpha byte and an argb one packs its alpha" {
    // The server reads a zero alpha as "nothing to blend". A window written as opaque
    // but reported translucent gets composited for no reason.
    const solid = Colour.rgb(0x11, 0x22, 0x33);

    const opaque_word = solid.toWord(.xrgb8888);
    try std.testing.expectEqual(@as(u32, 0x00), opaque_word >> 24);
    try std.testing.expectEqual(@as(u32, 0x11), (opaque_word >> 16) & 0xFF);

    const translucent_word = solid.toWord(.argb8888);
    try std.testing.expectEqual(@as(u32, 0xFF), translucent_word >> 24);
}

test "a colour survives a round trip through both formats" {
    inline for ([_]window.PixelFormat{ .argb8888, .xrgb8888 }) |format| {
        const wanted = Colour.rgba(0x40, 0x50, 0x60, 0xFF);
        const read = Colour.fromWord(wanted.toWord(format), format);

        try std.testing.expectEqual(wanted.r, read.r);
        try std.testing.expectEqual(wanted.g, read.g);
        try std.testing.expectEqual(wanted.b, read.b);
    }
}

test "an alpha of zero survives the argb round trip and is lost on xrgb" {
    // Both halves are intended: the first is the format that carries alpha, the
    // second is the format that deliberately does not.
    const clear = Colour.rgba(0x40, 0x50, 0x60, 0x00);

    const kept = Colour.fromWord(clear.toWord(.argb8888), .argb8888);
    try std.testing.expectEqual(@as(u8, 0x00), kept.a);

    const dropped = Colour.fromWord(clear.toWord(.xrgb8888), .xrgb8888);
    try std.testing.expectEqual(@as(u8, 0xFF), dropped.a);
}
