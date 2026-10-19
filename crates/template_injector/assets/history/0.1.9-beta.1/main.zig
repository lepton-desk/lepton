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

pub fn main() !void {{
    var gpa: std.heap.DebugAllocator(.{{}}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // `lepton replay`: the recorded requests run against these commands with no window,
    // and the process ends with the verdict. Before the display: a replay needs none.
    var app_state: AppState = .{{ .product = "{product}" }};
    if (comptime !core.render.is_native) {{
        if (core.webviewReplay.requested() != null) {{
            const registry = commands.bind(&app_state);
            core.webviewReplay.runFromEnvironment(allocator, &registry);
        }}
    }}

    // The channel is created before the engine: the frontend SDK looks the window up by
    // name the moment its script runs, and a window that appeared a turn later would
    // find nobody home.
    var window_channel = try core.channel.create(allocator, "{channel}", .{{}});
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
        return runNative(allocator, &window_channel);
    }}

    if (!core.render.can_load_pages) {{
        // Reached only by a webview build on a machine with no engine. Refused with a
        // reason rather than degraded into a blank window: saying so is more use than an
        // empty frame.
        std.debug.print(
            "this build cannot load pages: no web engine is installed. install " ++
                (if (windows) "the WebView2 runtime" else "WPE WebKit") ++
                " or build with --target native to run {product}\n",
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
    core.webviewPermissions.setApplication("{identifier}", "{product}");

    // Before the engine too: WebKit's processes inherit the cgroup they are forked in, so
    // the application moves into its own `app-{identifier}-<pid>.scope` first and a task
    // manager shows the core and every WebKit process as {product} — not as part of the
    // terminal or editor that started it. Left where it is without systemd.
    // Windows needs no such step: WebView2's processes are this process's children, and
    // Task Manager groups them under it.
    if (comptime !windows) {{
        const scoped = core.scope.enter("{identifier}", "{product}");
        core.report.fact("scope", if (scoped == .unavailable) .warn else .good, "{{t}}", .{{scoped}});
    }}

    var view = core.render.WebView.open() catch |err| {{
        std.debug.print("the engine refused to start: {{t}}\n", .{{err}});
        return err;
    }};
    defer view.close();

    // `lepton.config.json`'s `window`, passed to the build by the CLI (`-Dwindow-width`).
    const size = configuredSize();
    view.resized(@intCast(size.width), @intCast(size.height));
    view.map();
    // The window's name until the page sets `document.title`, and whenever it clears it.
    view.setTitle("{title}");

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
    const outbound = window_channel.outboundRegion();
    if (!view.injectTransport(outbound.len)) {{
        core.report.fact("transport", .warn, "not injected: the page will run without a channel", .{{}});
    }}
    view.bridge.exposeRegion(outbound);

    if (std.mem.startsWith(u8, address, "file://")) {{
        view.bridge.serveFrom(address["file://".len..]);
        // The core's own origin: `lepton://localhost/`, or the `lepton.localhost` host the
        // WebView2 view answers on Windows (`transport.core_origin`).
        view.load(core.webviewTransport.core_origin ++ "/");
    }} else {{
        // The dev server's page reads the ring cross-origin from `lepton://localhost`;
        // the bridge names exactly this origin in its answers, never a wildcard.
        if (!view.bridge.allowOriginOf(address)) {{
            core.report.fact("transport", .bad, "{{s}} is not an origin; the page will not reach the core", .{{address}});
        }}
        view.load(address);
    }}

    // The size is printed from the value the engine was given rather than from a second
    // copy baked in at substitution time, so the two cannot drift apart.
    core.report.fact("window", .plain, "{product} · {{s}} · {{d}}×{{d}}", .{{
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
    var rtt_window = try core.channel.create(allocator, "{channel}-rtt", .{{ .cell_count = 2 }});
    defer rtt_window.deinit(allocator);
    var rtt_peer = try core.channel.attach(allocator, "{channel}-rtt");
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
        return allocator.dupeZ(u8, options.dev_server);
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
fn configuredSize() core.window.Size {{
    const options = @import("build_options");
    return .{{ .width = options.window_width, .height = options.window_height }};
}}

/// The native program: open a window, paint into it, present.
///
/// This is the whole of what `--target native` means, and it is a real frame presented
/// through the same window layer the webview path ends at — not a placeholder that clears
/// the background once. The window is opened before the loop for the same reason the
/// engine is: the frontend SDK looks it up by name the moment its script runs.
fn runNative(allocator: std.mem.Allocator, channel: *core.channel.Channel) !void {{
    const request: core.window.Request = .{{
        .title = "{product}",
        .app_id = "{identifier}",
        .size = configuredSize(),
    }};

    var opened = try openWindow(allocator, request);
    defer opened.close(allocator);

    var frame = try core.surface.Surface.init(allocator, request.size, .argb8888);
    defer frame.deinit();

    // Text needs Cairo, which the build probed for rather than assumed. Absent, the
    // screen still draws and still reports — a template that refused to run would report
    // less than one that ran without labels.
    var subject: ?core.render.Text = null;
    if (core.render.can_draw_text) {{
        subject = core.render.Text.init(frame) catch |failure| blk: {{
            core.report.fact("text", .warn, "unavailable: {{t}}", .{{failure}});
            break :blk null;
        }};
        if (subject) |*type_face| type_face.setFace("monospace", 13);
    }} else {{
        core.report.fact("text", .warn, "no cairo; drawing without labels", .{{}});
    }}
    defer if (subject) |*type_face| type_face.deinit();

    var state: State = .{{}};

    // The GPU draws the screen as a command list when it can (Wayland, an ES 3 context,
    // the text libraries at build time); otherwise, or when the driver refuses, the CPU
    // paints the frame below and it is uploaded whole, as before.
    var gpu_screen: GpuSlot = if (comptime core.gles3.available) (if (opened == .wayland) GpuScreen.init(allocator) catch null else null) else {{}};
    defer if (comptime core.gles3.available) {{
        if (gpu_screen) |*screen| screen.deinit(allocator);
    }};

    std.debug.print("render       native, no engine\n", .{{}});
    std.debug.print("requested    {{d}}x{{d}}\n", .{{ request.size.width, request.size.height }});
    std.debug.print("channel      {{s}}\n", .{{"{channel}"}});

    var frames: u32 = 0;
    while (!core.termination.requested()) {{
        frames += 1;

        if (opened.takeConfigure()) |configure| {{
            // An empty size is the window closing — from the titlebar's close control or
            // from the compositor — and the loop ends so the window is closed once, here.
            if (configure.size.isEmpty()) break;
            // Printed on every change: the size the compositor *gave* is the fact, the
            // requested one above is only the wish.
            std.debug.print("configured   {{d}}x{{d}}\n", .{{ configure.size.width, configure.size.height }});
            try frame.resize(configure.size);
            // The text draws through a view of the frame's buffer at the frame's stride;
            // both can change on a resize, so the view is rebuilt with them.
            if (subject) |*type_face| try type_face.retarget(frame);
            try opened.resize(configure.size);
        }}

        // Resident set, read from `/proc/self/statm`. It is on the screen because it is
        // the figure this project's native mode exists to be low, and a number that is
        // only ever printed to a log is a number nobody checks.
        state.resident_bytes = core.probe.residentSetBytes() catch state.resident_bytes;

        if (comptime core.gles3.available) {{
            if (gpu_screen) |*screen| switch (opened) {{
                .wayland => |handle| {{
                    if (screen.draw(allocator, handle, frame.size, frames, &state)) |_| {{
                        if (frames == 1) std.debug.print("present      gpu scene\n", .{{}});
                        opened.wait(16) catch break;
                        continue;
                    }} else |err| {{
                        core.report.fact("gpu scene", .warn, "{{t}}; drawing with the CPU", .{{err}});
                        screen.deinit(allocator);
                        gpu_screen = null;
                    }}
                }},
                .x11 => {{}},
            }};
        }}

        paint(&frame, if (subject) |*t| t else null, frames, &state);
        // The window's own chrome, over the content: client-side decorations are drawn by
        // the client or not at all, and a window without them can be neither moved nor
        // closed. Painted from the window's live input state, so hover follows the pointer.
        switch (opened) {{
            inline else => |handle| {{
                core.waylandChrome.paintTitlebar(handle.input, frame);
                core.waylandChrome.paintMenu(handle.menu, frame);
            }},
        }}
        try opened.presentPixels(frame.pixels, frame.size, frame.format);
        if (frames == 1) switch (opened) {{
            .wayland => |handle| if (handle.presentPath()) |path| std.debug.print("present      {{s}}\n", .{{@tagName(path)}}),
            .x11 => std.debug.print("present      shm\n", .{{}}),
        }};

        opened.wait(16) catch break;
        _ = channel;
    }}
}}

/// The native screen.
///
/// Not a gradient and not a clearing colour. A window that opens onto a flat fill is
/// indistinguishable from a window that opened onto nothing, which is exactly how a
/// broken render path hides: the pixels are the right size and there is no error. So the
/// screen carries something that can only be present if the surface was written and
/// presented — a title, a rule, and a live count of frames.
///
/// Drawn with the same `Surface` primitives and the same Cairo text binding the core's own
/// native check uses, because that is the path proven to reach the display.
fn paint(frame: *core.surface.Surface, subject: ?*core.render.Text, frames: u32, state: *State) void {{
    const ink = Palette{{}};

    frame.fill(ink.bed);

    const width: i32 = @intCast(frame.size.width);
    const height: i32 = @intCast(frame.size.height);

    // A masthead: the project name at a readable size over a rule. This is the part that
    // proves the surface round-tripped, because it is text and rules rather than a
    // rectangle every display backend can manage.
    frame.fillRect(0, 0, width, baseline * 4, ink.rail);
    frame.hLine(0, baseline * 4, width, ink.rule);

    if (subject) |type_face| {{
        _ = type_face.draw(baseline, baseline * 3, "{product}", ink.heading);
        _ = type_face.draw(baseline, baseline * 3 + baseline * 2, "native render, no web engine", ink.body);
    }}

    // The frame counter, which is the part a developer actually watches: it only advances
    // if the loop presented, and a stalled render stops it visibly rather than silently.
    var counter: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrint(&counter, "frames {{d}}\x00", .{{frames}}) catch return;
    if (subject) |type_face| {{
        _ = type_face.draw(baseline, baseline * 8, counter_text, ink.body);
    }}

    // A live measure off the shared-memory channel, so the window shows the IPC the
    // frontend SDK is already speaking. No page is involved and none is needed: this is
    // the same channel the frontend binds at run time.
    if (state.resident_bytes) |bytes| {{
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrintZ(&line, "resident set {{d}} KiB", .{{bytes / 1024}}) catch return;
        if (subject) |type_face| {{
            _ = type_face.draw(baseline, baseline * 10, text, ink.body);
        }}
    }} else if (subject) |type_face| {{
        _ = type_face.draw(baseline, baseline * 10, "resident set unavailable", ink.dim);
    }}

    // A baseline lattice down the body, so a present that writes the wrong stride or the
    // wrong format shows up as shear rather than as a clean but wrong picture.
    var y: i32 = baseline * 12;
    while (y < height - baseline) : (y += baseline * 3) {{
        frame.hLine(baseline, y, width - baseline * 2, ink.groove);
    }}
}}

/// The screen as draw commands (`core.scene`), drawn by the GPU in one call with the
/// window's frame (`core.chromeScene`): the same masthead, counters and lattice as `paint`,
/// with the title in the bar and the menu's labels, which the CPU path cannot shape.
const GpuScreen = if (core.gles3.available) struct {{
    heading: core.gles3.glyph_text.Font,
    body: core.gles3.glyph_text.Font,
    glyphs: core.gles3.atlas.Atlas,
    list: core.gles3.scene.List = .{{}},

    fn init(allocator: std.mem.Allocator) !@This() {{
        var path: [1024]u8 = undefined;
        const file = try core.gles3.glyph_text.find("sans", &path);
        var heading = try core.gles3.glyph_text.Font.open(allocator, file, 20, 0);
        errdefer heading.deinit();
        var body = try core.gles3.glyph_text.Font.open(allocator, file, 13, 1);
        errdefer body.deinit();
        return .{{ .heading = heading, .body = body, .glyphs = try core.gles3.atlas.Atlas.init(allocator) }};
    }}

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {{
        self.list.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.body.deinit();
        self.heading.deinit();
    }}

    fn draw(self: *@This(), allocator: std.mem.Allocator, handle: *core.waylandWindow.WaylandWindow, size: core.window.Size, frames: u32, state: *const State) !void {{
        const scene = core.gles3.scene;
        self.list.clear();
        const w: f32 = @floatFromInt(size.width);
        const h: f32 = @floatFromInt(size.height);
        const top: f32 = @floatFromInt(handle.input.titlebar_height);
        const b: f32 = baseline;
        try self.list.rect(allocator, .{{ .x = 0, .y = top, .width = w, .height = b * 4 }}, .{{ .fill = scene.rgba(0x1b2026ff) }});
        try self.list.rect(allocator, .{{ .x = 0, .y = top + b * 4, .width = w, .height = 1 }}, .{{ .fill = scene.rgba(0x2c343dff) }});
        _ = try self.heading.draw(allocator, &self.glyphs, &self.list, "{product}", b, top + b * 2, scene.rgba(0xe6eaefff));
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, "native render, drawn on the GPU", b, top + b * 3, scene.rgba(0x9da7b2ff));

        var line: [64]u8 = undefined;
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "frames {{d}}", .{{frames}}), b, top + b * 6, scene.rgba(0x9da7b2ff));
        if (state.resident_bytes) |bytes| {{
            _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "resident set {{d}} KiB", .{{bytes / 1024}}), b, top + b * 7, scene.rgba(0x9da7b2ff));
        }}
        var y: f32 = top + b * 9;
        while (y < h - b) : (y += b * 3) {{
            try self.list.rect(allocator, .{{ .x = b, .y = y, .width = w - b * 2, .height = 1 }}, .{{ .fill = scene.rgba(0x1f252bff) }});
        }}

        try core.chromeScene.titlebar(handle.input, "{product}", &self.body, allocator, &self.glyphs, &self.list);
        try core.chromeScene.menu(handle.menu, &self.body, allocator, &self.glyphs, &self.list);
        try handle.presentScene(&self.list, &self.glyphs, scene.rgba(0x14181cff), size, null);
    }}
}} else void;

/// `?GpuScreen` where the build can draw on the GPU, nothing where it cannot.
const GpuSlot = if (core.gles3.available) ?GpuScreen else void;

/// What the screen shows about this process, read rather than assumed.
const State = struct {{
    resident_bytes: ?u64 = null,
}};

/// The screen's colours.
///
/// Dark, low-chroma, and not decorative: a window that has to be read and looked at for
/// a working day should not be the brightest object on the desktop.
const Palette = struct {{
    bed: core.surface.Colour = .rgb(0x14, 0x18, 0x1c),
    rail: core.surface.Colour = .rgb(0x1b, 0x20, 0x26),
    rule: core.surface.Colour = .rgb(0x2c, 0x34, 0x3d),
    groove: core.surface.Colour = .rgb(0x1f, 0x25, 0x2b),
    heading: core.surface.Colour = .rgb(0xe6, 0xea, 0xef),
    body: core.surface.Colour = .rgb(0x9d, 0xa7, 0xb2),
    dim: core.surface.Colour = .rgb(0x63, 0x6c, 0x76),
}};

const baseline: i32 = 24;

/// A window on whichever display server this session actually has.
///
/// Two handle types behind one name, because the call sites below are identical and only
/// the construction differs. Both backends' methods are transcribed from their own modules;
/// where one is a method and the other a free function over `*anyopaque`, that difference
/// is real and is not smoothed over here.
const Opened = union(enum) {{
    wayland: *core.waylandWindow.WaylandWindow,
    x11: *core.x11Window.X11Window,

    fn close(self: Opened, allocator: std.mem.Allocator) void {{
        switch (self) {{
            .wayland => |handle| {{
                handle.close();
                allocator.destroy(handle);
            }},
            .x11 => |handle| {{
                handle.close();
                allocator.destroy(handle);
            }},
        }}
    }}

    fn takeConfigure(self: Opened) ?core.window.Configure {{
        return switch (self) {{
            .wayland => |handle| handle.takeConfigure(),
            .x11 => |handle| core.x11Window.takeConfigure(handle),
        }};
    }}

    fn resize(self: Opened, size: core.window.Size) !void {{
        return switch (self) {{
            .wayland => |handle| try handle.resize(size),
            .x11 => |handle| try core.x11Window.resize(handle, size),
        }};
    }}

    fn presentPixels(
        self: Opened,
        pixels: []const u8,
        size: core.window.Size,
        format: core.window.PixelFormat,
    ) !void {{
        return switch (self) {{
            .wayland => |handle| try handle.presentPixels(pixels, size, format),
            .x11 => |handle| try core.x11Window.presentPixels(handle, pixels, size, format),
        }};
    }}

    fn wait(self: Opened, timeout_ms: i32) !void {{
        return switch (self) {{
            .wayland => |handle| try handle.wait(timeout_ms),
            .x11 => |handle| try core.x11Window.wait(handle, timeout_ms),
        }};
    }}
}};

fn openWindow(allocator: std.mem.Allocator, request: core.window.Request) !Opened {{
    const display = try core.display.Display.probe(core.display.processGetenv, null);
    switch (display.session) {{
        .wayland => {{
            const handle = try allocator.create(core.waylandWindow.WaylandWindow);
            errdefer allocator.destroy(handle);
            try handle.open(allocator, request);
            return .{{ .wayland = handle }};
        }},
        .x11 => {{
            const handle = try allocator.create(core.x11Window.X11Window);
            errdefer allocator.destroy(handle);
            handle.* = try core.x11Window.X11Window.open(request);
            return .{{ .x11 = handle }};
        }},
    }}
}}

/// Gives this application's web data — localStorage, IndexedDB, cookies, caches — its
/// own directories: `~/.local/share/{identifier}` and `~/.cache/{identifier}` (the XDG
/// directories when set). Every Lepton page has the same origin, `lepton://localhost`, so
/// a shared directory would let one application read another's storage — which is what
/// happened before this, measured.
fn claimOwnDataDirectory() void {{
    if (core.render.use_application_directories("{identifier}")) return;
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
    const written = std.fmt.bufPrintZ(&path, "{{s}}/data", .{{directory}}) catch return;
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
