//! The core's build file for a scaffolded project.
//!
//! One executable, from one source file. The frontend is not this build's business:
//! `lepton build` runs the bundler first and hands this build the directory to embed,
//! so the dependency runs the other way.
//!
//! ## The core is configured, not copied
//!
//! The display probes, the `pkg-config` queries and the Wayland protocol generation
//! are the framework's platform knowledge. This file asks the vendored core to
//! configure them through `configureCore` rather than repeating them, because a
//! second copy in every project would drift — and a project whose copy has drifted
//! compiles something that looks like Lepton's core and is not.
//!
//! ## Where the core comes from
//!
//! `vendor/lepton-core`, which is where `lepton new` puts it. That is what makes the
//! project self-contained: it builds with no network, no global package cache and no
//! checkout of Lepton beside it. `-Dcore` overrides the location for a developer
//! working on Lepton itself, which is the only reason the option exists — a project
//! should never need it.

const std = @import("std");

/// The vendored core's own build logic.
///
/// An `@import` of a relative path rather than a module import: this is the core's
/// build file being used as source, in the one build that needs it, with no module
/// graph entry to keep in step.
const lepton_build = @import("vendor/lepton-core/build.zig");

/// Where `lepton new` puts the core.
const VENDORED_CORE = "vendor/lepton-core";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    // `ReleaseSmall` by default rather than `Debug`: the whole reason this framework
    // exists is that a desktop application should not carry a browser's worth of
    // process. Debug is opt-in, which is the smaller promise.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, size, or debugging (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;

    const render = b.option([]const u8, "render", "Render path: webview or native (default: webview)") orelse "webview";
    const servo = b.option(bool, "servo", "Link the embedded Servo engine (Linux, webview path)") orelse false;

    // A contradictory pair of flags is a mistake in the command line, not a defect in
    // the build script, so it is reported rather than panicked: the message is the
    // only thing a developer sees.
    try check_render_options(render, servo);

    const name = b.option([]const u8, "name", "The binary's name") orelse "app";

    // The development server's address, given to the build by `lepton dev` rather than
    // compiled into the source. The frontend is a *runtime* address for this framework,
    // so a change to the frontend does not change the binary: the same executable reads
    // from whatever server it is pointed at.
    const dev_server = b.option([]const u8, "dev-server", "Address of the running dev server") orelse "";
    const dev_port = b.option(u16, "dev-port", "Port the dev server listens on") orelse 0;
    // `lepton.config.json`'s `permissions`, handed over by the CLI: the commands the page
    // may call. Checked against the registered commands when `main.zig` compiles.
    const permissions = b.option([]const u8, "permissions", "Commands the page may call, comma-separated") orelse "";
    // `webPermissions`: what the page may ask the engine for (camera, notifications, …),
    // `kind=allow|deny|ask` comma-separated. Absent kinds are denied.
    const web_permissions = b.option([]const u8, "web-permissions", "Engine permissions, kind=policy comma-separated") orelse "";
    // `lepton.config.json`'s `window.width`/`window.height`, handed over by the CLI on
    // every build so the configuration stays the source; a bare `zig build` gets the
    // configuration's own defaults.
    const window_width = b.option(u32, "window-width", "Initial window width") orelse 1200;
    const window_height = b.option(u32, "window-height", "Initial window height") orelse 800;

    // The vendored location, named once. `configureCore` needs it because
    // `std.Build` resolves paths against the root of the build that called it, and
    // from here that root is `src-lepton`, not the core's own directory.
    const configured = lepton_build.configureCore(b, .{
        .root = VENDORED_CORE,
        .target = target,
        .optimize = optimize,
        // Declared here and handed down, not read again inside the core: `std.Build`
        // refuses to declare the same option twice, so a core that read `-Drender`
        // itself would make every scaffolded project fail to configure.
        .render = render,
    });

    // The program's own build options. `lepton dev` passes the server address through
    // here rather than through the environment, so the binary records where it was told
    // to look and `lepton info` can report it afterwards.
    const options = b.addOptions();
    options.addOption([]const u8, "dev_server", dev_server);
    options.addOption(u16, "dev_port", dev_port);
    options.addOption([]const u8, "permissions", permissions);
    options.addOption([]const u8, "web_permissions", web_permissions);
    options.addOption(u32, "window_width", window_width);
    options.addOption(u32, "window_height", window_height);

    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        // Imported as a module rather than by relative path, so the project's own
        // files never grow a second copy of Lepton's internals and `@import`
        // inside the core keeps resolving against the core.
        .imports = &.{
            .{ .name = "lepton_core", .module = configured.module },
        },
    });
    root.addOptions("build_options", options);

    // Plugins: `-Dplugins=<module>=<absolute path of its plugin.zig>,…`, written by
    // `lepton` from the `"lepton": { "plugin": … }` field of the project's npm
    // dependencies. Each becomes a module that can import the core; `lepton_plugins.all`
    // is the tuple `main.zig` hands to the registry. No plugins: an empty tuple.
    const plugin_list = b.option([]const u8, "plugins", "Plugin modules, <module>=<path>, comma-separated") orelse "";
    const plugins_source = b.addWriteFiles();
    // Their settings: `lepton.config.json`'s `plugins` section flattened by `lepton` into
    // `key=value` lines (`fs.scope=$APPDATA`), plus `app.identifier`. Every plugin may
    // `@import("lepton_plugin_config").text` and read it with `core.pluginConfig`.
    const plugin_config = b.option([]const u8, "plugin-config", "Plugin settings, key=value lines") orelse "";
    const plugin_config_module = b.createModule(.{
        .root_source_file = plugins_source.add(
            "lepton_plugin_config.zig",
            b.fmt("pub const text = \"{f}\";\n", .{std.zig.fmtString(plugin_config)}),
        ),
    });
    var plugin_imports: std.ArrayList(std.Build.Module.Import) = .empty;
    var plugin_tuple: std.ArrayList(u8) = .empty;
    plugin_tuple.appendSlice(b.allocator, "pub const all = .{") catch @panic("out of memory");
    var plugin_entries = std.mem.tokenizeScalar(u8, plugin_list, ',');
    while (plugin_entries.next()) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse
            std.debug.panic("-Dplugins entry \"{s}\" is not <module>=<path>", .{entry});
        const module_name = entry[0..split];
        const plugin = b.createModule(.{
            .root_source_file = .{ .cwd_relative = entry[split + 1 ..] },
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lepton_core", .module = configured.module },
                .{ .name = "lepton_plugin_config", .module = plugin_config_module },
            },
        });
        plugin_imports.append(b.allocator, .{ .name = module_name, .module = plugin }) catch @panic("out of memory");
        plugin_tuple.appendSlice(b.allocator, b.fmt(" @import(\"{s}\"),", .{module_name})) catch @panic("out of memory");
    }
    plugin_tuple.appendSlice(b.allocator, " };\n") catch @panic("out of memory");
    const plugins_module = b.createModule(.{
        .root_source_file = plugins_source.add("lepton_plugins.zig", plugin_tuple.items),
        .imports = plugin_imports.items,
    });
    root.addImport("lepton_plugins", plugins_module);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root,
    });

    // The generated Wayland bindings, when there are any. Stated here rather than
    // assumed: forgetting it produces an undefined symbol at link time with nothing
    // in the message pointing at the cause.
    if (configured.protocol_step) |generated| {
        exe.step.dependOn(generated);
    }

    b.installArtifact(exe);

    // The TypeScript names of `main.zig`'s commands, regenerated on every build and
    // installed as `zig-out/lepton-commands.d.ts` (outside `bin/` and `share/`, so it is
    // never packaged); `lepton` copies it into `src/`. Run on the build machine, so only
    // when that is the target: a cross build has no binary here to run.
    // `zig build commands` writes only that file: `lepton` runs it before the frontend
    // is type-checked, so a page calling a command added in `main.zig` compiles on the
    // first build, not the second. Always defined; a no-op on a cross build.
    const commands_step = b.step("commands", "Write zig-out/lepton-commands.d.ts only");
    const host = b.graph.host.result;
    if (host.cpu.arch == target.result.cpu.arch and host.os.tag == target.result.os.tag) {
        const command_types = b.addExecutable(.{
            .name = "lepton-commands",
            .root_module = b.createModule(.{
                .root_source_file = b.path("lepton-commands.zig"),
                .target = target,
                .optimize = .Debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "app", .module = root },
                    .{ .name = "lepton_core", .module = configured.module },
                },
            }),
        });
        if (configured.protocol_step) |generated| command_types.step.dependOn(generated);
        const print_types = b.addRunArtifact(command_types);
        const types_file = print_types.captureStdOut(.{});
        const install_types = b.addInstallFile(types_file, "lepton-commands.d.ts");
        b.getInstallStep().dependOn(&install_types.step);
        commands_step.dependOn(&install_types.step);
    }

    // The bundled frontend, installed beside the binary in the layout a system install
    // uses: `bin/<name>` and `share/<name>/dist`. The executable resolves its frontend
    // from its own location (`<exe>/../share/<name>/dist`), so `zig-out` is a working
    // install prefix as built, and `lepton package` and a `/usr` install need no rewrite.
    // Passed in by `lepton` after the bundler ran rather than probed here: whether a
    // bundle exists is the CLI's knowledge, and a build script that guessed would
    // silently ship an application with a blank window.
    const frontend_dist = b.option([]const u8, "frontend-dist", "Absolute path of the bundled frontend to install") orelse "";
    if (frontend_dist.len != 0) {
        b.installDirectory(.{
            .source_dir = .{ .cwd_relative = frontend_dist },
            .install_dir = .prefix,
            .install_subdir = b.fmt("share/{s}/dist", .{name}),
        });
    }

    // `zig build run` from this directory should open a window, which is what a
    // developer expects the second time they type it.
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Build and open the window").dependOn(&run.step);
}

/// Refuses a combination of options that cannot mean anything.
///
/// Named rather than inlined because the message is the only thing a developer sees,
/// and a build script that has to be read to find out why it stopped is a build
/// script that gets worked around instead of fixed.
fn check_render_options(render: []const u8, servo: bool) !void {
    const webview = std.mem.eql(u8, render, "webview");
    const native = std.mem.eql(u8, render, "native");

    if (!webview and !native) {
        std.log.err("lepton: -Drender must be \"webview\" or \"native\", got \"{s}\"", .{render});
        return error.UnknownRenderPath;
    }

    if (servo and !webview) {
        std.log.err("lepton: -Dservo needs the webview render path: Servo is the engine the webview renders with, so there is nothing for it to serve in the native path", .{});
        return error.ServoNeedsWebview;
    }
}
