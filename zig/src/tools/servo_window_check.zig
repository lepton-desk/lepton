//! Servo drawing into the core's own window, with the core's input reaching the page.
//!
//! Opens the core's X11 window (`window/linux/x11_window.zig`), hands it to Servo through
//! the bridge's C ABI (`servo/lepton_servo.h`), and serves a page on `lepton://` from
//! this process. The page reports through its title: `ready injected=true` once the
//! user script ran and a first call came back, `clicked reply=…` after a click on its
//! button reached Servo through the window's own event handling and the call it made
//! came back intact. Each title is printed as it changes, so a driver (CI: `xdotool`
//! on Xvfb) can click when it sees `ready` and capture the screen when it sees
//! `clicked`. The button sits at 40,40–360,160 in the window, so a driver clicks 200,100.
//! Exits 0 three seconds after `clicked`; 1 on a failure; 2 on a timeout.
//!
//! Built with `zig build servo-window-check -Drender=native -Dservo-lib=<dir>`.

const std = @import("std");
const core = @import("lepton_core");

const c = @cImport({
    @cInclude("lepton_servo.h");
    @cInclude("X11/Xlib.h");
    @cInclude("xcb/xcb.h");
});

/// The body the page sends with every call; the reply is it reversed.
const sent = [_]u8{ 0, 1, 2, 3, 127, 128, 250, 255, 76, 101, 112, 116, 111, 110 };

const page =
    \\<!doctype html>
    \\<meta charset="utf-8">
    \\<title>loading</title>
    \\<style>
    \\  body { font: 22px sans-serif; margin: 40px; background: #f4f1ea; color: #1d1b16 }
    \\  button { position: fixed; left: 40px; top: 40px; width: 320px; height: 120px;
    \\           font: inherit; background: #2f5d50; color: white; border: 0; border-radius: 12px }
    \\  h1 { margin-top: 180px }
    \\</style>
    \\<h1>Lepton on Servo, in Lepton's window</h1>
    \\<p><button id="go">Call the core</button></p>
    \\<p id="out">loading…</p>
    \\<script>
    \\const sent = new Uint8Array([0, 1, 2, 3, 127, 128, 250, 255, 76, 101, 112, 116, 111, 110]);
    \\async function call() {
    \\  const response = await fetch("/__lepton/invoke", { method: "POST", body: sent });
    \\  if (!response.ok) throw new Error("status " + response.status);
    \\  return Array.from(new Uint8Array(await response.arrayBuffer())).join(",");
    \\}
    \\const out = document.getElementById("out");
    \\call().then(() => {
    \\  const injected = globalThis.__leptonProbe === 42;
    \\  out.textContent = "ready · user script " + (injected ? "ran" : "did not run");
    \\  document.title = "ready injected=" + injected;
    \\}, (error) => { document.title = "error " + error; });
    \\document.getElementById("go").addEventListener("click", async () => {
    \\  try {
    \\    const reply = await call();
    \\    out.textContent = "clicked · reply " + reply;
    \\    document.title = "clicked reply=" + reply;
    \\  } catch (error) { document.title = "error " + error; }
    \\});
    \\</script>
;

const State = struct {
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    title_changed: bool = false,
    loaded: bool = false,
    calls: u32 = 0,
    bodies_intact: u32 = 0,
    woken: std.atomic.Value(bool) = .init(false),

    fn titleText(self: *const State) []const u8 {
        return self.title[0..self.title_len];
    }
};

fn onWake(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    state.woken.store(true, .release);
}

fn onTitle(context: ?*anyopaque, utf8: [*c]const u8, len: usize) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    const n = @min(len, state.title.len);
    if (n > 0) @memcpy(state.title[0..n], utf8[0..n]);
    state.title_len = n;
    state.title_changed = true;
}

fn onConsole(_: ?*anyopaque, level: u32, utf8: [*c]const u8, len: usize) callconv(.c) void {
    std.debug.print("console {d}: {s}\n", .{ level, utf8[0..len] });
}

fn onLoaded(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    std.debug.print("loaded\n", .{});
    state.loaded = true;
}

/// The bytes a `lepton_servo_request_*` call pointed at. Called with the length the call
/// returned, after it: an argument list is evaluated left to right, so passing the pointer
/// and the call together read the pointer before the call set it (every URL read empty,
/// the page was answered 404, measured).
fn bytesOf(pointer: [*c]const u8, len: usize) []const u8 {
    if (len == 0 or pointer == null) return "";
    return pointer[0..len];
}

fn onRequest(context: ?*anyopaque, request: ?*c.LeptonServoRequest) callconv(.c) void {
    const req = request orelse return;
    defer c.lepton_servo_request_unref(req);
    const state: *State = @ptrCast(@alignCast(context orelse return));

    var url_ptr: [*c]const u8 = null;
    const url_len = c.lepton_servo_request_url(req, &url_ptr);
    const url = bytesOf(url_ptr, url_len);
    var body_ptr: [*c]const u8 = null;
    const body_len = c.lepton_servo_request_body(req, &body_ptr);
    const body = bytesOf(body_ptr, body_len);

    var method_ptr: [*c]const u8 = null;
    const method_len = c.lepton_servo_request_method(req, &method_ptr);
    const method = bytesOf(method_ptr, method_len);
    std.debug.print("request         {s} {s} ({d} bytes)\n", .{ method, url, body.len });

    const origin = "lepton://localhost";
    const path = if (std.mem.startsWith(u8, url, origin)) url[origin.len..] else url;

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        respond(req, 200, "text/html; charset=utf-8", page);
    } else if (std.mem.eql(u8, path, "/__lepton/invoke")) {
        state.calls += 1;
        if (std.mem.eql(u8, body, &sent)) state.bodies_intact += 1;
        var reply: [64]u8 = undefined;
        const n = @min(body.len, reply.len);
        for (0..n) |i| reply[i] = body[body.len - 1 - i];
        respond(req, 200, "application/octet-stream", reply[0..n]);
    } else {
        respond(req, 404, "text/plain; charset=utf-8", "no such path");
    }
}

fn respond(request: *c.LeptonServoRequest, status: u16, content_type: []const u8, bytes: []const u8) void {
    c.lepton_servo_request_respond(request, status, content_type.ptr, content_type.len, "", 0, bytes.ptr, bytes.len);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn elapsedMs(started: std.Io.Clock.Timestamp) i64 {
    const ns = started.durationTo(std.Io.Clock.Timestamp.now(io(), .awake)).raw.nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

/// The window's buttons, as the bridge numbers them (0 primary, 1 middle, 2 secondary).
const buttons = [_]struct { which: core.waylandInput.Button, number: u32 }{
    .{ .which = .left, .number = 0 },
    .{ .which = .middle, .number = 1 },
    .{ .which = .right, .number = 2 },
};

/// Forwards what changed in the window's input state since the last call.
fn forward(servo: *c.LeptonServo, input: *const core.waylandInput.Input, last_x: *f64, last_y: *f64, last_mask: *u32, out: *std.Io.Writer) !void {
    if (input.x != last_x.* or input.y != last_y.*) {
        last_x.* = input.x;
        last_y.* = input.y;
        c.lepton_servo_pointer_move(servo, input.x, input.y);
    }
    if (input.held_mask != last_mask.*) {
        for (buttons) |b| {
            const bit: u32 = @intFromEnum(b.which);
            if ((input.held_mask ^ last_mask.*) & bit != 0) {
                const pressed: i32 = if (input.held_mask & bit != 0) 1 else 0;
                c.lepton_servo_pointer_button(servo, b.number, pressed, input.x, input.y);
                try out.print("button          {d} {s} at {d:.0},{d:.0}\n", .{ b.number, if (pressed == 1) "down" else "up", input.x, input.y });
                try out.flush();
            }
        }
        last_mask.* = input.held_mask;
    }
}

pub fn main() !u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io(), &stdout_buffer);
    const out = &stdout.interface;
    const started = std.Io.Clock.Timestamp.now(io(), .awake);

    const display = core.display.Display.probe(core.display.processGetenv, null) catch |e| {
        try out.print("no display server: {t}\n", .{e});
        try out.flush();
        return 1;
    };
    if (display.session != .x11) {
        try out.writeAll("this check drives the X11 window; unset WAYLAND_DISPLAY and run it on X11 or Xvfb\n");
        try out.flush();
        return 1;
    }

    const size: core.window.Size = .{ .width = 800, .height = 600 };
    var w = try core.x11Window.X11Window.open(.{
        .title = "Lepton on Servo",
        .app_id = "dev.lepton.servocheck",
        .size = size,
    });
    defer w.close();

    // A second connection, through Xlib: surfman takes no XCB connection, and the window
    // is the server's, so Servo draws into it by its id.
    const xdisplay = c.XOpenDisplay(null) orelse {
        try out.writeAll("XOpenDisplay failed\n");
        try out.flush();
        return 1;
    };
    defer _ = c.XCloseDisplay(xdisplay);

    var state: State = .{};
    const surface: c.LeptonServoSurface = .{
        .kind = c.LEPTON_SERVO_X11,
        .width = size.width,
        .display = xdisplay,
        .surface = null,
        .window = w.window_id,
        .height = size.height,
        .scale = 1.0,
    };
    comptime std.debug.assert(@sizeOf(c.LeptonServoSurface) == 40);
    comptime std.debug.assert(@offsetOf(c.LeptonServoSurface, "window") == 24);
    comptime std.debug.assert(@sizeOf(c.LeptonServoCallbacks) == 48);
    comptime std.debug.assert(@offsetOf(c.LeptonServoCallbacks, "loaded") == 40);
    const callbacks: c.LeptonServoCallbacks = .{
        .context = &state,
        .wake = onWake,
        .request = onRequest,
        .title = onTitle,
        .console = onConsole,
        .loaded = onLoaded,
    };

    var error_text: [512]u8 = @splat(0);
    const scheme = "lepton";
    const servo = c.lepton_servo_create(&surface, scheme, scheme.len, &callbacks, &error_text, error_text.len) orelse {
        try out.print("lepton_servo_create: {s}\n", .{std.mem.sliceTo(&error_text, 0)});
        try out.flush();
        return 1;
    };
    defer c.lepton_servo_destroy(servo);
    try out.print("servo started   {d} ms\n", .{elapsedMs(started)});
    try out.flush();

    const script = "globalThis.__leptonProbe = 42;";
    if (c.lepton_servo_add_user_script(servo, script, script.len) != 0) {
        try out.writeAll("add_user_script failed\n");
        try out.flush();
        return 1;
    }
    const address = "lepton://localhost/";
    if (c.lepton_servo_load(servo, address, address.len) != 0) {
        try out.writeAll("load failed\n");
        try out.flush();
        return 1;
    }

    const conn: *c.xcb_connection_t = @ptrCast(w.conn);
    const fd: std.posix.fd_t = @intCast(c.xcb_get_file_descriptor(conn));
    var last_x: f64 = -1;
    var last_y: f64 = -1;
    var last_mask: u32 = 0;
    var clicked_at: ?i64 = null;
    var screenshot_asked = false;
    var last_beat: i64 = 0;

    while (true) {
        const now = elapsedMs(started);
        if (clicked_at) |at| {
            if (now - at > 3_000) break;
        } else if (now > 120_000) {
            try out.print("timeout          title \"{s}\"\n", .{state.titleText()});
            try out.flush();
            return 2;
        }

        if (now - last_beat >= 10_000) {
            last_beat = now;
            const woken = state.woken.load(.acquire);
            std.debug.print("alive           {d} ms, calls {d}, loaded {}, woken {}\n", .{ now, state.calls, state.loaded, woken });
        }

        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const wait_ms: i32 = if (state.woken.swap(false, .acq_rel)) 0 else 4;
        _ = std.posix.poll(&fds, wait_ms) catch {};
        // One event at a time, the input state compared after each: a click's press and
        // release arrive together, and compared only after the whole queue they cancel out.
        while (core.x11Window.pumpOne(&w)) {
            forward(servo, &w.input, &last_x, &last_y, &last_mask, out) catch {};
        }

        c.lepton_servo_spin(servo);

        if (state.title_changed) {
            state.title_changed = false;
            const title = state.titleText();
            try out.print("title           {s}  ({d} ms)\n", .{ title, elapsedMs(started) });
            try out.flush();
            if (std.mem.startsWith(u8, title, "error ")) return 1;
            if (std.mem.startsWith(u8, title, "clicked ") and clicked_at == null) {
                clicked_at = elapsedMs(started);
                if (!screenshot_asked) {
                    const path = "servo-window.png";
                    _ = c.lepton_servo_screenshot(servo, path, path.len);
                    screenshot_asked = true;
                }
            }
        }
    }

    try out.print("calls           {d}, bodies intact {d}\n", .{ state.calls, state.bodies_intact });
    try out.print("loaded          {}\n", .{state.loaded});
    try out.flush();
    const expected = "clicked reply=110,111,116,112,101,76,255,250,128,127,3,2,1,0";
    const passed = state.calls >= 2 and state.bodies_intact == state.calls and
        std.mem.eql(u8, state.titleText(), expected);
    try out.print("result          {s}\n", .{if (passed) "passed" else "failed"});
    try out.flush();
    return if (passed) 0 else 1;
}
