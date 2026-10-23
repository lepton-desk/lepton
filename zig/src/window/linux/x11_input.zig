//! The X11 window's input: one X event at a time into the window's input state, and the
//! native frame's own title bar and menu (`chrome.zig`).
//!
//! Split out of `x11_window.zig` by responsibility, as `wayland_input.zig` is out of the
//! Wayland window; `X11Window.handle` calls `applyEvent`, and `x11_window.zig` re-exports
//! `takeAction`, so callers see no change.

const xcb = @import("c_x11");
const chrome = @import("chrome.zig");
const X11Window = @import("x11_window.zig").X11Window;

/// Translates one X event into input state.
///
/// Every field is read from the event rather than from the window: a button press
/// carries its own coordinates, and reading the pointer position instead would report
/// where the pointer had got to by the time the frame ran rather than where it was
/// when it was pressed.
pub fn applyEvent(self: *X11Window, event: *const xcb.xcb_generic_event_t) void {
    if (self.overlay) |overlay| if (overlay.handle(overlay.context, event)) return;
    switch (event.response_type & ~X11Window.event_bit) {
        xcb.XCB_CONFIGURE_NOTIFY => {
            const cfg: *const xcb.xcb_configure_notify_event_t = @ptrCast(@alignCast(event));
            self.size = .{ .width = cfg.width, .height = cfg.height };
            // The zones follow the size the display server gave, not the size that was
            // asked for: the hit test and the drawn controls have to agree, and after a
            // resize both are measuring the window that exists.
            self.input.width = self.size.width;
            self.input.height = self.size.height;
            self.pending = .{ .size = self.size, .activated = true };
        },
        xcb.XCB_CLIENT_MESSAGE => {
            // The window manager's close (`WM_DELETE_WINDOW`, `acceptClose`), reported the
            // same way a Wayland close is, so the layer above has one way of learning a
            // window went away. Other client messages are not a close.
            const message: *const xcb.xcb_client_message_event_t = @ptrCast(@alignCast(event));
            if (self.delete_window != 0 and message.data.data32[0] == self.delete_window)
                self.pending = .{ .size = .{ .width = 0, .height = 0 }, .activated = false };
        },
        xcb.XCB_ENTER_NOTIFY => self.input.enter(),
        xcb.XCB_LEAVE_NOTIFY => {
            self.input.leave();
            self.menu.dismiss();
        },
        xcb.XCB_MOTION_NOTIFY => {
            const motion: *const xcb.xcb_motion_notify_event_t = @ptrCast(event);
            self.input.move(motion.event_x, motion.event_y);
            if (self.menu.open) self.menu.hover(self.input.x, self.input.y);
        },
        xcb.XCB_BUTTON_PRESS, xcb.XCB_BUTTON_RELEASE => {
            const press: *const xcb.xcb_button_press_event_t = @ptrCast(event);
            const down = event.response_type & ~X11Window.event_bit == xcb.XCB_BUTTON_PRESS;
            self.input.move(press.event_x, press.event_y);
            handleButton(self, press.detail, down);
        },
        xcb.XCB_PROPERTY_NOTIFY => {
            const notify: *const xcb.xcb_property_notify_event_t = @ptrCast(event);
            if (notify.atom == self.atom("_NET_WM_STATE")) self.state_changed = true;
        },
        xcb.XCB_KEY_PRESS, xcb.XCB_KEY_RELEASE => {
            const key: *const xcb.xcb_key_press_event_t = @ptrCast(event);
            self.input.modifier(key.state);
            if (self.key_count < self.keys.len) {
                self.keys[self.key_count] = .{
                    .keycode = key.detail,
                    .state = key.state,
                    .pressed = event.response_type & ~X11Window.event_bit == xcb.XCB_KEY_PRESS,
                };
                self.key_count += 1;
            }
            self.input.key(.{
                // X keycodes start at 8 while `Input` counts from 1, and leaving the
                // offset in place would make every keycode one bit group off from the
                // one the Wayland path reports for the same physical key.
                .keycode = key.detail - self.min_keycode + 1,
                .keysym = 0,
                .state = if (event.response_type & ~X11Window.event_bit == xcb.XCB_KEY_PRESS) .pressed else .released,
                .repeat = false,
            });
        },
        else => {},
    }
}

/// Pixels one wheel step scrolls: three lines, as browsers scroll.
const wheel_step: f64 = 48;

/// One button press or release, translated into the shared input rules.
///
/// The right button opens the menu and never reaches the zone logic, exactly as on
/// Wayland: a right press on the titlebar must not begin a drag the left button was
/// never asked for.
/// The native path's own frame: a right press opens its menu, a release chooses from it
/// or acts on the title bar. Null when the event was the frame's alone.
fn handleChrome(self: *X11Window, detail: u8, down: bool) ?void {
    if (down and detail == 3) {
        self.menu.openAt(self.input.x, self.input.y, self.input.width, self.input.height);
        return null;
    }
    if (!down and self.menu.open and detail == 1) {
        if (self.menu.entryAt(self.input.x, self.input.y)) |entry| {
            const chosen = self.menu.items[entry];
            self.menu.dismiss();
            self.chosen = chrome.menuAction(chosen);
            self.chosen_pending = true;
        } else {
            self.menu.dismiss();
        }
        return null;
    }
    if (!down and detail == 1) {
        if (self.menu.open) {
            self.menu.dismiss();
            return null;
        }
        self.chosen = chrome.actionFor(self.input, 0, self.last_click_ms, 1);
        self.chosen_pending = true;
    }
    return {};
}

fn handleButton(self: *X11Window, detail: u8, down: bool) void {
    if (self.own_chrome) handleChrome(self, detail, down) orelse return;
    // Buttons 4 to 7 are the wheel, one press per step (up, down, left, right), in the
    // pixels a step scrolls. They were read as the side and back buttons, so a wheel step
    // reached a page as "back".
    switch (detail) {
        4, 5, 6, 7 => {
            if (down) switch (detail) {
                4 => self.input.scroll(0, -wheel_step),
                5 => self.input.scroll(0, wheel_step),
                6 => self.input.scroll(-wheel_step, 0),
                else => self.input.scroll(wheel_step, 0),
            };
            return;
        },
        else => {},
    }
    // X button numbering starts at 1 and is an index; the shared rules want the
    // protocol's bit, so the two are translated here rather than in the rules. 8 and 9
    // are the back and forward buttons.
    const bit: u32 = switch (detail) {
        1 => 1 << 0,
        2 => 1 << 2,
        3 => 1 << 1,
        8 => 1 << 6,
        9 => 1 << 5,
        else => return,
    };
    self.input.button(bit, down, 0, 0);
}

/// Takes the action the last button release decided, if any.
///
/// Consumed rather than read: an action nobody took would be re-applied on the next frame,
/// and a close would run every frame until the process ended.
pub fn takeAction(self: *X11Window) chrome.Action {
    if (!self.chosen_pending) return .none;
    self.chosen_pending = false;
    return self.chosen;
}
