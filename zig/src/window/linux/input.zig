//! What the window knows about the pointer and the keyboard, and what it does about it.
//!
//! ## Why the state is separate from the Wayland callbacks
//!
//! Every event this file models arrives as a C callback with a signature the protocol
//! dictates and no place to hang a test. The state those events produce is plain data
//! with ordinary rules — a button is held between its press and its release, a modifier
//! is replaced rather than accumulated, a click is press-then-release inside a distance
//! and a time — and rules like those can only be checked where they can be reached. So
//! the callbacks translate and the rules live here, where a test drives them directly.
//!
//! Nothing in this file talks to Wayland. That is the point: the translation is one line
//! per event, and the behaviour worth testing is everything that happens after.
//!
//! ## Coordinates
//!
//! Surface-local, in pixels, with the origin at the top left and y increasing downward,
//! which is what every pointer event uses and the opposite of what a compositor's own
//! configure uses. Converting once, here, is what keeps the rest of the window from having
//! to know which convention it is holding.

const std = @import("std");

/// Converts one 24.8 fixed-point value to a double.
///
/// Wayland sends coordinates and scroll amounts as 24.8 fixed point: the top 24 bits are
/// the whole part and the low 8 bits are a fraction of 256. Passing the integer through
/// unconverted puts everything a hundred times too far right and down, which looks like a
/// hit-testing bug and is not one.
pub fn fixedToDouble(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

/// Converts one 24.8 fixed-point value to a whole pixel, rounding away from zero.
///
/// Used for the keymap-independent integer fields — keycodes and raw scroll steps — where
/// a fractional result would mean nothing.
pub fn fixedToInt(value: i32) i32 {
    const whole = @divTrunc(value, 256);
    const fraction = @rem(value, 256);
    if (fraction > 128) return whole + 1;
    if (fraction < -128) return whole - 1;
    return whole;
}

/// The pointer buttons Wayland reports. Bit codes, not an index, because the protocol
/// sends a bitmask and pretending otherwise would lose the ones nobody handled.
pub const Button = enum(u32) {
    left = 1 << 0,
    right = 1 << 1,
    middle = 1 << 2,
    side = 1 << 3,
    extra = 1 << 4,
    forward = 1 << 5,
    back = 1 << 6,
    task = 1 << 7,

    /// The button a Wayland `wl_pointer.button` names. The protocol sends the Linux evdev
    /// code (`BTN_LEFT` = 0x110, from `linux/input-event-codes.h`), not a mask bit: read as
    /// a bit, every real click was 272 and was dropped as an unknown button.
    pub fn fromEvdev(code: u32) ?Button {
        return switch (code) {
            0x110 => .left,
            0x111 => .right,
            0x112 => .middle,
            0x113 => .side,
            0x114 => .extra,
            0x115 => .forward,
            0x116 => .back,
            0x117 => .task,
            else => null,
        };
    }

    pub fn fromBit(bit: u32) ?Button {
        return switch (bit) {
            1 << 0 => .left,
            1 << 1 => .right,
            1 << 2 => .middle,
            1 << 3 => .side,
            1 << 4 => .extra,
            1 << 5 => .forward,
            1 << 6 => .back,
            1 << 7 => .task,
            else => null,
        };
    }
};

/// The modifier keys, as the protocol numbers them.
///
/// Kept as the protocol's own bits rather than an enum of Zig values, because the values
/// arrive as a `uint32_t` from C and translating them at the boundary is the only place
/// that conversion can be wrong.
pub const Modifiers = struct {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    alt: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    super: bool = false,
    mod5: bool = false,
    button_left: bool = false,
    button_right: bool = false,
    button_middle: bool = false,

    /// Reads the modifier mask `wl_pointer.modifiers` and `wl_keyboard.modifiers` carry.
    ///
    /// Replaces rather than accumulates: the protocol sends the complete current state on
    /// every change, so setting a bit from a mask that omitted it is the whole update.
    pub fn fromMask(mask: u32) Modifiers {
        return .{
            .shift = mask & (1 << 0) != 0,
            .lock = mask & (1 << 1) != 0,
            .control = mask & (1 << 2) != 0,
            .alt = mask & (1 << 3) != 0,
            .mod2 = mask & (1 << 4) != 0,
            .mod3 = mask & (1 << 5) != 0,
            .super = mask & (1 << 6) != 0,
            .mod5 = mask & (1 << 7) != 0,
            .button_left = mask & (1 << 8) != 0,
            .button_right = mask & (1 << 9) != 0,
            .button_middle = mask & (1 << 10) != 0,
        };
    }

    pub fn any(self: Modifiers) bool {
        return self.shift or self.lock or self.control or self.alt or
            self.mod2 or self.mod3 or self.super or self.mod5 or
            self.button_left or self.button_right or self.button_middle;
    }
};

/// A key press, in the keysyms the keymap reports.
///
/// `keycode` is kept beside the keysym because a shortcut has to know which physical key
/// was used, not only what it produced: `Ctrl+C` and a compose sequence both produce the
/// same keysym and only one of them is the shortcut.
pub const Key = struct {
    keycode: u32,
    keysym: u32,
    state: State,
    repeat: bool,

    pub const State = enum { pressed, released };

    pub fn isPress(self: Key) bool {
        return self.state == .pressed;
    }
};

/// A scroll offset, named so that two reads can be compared with each other.
pub const Scroll = struct { x: f64 = 0, y: f64 = 0 };

/// Where the pointer was when a button went down, kept so a release can be told apart
/// from a drag.
const Press = struct {
    button: Button,
    /// The compositor's serial for the press.
    ///
    /// Carried because a move or a resize is not a request anyone else can make on this
    /// window's behalf: the compositor only honours `xdg_toplevel.move` when it is handed
    /// the serial of the input event it authorised, so a serial not kept here is a serial
    /// that has to be refused.
    serial: u32 = 0,
    x: f64,
    y: f64,
    time_ms: u32,
};

/// Everything the window knows about input.
/// Milliseconds from `then` to `now` on the compositor's clock.
///
/// The clock is a wrapping u32 with an undefined base, so the difference is taken modulo
/// 2^32 and read as signed: forward spans up to ~24 days are exact across the wrap, and a
/// stamp that runs *backwards* — a compositor sending a release earlier than its press —
/// reads as zero instead of overflowing. Every value here is compositor input, and a
/// client that aborts on a compositor's arithmetic is a client anyone can crash.
pub fn elapsedMs(now: u32, then: u32) u32 {
    const signed: i32 = @bitCast(now -% then);
    return if (signed < 0) 0 else @intCast(signed);
}

pub const Input = struct {
    /// Whether a pointer is over the surface at all. Events still arrive outside it, so
    /// this is what tells a window leaving that a button it never saw go down is up.
    pointer_present: bool = false,
    x: f64 = 0,
    y: f64 = 0,

    /// The serial of the most recent press, valid while `press` is set.
    press_serial: u32 = 0,

    held: Button = .left,
    held_mask: u32 = 0,
    press: ?Press = null,

    modifiers: Modifiers = .{},
    scroll_x: f64 = 0,
    scroll_y: f64 = 0,

    keyboard_present: bool = false,
    keys: [64]bool = @splat(false),
    key_count: u32 = 0,

    /// The surface's size in pixels, used to decide which zone a point is in.
    width: u32 = 0,
    height: u32 = 0,

    /// The height of the titlebar strip drawn at the top of the surface.
    titlebar_height: u32 = 0,

    pub const Zone = enum { titlebar, close, minimize, maximize, client, outside };

    /// Records a pointer position.
    pub fn move(self: *Input, x: f64, y: f64) void {
        self.x = x;
        self.y = y;
    }

    pub fn enter(self: *Input) void {
        self.pointer_present = true;
    }

    pub fn leave(self: *Input) void {
        self.pointer_present = false;
        // A drag that leaves the window must not stay held: the release may never arrive,
        // and a button stuck down is worse than one lost.
        self.held_mask = 0;
        self.press = null;
    }

    /// Handles a button going down or up, as the protocol's `state` bit says which.
    pub fn button(self: *Input, bit: u32, down: bool, serial: u32, time_ms: u32) void {
        const which = Button.fromBit(bit) orelse return;
        const button_bit: u32 = @bitCast(@intFromEnum(which));
        if (down) {
            self.held = which;
            self.held_mask |= button_bit;
            // A fresh press starts a new anchor. Only the first button of a sequence sets
            // one, because a second button held during the first turns the pair into a
            // gesture that is not a click and should be measured from where it began.
            if (self.held_mask == button_bit) {
                self.press = .{ .button = which, .x = self.x, .y = self.y, .time_ms = time_ms };
                self.press_serial = serial;
            }
        } else {
            self.held_mask &= ~button_bit;
            // The anchor deliberately survives the release. A click is judged *after* the
            // release — that is when the distance and the duration are both known — so
            // clearing the anchor here would make every completed click read as no click.
            // It is replaced by the next press and dropped when the pointer leaves.
        }
    }

    pub fn isHeld(self: Input, which: Button) bool {
        return self.held_mask & @as(u32, @bitCast(@intFromEnum(which))) != 0;
    }

    pub fn modifier(self: *Input, mask: u32) void {
        self.modifiers = Modifiers.fromMask(mask);
    }

    /// Accumulates a scroll step.
    ///
    /// Accumulated rather than replaced because a compositor sends many small steps for
    /// one flick, and reporting only the last of them would drop most of the gesture.
    pub fn scroll(self: *Input, dx: f64, dy: f64) void {
        self.scroll_x += dx;
        self.scroll_y += dy;
    }

    /// Consumes the accumulated scroll, returning it and resetting.
    pub fn takeScroll(self: *Input) Scroll {
        const out = Scroll{ .x = self.scroll_x, .y = self.scroll_y };
        self.scroll_x = 0;
        self.scroll_y = 0;
        return out;
    }

    /// Records a key event.
    pub fn key(self: *Input, event: Key) void {
        self.keyboard_present = true;
        const index = event.keycode % self.keys.len;
        if (event.isPress()) {
            if (!self.keys[index]) self.key_count += 1;
            self.keys[index] = true;
        } else {
            if (self.keys[index]) self.key_count -= 1;
            self.keys[index] = false;
        }
    }

    pub fn isKeyHeld(self: Input, keycode: u32) bool {
        return self.keys[keycode % self.keys.len];
    }

    /// Whether the last release was a click rather than a drag.
    ///
    /// The threshold is what separates "press and release in the same place" from "press,
    /// move, release", which is the difference between activating a control and dragging
    /// a window. It is generous enough for a hand that moved slightly while pressing and
    /// tight enough that a deliberate drag is never mistaken for a click.
    pub fn wasClick(self: Input, now_ms: u32, distance_limit: f64, time_limit_ms: u32) bool {
        const anchor = self.press orelse return false;
        const dx = self.x - anchor.x;
        const dy = self.y - anchor.y;
        const distance = @sqrt(dx * dx + dy * dy);
        if (distance > distance_limit) return false;
        return elapsedMs(now_ms, anchor.time_ms) <= time_limit_ms;
    }

    /// Which part of the window a point is in.
    ///
    /// The titlebar buttons are squares at the right end of the bar, matching the order
    /// Wayland-side clients conventionally draw them, and each is half the bar's height so
    /// they are reachable without hunting.
    pub fn zoneAt(self: Input, px: f64, py: f64) Zone {
        if (px < 0 or py < 0) return .outside;
        if (px > @as(f64, @floatFromInt(self.width)) or py > @as(f64, @floatFromInt(self.height))) {
            return .outside;
        }
        if (self.titlebar_height == 0) return .client;

        const height = @as(f64, @floatFromInt(self.titlebar_height));
        if (py >= height) return .client;

        // The three buttons occupy the right end; each is as wide as it is tall so they
        // keep a square target whatever the bar is set to.
        const button_width = height;
        const left_edge = @as(f64, @floatFromInt(self.width)) - button_width * 3;
        if (px < left_edge) return .titlebar;
        if (px < left_edge + button_width) return .minimize;
        if (px < left_edge + button_width * 2) return .maximize;
        return .close;
    }
};

test "fixed point converts to the coordinate it means" {
    try std.testing.expectEqual(@as(f64, 0), fixedToDouble(0));
    try std.testing.expectEqual(@as(f64, 1), fixedToDouble(256));
    try std.testing.expectEqual(@as(f64, 0.5), fixedToDouble(128));
    try std.testing.expectEqual(@as(f64, -1.5), fixedToDouble(-384));
}

test "fixed point rounds to the nearest whole pixel" {
    try std.testing.expectEqual(@as(i32, 0), fixedToInt(128));
    try std.testing.expectEqual(@as(i32, 1), fixedToInt(384));
    try std.testing.expectEqual(@as(i32, -1), fixedToInt(-384));
}

test "a button held between press and release is remembered" {
    var input = Input{};
    input.button(1, true, 7, 10);
    try std.testing.expect(input.isHeld(.left));

    input.button(1, false, 8, 20);
    try std.testing.expect(!input.isHeld(.left));
}

test "an unknown button bit is ignored rather than guessed at" {
    var input = Input{};
    input.button(1 << 12, true, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), input.held_mask);
}

test "two buttons held release independently" {
    var input = Input{};
    input.button(1, true, 0, 0);
    input.button(2, true, 0, 0);
    try std.testing.expect(input.isHeld(.left));
    try std.testing.expect(input.isHeld(.right));

    input.button(1, false, 0, 0);
    try std.testing.expect(!input.isHeld(.left));
    try std.testing.expect(input.isHeld(.right));
}

test "leaving the window releases a button that will never report up" {
    var input = Input{};
    input.button(1, true, 0, 0);
    input.leave();
    try std.testing.expect(!input.isHeld(.left));
    try std.testing.expect(!input.pointer_present);
}

test "a modifier mask replaces rather than accumulates" {
    var input = Input{};
    input.modifier(1 << 0 | 1 << 2);
    try std.testing.expect(input.modifiers.shift);
    try std.testing.expect(input.modifiers.control);

    input.modifier(0);
    try std.testing.expect(!input.modifiers.shift);
    try std.testing.expect(!input.modifiers.control);
}

test "scroll accumulates and is then consumed" {
    var input = Input{};
    input.scroll(0, 10);
    input.scroll(0, 5);

    const first = input.takeScroll();
    try std.testing.expectEqual(@as(f64, 15), first.y);
    try std.testing.expectEqual(@as(f64, 0), input.takeScroll().y);
}

test "a key held across a repeat is counted once" {
    var input = Input{};
    input.key(.{ .keycode = 30, .keysym = 0, .state = .pressed, .repeat = false });
    try std.testing.expectEqual(@as(u32, 1), input.key_count);

    // A repeat arrives as another press with the repeat flag set. Counting it would make
    // the count of held keys climb while only one is down.
    input.key(.{ .keycode = 30, .keysym = 0, .state = .pressed, .repeat = true });
    try std.testing.expectEqual(@as(u32, 1), input.key_count);

    input.key(.{ .keycode = 30, .keysym = 0, .state = .released, .repeat = false });
    try std.testing.expectEqual(@as(u32, 0), input.key_count);
}

test "the titlebar zones divide the bar the way they are drawn" {
    var input = Input{ .width = 400, .height = 300, .titlebar_height = 30 };

    try std.testing.expectEqual(Input.Zone.titlebar, input.zoneAt(10, 10));
    try std.testing.expectEqual(Input.Zone.titlebar, input.zoneAt(300, 10));
    try std.testing.expectEqual(Input.Zone.minimize, input.zoneAt(325, 10));
    try std.testing.expectEqual(Input.Zone.maximize, input.zoneAt(355, 10));
    try std.testing.expectEqual(Input.Zone.close, input.zoneAt(385, 10));
    try std.testing.expectEqual(Input.Zone.client, input.zoneAt(10, 100));
    try std.testing.expectEqual(Input.Zone.outside, input.zoneAt(-1, 10));
}

test "a window with no titlebar is all client" {
    var input = Input{ .width = 400, .height = 300, .titlebar_height = 0 };
    try std.testing.expectEqual(Input.Zone.client, input.zoneAt(10, 10));
}
test "a click that straddles the clock's wrap is still a click" {
    // The compositor's clock is a u32 of milliseconds with an undefined base, so it wraps
    // every ~49.7 days of whatever it counts from. A 32 ms click across the wrap is 32 ms.
    var input = Input{};
    input.button(1, true, 0, 0xFFFF_FFF0);
    input.button(1, false, 0, 0x10);
    try std.testing.expect(input.wasClick(0x10, 4, 400));
    try std.testing.expectEqual(@as(u32, 32), elapsedMs(0x10, 0xFFFF_FFF0));
}

test "a release stamped before its press is a zero-length click, not a crash" {
    // Measured on COSMIC: a titlebar click arrived with the release earlier than the
    // press, and the plain subtraction overflowed and aborted the application. The
    // order the events arrived in is the order they happened; the stamp is only advice.
    var input = Input{};
    input.button(1, true, 0, 500);
    input.button(1, false, 0, 400);
    try std.testing.expect(input.wasClick(400, 4, 400));
    try std.testing.expectEqual(@as(u32, 0), elapsedMs(400, 500));
}

test "a long hold across the wrap is still too long" {
    var input = Input{};
    input.button(1, true, 0, 0xFFFF_FF00);
    input.button(1, false, 0, 0x400);
    try std.testing.expect(!input.wasClick(0x400, 4, 400));
}

test "a Wayland button code is read as the evdev code it is" {
    try std.testing.expectEqual(Button.left, Button.fromEvdev(0x110).?);
    try std.testing.expectEqual(Button.right, Button.fromEvdev(0x111).?);
    try std.testing.expectEqual(@as(?Button, null), Button.fromEvdev(1));
    // The old reading: the raw code taken as a mask bit is no button at all.
    try std.testing.expectEqual(@as(?Button, null), Button.fromBit(0x110));
}
