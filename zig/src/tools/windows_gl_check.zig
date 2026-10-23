//! The OpenGL 3.3 backend (`render/gpu/gl33.zig`) measured as `windows-gpu-check` measures
//! Direct3D 11: the same shapes read back from the screen, paced frames, and Linux's
//! 2001-shape scene unlimited with the GPU's own time a frame (timestamp queries,
//! `GL_TIMESTAMP`, around the drawing only). Part of `zig build windows-gpu-check`.

const std = @import("std");
const core = @import("lepton_window");
const native = core.window.win32;
const gl33 = core.gl33;
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
    // A machine without OpenGL 3.3 (a CI runner's Basic Render Driver offers GDI's 1.1)
    // says so and moves on; one that has it and draws wrong fails.
    if (try shapes(allocator)) try unlimited(allocator);
}

/// The D3D11 check's shapes, on a window of their own, paced by the swap interval.
fn shapes(allocator: std.mem.Allocator) !bool {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton gl 3.3 check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    const hwnd: c.HWND = @ptrCast(w.hwnd);

    var renderer = gl33.Renderer.open(w.hwnd, size.width, size.height, .display) catch |err| switch (err) {
        error.NoContext, error.NoFunction => {
            check.fact("gl 3.3", "none on this machine ({t})", .{err});
            return false;
        },
        else => {
            check.expect(false, "gl 3.3", "{t}", .{err});
            return false;
        },
    };
    defer renderer.deinit();
    w.setPresentPaces(renderer.pacesItself());
    check.expect(true, "gl 3.3", "{s}, {s}", .{ renderer.version, renderer.renderer_name });

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
    const at: gl33.Renderer.Size = .{ .width = size.width, .height = size.height };
    for (0..30) |_| {
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const inside = check.screenAt(hwnd, 80, 60);
    const corner = check.screenAt(hwnd, 22, 22);
    const blended = check.screenAt(hwnd, 200, 60);
    const covered = check.screenAt(hwnd, 270, 50);
    const uncovered = check.screenAt(hwnd, 314, 50);
    check.expect(near(inside, 0xc03020) and near(corner, 0x0000ff), "gl rect", "#{x:0>6} inside, #{x:0>6} outside the radius", .{ inside, corner });
    check.expect(near(blended, 0x80007f), "gl blend", "#{x:0>6}, half red over blue #80007f", .{blended});
    check.expect(near(covered, 0xff0000) and near(uncovered, 0x0000ff), "gl glyph", "#{x:0>6} | #{x:0>6}, atlas coverage left half", .{ covered, uncovered });

    const frames = 120;
    const started = check.ticks();
    for (0..frames) |_| {
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const per_second = @divTrunc(@as(i64, frames) * rate.frequency(), @max(check.ticks() - started, 1));
    const refresh = check.displayHz();
    check.expect(if (refresh == 0) per_second >= 57 and per_second <= 63 else @abs(per_second - refresh) <= 3, "gl paced", "{d} frames = {d}/s, display {d} Hz", .{ frames, per_second, refresh });
    return true;
}

/// Linux's 2001-shape scene with no swap interval, and the GPU's time for its drawing.
fn unlimited(allocator: std.mem.Allocator) !void {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton gl 3.3 rate", .size = .{ .width = 1200, .height = 800 }, .pacing = .unlimited });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    var renderer = gl33.Renderer.open(w.hwnd, size.width, size.height, .unlimited) catch |err| {
        check.expect(false, "gl unlimited", "{t}", .{err});
        return;
    };
    defer renderer.deinit();
    w.setPresentPaces(renderer.pacesItself());
    var glyphs = try atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var list: scene.List = .{};
    defer list.deinit(allocator);
    const clear = scene.rgba(0xedf0f4ff);
    const at: gl33.Renderer.Size = .{ .width = size.width, .height = size.height };

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

    // The GPU's time: a timestamp before and after the drawing, waited for each frame.
    const gl = &renderer.gl;
    var queries: [2]c.GLuint = undefined;
    gl.glGenQueries(2, &queries);
    defer gl.glDeleteQueries(2, &queries);
    var samples: [100]i64 = undefined;
    for (&samples, 0..) |*sample, frame| {
        try rate.cards(&list, allocator, frame);
        gl.glQueryCounter(queries[0], c.GL_TIMESTAMP);
        try renderer.record(&list, &glyphs, clear, at);
        gl.glQueryCounter(queries[1], c.GL_TIMESTAMP);
        try renderer.present();
        var first: u64 = 0;
        var last: u64 = 0;
        // `GL_QUERY_RESULT` waits for the result.
        gl.glGetQueryObjectui64v(queries[0], c.GL_QUERY_RESULT, &first);
        gl.glGetQueryObjectui64v(queries[1], c.GL_QUERY_RESULT, &last);
        sample.* = @intCast(@divTrunc(last -| first, 1000));
        try w.wait(16);
    }
    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    check.expect(per_second > check.displayHz(), "gl unlimited", "2001 shapes, {d}/s, CPU {d} us/frame, GPU {d} us/frame", .{ per_second, cpu_us, samples[samples.len / 2] });
}
