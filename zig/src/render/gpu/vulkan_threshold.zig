//! The Vulkan the native GPU renderer requires: the set the baseline card passes.
//!
//! The baseline is the user's AMD Radeon R7 240 (Oland, GCN 1.0) on RADV, measured with
//! `zig build vulkan-check`: Vulkan 1.3 with the features below. A device that misses any
//! of them gets the GLES 3 path instead (user's decision, 2026-10-18: the threshold stays
//! at this card's set rather than dropping to 1.1/1.2).
//!
//! Pure data and one function, so the decision is tested without a driver; the probe and
//! the renderer fill `Caps` from the device.

const std = @import("std");

/// Push constants the draw commands are laid out for: the baseline's `maxPushConstantsSize`.
pub const push_constant_bytes = 256;

/// What a device offers, as far as the threshold asks.
pub const Caps = struct {
    api_major: u32,
    api_minor: u32,
    dynamic_rendering: bool,
    synchronization2: bool,
    timeline_semaphore: bool,
    descriptor_indexing: bool,
    buffer_device_address: bool,
    max_push_constants: u32,
    /// `VK_KHR_swapchain`: without it nothing reaches the window.
    swapchain: bool,
};

pub const Requirement = enum {
    vulkan_1_3,
    dynamic_rendering,
    synchronization2,
    timeline_semaphore,
    descriptor_indexing,
    buffer_device_address,
    push_constants_256,
    swapchain,
};

/// The requirements `caps` misses, in `Requirement` order; empty when it qualifies.
pub fn missing(caps: Caps, out: *[@typeInfo(Requirement).@"enum".fields.len]Requirement) []const Requirement {
    var count: usize = 0;
    const checks = [_]struct { Requirement, bool }{
        .{ .vulkan_1_3, caps.api_major > 1 or (caps.api_major == 1 and caps.api_minor >= 3) },
        .{ .dynamic_rendering, caps.dynamic_rendering },
        .{ .synchronization2, caps.synchronization2 },
        .{ .timeline_semaphore, caps.timeline_semaphore },
        .{ .descriptor_indexing, caps.descriptor_indexing },
        .{ .buffer_device_address, caps.buffer_device_address },
        .{ .push_constants_256, caps.max_push_constants >= push_constant_bytes },
        .{ .swapchain, caps.swapchain },
    };
    for (checks) |check| {
        if (!check[1]) {
            out[count] = check[0];
            count += 1;
        }
    }
    return out[0..count];
}

/// The baseline's own figures (RADV OLAND, Mesa 26.2.4, measured 2026-10-18).
const r7_240: Caps = .{
    .api_major = 1,
    .api_minor = 3,
    .dynamic_rendering = true,
    .synchronization2 = true,
    .timeline_semaphore = true,
    .descriptor_indexing = true,
    .buffer_device_address = true,
    .max_push_constants = 256,
    .swapchain = true,
};

test "the baseline card qualifies" {
    var out: [8]Requirement = undefined;
    try std.testing.expectEqual(@as(usize, 0), missing(r7_240, &out).len);
}

test "a 1.2 device without dynamic rendering is named for both" {
    var older = r7_240;
    older.api_minor = 2;
    older.dynamic_rendering = false;
    older.max_push_constants = 128;
    var out: [8]Requirement = undefined;
    try std.testing.expectEqualSlices(
        Requirement,
        &.{ .vulkan_1_3, .dynamic_rendering, .push_constants_256 },
        missing(older, &out),
    );
}
