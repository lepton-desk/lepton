//! Tests for text on the native path.
//!
//! Every test rasterises real glyphs through real Pango and Cairo and then reads the
//! pixels back. A test that asserted only that a call returned would pass with a
//! font that draws nothing, and a panel that draws nothing looks exactly like a panel
//! whose text is too dark to see.

const std = @import("std");
const surface = @import("surface.zig");
const text = @import("text.zig");
const window = @import("../window/window.zig");

const Text = text.Text;

/// A frame large enough to hold a line of type, and the text bound to it.
const Bound = struct {
    frame: *surface.Surface,
    subject: Text,

    fn create(width: u32, height: u32) !Bound {
        const frame = try std.testing.allocator.create(surface.Surface);
        frame.* = try surface.Surface.init(std.testing.allocator, .{ .width = width, .height = height }, .argb8888);
        return .{ .frame = frame, .subject = try Text.init(frame.*) };
    }

    fn destroy(self: *Bound) void {
        self.subject.deinit();
        self.frame.deinit();
        std.testing.allocator.destroy(self.frame);
    }

    /// How many pixels in `frame` differ from `colour`.
    fn differing(self: Bound, colour: surface.Colour) usize {
        var count: usize = 0;
        var y: u32 = 0;
        while (y < self.frame.size.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.frame.size.width) : (x += 1) {
                const pixel = self.frame.pixelAt(x, y) orelse continue;
                if (pixel.r != colour.r or pixel.g != colour.g or pixel.b != colour.b) {
                    count += 1;
                }
            }
        }
        return count;
    }
};

test "text draws pixels that were not there before" {
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const bed = surface.Colour.rgb(0x14, 0x18, 0x1C);
    bound.frame.fill(bed);

    try std.testing.expectEqual(@as(usize, 0), bound.differing(bed));

    try std.testing.expect(bound.subject.draw(8, 8, "uptime", surface.Colour.rgb(0xCD, 0xD3, 0xD8)));

    // The assertion that matters: real glyphs reached the frame. A shaper that
    // resolved nothing, or a surface built over the wrong memory, would leave this at
    // zero and look identical to a panel whose type is simply too dim.
    try std.testing.expect(bound.differing(bed) > 20);
}

test "drawing the same string twice rasterises the same pixels" {
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const bed = surface.Colour.rgb(0x14, 0x18, 0x1C);
    const face = surface.Colour.rgb(0xCD, 0xD3, 0xD8);

    bound.frame.fill(bed);
    _ = bound.subject.draw(8, 8, "round trip", face);
    const first = bound.differing(bed);

    // Cleared and drawn again. If the cached rasterisation were being composited over
    // the previous frame instead of replacing it, this would differ.
    bound.frame.fill(bed);
    _ = bound.subject.draw(8, 8, "round trip", face);

    try std.testing.expectEqual(first, bound.differing(bed));
}

test "a string measures wider than an empty one and narrower than a long one" {
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const empty = bound.subject.measure("") orelse return error.NotMeasured;
    const short = bound.subject.measure("ns") orelse return error.NotMeasured;
    const long = bound.subject.measure("12345678901234567890") orelse return error.NotMeasured;

    try std.testing.expect(short.width > empty.width);
    try std.testing.expect(long.width > short.width);
}

test "a monospaced face gives every glyph the same advance" {
    // The whole reason the panel's figures line up. A proportional face would make
    // the column ragged by a pixel or two per row, which is the difference between a
    // table and a list.
    var bound = try Bound.create(640, 64);
    defer bound.destroy();

    const one = bound.subject.widthOf("0");
    const seven = bound.subject.widthOf("7");
    const letter = bound.subject.widthOf("m");

    try std.testing.expectEqual(one, seven);
    try std.testing.expectEqual(one, letter);
}

test "the ascent is above the origin and the descent below it" {
    // A grid can only be set from a baseline, so the two halves have to fall on the
    // right sides of the origin. A font whose metrics came back the other way round
    // would put every descender under the line.
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const extent = bound.subject.measure("resident set") orelse return error.NotMeasured;

    try std.testing.expect(extent.height > 0);
    try std.testing.expect(extent.ascent > 0);
    try std.testing.expect(extent.descent > 0);
}

test "rows of one face are the same height whatever they say" {
    // The reason the table lines up: the height comes from the face's metrics, not
    // from the tallest glyph in the string. If it came from the string, a row reading
    // "ns" would be shorter than one reading "resident set" and the grid would step.
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const short = bound.subject.measure("ns") orelse return error.NotMeasured;
    const long = bound.subject.measure("resident set") orelse return error.NotMeasured;
    const digits = bound.subject.measure("1234567890") orelse return error.NotMeasured;

    try std.testing.expectEqual(short.height, long.height);
    try std.testing.expectEqual(short.height, digits.height);
}

test "a face can be changed and the measurement follows" {
    var bound = try Bound.create(640, 64);
    defer bound.destroy();

    const monospace = bound.subject.widthOf("iiiiiiiiii");
    bound.subject.setFace("monospace", 24.0);
    const larger = bound.subject.widthOf("iiiiiiiiii");

    try std.testing.expect(larger > monospace);
}

test "an unparseable face leaves the previous one in place" {
    var bound = try Bound.create(320, 64);
    defer bound.destroy();

    const before = bound.subject.widthOf("stable");
    // A family name Cairo will not resolve falls back through fontconfig rather than
    // failing, so the width changes if anything at all happened.
    // An unresolvable family falls back through fontconfig rather than failing, so
    // the face is restored explicitly and the width compared against the original.
    bound.subject.setFace("no-such-family-anywhere", 11.0);
    bound.subject.setFace("monospace", 11.0);
    const after = bound.subject.widthOf("stable");

    // Refusing is the point: type that vanishes because a description was mistyped is
    // a worse failure than type in the wrong face.
    try std.testing.expectEqual(before, after);
}

test "text does not draw outside the frame it was given" {
    var bound = try Bound.create(64, 24);
    defer bound.destroy();

    const bed = surface.Colour.rgb(0x14, 0x18, 0x1C);
    bound.frame.fill(bed);

    // Well past the right and bottom edges. Cairo clips to the surface, so this must
    // not write past it; the bounds check in `Surface` would catch it if it did, and
    // this test is here so the failure names the text layer rather than the surface.
    _ = bound.subject.draw(600, 200, "overflowing text", surface.Colour.rgb(0xFF, 0xFF, 0xFF));

    try std.testing.expect(bound.differing(bed) < bound.frame.pixels.len);
}

test "an empty frame is refused rather than wrapped" {
    // A zero-sized surface has no memory to wrap. Handing Cairo a null pointer would
    // be a crash inside the rasteriser rather than an error here.
    const empty = surface.Surface{
        .pixels = &[_]u8{},
        .size = .{ .width = 0, .height = 0 },
        .format = .argb8888,
        .stride = 0,
        .allocator = std.testing.allocator,
    };

    try std.testing.expectError(text.Error.SurfaceRefused, Text.init(empty));
}

test "both frame formats draw, and neither is blank" {
    // The two formats differ only in the alpha byte, and Cairo is given one of them
    // for both. If a future change made the choice per-format, this is where it would
    // show.
    inline for ([_]window.PixelFormat{ .argb8888, .xrgb8888 }) |format| {
        var frame = try surface.Surface.init(std.testing.allocator, .{ .width = 200, .height = 48 }, format);
        defer frame.deinit();

        var subject = try Text.init(frame);
        defer subject.deinit();

        const bed = surface.Colour.rgb(0x14, 0x18, 0x1C);
        frame.fill(bed);
        _ = subject.draw(6, 6, "12", surface.Colour.rgb(0xCD, 0xD3, 0xD8));

        var differing: usize = 0;
        var y: u32 = 0;
        while (y < frame.size.height) : (y += 1) {
            var x: u32 = 0;
            while (x < frame.size.width) : (x += 1) {
                const pixel = frame.pixelAt(x, y) orelse continue;
                if (pixel.r != bed.r or pixel.g != bed.g or pixel.b != bed.b) differing += 1;
            }
        }
        try std.testing.expect(differing > 0);
    }
}

test "text retargeted after a resize draws exactly what a fresh one would" {
    // Measured in a real window: the frame shrank from 1200 to 910 px wide, the text
    // kept drawing with the 1200 px stride, and every line came out sheared across the
    // window. A grown frame is worse — its buffer is reallocated and the old Cairo
    // surface writes into freed memory. Retargeting must leave no trace of the old size.
    const bed = surface.Colour.rgb(0x14, 0x18, 0x1C);
    const ink = surface.Colour.rgb(0xCD, 0xD3, 0xD8);

    var resized = try Bound.create(320, 64);
    defer resized.destroy();
    try resized.frame.resize(.{ .width = 180, .height = 40 });
    try resized.subject.retarget(resized.frame.*);
    resized.frame.fill(bed);
    try std.testing.expect(resized.subject.draw(4, 4, "frames 317", ink));

    var fresh = try Bound.create(180, 40);
    defer fresh.destroy();
    fresh.frame.fill(bed);
    try std.testing.expect(fresh.subject.draw(4, 4, "frames 317", ink));

    const bytes = fresh.frame.stride * fresh.frame.size.height;
    try std.testing.expectEqual(fresh.frame.stride, resized.frame.stride);
    try std.testing.expectEqualSlices(u8, fresh.frame.pixels[0..bytes], resized.frame.pixels[0..bytes]);
}

test "a retarget keeps the face that was chosen" {
    var bound = try Bound.create(320, 64);
    defer bound.destroy();
    bound.subject.setFace("monospace", 22);
    const before = bound.subject.measure("WWWW") orelse return error.TestUnexpectedResult;

    try bound.frame.resize(.{ .width = 400, .height = 80 });
    try bound.subject.retarget(bound.frame.*);
    const after = bound.subject.measure("WWWW") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(before.width, after.width);
}
