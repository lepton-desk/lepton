//! An X11 window, built on `libxcb`.
//!
//! XCB rather than Xlib, for the same reason the display probe uses it: Xlib
//! allocates, opens its own connections behind accessors, and hands values back
//! through functions. XCB is the protocol library, so a query here is a request
//! and a reply, and the geometry comes back as integers — which matters most at
//! startup, where an allocator is exactly what should not be running.
//!
//! The flow is the X11 one: create a colormap and window, set the event mask,
//! map it, then let the server send events. Unlike Wayland, a size request here
//! takes effect immediately, so `resize` is a command rather than a negotiation
//! — the asymmetry is a property of the two window systems, not of this layer.

const std = @import("std");
const posix = std.posix;

const xcb = @import("c_x11");

const window = @import("../window.zig");
const platform_display = @import("../../platform/linux/display.zig");
const input_state = @import("input.zig");
const chrome = @import("chrome.zig");
const placement = @import("placement.zig");

pub const Size = window.Size;
pub const Configure = window.Configure;
pub const Request = window.Request;

pub const Error = window.Error || error{
    /// The display could not be opened.
    ConnectionFailed,
    /// The server advertised no screens, so there is nothing to open a window on.
    NoScreens,
};

/// What the window knows about itself between events.
pub const X11Window = struct {
    conn: *xcb.xcb_connection_t,

    /// Pointer and keyboard state, shared with the Wayland path so both backends obey
    /// the same rules rather than two copies of them.
    input: input_state.Input = .{},
    menu: chrome.Menu = .{},

    /// The action decided by the last button release, and whether it has been taken.
    ///
    /// Set on release and read by the caller at the top of its frame, because an action
    /// decided inside an event callback has nowhere to return to: the loop is inside
    /// `pumpEvents` and the window's own decisions live in the code that draws it.
    chosen: chrome.Action = .none,
    chosen_pending: bool = false,
    last_click_ms: ?u32 = null,

    /// The lowest keycode the display server uses, read from its setup.
    ///
    /// From the server rather than a constant: X11 keycodes start at whatever the server
    /// says they start at, and a file that assumed 8 would be off by that much on any
    /// server that chose otherwise — quietly, and only in the key numbers.
    min_keycode: u8 = 8,
    window_id: xcb.xcb_window_t = 0,
    graphics: xcb.xcb_gcontext_t = 0,
    /// The size the server last reported through a configure event.
    size: Size = .{ .width = 0, .height = 0 },
    /// The root visual's depth, which every window created on it inherits and which
    /// an image must match to be accepted.
    root_depth: u8 = 24,
    /// The configure the server sent, pending until the caller takes it.
    pending: ?Configure = null,
    /// The title is copied into the window by `xcb_change_property`, so it does
    /// not have to outlive the call.
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    /// Key events since `takeKeys`, as the server sent them: a caller that maps keys
    /// itself (Servo's view, which needs DOM names) reads the keycode and modifier state.
    /// Oldest first; when full, the newest are dropped rather than the order broken.
    keys: [32]RawKey = undefined,
    key_count: usize = 0,
    /// The root window and the screen's size, for placing the window in the middle.
    root: xcb.xcb_window_t = 0,
    screen_width: u16 = 0,
    screen_height: u16 = 0,
    /// Set when the window manager changed `_NET_WM_STATE`; `takeStateChange` reads it.
    state_changed: bool = false,

    /// One key event, raw: X's keycode (from `min_keycode`) and the modifier and group
    /// state of the event.
    pub const RawKey = struct { keycode: u8, state: u16, pressed: bool };

    /// The key events since the last call, oldest first.
    pub fn takeKeys(self: *X11Window, out: []RawKey) []RawKey {
        const n = @min(self.key_count, out.len);
        @memcpy(out[0..n], self.keys[0..n]);
        self.key_count = 0;
        return out[0..n];
    }

    /// Connects to the display named by `DISPLAY` and opens a window.
    pub fn open(request: Request) Error!X11Window {
        const display = x11Display() orelse return error.ConnectionFailed;

        const conn = xcb.xcb_connect(@ptrCast(display), null) orelse return error.ConnectionFailed;
        errdefer xcb.xcb_disconnect(conn);
        if (xcb.xcb_connection_has_error(conn) != 0) return error.ConnectionFailed;

        const setup = xcb.xcb_get_setup(conn) orelse return error.ConnectionFailed;
        const screen = firstScreen(@ptrCast(setup)) orelse return error.NoScreens;

        // Resource ids are allocated by the client in ranges the server reserves,
        // so this is where the window and its graphics context come from.
        const window_id = xcb.xcb_generate_id(conn);
        const graphics = xcb.xcb_generate_id(conn);

        // The value list is empty: the window is created on the parent screen's
        // visual with no attribute overrides, which is what a first window should
        // be. Every attribute the window needs is set explicitly afterwards.
        // Centred on the screen, as a Wayland compositor places a new window; the hints
        // below ask the window manager to keep the position rather than choose its own.
        const at = centred(request.size, screen.width_in_pixels, screen.height_in_pixels);
        _ = xcb.xcb_create_window(
            conn,
            xcb.XCB_COPY_FROM_PARENT,
            window_id,
            screen.root,
            at.x,
            at.y,
            @intCast(request.size.width),
            @intCast(request.size.height),
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            0,
            null,
        );

        // Input events are selected here rather than left to the pointer being polled:
        // X delivers no key or button event to a window that did not ask for it, so a
        // window that selected only `EXPOSURE` would be unclickable rather than slow.
        //
        // `KEY_PRESS`/`KEY_RELEASE` need the pointer's key state, not the window's, so
        // they are selected on the root window as well; a window that owns no key state
        // receives no key event at all.
        var mask: u32 = xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_EXPOSURE |
            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
            xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
            xcb.XCB_EVENT_MASK_POINTER_MOTION |
            xcb.XCB_EVENT_MASK_KEY_PRESS |
            xcb.XCB_EVENT_MASK_KEY_RELEASE |
            xcb.XCB_EVENT_MASK_ENTER_WINDOW |
            xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
            // `_NET_WM_STATE` changes: maximized, fullscreen, focused (`state`).
            xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

        var root_mask: u32 = xcb.XCB_EVENT_MASK_KEY_PRESS | xcb.XCB_EVENT_MASK_KEY_RELEASE;
        _ = xcb.xcb_change_window_attributes(conn, screen.root, xcb.XCB_CW_EVENT_MASK, @ptrCast(&root_mask));
        _ = xcb.xcb_change_window_attributes(conn, window_id, xcb.XCB_CW_EVENT_MASK, @ptrCast(&mask));

        _ = xcb.xcb_create_gc(conn, graphics, window_id, 0, null);

        var self = X11Window{
            .conn = conn,
            .window_id = window_id,
            .graphics = graphics,
            .size = request.size,
            // From the server's own setup rather than a constant: see `min_keycode`.
            .min_keycode = setup.*.min_keycode,
            // Read from the screen rather than assumed: a server with a depth-30 or
            // depth-16 root visual exists, and sending an image whose depth does not
            // match it is refused by `BadMatch` with a message that names neither.
            .root_depth = @intCast(screen.root_depth),
            .root = screen.root,
            .screen_width = screen.width_in_pixels,
            .screen_height = screen.height_in_pixels,
        };
        self.setTitle(request.title);
        self.setAppId(request.app_id);
        setPositionHints(conn, window_id, at, request.size);

        if (request.mapped) _ = xcb.xcb_map_window(conn, window_id);
        // The request is flushed explicitly rather than left to the library's
        // convenience layer, because the size the caller asked for should be the
        // size the server has been told about before anything reads it back.
        if (xcb.xcb_flush(conn) <= 0) return error.ConnectionFailed;

        return self;
    }

    /// The window's state in `invoke.WindowState`'s bits (fullscreen 1, maximized 2,
    /// active 4), from `_NET_WM_STATE` (EWMH); null when the window manager keeps none.
    pub fn state(self: *X11Window) ?u32 {
        const property = self.atom("_NET_WM_STATE");
        if (property == 0) return null;
        // ATOM (4); 32 atoms is more than any window carries.
        const reply = xcb.xcb_get_property_reply(self.conn, xcb.xcb_get_property(self.conn, 0, self.window_id, property, 4, 0, 32), null) orelse return null;
        defer std.c.free(reply);
        const count: usize = @intCast(@divTrunc(xcb.xcb_get_property_value_length(reply), 4));
        const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        const fullscreen = self.atom("_NET_WM_STATE_FULLSCREEN");
        const vertical = self.atom("_NET_WM_STATE_MAXIMIZED_VERT");
        const horizontal = self.atom("_NET_WM_STATE_MAXIMIZED_HORZ");
        const focused = self.atom("_NET_WM_STATE_FOCUSED");
        var bits: u32 = 0;
        var maximized: u2 = 0;
        for (atoms[0..count]) |each| {
            if (each == fullscreen) bits |= 1;
            if (each == vertical) maximized += 1;
            if (each == horizontal) maximized += 1;
            if (each == focused) bits |= 4;
        }
        if (maximized == 2) bits |= 2;
        return bits;
    }

    /// Whether `_NET_WM_STATE` changed since the last call.
    pub fn takeStateChange(self: *X11Window) bool {
        defer self.state_changed = false;
        return self.state_changed;
    }

    /// Asks the window manager to minimize the window (ICCCM `WM_CHANGE_STATE` to
    /// `IconicState`). False when there is no such atom to ask with.
    pub fn minimize(self: *X11Window) bool {
        const change = self.atom("WM_CHANGE_STATE");
        if (change == 0) return false;
        return self.toRoot(change, .{ 3, 0, 0, 0, 0 });
    }

    /// Asks the window manager to maximize or restore the window (`_NET_WM_STATE`).
    pub fn setMaximized(self: *X11Window, maximized: bool) bool {
        const property = self.atom("_NET_WM_STATE");
        if (property == 0) return false;
        // 1 add, 0 remove; both axes; source 1, an application.
        return self.toRoot(property, .{ @intFromBool(maximized), self.atom("_NET_WM_STATE_MAXIMIZED_VERT"), self.atom("_NET_WM_STATE_MAXIMIZED_HORZ"), 1, 0 });
    }

    /// A client message about this window to the root window, as EWMH and ICCCM ask
    /// requests to the window manager to be sent.
    fn toRoot(self: *X11Window, message_type: u32, data: [5]u32) bool {
        var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
        event.response_type = xcb.XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = self.window_id;
        event.type = message_type;
        event.data.data32 = data;
        const mask: u32 = xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
        _ = xcb.xcb_send_event(self.conn, 0, self.root, mask, @ptrCast(&event));
        return xcb.xcb_flush(self.conn) > 0;
    }

    /// An atom by name, 0 when the server cannot make it.
    fn atom(self: *X11Window, name: []const u8) u32 {
        const reply = xcb.xcb_intern_atom_reply(self.conn, xcb.xcb_intern_atom(self.conn, 0, @intCast(name.len), name.ptr), null) orelse return 0;
        defer std.c.free(reply);
        return reply.*.atom;
    }

    /// Shows a window opened with `mapped = false`.
    pub fn map(self: *X11Window) void {
        _ = xcb.xcb_map_window(self.conn, self.window_id);
        _ = xcb.xcb_flush(self.conn);
    }

    /// Destroys the window and closes the connection.
    pub fn close(self: *X11Window) void {
        _ = xcb.xcb_free_gc(self.conn, self.graphics);
        _ = xcb.xcb_destroy_window(self.conn, self.window_id);
        _ = xcb.xcb_flush(self.conn);
        xcb.xcb_disconnect(self.conn);
        self.window_id = 0;
        self.graphics = 0;
        self.conn = undefined;
    }

    /// Resizes the window. On X11 this takes effect immediately; the server still
    /// answers with a configure event, which is what `takeConfigure` reports.
    pub fn resize(self: *X11Window, size: Size) Error!void {
        if (size.isEmpty()) return error.SizeRefused;

        // The value list is positional and follows the mask, not a struct: XCB
        // writes and reads a flat word list whose order the mask selects. Width
        // comes before height, and a wrong order here resizes the window
        // transposed rather than failing.
        // The mask is XCB's named bits: it was `(1 << 0) | (1 << 1)`, which are X and Y,
        // so a resize to 1200×800 moved the window to (1200, 800) at its old size
        // (measured with `xwininfo` under Servo, 2026-10-20).
        var values = [_]u32{ size.width, size.height };
        const mask: u32 = xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
        _ = xcb.xcb_configure_window(
            self.conn,
            self.window_id,
            mask,
            @ptrCast(&values),
        );
        if (xcb.xcb_flush(self.conn) <= 0) return error.DisplayLost;
    }

    /// Resizes the window to `size`, made to fit the work area, and centres it there, as
    /// a Wayland compositor does for the core's other windows; returns the size used.
    /// The work area is `_NET_WORKAREA` when the window manager publishes it; COSMIC's
    /// XWayland does not (measured), so then nine tenths of the screen, which leaves a
    /// desktop's panels uncovered (a 1200x800 window on a 1366x768 screen grew past the
    /// bottom edge from where an 800x600 one had been centred).
    pub fn resizeCentred(self: *X11Window, size: Size) Error!Size {
        if (size.isEmpty()) return error.SizeRefused;
        const area = self.workArea();
        const fitted = placement.fit(size, .{ .width = area.width, .height = area.height });
        const x: i32 = area.x + @divTrunc(@as(i32, @intCast(area.width)) - @as(i32, @intCast(fitted.width)), 2);
        const y: i32 = area.y + @divTrunc(@as(i32, @intCast(area.height)) - @as(i32, @intCast(fitted.height)), 2);
        var values = [_]u32{ @bitCast(x), @bitCast(y), fitted.width, fitted.height };
        const mask: u32 = xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
        _ = xcb.xcb_configure_window(self.conn, self.window_id, mask, @ptrCast(&values));
        setPositionHints(self.conn, self.window_id, .{ .x = @as(i16, @intCast(x)), .y = @as(i16, @intCast(y)) }, fitted);
        if (xcb.xcb_flush(self.conn) <= 0) return error.DisplayLost;
        return fitted;
    }

    const Area = struct { x: i32, y: i32, width: u32, height: u32 };

    fn workArea(self: *X11Window) Area {
        const fallback: Area = blk: {
            const w: u32 = self.screen_width;
            const h: u32 = self.screen_height;
            break :blk .{ .x = @intCast((w - w * 9 / 10) / 2), .y = @intCast((h - h * 9 / 10) / 2), .width = w * 9 / 10, .height = h * 9 / 10 };
        };
        const name = "_NET_WORKAREA";
        const atom_reply = xcb.xcb_intern_atom_reply(self.conn, xcb.xcb_intern_atom(self.conn, 1, name.len, name), null) orelse return fallback;
        defer std.c.free(atom_reply);
        if (atom_reply.*.atom == 0) return fallback;
        // CARDINAL (6), four per desktop: x, y, width, height; the first desktop's.
        const reply = xcb.xcb_get_property_reply(self.conn, xcb.xcb_get_property(self.conn, 0, self.root, atom_reply.*.atom, 6, 0, 4), null) orelse return fallback;
        defer std.c.free(reply);
        if (xcb.xcb_get_property_value_length(reply) < 16) return fallback;
        const words: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        if (words[2] == 0 or words[3] == 0) return fallback;
        return .{ .x = @bitCast(words[0]), .y = @bitCast(words[1]), .width = words[2], .height = words[3] };
    }

    /// Sets the title the window manager shows.
    pub fn setTitle(self: *X11Window, text: []const u8) void {
        const n = @min(text.len, self.title.len - 1);
        @memcpy(self.title[0..n], text[0..n]);
        self.title[n] = 0;
        self.title_len = n;

        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            self.window_id,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(n),
            &self.title,
        );
        // Sent now: a window nothing else flushes (Servo draws through its own Xlib
        // connection) kept its old name, the request waiting in XCB's buffer (measured).
        _ = xcb.xcb_flush(self.conn);
    }

    /// Sets the window's class and instance, which is how a window manager groups
    /// windows with their application.
    pub fn setAppId(self: *X11Window, text: []const u8) void {
        // `WM_CLASS` is two NUL-terminated strings, so the value is built here
        // rather than passed straight through: a single string would leave the
        // window with no instance name, which some desktops use for their icon.
        var buf: [512]u8 = @splat(0);
        const n = @min(text.len, buf.len / 2 - 1);
        @memcpy(buf[0..n], text[0..n]);
        buf[n] = 0;
        const instance_len = n + 1;
        @memcpy(buf[instance_len .. instance_len + n], text[0..n]);
        buf[instance_len + n] = 0;

        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            self.window_id,
            xcb.XCB_ATOM_WM_CLASS,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(instance_len * 2),
            &buf,
        );
    }

    /// The size the server last reported.
    pub fn currentSize(self: *X11Window) Size {
        return self.size;
    }

    /// The configure the server sent, if any.
    pub fn takeConfigure(self: *X11Window) ?Configure {
        const c = self.pending orelse return null;
        self.pending = null;
        return c;
    }

    /// Waits for the next event from the server, then drains what is queued.
    ///
    /// The timeout is honoured by polling the connection's file descriptor rather
    /// than by blocking in the library, so a caller that has work of its own does
    /// not have to choose between the two.
    pub fn wait(self: *X11Window, timeout_ms: i32) Error!void {
        const fd: posix.fd_t = @intCast(xcb.xcb_get_file_descriptor(self.conn));
        var fds = [_]posix.pollfd{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, timeout_ms) catch return error.DisplayLost;
        if (fds[0].revents & posix.POLL.IN == 0) return;

        // `poll_for_event` blocks, but only after the descriptor said there was
        // something to read, so it returns immediately here in practice.
        while (xcb.xcb_poll_for_event(self.conn)) |event| {
            self.handle(event);
        }
    }

    /// The bit the X server sets on every event it sends.
    ///
    /// Not a constant from the XCB headers, because none exists: the protocol sets
    /// bit 7 of `response_type` to distinguish an event from a reply or an error,
    /// and there is no name for it. Masking it off is what turns `response_type` back
    /// into the event code, which is what `xcb.XCB_CONFIGURE_NOTIFY` and friends
    /// compare against.
    const event_bit: u8 = 0x80;

    /// Applies one event, recording a configure for the caller to take.
    fn handle(self: *X11Window, event: *xcb.xcb_generic_event_t) void {
        const kind = event.response_type & ~event_bit;
        switch (kind) {
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
                // A close request from the window manager arrives as a client
                // message; it is reported the same way a Wayland close is, so the
                // layer above has one way of learning a window went away.
                self.pending = Configure{ .size = Size{ .width = 0, .height = 0 }, .activated = false };
            },
            else => {},
        }
        // XCB has no `xcb_free_event`: an event from `xcb_poll_for_event` is
        // plain `malloc`'d memory and belongs to the caller, who releases it with
        // `free`. Leaking one event per frame would be invisible until the process
        // was killed, which is exactly the kind of bug a real window test catches
        // and a unit test never will.
        std.c.free(event);
    }
};

/// The first screen of the setup, or null when the server offers none.
/// Copies a rendered frame into the window.
///
/// X11 has no shared memory in the Wayland sense, so the frame travels as an
/// `xcb_image_t` the server reads directly from this process's memory. That is one
/// copy per frame too, and it is why a Wayland client and an X11 client can share a
/// renderer that knows about neither.
///
/// The image is destroyed before returning. `xcb_put_image` is asynchronous, and an
/// `xcb_image_t` may reuse its buffer once the request has been written, so holding
/// it past the flush would free memory the server might still be reading.
/// Drains the connection's events into this window's input state.
///
/// Called once per frame rather than from a loop of its own: the native path already
/// wakes on the connection and redraws, and a second loop would race the first for the
/// same events.
pub fn pumpEvents(self: *X11Window) void {
    var event = xcb.xcb_poll_for_event(self.conn) orelse return;
    while (true) {
        applyEvent(self, event);
        const next = xcb.xcb_poll_for_event(self.conn) orelse break;
        event = next;
    }
}

/// Applies one queued event, if there is one; false when the queue is empty.
///
/// For a caller that forwards input as it happens (the Servo engine): a click's press
/// and release arrive together, and after `pumpEvents` the held buttons read the same as
/// before, so a click compared before and after a whole drain was never seen.
pub fn pumpOne(self: *X11Window) bool {
    const event = xcb.xcb_poll_for_event(self.conn) orelse return false;
    applyEvent(self, event);
    return true;
}

/// The connection's descriptor, for a caller that waits on it beside its own (the Servo
/// engine also waits on the eventfd Servo wakes it with).
pub fn connectionFd(self: *X11Window) i32 {
    return @intCast(xcb.xcb_get_file_descriptor(self.conn));
}

/// Translates one X event into input state.
///
/// Every field is read from the event rather than from the window: a button press
/// carries its own coordinates, and reading the pointer position instead would report
/// where the pointer had got to by the time the frame ran rather than where it was
/// when it was pressed.
fn applyEvent(self: *X11Window, event: *const xcb.xcb_generic_event_t) void {
    switch (event.response_type & 0x7f) {
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
            const down = event.response_type & 0x7f == xcb.XCB_BUTTON_PRESS;
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
                    .pressed = event.response_type & 0x7f == xcb.XCB_KEY_PRESS,
                };
                self.key_count += 1;
            }
            self.input.key(.{
                // X keycodes start at 8 while `Input` counts from 1, and leaving the
                // offset in place would make every keycode one bit group off from the
                // one the Wayland path reports for the same physical key.
                .keycode = key.detail - self.min_keycode + 1,
                .keysym = 0,
                .state = if (event.response_type & 0x7f == xcb.XCB_KEY_PRESS) .pressed else .released,
                .repeat = false,
            });
        },
        else => {},
    }
}

/// Pixels one wheel step scrolls: three lines, as browsers scroll.
const wheel_step: f64 = 48;

/// Where a window of `size` sits centred on a screen of `width` by `height`.
fn centred(size: Size, width: u16, height: u16) struct { x: i16, y: i16 } {
    const w: i32 = @intCast(size.width);
    const h: i32 = @intCast(size.height);
    return .{
        .x = @intCast(@max(@divTrunc(@as(i32, width) - w, 2), 0)),
        .y = @intCast(@max(@divTrunc(@as(i32, height) - h, 2), 0)),
    };
}

/// `WM_NORMAL_HINTS` (ICCCM 4.1.2.3) with the position the window was created at and its
/// size, flagged as the program's own (`USPosition | PPosition | PSize`), so the window
/// manager keeps them.
fn setPositionHints(conn: *xcb.xcb_connection_t, target: xcb.xcb_window_t, at: anytype, size: Size) void {
    const us_position: u32 = 1;
    const p_position: u32 = 4;
    const p_size: u32 = 8;
    var hints: [18]u32 = @splat(0);
    hints[0] = us_position | p_position | p_size;
    hints[1] = @bitCast(@as(i32, at.x));
    hints[2] = @bitCast(@as(i32, at.y));
    hints[3] = size.width;
    hints[4] = size.height;
    // `WM_NORMAL_HINTS` and `WM_SIZE_HINTS` are predefined atoms 40 and 41.
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, target, 40, 41, 32, hints.len, &hints);
}

/// One button press or release, translated into the shared input rules.
///
/// The right button opens the menu and never reaches the zone logic, exactly as on
/// Wayland: a right press on the titlebar must not begin a drag the left button was
/// never asked for.
fn handleButton(self: *X11Window, detail: u8, down: bool) void {
    if (down and detail == 3) {
        self.menu.openAt(self.input.x, self.input.y, self.input.width, self.input.height);
        return;
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
        return;
    }
    if (!down and detail == 1) {
        if (self.menu.open) {
            self.menu.dismiss();
            return;
        }
        self.chosen = chrome.actionFor(self.input, 0, self.last_click_ms, 1);
        self.chosen_pending = true;
    }
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

pub fn presentPixels(handle: *anyopaque, pixels: []const u8, frame: Size, format: window.PixelFormat) window.Error!void {
    const self: *X11Window = @ptrCast(@alignCast(handle));
    if (frame.isEmpty()) return error.SizeRefused;

    // The protocol carries the extent in `u16`. A window past that is a protocol limit
    // rather than a rendering one, and refusing it names the real cause instead of
    // failing inside the server with a truncated frame.
    if (frame.width > std.math.maxInt(u16) or frame.height > std.math.maxInt(u16)) {
        return error.SizeRefused;
    }

    const stride = frame.stride(format);
    const needed = stride * frame.height;

    // A frame from a renderer that believes the window is a different size is refused
    // rather than truncated: a truncated frame looks like a drawing bug, and the
    // developer would go looking for one.
    if (pixels.len < needed) return error.FrameTruncated;
    if (needed > std.math.maxInt(u32)) return error.SizeRefused;

    // `xcb_put_image` takes the image header's fields as arguments rather than as a
    // struct, and this call's argument order is the protocol's, not the header's.
    //
    // The depth is the *drawable's*, not the frame's, and the two are not the same.
    // X requires an image's depth to match the drawable it goes into, and a window
    // created on the root visual is depth 24 on almost every server — so a 32-bit
    // frame is sent as a 24-bit image with a 32-bit scanline, where the fourth byte of
    // each pixel is not read. That is why `xrgb8888` exists as a format: an opaque
    // window with no alpha visual cannot be sent alpha at all.
    const depth: u8 = self.root_depth;

    const cookie = xcb.xcb_put_image(
        self.conn,
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
        self.window_id,
        self.graphics,
        @intCast(frame.width),
        @intCast(frame.height),
        0,
        0,
        0,
        depth,
        @intCast(needed),
        pixels.ptr,
    );

    // Flush rather than wait for a reply: a put is a one-way request, and waiting
    // would block on an event the caller is not asking about. What matters is that the
    // write reached the socket.
    _ = xcb.xcb_flush(self.conn);

    // A server that refused the image — the usual cause being a depth that does not
    // match the drawable — latches an error on the connection. Reporting it here
    // means the failure is this frame's rather than the next one's.
    _ = cookie;
    if (xcb.xcb_connection_has_error(self.conn) != 0) return error.DisplayLost;
}

/// The handle the dispatch in `window.Backend` reaches a window through.
///
/// Present here because the Wayland backend has one and the union needs both to be
/// shaped alike. A backend without it would make every dispatch site carry a branch
/// to work out which kind of handle it held.
pub fn asHandle(w: *X11Window) *anyopaque {
    return @ptrCast(w);
}

fn firstScreen(setup: [*c]const xcb.xcb_setup_t) ?*xcb.xcb_screen_t {
    const roots = xcb.xcb_setup_roots_iterator(setup);
    if (roots.rem == 0) return null;
    return &roots.data[0];
}

fn x11Display() ?[*:0]const u8 {
    return platform_display.processGetenv(null, "DISPLAY");
}

// --- Adapter for the window contract's dispatch ---------------------------

pub fn resize(handle: *anyopaque, size: Size) window.Error!void {
    const w: *X11Window = @ptrCast(@alignCast(handle));
    // `return` on the catch, not on one arm: without it the switch is evaluated for its
    // arms and then thrown away, so a failed resize reported success. Nothing noticed for
    // as long as no caller reached this function — `native_check` presents frames but
    // never resizes — which is exactly the shape of bug a dead adapter hides.
    w.resize(size) catch |e| return switch (e) {
        error.ConnectionFailed, error.NoScreens => error.DisplayLost,
        else => |other| other,
    };
}

pub fn setTitle(handle: *anyopaque, text: []const u8) window.Error!void {
    const w: *X11Window = @ptrCast(@alignCast(handle));
    w.setTitle(text);
}

pub fn currentSize(handle: *anyopaque) Size {
    const w: *X11Window = @ptrCast(@alignCast(handle));
    return w.currentSize();
}

pub fn wait(handle: *anyopaque, timeout_ms: i32) window.Error!void {
    const w: *X11Window = @ptrCast(@alignCast(handle));

    // The result is returned rather than produced and dropped. A `catch` with no
    // `return` here reads like a mapping but discards the error, so a caller polling a
    // window would be told the wait succeeded on a connection that had already died.
    return w.wait(timeout_ms) catch |failure| switch (failure) {
        error.ConnectionFailed, error.NoScreens => error.DisplayLost,
        else => |other| other,
    };
}

pub fn takeConfigure(handle: *anyopaque) ?Configure {
    const w: *X11Window = @ptrCast(@alignCast(handle));
    return w.takeConfigure();
}
