//! `window.menu` under Servo: the page's menu as a window of Lepton's own on the view's
//! X11 connection. WebView2 has `TrackPopupMenuEx`; X11 has no menu to ask for, so this
//! is an override-redirect window at the pointer, drawn with Cairo in the native path's
//! frame colours (`chrome.palette`), holding the pointer and the keyboard until an item is
//! chosen or the menu is dismissed.
//!
//! Like a native menu (and as Tauri's and Electron's do), it closes, choosing nothing,
//! when the application loses the focus or is minimized.
//!
//! Like a native menu: the release of the press that opened it chooses nothing; a click
//! or a release after moving chooses the item under the pointer; a press outside, or
//! Escape, dismisses it; Up, Down, Home and End move over the items that can be chosen,
//! and Enter or Space chooses. A disabled item and a separator are never chosen.

const std = @import("std");
const build_options = @import("build_options");
const xcb = @import("c_x11");
const x11 = @import("../../../window/linux/x11_window.zig");
const chrome = @import("../../../window/linux/chrome.zig");
const surface = @import("../../surface.zig");
const window = @import("../../../window/window.zig");
const menu_format = @import("../menu.zig");

/// Whether this build can draw the menu's text (Cairo found): without it `open` refuses
/// and `window.menu` answers `failed`, as where there is no menu at all.
pub const available = build_options.have_cairo;
const Text = if (available) @import("../../text.zig").Text else void;
const cairo = if (available) @import("c_cairo") else struct {};

const font_px: f64 = 14;
const row_height: i32 = 28;
const separator_height: i32 = 9;
const padding: i32 = 5;
/// Room left of the labels for a check mark.
const gutter: i32 = 30;
const trailing: i32 = 20;
const min_width: i32 = 168;
/// How far the pointer moves before the release of the opening press may choose.
const arm_distance: i32 = 4;
const disabled_text = surface.Colour.rgb(0x60, 0x66, 0x6d);

const Row = struct {
    id: u16,
    flags: u8,
    label_at: u16,
    label_len: u16,
    top: i32,
    height: i32,

    fn choosable(row: Row) bool {
        return row.flags & (menu_format.Flag.separator | menu_format.Flag.disabled) == 0;
    }
};

/// Called once per `open`, with the chosen id or 0 when the menu was dismissed.
pub const Done = *const fn (context: *anyopaque, id: u16) void;

pub const Menu = struct {
    host: ?*x11.X11Window = null,
    id: xcb.xcb_window_t = 0,
    graphics: xcb.xcb_gcontext_t = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    rows: [menu_format.max_items]Row = undefined,
    count: usize = 0,
    labels: [menu_format.max_items * menu_format.max_label]u8 = undefined,
    hovered: ?usize = null,
    armed: bool = false,
    /// Whether the window manager marked the window focused when the menu opened.
    opened_focused: bool = false,
    opened_x: i32 = 0,
    opened_y: i32 = 0,
    pixels: ?surface.Surface = null,
    text: Text = undefined,
    done: ?Done = null,
    done_context: *anyopaque = undefined,

    pub fn isOpen(self: *const Menu) bool {
        return self.id != 0;
    }

    /// Shows `bytes` (checked by `menu.valid`) at the pointer over `host`'s screen. `done`
    /// is called once, when an item is chosen or the menu is dismissed.
    pub fn open(self: *Menu, host: *x11.X11Window, bytes: []const u8, context: *anyopaque, done: Done) !void {
        if (comptime !available) return error.NoText;
        if (self.isOpen()) return error.Busy;
        self.* = .{ .host = host, .done = done, .done_context = context, .opened_focused = host.hasState("_NET_WM_STATE_FOCUSED") };
        try self.layOut(bytes);
        errdefer self.release();

        const conn = host.conn;
        const pointer = xcb.xcb_query_pointer_reply(conn, xcb.xcb_query_pointer(conn, host.root), null) orelse return error.NoPointer;
        defer std.c.free(pointer);
        self.opened_x = pointer.*.root_x;
        self.opened_y = pointer.*.root_y;
        // Opened at the pointer, kept on the screen: left of it when there is no room on
        // the right, above it when there is none below.
        const screen_w: i32 = host.screen_width;
        const screen_h: i32 = host.screen_height;
        self.x = if (self.opened_x + self.width > screen_w) @max(0, self.opened_x - self.width) else self.opened_x;
        self.y = if (self.opened_y + self.height > screen_h) @max(0, self.opened_y - self.height) else self.opened_y;

        self.id = xcb.xcb_generate_id(conn);
        const mask: u32 = xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_POINTER_MOTION |
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
            xcb.XCB_EVENT_MASK_KEY_PRESS | xcb.XCB_EVENT_MASK_KEY_RELEASE | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;
        // Override-redirect: placed where asked and above the window, as a menu is.
        // Values in the order of their bits: OVERRIDE_REDIRECT, then EVENT_MASK.
        const values = [_]u32{ 1, mask };
        _ = xcb.xcb_create_window(conn, 0, self.id, host.root, @intCast(self.x), @intCast(self.y), @intCast(self.width), @intCast(self.height), 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, 0, xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK, &values);
        self.setType();
        self.graphics = xcb.xcb_generate_id(conn);
        _ = xcb.xcb_create_gc(conn, self.graphics, self.id, 0, null);
        _ = xcb.xcb_map_window(conn, self.id);
        self.paint();
        self.grab();
        host.overlay = .{ .context = self, .handle = &handleEvent };
    }

    /// Takes the items and measures them; allocates the frame the menu is drawn into.
    fn layOut(self: *Menu, bytes: []const u8) !void {
        if (comptime !available) return error.NoText;
        var probe = try surface.Surface.init(std.heap.page_allocator, .{ .width = 8, .height = 8 }, .xrgb8888);
        defer probe.deinit();
        var measure = try Text.init(probe);
        defer measure.deinit();
        measure.setFace("sans-serif", font_px);

        var items = menu_format.items(bytes);
        var used: usize = 0;
        var top: i32 = padding;
        var widest: i32 = 0;
        while (items.next()) |item| : (self.count += 1) {
            const label = shown(item.label, self.labels[used..][0..item.label.len]);
            const height = if (item.isSeparator()) separator_height else row_height;
            self.rows[self.count] = .{ .id = item.id, .flags = item.flags, .label_at = @intCast(used), .label_len = @intCast(label.len), .top = top, .height = height };
            used += label.len;
            top += height;
            if (!item.isSeparator()) widest = @max(widest, measure.widthOf(label));
        }
        self.width = @max(min_width, gutter + widest + trailing);
        self.height = top + padding;

        self.pixels = try surface.Surface.init(std.heap.page_allocator, .{ .width = @intCast(self.width), .height = @intCast(self.height) }, .xrgb8888);
        self.text = Text.init(self.pixels.?) catch |failure| {
            self.pixels.?.deinit();
            self.pixels = null;
            return failure;
        };
        self.text.setFace("sans-serif", font_px);
    }

    /// `_NET_WM_WINDOW_TYPE_POPUP_MENU`, so a compositor treats it as a menu, and
    /// `WM_TRANSIENT_FOR` the window it belongs to.
    fn setType(self: *Menu) void {
        const host = self.host orelse return;
        const kind = host.atom("_NET_WM_WINDOW_TYPE");
        const popup = host.atom("_NET_WM_WINDOW_TYPE_POPUP_MENU");
        if (kind != 0 and popup != 0) _ = xcb.xcb_change_property(host.conn, xcb.XCB_PROP_MODE_REPLACE, self.id, kind, xcb.XCB_ATOM_ATOM, 32, 1, &popup);
        _ = xcb.xcb_change_property(host.conn, xcb.XCB_PROP_MODE_REPLACE, self.id, xcb.XCB_ATOM_WM_TRANSIENT_FOR, xcb.XCB_ATOM_WINDOW, 32, 1, &host.window_id);
    }

    /// The pointer and the keyboard, so a press anywhere and every key reach the menu. A
    /// grab is refused until the window is viewable, so it is asked for a few times.
    fn grab(self: *Menu) void {
        const conn = (self.host orelse return).conn;
        const pointer_mask: u16 = @intCast(xcb.XCB_EVENT_MASK_POINTER_MOTION | xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_LEAVE_WINDOW);
        var tries: usize = 0;
        while (tries < 20) : (tries += 1) {
            const reply = xcb.xcb_grab_pointer_reply(conn, xcb.xcb_grab_pointer(conn, 0, self.id, pointer_mask, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_CURRENT_TIME), null) orelse break;
            const status = reply.*.status;
            std.c.free(reply);
            if (status == xcb.XCB_GRAB_STATUS_SUCCESS) break;
            const pause: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&pause, null);
        }
        if (xcb.xcb_grab_keyboard_reply(conn, xcb.xcb_grab_keyboard(conn, 0, self.id, xcb.XCB_CURRENT_TIME, xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC), null)) |reply| std.c.free(reply);
        _ = xcb.xcb_flush(conn);
    }

    fn handleEvent(context: *anyopaque, event: *const xcb.xcb_generic_event_t) bool {
        const self: *Menu = @ptrCast(@alignCast(context));
        switch (event.response_type & 0x7f) {
            xcb.XCB_EXPOSE => {
                const expose: *const xcb.xcb_expose_event_t = @ptrCast(event);
                if (expose.window != self.id) return false;
                self.paint();
                return true;
            },
            xcb.XCB_MOTION_NOTIFY => {
                const motion: *const xcb.xcb_motion_notify_event_t = @ptrCast(event);
                self.pointerAt(motion.root_x, motion.root_y);
                return true;
            },
            xcb.XCB_BUTTON_PRESS => {
                const press: *const xcb.xcb_button_press_event_t = @ptrCast(event);
                if (press.detail >= 4 and press.detail <= 7) return true;
                if (self.rowAt(press.root_x, press.root_y) == null and !self.inside(press.root_x, press.root_y)) {
                    self.finish(0);
                } else {
                    self.armed = true;
                }
                return true;
            },
            xcb.XCB_BUTTON_RELEASE => {
                const up: *const xcb.xcb_button_press_event_t = @ptrCast(event);
                if (up.detail >= 4 and up.detail <= 7) return true;
                if (!self.armed) {
                    // The release of the press that opened the menu.
                    self.armed = true;
                    return true;
                }
                if (self.rowAt(up.root_x, up.root_y)) |index| {
                    if (self.rows[index].choosable()) self.finish(self.rows[index].id);
                }
                return true;
            },
            xcb.XCB_KEY_PRESS => {
                const key: *const xcb.xcb_key_press_event_t = @ptrCast(event);
                // X keycodes are evdev's plus 8: Escape 1, Enter 28, keypad Enter 96,
                // Space 57, Home 102, Up 103, End 107, Down 108.
                switch (key.detail -% 8) {
                    1 => self.finish(0),
                    28, 96, 57 => if (self.hovered) |index| {
                        if (self.rows[index].choosable()) self.finish(self.rows[index].id);
                    },
                    103 => self.step(-1, false),
                    108 => self.step(1, false),
                    102 => self.step(1, true),
                    107 => self.step(-1, true),
                    else => {},
                }
                return true;
            },
            xcb.XCB_KEY_RELEASE => return true,
            // Another application took the focus: the menu closes. A focus change caused
            // by the menu's own grab (mode Grab or Ungrab) is not one.
            xcb.XCB_FOCUS_OUT => {
                const focus: *const xcb.xcb_focus_out_event_t = @ptrCast(event);
                const host = self.host orelse return false;
                if (focus.event == host.window_id and focus.mode != xcb.XCB_NOTIFY_MODE_GRAB and focus.mode != xcb.XCB_NOTIFY_MODE_UNGRAB and focus.detail != xcb.XCB_NOTIFY_DETAIL_POINTER) self.finish(0);
                return false;
            },
            // The window manager marked the window unfocused or minimized; the window still
            // reads the change for its own `window.state`.
            xcb.XCB_PROPERTY_NOTIFY => {
                const notify: *const xcb.xcb_property_notify_event_t = @ptrCast(event);
                const host = self.host orelse return false;
                if (notify.window == host.window_id and notify.atom == host.atom("_NET_WM_STATE")) {
                    // Only a window that was focused when the menu opened can lose it: a
                    // window manager that never sets `_NET_WM_STATE_FOCUSED` must not
                    // close every menu as it opens.
                    const focused = host.hasState("_NET_WM_STATE_FOCUSED");
                    if ((self.opened_focused and !focused) or host.hasState("_NET_WM_STATE_HIDDEN")) self.finish(0);
                }
                return false;
            },
            xcb.XCB_LEAVE_NOTIFY => {
                const leave: *const xcb.xcb_leave_notify_event_t = @ptrCast(event);
                if (leave.event != self.id) return false;
                if (self.hovered != null) {
                    self.hovered = null;
                    self.paint();
                }
                return true;
            },
            else => return false,
        }
    }

    fn inside(self: *const Menu, root_x: i32, root_y: i32) bool {
        return root_x >= self.x and root_x < self.x + self.width and root_y >= self.y and root_y < self.y + self.height;
    }

    fn rowAt(self: *const Menu, root_x: i32, root_y: i32) ?usize {
        if (!self.inside(root_x, root_y)) return null;
        const y = root_y - self.y;
        for (self.rows[0..self.count], 0..) |row, index| {
            if (y >= row.top and y < row.top + row.height) return index;
        }
        return null;
    }

    fn pointerAt(self: *Menu, root_x: i32, root_y: i32) void {
        const far: u32 = arm_distance;
        if (!self.armed and (@abs(root_x - self.opened_x) > far or @abs(root_y - self.opened_y) > far)) self.armed = true;
        const under = self.rowAt(root_x, root_y);
        const hovered: ?usize = if (under) |index| (if (self.rows[index].choosable()) index else null) else null;
        if (hovered != self.hovered) {
            self.hovered = hovered;
            self.paint();
        }
    }

    /// Moves the highlight by `direction` over the choosable rows; `from_end` starts from
    /// the far end (Home goes forward from before the first, End back from after the last).
    fn step(self: *Menu, direction: i32, from_end: bool) void {
        const n: i32 = @intCast(self.count);
        var at: i32 = if (from_end or self.hovered == null) (if (direction > 0) -1 else n) else @intCast(self.hovered.?);
        var moved: i32 = 0;
        while (moved < n) : (moved += 1) {
            at += direction;
            if (at < 0 or at >= n) return;
            if (self.rows[@intCast(at)].choosable()) {
                self.hovered = @intCast(at);
                self.paint();
                return;
            }
        }
    }

    fn paint(self: *Menu) void {
        if (comptime !available) return;
        const host = self.host orelse return;
        const pixels = self.pixels orelse return;
        const palette = chrome.palette;
        pixels.fill(palette.rule);
        pixels.fillRect(1, 1, self.width - 2, self.height - 2, palette.bar);
        for (self.rows[0..self.count], 0..) |row, index| {
            if (row.flags & menu_format.Flag.separator != 0) {
                pixels.fillRect(8, row.top + @divTrunc(row.height, 2), self.width - 16, 1, palette.rule);
                continue;
            }
            if (self.hovered == index) pixels.fillRect(4, row.top + 1, self.width - 8, row.height - 2, palette.hovered);
            const colour = if (row.flags & menu_format.Flag.disabled != 0) disabled_text else palette.glyph;
            const label = self.labels[row.label_at..][0..row.label_len];
            const extent = self.text.measure(label) orelse continue;
            const baseline = row.top + @divTrunc(row.height - extent.height, 2) + extent.ascent;
            if (row.flags & menu_format.Flag.checked != 0) self.drawCheck(11, row.top + @divTrunc(row.height, 2), colour);
            _ = self.text.draw(gutter, baseline, label, colour);
        }
        const size: window.Size = .{ .width = @intCast(self.width), .height = @intCast(self.height) };
        const bytes = size.stride(.xrgb8888) * size.height;
        _ = xcb.xcb_put_image(host.conn, xcb.XCB_IMAGE_FORMAT_Z_PIXMAP, self.id, self.graphics, @intCast(self.width), @intCast(self.height), 0, 0, 0, host.root_depth, @intCast(bytes), pixels.pixels.ptr);
        _ = xcb.xcb_flush(host.conn);
    }

    /// A check mark drawn as a stroke, not a glyph: the default sans-serif here (Noto
    /// Sans) has no U+2713, and Cairo's toy text API does not fall back to a face that
    /// has (measured: the mark was missing).
    fn drawCheck(self: *Menu, x: i32, middle: i32, colour: surface.Colour) void {
        if (comptime !available) return;
        const context = self.text.context orelse return;
        const left: f64 = @floatFromInt(x);
        const mid: f64 = @floatFromInt(middle);
        cairo.cairo_set_source_rgba(context, @as(f64, @floatFromInt(colour.r)) / 255.0, @as(f64, @floatFromInt(colour.g)) / 255.0, @as(f64, @floatFromInt(colour.b)) / 255.0, 1.0);
        cairo.cairo_set_line_width(context, 1.8);
        cairo.cairo_set_line_cap(context, cairo.CAIRO_LINE_CAP_ROUND);
        cairo.cairo_set_line_join(context, cairo.CAIRO_LINE_JOIN_ROUND);
        cairo.cairo_move_to(context, left, mid);
        cairo.cairo_line_to(context, left + 4.0, mid + 4.0);
        cairo.cairo_line_to(context, left + 11.0, mid - 5.0);
        cairo.cairo_stroke(context);
        cairo.cairo_surface_flush(cairo.cairo_get_target(context));
    }

    /// Ends the menu and reports `id` (0: dismissed).
    pub fn finish(self: *Menu, id: u16) void {
        if (!self.isOpen()) return;
        const done = self.done;
        const context = self.done_context;
        self.release();
        if (done) |call| call(context, id);
    }

    fn release(self: *Menu) void {
        if (self.host) |host| {
            if (host.overlay) |overlay| {
                if (overlay.context == @as(*anyopaque, self)) host.overlay = null;
            }
            if (self.id != 0) {
                _ = xcb.xcb_ungrab_pointer(host.conn, xcb.XCB_CURRENT_TIME);
                _ = xcb.xcb_ungrab_keyboard(host.conn, xcb.XCB_CURRENT_TIME);
                if (self.graphics != 0) _ = xcb.xcb_free_gc(host.conn, self.graphics);
                _ = xcb.xcb_destroy_window(host.conn, self.id);
                _ = xcb.xcb_flush(host.conn);
            }
        }
        if (comptime available) {
            if (self.pixels) |*pixels| {
                self.text.deinit();
                pixels.deinit();
            }
        }
        self.* = .{};
    }
};

/// `label` as the menu shows it, written into `out` (as long as `label`): an access-key
/// marker (`&Copy`, Windows' notation, which the API README's example uses) is dropped and
/// `&&` is one `&`. X has no access keys to underline, and the marker was drawn as it was.
fn shown(label: []const u8, out: []u8) []const u8 {
    var length: usize = 0;
    var at: usize = 0;
    while (at < label.len) : (at += 1) {
        if (label[at] == '&') {
            if (at + 1 < label.len and label[at + 1] == '&') at += 1 else continue;
        }
        out[length] = label[at];
        length += 1;
    }
    return out[0..length];
}

test "an access-key marker is dropped and a doubled one is an ampersand" {
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Copy", shown("&Copy", &out));
    try std.testing.expectEqualStrings("Save & quit", shown("Save && quit", &out));
    try std.testing.expectEqualStrings("Plain", shown("Plain", &out));
    try std.testing.expectEqualStrings("Kopyala", shown("&Kopyala", &out));
}
