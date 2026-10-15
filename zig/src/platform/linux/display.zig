//! The display probe for Linux, read through XCB and the Wayland client library.
//!
//! Lepton needs three things from the display server before it opens a window:
//! which session it is in, the screen's dimensions, and the mode the compositor
//! reports. It gets them by asking the server directly. There is no GTK, no Qt
//! and no windowing wrapper between Lepton and the protocol, because a wrapper
//! would put back the dependency this framework exists to remove.
//!
//! Both sessions are probed and the machine decides: a Wayland session under
//! XWayland exports both variables, and Wayland wins when it is present.
//!
//! The probe runs once, before the event loop exists. That is why it reads the
//! environment through an injected getter rather than reaching for a global —
//! the caller owns where the environment comes from, which is what lets this
//! module be tested without mutating process state.

const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const wayland = @import("wayland_probe.zig");
const xcb = @import("xcb_probe.zig");

pub const Error = error{
    /// Neither X11 nor Wayland is reachable. The caller reports this to the
    /// developer instead of opening a window at a geometry it invented.
    NoDisplayServer,
    HandshakeFailed,
    UnexpectedResponse,
};

/// Which window system the core will drive.
pub const Session = enum {
    wayland,
    x11,

    pub fn label(self: Session) []const u8 {
        return switch (self) {
            .wayland => "wayland",
            .x11 => "x11",
        };
    }
};

/// What the display server reports about the screen we will open on.
pub const Display = struct {
    session: Session,
    width: u32,
    height: u32,
    /// Refresh rate in millihertz, so 60Hz is 60000. Zero when the server does
    /// not report it, which is legal and is never invented.
    refresh_mhz: u32,

    pub fn probe(getenv_w: GetenvFn, userdata: ?*anyopaque) Error!Display {
        const env: Env = .{ .getenv = getenv_w, .userdata = userdata };

        if (env.waylandSocket() != null and config.have_wayland) {
            if (wayland.probe(env.waylandSocket().?)) |d| {
                return .{ .session = .wayland, .width = d.width, .height = d.height, .refresh_mhz = d.refresh_mhz };
            } else |_| {}
        }

        if (env.x11Display() != null and config.have_xcb) {
            if (xcb.probe(env.x11Display().?)) |d| {
                return .{ .session = .x11, .width = d.width, .height = d.height, .refresh_mhz = d.refresh_mhz };
            } else |_| {}
        }

        return error.NoDisplayServer;
    }
};

/// Reads one environment variable. Returning null means unset.
pub const GetenvFn = *const fn (userdata: ?*anyopaque, name: [*:0]const u8) ?[*:0]const u8;

/// Reads one environment variable from the real process environment.
///
/// Walks `environ` directly rather than through an environment map: the probe
/// runs once at startup, needs no allocation, and reading the C `environ` array
/// is the same thing every other program on this machine does.
pub fn processGetenv(userdata: ?*anyopaque, name: [*:0]const u8) ?[*:0]const u8 {
    _ = userdata;
    var entry: [*:null]const ?[*:0]u8 = @ptrCast(std.c.environ);
    while (entry[0]) |kv| : (entry += 1) {
        const pair = std.mem.span(kv);
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..split], std.mem.span(name))) continue;
        // An empty value is still a set variable, and the caller distinguishes
        // "set to nothing" from "not set" by getting a non-null empty string.
        return @ptrCast(pair[split + 1 .. :0]);
    }
    return null;
}

const Env = struct {
    getenv: GetenvFn,
    userdata: ?*anyopaque,

    pub fn waylandSocket(self: Env) ?[*:0]const u8 {
        return self.getenv(self.userdata, "WAYLAND_DISPLAY");
    }

    pub fn x11Display(self: Env) ?[*:0]const u8 {
        return self.getenv(self.userdata, "DISPLAY");
    }
};

comptime {
    // The display probes are only meaningful on Linux. Building the module for
    // another target must not fail over a display library that target lacks.
    if (builtin.os.tag != .linux) {
        @compileError("display.zig is the Linux platform layer");
    }
}

test {
    _ = wayland;
    _ = xcb;
    _ = processGetenv;
}
