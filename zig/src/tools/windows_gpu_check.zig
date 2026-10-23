//! The Windows GPU path's first measurement: can this machine's Direct3D 11 draw into the
//! native path's window, at what feature level, how fast, and does what it drew reach the
//! screen? Also whether WARP (Direct3D's software rasteriser, the CPU fallback candidate)
//! comes up. Each fact is printed; a mismatch exits 1.
//!
//! The swap chain is the flip model (`FLIP_DISCARD`, Windows 10): DWM composes the buffer
//! itself, no copy through GDI. The screen is read with `GetPixel`, so a buffer that never
//! reached the window shows as the wrong colour.
//!
//! Run with `zig build windows-gpu-check` (Windows only).

const std = @import("std");
const core = @import("lepton_window");
const layer = core.window;
const native = layer.win32;
const d3d11 = core.d3d11;
const scene = core.scene;
const atlas = core.atlas;
const glyph_text = core.glyph_text;
const rate = @import("windows_gpu_rate.zig");
const c = @import("c_windows");

const iid_dxgi_device: c.GUID = .{ .Data1 = 0x54ec77fa, .Data2 = 0x1377, .Data3 = 0x44e6, .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_dxgi_factory2: c.GUID = .{ .Data1 = 0x50c83a1c, .Data2 = 0xe072, .Data3 = 0x4c48, .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const iid_texture2d: c.GUID = .{ .Data1 = 0x6f15aaf2, .Data2 = 0xd208, .Data3 = 0x4e89, .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/// From the highest down to 10_0, the floor that keeps Vista in reach (`docs/plans/windows.md`).
const levels = [_]c.D3D_FEATURE_LEVEL{ c.D3D_FEATURE_LEVEL_11_1, c.D3D_FEATURE_LEVEL_11_0, c.D3D_FEATURE_LEVEL_10_1, c.D3D_FEATURE_LEVEL_10_0 };

var failed = false;

pub fn expect(ok: bool, comptime label: []const u8, comptime format: []const u8, args: anytype) void {
    if (!ok) failed = true;
    std.debug.print("{s} {s:<14} " ++ format ++ "\n", .{ if (ok) "ok  " else "FAIL", label } ++ args);
}

pub fn fact(comptime label: []const u8, comptime format: []const u8, args: anytype) void {
    std.debug.print("     {s:<14} " ++ format ++ "\n", .{label} ++ args);
}

fn release(object: anytype) void {
    const pointer = switch (@typeInfo(@TypeOf(object))) {
        .optional => object orelse return,
        else => object,
    };
    _ = pointer.lpVtbl.*.Release.?(pointer);
}

const Device = struct { device: *c.ID3D11Device, context: *c.ID3D11DeviceContext, level: c.D3D_FEATURE_LEVEL };

/// A device of `driver`, at the highest level the runtime and the driver allow. A runtime
/// without Direct3D 11.1 refuses a list naming 11_1 (`E_INVALIDARG`), so it is asked again
/// without it.
fn createDevice(driver: c.D3D_DRIVER_TYPE) ?Device {
    var device: ?*c.ID3D11Device = null;
    var context: ?*c.ID3D11DeviceContext = null;
    var level: c.D3D_FEATURE_LEVEL = 0;
    const flags: c.UINT = c.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    var hr = c.D3D11CreateDevice(null, driver, null, flags, &levels, levels.len, c.D3D11_SDK_VERSION, &device, &level, &context);
    if (hr == c.E_INVALIDARG) hr = c.D3D11CreateDevice(null, driver, null, flags, levels[1..].ptr, levels.len - 1, c.D3D11_SDK_VERSION, &device, &level, &context);
    if (hr < 0) {
        fact("device", "refused: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return null;
    }
    return .{ .device = device.?, .context = context.?, .level = level };
}

fn levelName(level: c.D3D_FEATURE_LEVEL) []const u8 {
    return switch (level) {
        c.D3D_FEATURE_LEVEL_11_1 => "11_1",
        c.D3D_FEATURE_LEVEL_11_0 => "11_0",
        c.D3D_FEATURE_LEVEL_10_1 => "10_1",
        c.D3D_FEATURE_LEVEL_10_0 => "10_0",
        else => "other",
    };
}

/// The colour on screen at a client point, `0xRRGGBB`. When another window is over the
/// point (`WindowFromPoint`), this one is brought to the front and read again once; still
/// covered, the colour is `covered_point`, and the check fails saying so rather than reporting
/// another window's pixel as this one's (a run once read #2073ab for #2180bf, and two
/// reruns read #2180bf).
pub fn screenAt(hwnd: c.HWND, x: i32, y: i32) u32 {
    var point: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &point);
    if (c.WindowFromPoint(point) != hwnd) {
        rate.onTop(hwnd);
        c.Sleep(300);
        if (c.WindowFromPoint(point) != hwnd) return covered_point;
    }
    const dc = c.GetDC(null) orelse return 0xFFFF_FFFF;
    defer _ = c.ReleaseDC(null, dc);
    const colour: u32 = c.GetPixel(dc, point.x, point.y);
    return ((colour & 0xFF) << 16) | (colour & 0xFF00) | ((colour >> 16) & 0xFF);
}

/// The screen under a client rectangle, `0xRRGGBB` row by row, read with one `BitBlt`. The
/// text check once read its 11 200 points with `screenAt`, which brings the window forward
/// and sleeps 300 ms for each covered point: with the window behind another, it hung for
/// most of an hour, and Windows swapped in its "Not Responding" ghost, which covered the
/// rest (measured, every point `covered_point`). Here the window is brought forward once;
/// points still covered are `covered_point`.
fn screenRegion(hwnd: c.HWND, comptime w: usize, comptime h: usize, out: *[h][w]u32) !void {
    var origin: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.ClientToScreen(hwnd, &origin);
    var corner: c.POINT = .{ .x = origin.x + @as(i32, w) - 1, .y = origin.y + @as(i32, h) - 1 };
    if (c.WindowFromPoint(origin) != hwnd or c.WindowFromPoint(corner) != hwnd) {
        rate.onTop(hwnd);
        c.Sleep(300);
    }
    const screen = c.GetDC(null) orelse return error.NoScreen;
    defer _ = c.ReleaseDC(null, screen);
    const memory = c.CreateCompatibleDC(screen) orelse return error.NoScreen;
    defer _ = c.DeleteDC(memory);
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = @intCast(w);
    info.bmiHeader.biHeight = -@as(i32, @intCast(h));
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = c.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(memory, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return error.NoScreen;
    defer _ = c.DeleteObject(bitmap);
    const previous = c.SelectObject(memory, bitmap);
    defer _ = c.SelectObject(memory, previous);
    if (c.BitBlt(memory, 0, 0, @intCast(w), @intCast(h), screen, origin.x, origin.y, c.SRCCOPY) == 0) return error.NoScreen;
    const pixels: [*]const u32 = @ptrCast(@alignCast(bits.?));
    for (0..h) |y| for (0..w) |x| {
        corner = .{ .x = origin.x + @as(i32, @intCast(x)), .y = origin.y + @as(i32, @intCast(y)) };
        // A DIB pixel is 0x00RRGGBB already (blue in the low byte).
        out[y][x] = if (c.WindowFromPoint(corner) != hwnd) covered_point else pixels[y * w + x] & 0xFF_FFFF;
    };
}

/// What `screenAt` answers for a point another window covers: no 24-bit colour is this.
const covered_point: u32 = 0xC0FFEE00;

pub fn ticks() i64 {
    var now: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&now);
    return now.QuadPart;
}

pub fn main() !void {
    try rawSwapChain();
    try sceneOnWindow();
    try uncapped();
    try swapModels();
    try @import("windows_gl_check.zig").run();
    try @import("windows_vulkan_check.zig").run();
    if (failed) std.process.exit(1);
    std.debug.print("all checks passed\n", .{});
}

/// The renderer (`render/gpu/d3d11.zig`) on a window of its own: the shapes the GLES 3
/// tests assert on, read back from the screen; frames paced by the swap chain; a resize.
fn sceneOnWindow() !void {
    const allocator = std.heap.page_allocator;
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton d3d11 scene check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    var size = (w.takeConfigure() orelse return error.NoConfigure).size;
    const hwnd: c.HWND = @ptrCast(w.hwnd);

    var renderer = d3d11.Renderer.open(w.hwnd, size.width, size.height, .display) catch |err| {
        expect(false, "renderer", "{t}", .{err});
        return;
    };
    defer renderer.deinit();
    w.setFrameWait(renderer.frameWait());
    w.setPresentPaces(renderer.pacesItself());
    expect(renderer.frameWait() != null, "renderer", "level {s}, frame-latency object {s}", .{ levelName(renderer.level), if (renderer.frameWait() != null) "yes" else "no" });

    var glyphs = try atlas.Atlas.init(allocator);
    defer glyphs.deinit(allocator);
    // A 4×4 coverage block: left half full, right half none (the GLES 3 test's).
    var bitmap: [16]u8 = undefined;
    for (0..4) |at| @memcpy(bitmap[at * 4 ..][0..4], &[_]u8{ 255, 255, 0, 0 });
    const slot = (try glyphs.put(allocator, .{ .font = 0, .glyph = 1, .size = 4 }, 4, 4, 4, &bitmap, 0, 4)).?;

    var list: scene.List = .{};
    defer list.deinit(allocator);
    try list.rect(allocator, .{ .x = 20, .y = 20, .width = 120, .height = 80 }, .{ .fill = scene.rgba(0xc03020ff), .radius = 24 });
    try list.rect(allocator, .{ .x = 160, .y = 20, .width = 80, .height = 80 }, .{ .fill = scene.rgba(0xff000080) });
    try list.glyph(allocator, .{ .x = 260, .y = 20, .width = 64, .height = 64 }, slot.uv(), scene.rgba(0xff0000ff));
    const clear = scene.rgba(0x0000ffff);

    for (0..30) |_| {
        try renderer.draw(&list, &glyphs, clear, .{ .width = size.width, .height = size.height });
        try w.wait(16);
    }
    const near = struct {
        fn f(got: u32, want: u32) bool {
            inline for (.{ 16, 8, 0 }) |shift| {
                const a: i32 = @intCast((got >> shift) & 0xff);
                const b: i32 = @intCast((want >> shift) & 0xff);
                if (@abs(a - b) > 3) return false;
            }
            return true;
        }
    }.f;
    const inside = screenAt(hwnd, 80, 60);
    expect(near(inside, 0xc03020), "rect", "#{x:0>6} inside, drawn #c03020", .{inside});
    const corner = screenAt(hwnd, 22, 22);
    expect(near(corner, 0x0000ff), "rounded corner", "#{x:0>6} outside the radius, clear #0000ff", .{corner});
    const blended = screenAt(hwnd, 200, 60);
    expect(near(blended, 0x80007f), "blend", "#{x:0>6}, half red over blue #80007f", .{blended});
    const covered = screenAt(hwnd, 270, 50);
    const uncovered = screenAt(hwnd, 314, 50);
    expect(near(covered, 0xff0000) and near(uncovered, 0x0000ff), "glyph", "#{x:0>6} | #{x:0>6}, atlas coverage left half", .{ covered, uncovered });
    expect(glyphs.takeDirty() == null, "atlas", "sent once ({d} bytes uploaded in all)", .{renderer.uploaded});

    // Frames paced by the swap chain: as many a second as the display refreshes.
    var frequency: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceFrequency(&frequency);
    const frames = 120;
    const started = ticks();
    for (0..frames) |_| {
        try renderer.draw(&list, &glyphs, clear, .{ .width = size.width, .height = size.height });
        try w.wait(16);
    }
    const elapsed_ms = @divTrunc((ticks() - started) * 1000, frequency.QuadPart);
    const per_second = @divTrunc(@as(i64, frames) * 1000, @max(elapsed_ms, 1));
    const refresh = displayHz();
    expect(if (refresh == 0) per_second >= 57 and per_second <= 63 else @abs(per_second - refresh) <= 3, "paced", "{d} frames in {d} ms = {d}/s, display {d} Hz", .{ frames, elapsed_ms, per_second, refresh });

    // Text (`render/glyph_text_windows.zig`), as the GLES 3 test draws it: ink between the
    // pen's start and its advance, above the baseline down to the descender; none outside.
    var font = try glyph_text.Font.open(allocator, "sans", 20, 0);
    defer font.deinit();
    var words: scene.List = .{};
    defer words.deinit(allocator);
    const advance = try font.draw(allocator, &glyphs, &words, "Lepton", 6, 40, scene.rgba(0x000000ff));
    expect(words.instances.items.len == 6 and advance > 40 and advance < 90, "text laid out", "{d} glyphs, advance {d:.0} px", .{ words.instances.items.len, advance });
    const before = renderer.uploaded;
    for (0..10) |_| {
        try renderer.draw(&words, &glyphs, scene.rgba(0xffffffff), .{ .width = size.width, .height = size.height });
        try w.wait(16);
    }
    var ink: usize = 0;
    var stray: usize = 0;
    var region: [70][160]u32 = undefined;
    try screenRegion(hwnd, 160, 70, &region);
    for (0..70) |y| for (0..160) |x| {
        const shown = region[y][x];
        const dark = shown != covered_point and (shown >> 16) < 128;
        const in_box = x >= 6 and x <= 6 + @as(usize, @intFromFloat(advance)) and y >= 40 - 20 and y <= 40 + 6;
        if (dark and in_box) ink += 1;
        if (dark and !in_box) stray += 1;
    };
    expect(ink > 80 and stray == 0, "text on screen", "{d} dark pixels in its box, {d} outside", .{ ink, stray });
    words.clear();
    _ = try font.draw(allocator, &glyphs, &words, "Lepton", 6, 40, scene.rgba(0x000000ff));
    const sent = renderer.uploaded;
    try renderer.draw(&words, &glyphs, scene.rgba(0xffffffff), .{ .width = size.width, .height = size.height });
    expect(renderer.uploaded - sent == words.bytes().len, "glyphs once", "second frame sent {d} bytes (its instances), first {d}", .{ renderer.uploaded - sent, sent - before });

    // A resize: the swap chain follows, the new corner is drawn.
    try w.resize(.{ .width = size.width + 100, .height = size.height + 60 });
    for (0..10) |_| try w.wait(16);
    if (w.takeConfigure()) |configure| size = configure.size;
    for (0..10) |_| {
        try renderer.draw(&list, &glyphs, clear, .{ .width = size.width, .height = size.height });
        try w.wait(16);
    }
    const far = screenAt(hwnd, @intCast(size.width - 4), @intCast(size.height - 4));
    expect(renderer.width == size.width and near(far, 0x0000ff), "resize", "{d}x{d}, far corner #{x:0>6}", .{ renderer.width, renderer.height, far });
}

fn rawSwapChain() !void {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton windows gpu check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    rate.onTop(@ptrCast(w.hwnd));
    const size = (w.takeConfigure() orelse return error.NoConfigure).size;
    const hwnd: c.HWND = @ptrCast(w.hwnd);

    const gpu = createDevice(c.D3D_DRIVER_TYPE_HARDWARE) orelse {
        expect(false, "hardware", "no Direct3D 11 device", .{});
        std.process.exit(1);
    };
    defer release(gpu.device);
    defer release(gpu.context);
    expect(gpu.level >= c.D3D_FEATURE_LEVEL_10_0, "hardware", "feature level {s}", .{levelName(gpu.level)});

    // The adapter, through the device's DXGI side: its name, and the factory that makes
    // the swap chain on the same adapter.
    var dxgi_device: ?*c.IDXGIDevice = null;
    if (gpu.device.lpVtbl.*.QueryInterface.?(gpu.device, &iid_dxgi_device, @ptrCast(&dxgi_device)) < 0) return error.NoDxgiDevice;
    defer release(dxgi_device);
    var adapter: ?*c.IDXGIAdapter = null;
    if (dxgi_device.?.lpVtbl.*.GetAdapter.?(dxgi_device.?, &adapter) < 0) return error.NoAdapter;
    defer release(adapter);
    var description: c.DXGI_ADAPTER_DESC = undefined;
    if (adapter.?.lpVtbl.*.GetDesc.?(adapter.?, &description) >= 0) {
        var name: [256]u8 = undefined;
        const units = std.mem.sliceTo(&description.Description, 0);
        const length = std.unicode.utf16LeToUtf8(&name, units) catch 0;
        fact("adapter", "{s}, {d} MiB video memory", .{ name[0..length], description.DedicatedVideoMemory / (1024 * 1024) });
    }
    var factory: ?*c.IDXGIFactory2 = null;
    if (adapter.?.lpVtbl.*.GetParent.?(adapter.?, &iid_dxgi_factory2, @ptrCast(&factory)) < 0) {
        expect(false, "swap chain", "no IDXGIFactory2 (DXGI 1.2, Windows 8+)", .{});
        std.process.exit(1);
    }
    defer release(factory);

    const chain_description: c.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = size.width,
        .Height = size.height,
        .Format = c.DXGI_FORMAT_B8G8R8A8_UNORM,
        .Stereo = c.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = c.DXGI_SCALING_STRETCH,
        .SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = c.DXGI_ALPHA_MODE_UNSPECIFIED,
        .Flags = 0,
    };
    var chain: ?*c.IDXGISwapChain1 = null;
    const made = factory.?.lpVtbl.*.CreateSwapChainForHwnd.?(factory.?, @ptrCast(gpu.device), hwnd, &chain_description, null, null, &chain);
    expect(made >= 0, "swap chain", "flip-discard, 2 buffers, {d}x{d} (hr 0x{X:0>8})", .{ size.width, size.height, @as(u32, @bitCast(made)) });
    if (made < 0) std.process.exit(1);
    defer release(chain);

    var buffer: ?*c.ID3D11Texture2D = null;
    if (chain.?.lpVtbl.*.GetBuffer.?(chain.?, 0, &iid_texture2d, @ptrCast(&buffer)) < 0) return error.NoBuffer;
    var target: ?*c.ID3D11RenderTargetView = null;
    const viewed = gpu.device.lpVtbl.*.CreateRenderTargetView.?(gpu.device, @ptrCast(buffer), null, &target);
    release(buffer);
    if (viewed < 0) return error.NoRenderTarget;
    defer release(target);

    // Two colours a frame apart; the screen must show the second.
    const colours = [_][4]f32{ .{ 0.80, 0.20, 0.10, 1 }, .{ 0.13, 0.50, 0.75, 1 } };
    const wanted: u32 = 0x2180BF; // 0.13, 0.50, 0.75 rounded to bytes
    for (colours) |colour| {
        gpu.context.lpVtbl.*.ClearRenderTargetView.?(gpu.context, target, &colour);
        if (chain.?.lpVtbl.*.Present.?(chain.?, 1, 0) < 0) return error.PresentFailed;
        try w.wait(16);
    }
    for (0..20) |_| try w.wait(16);
    const shown = screenAt(hwnd, @intCast(size.width / 2), @intCast(size.height / 2));
    const close_enough = @abs(@as(i32, @intCast(shown >> 16)) - 0x21) <= 2 and @abs(@as(i32, @intCast((shown >> 8) & 0xFF)) - 0x80) <= 2 and @abs(@as(i32, @intCast(shown & 0xFF)) - 0xBF) <= 2;
    expect(close_enough, "on screen", "#{x:0>6}, cleared #{x:0>6}", .{ shown, wanted });

    // Presents with vsync: as many a second as the display refreshes.
    var frequency: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceFrequency(&frequency);
    const frames = 120;
    const started = ticks();
    for (0..frames) |index| {
        const shade: f32 = @as(f32, @floatFromInt(index % 60)) / 60.0;
        const colour = [4]f32{ shade, 0.2, 0.3, 1 };
        gpu.context.lpVtbl.*.ClearRenderTargetView.?(gpu.context, target, &colour);
        if (chain.?.lpVtbl.*.Present.?(chain.?, 1, 0) < 0) return error.PresentFailed;
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) _ = c.DispatchMessageW(&message);
    }
    const elapsed_ms = @divTrunc((ticks() - started) * 1000, frequency.QuadPart);
    const per_second = @divTrunc(@as(i64, frames) * 1000, @max(elapsed_ms, 1));
    const refresh = displayHz();
    expect(refresh == 0 or @abs(per_second - refresh) <= 3, "vsync", "{d} presents in {d} ms = {d}/s, display {d} Hz", .{ frames, elapsed_ms, per_second, refresh });

    const warp = createDevice(c.D3D_DRIVER_TYPE_WARP);
    if (warp) |software| {
        fact("warp", "feature level {s}", .{levelName(software.level)});
        release(software.context);
        release(software.device);
    } else expect(false, "warp", "no WARP device", .{});
}

/// The display's refresh rate, Hz; 0 when Windows does not say.
pub fn displayHz() i64 {
    var mode: c.DEVMODEW = std.mem.zeroes(c.DEVMODEW);
    mode.dmSize = @sizeOf(c.DEVMODEW);
    return if (c.EnumDisplaySettingsW(null, c.ENUM_CURRENT_SETTINGS, &mode) != 0) mode.dmDisplayFrequency else 0;
}

/// Linux's 2001-shape scene, paced by the display and unlimited (`windows_gpu_rate.zig`).
fn uncapped() !void {
    const allocator = std.heap.page_allocator;
    const paced = rate.measure(allocator, .display) catch |err| {
        expect(false, "scene paced", "{t}", .{err});
        return;
    };
    // No GPU time for the paced frames: their timeline holds the wait for a back buffer the
    // display still shows (15.5 ms a frame, measured), not drawing. The drawing costs what
    // the unlimited frames say.
    fact("scene paced", "2001 shapes, {d}/s, CPU {d} us/frame", .{ paced.per_second, paced.cpu_us });
    const free = rate.measure(allocator, .unlimited) catch |err| {
        expect(false, "unlimited", "{t}", .{err});
        return;
    };
    expect(free.per_second > paced.per_second, "unlimited", "2001 shapes, {d}/s, CPU {d} us/frame, GPU {d} us/frame, tearing {s}", .{ free.per_second, free.cpu_us, free.gpu_us, if (free.tearing) "yes" else "no" });
}

/// Each swap model the renderer falls back through (`d3d11.Swap`), forced in turn: the
/// older systems' paths (Windows 8's flip-sequential, Windows 7's blt model) measured on
/// this one — accepted, drawn on the screen, and paced at the display's refresh.
fn swapModels() !void {
    const allocator = std.heap.page_allocator;
    const refresh = displayHz();
    var frequency: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceFrequency(&frequency);
    for (std.enums.values(d3d11.Swap)) |model| {
        var w: native.NativeWindow = undefined;
        try w.open(.{ .title = "lepton d3d11 swap model", .size = .{ .width = 320, .height = 240 } });
        defer w.close();
        rate.onTop(@ptrCast(w.hwnd));
        const size = (w.takeConfigure() orelse return error.NoConfigure).size;
        var renderer = d3d11.Renderer.openWith(w.hwnd, size.width, size.height, .display, model) catch |err| {
            expect(false, "swap model", "{t}: {t}", .{ model, err });
            continue;
        };
        defer renderer.deinit();
        w.setFrameWait(renderer.frameWait());
        w.setPresentPaces(renderer.pacesItself());
        var glyphs = try atlas.Atlas.init(allocator);
        defer glyphs.deinit(allocator);
        var list: scene.List = .{};
        defer list.deinit(allocator);
        try list.rect(allocator, .{ .x = 0, .y = 0, .width = 320, .height = 240 }, .{ .fill = scene.rgba(0x3090c0ff) });
        const at: d3d11.Renderer.Size = .{ .width = size.width, .height = size.height };
        for (0..20) |_| {
            try renderer.draw(&list, &glyphs, scene.rgba(0x000000ff), at);
            try w.wait(16);
        }
        const frames = 120;
        const started = ticks();
        for (0..frames) |_| {
            try renderer.draw(&list, &glyphs, scene.rgba(0x000000ff), at);
            try w.wait(16);
        }
        const per_second = @divTrunc(@as(i64, frames) * frequency.QuadPart, @max(ticks() - started, 1));
        const shown = screenAt(@ptrCast(w.hwnd), @intCast(size.width / 2), @intCast(size.height / 2));
        // Paced, not unlimited: no faster than the refresh (6 % over, rounded up, 3 frames at
        // least), and not far under it. The CI runner draws on the CPU (Basic Render Driver,
        // a nominal 64 Hz) and paced these at 58 to 65 a second, slowest right after the
        // unlimited scene had it busy (measured over three runs); a real GPU here, 59 at 60 Hz.
        const over = @max(3, @divTrunc(refresh * 6 + 99, 100));
        const paced = refresh == 0 or (per_second <= refresh + over and per_second * 100 >= refresh * 85);
        expect(renderer.swap == model and shown == 0x3090c0 and paced, "swap model", "{t}: made {t}, #{x:0>6} on screen, {d}/s, frame-latency object {s}", .{ model, renderer.swap, shown, per_second, if (renderer.frameWait() != null) "yes" else "no" });
    }
}
