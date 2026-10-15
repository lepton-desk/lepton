//! Tests for the window contract.
//!
//! These check the parts of the layer that are pure arithmetic and policy:
//! stride rounding, pixel word order, and the empty-size case. They do not open a
//! window, because opening one requires a display server and a compositor, and a
//! test that passes on a headless host while failing on a desktop is worse than
//! no test. The real backend tests live beside their backends and run against
//! whatever the machine actually has.

const std = @import("std");
const testing = std.testing;
const window = @import("window.zig");

test "a stride is rounded up so rows stay aligned" {
    const size: window.Size = .{ .width = 3, .height = 2 };

    // 3 pixels at 4 bytes is 12 bytes, which is already a multiple of 4.
    try testing.expectEqual(@as(usize, 12), size.stride(.argb8888));
    try testing.expectEqual(@as(usize, 24), size.frameBytes(.argb8888));

    // A width whose byte count is not aligned rounds up, and the frame size follows
    // the stride rather than the raw width — the bug this guards is a framebuffer
    // whose second row starts at the wrong offset.
    const odd: window.Size = .{ .width = 5, .height = 3 };
    try testing.expectEqual(@as(usize, 20), odd.stride(.argb8888));
    try testing.expectEqual(@as(usize, 60), odd.frameBytes(.argb8888));
}

test "both formats are four bytes and both report the same layout" {
    try testing.expectEqual(@as(usize, 4), window.PixelFormat.argb8888.bytesPerPixel());
    try testing.expectEqual(@as(usize, 4), window.PixelFormat.xrgb8888.bytesPerPixel());

    // A size in one format occupies exactly as many bytes in the other, so a
    // backend can switch formats without reallocating.
    const size: window.Size = .{ .width = 37, .height = 11 };
    try testing.expectEqual(
        size.frameBytes(.argb8888),
        size.frameBytes(.xrgb8888),
    );
}

test "a pixel word puts its channels in the order a little-endian server expects" {
    // The constant is written as 0xAARRGGBB and stored little-endian, so the byte
    // at offset 0 is blue. Getting this backwards produces a window that is
    // magenta instead of the colour that was written.
    const argb = window.PixelFormat.argb8888.pixelWord();
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, argb, .little);

    try testing.expectEqual(@as(u8, 0xBB), bytes[0]); // blue
    try testing.expectEqual(@as(u8, 0x88), bytes[1]); // green
    try testing.expectEqual(@as(u8, 0x88), bytes[2]); // red
    try testing.expectEqual(@as(u8, 0xFF), bytes[3]); // alpha

    // The opaque format leaves the top byte at zero, which is what tells the
    // server the window has no transparency to blend.
    const xrgb = window.PixelFormat.xrgb8888.pixelWord();
    std.mem.writeInt(u32, &bytes, xrgb, .little);
    try testing.expectEqual(@as(u8, 0x00), bytes[3]);
    try testing.expectEqual(@as(u8, 0xBB), bytes[0]);
}

test "an empty size is recognised rather than allocated" {
    try testing.expect((window.Size{ .width = 0, .height = 600 }).isEmpty());
    try testing.expect((window.Size{ .width = 600, .height = 0 }).isEmpty());
    try testing.expect(!(window.Size{ .width = 1, .height = 1 }).isEmpty());
}

test "the default request describes a real window" {
    const request: window.Request = .{};
    try testing.expect(!request.size.isEmpty());
    try testing.expect(request.title.len > 0);
    try testing.expect(request.app_id.len > 0);
    // A framebuffer must be allocatable from the default request.
    try testing.expect(request.size.frameBytes(request.format) > 0);
}
