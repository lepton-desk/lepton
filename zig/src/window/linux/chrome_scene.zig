//! The window's frame as draw commands: the titlebar and window menu for the GPU path.
//!
//! The same geometry as `chrome.zig`'s CPU painting — `controlBounds`, the menu's walk, the
//! palette — so a control is drawn where it is clicked. Two things change because the GPU
//! path has a shaper: the title is drawn in the bar, and the menu's entries carry their
//! labels instead of the marked rules the CPU path draws in their place.

const std = @import("std");
const chrome = @import("chrome.zig");
const input = @import("input.zig");
const scene = @import("../../render/scene.zig");
const atlas = @import("../../render/atlas.zig");
const glyph_text = @import("../../render/glyph_text.zig");
const Colour = @import("../../render/surface.zig").Colour;

pub const Error = glyph_text.Error;

fn ink(colour: Colour) scene.Colour {
    return .{
        @as(f32, @floatFromInt(colour.r)) / 255.0,
        @as(f32, @floatFromInt(colour.g)) / 255.0,
        @as(f32, @floatFromInt(colour.b)) / 255.0,
        @as(f32, @floatFromInt(colour.a)) / 255.0,
    };
}

fn box(rect: chrome.Rect) scene.Rect {
    return .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .width = @floatCast(rect.width), .height = @floatCast(rect.height) };
}

/// Text in `font`, its line centred on `middle`.
fn label(font: *glyph_text.Font, allocator: std.mem.Allocator, glyphs: *atlas.Atlas, list: *scene.List, text: []const u8, x: f32, middle: f32, colour: scene.Colour) Error!void {
    const ascender: f32 = @as(f32, @floatFromInt(font.face.*.size.*.metrics.ascender)) / 64.0;
    const descender: f32 = @as(f32, @floatFromInt(font.face.*.size.*.metrics.descender)) / 64.0;
    _ = try font.draw(allocator, glyphs, list, text, x, middle + (ascender + descender) / 2, colour);
}

/// The bar, the rule under it, the title and the three controls.
pub fn titlebar(state: input.Input, title: []const u8, font: *glyph_text.Font, allocator: std.mem.Allocator, glyphs: *atlas.Atlas, list: *scene.List) Error!void {
    const bar: f32 = @floatFromInt(state.titlebar_height);
    if (bar == 0) return;
    const width: f32 = @floatFromInt(state.width);
    try list.rect(allocator, .{ .x = 0, .y = 0, .width = width, .height = bar }, .{ .fill = ink(chrome.palette.bar) });
    try list.rect(allocator, .{ .x = 0, .y = bar - 1, .width = width, .height = 1 }, .{ .fill = ink(chrome.palette.rule) });

    const bounds = chrome.controlBounds(state);
    const hovered = state.zoneAt(state.x, state.y);
    var cut: [256]u8 = undefined;
    const room: f32 = @as(f32, @floatCast(bounds.minimize.x)) - 24;
    try label(font, allocator, glyphs, list, try font.fit(title, room, &cut), 12, bar / 2, ink(chrome.palette.glyph));

    inline for (.{ .{ bounds.minimize, hovered == .minimize, false }, .{ bounds.maximize, hovered == .maximize, false }, .{ bounds.close, hovered == .close, true } }, 0..) |control, index| {
        const rect = box(control[0]);
        const lit = control[1];
        const background = if (control[2]) (if (lit) chrome.palette.close_hovered else chrome.palette.bar) else (if (lit) chrome.palette.hovered else chrome.palette.bar);
        const glyph_colour = if (lit) ink(Colour.rgb(0xf2, 0xf5, 0xf7)) else ink(chrome.palette.glyph);
        try list.rect(allocator, rect, .{ .fill = ink(background) });
        const inset = rect.height * 0.28;
        switch (index) {
            0 => try list.rect(allocator, .{ .x = rect.x + inset, .y = rect.y + rect.height - inset, .width = rect.width - inset * 2, .height = 1 }, .{ .fill = glyph_colour }),
            1 => try list.rect(allocator, .{ .x = rect.x + inset, .y = rect.y + inset, .width = rect.width - inset * 2, .height = rect.height - inset * 2 }, .{
                .fill = .{ 0, 0, 0, 0 },
                .border = 1,
                .border_colour = glyph_colour,
            }),
            else => {
                const mark = "×";
                const advance = try font.measure(mark);
                try label(font, allocator, glyphs, list, mark, rect.x + (rect.width - advance) / 2, rect.y + rect.height / 2, glyph_colour);
            },
        }
    }
}

/// The window menu with its entries' labels, or nothing when it is closed.
pub fn menu(state: chrome.Menu, font: *glyph_text.Font, allocator: std.mem.Allocator, glyphs: *atlas.Atlas, list: *scene.List) Error!void {
    if (!state.open) return;
    const bounds = box(state.bounds());
    // A soft shadow under the plate: the GPU path has the blur the CPU path does not.
    try list.shadow(allocator, .{ .x = bounds.x, .y = bounds.y + 3, .width = bounds.width, .height = bounds.height }, 6, 8, scene.rgba(0x00000080));
    try list.rect(allocator, bounds, .{ .fill = ink(chrome.palette.bar), .radius = 6, .border = 1, .border_colour = ink(chrome.palette.rule) });

    var offset: f32 = bounds.y + @as(f32, chrome.menu_padding);
    const entry: f32 = chrome.menu_entry_height;
    for (state.items[0..chrome.Menu.entries], 0..) |item, index| {
        if (item.isSeparatorBefore()) {
            try list.rect(allocator, .{ .x = bounds.x + 6, .y = offset, .width = bounds.width - 12, .height = 1 }, .{ .fill = ink(chrome.palette.rule) });
            offset += entry * 0.5;
        }
        if (state.hovered == index) {
            try list.rect(allocator, .{ .x = bounds.x + 4, .y = offset, .width = bounds.width - 8, .height = entry }, .{ .fill = ink(chrome.palette.hovered), .radius = 4 });
        }
        try label(font, allocator, glyphs, list, item.label(), bounds.x + 14, offset + entry / 2, ink(chrome.palette.glyph));
        offset += entry;
    }
}
