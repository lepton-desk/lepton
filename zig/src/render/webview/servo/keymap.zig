//! X keys in the DOM's names, for Servo (`lepton_servo_key`): `key` is what the key
//! produced ("a", "ş", "Enter"), `code` which physical key it was ("KeyA").
//!
//! `key`: the keysym Xlib's `XLookupString` reads with the event's Shift, Caps Lock and
//! group (so a Turkish layout gives "ş"); a named key from the table below, otherwise the
//! character xkbcommon says the keysym stands for. `code`: the evdev keycode (X's keycode
//! minus 8), by the W3C UI Events code table, which names physical keys by their US
//! position whatever the layout.

const std = @import("std");

/// The DOM name of a keysym that is not a character, or null for one that is.
pub fn named(keysym: u32) ?[]const u8 {
    return switch (keysym) {
        0xff08 => "Backspace",
        0xff09, 0xfe20 => "Tab",
        0xff0d, 0xff8d => "Enter",
        0xff1b => "Escape",
        0xffff => "Delete",
        0xff63 => "Insert",
        0xff50 => "Home",
        0xff57 => "End",
        0xff55 => "PageUp",
        0xff56 => "PageDown",
        0xff51 => "ArrowLeft",
        0xff52 => "ArrowUp",
        0xff53 => "ArrowRight",
        0xff54 => "ArrowDown",
        0xffe1, 0xffe2 => "Shift",
        0xffe3, 0xffe4 => "Control",
        0xffe9, 0xffea => "Alt",
        0xfe03 => "AltGraph",
        0xffeb, 0xffec, 0xffe7, 0xffe8 => "Meta",
        0xffe5 => "CapsLock",
        0xff7f => "NumLock",
        0xff14 => "ScrollLock",
        0xff13 => "Pause",
        0xff61 => "PrintScreen",
        0xff67 => "ContextMenu",
        0xffbe...0xffc9 => f_keys[keysym - 0xffbe],
        else => null,
    };
}

const f_keys = [_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12" };

/// The DOM `code` of an evdev keycode, or "Unidentified".
pub fn code(evdev: u32) []const u8 {
    return if (evdev < codes.len and codes[evdev].len > 0) codes[evdev] else "Unidentified";
}

/// Evdev keycodes (`linux/input-event-codes.h`) to DOM codes, by index.
const codes = blk: {
    var table: [128][]const u8 = @splat("");
    const pairs = .{
        .{ 1, "Escape" },        .{ 2, "Digit1" },          .{ 3, "Digit2" },          .{ 4, "Digit3" },
        .{ 5, "Digit4" },        .{ 6, "Digit5" },          .{ 7, "Digit6" },          .{ 8, "Digit7" },
        .{ 9, "Digit8" },        .{ 10, "Digit9" },         .{ 11, "Digit0" },         .{ 12, "Minus" },
        .{ 13, "Equal" },        .{ 14, "Backspace" },      .{ 15, "Tab" },            .{ 16, "KeyQ" },
        .{ 17, "KeyW" },         .{ 18, "KeyE" },           .{ 19, "KeyR" },           .{ 20, "KeyT" },
        .{ 21, "KeyY" },         .{ 22, "KeyU" },           .{ 23, "KeyI" },           .{ 24, "KeyO" },
        .{ 25, "KeyP" },         .{ 26, "BracketLeft" },    .{ 27, "BracketRight" },   .{ 28, "Enter" },
        .{ 29, "ControlLeft" },  .{ 30, "KeyA" },           .{ 31, "KeyS" },           .{ 32, "KeyD" },
        .{ 33, "KeyF" },         .{ 34, "KeyG" },           .{ 35, "KeyH" },           .{ 36, "KeyJ" },
        .{ 37, "KeyK" },         .{ 38, "KeyL" },           .{ 39, "Semicolon" },      .{ 40, "Quote" },
        .{ 41, "Backquote" },    .{ 42, "ShiftLeft" },      .{ 43, "Backslash" },      .{ 44, "KeyZ" },
        .{ 45, "KeyX" },         .{ 46, "KeyC" },           .{ 47, "KeyV" },           .{ 48, "KeyB" },
        .{ 49, "KeyN" },         .{ 50, "KeyM" },           .{ 51, "Comma" },          .{ 52, "Period" },
        .{ 53, "Slash" },        .{ 54, "ShiftRight" },     .{ 55, "NumpadMultiply" }, .{ 56, "AltLeft" },
        .{ 57, "Space" },        .{ 58, "CapsLock" },       .{ 59, "F1" },             .{ 60, "F2" },
        .{ 61, "F3" },           .{ 62, "F4" },             .{ 63, "F5" },             .{ 64, "F6" },
        .{ 65, "F7" },           .{ 66, "F8" },             .{ 67, "F9" },             .{ 68, "F10" },
        .{ 69, "NumLock" },      .{ 70, "ScrollLock" },     .{ 71, "Numpad7" },        .{ 72, "Numpad8" },
        .{ 73, "Numpad9" },      .{ 74, "NumpadSubtract" }, .{ 75, "Numpad4" },        .{ 76, "Numpad5" },
        .{ 77, "Numpad6" },      .{ 78, "NumpadAdd" },      .{ 79, "Numpad1" },        .{ 80, "Numpad2" },
        .{ 81, "Numpad3" },      .{ 82, "Numpad0" },        .{ 83, "NumpadDecimal" },  .{ 86, "IntlBackslash" },
        .{ 87, "F11" },          .{ 88, "F12" },            .{ 96, "NumpadEnter" },    .{ 97, "ControlRight" },
        .{ 98, "NumpadDivide" }, .{ 99, "PrintScreen" },    .{ 100, "AltRight" },      .{ 102, "Home" },
        .{ 103, "ArrowUp" },     .{ 104, "PageUp" },        .{ 105, "ArrowLeft" },     .{ 106, "ArrowRight" },
        .{ 107, "End" },         .{ 108, "ArrowDown" },     .{ 109, "PageDown" },      .{ 110, "Insert" },
        .{ 111, "Delete" },      .{ 119, "Pause" },         .{ 125, "MetaLeft" },      .{ 126, "MetaRight" },
        .{ 127, "ContextMenu" },
    };
    for (pairs) |pair| table[pair[0]] = pair[1];
    break :blk table;
};

/// X modifier state to `lepton_servo_key`'s bits: 1 shift, 2 control, 4 alt, 8 meta.
pub fn modifiers(state: u16) u32 {
    var bits: u32 = 0;
    if (state & 1 != 0) bits |= 1; // ShiftMask
    if (state & 4 != 0) bits |= 2; // ControlMask
    if (state & 8 != 0) bits |= 4; // Mod1Mask: Alt
    if (state & 64 != 0) bits |= 8; // Mod4Mask: Super
    return bits;
}

test "keys and codes read as the DOM names them" {
    try std.testing.expectEqualStrings("Enter", named(0xff0d).?);
    try std.testing.expectEqualStrings("F12", named(0xffc9).?);
    try std.testing.expect(named('a') == null);
    try std.testing.expectEqualStrings("KeyA", code(30));
    try std.testing.expectEqualStrings("Space", code(57));
    try std.testing.expectEqualStrings("Unidentified", code(127 + 50));
    try std.testing.expectEqual(@as(u32, 1 | 2), modifiers(1 | 4));
}
