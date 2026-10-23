//! Text on the native path on Windows: the same calls as `text.zig` (Cairo on Linux), drawn
//! with DirectWrite, which comes with Windows (7 and later; Vista with its Platform Update).
//!
//! DirectWrite lays the string out — shaping, the system's fallback fonts for a character
//! the face lacks, ClearType — and Direct2D rasterises the layout into a GDI DIB through a
//! DC render target. The DIB is a scratch copy of the part of the frame the string covers:
//! copied from the frame, drawn over, copied back, so the glyphs' edges are blended with
//! what is really under them. No COM object of our own is involved (`IDWriteTextLayout`
//! and `DrawTextLayout`, rather than a glyph-run renderer).
//!
//! Sizes are pixels, as Cairo's are here: the render target's DPI is fixed at 96, where a
//! DirectWrite DIP is one pixel. Generic families map to Windows' own faces (`monospace`
//! is Consolas, `sans` Segoe UI, `serif` Times New Roman), the faces CSS would pick there.

const std = @import("std");
const surface = @import("surface.zig");
const Size = @import("../window/window.zig").Size;

const c = @import("c_win_text");

pub const Error = error{
    /// The frame has no pixels to draw into.
    SurfaceRefused,
    /// Direct2D, DirectWrite or GDI refused one of the objects text needs.
    ContextRefused,
};

const iid_d2d1_factory: c.GUID = .{ .Data1 = 0x06152247, .Data2 = 0x6f50, .Data3 = 0x465a, .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
const iid_dwrite_factory: c.GUID = .{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };

pub const Text = struct {
    /// The frame drawn into: its memory, size and row length. The caller's; never freed here.
    pixels: []u8,
    size: Size,
    stride: usize,
    write: *c.IDWriteFactory,
    d2d: *c.ID2D1Factory,
    target: *c.ID2D1DCRenderTarget,
    /// The scratch DIB the target draws into, grown to the largest string drawn.
    dc: c.HDC,
    bitmap: ?c.HBITMAP = null,
    bits: ?[*]u8 = null,
    scratch: Size = .{ .width = 0, .height = 0 },
    format: ?*c.IDWriteTextFormat = null,

    pub fn init(target: surface.Surface) Error!Text {
        if (target.pixels.len == 0) return error.SurfaceRefused;

        var d2d: ?*c.ID2D1Factory = null;
        if (c.D2D1CreateFactory(c.D2D1_FACTORY_TYPE_SINGLE_THREADED, &iid_d2d1_factory, null, @ptrCast(&d2d)) < 0) return error.ContextRefused;
        errdefer release(d2d);
        var write: ?*c.IDWriteFactory = null;
        if (c.DWriteCreateFactory(c.DWRITE_FACTORY_TYPE_SHARED, &iid_dwrite_factory, @ptrCast(&write)) < 0) return error.ContextRefused;
        errdefer release(write);

        // 96 DPI: a DIP is a pixel, as the frame counts them. Opaque (`IGNORE`): the frame
        // has nothing behind it, and ClearType needs an opaque target. Software, because
        // this is the CPU path's text — the frame is in memory and GDI presents it: a
        // hardware target read every string back from the GPU into the DC, and five strings
        // a frame held the window at 39.8 frames a second against 50.4 (measured, R7 240).
        // The GPU path (D3D11, the frame never leaves the GPU) draws text from a glyph atlas.
        const properties: c.D2D1_RENDER_TARGET_PROPERTIES = .{
            .type = c.D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            .pixelFormat = .{ .format = c.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = c.D2D1_ALPHA_MODE_IGNORE },
            .dpiX = 96,
            .dpiY = 96,
            .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        var dc_target: ?*c.ID2D1DCRenderTarget = null;
        if (d2d.?.lpVtbl.*.CreateDCRenderTarget.?(d2d.?, &properties, &dc_target) < 0) return error.ContextRefused;
        errdefer release(dc_target);

        const dc = c.CreateCompatibleDC(null) orelse return error.ContextRefused;
        var self: Text = .{
            .pixels = target.pixels,
            .size = target.size,
            .stride = target.stride,
            .write = write.?,
            .d2d = d2d.?,
            .target = dc_target.?,
            .dc = dc,
        };
        self.setFace("monospace", default_size);
        return self;
    }

    /// Points the text at `target` again after the frame was resized; the face carries over.
    pub fn retarget(self: *Text, target: surface.Surface) Error!void {
        if (target.pixels.len == 0) return error.SurfaceRefused;
        self.pixels = target.pixels;
        self.size = target.size;
        self.stride = target.stride;
    }

    const default_size: f64 = 11.0;

    pub fn deinit(self: *Text) void {
        release(self.format);
        if (self.bitmap) |bitmap| _ = c.DeleteObject(bitmap);
        _ = c.DeleteDC(self.dc);
        release(self.target);
        release(self.write);
        release(self.d2d);
        self.* = undefined;
    }

    /// Sets the typeface and size: a family name (or `monospace`, `sans`, `serif`) and pixels.
    pub fn setFace(self: *Text, family: [*:0]const u8, points: f64) void {
        var name: [64:0]u16 = undefined;
        const wanted = std.mem.span(family);
        const face = generic(wanted) orelse wanted;
        const units = std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], face[0..@min(face.len, 60)]) catch return;
        name[units] = 0;
        var format: ?*c.IDWriteTextFormat = null;
        const hr = self.write.lpVtbl.*.CreateTextFormat.?(self.write, &name, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, @floatCast(points), std.unicode.utf8ToUtf16LeStringLiteral("en-us"), &format);
        if (hr < 0) return;
        release(self.format);
        self.format = format;
    }

    pub const Extent = struct {
        width: i32,
        height: i32,
        ascent: i32,
        descent: i32,
    };

    /// The longest string drawn, in bytes, as `text.zig` refuses past it.
    pub const max_bytes: usize = 256;

    pub fn measure(self: *Text, text: []const u8) ?Extent {
        const layout = self.lay(text) orelse return null;
        defer release(layout.layout);
        return .{
            .width = @intFromFloat(@round(layout.width)),
            .height = @intFromFloat(@round(layout.height)),
            .ascent = @intFromFloat(@round(layout.baseline)),
            .descent = @intFromFloat(@round(layout.height - layout.baseline)),
        };
    }

    /// Draws `text` with its baseline starting at (`x`, `y`). False when it is too long or
    /// could not be laid out.
    pub fn draw(self: *Text, x: i32, y: i32, text: []const u8, colour: surface.Colour) bool {
        const layout = self.lay(text) orelse return false;
        defer release(layout.layout);

        // The box the string covers, with room for glyphs that overhang their advance.
        const margin: i32 = 4;
        const top_y = y - @as(i32, @intFromFloat(@ceil(layout.baseline)));
        const box_left = @max(x - margin, 0);
        const box_top = @max(top_y - margin, 0);
        const box_right = @min(x + @as(i32, @intFromFloat(@ceil(layout.width))) + margin, @as(i32, @intCast(self.size.width)));
        const box_bottom = @min(top_y + @as(i32, @intFromFloat(@ceil(layout.height))) + margin, @as(i32, @intCast(self.size.height)));
        if (box_right <= box_left or box_bottom <= box_top) return true;
        const width: u32 = @intCast(box_right - box_left);
        const height: u32 = @intCast(box_bottom - box_top);
        const bits = self.reserve(width, height) orelse return false;

        self.copy(bits, box_left, box_top, width, height, .into_scratch);

        const area: c.RECT = .{ .left = 0, .top = 0, .right = @intCast(width), .bottom = @intCast(height) };
        if (self.target.lpVtbl.*.BindDC.?(self.target, self.dc, &area) < 0) return false;
        const render: *c.ID2D1RenderTarget = @ptrCast(self.target);
        const ink: c.D2D1_COLOR_F = .{
            .r = @as(f32, @floatFromInt(colour.r)) / 255.0,
            .g = @as(f32, @floatFromInt(colour.g)) / 255.0,
            .b = @as(f32, @floatFromInt(colour.b)) / 255.0,
            .a = @as(f32, @floatFromInt(colour.a)) / 255.0,
        };
        var brush: ?*c.ID2D1SolidColorBrush = null;
        render.lpVtbl.*.BeginDraw.?(render);
        if (render.lpVtbl.*.CreateSolidColorBrush.?(render, &ink, null, &brush) < 0) {
            _ = render.lpVtbl.*.EndDraw.?(render, null, null);
            return false;
        }
        defer release(brush);
        const origin: c.D2D1_POINT_2F = .{ .x = @floatFromInt(x - box_left), .y = @floatFromInt(top_y - box_top) };
        render.lpVtbl.*.DrawTextLayout.?(render, origin, layout.layout, @ptrCast(brush), c.D2D1_DRAW_TEXT_OPTIONS_NONE);
        if (render.lpVtbl.*.EndDraw.?(render, null, null) < 0) return false;
        // Direct2D hands the result to GDI; GDI may still be holding it in its batch.
        _ = c.GdiFlush();

        self.copy(bits, box_left, box_top, width, height, .into_frame);
        return true;
    }

    pub fn widthOf(self: *Text, text: []const u8) i32 {
        const extent = self.measure(text) orelse return 0;
        return extent.width;
    }

    const Laid = struct { layout: *c.IDWriteTextLayout, width: f32, height: f32, baseline: f32 };

    /// `text` laid out on one line in the current face, with its size and baseline.
    fn lay(self: *Text, text: []const u8) ?Laid {
        if (text.len + 1 > max_bytes) return null;
        const format = self.format orelse return null;
        var wide: [max_bytes]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(&wide, text) catch return null;
        var layout: ?*c.IDWriteTextLayout = null;
        if (self.write.lpVtbl.*.CreateTextLayout.?(self.write, &wide, @intCast(units), format, 16384, 16384, &layout) < 0) return null;
        const laid = layout.?;
        var metrics: c.DWRITE_TEXT_METRICS = undefined;
        var line: c.DWRITE_LINE_METRICS = undefined;
        var lines: u32 = 0;
        if (laid.lpVtbl.*.GetMetrics.?(laid, &metrics) < 0 or
            laid.lpVtbl.*.GetLineMetrics.?(laid, &line, 1, &lines) < 0 or lines == 0)
        {
            release(laid);
            return null;
        }
        return .{ .layout = laid, .width = metrics.widthIncludingTrailingWhitespace, .height = line.height, .baseline = line.baseline };
    }

    /// The scratch DIB, at least `width` × `height`, selected into the DC.
    fn reserve(self: *Text, width: u32, height: u32) ?[*]u8 {
        if (self.bits) |bits| if (self.scratch.width >= width and self.scratch.height >= height) return bits;
        const grown: Size = .{ .width = @max(width, self.scratch.width), .height = @max(height, self.scratch.height) };
        var info = std.mem.zeroes(c.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = @intCast(grown.width);
        info.bmiHeader.biHeight = -@as(i32, @intCast(grown.height)); // top-down, as the frame
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = c.BI_RGB;
        var raw: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(self.dc, &info, c.DIB_RGB_COLORS, &raw, null, 0) orelse return null;
        _ = c.SelectObject(self.dc, bitmap);
        if (self.bitmap) |old| _ = c.DeleteObject(old);
        self.bitmap = bitmap;
        self.bits = @ptrCast(raw);
        self.scratch = grown;
        return self.bits;
    }

    const Direction = enum { into_scratch, into_frame };

    /// Copies a box between the frame and the scratch DIB, row by row (their rows differ).
    fn copy(self: *Text, bits: [*]u8, left: i32, top: i32, width: u32, height: u32, direction: Direction) void {
        const row_bytes = @as(usize, width) * 4;
        const scratch_stride = @as(usize, self.scratch.width) * 4;
        for (0..height) |row| {
            const frame_at = (@as(usize, @intCast(top)) + row) * self.stride + @as(usize, @intCast(left)) * 4;
            const frame_row = self.pixels[frame_at..][0..row_bytes];
            const scratch_row = bits[row * scratch_stride ..][0..row_bytes];
            switch (direction) {
                .into_scratch => @memcpy(scratch_row, frame_row),
                .into_frame => @memcpy(frame_row, scratch_row),
            }
        }
    }
};

/// Windows' face for a generic family name, as CSS would pick it there.
fn generic(family: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, family, "monospace")) return "Consolas";
    if (std.mem.eql(u8, family, "sans") or std.mem.eql(u8, family, "sans-serif")) return "Segoe UI";
    if (std.mem.eql(u8, family, "serif")) return "Times New Roman";
    return null;
}

/// `IUnknown::Release` on any COM pointer, null included. Through `IUnknown`: mingw's
/// Direct2D vtables nest IUnknown's methods in a `Base` field, DirectWrite's list them
/// flat, and every COM vtable starts with them either way.
fn release(object: anytype) void {
    const pointer = switch (@typeInfo(@TypeOf(object))) {
        .optional => object orelse return,
        else => object,
    };
    const unknown: *c.IUnknown = @ptrCast(pointer);
    _ = unknown.lpVtbl.*.Release.?(unknown);
}

test "a string drawn with DirectWrite lands on its baseline, inside its box, in its colour" {
    var frame = try surface.Surface.init(std.testing.allocator, .{ .width = 240, .height = 60 }, .argb8888);
    defer frame.deinit();
    const bed = surface.Colour.rgb(0x14, 0x18, 0x1c);
    const ink = surface.Colour.rgb(0xe6, 0xea, 0xef);
    frame.fill(bed);

    var text = try Text.init(frame);
    defer text.deinit();
    text.setFace("sans", 20);
    const extent = text.measure("Lepton") orelse return error.NotMeasured;
    try std.testing.expect(extent.width > 30 and extent.ascent > 10);

    const x: i32 = 10;
    const baseline: i32 = 40;
    try std.testing.expect(text.draw(x, baseline, "Lepton", ink));

    // Every changed pixel is inside the string's box; the brightest is the ink itself.
    var changed: usize = 0;
    var brightest: u32 = 0;
    var lowest: u32 = 0;
    for (0..frame.size.height) |y| for (0..frame.size.width) |column| {
        const here = frame.pixelAt(@intCast(column), @intCast(y)).?;
        if (here.r == bed.r and here.g == bed.g and here.b == bed.b) continue;
        changed += 1;
        try std.testing.expect(column + 1 >= x and column <= x + extent.width + 4);
        try std.testing.expect(y + 1 >= baseline - extent.ascent and y <= baseline + extent.descent);
        brightest = @max(brightest, @as(u32, here.r) + here.g + here.b);
        lowest = @max(lowest, @as(u32, @intCast(y)));
    };
    try std.testing.expect(changed > 50);
    try std.testing.expect(brightest >= @as(u32, ink.r) + ink.g + ink.b - 30);
    // "Lepton" has a descender (p): ink reaches below the baseline, not far.
    try std.testing.expect(lowest > baseline and lowest <= baseline + extent.descent);
}

test "generic families are Windows' own faces" {
    try std.testing.expectEqualStrings("Consolas", generic("monospace").?);
    try std.testing.expectEqualStrings("Segoe UI", generic("sans").?);
    try std.testing.expect(generic("Inter") == null);
}
