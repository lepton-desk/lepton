//! Choosing the window's size inside what the compositor says will fit.
//!
//! `xdg_toplevel.configure_bounds` (xdg-shell v4) is the compositor telling the client
//! how much of the output a window can occupy — the work area, minus panels. A
//! configure of 0x0 then hands the choice to the client. A client that ignores the
//! bounds and keeps its requested size opens a window larger than the screen:
//! measured on a 1366x768 COSMIC desktop, a 1200x800 request put the titlebar's
//! controls past the right edge, and the window could be neither closed nor moved.
//!
//! Pure functions, so the rule is tested without a compositor and the protocol
//! handlers stay a thin layer over it.

const std = @import("std");
const window = @import("../window.zig");

pub const Size = window.Size;

/// The bounds last announced, per axis. Zero on an axis means the compositor does not
/// know (the spec's wording), which is not the same as "no room".
pub const Bounds = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn fromWire(width: i32, height: i32) Bounds {
        return .{
            .width = if (width > 0) @intCast(width) else 0,
            .height = if (height > 0) @intCast(height) else 0,
        };
    }
};

/// The size to use when the compositor leaves the choice to the client.
///
/// Each axis is clamped on its own: shrinking a too-tall window must not also narrow
/// a width that already fits. An axis with unknown bounds keeps the request.
pub fn fit(requested: Size, bounds: Bounds) Size {
    return .{
        .width = clampAxis(requested.width, bounds.width),
        .height = clampAxis(requested.height, bounds.height),
    };
}

fn clampAxis(requested: u32, bound: u32) u32 {
    if (bound == 0) return requested;
    return @min(requested, bound);
}

test "a window larger than the work area is shrunk to it" {
    // The measured case: 1200x800 requested on a 1366x768 screen with panels.
    const fitted = fit(.{ .width = 1200, .height = 800 }, .{ .width = 1366, .height = 666 });
    try std.testing.expectEqual(Size{ .width = 1200, .height = 666 }, fitted);
}

test "a window that fits keeps the size it asked for" {
    const fitted = fit(.{ .width = 800, .height = 600 }, .{ .width = 1920, .height = 1040 });
    try std.testing.expectEqual(Size{ .width = 800, .height = 600 }, fitted);
}

test "unknown bounds leave the request alone" {
    // Before v4, or a compositor that does not know the output yet, sends nothing or
    // zeros: the request is then the best information there is.
    const fitted = fit(.{ .width = 1200, .height = 800 }, .{});
    try std.testing.expectEqual(Size{ .width = 1200, .height = 800 }, fitted);
}

test "negative wire bounds read as unknown, not as a huge u32" {
    const bounds = Bounds.fromWire(-1, 700);
    try std.testing.expectEqual(@as(u32, 0), bounds.width);
    try std.testing.expectEqual(Size{ .width = 1200, .height = 700 }, fit(.{ .width = 1200, .height = 800 }, bounds));
}
