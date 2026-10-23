//! The draw command list (`render/scene.zig`) on Direct3D 11: the Windows GPU path, below
//! Vulkan (`docs/plans/windows.md`). The same 64-byte instances the GLES 3 backend reads
//! (`render/gles3.zig`), the same shapes (`d3d11/scene.hlsl`), one instanced draw a frame,
//! straight into a flip-model swap chain on the window: nothing is painted on the CPU and
//! no frame-sized buffer crosses to the GPU.
//!
//! Frames are paced by the swap chain itself: it is made with a frame-latency waitable
//! object (DXGI 1.3, Windows 8.1+), signalled when the next frame may be drawn — at the
//! display's refresh. `frameWait` hands it to the window, whose `wait` sleeps on it with
//! messages still handled. With `unlimited` pacing (`window.Pacing`) presents carry no sync
//! interval and tear where DXGI allows it; the object then signals when the GPU has room.

const std = @import("std");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");

const c = @import("c_windows");

pub const Error = error{ NoDevice, NoFactory, NoSwapChain, NoShader, NoBuffer, NoTexture, NoState, DeviceLost };

const vs_bytes = @embedFile("d3d11/scene_vs.dxbc");
const ps_bytes = @embedFile("d3d11/scene_ps.dxbc");

const iid_dxgi_device: c.GUID = .{ .Data1 = 0x54ec77fa, .Data2 = 0x1377, .Data3 = 0x44e6, .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_dxgi_factory2: c.GUID = .{ .Data1 = 0x50c83a1c, .Data2 = 0xe072, .Data3 = 0x4c48, .Data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const iid_swap_chain2: c.GUID = .{ .Data1 = 0xa8be2ac4, .Data2 = 0x199f, .Data3 = 0x4946, .Data4 = .{ 0xb3, 0x31, 0x79, 0x59, 0x9f, 0xb9, 0x8d, 0xe7 } };
const iid_texture2d: c.GUID = .{ .Data1 = 0x6f15aaf2, .Data2 = 0xd208, .Data3 = 0x4e89, .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

/// From the highest down to 10_0, the floor the shaders are compiled for (shader model 4.0).
const levels = [_]c.D3D_FEATURE_LEVEL{ c.D3D_FEATURE_LEVEL_11_1, c.D3D_FEATURE_LEVEL_11_0, c.D3D_FEATURE_LEVEL_10_1, c.D3D_FEATURE_LEVEL_10_0 };

const latency_flag: c.UINT = c.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
const iid_dxgi_factory5: c.GUID = .{ .Data1 = 0x7632e1f5, .Data2 = 0xee65, .Data3 = 0x4dca, .Data4 = .{ 0x87, 0xfd, 0x84, 0xcd, 0x75, 0xf8, 0x83, 0x8d } };

pub const Pacing = @import("../../window/window.zig").Pacing;

pub const Renderer = struct {
    device: *c.ID3D11Device,
    context: *c.ID3D11DeviceContext,
    chain: *c.IDXGISwapChain1,
    /// Signalled when the next frame may be drawn; null where DXGI 1.3 is missing.
    latency: c.HANDLE,
    target: ?*c.ID3D11RenderTargetView = null,
    vertex: *c.ID3D11VertexShader,
    pixel: *c.ID3D11PixelShader,
    layout: *c.ID3D11InputLayout,
    frame: *c.ID3D11Buffer,
    instances: ?*c.ID3D11Buffer = null,
    /// Bytes the instance buffer holds; it grows, never shrinks.
    capacity: usize = 0,
    blend: *c.ID3D11BlendState,
    raster: *c.ID3D11RasterizerState,
    sampler: *c.ID3D11SamplerState,
    atlas_texture: *c.ID3D11Texture2D,
    atlas_view: *c.ID3D11ShaderResourceView,
    level: c.D3D_FEATURE_LEVEL,
    pacing: Pacing,
    /// Unlimited frames on a system that lets a windowed flip-model chain tear: presents are
    /// shown the moment they are made, instead of the next composition taking the newest.
    tearing: bool,
    width: u32,
    height: u32,
    /// Bytes handed to the GPU by `draw`, all frames: the instances, and the atlas regions
    /// seen for the first time.
    uploaded: u64 = 0,

    /// A device on the default adapter and a swap chain on `window`, `width` × `height`
    /// physical pixels, paced by `pacing`. Any refusal is an error, and the caller draws on the
    /// CPU instead.
    pub fn open(window: c.HWND, width: u32, height: u32, pacing: Pacing) Error!Renderer {
        var device: ?*c.ID3D11Device = null;
        var context: ?*c.ID3D11DeviceContext = null;
        var level: c.D3D_FEATURE_LEVEL = 0;
        const flags: c.UINT = c.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        var hr = c.D3D11CreateDevice(null, c.D3D_DRIVER_TYPE_HARDWARE, null, flags, &levels, levels.len, c.D3D11_SDK_VERSION, &device, &level, &context);
        // A runtime without Direct3D 11.1 refuses a list that names 11_1.
        if (hr == c.E_INVALIDARG) hr = c.D3D11CreateDevice(null, c.D3D_DRIVER_TYPE_HARDWARE, null, flags, levels[1..].ptr, levels.len - 1, c.D3D11_SDK_VERSION, &device, &level, &context);
        if (hr < 0) return error.NoDevice;
        errdefer release(device);
        errdefer release(context);

        const tearing = pacing == .unlimited and allowsTearing(device.?);
        const chain = try swapChain(device.?, window, width, height, swapFlags(tearing));
        errdefer release(chain);
        var latency: c.HANDLE = null;
        var chain2: ?*c.IDXGISwapChain2 = null;
        if (chain.lpVtbl.*.QueryInterface.?(chain, &iid_swap_chain2, @ptrCast(&chain2)) >= 0) {
            _ = chain2.?.lpVtbl.*.SetMaximumFrameLatency.?(chain2.?, 1);
            latency = chain2.?.lpVtbl.*.GetFrameLatencyWaitableObject.?(chain2.?);
            release(chain2);
        }

        var self: Renderer = .{
            .device = device.?,
            .context = context.?,
            .chain = chain,
            .latency = latency,
            .vertex = undefined,
            .pixel = undefined,
            .layout = undefined,
            .frame = undefined,
            .blend = undefined,
            .raster = undefined,
            .sampler = undefined,
            .atlas_texture = undefined,
            .atlas_view = undefined,
            .level = level,
            .pacing = pacing,
            .tearing = tearing,
            .width = width,
            .height = height,
        };
        try self.makePipeline();
        try self.makeTarget();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        _ = self.context.lpVtbl.*.ClearState.?(self.context);
        release(self.target);
        release(self.instances);
        release(self.atlas_view);
        release(self.atlas_texture);
        release(self.sampler);
        release(self.raster);
        release(self.blend);
        release(self.frame);
        release(self.layout);
        release(self.pixel);
        release(self.vertex);
        if (self.latency) |handle| _ = c.CloseHandle(handle);
        release(self.chain);
        release(self.context);
        release(self.device);
        self.* = undefined;
    }

    /// What the window waits on between frames (`NativeWindow.frame_wait`).
    pub fn frameWait(self: *const Renderer) ?*anyopaque {
        return self.latency;
    }

    /// Draws `list` over `clear` at `size` and presents it, synchronised to the display.
    pub fn draw(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) Error!void {
        try self.record(list, glyphs, clear, size);
        try self.present();
    }

    /// `draw` up to the present: the frame's commands, queued. Apart so a measurement can
    /// time the drawing without the present's wait for the display (`tools/windows_gpu_rate.zig`).
    pub fn record(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) Error!void {
        if (size.width != self.width or size.height != self.height) try self.resize(size);
        self.syncAtlas(glyphs);

        const context = self.context;
        const constants = [4]f32{ @floatFromInt(self.width), @floatFromInt(self.height), 0, 0 };
        try self.write(@ptrCast(self.frame), std.mem.asBytes(&constants));

        const bytes = list.bytes();
        if (bytes.len > self.capacity) try self.grow(bytes.len);
        if (bytes.len > 0) try self.write(@ptrCast(self.instances.?), bytes);
        self.uploaded += bytes.len;

        const premultiplied = [4]f32{ clear[0] * clear[3], clear[1] * clear[3], clear[2] * clear[3], clear[3] };
        context.lpVtbl.*.OMSetRenderTargets.?(context, 1, &self.target, null);
        const viewport: c.D3D11_VIEWPORT = .{ .TopLeftX = 0, .TopLeftY = 0, .Width = @floatFromInt(self.width), .Height = @floatFromInt(self.height), .MinDepth = 0, .MaxDepth = 1 };
        context.lpVtbl.*.RSSetViewports.?(context, 1, &viewport);
        context.lpVtbl.*.ClearRenderTargetView.?(context, self.target, &premultiplied);
        if (bytes.len > 0) {
            const stride: c.UINT = @sizeOf(scene.Instance);
            const offset: c.UINT = 0;
            context.lpVtbl.*.IASetInputLayout.?(context, self.layout);
            context.lpVtbl.*.IASetPrimitiveTopology.?(context, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
            context.lpVtbl.*.IASetVertexBuffers.?(context, 0, 1, &self.instances, &stride, &offset);
            context.lpVtbl.*.VSSetShader.?(context, self.vertex, null, 0);
            context.lpVtbl.*.VSSetConstantBuffers.?(context, 0, 1, &self.frame);
            context.lpVtbl.*.PSSetShader.?(context, self.pixel, null, 0);
            context.lpVtbl.*.PSSetShaderResources.?(context, 0, 1, &self.atlas_view);
            context.lpVtbl.*.PSSetSamplers.?(context, 0, 1, &self.sampler);
            const factor = [4]f32{ 0, 0, 0, 0 };
            context.lpVtbl.*.OMSetBlendState.?(context, self.blend, &factor, 0xffff_ffff);
            context.lpVtbl.*.RSSetState.?(context, self.raster);
            context.lpVtbl.*.DrawInstanced.?(context, 4, @intCast(list.instances.items.len), 0, 0);
        }
    }

    /// Shows the frame `record` queued, as `pacing` says.
    pub fn present(self: *Renderer) Error!void {
        // Unlimited: no sync interval, so a present waits for no refresh; the window still waits
        // on the frame-latency object, which now signals when the GPU has room for a frame.
        const presented = switch (self.pacing) {
            .display => self.chain.lpVtbl.*.Present.?(self.chain, 1, 0),
            .unlimited => self.chain.lpVtbl.*.Present.?(self.chain, 0, if (self.tearing) c.DXGI_PRESENT_ALLOW_TEARING else 0),
        };
        if (presented == c.DXGI_ERROR_DEVICE_REMOVED or presented == c.DXGI_ERROR_DEVICE_RESET) return error.DeviceLost;
        if (presented < 0) return error.DeviceLost;
    }

    pub const Size = struct { width: u32, height: u32 };

    fn resize(self: *Renderer, size: Size) Error!void {
        if (size.width == 0 or size.height == 0) return;
        self.context.lpVtbl.*.OMSetRenderTargets.?(self.context, 0, null, null);
        release(self.target);
        self.target = null;
        if (self.chain.lpVtbl.*.ResizeBuffers.?(self.chain, 0, size.width, size.height, c.DXGI_FORMAT_UNKNOWN, swapFlags(self.tearing)) < 0) return error.NoSwapChain;
        self.width = size.width;
        self.height = size.height;
        try self.makeTarget();
    }

    fn makeTarget(self: *Renderer) Error!void {
        var back: ?*c.ID3D11Texture2D = null;
        if (self.chain.lpVtbl.*.GetBuffer.?(self.chain, 0, &iid_texture2d, @ptrCast(&back)) < 0) return error.NoSwapChain;
        defer release(back);
        if (self.device.lpVtbl.*.CreateRenderTargetView.?(self.device, @ptrCast(back), null, &self.target) < 0) return error.NoSwapChain;
    }

    fn makePipeline(self: *Renderer) Error!void {
        const device = self.device;
        var vertex: ?*c.ID3D11VertexShader = null;
        if (device.lpVtbl.*.CreateVertexShader.?(device, vs_bytes.ptr, vs_bytes.len, null, &vertex) < 0) return error.NoShader;
        self.vertex = vertex.?;
        var pixel: ?*c.ID3D11PixelShader = null;
        if (device.lpVtbl.*.CreatePixelShader.?(device, ps_bytes.ptr, ps_bytes.len, null, &pixel) < 0) return error.NoShader;
        self.pixel = pixel.?;

        // One element per 16-byte field of `scene.Instance`, all per instance.
        const elements = [_]c.D3D11_INPUT_ELEMENT_DESC{
            element("RECT", @offsetOf(scene.Instance, "rect")),
            element("FILL", @offsetOf(scene.Instance, "fill")),
            element("BORDER", @offsetOf(scene.Instance, "border_colour")),
            element("PARAMS", @offsetOf(scene.Instance, "params")),
        };
        var layout: ?*c.ID3D11InputLayout = null;
        if (device.lpVtbl.*.CreateInputLayout.?(device, &elements, elements.len, vs_bytes.ptr, vs_bytes.len, &layout) < 0) return error.NoShader;
        self.layout = layout.?;

        self.frame = try self.buffer(16, c.D3D11_BIND_CONSTANT_BUFFER);

        var blend_description = std.mem.zeroes(c.D3D11_BLEND_DESC);
        blend_description.RenderTarget[0] = .{
            .BlendEnable = c.TRUE,
            .SrcBlend = c.D3D11_BLEND_ONE,
            .DestBlend = c.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOp = c.D3D11_BLEND_OP_ADD,
            .SrcBlendAlpha = c.D3D11_BLEND_ONE,
            .DestBlendAlpha = c.D3D11_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = c.D3D11_BLEND_OP_ADD,
            .RenderTargetWriteMask = c.D3D11_COLOR_WRITE_ENABLE_ALL,
        };
        var blend: ?*c.ID3D11BlendState = null;
        if (device.lpVtbl.*.CreateBlendState.?(device, &blend_description, &blend) < 0) return error.NoState;
        self.blend = blend.?;

        var raster_description = std.mem.zeroes(c.D3D11_RASTERIZER_DESC);
        raster_description.FillMode = c.D3D11_FILL_SOLID;
        raster_description.CullMode = c.D3D11_CULL_NONE;
        raster_description.DepthClipEnable = c.TRUE;
        var raster: ?*c.ID3D11RasterizerState = null;
        if (device.lpVtbl.*.CreateRasterizerState.?(device, &raster_description, &raster) < 0) return error.NoState;
        self.raster = raster.?;

        var sampler_description = std.mem.zeroes(c.D3D11_SAMPLER_DESC);
        sampler_description.Filter = c.D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampler_description.AddressU = c.D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler_description.AddressV = c.D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler_description.AddressW = c.D3D11_TEXTURE_ADDRESS_CLAMP;
        sampler_description.MaxLOD = c.D3D11_FLOAT32_MAX;
        var sampler: ?*c.ID3D11SamplerState = null;
        if (device.lpVtbl.*.CreateSamplerState.?(device, &sampler_description, &sampler) < 0) return error.NoState;
        self.sampler = sampler.?;

        // The glyph atlas: one byte of coverage a pixel, `atlas.side` square, filled as
        // glyphs are first seen (`syncAtlas`).
        var texture_description = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
        texture_description.Width = atlas.side;
        texture_description.Height = atlas.side;
        texture_description.MipLevels = 1;
        texture_description.ArraySize = 1;
        texture_description.Format = c.DXGI_FORMAT_R8_UNORM;
        texture_description.SampleDesc = .{ .Count = 1, .Quality = 0 };
        texture_description.Usage = c.D3D11_USAGE_DEFAULT;
        texture_description.BindFlags = c.D3D11_BIND_SHADER_RESOURCE;
        var texture: ?*c.ID3D11Texture2D = null;
        if (device.lpVtbl.*.CreateTexture2D.?(device, &texture_description, null, &texture) < 0) return error.NoTexture;
        self.atlas_texture = texture.?;
        var view: ?*c.ID3D11ShaderResourceView = null;
        if (device.lpVtbl.*.CreateShaderResourceView.?(device, @ptrCast(texture), null, &view) < 0) return error.NoTexture;
        self.atlas_view = view.?;
    }

    fn buffer(self: *Renderer, bytes: usize, bind: c.UINT) Error!*c.ID3D11Buffer {
        const description: c.D3D11_BUFFER_DESC = .{
            .ByteWidth = @intCast(bytes),
            .Usage = c.D3D11_USAGE_DYNAMIC,
            .BindFlags = bind,
            .CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE,
            .MiscFlags = 0,
            .StructureByteStride = 0,
        };
        var made: ?*c.ID3D11Buffer = null;
        if (self.device.lpVtbl.*.CreateBuffer.?(self.device, &description, null, &made) < 0) return error.NoBuffer;
        return made.?;
    }

    /// The instance buffer, grown to at least `bytes` (doubling, so a growing scene does not
    /// reallocate every frame).
    fn grow(self: *Renderer, bytes: usize) Error!void {
        const capacity = @max(bytes, self.capacity * 2, 64 * 256);
        const made = try self.buffer(capacity, c.D3D11_BIND_VERTEX_BUFFER);
        release(self.instances);
        self.instances = made;
        self.capacity = capacity;
    }

    /// Replaces a dynamic buffer's contents with `bytes`.
    fn write(self: *Renderer, resource: *c.ID3D11Resource, bytes: []const u8) Error!void {
        var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (self.context.lpVtbl.*.Map.?(self.context, resource, 0, c.D3D11_MAP_WRITE_DISCARD, 0, &mapped) < 0) return error.DeviceLost;
        @memcpy(@as([*]u8, @ptrCast(mapped.pData))[0..bytes.len], bytes);
        self.context.lpVtbl.*.Unmap.?(self.context, resource, 0);
    }

    /// Sends the atlas region glyphs were added to since the last frame, and nothing else.
    fn syncAtlas(self: *Renderer, glyphs: *atlas.Atlas) void {
        const region = glyphs.takeDirty() orelse return;
        const box: c.D3D11_BOX = .{ .left = region.x, .top = region.y, .front = 0, .right = region.x + region.width, .bottom = region.y + region.height, .back = 1 };
        const first = glyphs.pixels[@as(usize, region.y) * atlas.side + region.x ..];
        self.context.lpVtbl.*.UpdateSubresource.?(self.context, @ptrCast(self.atlas_texture), 0, &box, first.ptr, atlas.side, 0);
        self.uploaded += @as(u64, region.width) * region.height;
    }
};

fn element(comptime semantic: [*:0]const u8, offset: usize) c.D3D11_INPUT_ELEMENT_DESC {
    return .{
        .SemanticName = semantic,
        .SemanticIndex = 0,
        .Format = c.DXGI_FORMAT_R32G32B32A32_FLOAT,
        .InputSlot = 0,
        .AlignedByteOffset = @intCast(offset),
        .InputSlotClass = c.D3D11_INPUT_PER_INSTANCE_DATA,
        .InstanceDataStepRate = 1,
    };
}

/// The swap chain's flags: always the frame-latency object, tearing when it was granted.
fn swapFlags(tearing: bool) c.UINT {
    return latency_flag | if (tearing) @as(c.UINT, @intCast(c.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING)) else 0;
}

/// Whether the device's DXGI lets a windowed flip-model swap chain tear (Windows 10 1607+,
/// a driver and display that allow it). Without it, unlimited presents still run free and
/// the compositor shows the newest at each refresh.
fn allowsTearing(device: *c.ID3D11Device) bool {
    var dxgi_device: ?*c.IDXGIDevice = null;
    if (device.lpVtbl.*.QueryInterface.?(device, &iid_dxgi_device, @ptrCast(&dxgi_device)) < 0) return false;
    defer release(dxgi_device);
    var adapter: ?*c.IDXGIAdapter = null;
    if (dxgi_device.?.lpVtbl.*.GetAdapter.?(dxgi_device.?, &adapter) < 0) return false;
    defer release(adapter);
    var factory: ?*c.IDXGIFactory5 = null;
    if (adapter.?.lpVtbl.*.GetParent.?(adapter.?, &iid_dxgi_factory5, @ptrCast(&factory)) < 0) return false;
    defer release(factory);
    var allowed: c.BOOL = c.FALSE;
    if (factory.?.lpVtbl.*.CheckFeatureSupport.?(factory.?, c.DXGI_FEATURE_PRESENT_ALLOW_TEARING, &allowed, @sizeOf(c.BOOL)) < 0) return false;
    return allowed != c.FALSE;
}

/// A flip-model swap chain on `window` from the device's own adapter's factory.
fn swapChain(device: *c.ID3D11Device, window: c.HWND, width: u32, height: u32, flags: c.UINT) Error!*c.IDXGISwapChain1 {
    var dxgi_device: ?*c.IDXGIDevice = null;
    if (device.lpVtbl.*.QueryInterface.?(device, &iid_dxgi_device, @ptrCast(&dxgi_device)) < 0) return error.NoFactory;
    defer release(dxgi_device);
    var adapter: ?*c.IDXGIAdapter = null;
    if (dxgi_device.?.lpVtbl.*.GetAdapter.?(dxgi_device.?, &adapter) < 0) return error.NoFactory;
    defer release(adapter);
    var factory: ?*c.IDXGIFactory2 = null;
    if (adapter.?.lpVtbl.*.GetParent.?(adapter.?, &iid_dxgi_factory2, @ptrCast(&factory)) < 0) return error.NoFactory;
    defer release(factory);
    const description: c.DXGI_SWAP_CHAIN_DESC1 = .{
        .Width = width,
        .Height = height,
        .Format = c.DXGI_FORMAT_B8G8R8A8_UNORM,
        .Stereo = c.FALSE,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .Scaling = c.DXGI_SCALING_STRETCH,
        .SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = c.DXGI_ALPHA_MODE_UNSPECIFIED,
        .Flags = flags,
    };
    var chain: ?*c.IDXGISwapChain1 = null;
    if (factory.?.lpVtbl.*.CreateSwapChainForHwnd.?(factory.?, @ptrCast(device), window, &description, null, null, &chain) < 0) return error.NoSwapChain;
    return chain.?;
}

fn release(object: anytype) void {
    const pointer = switch (@typeInfo(@TypeOf(object))) {
        .optional => object orelse return,
        else => object,
    };
    _ = pointer.lpVtbl.*.Release.?(pointer);
}
