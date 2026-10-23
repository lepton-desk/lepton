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
const layer = @import("lepton_window").window;
const native = layer.win32;
const c = @import("c_d3d11");

const iid_dxgi_device: c.GUID = .{ .Data1 = 0x54ec77fa, .Data2 = 0x1377, .Data3 = 0x44e6, .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_dxgi_factory2: c.GUID = .{ .Data1 = 0x50c83a1c, .Data2 = 0xe072, .Data3 = 0x4c48, .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const iid_texture2d: c.GUID = .{ .Data1 = 0x6f15aaf2, .Data2 = 0xd208, .Data3 = 0x4e89, .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/// From the highest down to 10_0, the floor that keeps Vista in reach (`docs/plans/windows.md`).
const levels = [_]c.D3D_FEATURE_LEVEL{ c.D3D_FEATURE_LEVEL_11_1, c.D3D_FEATURE_LEVEL_11_0, c.D3D_FEATURE_LEVEL_10_1, c.D3D_FEATURE_LEVEL_10_0 };

var failed = false;

fn expect(ok: bool, comptime label: []const u8, comptime format: []const u8, args: anytype) void {
    if (!ok) failed = true;
    std.debug.print("{s} {s:<14} " ++ format ++ "\n", .{ if (ok) "ok  " else "FAIL", label } ++ args);
}

fn fact(comptime label: []const u8, comptime format: []const u8, args: anytype) void {
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

/// The colour on screen at a client point, `0xRRGGBB`.
fn screenAt(hwnd: c.HWND, x: i32, y: i32) u32 {
    var point: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &point);
    const dc = c.GetDC(null) orelse return 0xFFFF_FFFF;
    defer _ = c.ReleaseDC(null, dc);
    const colour: u32 = c.GetPixel(dc, point.x, point.y);
    return ((colour & 0xFF) << 16) | (colour & 0xFF00) | ((colour >> 16) & 0xFF);
}

fn ticks() i64 {
    var now: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&now);
    return now.QuadPart;
}

pub fn main() !void {
    var w: native.NativeWindow = undefined;
    try w.open(.{ .title = "lepton windows gpu check", .size = .{ .width = 480, .height = 320 } });
    defer w.close();
    _ = c.SetForegroundWindow(@ptrCast(w.hwnd));
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
    var mode: c.DEVMODEW = std.mem.zeroes(c.DEVMODEW);
    mode.dmSize = @sizeOf(c.DEVMODEW);
    const refresh: i64 = if (c.EnumDisplaySettingsW(null, c.ENUM_CURRENT_SETTINGS, &mode) != 0) mode.dmDisplayFrequency else 0;
    expect(refresh == 0 or @abs(per_second - refresh) <= 3, "vsync", "{d} presents in {d} ms = {d}/s, display {d} Hz", .{ frames, elapsed_ms, per_second, refresh });

    const warp = createDevice(c.D3D_DRIVER_TYPE_WARP);
    if (warp) |software| {
        fact("warp", "feature level {s}", .{levelName(software.level)});
        release(software.context);
        release(software.device);
    } else expect(false, "warp", "no WARP device", .{});

    if (failed) std.process.exit(1);
    std.debug.print("all checks passed\n", .{});
}
