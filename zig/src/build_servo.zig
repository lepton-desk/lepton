//! The Servo engine's build steps, kept out of `build.zig` (which is at its size limit).
//!
//! Servo is a Rust library behind the C ABI in `servo/lepton_servo.h`, built as
//! `liblepton_servo.so` (`servo/bridge` at the repository root) — in CI, never on the
//! project's machine. `-Dservo-lib=<dir>` names the directory that holds it; without
//! it none of this is defined.

const std = @import("std");
const support = @import("build_support.zig");

/// `zig build servo-window-check -Drender=native -Dservo-lib=<dir>`: installs
/// `lepton-servo-window-check`, which opens the core's own X11 window and has Servo
/// draw a `lepton://` page into it (`src/tools/servo_window_check.zig`).
pub fn windowCheck(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core: *std.Build.Module,
    protocol_step: ?*std.Build.Step,
    lib_dir: []const u8,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/tools/servo_window_check.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lepton_core", .module = core },
        },
    });
    module.addIncludePath(b.path("servo"));
    module.addLibraryPath(.{ .cwd_relative = lib_dir });
    module.addRPath(.{ .cwd_relative = lib_dir });
    module.linkSystemLibrary("lepton_servo", .{ .use_pkg_config = .no });
    // surfman takes an Xlib display, not the core's XCB connection (lepton_servo.h).
    module.linkSystemLibrary("X11", .{});

    const exe = support.throughLld(b.addExecutable(.{
        .name = "lepton-servo-window-check",
        .root_module = module,
    }));
    if (protocol_step) |generated| exe.step.dependOn(generated);

    const step = b.step(
        "servo-window-check",
        "Install the check that draws a lepton:// page with Servo into the core's own window (-Dservo-lib)",
    );
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
}
