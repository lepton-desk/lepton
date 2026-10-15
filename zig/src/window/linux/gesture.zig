//! Gestures that must start while the button is still down.
//!
//! `xdg_toplevel.move` and `xdg_toplevel.resize` take the serial of a press the user is
//! *still holding*: the compositor turns that implicit grab into its own interactive
//! grab. The first version decided both on release, where the grab is already gone —
//! the compositor ignored every request and the window could not be dragged at all.
//!
//! So the decision is split. A press on a resize edge starts the resize at once. A press
//! on the bare titlebar only *arms* a move, which starts on the first motion past the
//! click threshold — that keeps a plain click (and a double click, which maximises) from
//! being swallowed by a move the user never made. Controls and the client area never
//! arm anything: they act on release, as a click.

const std = @import("std");
const input = @import("input.zig");
const chrome = @import("chrome.zig");

/// What a left press asks for before the release is known.
pub const OnPress = union(enum) {
    none,
    resize: chrome.input_zone.Edge,
    arm_move,
};

/// Decides what a left press starts. Edges win over the titlebar, as in `actionFor`,
/// because the corner of the bar is also the corner of the window.
pub fn onPress(state: input.Input) OnPress {
    if (!state.isHeld(.left) or state.held_mask != @as(u32, @bitCast(@intFromEnum(input.Button.left)))) {
        return .none;
    }
    const edge = chrome.edgeAt(state, state.x, state.y);
    if (edge != .none) return .{ .resize = edge };
    if (state.zoneAt(state.x, state.y) == .titlebar) return .arm_move;
    return .none;
}

/// Whether an armed move should start now: the left button is still down and the pointer
/// has left the click radius around the press.
pub fn moveStarts(state: input.Input) bool {
    if (!state.isHeld(.left)) return false;
    const anchor = state.press orelse return false;
    const dx = state.x - anchor.x;
    const dy = state.y - anchor.y;
    return @sqrt(dx * dx + dy * dy) > chrome.click_distance_limit;
}

/// The time the next click is measured against for a double click, after `action`.
///
/// A plain titlebar click counts — it reads as `begin_drag` because a press on the bar
/// arms a move that never started — and the first version left it out, so the second
/// click never saw a first one and a titlebar double click could not happen. A double
/// click resets the clock, so a third click starts a new pair instead of toggling again.
pub fn nextLastClick(action: chrome.Action, now_ms: u32) ?u32 {
    return switch (action) {
        .client, .close, .minimize, .maximize, .begin_drag => now_ms,
        .double_click_titlebar => null,
        else => null,
    };
}

fn bar() input.Input {
    return .{ .width = 400, .height = 300, .titlebar_height = 32 };
}

test "a press on the bare titlebar arms a move instead of starting one" {
    var state = bar();
    state.move(40, 10);
    state.button(1, true, 9, 100);
    try std.testing.expectEqual(OnPress.arm_move, onPress(state));
    // Not moved yet: a click or a double click is still possible.
    try std.testing.expect(!moveStarts(state));
}

test "the move starts once the held pointer leaves the click radius" {
    var state = bar();
    state.move(40, 10);
    state.button(1, true, 9, 100);
    state.move(52, 12);
    try std.testing.expect(moveStarts(state));
}

test "a released button never starts a move" {
    var state = bar();
    state.move(40, 10);
    state.button(1, true, 9, 100);
    state.move(80, 12);
    state.button(1, false, 10, 140);
    try std.testing.expect(!moveStarts(state));
}

test "a press on an edge starts the resize at once" {
    var state = bar();
    state.move(399, 150);
    state.button(1, true, 9, 100);
    try std.testing.expectEqual(OnPress{ .resize = .right }, onPress(state));
}

test "a press on a control or the client arms nothing" {
    var state = bar();
    const bounds = chrome.controlBounds(state);
    state.move(bounds.close.x + 8, bounds.close.y + 12);
    state.button(1, true, 9, 100);
    try std.testing.expectEqual(OnPress.none, onPress(state));

    var client = bar();
    client.move(200, 150);
    client.button(1, true, 9, 100);
    try std.testing.expectEqual(OnPress.none, onPress(client));
}

test "a right press arms nothing" {
    var state = bar();
    state.move(40, 10);
    state.button(1 << 1, true, 9, 100);
    try std.testing.expectEqual(OnPress.none, onPress(state));
}

test "two clicks on the titlebar become a double click through the real bookkeeping" {
    var state = bar();
    state.move(40, 10);
    state.button(1, true, 1, 100);
    state.button(1, false, 2, 120);
    const first = chrome.actionFor(state, 120, null, 1);
    const remembered = nextLastClick(first, 120);
    try std.testing.expect(remembered != null);

    state.button(1, true, 3, 250);
    state.button(1, false, 4, 270);
    try std.testing.expectEqual(chrome.Action.double_click_titlebar, chrome.actionFor(state, 270, remembered, 1));
}

test "a third click after a double click starts a new pair" {
    try std.testing.expectEqual(@as(?u32, null), nextLastClick(.double_click_titlebar, 270));
}
