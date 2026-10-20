//! The Servo bridge's C ABI (`servo/lepton_servo.h`) and the Xlib calls the view needs,
//! imported once for the engine's files.
//!
//! The header's struct layouts are checked here against the numbers written beside them,
//! as the bridge checks them on its side (`servo/bridge/src/abi.rs`).

const std = @import("std");

pub const c = @cImport({
    @cInclude("lepton_servo.h");
    @cInclude("X11/Xlib.h");
});

comptime {
    std.debug.assert(@sizeOf(c.LeptonServoSurface) == 40);
    std.debug.assert(@offsetOf(c.LeptonServoSurface, "window") == 24);
    std.debug.assert(@offsetOf(c.LeptonServoSurface, "scale") == 36);
    std.debug.assert(@sizeOf(c.LeptonServoCallbacks) == 48);
    std.debug.assert(@offsetOf(c.LeptonServoCallbacks, "loaded") == 40);
}
