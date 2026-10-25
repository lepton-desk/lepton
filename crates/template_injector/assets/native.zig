//! The `--target native` program: no web engine, the window drawn directly.
//!
//! Lepton's file, as `build.zig` is: `lepton update` keeps it current, and `main.zig` —
//! the application's own commands, state and events — stays short. `main.zig` hands over
//! to `run` when the build is native (`core.render.is_native`); a webview build never
//! reaches this file, and Zig compiles none of it then.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("lepton_core");
/// `main.zig`: who the application is and the window's configured size.
const app = @import("root");
const who = app.who;

const windows = builtin.os.tag == .windows;

/// The native program: open a window, paint into it, present.
///
/// This is the whole of what `--target native` means, and it is a real frame presented
/// through the same window layer the webview path ends at — not a placeholder that clears
/// the background once. The window is opened before the loop for the same reason the
/// engine is: the frontend SDK looks it up by name the moment its script runs.
pub fn run(allocator: std.mem.Allocator, channel: *core.channel.Channel) !void {
    const request: core.window.Request = .{
        .title = who.title,
        .app_id = who.identifier,
        .size = app.configuredSize(),
        // The masthead's colour (`Palette.rail`): the system title bar takes it (Windows).
        .title_colour = .{ 0x1b, 0x20, 0x26 },
        // `lepton.config.json`'s `window.frameRate` (`-Dframe-rate`), or `LEPTON_FRAME_RATE`.
        .pacing = core.window.Pacing.chosen(comptime std.meta.stringToEnum(core.window.Pacing, @import("build_options").frame_rate) orelse .display),
    };

    var opened = try openWindow(allocator, request);
    defer opened.close(allocator);

    var frame = try core.surface.Surface.init(allocator, request.size, .argb8888);
    defer frame.deinit();

    // Text needs Cairo, which the build probed for rather than assumed. Absent, the
    // screen still draws and still reports — a template that refused to run would report
    // less than one that ran without labels.
    var subject: ?core.render.Text = null;
    if (core.render.can_draw_text) {
        subject = core.render.Text.init(frame) catch |failure| blk: {
            core.report.fact("text", .warn, "unavailable: {t}", .{failure});
            break :blk null;
        };
        if (subject) |*type_face| type_face.setFace("monospace", 13);
    } else {
        core.report.fact("text", .warn, "no cairo; drawing without labels", .{});
    }
    // `core.render.Text` is `void` in a build without Cairo (Windows today), so every use
    // of it is behind `can_draw_text`, decided at compile time.
    defer if (comptime core.render.can_draw_text) {
        if (subject) |*type_face| type_face.deinit();
    };

    var state: State = .{};

    // The GPU draws the screen as a command list when it can (Wayland, an ES 3 context,
    // the text libraries at build time); otherwise, or when the driver refuses, the CPU
    // paints the frame below and it is uploaded whole, as before.
    var gpu_screen: GpuSlot = if (comptime core.gles3.available) (if (opened == .wayland and core.gles3.wanted()) GpuScreen.init(allocator) catch null else null) else {};
    defer if (comptime core.gles3.available) {
        if (gpu_screen) |*screen| screen.deinit(allocator);
    };
    // Windows: Direct3D 11, else OpenGL 3.3 (`LEPTON_GPU=d3d11|gl` names one, `cpu` none);
    // when none opens, the CPU paints the frame below, as before.
    var win_gpu: WinGpuSlot = if (comptime core.windowsGpu.available) (if (core.windowsGpu.wanted()) WinGpuScreen.init(allocator, opened.win32) catch |err| blk: {
        core.report.fact("gpu", .warn, "{t}; drawing with the CPU", .{err});
        break :blk null;
    } else null) else {};
    defer if (comptime core.windowsGpu.available) {
        if (win_gpu) |*screen| screen.deinit(allocator, opened.win32);
    };

    std.debug.print("render       native, no engine\n", .{});
    std.debug.print("requested    {d}x{d}\n", .{ request.size.width, request.size.height });
    std.debug.print("channel      {s}\n", .{who.channel});
    std.debug.print("frames       {t}\n", .{request.pacing});

    var frames: u32 = 0;
    while (!core.termination.requested()) {
        frames += 1;

        if (opened.takeConfigure()) |configure| {
            // An empty size is the window closing — from the titlebar's close control or
            // from the compositor — and the loop ends so the window is closed once, here.
            if (configure.size.isEmpty()) break;
            // Printed on every change: the size the compositor *gave* is the fact, the
            // requested one above is only the wish.
            std.debug.print("configured   {d}x{d}\n", .{ configure.size.width, configure.size.height });
            try frame.resize(configure.size);
            // The text draws through a view of the frame's buffer at the frame's stride;
            // both can change on a resize, so the view is rebuilt with them.
            if (comptime core.render.can_draw_text) {
                if (subject) |*type_face| try type_face.retarget(frame);
            }
            try opened.resize(configure.size);
        }

        // Resident set, read from `/proc/self/statm`. It is on the screen because it is
        // the figure this project's native mode exists to be low, and a number that is
        // only ever printed to a log is a number nobody checks.
        state.resident_bytes = core.probe.residentSetBytes() catch state.resident_bytes;

        if (comptime core.gles3.available) {
            if (gpu_screen) |*screen| switch (opened) {
                .wayland => |handle| {
                    if (screen.draw(allocator, handle, frame.size, frames, &state)) |_| {
                        if (frames == 1) std.debug.print("present      gpu scene\n", .{});
                        opened.wait(16) catch break;
                        continue;
                    } else |err| {
                        core.report.fact("gpu scene", .warn, "{t}; drawing with the CPU", .{err});
                        screen.deinit(allocator);
                        gpu_screen = null;
                    }
                },
                .x11 => {},
            };
        }

        if (comptime core.windowsGpu.available) {
            if (win_gpu) |*screen| {
                if (screen.draw(allocator, frame.size, frames, &state)) |_| {
                    if (frames == 1) std.debug.print("present      {s}\n", .{screen.renderer.name()});
                    opened.wait(16) catch break;
                    continue;
                } else |err| {
                    core.report.fact("gpu", .warn, "{t}; drawing with the CPU", .{err});
                    screen.deinit(allocator, opened.win32);
                    win_gpu = null;
                }
            }
        }

        paint(&frame, if (subject) |*t| t else null, frames, &state);
        // The window's own chrome, over the content: client-side decorations are drawn by
        // the client or not at all, and a window without them can be neither moved nor
        // closed. Painted from the window's live input state, so hover follows the pointer.
        // Windows draws the frame itself (title bar, buttons, borders): nothing to paint.
        if (comptime !windows) switch (opened) {
            inline else => |handle| {
                core.waylandChrome.paintTitlebar(handle.input, frame);
                if (comptime core.render.can_draw_text) {
                    if (subject) |*type_face| titleOnBar(type_face, handle.input);
                }
                core.waylandChrome.paintMenu(handle.menu, frame);
            },
        };
        try opened.presentPixels(frame.pixels, frame.size, frame.format);
        if (frames == 1) {
            if (comptime windows) {
                std.debug.print("present      gdi\n", .{});
            } else switch (opened) {
                .wayland => |handle| if (handle.presentPath()) |path| std.debug.print("present      {s}\n", .{@tagName(path)}),
                .x11 => std.debug.print("present      shm\n", .{}),
            }
        }

        opened.wait(16) catch break;
        _ = channel;
    }
}

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
fn paint(frame: *core.surface.Surface, subject: ?*core.render.Text, frames: u32, state: *State) void {
    const ink = Palette{};

    frame.fill(ink.bed);

    const width: i32 = @intCast(frame.size.width);
    const height: i32 = @intCast(frame.size.height);

    // A masthead: the project name at a readable size over a rule. This is the part that
    // proves the surface round-tripped, because it is text and rules rather than a
    // rectangle every display backend can manage.
    frame.fillRect(0, 0, width, baseline * 4, ink.rail);
    frame.hLine(0, baseline * 4, width, ink.rule);

    // Type only where the build can draw it (`core.render.Text` is `void` without Cairo).
    if (comptime core.render.can_draw_text) {
        if (subject) |type_face| label(type_face, frames, state, ink);
    }

    // A baseline lattice down the body, so a present that writes the wrong stride or the
    // wrong format shows up as shear rather than as a clean but wrong picture.
    var y: i32 = baseline * 12;
    while (y < height - baseline) : (y += baseline * 3) {
        frame.hLine(baseline, y, width - baseline * 2, ink.groove);
    }
}

/// The window's name on the bar `paintTitlebar` drew, which leaves the text to a caller
/// that has a font (the GPU path's is `chromeScene.titlebar`). Cut with "…" before the
/// controls.
fn titleOnBar(type_face: *core.render.Text, state: core.waylandInput.Input) void {
    const bar: i32 = @intCast(state.titlebar_height);
    if (bar == 0) return;
    const room: i32 = @as(i32, @intFromFloat(core.waylandChrome.controlBounds(state).minimize.x)) - 24;
    var cut: [core.render.Text.max_bytes]u8 = undefined;
    var shown: []const u8 = who.title[0..@min(who.title.len, cut.len - 3)];
    var extent = type_face.measure(shown) orelse return;
    var text = shown;
    while (extent.width > room and shown.len > 0) {
        shown.len -= 1;
        while (shown.len > 0 and shown[shown.len] & 0xc0 == 0x80) shown.len -= 1;
        @memcpy(cut[0..shown.len], shown);
        @memcpy(cut[shown.len..][0..3], "…");
        text = cut[0 .. shown.len + 3];
        extent = type_face.measure(text) orelse return;
    }
    _ = type_face.draw(12, @divTrunc(bar + extent.ascent - extent.descent, 2), text, core.waylandChrome.palette.glyph);
}

/// The screen's type: the name, the frame counter and the resident set.
fn label(type_face: *core.render.Text, frames: u32, state: *State, ink: Palette) void {
    _ = type_face.draw(baseline, baseline * 3, who.product, ink.heading);
    _ = type_face.draw(baseline, baseline * 3 + baseline * 2, "native render, no web engine", ink.body);

    // The frame counter, which is the part a developer actually watches: it only advances
    // if the loop presented, and a stalled render stops it visibly rather than silently.
    var counter: [32]u8 = undefined;
    const counter_text = std.fmt.bufPrint(&counter, "frames {d}\x00", .{frames}) catch return;
    _ = type_face.draw(baseline, baseline * 8, counter_text, ink.body);

    // A live measure off the shared-memory channel, so the window shows the IPC the
    // frontend SDK is already speaking. No page is involved and none is needed: this is
    // the same channel the frontend binds at run time.
    if (state.resident_bytes) |bytes| {
        var line: [64]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&line, "resident set {d} KiB", .{bytes / 1024}, 0) catch return;
        _ = type_face.draw(baseline, baseline * 10, text, ink.body);
    } else {
        _ = type_face.draw(baseline, baseline * 10, "resident set unavailable", ink.dim);
    }
}

/// The screen as draw commands (`core.scene`), drawn by the GPU in one call with the
/// window's frame (`core.chromeScene`): the same masthead, counters and lattice as `paint`,
/// with the title in the bar and the menu's labels, which the CPU path cannot shape.
const GpuScreen = if (core.gles3.available) struct {
    heading: core.gles3.glyph_text.Font,
    body: core.gles3.glyph_text.Font,
    glyphs: core.gles3.atlas.Atlas,
    list: core.gles3.scene.List = .{},

    fn init(allocator: std.mem.Allocator) !@This() {
        var path: [1024]u8 = undefined;
        const file = try core.gles3.glyph_text.find("sans", &path);
        var heading = try core.gles3.glyph_text.Font.open(allocator, file, 20, 0);
        errdefer heading.deinit();
        var body = try core.gles3.glyph_text.Font.open(allocator, file, 13, 1);
        errdefer body.deinit();
        return .{ .heading = heading, .body = body, .glyphs = try core.gles3.atlas.Atlas.init(allocator) };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.body.deinit();
        self.heading.deinit();
    }

    fn draw(self: *@This(), allocator: std.mem.Allocator, handle: *core.waylandWindow.WaylandWindow, size: core.window.Size, frames: u32, state: *const State) !void {
        const scene = core.gles3.scene;
        self.list.clear();
        const w: f32 = @floatFromInt(size.width);
        const h: f32 = @floatFromInt(size.height);
        const top: f32 = @floatFromInt(handle.input.titlebar_height);
        const b: f32 = baseline;
        try self.list.rect(allocator, .{ .x = 0, .y = top, .width = w, .height = b * 4 }, .{ .fill = scene.rgba(0x1b2026ff) });
        try self.list.rect(allocator, .{ .x = 0, .y = top + b * 4, .width = w, .height = 1 }, .{ .fill = scene.rgba(0x2c343dff) });
        _ = try self.heading.draw(allocator, &self.glyphs, &self.list, who.product, b, top + b * 2, scene.rgba(0xe6eaefff));
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, "native render, drawn on the GPU", b, top + b * 3, scene.rgba(0x9da7b2ff));

        var line: [64]u8 = undefined;
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "frames {d}", .{frames}), b, top + b * 6, scene.rgba(0x9da7b2ff));
        if (state.resident_bytes) |bytes| {
            _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "resident set {d} KiB", .{bytes / 1024}), b, top + b * 7, scene.rgba(0x9da7b2ff));
        }
        var y: f32 = top + b * 9;
        while (y < h - b) : (y += b * 3) {
            try self.list.rect(allocator, .{ .x = b, .y = y, .width = w - b * 2, .height = 1 }, .{ .fill = scene.rgba(0x1f252bff) });
        }

        try core.chromeScene.titlebar(handle.input, who.title, &self.body, allocator, &self.glyphs, &self.list);
        try core.chromeScene.menu(handle.menu, &self.body, allocator, &self.glyphs, &self.list);
        try handle.presentScene(&self.list, &self.glyphs, scene.rgba(0x14181cff), size, null);
    }
} else void;

/// `?GpuScreen` where the build can draw on the GPU, nothing where it cannot.
const GpuSlot = if (core.gles3.available) ?GpuScreen else void;

/// Windows: the same screen on the GPU (`core.windowsGpu`: Direct3D 11, else OpenGL 3.3),
/// with DirectWrite's text; the swap chain (or the swap interval) paces the frames. Windows
/// draws the title bar, so the masthead starts at 0.
const WinGpuScreen = if (core.windowsGpu.available) struct {
    renderer: core.windowsGpu.Renderer,
    heading: core.windowsGpu.glyph_text.Font,
    body: core.windowsGpu.glyph_text.Font,
    glyphs: core.atlas.Atlas,
    list: core.scene.List = .{},

    fn init(allocator: std.mem.Allocator, window: *core.window.win32.NativeWindow) !@This() {
        var refused: core.windowsGpu.Renderer.Refusals = .{};
        const opened = core.windowsGpu.Renderer.open(window.hwnd, window.size.width, window.size.height, window.pacing, &refused);
        // Each backend that refused, and why, before the one that opened (or the CPU).
        for (refused.slice()) |refusal| core.report.fact("gpu", .warn, "{t} refused: {t}", .{ refusal.backend, refusal.reason });
        var renderer = opened orelse return error.NoGpuBackend;
        errdefer renderer.deinit();
        var heading = try core.windowsGpu.glyph_text.Font.open(allocator, "sans", 20, 0);
        errdefer heading.deinit();
        var body = try core.windowsGpu.glyph_text.Font.open(allocator, "sans", 13, 1);
        errdefer body.deinit();
        window.setFrameWait(renderer.frameWait());
        window.setPresentPaces(renderer.pacesItself());
        return .{ .renderer = renderer, .heading = heading, .body = body, .glyphs = try core.atlas.Atlas.init(allocator) };
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator, window: *core.window.win32.NativeWindow) void {
        window.setFrameWait(null);
        window.setPresentPaces(false);
        self.list.deinit(allocator);
        self.glyphs.deinit(allocator);
        self.body.deinit();
        self.heading.deinit();
        self.renderer.deinit();
    }

    fn draw(self: *@This(), allocator: std.mem.Allocator, size: core.window.Size, frames: u32, state: *const State) !void {
        const scene = core.scene;
        self.list.clear();
        const w: f32 = @floatFromInt(size.width);
        const h: f32 = @floatFromInt(size.height);
        const b: f32 = baseline;
        try self.list.rect(allocator, .{ .x = 0, .y = 0, .width = w, .height = b * 4 }, .{ .fill = scene.rgba(0x1b2026ff) });
        try self.list.rect(allocator, .{ .x = 0, .y = b * 4, .width = w, .height = 1 }, .{ .fill = scene.rgba(0x2c343dff) });
        _ = try self.heading.draw(allocator, &self.glyphs, &self.list, who.product, b, b * 2, scene.rgba(0xe6eaefff));
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, "native render, drawn on the GPU", b, b * 3, scene.rgba(0x9da7b2ff));

        var line: [64]u8 = undefined;
        _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "frames {d}", .{frames}), b, b * 6, scene.rgba(0x9da7b2ff));
        if (state.resident_bytes) |bytes| {
            _ = try self.body.draw(allocator, &self.glyphs, &self.list, try std.fmt.bufPrint(&line, "resident set {d} KiB", .{bytes / 1024}), b, b * 7, scene.rgba(0x9da7b2ff));
        }
        var y: f32 = b * 9;
        while (y < h - b) : (y += b * 3) {
            try self.list.rect(allocator, .{ .x = b, .y = y, .width = w - b * 2, .height = 1 }, .{ .fill = scene.rgba(0x1f252bff) });
        }
        try self.renderer.draw(&self.list, &self.glyphs, scene.rgba(0x14181cff), .{ .width = size.width, .height = size.height });
    }
} else void;

/// `?WinGpuScreen` in a native Windows build, nothing elsewhere.
const WinGpuSlot = if (core.windowsGpu.available) ?WinGpuScreen else void;

/// What the screen shows about this process, read rather than assumed.
const State = struct {
    resident_bytes: ?u64 = null,
};

/// The screen's colours.
///
/// Dark, low-chroma, and not decorative: a window that has to be read and looked at for
/// a working day should not be the brightest object on the desktop.
const Palette = struct {
    bed: core.surface.Colour = .rgb(0x14, 0x18, 0x1c),
    rail: core.surface.Colour = .rgb(0x1b, 0x20, 0x26),
    rule: core.surface.Colour = .rgb(0x2c, 0x34, 0x3d),
    groove: core.surface.Colour = .rgb(0x1f, 0x25, 0x2b),
    heading: core.surface.Colour = .rgb(0xe6, 0xea, 0xef),
    body: core.surface.Colour = .rgb(0x9d, 0xa7, 0xb2),
    dim: core.surface.Colour = .rgb(0x63, 0x6c, 0x76),
};

const baseline: i32 = 24;

/// A window on whichever display server this session actually has.
///
/// Two handle types behind one name, because the call sites below are identical and only
/// the construction differs. Both backends' methods are transcribed from their own modules;
/// where one is a method and the other a free function over `*anyopaque`, that difference
/// is real and is not smoothed over here.
const Opened = if (windows) Win32Opened else LinuxOpened;

/// Windows: the Win32 window (`core.window.win32`); Windows draws its frame.
const Win32Opened = union(enum) {
    win32: *core.window.win32.NativeWindow,

    fn close(self: Win32Opened, allocator: std.mem.Allocator) void {
        self.win32.close();
        allocator.destroy(self.win32);
    }

    fn takeConfigure(self: Win32Opened) ?core.window.Configure {
        return self.win32.takeConfigure();
    }

    fn resize(self: Win32Opened, size: core.window.Size) !void {
        return self.win32.resize(size);
    }

    fn presentPixels(self: Win32Opened, pixels: []const u8, size: core.window.Size, format: core.window.PixelFormat) !void {
        return self.win32.presentPixels(pixels, size, format);
    }

    fn wait(self: Win32Opened, timeout_ms: i32) !void {
        return self.win32.wait(timeout_ms);
    }
};

const LinuxOpened = union(enum) {
    wayland: *core.waylandWindow.WaylandWindow,
    x11: *core.x11Window.X11Window,

    fn close(self: Opened, allocator: std.mem.Allocator) void {
        switch (self) {
            .wayland => |handle| {
                handle.close();
                allocator.destroy(handle);
            },
            .x11 => |handle| {
                handle.close();
                allocator.destroy(handle);
            },
        }
    }

    fn takeConfigure(self: Opened) ?core.window.Configure {
        return switch (self) {
            .wayland => |handle| handle.takeConfigure(),
            .x11 => |handle| core.x11Window.takeConfigure(handle),
        };
    }

    fn resize(self: Opened, size: core.window.Size) !void {
        return switch (self) {
            .wayland => |handle| try handle.resize(size),
            .x11 => |handle| try core.x11Window.resize(handle, size),
        };
    }

    fn presentPixels(
        self: Opened,
        pixels: []const u8,
        size: core.window.Size,
        format: core.window.PixelFormat,
    ) !void {
        return switch (self) {
            .wayland => |handle| try handle.presentPixels(pixels, size, format),
            .x11 => |handle| try core.x11Window.presentPixels(handle, pixels, size, format),
        };
    }

    fn wait(self: Opened, timeout_ms: i32) !void {
        return switch (self) {
            .wayland => |handle| try handle.wait(timeout_ms),
            .x11 => |handle| try core.x11Window.wait(handle, timeout_ms),
        };
    }
};

fn openWindow(allocator: std.mem.Allocator, request: core.window.Request) !Opened {
    if (comptime windows) {
        const handle = try allocator.create(core.window.win32.NativeWindow);
        errdefer allocator.destroy(handle);
        try handle.open(request);
        return .{ .win32 = handle };
    }
    const display = try core.display.Display.probe(core.display.processGetenv, null);
    switch (display.session) {
        .wayland => {
            const handle = try allocator.create(core.waylandWindow.WaylandWindow);
            errdefer allocator.destroy(handle);
            try handle.open(allocator, request);
            return .{ .wayland = handle };
        },
        .x11 => {
            const handle = try allocator.create(core.x11Window.X11Window);
            errdefer allocator.destroy(handle);
            handle.* = try core.x11Window.X11Window.open(request);
            return .{ .x11 = handle };
        },
    }
}
