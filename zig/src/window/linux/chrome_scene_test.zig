//! The GPU frame (`chrome_scene.zig`) drawn by GLES 3 and read back.

const std = @import("std");
const chrome = @import("chrome.zig");
const chrome_scene = @import("chrome_scene.zig");
const input = @import("input.zig");
const gles3 = @import("../../render/gles3.zig");
const scene = gles3.scene;

const width = 400;
const height = 200;

const Drawn = struct {
    frame: [width * height * 4]u8,

    fn at(self: *const Drawn, x: usize, y: usize) [3]u8 {
        return self.frame[(y * width + x) * 4 ..][0..3].*;
    }

    /// Pixels in the rectangle whose colour is not `ground`.
    fn marked(self: *const Drawn, x0: usize, y0: usize, x1: usize, y1: usize, ground: [3]u8) usize {
        var count: usize = 0;
        for (y0..y1) |y| {
            for (x0..x1) |x| {
                if (!std.mem.eql(u8, &self.at(x, y), &ground)) count += 1;
            }
        }
        return count;
    }
};

fn draw(state: input.Input, menu: chrome.Menu, title: []const u8) !Drawn {
    const allocator = std.testing.allocator;
    var path_buffer: [1024]u8 = undefined;
    var font = try gles3.glyph_text.Font.open(allocator, try gles3.glyph_text.find("sans", &path_buffer), 13, 0);
    defer font.deinit();
    var glyphs = try gles3.atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var list: scene.List = .{};
    defer list.deinit(allocator);
    try chrome_scene.titlebar(state, title, &font, allocator, &glyphs, &list);
    try chrome_scene.menu(menu, &font, allocator, &glyphs, &list);

    var renderer = try gles3.open(width, height);
    defer renderer.deinit();
    renderer.syncAtlas(&glyphs);
    renderer.draw(&list, scene.rgba(0xffffffff));
    renderer.finish();
    var drawn: Drawn = undefined;
    renderer.read(&drawn.frame);
    return drawn;
}

const bar = [3]u8{ 0x16, 0x18, 0x1b };

test "the GPU titlebar draws the bar, the title and each control where it is clicked" {
    const state: input.Input = .{ .width = width, .height = height, .titlebar_height = 30, .x = -1, .y = -1 };
    const drawn = try draw(state, .{}, "Notes");
    const bounds = chrome.controlBounds(state);
    // The bar's own colour between the title and the controls, the client's below it.
    try std.testing.expectEqualSlices(u8, &bar, &drawn.at(200, 4));
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, &drawn.at(200, 100));
    // The title is text: ink at the left of the bar.
    try std.testing.expect(drawn.marked(12, 0, 60, 29, bar) > 30);
    // Each control has its glyph inside its own bounds.
    for ([_]chrome.Rect{ bounds.minimize, bounds.maximize, bounds.close }) |rect| {
        const x0: usize = @intFromFloat(rect.x);
        const y0: usize = @intFromFloat(rect.y);
        try std.testing.expect(drawn.marked(x0, y0, x0 + @as(usize, @intFromFloat(rect.width)), @min(y0 + @as(usize, @intFromFloat(rect.height)), 29), bar) > 4);
    }
}

test "a hovered close control turns red" {
    var state: input.Input = .{ .width = width, .height = height, .titlebar_height = 30, .x = -1, .y = -1 };
    const close = chrome.controlBounds(state).close;
    state.x = close.x + 2;
    state.y = close.y + 2;
    const drawn = try draw(state, .{}, "Notes");
    try std.testing.expectEqualSlices(u8, &.{ 0x8e, 0x2f, 0x2a }, &drawn.at(@intFromFloat(close.x + 2), @intFromFloat(close.y + 2)));
}

test "a long title is cut before the controls" {
    const state: input.Input = .{ .width = width, .height = height, .titlebar_height = 30, .x = -1, .y = -1 };
    const drawn = try draw(state, .{}, "A title far too long to fit in a four hundred pixel wide window bar");
    const minimize: usize = @intFromFloat(chrome.controlBounds(state).minimize.x);
    // Nothing of the title in the last 12 pixels before the first control.
    try std.testing.expectEqual(@as(usize, 0), drawn.marked(minimize - 12, 0, minimize, 28, bar));
}

test "the open menu carries its labels" {
    const state: input.Input = .{ .width = width, .height = height, .titlebar_height = 30, .x = -1, .y = -1 };
    var menu: chrome.Menu = .{};
    menu.openAt(40, 50, width, height);
    const drawn = try draw(state, menu, "Notes");
    const bounds = menu.bounds();
    const x0: usize = @intFromFloat(bounds.x + 14);
    const y0: usize = @intFromFloat(bounds.y + chrome.menu_padding);
    // The first entry's label ("Minimize") is ink on the menu plate.
    try std.testing.expect(drawn.marked(x0, y0 + 4, x0 + 50, y0 + @as(usize, @intFromFloat(chrome.menu_entry_height)) - 4, bar) > 40);
}
