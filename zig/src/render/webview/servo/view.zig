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
//! Not yet: keyboard input (the core's X11 window records keycodes; Servo takes DOM `key`
//! and `code` names, which need the keymap), the wheel, window commands from the page
//! (`window.minimize`…), a per-application data directory, and the plugins' engine calls
//! (the clipboard answers `failed`, as in a native build).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const x11 = @import("../../../window/linux/x11_window.zig");
const input_state = @import("../../../window/linux/input.zig");
const bridge_mod = @import("../bridge.zig");
const transport = @import("../transport.zig");
const request = @import("request.zig");

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

/// Servo keeps no profile here yet: storage lives for the run. Accepted and unused, so a
/// template that asks for a data directory still builds.
pub fn setDataDirectory(path: [*:0]const u8) void {
    _ = path;
}

pub fn useApplicationDirectories(identifier: []const u8) bool {
    _ = identifier;
    return false;
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
    if (builtin.mode != .Debug or utf8 == null) return;
    const names = [_][]const u8{ "log", "debug", "info", "warn", "error", "trace" };
    std.debug.print("console {s}: {s}\n", .{ if (level < names.len) names[level] else "log", utf8[0..len] });
}

fn onLoaded(_: ?*anyopaque) callconv(.c) void {}

// --- the view -------------------------------------------------------------------------------

/// Window buttons as the bridge numbers them (0 primary, 1 middle, 2 secondary).
const buttons = [_]struct { which: input_state.Button, number: u32 }{
    .{ .which = .left, .number = 0 },
    .{ .which = .middle, .number = 1 },
    .{ .which = .right, .number = 2 },
};

pub const View = struct {
    window: x11.X11Window,
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

    /// Opens the core's X11 window and starts Servo drawing into it.
    pub fn open() Error!View {
        var window = x11.X11Window.open(.{ .title = "Lepton", .size = .{ .width = 800, .height = 600 } }) catch
            return error.NoWindow;
        errdefer window.close();

        const xdisplay = c.XOpenDisplay(null) orelse return error.NoXlib;
        errdefer _ = c.XCloseDisplay(xdisplay);

        const created = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(created) != .SUCCESS) return error.Wake;
        host.wake_fd = @intCast(created);
        errdefer {
            _ = linux.close(host.wake_fd);
            host.wake_fd = -1;
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
            }
        }
    }

    fn forward(self: *View) void {
        const input = &self.window.input;
        if (input.x != self.last_x or input.y != self.last_y) {
            self.last_x = input.x;
            self.last_y = input.y;
            c.lepton_servo_pointer_move(self.servo, input.x, input.y);
        }
        if (input.held_mask == self.last_mask) return;
        for (buttons) |b| {
            const bit: u32 = @intFromEnum(b.which);
            if ((input.held_mask ^ self.last_mask) & bit == 0) continue;
            const pressed: i32 = if (input.held_mask & bit != 0) 1 else 0;
            c.lepton_servo_pointer_button(self.servo, b.number, pressed, input.x, input.y);
        }
        self.last_mask = input.held_mask;
    }

    pub fn resized(self: *View, width: i32, height: i32) void {
        const size: x11.Size = .{ .width = @intCast(@max(width, 1)), .height = @intCast(@max(height, 1)) };
        self.window.resize(size) catch {};
        c.lepton_servo_resize(self.servo, size.width, size.height);
    }

    pub fn map(self: *View) void {
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
    }

    /// The window manager's close request ends the run (`applyEvents`).
    pub fn watchClose(self: *View) void {
        self.own();
    }

    /// `globalThis.__lepton` before every document's own scripts, sized for the ring.
    pub fn injectTransport(self: *View, region_len: usize) bool {
        var source: [16384]u8 = undefined;
        const text = transport.script(&source, region_len, &self.bridge.registry) catch return false;
        return c.lepton_servo_add_user_script(self.servo, text.ptr, text.len) == 0;
    }

    pub fn load(self: *View, location: [:0]const u8) void {
        _ = c.lepton_servo_load(self.servo, location.ptr, location.len);
    }

    pub fn close(self: *View) void {
        if (self.bridge.recorder) |*recorder| recorder.close();
        if (host.view == self) host.view = null;
        c.lepton_servo_destroy(self.servo);
        _ = c.XCloseDisplay(self.xdisplay);
        self.window.close();
        if (host.wake_fd >= 0) {
            _ = linux.close(host.wake_fd);
            host.wake_fd = -1;
        }
        self.* = undefined;
    }
};
