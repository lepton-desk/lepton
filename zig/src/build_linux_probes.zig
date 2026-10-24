//! The Linux GPU probes' steps (`gpu-check`, `scene-window-check`, `vulkan-check`),
//! registered by `build.zig` where EGL or Vulkan is found; kept here so `build.zig` stays
//! under the project's 800-line limit.

const std = @import("std");
const support = @import("build_support.zig");

/// `gpu-check` and `scene-window-check`: the native path with EGL. `headers` are the C
/// headers' modules for a Debug build.
pub fn gpu(b: *std.Build, target: std.Build.ResolvedTarget, core: *std.Build.Module, headers: support.CHeaders, protocol_step: ?*std.Build.Step) void {
    // Linked on the module, before the executable is made from it: `std.Build`
    // refuses a link after a compilation step exists, and the core module has the
    // same rule written next to its own library links.
    const gpu_module = b.createModule(.{
        .root_source_file = b.path("src/tools/gpu_check.zig"),
        .target = target,
        .optimize = std.builtin.OptimizeMode.Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lepton_core", .module = core },
        },
    });
    gpu_module.linkSystemLibrary("egl", .{});
    // EGL makes the context; OpenGL ES is what draws into it, and the two are
    // separate libraries. Linking only EGL leaves `glClear` undefined at link time.
    gpu_module.linkSystemLibrary("GLESv2", .{});
    gpu_module.linkSystemLibrary("wayland-egl", .{});
    support.addCModules(b, gpu_module, headers, &.{"c_gpu_check"});
    // The bare-surface probe builds a `wl_surface` itself rather than taking the
    // window's, which means it needs the Wayland client library directly instead of
    // inheriting it from the core module.

    const gpu_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-gpu-check",
        .root_module = gpu_module,
    }));

    const run_gpu_check = b.addRunArtifact(gpu_check);
    const gpu_check_step = b.step(
        "gpu-check",
        "Measure whether this framework's own window can carry a GPU surface",
    );
    gpu_check_step.dependOn(&run_gpu_check.step);

    const scene_window_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-scene-window-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/scene_window_check.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.ReleaseSafe,
            .link_libc = true,
            .imports = &.{.{ .name = "lepton_core", .module = core }},
        }),
    }));
    const scene_window_step = b.step(
        "scene-window-check",
        "Present the draw command list in a real window for 3 s and read the surface back",
    );
    scene_window_step.dependOn(&b.addRunArtifact(scene_window_check).step);
    if (protocol_step) |generated| scene_window_check.step.dependOn(generated);
}

/// `vulkan-check`: the threshold and a device that draws, headless.
pub fn vulkan(b: *std.Build, target: std.Build.ResolvedTarget, core: *std.Build.Module, headers: support.CHeaders) void {
    const vulkan_module = b.createModule(.{
        .root_source_file = b.path("src/tools/vulkan_check.zig"),
        .target = target,
        .optimize = std.builtin.OptimizeMode.Debug,
        .link_libc = true,
        .imports = &.{
            .{ .name = "lepton_core", .module = core },
        },
    });
    vulkan_module.linkSystemLibrary("vulkan", .{});
    support.addCModules(b, vulkan_module, headers, &.{"c_vulkan"});
    const vulkan_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-vulkan-check",
        .root_module = vulkan_module,
    }));
    const run_vulkan_check = b.addRunArtifact(vulkan_check);
    const vulkan_check_step = b.step(
        "vulkan-check",
        "Measure whether this machine's Vulkan meets the native renderer's threshold, and draws",
    );
    vulkan_check_step.dependOn(&run_vulkan_check.step);
}
