//! `zig build setup-exe`: setup.exe's program (`src/setup/`), always for x86-64 Windows and
//! from any host. `lepton package` appends an application to it; it is built here once and
//! shipped as `@lepton-desk/setup-windows-x64` (`packages/setup-windows-x64`).

const std = @import("std");
const support = @import("build_support.zig");

pub fn add(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const optimize = std.builtin.OptimizeMode.ReleaseSmall;
    const module = b.createModule(.{
        .root_source_file = b.path("src/setup/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
        .single_threaded = false,
    });
    support.addCModules(b, module, .{ .root = ".", .target = target, .optimize = optimize }, &.{"c_setup"});
    module.addWin32ResourceFile(.{ .file = b.path("src/setup/resources/setup.rc") });
    for ([_][]const u8{ "user32", "gdi32", "shell32", "ole32", "advapi32", "comctl32" }) |library| {
        module.linkSystemLibrary(library, .{});
    }
    const exe = support.throughLld(b.addExecutable(.{ .name = "setup", .root_module = module }));
    exe.subsystem = .windows;
    const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "setup" } } });
    b.step("setup-exe", "Build setup.exe's program for x86-64 Windows").dependOn(&install.step);

    // Its platform-free half, tested on any host.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/setup/tests.zig"),
        .target = b.graph.host,
    }) });
    b.step("setup-test", "Test setup.exe's zip reader, manifest, versions and texts").dependOn(&b.addRunArtifact(tests).step);
}
