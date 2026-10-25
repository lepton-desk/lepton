//! A Servo view in the core's own X11 window: the third engine beside `wpe_view.zig` and
//! `webview2/view.zig`, chosen with `-Dservo-lib` (experimental).
//!
//! The same surface the template's `main.zig` drives — `open`, `resized`, `map`,
//! `setTitle`, `startBridge`, `watchClose`, `injectTransport`, `load`, `close`, the
//! `bridge` and the `closed` flag — so one entry point runs on all three.
//!
//! Servo is a Rust library behind `servo/lepton_servo.h` (`liblepton_servo.so`, built in
//! CI). It draws into the core's X11 window through a second, Xlib connection: surfman
//! takes no XCB connection, and an X11 window is the server's, so Servo draws into it by
//! its id (measured: `servo-window-check`, run 39447351318). On a Wayland session the
//! window opens through XWayland; Servo in the core's Wayland window needs a subsurface
//! under the core's titlebar and is not done.
//!
//! Requests on `lepton://` reach `bridge.zig` through `servo/request.zig`, answered as on
//! WebKit. The loop is the core's own: `pumpBlocking` waits on the X connection, an
//! eventfd Servo's `wake` writes from any thread, and the next timer.
//!
//! Keys reach Servo by their DOM names (`keymap.zig`), the wheel as pixel deltas.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const x11 = @import("../../../window/linux/x11_window.zig");
const placement = @import("../../../window/linux/placement.zig");
/// How close to an edge, in pixels, a press of a frameless window resizes it.
const resize_band: f64 = 6;
const input_state = @import("../../../window/linux/input.zig");
const bridge_mod = @import("../bridge.zig");
const transport = @import("../transport.zig");
const request = @import("request.zig");
const keymap = @import("keymap.zig");
const menu_x11 = @import("menu_x11.zig");
const cursor_x11 = @import("cursor_x11.zig");
const invoke = @import("../invoke.zig");
const events = @import("../events.zig");

/// `int xkb_keysym_to_utf8(xkb_keysym_t, char *, size_t)`: the bytes written with the
/// terminating NUL, 0 for a keysym with no character (xkbcommon.h).
const e_keysym_to_utf8 = @extern(*const fn (u32, [*]u8, usize) callconv(.c) c_int, .{ .name = "xkb_keysym_to_utf8" });

pub const Error = error{ NoWindow, NoXlib, Engine, Wake };

const linux = std.os.linux;

/// What Servo's callbacks reach: the view, once it lives where it will stay
/// (`map`/`startBridge`), and the eventfd `wake` writes. Module-level because Servo starts
/// once per process and its callbacks are given at start, before `open` returns by value.
const Host = struct {
    view: ?*View = null,
    wake_fd: i32 = -1,
};
var host: Host = .{};

/// How often `pumpBlocking` returns even when nothing happens (`wakeEvery`); 0 = never.
var wake_interval_ms: u32 = 0;

pub fn is_available() bool {
    return true;
}

pub fn loadedBackend() ?[]const u8 {
    return "Servo 0.6 (experimental)";
}

/// The application's identifier, kept by `useApplicationDirectories` for `open`: the window's
/// `WM_CLASS`, which the desktop entry's `StartupWMClass` matches. Without it every Servo
/// window was `dev.lepton.app`, so its icon and dock grouping missed (`docs/durum.md`).
var application_id: [256]u8 = undefined;
var application_id_len: usize = 0;

/// Servo's web data (cookies, `localStorage`, IndexedDB, caches) for this application only:
/// `$APPDATA/servo`, made 0700, given to the bridge before Servo starts. Every Lepton page
/// has the origin `lepton://localhost`, so a shared directory would hand one application's
/// storage to the next, as it did on WPE before (`wpe_view.zig`). Call before `open`.
pub fn useApplicationDirectories(identifier: []const u8) bool {
    application_id_len = @min(identifier.len, application_id.len);
    @memcpy(application_id[0..application_id_len], identifier[0..application_id_len]);
    const paths = @import("../../../platform/linux/paths.zig");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var scratch: [4096]u8 = undefined;
    const data = paths.resolve(.app_data, identifier, buffer[0 .. buffer.len - 8], &scratch) catch return false;
    const suffix = "/servo";
    @memcpy(buffer[data.len..][0..suffix.len], suffix);
    buffer[data.len + suffix.len] = 0;
    const directory = buffer[0 .. data.len + suffix.len :0];
    if (!paths.makePrivate(directory)) return false;
    // The application's own directory and Servo's inside it.
    buffer[data.len] = 0;
    if (!paths.makeOwnPrivate(buffer[0..data.len :0])) return false;
    buffer[data.len] = '/';
    if (!paths.makeOwnPrivate(directory)) return false;
    return c.lepton_servo_set_data_directory(directory.ptr, directory.len) == 0;
}

/// A directory named by the caller (no `HOME`: beside the executable).
pub fn setDataDirectory(path: [*:0]const u8) void {
    const directory = std.mem.span(path);
    _ = c.lepton_servo_set_data_directory(directory.ptr, directory.len);
}

// --- timers: one-shot, the counterpart of `g_timeout_add` returning 0 ------------------------

const Timer = struct {
    due_ns: i96 = 0,
    callback: ?*const fn (?*anyopaque) callconv(.c) c_int = null,
    data: ?*anyopaque = null,
};
var timers: [16]Timer = @splat(.{});

fn nowNs() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// Calls `callback(data)` once after `ms`, from the view's loop.
pub fn timeoutOnce(ms: c_uint, callback: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) void {
    for (&timers) |*timer| {
        if (timer.callback != null) continue;
        timer.* = .{ .due_ns = nowNs() + @as(i96, ms) * std.time.ns_per_ms, .callback = callback, .data = data };
        wake();
        return;
    }
}

fn fireTimers() void {
    const now = nowNs();
    for (&timers) |*timer| {
        const callback = timer.callback orelse continue;
        if (timer.due_ns > now) continue;
        const data = timer.data;
        timer.* = .{};
        _ = callback(data);
    }
}

/// Milliseconds until the next timer, or -1 for none.
fn untilNextTimer() i32 {
    const now = nowNs();
    var soonest: ?i96 = null;
    for (timers) |timer| {
        if (timer.callback == null) continue;
        soonest = if (soonest) |s| @min(s, timer.due_ns) else timer.due_ns;
    }
    const due = soonest orelse return -1;
    if (due <= now) return 0;
    return @intCast(@min(@divTrunc(due - now, std.time.ns_per_ms) + 1, std.math.maxInt(i32)));
}

// --- the loop -------------------------------------------------------------------------------

fn wake() void {
    if (host.wake_fd < 0) return;
    const one: u64 = 1;
    _ = linux.write(host.wake_fd, std.mem.asBytes(&one), 8);
}

fn drainWake() void {
    if (host.wake_fd < 0) return;
    var count: u64 = 0;
    _ = linux.read(host.wake_fd, std.mem.asBytes(&count), 8);
}

/// One turn: wait up to `timeout_ms` for the X connection, a wake or a timer, then apply
/// the window's events, run Servo and fire what is due. False when there is no view.
fn turn(timeout_ms: i32) bool {
    const view = host.view orelse return false;
    var fds = [_]std.posix.pollfd{
        .{ .fd = view.connectionFd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = host.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = std.posix.poll(&fds, timeout_ms) catch {};
    drainWake();
    view.applyEvents();
    c.lepton_servo_spin(view.servo);
    fireTimers();
    return true;
}

/// Runs whatever is waiting; never sleeps.
pub fn pump() bool {
    return turn(0);
}

/// Sleeps until the window, Servo or a timer has something, or `wakeEvery` elapses.
pub fn pumpBlocking() bool {
    var timeout = untilNextTimer();
    if (wake_interval_ms != 0) {
        const interval: i32 = @intCast(@min(wake_interval_ms, std.math.maxInt(i32)));
        timeout = if (timeout < 0) interval else @min(timeout, interval);
    }
    return turn(timeout);
}

pub fn wakeEvery(interval_ms: u32) u32 {
    wake_interval_ms = interval_ms;
    return 1;
}

// --- Servo's callbacks ----------------------------------------------------------------------

fn onWake(_: ?*anyopaque) callconv(.c) void {
    wake();
}

/// `LEPTON_SERVO_TRACE=1` prints every request Servo hands the core: what CI reads to tell
/// a page that reached the core from one that only drew.
fn tracing() bool {
    const value = std.c.getenv("LEPTON_SERVO_TRACE") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

fn onRequest(_: ?*anyopaque, held: ?*c.LeptonServoRequest) callconv(.c) void {
    const req: request.Request = @ptrCast(held);
    // The request is ours to drop; the bridge takes its own reference for a later answer.
    defer request.unref(req);
    if (tracing()) std.debug.print("servo request {s} {s}\n", .{ request.method(req), request.uri(req) });
    const view = host.view orelse return;
    view.bridge.deliver(req);
}

fn onTitle(_: ?*anyopaque, utf8: [*c]const u8, len: usize) callconv(.c) void {
    const view = host.view orelse return;
    const page = if (len == 0 or utf8 == null) "" else utf8[0..len];
    view.window.setTitle(if (page.len == 0) view.title[0..view.title_len] else page);
}

fn onConsole(_: ?*anyopaque, level: u32, utf8: [*c]const u8, len: usize) callconv(.c) void {
    // Debug builds print the page's console, as on WebKit.
    if (builtin.mode != std.builtin.OptimizeMode.Debug or utf8 == null) return;
    const names = [_][]const u8{ "log", "debug", "info", "warn", "error", "trace" };
    std.debug.print("console {s}: {s}\n", .{ if (level < names.len) names[level] else "log", utf8[0..len] });
}

fn onLoaded(_: ?*anyopaque) callconv(.c) void {}

fn onCursor(_: ?*anyopaque, name: [*c]const u8, len: usize) callconv(.c) void {
    const view = host.view orelse return;
    if (name == null or len == 0) return;
    view.cursors.setPage(view.xdisplay, view.window.window_id, name[0..len], view.over_edge);
}

/// The view's document may only be the application's own page (`features.isOwnPage`).
/// Another address is refused, and not opened elsewhere yet: handing it to the desktop
/// goes through the OpenURI portal, which a Servo build does not link.
fn onNavigation(_: ?*anyopaque, utf8: [*c]const u8, len: usize) callconv(.c) i32 {
    if (utf8 == null) return 0;
    const url = utf8[0..len];
    if (@import("../features.zig").isOwnPage(url)) return 1;
    std.debug.print("link         not opened (Servo): {s}\n", .{url});
    return 0;
}

// --- the view -------------------------------------------------------------------------------

/// Window buttons as the bridge numbers them (0 primary, 1 middle, 2 secondary).
const buttons = [_]struct { which: input_state.Button, number: u32 }{
    .{ .which = .left, .number = 0 },
    .{ .which = .middle, .number = 1 },
    .{ .which = .right, .number = 2 },
};

pub const View = struct {
    window: x11.X11Window,
    /// The page's menu (`window.menu`) while it is open, and the request it answers.
    menu: menu_x11.Menu = .{},
    menu_answer: ?invoke.Later = null,
    xdisplay: *c.Display,
    servo: *c.LeptonServo,

    bridge: bridge_mod.Bridge = .{},
    /// Set when the window manager asked the window to close.
    closed: bool = false,

    /// The application's title, shown while the page has none of its own.
    title: [256]u8 = @splat(0),
    title_len: usize = 0,

    last_x: f64 = -1,
    last_y: f64 = -1,
    last_mask: u32 = 0,
    /// `window.decorations: false`: no frame, so the edges resize (`forward`).
    frameless: bool = false,
    /// The pointer's shape (`cursor_x11.zig`), and whether it is over a resizing edge.
    cursors: cursor_x11.Cursors = .{},
    over_edge: bool = false,

    /// Opens the core's X11 window and starts Servo drawing into it.
    pub fn open() Error!View {
        var window = x11.X11Window.open(.{ .title = "Lepton", .size = .{ .width = 800, .height = 600 }, .mapped = false }) catch
            return error.NoWindow;
        errdefer window.close();
        if (application_id_len > 0) window.setAppId(application_id[0..application_id_len]);
        // Servo fills the window; the native path's title bar and right-press menu would
        // take the page's own right button.
        window.own_chrome = false;

        const xdisplay = c.XOpenDisplay(null) orelse return error.NoXlib;
        errdefer _ = c.XCloseDisplay(xdisplay);

        // Made once and never closed: Servo's threads may still call `wake` while or after
        // the view closes, and a closed number can be reused by the next file opened, which
        // `wake` would then write eight bytes into.
        if (host.wake_fd < 0) {
            const created = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(created) != .SUCCESS) return error.Wake;
            host.wake_fd = @intCast(created);
        }

        const size = window.currentSize();
        const surface: c.LeptonServoSurface = .{
            .kind = c.LEPTON_SERVO_X11,
            .width = size.width,
            .display = xdisplay,
            .surface = null,
            .window = window.window_id,
            .height = size.height,
            .scale = 1.0,
        };
        const callbacks: c.LeptonServoCallbacks = .{
            .context = null,
            .wake = onWake,
            .request = onRequest,
            .title = onTitle,
            .console = onConsole,
            .loaded = onLoaded,
            .navigation = onNavigation,
            .cursor = onCursor,
        };
        var reason: [512]u8 = @splat(0);
        const scheme = "lepton";
        const servo = c.lepton_servo_create(&surface, scheme, scheme.len, &callbacks, &reason, reason.len) orelse {
            std.debug.print("servo: {s}\n", .{std.mem.sliceTo(&reason, 0)});
            return error.Engine;
        };
        return .{ .window = window, .xdisplay = xdisplay, .servo = servo };
    }

    /// The view's callbacks reach this address from now on.
    fn own(self: *View) void {
        host.view = self;
    }

    fn connectionFd(self: *View) i32 {
        return x11.connectionFd(&self.window);
    }

    /// The window's events, one at a time: a click's press and release arrive together,
    /// and compared only after the whole queue they cancel out (measured).
    fn applyEvents(self: *View) void {
        while (x11.pumpOne(&self.window)) self.forward();
        if (self.window.takeConfigure()) |configure| {
            if (configure.size.width == 0 or configure.size.height == 0) {
                self.closed = true;
            } else {
                c.lepton_servo_resize(self.servo, configure.size.width, configure.size.height);
                var size_bytes: [8]u8 = undefined;
                std.mem.writeInt(u32, size_bytes[0..4], configure.size.width, .little);
                std.mem.writeInt(u32, size_bytes[4..8], configure.size.height, .little);
                _ = self.bridge.emit(events.window_resized, &size_bytes) catch {};
            }
        }
        if (self.window.takeStateChange()) {
            if (self.window.state()) |bits| {
                var state_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &state_bytes, bits, .little);
                _ = self.bridge.emit(events.window_state, &state_bytes) catch {};
            }
        }
    }

    /// Over the band a frameless window resizes from, the edge's resize shape; off it,
    /// the page's again.
    fn showEdge(self: *View) void {
        const size = self.window.currentSize();
        const edge = placement.edgeAt(self.last_x, self.last_y, size.width, size.height, resize_band);
        if (edge) |direction| {
            self.cursors.show(self.xdisplay, self.window.window_id, cursor_x11.edge_names[direction]);
        } else if (self.over_edge) {
            self.cursors.restorePage(self.xdisplay, self.window.window_id);
        }
        self.over_edge = edge != null;
    }

    fn forward(self: *View) void {
        const input = &self.window.input;
        if (input.x != self.last_x or input.y != self.last_y) {
            self.last_x = input.x;
            self.last_y = input.y;
            c.lepton_servo_pointer_move(self.servo, input.x, input.y);
            if (self.frameless) self.showEdge();
        }
        var raw: [32]x11.X11Window.RawKey = undefined;
        for (self.window.takeKeys(&raw)) |key| self.forwardKey(key);
        // The window counts a step down as positive, Wayland's way; Servo takes the DOM's
        // sign, where a step down is a negative delta (`lepton_servo.h`).
        const scrolled = input.takeScroll();
        if (scrolled.x != 0 or scrolled.y != 0) {
            c.lepton_servo_wheel(self.servo, -scrolled.x, -scrolled.y, input.x, input.y);
        }
        // Frameless, the window manager draws no border to resize by: a primary press near
        // an edge resizes from it instead of reaching the page (`placement.edgeAt`).
        const primary: u32 = 1 << 0;
        if (self.frameless and input.held_mask & primary != 0 and self.last_mask & primary == 0) {
            const size = self.window.currentSize();
            if (placement.edgeAt(input.x, input.y, size.width, size.height, resize_band)) |direction| {
                if (self.window.startResize(direction)) {
                    self.last_mask = input.held_mask;
                    return;
                }
            }
        }
        if (input.held_mask == self.last_mask) return;
        for (buttons) |b| {
            const bit: u32 = @intFromEnum(b.which);
            if ((input.held_mask ^ self.last_mask) & bit == 0) continue;
            const pressed: i32 = if (input.held_mask & bit != 0) 1 else 0;
            if (pressed == 1) @import("../activation.zig").press();
            c.lepton_servo_pointer_button(self.servo, b.number, pressed, input.x, input.y);
        }
        self.last_mask = input.held_mask;
    }

    /// One key to Servo by its DOM names (`keymap.zig`). The keysym is Xlib's reading of
    /// the event through this view's own connection, so Shift, Caps Lock and the layout's
    /// group apply; the character is xkbcommon's.
    fn forwardKey(self: *View, key: x11.X11Window.RawKey) void {
        var event = std.mem.zeroes(c.XKeyEvent);
        event.type = if (key.pressed) c.KeyPress else c.KeyRelease;
        event.display = self.xdisplay;
        event.keycode = key.keycode;
        event.state = key.state;
        var keysym: c.KeySym = 0;
        var latin: [8]u8 = undefined;
        _ = c.XLookupString(&event, &latin, latin.len, &keysym, null);
        const sym: u32 = @truncate(@as(u64, @intCast(keysym)));
        var text: [8]u8 = undefined;
        const name: []const u8 = keymap.named(sym) orelse blk: {
            const written = e_keysym_to_utf8(sym, &text, text.len);
            // Counts the terminating NUL; 0 or a control character is no character.
            if (written <= 1 or text[0] < 0x20) break :blk "Unidentified";
            break :blk text[0..@intCast(written - 1)];
        };
        const code = keymap.code(@as(u32, key.keycode) -| 8);
        if (key.pressed) @import("../activation.zig").press();
        _ = c.lepton_servo_key(self.servo, @intFromBool(key.pressed), name.ptr, name.len, code.ptr, code.len, keymap.modifiers(key.state), 0);
    }

    pub fn resized(self: *View, width: i32, height: i32) void {
        const asked: x11.Size = .{ .width = @intCast(@max(width, 1)), .height = @intCast(@max(height, 1)) };
        // Fitted to the work area and centred, as the other engines' windows open.
        const size = self.window.resizeCentred(asked) catch asked;
        c.lepton_servo_resize(self.servo, size.width, size.height);
    }

    /// `window.decorations: false`: the window manager draws no frame (`_MOTIF_WM_HINTS`)
    /// and the page's own title bar moves the window (`window.start_drag`).
    pub fn setDecorations(self: *View, decorated: bool) void {
        self.frameless = !decorated;
        _ = self.window.setDecorated(decorated);
    }

    pub fn map(self: *View) void {
        // Shown only now, sized and centred (`resized`): see `Request.mapped`.
        self.window.map();
        self.own();
    }

    /// Titles the window `title`, then follows the page's `document.title`, falling back
    /// to `title` whenever the page has none.
    pub fn setTitle(self: *View, title: []const u8) void {
        const kept = title[0..@min(title.len, self.title.len - 1)];
        @memcpy(self.title[0..kept.len], kept);
        self.title_len = kept.len;
        self.window.setTitle(kept);
    }

    pub fn startBridge(self: *View) void {
        self.own();
        self.bridge.recorder = @import("../record.zig").Recorder.fromEnvironment();
        self.bridge.page_replay = @import("../page_replay.zig").fromEnvironment();
        if (self.bridge.page_replay) |*script| script.closeWhenDone(&self.bridge.close_requested);
        // The page's `window.*` commands act on the core's X11 window (EWMH), and its
        // state and size reach the page as `window.state` and `window.resized` events
        // (`applyEvents`). Engine permission prompts are WebKit's; Servo asks none.
        self.bridge.window = .{ .context = self, .act = &windowAct, .state = &windowState, .start_drag = &windowDrag, .menu = &windowMenu };
    }

    fn windowAct(data: ?*anyopaque, action: invoke.WindowAction) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        return switch (action) {
            .minimize => self.window.minimize(),
            .maximize => self.window.setMaximized(true),
            .unmaximize => self.window.setMaximized(false),
        };
    }

    fn windowMenu(data: ?*anyopaque, bytes: []const u8, later: invoke.Later) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        if (self.menu.isOpen()) return false;
        self.menu_answer = later;
        self.menu.open(&self.window, bytes, self, &menuDone) catch {
            self.menu_answer = null;
            return false;
        };
        return true;
    }

    /// The chosen id as `window.menu` answers it: u16, 0 when dismissed.
    fn menuDone(context: *anyopaque, id: u16) void {
        const self: *View = @ptrCast(@alignCast(context));
        const later = self.menu_answer orelse return;
        self.menu_answer = null;
        var result: [2]u8 = undefined;
        std.mem.writeInt(u16, &result, id, .little);
        later.finish(.ok, &result);
    }

    fn windowDrag(data: ?*anyopaque) bool {
        const self: *View = @ptrCast(@alignCast(data orelse return false));
        return self.window.startMove();
    }

    fn windowState(data: ?*anyopaque) ?u32 {
        const self: *View = @ptrCast(@alignCast(data orelse return null));
        return self.window.state();
    }

    /// The window manager's close request ends the run (`applyEvents`).
    pub fn watchClose(self: *View) void {
        self.own();
    }

    /// `globalThis.__lepton` before every document's own scripts, sized for the ring.
    pub fn injectTransport(self: *View, region_len: usize) bool {
        var source: [16384]u8 = undefined;
        const text = transport.script(&source, region_len, &self.bridge.registry, self.bridge.pageOrigin(), self.bridge.application) catch return false;
        return c.lepton_servo_add_user_script(self.servo, text.ptr, text.len) == 0;
    }

    pub fn load(self: *View, location: [:0]const u8) void {
        _ = c.lepton_servo_load(self.servo, location.ptr, location.len);
    }

    pub fn close(self: *View) void {
        if (self.bridge.recorder) |*recorder| recorder.close();
        // Servo writes its cookie jar only at the end of the shutdown skipped below
        // (measured: a cookie the dev server's page wrote was gone at the next start, and
        // no `cookie_jar.json` was ever written); this writes it now.
        self.menu.finish(0);
        c.lepton_servo_write_state(self.servo);
        if (host.view == self) host.view = null;
        // Servo, its Xlib display and the window it draws into are left to the process's
        // end, which the view closing always is. Servo's own shutdown (`Drop for
        // ServoInner`, 0.6) spins until every worker has stopped, with no limit: under
        // `lepton dev` the Vite client's worker never did, the process hung there, and the
        // channel's `defer` never ran (measured: alive a minute after Ctrl+C, two files left
        // in /dev/shm). Closing the display or the window under Servo's threads would race
        // them; the kernel closes both, and the threads, when the process exits.
        // `host.wake_fd` stays open (`open`).
        self.* = undefined;
    }
};
