//! Tests for `chrome.zig`: the click decision, the titlebar's controls and the window menu.
//!
//! Kept beside the code rather than inside it so `chrome.zig` stays under the 800-line
//! limit. Every test paints into a real `Surface` or feeds a real `input.Input`, the same
//! values the Wayland callbacks pass at run time.

const std = @import("std");
const input = @import("input.zig");
const surface_mod = @import("../../render/surface.zig");
const chrome = @import("chrome.zig");

const Surface = surface_mod.Surface;
const Colour = surface_mod.Colour;

const Action = chrome.Action;
const actionFor = chrome.actionFor;
const controlBounds = chrome.controlBounds;
const palette = chrome.palette;
const paintTitlebar = chrome.paintTitlebar;
const MenuItem = chrome.MenuItem;
const menu_width = chrome.menu_width;
const menu_entry_height = chrome.menu_entry_height;
const menu_padding = chrome.menu_padding;
const Menu = chrome.Menu;
const menuAction = chrome.menuAction;
const paintMenu = chrome.paintMenu;

test "the bar fills the top strip and leaves the client alone" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0, 0, 0));

    const state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    paintTitlebar(state, target);

    // A pixel in the bar is the bar's colour, not the fill underneath it.
    try std.testing.expectEqual(palette.bar, target.pixelAt(5, 5).?);
    // A pixel below it is untouched: the bar must not bleed into the client area.
    try std.testing.expectEqual(Colour.rgb(0, 0, 0), target.pixelAt(5, 100).?);
}

test "hovering close paints a different ground than hovering minimize" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0, 0, 0));

    const bounds = controlBounds(.{ .width = 400, .height = 300, .titlebar_height = 32 });

    var on_close = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    on_close.move(bounds.close.x + 2, 4);
    paintTitlebar(on_close, target);
    const close_ground = target.pixelAt(@intFromFloat(bounds.close.x + 2), 2).?;

    var on_minimize = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    on_minimize.move(bounds.minimize.x + 2, 4);
    paintTitlebar(on_minimize, target);
    const minimize_ground = target.pixelAt(@intFromFloat(bounds.minimize.x + 2), 2).?;

    try std.testing.expectEqual(palette.close_hovered, close_ground);
    try std.testing.expectEqual(palette.hovered, minimize_ground);
    try std.testing.expect(!std.meta.eql(close_ground, minimize_ground));
}

test "a menu opens at the pointer and covers three entries" {
    var menu = Menu{};
    menu.openAt(200, 150, 800, 600);
    try std.testing.expect(menu.open);
    try std.testing.expectEqual(@as(usize, 3), Menu.entries);
}

test "a menu nudged at the right edge stays fully inside the window" {
    var menu = Menu{};
    menu.openAt(790, 150, 800, 600);
    try std.testing.expect(menu.bounds().x + menu_width <= 800);
    // The entry that closes the window has to be reachable, which means inside. Its
    // middle is walked to rather than guessed: the separator before it costs half an
    // entry, and the menu's own bottom padding sits below it, so the very last pixel of
    // the menu belongs to no entry at all.
    const last_middle = menu.y + menu_padding + menu_entry_height * 2 +
        menu_entry_height * 0.5 + menu_entry_height / 2;
    try std.testing.expectEqual(@as(?usize, 2), menu.entryAt(menu.bounds().x + 4, last_middle));
}

test "every entry is reachable at the point it is drawn" {
    var menu = Menu{};
    menu.openAt(100, 100, 800, 600);

    var seen: usize = 0;
    var y = menu.y + menu_padding;
    var index: usize = 0;
    while (index < Menu.entries) : (index += 1) {
        if (menu.items[index].isSeparatorBefore()) y += menu_entry_height * 0.5;
        const hit = menu.entryAt(menu.x + menu_width / 2, y + menu_entry_height / 2);
        try std.testing.expectEqual(@as(?usize, index), hit);
        seen += 1;
        y += menu_entry_height;
    }
    try std.testing.expectEqual(Menu.entries, seen);
}

test "a point outside the menu is over nothing" {
    var menu = Menu{};
    menu.openAt(100, 100, 800, 600);
    try std.testing.expectEqual(@as(?usize, null), menu.entryAt(10, 10));
    try std.testing.expectEqual(@as(?usize, null), menu.entryAt(700, 700));
}

test "a dismissed menu is over nothing even where it was" {
    var menu = Menu{};
    menu.openAt(100, 100, 800, 600);
    const inside_x = menu.x + menu_width / 2;
    const inside_y = menu.y + menu_padding + 2;
    menu.dismiss();
    try std.testing.expectEqual(@as(?usize, null), menu.entryAt(inside_x, inside_y));
}

test "the menu's entries stand for the window actions" {
    try std.testing.expectEqual(Action.minimize, menuAction(.minimize));
    try std.testing.expectEqual(Action.maximize, menuAction(.maximize));
    try std.testing.expectEqual(Action.close, menuAction(.close));
}

test "close is set apart from the everyday entries" {
    try std.testing.expect(!MenuItem.minimize.isSeparatorBefore());
    try std.testing.expect(!MenuItem.maximize.isSeparatorBefore());
    try std.testing.expect(MenuItem.close.isSeparatorBefore());
}

test "a closed menu paints nothing at all" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0x11, 0x22, 0x33));
    const before = target.pixelAt(120, 120).?;

    const menu = Menu{};
    paintMenu(menu, target);

    // Menu state alone must not draw. A closed menu that still painted a plate would
    // leave a rectangle on the window for as long as the pointer had ever right-clicked.
    try std.testing.expectEqual(before, target.pixelAt(120, 120).?);
}

test "an open menu paints a plate inside the window" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0x11, 0x22, 0x33));

    var menu = Menu{};
    menu.openAt(100, 100, 400, 300);
    paintMenu(menu, target);

    // Inside the plate: the menu's own ground, not the window's and not the rule colour.
    const inside_x: u32 = @intFromFloat(menu.bounds().x + menu_width / 2);
    const inside_y: u32 = @intFromFloat(menu.y + menu_padding + 1);
    try std.testing.expectEqual(palette.bar, target.pixelAt(inside_x, inside_y).?);

    // Just outside: the one-pixel rule, which is what separates the menu from the frame.
    const edge_x: u32 = @as(u32, @intFromFloat(menu.bounds().x)) - 1;
    const edge_y: u32 = @intFromFloat(menu.y + menu_padding + 1);
    try std.testing.expectEqual(palette.rule, target.pixelAt(edge_x, edge_y).?);
}

test "the drawn highlight lands on the entry the pointer is over" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0x11, 0x22, 0x33));

    var menu = Menu{};
    menu.openAt(100, 100, 400, 300);

    // Hover the third entry using the same walk the hit test uses, then paint and read
    // the pixel back. If the drawn highlight and the hit test disagreed, this is where it
    // would show: the wrong row would carry the hover ground.
    const last_middle = menu.y + menu_padding + menu_entry_height * 2 +
        menu_entry_height * 0.5 + menu_entry_height / 2;
    menu.hover(menu.bounds().x + menu_width / 2, last_middle);
    try std.testing.expectEqual(@as(?usize, 2), menu.hovered);

    paintMenu(menu, target);

    const probe_x: u32 = @intFromFloat(menu.bounds().x + menu_width / 2);
    const probe_y: u32 = @intFromFloat(last_middle);
    try std.testing.expectEqual(palette.hovered, target.pixelAt(probe_x, probe_y).?);
}

test "no entry is highlighted when the pointer is off the menu" {
    var target = try Surface.init(std.testing.allocator, .{ .width = 400, .height = 300 }, .argb8888);
    defer target.deinit();
    target.fill(Colour.rgb(0x11, 0x22, 0x33));

    var menu = Menu{};
    menu.openAt(100, 100, 400, 300);
    menu.hover(5, 5);
    try std.testing.expectEqual(@as(?usize, null), menu.hovered);

    paintMenu(menu, target);

    // The first entry's middle, which would be highlighted if the off-menu hover had
    // silently kept whatever entry it last passed over.
    const first_middle: f64 = menu.y + menu_padding + menu_entry_height / 2;
    const probe_x: u32 = @intFromFloat(menu.bounds().x + menu_width / 2);
    const probe_y: u32 = @intFromFloat(first_middle);
    try std.testing.expect(!std.meta.eql(palette.hovered, target.pixelAt(probe_x, probe_y).?));
}

test "a click on close asks for close" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    const bounds = controlBounds(state);
    state.move(bounds.close.x + 1, bounds.close.y + 1);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 120);

    try std.testing.expectEqual(Action.close, actionFor(state, 120, null, 1));
}

test "a click on the titlebar away from the controls begins a drag" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    state.move(40, 10);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 130);

    try std.testing.expectEqual(Action.begin_drag, actionFor(state, 130, null, 1));
}

test "a click in the client area belongs to the client" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    state.move(40, 200);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 120);

    try std.testing.expectEqual(Action.client, actionFor(state, 120, null, 1));
}

test "a drag that ends on close is not a click" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    const bounds = controlBounds(state);
    state.move(bounds.close.x + 1, bounds.close.y + 1);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 120);
    // The pointer travelled to get here; the anchor is where the press started.
    state.press = .{ .button = .left, .x = 4, .y = 200, .time_ms = 100 };

    try std.testing.expectEqual(Action.none, actionFor(state, 120, null, 1));
}

test "a press held too long is not a click" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    const bounds = controlBounds(state);
    state.move(bounds.close.x + 1, bounds.close.y + 1);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 900);

    try std.testing.expectEqual(Action.none, actionFor(state, 900, null, 1));
}

test "a second click on the titlebar within the gap is a double click" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    state.move(40, 10);
    state.button(1, true, 0, 100);
    state.button(1, false, 0, 120);

    try std.testing.expectEqual(Action.begin_drag, actionFor(state, 120, null, 1));
    // The previous click was at 120; this one lands at 300.
    try std.testing.expectEqual(Action.double_click_titlebar, actionFor(state, 300, 120, 1));
}

test "two clicks further apart than the gap are two single clicks" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    // The second click happens a long way in time from the first. Its own press and
    // release have to be at that later time too: a click is judged by the press that
    // produced it, not by whichever press happened to be recorded last.
    state.move(40, 10);
    state.button(1, true, 0, 1200);
    state.button(1, false, 0, 1210);

    try std.testing.expectEqual(Action.begin_drag, actionFor(state, 1210, 120, 1));
}

test "the pointer on an edge while held is a resize, not a move" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    // Pressed in the client area and carried to the edge, so the gesture is a drag. A
    // press *and* release at the edge would be a click in the client area instead.
    state.move(100, 150);
    state.button(1, true, 0, 100);
    state.move(400 - 2, 150);

    const action = actionFor(state, 150, null, 1);
    try std.testing.expectEqual(Action{ .begin_resize = .right }, action);
}

test "a corner is read as a corner rather than one of its edges" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    // Carried into the corner, not clicked there. A press *and* release inside the titlebar
    // is a click that moves the window, which is what a click in the corner should do;
    // resizing a corner needs the pointer to travel, so this is the gesture that means it.
    state.move(100, 200);
    state.button(1, true, 0, 0);
    state.move(1, 1);

    try std.testing.expectEqual(Action{ .begin_resize = .top_left }, actionFor(state, 40, null, 1));
}

test "control bounds match the zones they are drawn in" {
    const state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    const bounds = controlBounds(state);

    // The whole of each rectangle must read as its own zone, which is the property that
    // stops a control being drawn in one place and clicked in another.
    try std.testing.expectEqual(input.Input.Zone.minimize, state.zoneAt(bounds.minimize.x + 1, 1));
    try std.testing.expectEqual(input.Input.Zone.maximize, state.zoneAt(bounds.maximize.x + 1, 1));
    try std.testing.expectEqual(input.Input.Zone.close, state.zoneAt(bounds.close.x + 1, 1));
    try std.testing.expect(bounds.close.contains(bounds.close.x + 1, 1));
    try std.testing.expect(!bounds.close.contains(bounds.close.x + 1, 40));
}

test "a close click whose release is stamped early still closes" {
    var state = input.Input{ .width = 400, .height = 300, .titlebar_height = 32 };
    const bounds = controlBounds(state);
    state.move(bounds.close.x + 1, bounds.close.y + 1);
    state.button(1, true, 0, 5000);
    state.button(1, false, 0, 4990);

    try std.testing.expectEqual(Action.close, actionFor(state, 4990, null, 1));
}
