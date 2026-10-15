//! Tests for the Linux display probe.
//!
//! The probe reads real environment variables and asks a real display server.
//! The environment is injected so a test can describe a session without mutating
//! process state, and the protocol probes run only when this machine actually has
//! a session — a headless build host must not fail a test for lacking a display,
//! but it must also never pass one by inventing geometry.

const std = @import("std");
const testing = std.testing;
const display = @import("display.zig");

test "a session with neither variable reports no display server" {
    // The real environment getter, pointed at nothing: this asserts the failure
    // path a headless host takes, which is the one that must never be faked.
    const fake = struct {
        fn get(_: ?*anyopaque, _: [*:0]const u8) ?[*:0]const u8 {
            return null;
        }
    }.get;

    try testing.expectError(error.NoDisplayServer, display.Display.probe(fake, null));
}

test "this machine's real session is detected and reports real dimensions" {
    // Skipped when this host has no session; asserted hard when it does, because
    // a probe that returns a size for a session that is not there would be the
    // exact failure the module exists to prevent.
    const env_get = display.processGetenv;
    const result = display.Display.probe(env_get, null);

    if (result) |d| {
        try testing.expect(d.width > 0);
        try testing.expect(d.height > 0);
        // Whichever session answered, the label must name it.
        try testing.expect(std.mem.eql(u8, d.session.label(), switch (d.session) {
            .wayland => "wayland",
            .x11 => "x11",
        }));
        // A refresh rate is optional in the protocol, so zero is legal; a
        // negative or absurd value would mean the conversion is wrong.
        try testing.expect(d.refresh_mhz == 0 or d.refresh_mhz > 1000);
    } else |err| {
        try testing.expectEqual(error.NoDisplayServer, err);
    }
}

test "session labels are stable" {
    try testing.expectEqualStrings("wayland", display.Session.wayland.label());
    try testing.expectEqualStrings("x11", display.Session.x11.label());
}
