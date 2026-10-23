//! How fast the Direct3D 11 renderer draws when nothing holds it back, beside the paced
//! rate: Linux's `scene-check` scene (1200×800, 1000 cards = a shadow and a bordered card
//! each, 2001 shapes with the top bar), drawn into the native window with `display` and
//! with `unlimited` pacing. For each: frames a second, the process's CPU time a frame, and
//! the GPU's own time for one frame (timestamp queries around `record`, the present left
//! out, waited for, so it is measured on frames apart from the counted ones; meaningful
//! unlimited only — paced, the timeline also holds the wait for a free back buffer).
//!
//! Part of `zig build windows-gpu-check`; facts, not limits — only a renderer that will
//! not open, or an unlimited rate below the paced one, is a failure.

const std = @import("std");
const core = @import("lepton_window");
const native = core.window.win32;
const d3d11 = core.d3d11;
const scene = core.scene;
const atlas = core.atlas;
const c = @import("c_windows");

const width = 1200;
const height = 800;
const count = 1000;
const warm = 30;
const counted = 300;
const timed = 100;

pub const Result = struct { per_second: i64, cpu_us: i64, gpu_us: i64, tearing: bool };

fn ticks() i64 {
    var now: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&now);
    return now.QuadPart;
}

pub fn frequency() i64 {
    var value: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceFrequency(&value);
    return value.QuadPart;
}

/// The process's user and kernel time, microseconds.
pub fn processorUs() i64 {
    var created: c.FILETIME = undefined;
    var exited: c.FILETIME = undefined;
    var kernel: c.FILETIME = undefined;
    var user: c.FILETIME = undefined;
    if (c.GetProcessTimes(c.GetCurrentProcess(), &created, &exited, &kernel, &user) == 0) return 0;
    const k = (@as(i64, kernel.dwHighDateTime) << 32) | kernel.dwLowDateTime;
    const u = (@as(i64, user.dwHighDateTime) << 32) | user.dwLowDateTime;
    return @divTrunc(k + u, 10);
}

/// The scene `tools/scene_check.zig` draws, moved a pixel a frame so no frame repeats.
pub fn cards(list: *scene.List, allocator: std.mem.Allocator, frame: usize) !void {
    list.clear();
    try list.rect(allocator, .{ .x = 0, .y = 0, .width = width, .height = 48 }, .{ .fill = scene.rgba(0x2b2d42ff) });
    const columns = 40;
    const cell_w: f32 = @as(f32, width) / columns;
    const rows = (count + columns - 1) / columns;
    const cell_h: f32 = (@as(f32, height) - 56) / @as(f32, @floatFromInt(rows));
    const drift: f32 = @floatFromInt(frame % 4);
    for (0..count) |index| {
        const col: f32 = @floatFromInt(index % columns);
        const row: f32 = @floatFromInt(index / columns);
        const at: scene.Rect = .{ .x = col * cell_w + 3 + drift, .y = 56 + row * cell_h + 3, .width = cell_w - 6, .height = cell_h - 6 };
        try list.shadow(allocator, .{ .x = at.x, .y = at.y + 2, .width = at.width, .height = at.height }, 4, 4, scene.rgba(0x00000040));
        try list.rect(allocator, at, .{
            .fill = if (index % 7 == 0) scene.rgba(0x8d99aeff) else scene.rgba(0xffffffff),
            .radius = 4,
            .border = 1,
            .border_colour = scene.rgba(0xd0d4dcff),
        });
    }
}

/// One pacing's figures, on a window of its own.
pub fn measure(allocator: std.mem.Allocator, pacing: d3d11.Pacing) !Result {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton d3d11 rate", .size = .{ .width = width, .height = height }, .pacing = pacing });
    defer w.close();
    onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;

    var renderer = try d3d11.Renderer.open(w.hwnd, size.width, size.height, pacing);
    defer renderer.deinit();
    w.setFrameWait(renderer.frameWait());
    w.setPresentPaces(renderer.pacesItself());

    var glyphs = try atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    var list: scene.List = .{};
    defer list.deinit(allocator);
    const clear = scene.rgba(0xedf0f4ff);
    const at: d3d11.Renderer.Size = .{ .width = size.width, .height = size.height };

    for (0..warm) |frame| {
        try cards(&list, allocator, frame);
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const started = ticks();
    const cpu_started = processorUs();
    for (0..counted) |frame| {
        try cards(&list, allocator, frame);
        try renderer.draw(&list, &glyphs, clear, at);
        try w.wait(16);
    }
    const elapsed = ticks() - started;
    const cpu = processorUs() - cpu_started;

    return .{
        .per_second = @divTrunc(@as(i64, counted) * frequency(), @max(elapsed, 1)),
        .cpu_us = @divTrunc(cpu, counted),
        .gpu_us = try gpuTime(&renderer, &list, &glyphs, clear, at, allocator, &w),
        .tearing = renderer.tearing,
    };
}

/// The median GPU time of `timed` frames, from two timestamps around each `record` (not the present, whose wait for the display
/// would be counted as drawing: 15.4 ms a frame paced, measured) inside a
/// disjoint query (which gives the clock's rate and says whether it held steady).
fn gpuTime(renderer: *d3d11.Renderer, list: *scene.List, glyphs: *atlas.Atlas, clear: [4]f32, at: d3d11.Renderer.Size, allocator: std.mem.Allocator, w: *native.NativeWindow) !i64 {
    const device = renderer.device;
    const context = renderer.context;
    var disjoint: ?*c.ID3D11Query = null;
    var begin: ?*c.ID3D11Query = null;
    var end: ?*c.ID3D11Query = null;
    var description: c.D3D11_QUERY_DESC = .{ .Query = c.D3D11_QUERY_TIMESTAMP_DISJOINT, .MiscFlags = 0 };
    if (device.lpVtbl.*.CreateQuery.?(device, &description, &disjoint) < 0) return error.NoQuery;
    defer _ = disjoint.?.lpVtbl.*.Release.?(disjoint.?);
    description.Query = c.D3D11_QUERY_TIMESTAMP;
    if (device.lpVtbl.*.CreateQuery.?(device, &description, &begin) < 0) return error.NoQuery;
    defer _ = begin.?.lpVtbl.*.Release.?(begin.?);
    if (device.lpVtbl.*.CreateQuery.?(device, &description, &end) < 0) return error.NoQuery;
    defer _ = end.?.lpVtbl.*.Release.?(end.?);

    var samples: [timed]i64 = undefined;
    var kept: usize = 0;
    for (0..timed) |frame| {
        try cards(list, allocator, frame);
        context.lpVtbl.*.Begin.?(context, @ptrCast(disjoint));
        context.lpVtbl.*.End.?(context, @ptrCast(begin));
        try renderer.record(list, glyphs, clear, at);
        context.lpVtbl.*.End.?(context, @ptrCast(end));
        context.lpVtbl.*.End.?(context, @ptrCast(disjoint));
        try renderer.present();
        var clock: c.D3D11_QUERY_DATA_TIMESTAMP_DISJOINT = undefined;
        while (context.lpVtbl.*.GetData.?(context, @ptrCast(disjoint), &clock, @sizeOf(@TypeOf(clock)), 0) == c.S_FALSE) {}
        var first: u64 = 0;
        var last: u64 = 0;
        while (context.lpVtbl.*.GetData.?(context, @ptrCast(begin), &first, @sizeOf(u64), 0) == c.S_FALSE) {}
        while (context.lpVtbl.*.GetData.?(context, @ptrCast(end), &last, @sizeOf(u64), 0) == c.S_FALSE) {}
        try w.wait(16);
        if (clock.Disjoint != c.FALSE or clock.Frequency == 0 or last < first) continue;
        samples[kept] = @intCast(@divTrunc((last - first) * 1_000_000, clock.Frequency));
        kept += 1;
    }
    if (kept == 0) return error.NoTimestamps;
    std.mem.sort(i64, samples[0..kept], {}, std.sort.asc(i64));
    return samples[kept / 2];
}

/// Puts a check's window above every other, so the screen it reads is its own. Not
/// `SetForegroundWindow`, which Windows refuses to a process that is not in front: run from
/// a terminal behind another app, every point read was that app's window (measured, the
/// Claude desktop app's "Chrome Legacy Window"). A topmost window needs no such right.
/// `HWND_TOPMOST` is `(HWND)-1`, an address no `HWND` may hold in Zig (it must be aligned), so
/// the call is declared here with the insert-after handle as the integer it is.
const topmost: usize = std.math.maxInt(usize);
extern "user32" fn SetWindowPos(window: c.HWND, insert_after: usize, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: c.UINT) callconv(.winapi) c.BOOL;

pub fn onTop(hwnd: c.HWND) void {
    _ = SetWindowPos(hwnd, topmost, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
}
