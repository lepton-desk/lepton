//! What the draw command list costs on GLES 3: a window-sized scene of cards, timed.
//!
//! Draws `LEPTON_SCENE_CARDS` (default 1000) cards — a shadow and a bordered rounded
//! rectangle each — at 1200×800 off-screen, 300 frames with `glFinish` after each, and
//! prints the driver, the bytes uploaded per frame against the full-frame texture the
//! native path uploads today (1200×800×4), and the frame times. `LEPTON_SCENE_DUMP=<file>`
//! writes the last frame as a binary PPM to look at. `LIBGL_ALWAYS_SOFTWARE=1` runs it on
//! llvmpipe. The same run also times what today's native path costs at the least: one
//! 1200×800 `glTexSubImage2D` a frame (its CPU painting not counted).

const std = @import("std");
const gles3 = @import("gles3");
const scene = gles3.scene;
const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const width = 1200;
const height = 800;
const frames = 300;

fn cards(list: *scene.List, allocator: std.mem.Allocator, count: usize, frame: usize) !void {
    list.clear();
    try list.rect(allocator, .{ .x = 0, .y = 0, .width = width, .height = 48 }, .{ .fill = scene.rgba(0x2b2d42ff) });
    const columns = 40;
    const cell_w: f32 = @as(f32, width) / columns;
    const rows = (count + columns - 1) / columns;
    const cell_h: f32 = (@as(f32, height) - 56) / @as(f32, @floatFromInt(@max(rows, 1)));
    // Moves a little each frame, so no frame is a copy of the last.
    const drift: f32 = @floatFromInt(frame % 4);
    for (0..count) |index| {
        const col: f32 = @floatFromInt(index % columns);
        const row: f32 = @floatFromInt(index / columns);
        const at: scene.Rect = .{
            .x = col * cell_w + 3 + drift,
            .y = 56 + row * cell_h + 3,
            .width = cell_w - 6,
            .height = cell_h - 6,
        };
        try list.shadow(allocator, .{ .x = at.x, .y = at.y + 2, .width = at.width, .height = at.height }, 4, 4, scene.rgba(0x00000040));
        try list.rect(allocator, at, .{
            .fill = if (index % 7 == 0) scene.rgba(0x8d99aeff) else scene.rgba(0xffffffff),
            .radius = 4,
            .border = 1,
            .border_colour = scene.rgba(0xd0d4dcff),
        });
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const count: usize = if (std.c.getenv("LEPTON_SCENE_CARDS")) |text|
        std.fmt.parseInt(usize, std.mem.span(text), 10) catch 1000
    else
        1000;

    var renderer = try gles3.open(width, height);
    defer renderer.deinit();
    var list: scene.List = .{};
    defer list.deinit(allocator);

    const io = std.Io.Threaded.global_single_threaded.io();
    var times: [frames]u64 = undefined;
    for (0..frames) |frame| {
        try cards(&list, allocator, count, frame);
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        renderer.draw(&list, scene.rgba(0xedf2f4ff));
        renderer.finish();
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        times[frame] = @intCast(@max(elapsed, 0));
    }
    // The first frames compile and warm caches; the figure is the steady state.
    const steady = times[30..];
    std.mem.sort(u64, steady, {}, std.sort.asc(u64));
    var total: u64 = 0;
    for (steady) |t| total += t;

    const per_frame = list.bytes().len;
    const texture = width * height * 4;
    std.debug.print("driver       {s}\n", .{renderer.rendererName()});
    std.debug.print("scene        {d} cards = {d} shapes, {d}x{d}\n", .{ count, list.instances.items.len, width, height });
    std.debug.print("upload       {d} B a frame (a full-frame texture is {d} B: {d:.1}x less)\n", .{
        per_frame, texture, @as(f64, @floatFromInt(texture)) / @as(f64, @floatFromInt(@max(per_frame, 1))),
    });
    std.debug.print("frame        median {d} us, p95 {d} us, mean {d} us over {d} frames (draw + glFinish)\n", .{
        steady[steady.len / 2] / 1000,
        steady[steady.len * 95 / 100] / 1000,
        total / steady.len / 1000,
        steady.len,
    });

    // Today's path, at the least: the whole frame uploaded as a texture, every frame.
    {
        const frame_pixels = try allocator.alloc(u8, texture);
        defer allocator.free(frame_pixels);
        for (frame_pixels, 0..) |*byte, i| byte.* = @truncate(i);
        var texture_id: c.GLuint = 0;
        c.glGenTextures(1, &texture_id);
        defer c.glDeleteTextures(1, &texture_id);
        c.glBindTexture(c.GL_TEXTURE_2D, texture_id);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        var uploads: [frames]u64 = undefined;
        for (0..frames) |frame| {
            frame_pixels[frame] +%= 1;
            const started = std.Io.Clock.Timestamp.now(io, .awake);
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, width, height, c.GL_RGBA, c.GL_UNSIGNED_BYTE, frame_pixels.ptr);
            c.glFinish();
            const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
            uploads[frame] = @intCast(@max(elapsed, 0));
        }
        const settled = uploads[30..];
        std.mem.sort(u64, settled, {}, std.sort.asc(u64));
        std.debug.print("texture      full-frame upload alone: median {d} us, p95 {d} us (CPU painting not counted)\n", .{
            settled[settled.len / 2] / 1000,
            settled[settled.len * 95 / 100] / 1000,
        });
    }

    if (std.c.getenv("LEPTON_SCENE_DUMP")) |path| {
        const pixels = try allocator.alloc(u8, texture);
        defer allocator.free(pixels);
        renderer.read(pixels);
        var rgb = try allocator.alloc(u8, width * height * 3);
        defer allocator.free(rgb);
        for (0..width * height) |i| @memcpy(rgb[i * 3 ..][0..3], pixels[i * 4 ..][0..3]);
        var header_buffer: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ width, height });
        const file = std.c.fopen(path, "wb") orelse return error.CannotWrite;
        defer _ = std.c.fclose(file);
        _ = std.c.fwrite(header.ptr, 1, header.len, file);
        _ = std.c.fwrite(rgb.ptr, 1, rgb.len, file);
        std.debug.print("dump         {s}\n", .{std.mem.span(path)});
    }
}
