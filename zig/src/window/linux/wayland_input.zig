//! Pointer and keyboard input for the Wayland window: the seat's listener tables and
//! the callbacks they dispatch into.
//!
//! Split out of `wayland_window.zig` by responsibility. Every callback here resolves the
//! window it belongs to through `currentInput`, and mutates only the input-facing fields
//! of `WaylandWindow` (`input`, `menu`, `keymap`, the pending action).

const wl = @import("wayland_c.zig").wl;
const input_state = @import("input.zig");
const chrome = @import("chrome.zig");
const gesture = @import("gesture.zig");
const WaylandWindow = @import("wayland_window.zig").WaylandWindow;

/// The keymap the compositor sent, as the raw XKB bytes it sent them in.
///
/// ## What this is not
///
/// A keysym lookup is not implemented, and `keysymFor` therefore returns the raw keycode
/// rather than a translated symbol. That is a deliberate, stated limit rather than a
/// silent one: turning XKB keymap bytes into keysyms means walking the `xkb_keymap` format,
/// and a lookup that guessed a symbol would make a shortcut fire on the wrong key while
/// looking correct. Nothing depends on the translation yet — key *presses* work, and are
/// counted and held correctly — and the first thing that needs keysyms must bring a real
/// map reader with it rather than inherit a guess.
pub const Keymap = struct {
    /// The keymap's own size, as announced. Kept because a short read from the announced
    /// size is the difference between a map and a truncated fragment.
    size: u32 = 0,
    /// Whether bytes were read at all. An unloaded keymap is not an empty one.
    loaded: bool = false,

    /// The key the compositor reported, unchanged.
    pub fn keysymFor(self: Keymap, keycode: u32) u32 {
        _ = self;
        return keycode;
    }
};

/// The xdg-shell edge constants, by name rather than by value.
///
/// The numbers are protocol ABI and belong in exactly one place; a second copy is a
/// second chance to be wrong, and being wrong here resizes from the wrong edge without
/// any visible error.
pub fn resizeEdgeConstant(edge: chrome.input_zone.Edge) u32 {
    return switch (edge) {
        .none => wl.XDG_TOPLEVEL_RESIZE_EDGE_NONE,
        .top => wl.XDG_TOPLEVEL_RESIZE_EDGE_TOP,
        .bottom => wl.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM,
        .left => wl.XDG_TOPLEVEL_RESIZE_EDGE_LEFT,
        .right => wl.XDG_TOPLEVEL_RESIZE_EDGE_RIGHT,
        .top_left => wl.XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT,
        .top_right => wl.XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT,
        .bottom_left => wl.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT,
        .bottom_right => wl.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT,
    };
}

/// Starts listening for pointer and keyboard events on this window's seat.
///
/// A missing seat is not an error: a session can have no input at all — a headless
/// compositor, a remote session with input redirected — and a window that opens without
/// a keyboard there is working, not broken.
pub fn start(self: *WaylandWindow) void {
    const seat = self.seat orelse return;

    inputWindow = self;

    if (wl.wl_seat_get_pointer(seat)) |pointer| {
        self.pointer = @ptrCast(@alignCast(pointer));
        _ = wl.wl_pointer_add_listener(pointer, &pointer_listener, self);
    }
    if (wl.wl_seat_get_keyboard(seat)) |keyboard| {
        self.keyboard = @ptrCast(@alignCast(keyboard));
        _ = wl.wl_keyboard_add_listener(keyboard, &keyboard_listener, self);
    }
}

/// Detaches `self` from the input callbacks, so an event dispatched after the window
/// closed finds no window rather than a freed one.
pub fn release(self: *WaylandWindow) void {
    if (inputWindow == self) inputWindow = null;
}

/// The listener tables, typed by libwayland's own declarations.
///
/// They used to be hand-written `extern struct`s, on the belief that translate-c could
/// not produce `wl_pointer_listener`. Measured with Zig 0.16: it can, completely. The
/// hand-written copy had left out the second C parameter of every callback — the
/// `struct wl_pointer *` / `struct wl_keyboard *` proxy — so each argument arrived one
/// register late: `button` read the timestamp as the button code (every click was
/// dropped as an unknown button), `motion` read the time as x, and `keymap` read
/// `format` (1) as the file descriptor, i.e. stdout. With the C types the compiler
/// checks every callback against the header; a wrong signature no longer compiles.
///
/// A seat bound at version 5 entitles the compositor to every event up to v5, and a null
/// entry is a jump to address zero, so each optional event gets a real (empty) callback.
/// `axis_relative_direction` (v9) and `warp` (v10) are past the bound version.
const pointer_listener = wl.wl_pointer_listener{
    .enter = onPointerEnter,
    .leave = onPointerLeave,
    .motion = onPointerMotion,
    .button = onPointerButton,
    .axis = onPointerAxis,
    .frame = onPointerFrame,
    .axis_source = onPointerAxisSource,
    .axis_stop = onPointerAxisStop,
    .axis_discrete = onPointerAxisDiscrete,
    .axis_value120 = onPointerAxisValue120,
    .axis_relative_direction = onPointerAxisRelative,
    .warp = null,
};

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = onKeyboardKeymap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKeyboardKey,
    .modifiers = onKeyboardModifiers,
    .repeat_info = onKeyboardRepeatInfo,
};

const Pointer = ?*wl.wl_pointer;
const Keyboard = ?*wl.wl_keyboard;
const Surface = ?*wl.wl_surface;

fn onPointerFrame(_: ?*anyopaque, _: Pointer) callconv(.c) void {}
fn onPointerAxisSource(_: ?*anyopaque, _: Pointer, _: u32) callconv(.c) void {}
fn onPointerAxisStop(_: ?*anyopaque, _: Pointer, _: u32, _: u32) callconv(.c) void {}
fn onPointerAxisDiscrete(_: ?*anyopaque, _: Pointer, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisValue120(_: ?*anyopaque, _: Pointer, _: u32, _: i32) callconv(.c) void {}
fn onPointerAxisRelative(_: ?*anyopaque, _: Pointer, _: u32, _: u32) callconv(.c) void {}

fn onKeyboardRepeatInfo(_: ?*anyopaque, _: Keyboard, rate: i32, delay: i32) callconv(.c) void {
    const target = currentInput() orelse return;
    target.repeat_rate_hz = rate;
    target.repeat_delay_ms = delay;
}

/// `wl_pointer.enter` — the pointer arrived on this surface.
///
/// The position arrives as 24.8 fixed point, which is not a detail: passing the raw
/// integer on would put the pointer a hundred times further right and down than it is,
/// and every hit test past the first hundred pixels would land on the wrong control.
fn onPointerEnter(_: ?*anyopaque, _: Pointer, _: u32, _: Surface, sx: i32, sy: i32) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.enter();
    target.input.move(input_state.fixedToDouble(sx), input_state.fixedToDouble(sy));
}

fn onPointerLeave(_: ?*anyopaque, _: Pointer, _: u32, _: Surface) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.leave();
    // The menu is painted inside this window, so a pointer that has left it cannot be
    // over any entry, and leaving one up would keep a highlight nobody can move.
    target.menu.dismiss();
}

fn onPointerMotion(_: ?*anyopaque, _: Pointer, _: u32, sx: i32, sy: i32) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.move(input_state.fixedToDouble(sx), input_state.fixedToDouble(sy));
    if (target.menu.open) target.menu.hover(target.input.x, target.input.y);

    // The armed move starts here, while the press that armed it is still held: its serial
    // is the implicit grab the compositor turns into the interactive move.
    if (target.move_armed and gesture.moveStarts(target.input)) {
        target.move_armed = false;
        const toplevel = target.toplevel orelse return;
        const seat = target.seat orelse return;
        wl.xdg_toplevel_move(toplevel, seat, target.input.press_serial);
    }
}

fn onPointerButton(_: ?*anyopaque, _: Pointer, serial: u32, time_ms: u32, code: u32, state: u32) callconv(.c) void {
    const target = currentInput() orelse return;
    const which = input_state.Button.fromEvdev(code) orelse return;
    const button: u32 = @intFromEnum(which);
    target.input.button(button, state == wl.WL_POINTER_BUTTON_STATE_PRESSED, serial, time_ms);

    const pressed = state == wl.WL_POINTER_BUTTON_STATE_PRESSED;

    if (pressed and !target.menu.open) {
        switch (gesture.onPress(target.input)) {
            .none => {},
            .arm_move => target.move_armed = true,
            .resize => |edge| {
                const toplevel = target.toplevel orelse return;
                const seat = target.seat orelse return;
                wl.xdg_toplevel_resize(toplevel, seat, serial, resizeEdgeConstant(edge));
                return;
            },
        }
    }
    if (!pressed) target.move_armed = false;

    // The right button opens the menu and nothing else. A right press must not also reach
    // the zone logic, or a right click on the titlebar would begin a drag that the left
    // button was never asked for.
    if (pressed and button == (1 << 1)) {
        target.menu.openAt(target.input.x, target.input.y, target.input.width, target.input.height);
        return;
    }

    if (!pressed) {
        // While the menu is up it owns the left button: a click inside it chooses an
        // entry and a click anywhere else dismisses it, and in both cases the click does
        // not also reach whatever was underneath.
        if (target.menu.open and button == (1 << 0)) {
            if (target.menu.entryAt(target.input.x, target.input.y)) |entry| {
                const chosen = target.menu.items[entry];
                target.menu.dismiss();
                target.performAction(chrome.menuAction(chosen));
            } else {
                target.menu.dismiss();
            }
            return;
        }

        // A left press that opened the menu on release dismisses it, so the same press
        // that raised it cannot also act through it.
        if (button == (1 << 0) and target.menu.open) {
            target.menu.dismiss();
            return;
        }

        // A decision is taken only on release. Acting on the press would fire the moment
        // the button went down, before the user had moved far enough to reveal that they
        // meant to drag instead — and the same press would then both move the window and
        // activate the control it started on.
        const action = chrome.actionFor(target.input, time_ms, target.last_click_ms, @popCount(target.input.held_mask) + 1);
        target.action = action;
        target.action_pending = true;
        // Moves and resizes were started while the button was held (see `gesture`); a
        // request made now, with the grab gone, would only be ignored by the compositor.
        switch (action) {
            .begin_drag, .begin_resize => {},
            else => target.performAction(action),
        }
        target.last_click_ms = gesture.nextLastClick(action, time_ms);
    }
}

fn onPointerAxis(_: ?*anyopaque, _: Pointer, _: u32, axis: u32, value: i32) callconv(.c) void {
    const target = currentInput() orelse return;
    const amount = input_state.fixedToDouble(value);
    switch (axis) {
        wl.WL_POINTER_AXIS_VERTICAL_SCROLL => target.input.scroll(0, amount),
        wl.WL_POINTER_AXIS_HORIZONTAL_SCROLL => target.input.scroll(amount, 0),
        else => {},
    }
}

fn onKeyboardKeymap(_: ?*anyopaque, _: Keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const target = currentInput() orelse return;
    target.adoptKeymap(format, fd, size);
}

fn onKeyboardEnter(_: ?*anyopaque, _: Keyboard, _: u32, _: Surface, _: [*c]wl.wl_array) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.keyboard_present = true;
}

fn onKeyboardLeave(_: ?*anyopaque, _: Keyboard, _: u32, _: Surface) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.keyboard_present = false;
}

fn onKeyboardKey(_: ?*anyopaque, _: Keyboard, _: u32, time_ms: u32, keycode: u32, state: u32) callconv(.c) void {
    const target = currentInput() orelse return;
    target.input.key(.{
        .keycode = keycode,
        .keysym = target.keymap.keysymFor(keycode),
        .state = if (state == wl.WL_KEYBOARD_KEY_STATE_PRESSED) .pressed else .released,
        // The protocol marks a repeat with the high bit rather than a separate flag.
        .repeat = keycode & (1 << 16) != 0,
    });
    _ = time_ms;
}

fn onKeyboardModifiers(_: ?*anyopaque, _: Keyboard, _: u32, depressed: u32, _: u32, locked: u32, _: u32) callconv(.c) void {
    const target = currentInput() orelse return;
    // A key that is physically down and a modifier that is latched both count while held,
    // and the protocol reports them in separate masks, so the usable set is their union.
    target.input.modifier(depressed | locked);
}

/// The window the input callbacks belong to.
///
/// Wayland listeners receive only their own pointer, not the window that owns it, and a
/// single-window process is the only shape this file supports — a callback with no handle
/// to anything is worse than one with a documented single answer.
fn currentInput() ?*WaylandWindow {
    return inputWindow;
}

var inputWindow: ?*WaylandWindow = null;
