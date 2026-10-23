//! The Vulkan backend (`render/gpu/vulkan.zig`) measured as `windows-gpu-check` measures the
//! others: whether the device passes the threshold (and what it misses), the shapes read
//! back from the screen, paced frames, Linux's 2001-shape scene unlimited with the GPU's
//! own time a frame (timestamps around the render pass), and which backend the cascade
//! picks on this machine. Opened as `LEPTON_GPU=vulkan` opens it: without the threshold.
//! Part of `zig build windows-gpu-check`.

const std = @import("std");
const core = @import("lepton_window");
const native = core.window.win32;
const vulkan = core.vulkan;
const threshold = core.vulkanThreshold;
const scene = core.scene;
const atlas = core.atlas;
const check = @import("root");
const rate = @import("windows_gpu_rate.zig");
const c = @import("c_windows");

fn near(got: u32, want: u32) bool {
    inline for (.{ 16, 8, 0 }) |shift| {
        const a: i32 = @intCast((got >> shift) & 0xff);
        const b: i32 = @intCast((want >> shift) & 0xff);
        if (@abs(a - b) > 3) return false;
    }
    return true;
}

pub fn run() !void {
    const allocator = std.heap.page_allocator;
    // A machine without a Vulkan driver (a CI runner's Basic Render Driver) says so and
    // moves on; one that has it and draws wrong fails.
    if (try shapes(allocator)) try unlimited(allocator);
    try cascade();
}

fn shapes(allocator: std.mem.Allocator) !bool {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton vulkan check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    const hwnd: c.HWND = @ptrCast(w.hwnd);

    var renderer = vulkan.Renderer.open(w.hwnd, size.width, size.height, .display, false) catch |err| switch (err) {
        error.NoLibrary, error.NoInstance, error.NoDevice => {
            check.fact("vulkan", "none on this machine ({t})", .{err});
            return false;
        },
        else => {
            check.expect(false, "vulkan", "{t}", .{err});
            return false;
        },
    };
    defer renderer.deinit();
    w.setPresentPaces(renderer.pacesItself());
    const version = renderer.device.properties.apiVersion;
    check.fact("vulkan", "{s}, Vulkan {d}.{d}.{d}, present {s}", .{ renderer.device.name(), c.VK_API_VERSION_MAJOR(version), c.VK_API_VERSION_MINOR(version), c.VK_API_VERSION_PATCH(version), renderer.presentModeName() });
    var out: [8]threshold.Requirement = undefined;
    const missed = threshold.missing(renderer.device.caps, &out);
    if (missed.len == 0) {
        check.fact("threshold", "passes: the cascade picks Vulkan here", .{});
    } else {
        var names: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&names);
        for (missed, 0..) |requirement, at| writer.print("{s}{t}", .{ if (at == 0) "" else ", ", requirement }) catch break;
        check.fact("threshold", "misses {s}: the cascade passes it over", .{writer.buffered()});
    }

    var glyphs = try atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var bitmap: [16]u8 = undefined;
    for (0..4) |at| @memcpy(bitmap[at * 4 ..][0..4], &[_]u8{ 255, 255, 0, 0 });
    const slot = (try glyphs.put(allocator, .{ .font = 0, .glyph = 1, .size = 4 }, 4, 4, 4, &bitmap, 0, 4)).?;
    var list: scene.List = .{};
    defer list.deinit(allocator);
    try list.rect(allocator, .{ .x = 20, .y = 20, .width = 120, .height = 80 }, .{ .fill = scene.rgba(0xc03020ff), .radius = 24 });
    try list.rect(allocator, .{ .x = 160, .y = 20, .width = 80, .height = 80 }, .{ .fill = scene.rgba(0xff000080) });
    try list.glyph(allocator, .{ .x = 260, .y = 20, .width = 64, .height = 64 }, slot.uv(), scene.rgba(0xff0000ff));
    const clear = scene.rgba(0x0000ffff);
    const at: vulkan.Renderer.Size = .{ .width = size.width, .height = size.height };
    for (0..30) |_| {
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const inside = check.screenAt(hwnd, 80, 60);
    const corner = check.screenAt(hwnd, 22, 22);
    const blended = check.screenAt(hwnd, 200, 60);
    const covered = check.screenAt(hwnd, 270, 50);
    const uncovered = check.screenAt(hwnd, 314, 50);
    check.expect(near(inside, 0xc03020) and near(corner, 0x0000ff), "vk rect", "#{x:0>6} inside, #{x:0>6} outside the radius", .{ inside, corner });
    check.expect(near(blended, 0x80007f), "vk blend", "#{x:0>6}, half red over blue #80007f", .{blended});
    check.expect(near(covered, 0xff0000) and near(uncovered, 0x0000ff), "vk glyph", "#{x:0>6} | #{x:0>6}, atlas coverage left half", .{ covered, uncovered });

    const frames = 120;
    const started = check.ticks();
    for (0..frames) |_| {
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const per_second = @divTrunc(@as(i64, frames) * rate.frequency(), @max(check.ticks() - started, 1));
    const refresh = check.displayHz();
    check.expect(if (refresh == 0) per_second >= 57 and per_second <= 63 else @abs(per_second - refresh) <= 3, "vk paced", "{d} frames = {d}/s, display {d} Hz", .{ frames, per_second, refresh });

    // A resize: the swap chain is made again at the new size, the far corner drawn.
    try w.resize(.{ .width = size.width + 100, .height = size.height + 60 });
    for (0..10) |_| try w.wait(16);
    const grown = if (w.takeConfigure()) |configure| configure.size else size;
    for (0..10) |_| {
        try renderer.draw(&list, &glyphs, clear, .{ .width = grown.width, .height = grown.height });
        try w.wait(16);
    }
    const far = check.screenAt(hwnd, @intCast(grown.width - 4), @intCast(grown.height - 4));
    check.expect(renderer.swapchain.extent.width == grown.width and near(far, 0x0000ff), "vk resize", "{d}x{d}, far corner #{x:0>6}", .{ renderer.swapchain.extent.width, renderer.swapchain.extent.height, far });
    return true;
}

fn unlimited(allocator: std.mem.Allocator) !void {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton vulkan rate", .size = .{ .width = 1200, .height = 800 }, .pacing = .unlimited });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    var renderer = vulkan.Renderer.open(w.hwnd, size.width, size.height, .unlimited, false) catch |err| {
        check.expect(false, "vk unlimited", "{t}", .{err});
        return;
    };
    defer renderer.deinit();
    w.setPresentPaces(renderer.pacesItself());
    var glyphs = try atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var list: scene.List = .{};
    defer list.deinit(allocator);
    const clear = scene.rgba(0xedf0f4ff);
    const at: vulkan.Renderer.Size = .{ .width = size.width, .height = size.height };
    for (0..30) |frame| {
        try rate.cards(&list, allocator, frame);
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const counted = 300;
    const started = check.ticks();
    const cpu_started = rate.processorUs();
    for (0..counted) |frame| {
        try rate.cards(&list, allocator, frame);
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const per_second = @divTrunc(@as(i64, counted) * rate.frequency(), @max(check.ticks() - started, 1));
    const cpu_us = @divTrunc(rate.processorUs() - cpu_started, counted);

    try renderer.time();
    var samples: [100]i64 = undefined;
    var kept: usize = 0;
    for (0..samples.len) |frame| {
        try rate.cards(&list, allocator, frame);
        try renderer.draw(&list, &glyphs, clear, at);
        if (renderer.gpuMicroseconds()) |us| {
            samples[kept] = us;
            kept += 1;
        }
        try w.wait(16);
    }
    std.mem.sort(i64, samples[0..kept], {}, std.sort.asc(i64));
    const gpu_us: i64 = if (kept > 0) samples[kept / 2] else -1;
    check.expect(per_second > check.displayHz(), "vk unlimited", "2001 shapes, {d}/s, CPU {d} us/frame, GPU {d} us/frame, present {s}", .{ per_second, cpu_us, gpu_us, renderer.presentModeName() });
}

/// The backend the cascade opens here, and why each one before it refused.
fn cascade() !void {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton gpu cascade", .size = .{ .width = 320, .height = 240 } });
    defer w.close();
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    var refused: core.windowsGpu.Renderer.Refusals = .{};
    var renderer = core.windowsGpu.Renderer.open(w.hwnd, size.width, size.height, .display, &refused) orelse {
        check.expect(false, "cascade", "no backend opened", .{});
        return;
    };
    defer renderer.deinit();
    for (refused.slice()) |refusal| check.fact("cascade", "{t} refused: {t}", .{ refusal.backend, refusal.reason });
    check.expect(true, "cascade", "opened {s}", .{renderer.name()});
}
