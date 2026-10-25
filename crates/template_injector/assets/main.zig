//! The Lepton core entry point for {product}.
//!
//! Opens the channel, brings up the web engine, loads the built frontend into it, and
//! runs the engine's loop. Everything below the engine is the framework's; everything
//! after it is yours.
//!
//! ## Why there is no window here
//!
//! There is one window on screen and the engine owns it. That is not a shortcut and it
//! is not going to change by accident — it is what WPE's architecture produces today,
//! and pretending otherwise would mean opening a second window for one application.
//!
//! `struct wpe_view_backend_interface` (`wpe/view-backend.h:63-75`) is the entire
//! surface an embedder implements: `create`, `destroy`, `initialize`,
//! `get_renderer_host_fd`. There is no render target in it, so the engine cannot be
//! handed a frame to draw into, and the backend-client notifications cannot be
//! installed either — those need the platform's own `wpe_view_backend`, which this
//! process does not hold. What remains is to implement that interface: a
//! `wpebackend-lepton` that brings up EGL on `wpe_view_backend_get_renderer_host_fd`
//! and composites into the frame `core.waylandWindow` already presents. When that
//! lands, this file grows a window and a `presentPixels` call, and nothing above the
//! engine changes.

const std = @import("std");
/// Who the application is: `lepton.config.json`'s `identifier`, `productName`, `channel.name`,
/// `window.title` and `version`, read by `build.zig` on every build, so an edit there reaches the program.
pub const who = struct {{
    pub const identifier = std.fmt.comptimePrint("{{s}}", .{{@import("build_options").identifier}});
    pub const product = std.fmt.comptimePrint("{{s}}", .{{@import("build_options").product}});
    pub const channel = std.fmt.comptimePrint("{{s}}", .{{@import("build_options").channel}});
    pub const title = std.fmt.comptimePrint("{{s}}", .{{@import("build_options").title}});
    pub const version = std.fmt.comptimePrint("{{s}}", .{{@import("build_options").app_version}});
}};
const builtin = @import("builtin");
const core = @import("lepton_core");

/// Windows runs the page in WebView2 (a Win32 window, Windows' own frame); Linux in WPE
/// WebKit. The Linux-only steps below — the display server probe, the systemd scope,
/// `/proc/self/exe` — are left out at compile time on Windows.
const windows = builtin.os.tag == .windows;

/// The built frontend, relative to the project root.
///
/// Loaded from disk rather than from a development server: this binary is what ships,
/// and a shipped binary that silently depended on `localhost:5173` would be a binary
/// that only worked on the machine that built it. Run `lepton dev` (`npm run lepton dev`, `pnpm lepton dev`, …) for the
/// server-driven loop.
/// The bundler's output directory, relative to the project and to `share/<name>/`.
const frontend = "dist";

/// What your commands share: handlers get a `*AppState`, bound once in `main`. Put the
/// application's own state here — open documents, a database handle — instead of globals.
const AppState = struct {
    product: []const u8,
}};

/// Your commands: what the page can `invoke` beyond the core's own. Each one must also be
/// listed under `permissions` in `lepton.config.json` — a page calling an unlisted one is
/// refused, and a listed name that matches no command here fails this file's build.
///
/// From the page: `await invoke("app.name")` (`@lepton-desk/api/core`) resolves with the
/// bytes the handler wrote. Their names reach TypeScript as `src/lepton-commands.d.ts`,
/// regenerated from this list on every build.
///
/// Plugins (`@lepton-desk/plugin-*` in `package.json`) add their commands after yours;
/// they too run only when listed under `permissions`.
pub const commands = core.webviewRegistry.checkedWith(
    AppState,
    &.{{
        .{{ .name = "app.name", .run = &appName }},
    }},
    core.webviewRegistry.pluginCommands(@import("lepton_plugins").all),
    core.webviewRegistry.permissionList(@import("build_options").permissions),
);

/// Your events: what the core may send the page beyond its own (`window.state`,
/// `window.resized`). Declare a name here, then emit it from Zig —
/// `_ = try events.emit(&view.bridge, "notes.saved", bytes);` — and the page receives it
/// with `listen("notes.saved", ...)` (`@lepton-desk/api/event`). An undeclared name does
/// not compile, and the list reaches TypeScript in `src/lepton-commands.d.ts`.
pub const events = core.webviewEvents.Declared(&.{{}});

/// `app.name`: the product's name, as UTF-8.
fn appName(state: *AppState, _: []const u8, out: []u8) core.webviewRegistry.HandlerError!usize {{
    if (state.product.len > out.len) return error.TooLarge;
    @memcpy(out[0..state.product.len], state.product);
    return state.product.len;
}}

pub fn main(init: std.process.Init.Minimal) !void {{
    // Every `defer` below has run when `run` returns. With Servo the process then leaves
    // with `_exit`: `exit` would run the Servo library's destructors under its threads.
    run(init) catch |err| {{
        if (comptime core.render.exit_without_teardown) {{
            std.debug.print("error: {{s}}\n", .{{@errorName(err)}});
            std.c._exit(1);
        }}
        return err;
    }};
    if (comptime core.render.exit_without_teardown) std.c._exit(0);
}}

fn run(init: std.process.Init.Minimal) !void {{
    var gpa: std.heap.DebugAllocator(.{{}}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // `lepton replay`: the recorded requests run against these commands with no window,
    // and the process ends with the verdict. Before the display: a replay needs none.
    var app_state: AppState = .{{ .product = who.product }};
    if (comptime !core.render.is_native) {{
        if (core.webviewReplay.requested() != null) {{
            const registry = commands.bind(&app_state);
            core.webviewReplay.runFromEnvironment(allocator, &registry);
        }}
    }}

    // One copy per user: a second start (a deep link, a file opened from the desktop)
    // hands its arguments to this one and ends; this one emits them to the page as the
    // `app.opened` event in the loop below. The page reads its own start's with `app.args`.
    var instance: ?core.singleInstance.Instance = null;
    defer if (instance) |*held| held.deinit();
    if (comptime !core.render.is_native) {{
        var args = try init.args.iterateAllocator(allocator);
        defer args.deinit();
        _ = args.next();
        var given: [32][]const u8 = undefined;
        var count: usize = 0;
        while (args.next()) |arg| : (count += 1) {{
            if (count == given.len) break;
            given[count] = arg;
        }}
        switch (core.singleInstance.claim(who.identifier, given[0..count])) {{
            .primary => |held| instance = held,
            .forwarded => return,
            .alone => {{}},
        }}
    }}

    // The channel is created before the engine: the frontend SDK looks the window up by
    // name the moment its script runs, and a window that appeared a turn later would
    // find nobody home.
    var window_channel = try core.channel.create(allocator, who.channel, .{{}});
    defer window_channel.deinit(allocator);
    // SIGTERM, Ctrl+C or the session ending: the loop ends and every `defer` runs, so the
    // channel leaves `/dev/shm` with the process instead of staying behind.
    core.termination.catchSignals();

    const session: []const u8 = if (comptime windows) "win32" else probed: {{
        const display = core.display.Display.probe(core.display.processGetenv, null) catch |err| {{
            std.debug.print("no display server: {{t}}\n", .{{err}});
            return err;
        }};
        break :probed @tagName(display.session);
    }};

    // Two completely different programs, chosen at compile time rather than at run time.
    // `--target native` must not merely degrade when there is no engine: it is the mode
    // this project exists for, and it draws to the window directly.
    if (comptime core.render.is_native) {{
        return @import("native.zig").run(allocator, &window_channel);
    }}

    if (!core.render.can_load_pages) {{
        // Reached only by a webview build on a machine with no engine. Refused with a
        // reason rather than degraded into a blank window: saying so is more use than an
        // empty frame.
        std.debug.print(
            "this build cannot load pages: no web engine is installed. install " ++
                (if (windows) "the WebView2 runtime" else "WPE WebKit") ++
                " or build with --target native to run " ++ who.product ++ "\n",
            .{{}},
        );
        return error.NoEngine;
    }}

    const io = std.Io.Threaded.global_single_threaded.io();
    const address = try frontendAddress(allocator, io);
    defer allocator.free(address);

    // Before the engine: WebKitWPE reads its data directory when the context is created,
    // so this has to happen before `open` or the store stays where it was.
    //
    // Pointed at this application's own directories rather than left at the engine's
    // default, `$XDG_DATA_HOME/wpe`, which every WPE application on the machine shares.
    claimOwnDataDirectory();
    // `lepton.config.json`'s `webPermissions`: what the page may ask the engine for.
    core.webviewPermissions.setPolicies(@import("build_options").web_permissions);
    core.webviewPermissions.setApplication(who.identifier, who.product);

    // Before the engine too: WebKit's processes inherit the cgroup they are forked in, so
    // the application moves into its own `app-{identifier}-<pid>.scope` first and a task
    // manager shows the core and every WebKit process as {product} — not as part of the
    // terminal or editor that started it. Left where it is without systemd.
    // Windows needs no such step: WebView2's processes are this process's children, and
    // Task Manager groups them under it.
    if (comptime !windows) {{
        const scoped = core.scope.enter(who.identifier, who.product);
        core.report.fact("scope", if (scoped == .unavailable) .warn else .good, "{{t}}", .{{scoped}});
    }}

    var view = core.render.WebView.open() catch |err| {{
        std.debug.print("the engine refused to start: {{t}}\n", .{{err}});
        return err;
    }};
    defer view.close();

    // `window.decorations: false` (`-Dwindow-decorations`): no title bar, the page draws its
    // own and moves the window with `window.start_drag` (`@lepton-desk/api/window`). Before
    // the size, which is the client area's and depends on it.
    if (comptime !@import("build_options").window_decorations and @hasDecl(@TypeOf(view), "setDecorations")) view.setDecorations(false);
    // `lepton.config.json`'s `window`, passed to the build by the CLI (`-Dwindow-width`).
    const size = configuredSize();
    view.resized(@intCast(size.width), @intCast(size.height));
    view.map();
    // The window's name until the page sets `document.title`, and whenever it clears it.
    view.setTitle(who.title);

    // The core's scheme, registered on the view that lives here for the whole run. It is
    // both the IPC channel and, for a bundled frontend, the server: a `file://` document
    // has an opaque origin and WebKit refuses Vite's `type="module" crossorigin` entry
    // from it, so the bundle is served at `lepton://localhost/` instead.
    view.startBridge();
    // Closing the window — by the user, or by the page's `window.close()` — ends the run.
    view.watchClose();

    // The page's end of the channel. `__lepton` is injected before any of the page's own
    // scripts run, sized for the ring the core writes, and refreshed from that ring's
    // mapping at `/__lepton/region` on the page's own origin.
    // Before the transport is written: the page learns the application's command names
    // from it, and the bridge answers only what `permissions` grants.
    view.bridge.registry = commands.bind(&app_state);
    // Who the application is, for the page's `info()` (`@lepton-desk/api/app`) and the
    // window's name in a title bar it draws itself (`title()`, `@lepton-desk/api/window`).
    view.bridge.application = .{{ .name = who.product, .version = who.version, .identifier = who.identifier, .title = who.title }};
    // The dev server's origin before the transport: the transport defines itself only in
    // the application's own page, which under `lepton dev` is the dev server's.
    const from_dev_server = !std.mem.startsWith(u8, address, "file://");
    if (from_dev_server and !view.bridge.allowOriginOf(address)) {{
        core.report.fact("transport", .bad, "{{s}} is not an origin; the page will not reach the core", .{{address}});
    }}
    const outbound = window_channel.outboundRegion();
    if (!view.injectTransport(outbound.len)) {{
        core.report.fact("transport", .warn, "not injected: the page will run without a channel", .{{}});
    }}
    view.bridge.exposeRegion(outbound);

    if (!from_dev_server) {{
        view.bridge.serveFrom(address["file://".len..]);
        // The core's own origin: `lepton://localhost/`, or the `lepton.localhost` host the
        // WebView2 view answers on Windows (`transport.core_origin`).
        view.load(core.webviewTransport.core_origin ++ "/");
    }} else {{
        // The dev server's page reads the ring cross-origin from `lepton://localhost`;
        // the bridge names exactly this origin in its answers, never a wildcard.
        view.load(address);
    }}

    // The size is printed from the value the engine was given rather than from a second
    // copy baked in at substitution time, so the two cannot drift apart.
    core.report.fact("window", .plain, who.product ++ " · {{s}} · {{d}}×{{d}}", .{{
        session,
        size.width,
        size.height,
    }});
    if (core.render.loaded_webview_backend()) |implementation| {{
        core.report.fact("engine", .plain, "{{s}}", .{{implementation}});
    }}

    // A second, private channel for the round-trip figure: a frame out and its echo back
    // through a real mapping, timed. Separate from the page's ring so the probe never
    // consumes a sample the page has not read.
    var rtt_window = try core.channel.create(allocator, who.channel ++ "-rtt", .{{ .cell_count = 2 }});
    defer rtt_window.deinit(allocator);
    var rtt_peer = try core.channel.attach(allocator, who.channel ++ "-rtt");
    defer rtt_peer.deinit(allocator);

    window_channel.sendHello(core.wire.Mode.webview, 0) catch |err| switch (err) {{
        error.Full => {{}},
        else => return err,
    }};

    // Sleep in the engine's loop and wake on schedule. The previous loop called the
    // non-blocking pump in a tight `while`, which kept a core at 100% while the page sat
    // idle; a timer source ends each wait instead.
    _ = core.render.wake_webview_every(250);
    var probe = core.probe.Probe.init();
    var heap_high_water: u64 = 0;
    var last_publish: ?std.Io.Clock.Timestamp = null;

    while (!view.bridge.close_requested and !view.closed and !core.termination.requested()) {{
        _ = core.render.pump_webview_blocking();

        // Plugins that watch something (`fs.watch`) emit what changed.
        inline for (@import("lepton_plugins").all) |plugin| {{
            if (comptime @hasDecl(plugin, "tick")) plugin.tick(&view.bridge);
        }}

        if (instance) |*held| {{
            var opened: [core.singleInstance.max_message]u8 = undefined;
            while (held.take(&opened)) |message| {{
                var number: [4]u8 = undefined;
                std.mem.writeInt(u32, &number, core.singleInstance.remember(message), .little);
                _ = view.bridge.emit(core.webviewEvents.app_opened, &number) catch {{}};
            }}
        }}

        const now = std.Io.Clock.Timestamp.now(io, .awake);
        if (last_publish) |at| {{
            if (at.durationTo(now).raw.nanoseconds < std.time.ns_per_s) continue;
        }}
        last_publish = now;

        const round_trip = try roundTripNs(&rtt_window, &rtt_peer, io);
        probe.recordRoundTrip(round_trip);
        const reading = try probe.read(window_channel.freeCells(), window_channel.capacity());
        const heap = core.probe.heapBytes();
        heap_high_water = @max(heap_high_water, heap.in_use);

        const sample: core.wire.Sample = .{{
            .timestamp_ns = reading.uptime_ns,
            .rss_bytes = reading.rss_bytes,
            .heap_high_water_bytes = heap_high_water,
            .heap_in_use_bytes = heap.in_use,
            .ring_free_cells = reading.ring_free_cells,
            .ring_capacity_cells = reading.ring_capacity_cells,
            .round_trip_ns = reading.round_trip_ns,
            .round_trip_max_ns = reading.round_trip_max_ns,
        }};
        // Latest, not queued: the page snapshots the ring and never consumes, so a
        // queueing send would fill it in a minute and freeze the page on old numbers.
        _ = try window_channel.publishLatest(.sample, &sample);
        // Wakes the page's held `/__lepton/region` read; without it the page sleeps.
        view.bridge.published();
    }}

    // `lepton replay --page`: what the page asked against what was recorded.
    if (view.bridge.pageReplayPassed()) |passed| {{
        if (!passed) return error.PageReplayDiverged;
    }}
}}

/// One frame out through a real mapping and its echo back, in nanoseconds.
///
/// The echo carries the request's sequence and the reply flag, so a stale frame is
/// refused rather than timed.
fn roundTripNs(window: *core.channel.Channel, peer: *core.channel.Channel, io: std.Io) !u64 {{
    const ping: core.wire.Sample = std.mem.zeroes(core.wire.Sample);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const request = try window.send(.sample, &ping, .{{}});

    var frame = (try peer.receive()) orelse return error.NoRequestArrived;
    defer frame.release();
    if (frame.header.sequence != request) return error.SequenceMismatch;
    const echoed = try frame.as(core.wire.Sample);
    _ = try peer.send(.sample, &echoed, .{{ .sequence = request, .reply = true }});

    var back = (try window.receive()) orelse return error.NoReplyArrived;
    defer back.release();
    if (!core.wire.flagOf(back.header, .reply) or back.header.sequence != request) return error.SequenceMismatch;

    const elapsed = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}}

/// Where the frontend is: the dev server's URL, or `file://` + the bundle's directory,
/// which the caller serves at `lepton://localhost/` rather than loading as a file.
///
/// Built rather than written down because the project root is wherever the developer
/// cloned to, and a hardcoded absolute path would be wrong everywhere but here. The
/// working directory is read through `std.process` rather than `getcwd` so the same
/// source builds on all three platforms without a `#ifdef`.
fn frontendAddress(allocator: std.mem.Allocator, io: std.Io) ![:0]const u8 {{
    // `lepton dev` hands the server's address to the *build*, so the same executable
    // reads from a running server in development and from the files on disk in a package.
    // That is the whole reason the frontend is not compiled into the binary: an edit to it
    // does not change the binary, so nothing has to be rebuilt or restarted.
    const options = @import("build_options");
    if (options.dev_server.len != 0) {{
        return allocator.dupeSentinel(u8, options.dev_server, 0);
    }}

    // Installed layout first: `<prefix>/bin/<name>` beside `<prefix>/share/<name>/dist`.
    // A packaged binary is started from anywhere — a desktop entry runs it with `$HOME` as
    // its working directory — so its frontend is found from where the binary *is*, not
    // from where it was started. `zig-out` is laid out the same way by the build.
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (comptime windows) {{
        // `<prefix>\bin\<name>.exe` beside `<prefix>\share\<name>\dist`, as on Linux.
        if (std.process.executablePath(io, &exe_buffer)) |len| {{
            const exe = exe_buffer[0..len];
            const bin_dir = std.fs.path.dirname(exe) orelse "";
            const prefix = std.fs.path.dirname(bin_dir) orelse "";
            const directory = try std.fs.path.join(allocator, &.{{ prefix, "share", std.fs.path.stem(exe), frontend }});
            defer allocator.free(directory);
            const index = try std.fs.path.join(allocator, &.{{ directory, "index.html" }});
            defer allocator.free(index);
            if (prefix.len != 0) {{
                if (std.Io.Dir.accessAbsolute(io, index, .{{}})) |_| {{
                    return std.fmt.allocPrintSentinel(allocator, "file://{{s}}", .{{directory}}, 0);
                }} else |_| {{}}
            }}
        }} else |_| {{}}
    }} else if (readSelfExe(exe_buffer[0..])) |link| {{
        const bin_dir = std.fs.path.dirname(link) orelse "";
        const prefix = std.fs.path.dirname(bin_dir) orelse "";
        const name = std.fs.path.basename(link);
        const directory = try std.fmt.allocPrint(allocator, "{{s}}/share/{{s}}/{{s}}", .{{ prefix, name, frontend }});
        defer allocator.free(directory);
        const index = try std.fmt.allocPrintSentinel(allocator, "{{s}}/index.html", .{{directory}}, 0);
        defer allocator.free(index);
        if (prefix.len != 0 and access(index.ptr, readable) == 0) {{
            return std.fmt.allocPrintSentinel(allocator, "file://{{s}}", .{{directory}}, 0);
        }}
    }} else |_| {{}}

    // A tree that was never installed: the bundle next to where the program was started.
    const root = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(root);

    return std.fmt.allocPrintSentinel(
        allocator,
        "file://{{s}}/{s}",
        .{{ root, frontend }},
        0,
    );
}}

/// The window's first size, from the build rather than this file: `lepton new` once
/// wrote the numbers here, so a later edit to `lepton.config.json` changed nothing.
pub fn configuredSize() core.window.Size {{
    const options = @import("build_options");
    return .{{ .width = options.window_width, .height = options.window_height }};
}}

/// Gives this application's web data — localStorage, IndexedDB, cookies, caches — its
/// own directories: `~/.local/share/{identifier}` and `~/.cache/{identifier}` (the XDG
/// directories when set). Every Lepton page has the same origin, `lepton://localhost`, so
/// a shared directory would let one application read another's storage — which is what
/// happened before this, measured.
fn claimOwnDataDirectory() void {{
    if (core.render.use_application_directories(who.identifier)) return;
    // Windows: `%LOCALAPPDATA%` is set for every signed-in user; without it the engine
    // keeps its own default, `<exe>.WebView2` beside the executable.
    if (comptime windows) return;

    // No `HOME`: a service unit, a sandbox, a container. Beside the executable is the one
    // place a self-contained bundle can rely on being able to write, and for a portable
    // install it is also where the user's data belongs. `/proc/self/exe` rather than a
    // std helper: Zig 0.16 exposes no self-executable path.
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link = readSelfExe(buffer[0..]) catch return;
    const directory = std.fs.path.dirname(link) orelse return;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const written = std.fmt.bufPrintSentinel(&path, "{{s}}/data", .{{directory}}, 0) catch return;
    core.render.set_webview_data_directory(written.ptr);
}}

/// Reads `/proc/self/exe` into `buffer`.
///
/// libc's `readlink`, declared rather than reached through `std`: Zig 0.16's `std.posix`
/// has no `readlink` either, which is the second time this template has been bitten by the
/// same reorganisation.
const readlink = @extern(
    *const fn ([*:0]const u8, [*]u8, usize) callconv(.c) isize,
    .{ .name = "readlink" },
);

/// libc's `access`, for the same reason as `readlink`: whether the installed frontend is
/// there is asked of the kernel, not guessed from a path.
const access = @extern(
    *const fn ([*:0]const u8, c_int) callconv(.c) c_int,
    .{{ .name = "access" }},
);
const readable: c_int = 4; // R_OK

fn readSelfExe(buffer: []u8) ![]u8 {{
    const written = readlink("/proc/self/exe", buffer.ptr, buffer.len);
    if (written <= 0) return error.ExecutablePathUnavailable;
    return buffer[0..@intCast(written)];
}}
