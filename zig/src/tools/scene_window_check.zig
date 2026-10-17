//! The draw command list in a real window: does it reach the screen, and at what cost?
//!
//! Opens a Wayland window, then for 3 seconds builds a scene of labelled cards at the
//! window's configured size and presents it through `WaylandWindow.presentScene` — the
//! GLES 3 renderer on the window's own EGL surface, no frame painted on the CPU. On the
//! last frame the finished image is read back from the window's surface before the swap
//! and checked where the header and a card must be. Prints frames, frame rate, the time a
//! present takes (draw + swap; the swap waits for the compositor), bytes sent per frame
//! and the process's resident memory.

const std = @import("std");
const core = @import("lepton_core");
const gles3 = core.gles3;
const scene = gles3.scene;

const seconds = 3;

fn build(list: *scene.List, allocator: std.mem.Allocator, font: *gles3.glyph_text.Font, glyphs: *gles3.atlas.Atlas, size: core.window.Size, frame: u32) !void {
    list.clear();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);
    try list.rect(allocator, .{ .x = 0, .y = 0, .width = w, .height = 48 }, .{ .fill = scene.rgba(0x2b2d42ff) });
    _ = try font.draw(allocator, glyphs, list, "Lepton · GPU scene", 16, 30, scene.rgba(0xedf2f4ff));
    const columns: usize = 12;
    const cell_w = w / @as(f32, @floatFromInt(columns));
    const cell_h: f32 = 64;
    const rows: usize = @intFromFloat(@max((h - 56) / cell_h, 0));
    for (0..rows * columns) |index| {
        const at: scene.Rect = .{
            .x = @as(f32, @floatFromInt(index % columns)) * cell_w + 6,
            .y = 56 + @as(f32, @floatFromInt(index / columns)) * cell_h + 6,
            .width = cell_w - 12,
            .height = cell_h - 12,
        };
        const lit = (index + frame / 6) % 17 == 0;
        try list.shadow(allocator, .{ .x = at.x, .y = at.y + 2, .width = at.width, .height = at.height }, 6, 5, scene.rgba(0x00000040));
        try list.rect(allocator, at, .{
            .fill = if (lit) scene.rgba(0xef8354ff) else scene.rgba(0xffffffff),
            .radius = 6,
            .border = 1,
            .border_colour = scene.rgba(0xd0d4dcff),
        });
        var name: [24]u8 = undefined;
        _ = try font.draw(allocator, glyphs, list, try std.fmt.bufPrint(&name, "Card {d}", .{index}), at.x + 8, at.y + 20, scene.rgba(0x2b2d42ff));
    }
}

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const display = core.display.Display.probe(core.display.processGetenv, null) catch |e| {
        std.debug.print("no display server: {t}\n", .{e});
        return 1;
    };
    if (display.session != .wayland) {
        std.debug.print("session      {s}: this check needs Wayland\n", .{display.session.label()});
        return 1;
    }

    var window: core.waylandWindow.WaylandWindow = undefined;
    try window.open(allocator, .{ .title = "Lepton scene check", .app_id = "dev.lepton.scenecheck", .size = .{ .width = 960, .height = 600 } });
    defer window.close();

    var path_buffer: [1024]u8 = undefined;
    var font = try gles3.glyph_text.Font.open(try gles3.glyph_text.find("sans", &path_buffer), 13, 0);
    defer font.deinit();
    var glyphs = try gles3.atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var list: scene.List = .{};
    defer list.deinit(allocator);

    const io = std.Io.Threaded.global_single_threaded.io();
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    var size = window.currentSize();
    var frames: u32 = 0;
    var present_ns: u64 = 0;
    var readback: []u8 = &.{};
    defer allocator.free(readback);
    var checked_size = size;

    while (true) {
        if (window.takeConfigure()) |configure| {
            if (configure.size.isEmpty()) break;
            size = configure.size;
        }
        const elapsed = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        const last = elapsed >= seconds * std.time.ns_per_s;
        try build(&list, allocator, &font, &glyphs, size, frames);
        if (last) {
            readback = try allocator.alloc(u8, @as(usize, size.width) * size.height * 4);
            checked_size = size;
        }
        const before = std.Io.Clock.Timestamp.now(io, .awake);
        window.presentScene(&list, &glyphs, scene.rgba(0xedf2f4ff), size, if (last) readback else null) catch |e| {
            std.debug.print("present      refused: {t} (no ES 3 presenter: the CPU path draws instead)\n", .{e});
            return 2;
        };
        present_ns += @intCast(@max(before.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds, 0));
        frames += 1;
        if (last) break;
        window.wait(0) catch break;
    }

    const total_ns: u64 = @intCast(@max(started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds, 1));
    std.debug.print("window       {d}x{d}, presented through {s}\n", .{ size.width, size.height, if (window.presentPath()) |path| @tagName(path) else "nothing" });
    std.debug.print("frames       {d} in {d} ms = {d:.1} fps; present (draw + swap) {d} us on average\n", .{
        frames,                                   total_ns / std.time.ns_per_ms,
        @as(f64, @floatFromInt(frames)) * 1e9 / @as(f64, @floatFromInt(total_ns)), present_ns / frames / 1000,
    });
    std.debug.print("upload       {d} instances = {d} B a frame; the atlas holds {d} B of glyph coverage\n", .{
        list.instances.items.len, list.bytes().len, glyphs.pixels.len - std.mem.count(u8, glyphs.pixels, &.{0}),
    });
    std.debug.print("memory       {d} KiB resident\n", .{(core.probe.residentSetBytes() catch 0) / 1024});

    if (readback.len == 0) return 2;
    const row = @as(usize, checked_size.width) * 4;
    const header = readback[10 * row + 4 * 4 ..][0..3].*;
    const card = readback[(56 + 40) * row + 60 * 4 ..][0..3].*;
    std.debug.print("read back    header {any}, inside the first card {any}\n", .{ header, card });
    const header_ok = header[0] == 0x2b and header[1] == 0x2d and header[2] == 0x42;
    const card_ok = card[0] > 0xf0 and card[1] > 0xf0 and card[2] > 0xf0;
    std.debug.print("result       {s}\n", .{if (header_ok and card_ok) "the scene reached the window's surface" else "the window's surface does not hold the scene"});
    return if (header_ok and card_ok) 0 else 3;
}
