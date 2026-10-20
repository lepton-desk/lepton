//! Build graph for the Lepton core.
//!
//! One module, one responsibility: turn `src/` into the static library the window
//! layer and the C-ABI bridge link against, and run its tests.
//!
//! The Linux display libraries are discovered with `pkg-config` at configure
//! time rather than assumed. A host without Wayland still builds, because a
//! missing display server is a runtime condition the developer must be told
//! about, not a compile error that would take the whole core down with it.

const std = @import("std");
// Machine probes (pkg-config) and protocol generation, kept apart so this file stays
// under the 800-line limit; under `src/` so `lepton new` vendors it with the core.
const support = @import("src/build_support.zig");
const hasPkgConfig = support.hasPkgConfig;
const pkgConfigVersion = support.pkgConfigVersion;
const pkgConfigRequires = support.pkgConfigRequires;
const wpeBackendLibrary = support.wpeBackendLibrary;
const addPkgConfigIncludes = support.addPkgConfigIncludes;
const addIncludeDirectory = support.addIncludeDirectory;
const generateProtocols = support.generateProtocols;
const ProtocolBindings = support.ProtocolBindings;

/// Protocols vendored as XML and turned into C headers at build time.
///
/// The XML is the authoritative source of the wire protocol, and `wayland-scanner`
/// is the tool that turns it into bindings. Generating rather than checking in a
/// generated header keeps the vendored artefact to one reviewable text file, and
/// keeps the opcodes from drifting away from the protocol they came from.
const Protocol = support.Protocol;

/// What a project's build has to say about itself for the core to be built.
///
/// Only the facts the core cannot work out for itself. Which display libraries
/// exist and which Wayland protocols to generate are properties of the machine, so
/// the core asks the machine rather than being told by the project.
pub const CoreOptions = struct {
    /// Where this package's own files are, relative to the build's root.
    ///
    /// Not optional and not assumed to be `"."`, because the two callers need
    /// different answers: this repository's own build has the core at its root, while
    /// a scaffolded project has it under `vendor/lepton-core`. `std.Build` resolves
    /// `b.path` against the root of whichever build called it, so a core that assumed
    /// its own layout would look for `protocols/` one directory too high and fail on
    /// a machine that has Wayland, and only on that machine.
    root: []const u8,

    /// Target triple, already resolved by the caller.
    target: std.Build.ResolvedTarget,

    /// Optimisation level the core is compiled at.
    optimize: std.builtin.OptimizeMode,

    /// Which render path this build contains: `"webview"` or `"native"`.
    ///
    /// Passed in rather than read with `b.option` here, because `std.Build` refuses to
    /// declare the same option twice and the caller has already declared it — it is the
    /// caller's flag, and a core that claimed ownership of it would break the moment a
    /// project had its own `-Drender`. The value is validated where it is read, so an
    /// unrecognised string is still reported once, by the party that received it.
    render: []const u8 = "webview",
};

/// Configures the core module and returns it.
///
/// Public because a scaffolded project's build calls this instead of repeating it.
/// The display probes, the `pkg-config` queries and the protocol generation are
/// where the framework's platform knowledge lives; a second copy of them in every
/// project would drift, and a project whose copy has drifted compiles a core that is
/// subtly not Lepton's.
///
/// The caller owns the module's target and optimisation, because those are the
/// project's business. Everything else is the core's.
/// The GIO extension module that registers this framework's `WPEDisplay`.
///
/// Named for what the engine matches on: `WPE_PLATFORM` is set to `lepton`, so the file
/// name and the selector do not have to agree — but keeping them close means a directory
/// listing tells you what `WPE_PLATFORM` should say.
const platform_module_name = "wpe-display-lepton";

pub fn configureCore(b: *std.Build, options: CoreOptions) Configured {
    // The IPC layer maps POSIX shared memory and opens it with the platform's own
    // `shm_open`, so libc is a hard requirement rather than an option.
    const core = b.createModule(.{
        .root_source_file = b.path(b.pathJoin(&.{ options.root, "src", "root.zig" })),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    // `linkSystemLibrary` must be called on the module before any compilation step
    // consumes it, so the display probes run first and record only what this machine
    // actually has.
    const opts = b.addOptions();

    // `render` chooses which render path's sources enter the graph. Read here rather
    // than in a caller, because the decision that matters is the one about what gets
    // compiled: a build option read inside the core would leave the other path's
    // modules reachable, and a native build would carry a web engine in its binary.
    const render_choice = options.render;
    if (!std.mem.eql(u8, render_choice, "webview") and !std.mem.eql(u8, render_choice, "native")) {
        // Reported through the log rather than returned, because `configureCore` hands
        // back a module rather than a result — the same shape the display probes
        // settled on. A bad flag is a mistake in the command line, not a defect here.
        std.log.err("lepton: -Drender must be \"webview\" or \"native\", got \"{s}\"", .{render_choice});
    }

    // An unrecognised value falls back to webview, which is the default and therefore
    // the safe reading of a flag nobody understood. The error above has already said
    // so, so the build continuing is not the build pretending it succeeded.
    const native_render = std.mem.eql(u8, render_choice, "native");

    // Every library below is found by asking this machine's pkg-config, which describes
    // this machine's Linux libraries. Building for another system (`lepton build --windows`
    // on Linux) must not link them: the Windows binary was handed WPE, GLib, Cairo, XCB and
    // Wayland and the link failed on all of them (measured 2026-10-19).
    const linux = options.target.result.os.tag == .linux;

    // XCB's RandR header is a separate library from XCB itself: `xcb/xcb.h` and
    // `xcb/randr.h` live in the same package but the symbols do not, and a link
    // against `xcb` alone leaves the refresh-rate query undefined.
    const have_xcb = linux and hasPkgConfig(b, "xcb");
    const have_xcb_randr = linux and hasPkgConfig(b, "xcb-randr");
    const have_wayland = linux and hasPkgConfig(b, "wayland-client");

    // The native path's drawing and text. Probed for the same reason the display
    // libraries are: a machine without Cairo still compiles, because a missing text
    // stack is a runtime condition the developer has to be shown rather than a compile
    // error that takes the whole core down with it.
    const have_cairo = linux and hasPkgConfig(b, "cairo");

    // WPE WebKit for the webview path. Probed rather than assumed for the same
    // reason the display libraries are: a machine without it still builds the core,
    // and the absence is reported at run time where a developer can act on it.
    // The engine is probed and linked only when this build actually renders pages.
    // A native build that carried the engine would carry all of WebKit for a path
    // that never calls it, which is the single cost the native path exists to avoid —
    // and the reason `-Drender` is resolved here, in the build graph, rather than at
    // run time behind a `switch`.
    const want_webview = !native_render;
    // WPE is the Linux engine; Windows pages go through WebView2 below.
    const want_wpe = want_webview and linux;

    // Two engine ABIs are in the wild and they are not source compatible.
    //
    // The platform API (WPEPlatform) is stable and on by default since 2.54: the platform
    // integration lives inside WebKit, a view is made with
    // `g_object_new(WEBKIT_TYPE_WEB_VIEW, nullptr)` and the platform view is read back
    // from it. The older libwpe API is the other way round: the embedder loads a backend
    // (WPEBackend-fdo), hands WebKit a view backend, and the display is the embedder's.
    // 2.54 still offers it as a build option ("may be deprecated in the future", 2.54.0
    // release notes); Arch builds without it, Debian and openSUSE with it.
    //
    // Both are detected rather than assumed, because a machine may carry either, and
    // `-Dwpe-abi=legacy` exists for engines that have only the old one: the platform API
    // is preferred whenever it is there, since staying on the older path by accident
    // would mean a distribution dropping it breaks the build with no change on this side.
    const have_wpe_platform = want_wpe and hasPkgConfig(b, "wpe-platform-2.0");
    const have_wpe_legacy = want_wpe and hasPkgConfig(b, "wpe-1.0");
    const wpe_abi_choice = b.option(
        []const u8,
        "wpe-abi",
        "Engine ABI: auto (default), platform (WebKit 2.54+) or legacy (WebKit 2.52 and older)",
    ) orelse "auto";
    const use_platform_abi = if (std.mem.eql(u8, wpe_abi_choice, "platform"))
        true
    else if (std.mem.eql(u8, wpe_abi_choice, "legacy"))
        false
    else if (std.mem.eql(u8, wpe_abi_choice, "auto"))
        have_wpe_platform or !have_wpe_legacy
    else {
        std.log.err("lepton: -Dwpe-abi takes auto, platform or legacy, not '{s}'", .{wpe_abi_choice});
        std.process.exit(1);
    };
    if (want_wpe and hasPkgConfig(b, "wpe-webkit-2.0") and !use_platform_abi and !have_wpe_legacy) {
        std.log.err("lepton: -Dwpe-abi=legacy needs libwpe, which is not installed", .{});
        std.process.exit(1);
    }

    // An engine built without its libwpe API (Arch: `ENABLE_WPE_LEGACY_API=OFF`) has no
    // `webkit_web_view_new` or `webkit_web_view_backend_new`, even with libwpe itself still
    // installed, as it is after an upgrade from 2.52. Left to the linker this arrives as a
    // wall of undefined symbols that names neither the flag nor the reason, so the engine's
    // own `.pc` file is asked: built with the libwpe API, it requires `wpe-1.0`.
    if (want_wpe and !use_platform_abi and hasPkgConfig(b, "wpe-webkit-2.0") and
        !pkgConfigRequires(b, "wpe-webkit-2.0", "wpe-1.0"))
    {
        std.log.err(
            "lepton: the libwpe API was asked for (-Dwpe-abi=legacy, or no WPEPlatform found), " ++
                "but this WebKit {s} was built without it. " ++
                "Drop -Dwpe-abi=legacy to use the platform API.",
            .{pkgConfigVersion(b, "wpe-webkit-2.0") orelse ""},
        );
        std.process.exit(1);
    }
    const have_wpe = want_wpe and hasPkgConfig(b, "wpe-webkit-2.0");

    // Windows pages go through WebView2 (`render/webview/webview2/`): Microsoft's header is
    // vendored in `webview2/` with its licence, the runtime is the one Windows installs, and
    // its loader DLL is not shipped — the runtime is found in the registry
    // (`webview2/runtime.zig`). The rest is system DLLs every Windows has.
    const windows = options.target.result.os.tag == .windows;
    const have_webview2 = want_webview and windows;
    if (have_webview2) {
        core.addIncludePath(b.path(b.pathJoin(&.{ options.root, "webview2" })));
        for ([_][]const u8{ "ole32", "user32", "advapi32", "shlwapi", "shell32", "dwmapi" }) |library| {
            core.linkSystemLibrary(library, .{});
        }
    }

    // The platform backend's library name, taken from its own `.pc` file rather than
    // assembled from a version convention. `wpe_loader_init` hands its argument
    // straight to `dlopen`, and the file it must open is named after the backend's
    // *ABI*, which is not the release version: libwpe 1.16.3 and its fdo backend
    // 1.16.1 both ship `libWPEBackend-fdo-1.0.so`. `pkg-config --libs-only-l` is where
    // that ABI is written down, so this reads the packaging instead of guessing at it.
    // Only the libwpe path loads a backend; the platform path has none to find.
    const wpe_backend_library = if (want_wpe and !use_platform_abi) wpeBackendLibrary(b, "wpebackend-fdo-1.0") else null;
    if (have_wpe and !use_platform_abi and wpe_backend_library == null) {
        std.log.warn(
            "lepton: the web engine is installed but no platform backend was found;" ++
                " the webview path will report NoBackendLibrary at run time",
            .{},
        );
    }

    // Pango's shaper and PangoCairo are separate shared objects: linking only the
    // shaper leaves every `pango_cairo_*` symbol undefined at link time.
    if (have_cairo) core.linkSystemLibrary("cairo", .{});

    // The native path presents through the GPU when the driver will give it a window
    // surface, and copies through shared memory when it will not. Both halves are always
    // compiled in — the choice is made at run time and the machine that falls back must
    // not have been built without the other path.
    const gpu_text = native_render and linux and hasPkgConfig(b, "egl") and hasPkgConfig(b, "freetype2") and
        hasPkgConfig(b, "harfbuzz") and hasPkgConfig(b, "fontconfig");
    if (native_render and linux and hasPkgConfig(b, "egl")) {
        core.linkSystemLibrary("egl", .{});
        core.linkSystemLibrary("GLESv2", .{});
        core.linkSystemLibrary("wayland-egl", .{});
        // Text for the draw command list (`render/glyph_text.zig`), when all three are
        // installed: without them the native path draws with the CPU, as before.
        if (gpu_text) {
            for ([_][]const u8{ "freetype2", "harfbuzz", "fontconfig" }) |library| core.linkSystemLibrary(library, .{});
        }
    }

    if (have_wpe) {
        // The web engine, the object system it is built on, and the platform library
        // underneath. Linking only the engine leaves every `g_object_unref` and
        // `wpe_view_backend_*` symbol undefined.
        //
        // `pkg-config` is left in its default mode so it supplies the transitive
        // libraries and their link order, which is what the engine's own `.pc` file
        // already computed.
        core.linkSystemLibrary("WPEWebKit-2.0", .{});
        // libsoup directly too: the bridge builds response headers (`SoupMessageHeaders`)
        // for the dev server's cross-origin reads, and an indirect dependency's symbols
        // are not ours to call.
        core.linkSystemLibrary("libsoup-3.0", .{});
        // Only the ABI actually in use is linked. Linking the legacy `libwpe` alongside
        // the new platform library would resolve symbols that no longer exist in the
        // engine and leave the link failing on names the caller cannot see.
        if (use_platform_abi) {
            core.linkSystemLibrary("wpe-platform-2.0", .{});
        } else {
            core.linkSystemLibrary("wpe-1.0", .{});
        }
        core.linkSystemLibrary("gio-2.0", .{});
        core.linkSystemLibrary("gobject-2.0", .{});
        core.linkSystemLibrary("glib-2.0", .{});
    }

    // Cairo's and Pango's headers are not in the default include path, and Pango
    // reaches through GLib, HarfBuzz and FriBidi — each of which has its own directory
    // that `pangocairo.pc` alone does not spell out. The flags come from pkg-config so
    // the list is whatever this machine actually installs rather than a copy in this
    // file that goes stale at the next distribution upgrade.
    if (have_cairo) addPkgConfigIncludes(b, core, "cairo");
    // No include paths for WPE on purpose: nothing in this build reads its headers.
    // The engine is reached through explicit declarations in
    // `src/render/webview/wpe_view.zig`, each one transcribed from the installed
    // header, because Zig's C translator cannot process GLib at all. See that file
    // for the two translator defects and why rewriting the headers does not help.

    var protocols: ?ProtocolBindings = null;
    if (have_xcb) core.linkSystemLibrary("xcb", .{});
    if (have_xcb_randr) core.linkSystemLibrary("xcb-randr", .{});
    if (have_wayland) {
        core.linkSystemLibrary("wayland-client", .{});

        // xdg-shell is how a Wayland client asks for a window that a compositor will
        // actually map. Without these bindings a client can create a surface and then
        // have the compositor ignore it, so the generated headers are a requirement
        // for the Wayland path rather than a nicety.
        const generated = generateProtocols(b, options.root, &.{
            .{ .name = "xdg-shell", .version = 0 },
        });
        core.addIncludePath(generated.include_dir);
        // The descriptor table the inline request helpers call into: without it
        // compiled in, every helper is an undefined symbol at link time.
        core.addCSourceFile(.{ .file = generated.sourceFile("xdg-shell"), .flags = &.{} });
        protocols = generated;
    }

    opts.addOption(bool, "have_xcb", have_xcb);
    opts.addOption(bool, "have_xcb_randr", have_xcb_randr);
    opts.addOption(bool, "have_wayland", have_wayland);
    opts.addOption(bool, "native_render", native_render);
    opts.addOption(bool, "have_cairo", have_cairo);
    // The native path can draw its screen as a command list on the GPU (EGL + text libs).
    opts.addOption(bool, "gpu_scene", gpu_text);
    opts.addOption(bool, "have_wpe", have_wpe);
    opts.addOption(bool, "have_webview2", have_webview2);
    opts.addOption(bool, "wpe_platform_abi", use_platform_abi);
    opts.addOption([]const u8, "wpe_backend_library", wpe_backend_library orelse "");

    // The display module the engine will be pointed at. Built as a shared library and
    // its directory recorded, because the runtime has to open it itself and hold it:
    // GIO unloads what it scans, and a type whose vtable lives in a closed library
    // faults on the first virtual call.
    const platform_module = b.addLibrary(.{
        .name = platform_module_name,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ options.root, "src", "render", "webview", "platform", "lepton_display.zig" })),
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        }),
    });
    // WPE's display module; Windows has no WPE to load it.
    if (!windows) b.installArtifact(platform_module);

    // The file name and the install prefix are recorded; the build cache path is not.
    // A cache path is the kind of path that works on the machine that built the project
    // and nowhere else, and a module found only there is a module that ships broken.
    opts.addOption([]const u8, "lepton_platform_module_name", "lib" ++ platform_module_name ++ ".so");
    opts.addOption([]const u8, "lepton_platform_module_dir", b.getInstallPath(.lib, ""));
    core.addOptions("build_options", opts);

    return .{
        .module = core,
        .engine_linked = have_wpe,
        .platform_module_step = &platform_module.step,
        .protocol_step = if (protocols) |generated| generated.step else null,
        .native_render = native_render,
        .options = opts,
    };
}

/// What `configureCore` hands back.
///
/// The protocol step travels with the module rather than being asked for separately,
/// because generating the bindings creates a named step: a build that asked twice
/// would either duplicate the work or collide on the step's name, and both are
/// failures that only appear on a machine that has Wayland.
pub const Configured = struct {
    /// The core, ready to be imported by a name of the caller's choosing.
    module: *std.Build.Module,

    /// Whether this build links the web engine. Carried out of `configureCore` so the
    /// build graph never re-derives it: the step that measures the engine's capabilities
    /// and the option that decided to link it must not be able to disagree.
    engine_linked: bool,

    /// The step that builds this framework's display module, so a step that needs the
    /// module at run time can depend on it without re-deriving where it comes from.
    platform_module_step: *std.Build.Step,

    /// The step that generates the Wayland bindings, or null when there are none to
    /// make — a machine without Wayland has nothing to generate and nothing to wait
    /// for, and a build waiting on a step that does not exist never finishes.
    ///
    /// Every compilation that reaches the Wayland backend must depend on this. An
    /// include path does not carry the dependency on its own.
    protocol_step: ?*std.Build.Step,

    /// Whether the native render path was selected.
    native_render: bool,

    /// The `build_options` the core was given, for a test root that must see the same.
    options: *std.Build.Step.Options,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Declared here and handed to the core, exactly as a scaffolded project's build
    // does. `std.Build` refuses to declare the same option twice, so the core cannot
    // both own `-Drender` and be handed it — and it should not own it anyway, since a
    // product's build flags belong to the product.
    const render = b.option([]const u8, "render", "Render path: webview or native (default: webview)") orelse "webview";

    const configured = configureCore(b, .{
        .root = ".",
        .target = target,
        .optimize = optimize,
        .render = render,
    });
    const core = configured.module;

    const lib = b.addLibrary(.{
        .name = "lepton_core",
        .linkage = .static,
        .root_module = core,
    });
    b.installArtifact(lib);

    // On Windows the core root reaches the Linux window and display layers, which do not
    // build there; `src/windows_tests.zig` is the root of the Windows half instead, with the
    // same options, header and libraries.
    const tested = if (target.result.os.tag == .windows) blk: {
        const windows_tests = b.createModule(.{
            .root_source_file = b.path("src/windows_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        windows_tests.addOptions("build_options", configured.options);
        windows_tests.addIncludePath(b.path("webview2"));
        for ([_][]const u8{ "ole32", "user32", "advapi32", "shlwapi", "shell32", "dwmapi" }) |library| {
            windows_tests.linkSystemLibrary(library, .{});
        }
        break :blk windows_tests;
    } else core;
    const core_tests = support.throughLld(b.addTest(.{ .root_module = tested }));
    const run_core_tests = b.addRunArtifact(core_tests);

    if (configured.protocol_step) |generated| {
        lib.step.dependOn(generated);
        core_tests.step.dependOn(generated);
    }

    const test_step = b.step("test", "Run the core's real integration tests");
    test_step.dependOn(&run_core_tests.step);

    // The GPU renderer's own tests, separate from the core's.
    //
    // They are not in `test` because they need a GL ES context, which is a machine with
    // a working EGL implementation and nothing else — a different requirement from the
    // core's, and folding the two together would make one machine's missing driver look
    // like a failure of the framework's own logic.
    if (hasPkgConfig(b, "egl")) {
        const gpu_module = b.createModule(.{
            // The presenter, not the renderer: it imports the renderer, so both files'
            // tests run, and the presenter's choice of path is tested where it is made.
            .root_source_file = b.path("src/gpu_tests.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        gpu_module.linkSystemLibrary("egl", .{});
        gpu_module.linkSystemLibrary("GLESv2", .{});
        gpu_module.linkSystemLibrary("wayland-egl", .{});
        gpu_module.linkSystemLibrary("wayland-client", .{});
        // The presenter reaches the scene renderer, whose text half needs these.
        gpu_module.linkSystemLibrary("freetype2", .{});
        gpu_module.linkSystemLibrary("harfbuzz", .{});
        gpu_module.linkSystemLibrary("fontconfig", .{});

        const gpu_tests = support.throughLld(b.addTest(.{ .root_module = gpu_module }));
        const run_gpu_tests = b.addRunArtifact(gpu_tests);
        const gpu_test_step = b.step(
            "gpu-test",
            "Draw a frame on the GPU and assert on what the GPU read back",
        );
        gpu_test_step.dependOn(&run_gpu_tests.step);

        // The draw command list on GLES 3: shapes drawn by the GPU, read back.
        const gles3_module = b.createModule(.{
            .root_source_file = b.path("src/render/gles3.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
        });
        gles3_module.linkSystemLibrary("egl", .{});
        gles3_module.linkSystemLibrary("GLESv2", .{});
        // Text: HarfBuzz shapes, FreeType rasterises, fontconfig finds the file.
        gles3_module.linkSystemLibrary("freetype2", .{});
        gles3_module.linkSystemLibrary("harfbuzz", .{});
        gles3_module.linkSystemLibrary("fontconfig", .{});
        const gles3_tests = support.throughLld(b.addTest(.{ .root_module = gles3_module }));
        gpu_test_step.dependOn(&b.addRunArtifact(gles3_tests).step);

        const scene_check = support.throughLld(b.addExecutable(.{
            .name = "lepton-scene-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/scene_check.zig"),
                .target = target,
                // Timed: the driver's work, not a Debug build's bounds checks.
                .optimize = .ReleaseSafe,
                .link_libc = true,
                .imports = &.{.{ .name = "gles3", .module = gles3_module }},
            }),
        }));
        const scene_check_step = b.step(
            "scene-check",
            "Time a window-sized scene of cards on GLES 3 and say what crosses to the GPU",
        );
        scene_check_step.dependOn(&b.addRunArtifact(scene_check).step);
    }

    // A measurement, not a demo: the round-trip figure the framework's claim rests
    // on is produced by this binary from the real shared region.
    const roundtrip = support.throughLld(b.addExecutable(.{
        .name = "lepton-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/roundtrip.zig"),
            .target = target,
            // ReleaseFast so the figure describes the shipped code path rather
            // than a debug build's bounds checks.
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lepton_core", .module = core },
            },
        }),
    }));

    const run_roundtrip = b.addRunArtifact(roundtrip);
    const roundtrip_step = b.step("roundtrip", "Measure the real IPC round trip");
    roundtrip_step.dependOn(&run_roundtrip.step);

    // The real `invoke` handler behind stdin/stdout, for `@lepton-desk/api`'s tests.
    const invoke_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-invoke-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/invoke_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "lepton_core", .module = core }},
        }),
    }));
    const install_invoke_check = b.addInstallArtifact(invoke_check, .{});
    b.step("invoke-check", "Build the invoke handler the SDK tests talk to").dependOn(&install_invoke_check.step);

    // Opens a real window on whatever display the machine has and reports what the
    // server said about it. The check that the window layer is not merely a struct.
    const window_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-window-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/window_check.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lepton_core", .module = core },
            },
        }),
    }));

    // The native path's proof: opens a real window, paints a real frame with the
    // render layer's own surface, presents it and reports what the server said. A
    // separate step from `window-check` because it answers a different question —
    // not "can the layer open a window" but "can a frame drawn without an engine
    // reach the screen".
    const native_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-native-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/native_check.zig"),
            .target = target,
            // Debug by default, overridable: the tool drives a framebuffer and a
            // protocol by hand, and a safety check that fires is a finding rather
            // than a nuisance. Debug is the default so a failure points at the line
            // that failed rather than at whatever the optimiser kept.
            .optimize = b.option(
                std.builtin.OptimizeMode,
                "native-check-optimize",
                "Optimisation for the native check tool (default: Debug)",
            ) orelse .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lepton_core", .module = core },
            },
        }),
    }));

    const run_native_check = b.addRunArtifact(native_check);
    const native_check_step = b.step("native-check", "Paint a real window with the native path and report what reached the screen");
    native_check_step.dependOn(&run_native_check.step);

    if (configured.protocol_step) |generated| {
        native_check.step.dependOn(generated);
    }

    // The webview path's proof: a real page loaded into a real frame. Separate from
    // `window-check` and `native-check` because it answers a third question — not
    // "can a window open" and not "can a frame be drawn without an engine", but "can
    // an engine's pixels land in a frame this framework owns".
    const webview_check = support.throughLld(b.addExecutable(.{
        .name = "lepton-webview-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/webview_check.zig"),
            .target = target,
            .optimize = b.option(
                std.builtin.OptimizeMode,
                "webview-check-optimize",
                "Optimisation for the webview check tool (default: Debug)",
            ) orelse .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lepton_core", .module = core },
            },
        }),
    }));

    const run_webview_check = b.addRunArtifact(webview_check);
    const webview_check_step = b.step("webview-check", "Load a real page into a real frame and report what changed");
    webview_check_step.dependOn(&run_webview_check.step);

    if (configured.protocol_step) |generated| {
        webview_check.step.dependOn(generated);
    }

    // The WebView2 probe: Windows only, and on its own — the core does not build there yet
    // (POSIX IPC, the Linux window layer). `webview2/` holds Microsoft's header.
    if (target.result.os.tag == .windows) {
        const webview2_check = support.throughLld(b.addExecutable(.{
            .name = "lepton-webview2-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/webview2_check.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
            }),
        }));
        webview2_check.root_module.addIncludePath(b.path("webview2"));
        for ([_][]const u8{ "ole32", "user32", "advapi32", "shlwapi" }) |name| {
            webview2_check.root_module.linkSystemLibrary(name, .{});
        }
        const run_webview2_check = b.addRunArtifact(webview2_check);
        b.step(
            "webview2-check",
            "Put WebView2 in a real Win32 window, load a page and report what reached it",
        ).dependOn(&run_webview2_check.step);
    }

    // Only built where the engine is linked. A capability report on a build with no
    // engine would report "no pixels reachable" for the uninteresting reason that there
    // is no engine, and that message would be indistinguishable from the real one.
    if (configured.engine_linked) {
        const engine_caps_tool = support.throughLld(b.addExecutable(.{
            .name = "lepton-engine-caps",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/engine_caps.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "lepton_core", .module = core },
                },
            }),
        }));

        const run_engine_caps = b.addRunArtifact(engine_caps_tool);
        const engine_caps_step = b.step(
            "engine-caps",
            "Measure which ways into the web engine this build allows",
        );
        engine_caps_step.dependOn(&run_engine_caps.step);
    }

    if (configured.engine_linked) {
        const platform_check = support.throughLld(b.addExecutable(.{
            .name = "lepton-platform-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/platform_check.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "lepton_core", .module = core },
                },
            }),
        }));
        // The tool is pointed at the install prefix, so the module has to be installed —
        // building it is not enough. Depending on the install step is what makes the
        // directory the tool is told about actually contain what the tool is looking for.
        platform_check.step.dependOn(b.getInstallStep());
        platform_check.step.dependOn(configured.platform_module_step);

        const run_platform_check = b.addRunArtifact(platform_check);
        // The module lands in the install prefix, and the tool looks beside its own
        // executable first, so it is told where the build put it. This is the one place
        // a build directory is allowed to appear, and it is the override the runtime
        // documents for exactly this case.
        run_platform_check.setEnvironmentVariable(
            "LEPTON_PLATFORM_MODULE_DIR",
            b.getInstallPath(.lib, ""),
        );

        const platform_check_step = b.step(
            "platform-check",
            "Prove the engine draws into Lepton's own display",
        );
        platform_check_step.dependOn(&run_platform_check.step);
    }

    // Whether this framework's own window can be made into a GPU surface. The step is
    // here before anything is built on the answer, because the whole native GPU plan
    // rests on it and a plan built on an unmeasured assumption is the failure mode this
    // project keeps paying for.
    if (std.mem.eql(u8, render, "native") and hasPkgConfig(b, "egl")) {
        // Linked on the module, before the executable is made from it: `std.Build`
        // refuses a link after a compilation step exists, and the core module has the
        // same rule written next to its own library links.
        const gpu_module = b.createModule(.{
            .root_source_file = b.path("src/tools/gpu_check.zig"),
            .target = target,
            .optimize = .Debug,
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
                .optimize = .ReleaseSafe,
                .link_libc = true,
                .imports = &.{.{ .name = "lepton_core", .module = core }},
            }),
        }));
        const scene_window_step = b.step(
            "scene-window-check",
            "Present the draw command list in a real window for 3 s and read the surface back",
        );
        scene_window_step.dependOn(&b.addRunArtifact(scene_window_check).step);
        if (configured.protocol_step) |generated| scene_window_check.step.dependOn(generated);
    }

    // The 0.2.0 GPU renderer's first measurement: does this machine's Vulkan meet the
    // threshold (`render/gpu/vulkan_threshold.zig`), and does a device with exactly those
    // features draw? Headless, so it is not tied to the render path.
    if (hasPkgConfig(b, "vulkan")) {
        const vulkan_module = b.createModule(.{
            .root_source_file = b.path("src/tools/vulkan_check.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "lepton_core", .module = core },
            },
        });
        vulkan_module.linkSystemLibrary("vulkan", .{});
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

    const run_window_check = b.addRunArtifact(window_check);
    const window_check_step = b.step("window-check", "Open a real window and report what the server said");
    window_check_step.dependOn(&run_window_check.step);

    if (configured.protocol_step) |generated| {
        window_check.step.dependOn(generated);
    }
}
