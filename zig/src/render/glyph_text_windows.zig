//! Text for the draw command list on Windows: the same calls as `glyph_text.zig` (HarfBuzz
//! and FreeType on Linux), with DirectWrite, which comes with Windows.
//!
//! A run is laid out by `IDWriteTextLayout` — shaping, kerning, and the system's fallback
//! faces for characters the chosen face lacks — and handed back glyph by glyph to a text
//! renderer of our own (`Collector`, the one COM object here), which keeps each glyph's
//! face, index and pen offset. A glyph is rasterised once per face and size with
//! `CreateGlyphRunAnalysis`: its ClearType (3×1) texture, the three subpixels averaged to
//! one byte of coverage, into the atlas (`atlas.zig`). Pens are rounded to whole pixels, so
//! one rasterisation serves every place the glyph appears, as on Linux.
//!
//! Families are names (`Segoe UI`) or the generic ones `text_windows.zig` maps.

const std = @import("std");
const scene = @import("scene.zig");
const atlas = @import("atlas.zig");

const c = @import("c_win_text");

pub const Error = error{ NoFactory, NoFont, NoLayout, AtlasFull, TooManyFaces, OutOfMemory };

const iid_dwrite_factory: c.GUID = .{ .Data1 = 0xb859ee5a, .Data2 = 0xd838, .Data3 = 0x4b5b, .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };

/// Runs kept before the cache is emptied, as `glyph_text.zig` keeps them.
pub const cache_capacity = 4096;

/// One glyph of a laid-out run.
const Shaped = struct {
    /// Which of `Font.faces` draws it.
    face: u8,
    glyph: u16,
    /// From the run's pen start, whole pixels.
    x: f32,
    /// Up from the baseline (a mark's offset), whole pixels.
    y: f32,
};

const Run = struct { glyphs: []Shaped, advance: f32 };

pub const Font = struct {
    allocator: std.mem.Allocator,
    write: *c.IDWriteFactory,
    format: *c.IDWriteTextFormat,
    /// The faces runs were drawn with: the family's own first, fallbacks as they appear.
    /// Each holds a reference; part of the atlas key, so glyph 37 of two faces is two glyphs.
    faces: std.ArrayList(*c.IDWriteFontFace) = .empty,
    runs: std.StringHashMapUnmanaged(Run) = .empty,
    /// Pixel size; part of every atlas key.
    size: u32,
    /// Tells this font's glyphs from another's in the atlas.
    id: u32,
    line_height: f32 = 0,

    pub fn open(allocator: std.mem.Allocator, family: [:0]const u8, size: u32, id: u32) Error!Font {
        var write: ?*c.IDWriteFactory = null;
        if (c.DWriteCreateFactory(c.DWRITE_FACTORY_TYPE_SHARED, &iid_dwrite_factory, @ptrCast(&write)) < 0) return error.NoFactory;
        errdefer release(write);
        var name: [64:0]u16 = undefined;
        const face_name = generic(family) orelse family;
        const units = std.unicode.utf8ToUtf16Le(name[0 .. name.len - 1], face_name[0..@min(face_name.len, 60)]) catch return error.NoFont;
        name[units] = 0;
        var format: ?*c.IDWriteTextFormat = null;
        if (write.?.lpVtbl.*.CreateTextFormat.?(write.?, &name, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, @floatFromInt(size), std.unicode.utf8ToUtf16LeStringLiteral("en-us"), &format) < 0) return error.NoFont;
        var self: Font = .{ .allocator = allocator, .write = write.?, .format = format.?, .size = size, .id = id };
        errdefer self.deinit();
        // The line's height, from DirectWrite's own layout of one line.
        const one_line = try self.layout("X");
        defer release(one_line);
        var line: c.DWRITE_LINE_METRICS = undefined;
        var lines: u32 = 0;
        if (one_line.lpVtbl.*.GetLineMetrics.?(one_line, &line, 1, &lines) >= 0 and lines > 0) self.line_height = line.height;
        return self;
    }

    fn forget(self: *Font) void {
        var entries = self.runs.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.glyphs);
        }
        self.runs.clearAndFree(self.allocator);
    }

    pub fn deinit(self: *Font) void {
        self.forget();
        for (self.faces.items) |face| release(face);
        self.faces.deinit(self.allocator);
        release(self.format);
        release(self.write);
    }

    /// The distance from one baseline to the next, in pixels.
    pub fn lineHeight(self: *const Font) f32 {
        return self.line_height;
    }

    fn layout(self: *Font, utf8: []const u8) Error!*c.IDWriteTextLayout {
        var wide: [1024]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(&wide, utf8) catch return error.NoLayout;
        var made: ?*c.IDWriteTextLayout = null;
        if (self.write.lpVtbl.*.CreateTextLayout.?(self.write, &wide, @intCast(units), self.format, 1e6, 1e6, &made) < 0) return error.NoLayout;
        return made.?;
    }

    /// The run for `utf8`, laid out by DirectWrite the first time and kept.
    fn shaped(self: *Font, utf8: []const u8) Error!Run {
        if (self.runs.get(utf8)) |known| return known;
        if (self.runs.count() >= cache_capacity) self.forget();
        const laid = try self.layout(utf8);
        defer release(laid);
        var collector: Collector = .{ .font = self };
        defer collector.glyphs.deinit(self.allocator);
        if (laid.lpVtbl.*.Draw.?(laid, null, &collector.renderer, 0, 0) < 0 or collector.failed != null) return collector.failed orelse error.NoLayout;
        var metrics: c.DWRITE_TEXT_METRICS = undefined;
        const advance: f32 = if (laid.lpVtbl.*.GetMetrics.?(laid, &metrics) >= 0) @round(metrics.widthIncludingTrailingWhitespace) else 0;
        const run: Run = .{ .glyphs = try collector.glyphs.toOwnedSlice(self.allocator), .advance = advance };
        errdefer self.allocator.free(run.glyphs);
        const key = try self.allocator.dupe(u8, utf8);
        errdefer self.allocator.free(key);
        try self.runs.put(self.allocator, key, run);
        return run;
    }

    /// The index of `face` in `faces`, holding a reference to it the first time.
    fn faceIndex(self: *Font, face: *c.IDWriteFontFace) Error!u8 {
        for (self.faces.items, 0..) |known, index| if (known == face) return @intCast(index);
        if (self.faces.items.len == 255) return error.TooManyFaces;
        _ = face.lpVtbl.*.AddRef.?(face);
        try self.faces.append(self.allocator, face);
        return @intCast(self.faces.items.len - 1);
    }

    /// The glyph's slot, rasterising it into `glyphs` the first time.
    fn slot(self: *Font, allocator: std.mem.Allocator, glyphs: *atlas.Atlas, face_index: u8, glyph: u16) Error!atlas.Slot {
        const key: atlas.Key = .{ .font = self.id * 256 + face_index, .glyph = glyph, .size = self.size };
        if (glyphs.find(key)) |known| return known;
        const face = self.faces.items[face_index];
        var index = glyph;
        var advance: f32 = 0;
        var offset: c.DWRITE_GLYPH_OFFSET = .{ .advanceOffset = 0, .ascenderOffset = 0 };
        const run: c.DWRITE_GLYPH_RUN = .{
            .fontFace = face,
            .fontEmSize = @floatFromInt(self.size),
            .glyphCount = 1,
            .glyphIndices = &index,
            .glyphAdvances = &advance,
            .glyphOffsets = &offset,
            .isSideways = c.FALSE,
            .bidiLevel = 0,
        };
        var analysis: ?*c.IDWriteGlyphRunAnalysis = null;
        if (self.write.lpVtbl.*.CreateGlyphRunAnalysis.?(self.write, &run, 1.0, null, c.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, c.DWRITE_MEASURING_MODE_NATURAL, 0, 0, &analysis) < 0) return error.NoLayout;
        defer release(analysis);
        var bounds: c.RECT = undefined;
        if (analysis.?.lpVtbl.*.GetAlphaTextureBounds.?(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds) < 0) return error.NoLayout;
        const width: u32 = @intCast(@max(bounds.right - bounds.left, 0));
        const height: u32 = @intCast(@max(bounds.bottom - bounds.top, 0));
        if (width == 0 or height == 0) {
            return (try glyphs.put(allocator, key, 0, 0, 0, &.{}, 0, 0)) orelse error.AtlasFull;
        }
        const texture = try allocator.alloc(u8, width * height * 3);
        defer allocator.free(texture);
        if (analysis.?.lpVtbl.*.CreateAlphaTexture.?(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, texture.ptr, @intCast(texture.len)) < 0) return error.NoLayout;
        // One byte of coverage a pixel: the three subpixels' mean.
        const coverage = try allocator.alloc(u8, width * height);
        defer allocator.free(coverage);
        for (coverage, 0..) |*each, at| {
            const sum = @as(u32, texture[at * 3]) + texture[at * 3 + 1] + texture[at * 3 + 2];
            each.* = @intCast(sum / 3);
        }
        return (try glyphs.put(allocator, key, width, height, width, coverage, bounds.left, -bounds.top)) orelse error.AtlasFull;
    }

    /// The pen advance of `utf8` in pixels, without drawing it (the run is kept).
    pub fn measure(self: *Font, utf8: []const u8) Error!f32 {
        return (try self.shaped(utf8)).advance;
    }

    /// The longest prefix of `utf8`, cut at a character boundary, that is at most `limit`
    /// pixels wide followed by "…"; `utf8` itself when it fits.
    pub fn fit(self: *Font, utf8: []const u8, limit: f32, out: []u8) Error![]const u8 {
        if (try self.measure(utf8) <= limit) return utf8;
        const ellipsis = "…";
        var end = utf8.len;
        while (end > 0) {
            end -= 1;
            while (end > 0 and utf8[end] & 0xC0 == 0x80) end -= 1;
            if (end + ellipsis.len > out.len) continue;
            @memcpy(out[0..end], utf8[0..end]);
            @memcpy(out[end..][0..ellipsis.len], ellipsis);
            if (try self.measure(out[0 .. end + ellipsis.len]) <= limit) return out[0 .. end + ellipsis.len];
        }
        return "";
    }

    /// Lays `utf8` out and appends its glyphs with the pen starting at `x` on the baseline
    /// `baseline`. Returns the pen's advance in pixels.
    pub fn draw(
        self: *Font,
        allocator: std.mem.Allocator,
        glyphs: *atlas.Atlas,
        list: *scene.List,
        utf8: []const u8,
        x: f32,
        baseline: f32,
        colour: scene.Colour,
    ) Error!f32 {
        const run = try self.shaped(utf8);
        const pen: f32 = @round(x);
        const line: f32 = @round(baseline);
        for (run.glyphs) |each| {
            const placed = try self.slot(allocator, glyphs, each.face, each.glyph);
            if (placed.width == 0 or placed.height == 0) continue;
            try list.glyph(allocator, .{
                .x = pen + each.x + @as(f32, @floatFromInt(placed.left)),
                .y = line - each.y - @as(f32, @floatFromInt(placed.top)),
                .width = @floatFromInt(placed.width),
                .height = @floatFromInt(placed.height),
            }, placed.uv(), colour);
        }
        return run.advance;
    }
};

/// The text renderer DirectWrite hands a laid-out run to: it draws nothing, it keeps each
/// glyph's face, index and pen position. The interface is the first field, so a pointer to
/// it is a pointer to the collector.
const Collector = struct {
    /// The header types `lpVtbl` as mutable; the table is never written through it.
    renderer: c.IDWriteTextRenderer = .{ .lpVtbl = @constCast(&vtable) },
    font: *Font,
    glyphs: std.ArrayList(Shaped) = .empty,
    /// The first line's baseline, which every glyph's height is measured from.
    baseline: ?f32 = null,
    failed: ?Error = null,

    const vtable: c.IDWriteTextRendererVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = releaseSelf,
        .IsPixelSnappingDisabled = isPixelSnappingDisabled,
        .GetCurrentTransform = getCurrentTransform,
        .GetPixelsPerDip = getPixelsPerDip,
        .DrawGlyphRun = drawGlyphRun,
        .DrawUnderline = drawUnderline,
        .DrawStrikethrough = drawStrikethrough,
        .DrawInlineObject = drawInlineObject,
    };

    fn of(this: [*c]c.IDWriteTextRenderer) *Collector {
        return @fieldParentPtr("renderer", @as(*c.IDWriteTextRenderer, @ptrCast(this)));
    }

    fn queryInterface(_: [*c]c.IDWriteTextRenderer, _: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.winapi) c.HRESULT {
        // Only DirectWrite ever holds it, for the length of one `Draw`; no other interface.
        out.* = null;
        return c.E_NOINTERFACE;
    }
    fn addRef(_: [*c]c.IDWriteTextRenderer) callconv(.winapi) c.ULONG {
        return 1;
    }
    fn releaseSelf(_: [*c]c.IDWriteTextRenderer) callconv(.winapi) c.ULONG {
        return 1;
    }
    fn isPixelSnappingDisabled(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, disabled: [*c]c.BOOL) callconv(.winapi) c.HRESULT {
        disabled.* = c.FALSE;
        return c.S_OK;
    }
    fn getCurrentTransform(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, transform: [*c]c.DWRITE_MATRIX) callconv(.winapi) c.HRESULT {
        transform.* = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 };
        return c.S_OK;
    }
    fn getPixelsPerDip(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, pixels: [*c]c.FLOAT) callconv(.winapi) c.HRESULT {
        pixels.* = 1;
        return c.S_OK;
    }
    fn drawGlyphRun(this: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, x: c.FLOAT, y: c.FLOAT, _: c.DWRITE_MEASURING_MODE, run: [*c]const c.DWRITE_GLYPH_RUN, _: [*c]const c.DWRITE_GLYPH_RUN_DESCRIPTION, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
        const self = of(this);
        self.collect(x, y, run) catch |err| {
            self.failed = err;
            return c.E_FAIL;
        };
        return c.S_OK;
    }
    fn drawUnderline(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, _: c.FLOAT, _: c.FLOAT, _: [*c]const c.DWRITE_UNDERLINE, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
        return c.S_OK;
    }
    fn drawStrikethrough(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, _: c.FLOAT, _: c.FLOAT, _: [*c]const c.DWRITE_STRIKETHROUGH, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
        return c.S_OK;
    }
    fn drawInlineObject(_: [*c]c.IDWriteTextRenderer, _: ?*anyopaque, _: c.FLOAT, _: c.FLOAT, _: [*c]c.IDWriteInlineObject, _: c.BOOL, _: c.BOOL, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
        return c.S_OK;
    }

    fn collect(self: *Collector, x: f32, y: f32, run: *const c.DWRITE_GLYPH_RUN) Error!void {
        const baseline = self.baseline orelse y;
        self.baseline = baseline;
        const face = try self.font.faceIndex(run.fontFace);
        var pen = x;
        for (0..run.glyphCount) |at| {
            const offset: c.DWRITE_GLYPH_OFFSET = if (run.glyphOffsets != null) run.glyphOffsets[at] else .{ .advanceOffset = 0, .ascenderOffset = 0 };
            try self.glyphs.append(self.font.allocator, .{
                .face = face,
                .glyph = run.glyphIndices[at],
                .x = @round(pen + offset.advanceOffset),
                .y = @round(baseline - y + offset.ascenderOffset),
            });
            pen += if (run.glyphAdvances != null) run.glyphAdvances[at] else 0;
        }
    }
};

/// Windows' face for a generic family name, as `text_windows.zig` maps them.
fn generic(family: []const u8) ?[:0]const u8 {
    if (std.mem.eql(u8, family, "monospace")) return "Consolas";
    if (std.mem.eql(u8, family, "sans") or std.mem.eql(u8, family, "sans-serif")) return "Segoe UI";
    if (std.mem.eql(u8, family, "serif")) return "Times New Roman";
    return null;
}

/// `IUnknown::Release` on any COM pointer, null included (through `IUnknown`: every COM
/// vtable starts with its methods).
fn release(object: anytype) void {
    const pointer = switch (@typeInfo(@TypeOf(object))) {
        .optional => object orelse return,
        else => object,
    };
    const unknown: *c.IUnknown = @ptrCast(pointer);
    _ = unknown.lpVtbl.*.Release.?(unknown);
}
