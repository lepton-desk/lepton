//! The Windows probes' steps (`webview2-check`, `win32-window-check`, `windows-gpu-check`),
//! registered by `build.zig` on a Windows target; kept here so `build.zig` stays under
//! the project's 800-line limit.

const std = @import("std");
const support = @import("build_support.zig");

/// `headers` are the C headers' modules for a Debug build; `core_headers` the names the
/// core's own modules use.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, headers: support.CHeaders, comptime core_headers: []const []const u8) void {
    const webview2_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-webview2-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/webview2_check.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.Debug,
            .link_libc = true,
        }),
    }));
    webview2_check.root_module.addIncludePath(b.path("webview2"));
    support.addCModules(b, webview2_check.root_module, headers, &.{"c_webview2_check"});
    for ([_][]const u8{ "ole32", "user32", "advapi32", "shlwapi" }) |name| {
        webview2_check.root_module.linkSystemLibrary(name, .{});
    }
    const run_webview2_check = b.addRunArtifact(webview2_check);
    b.step(
        "webview2-check",
        "Put WebView2 in a real Win32 window, load a page and report what reached it",
    ).dependOn(&run_webview2_check.step);

    // The native render path's Win32 window, measured from the screen. The window layer
    // comes from `src/windows_root.zig`: the core's root does not build on Windows yet.
    const window_layer = b.createModule(.{
        .root_source_file = b.path("src/windows_root.zig"),
        .target = target,
        .optimize = std.builtin.OptimizeMode.Debug,
        .link_libc = true,
    });
    window_layer.addIncludePath(b.path("webview2"));
    support.addCModules(b, window_layer, headers, core_headers);
    const win32_window_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-win32-window-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/win32_window_check.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "lepton_window", .module = window_layer }},
        }),
    }));
    win32_window_check.root_module.addIncludePath(b.path("webview2"));
    support.addCModules(b, win32_window_check.root_module, headers, &.{"c_windows"});
    for ([_][]const u8{ "user32", "gdi32", "dwmapi" }) |name| {
        win32_window_check.root_module.linkSystemLibrary(name, .{});
    }
    b.step(
        "win32-window-check",
        "Open the native path's Win32 window, present a frame and read it back from the screen",
    ).dependOn(&b.addRunArtifact(win32_window_check).step);

    // The GPU half's first measurement: a Direct3D 11 device and a flip-model swap chain
    // on that window, read back from the screen; WARP alongside.
    const windows_gpu_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-windows-gpu-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/windows_gpu_check.zig"),
            .target = target,
            .optimize = std.builtin.OptimizeMode.Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "lepton_window", .module = window_layer }},
        }),
    }));
    support.addCModules(b, windows_gpu_check.root_module, headers, &.{"c_windows"});
    for ([_][]const u8{ "user32", "gdi32", "dwmapi", "d3d11", "dxgi", "dwrite", "opengl32" }) |name| {
        windows_gpu_check.root_module.linkSystemLibrary(name, .{});
    }
    b.step(
        "windows-gpu-check",
        "Draw with Direct3D 11 into the native window and read it back from the screen",
    ).dependOn(&b.addRunArtifact(windows_gpu_check).step);
}
