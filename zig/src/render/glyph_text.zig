//! Text for the draw command list: HarfBuzz shapes, FreeType rasterises, the atlas keeps.
//!
//! `Font.draw` shapes a UTF-8 run (ligatures, kerning, any script HarfBuzz knows), puts
//! each glyph it has not seen at this size into the atlas once, and appends one
//! `scene.Kind.glyph` instance per glyph. Pens are rounded to whole pixels, so a glyph's
//! one rasterisation is reused wherever it appears. The font file is found through
//! fontconfig (`find`), as the desktop finds it.
//!
//! A run is shaped once: its glyphs and pixel offsets are kept by its text, so a frame that
//! draws the same labels again only places them. Measured on the card scene: shaping 1000
//! labels every frame cost 1494 µs of CPU a frame.

const std = @import("std");
const scene = @import("scene.zig");
const atlas = @import("atlas.zig");

const c = @cImport({
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("fontconfig/fontconfig.h");
});

pub const Error = error{ NoFreeType, NoFace, NoSize, NoFont, NoShaping, AtlasFull, OutOfMemory };

/// The file fontconfig picks for `pattern` ("sans", "monospace", "Noto Serif:bold"),
/// written into `out`.
pub fn find(pattern: [:0]const u8, out: []u8) Error![:0]const u8 {
    const config = c.FcInitLoadConfigAndFonts() orelse return error.NoFont;
    defer c.FcConfigDestroy(config);
    const wanted = c.FcNameParse(pattern.ptr) orelse return error.NoFont;
    defer c.FcPatternDestroy(wanted);
    _ = c.FcConfigSubstitute(config, wanted, c.FcMatchPattern);
    c.FcDefaultSubstitute(wanted);
    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(config, wanted, &result) orelse return error.NoFont;
    defer c.FcPatternDestroy(match);
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch) return error.NoFont;
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
    if (path.len + 1 > out.len) return error.NoFont;
    @memcpy(out[0..path.len], path);
    out[path.len] = 0;
    return out[0..path.len :0];
}

/// One shaped glyph, in whole pixels.
const Shaped = struct {
    glyph: u32,
    x_offset: f32,
    y_offset: f32,
    advance: f32,
};

/// Runs kept at most; past it the cache starts again (a UI's labels repeat; a log's lines
/// would otherwise grow it without end).
pub const cache_capacity = 4096;

pub const Font = struct {
    allocator: std.mem.Allocator,
    /// Shaped runs by their text (the key is an owned copy).
    runs: std.StringHashMapUnmanaged([]Shaped) = .empty,
    library: c.FT_Library,
    face: c.FT_Face,
    shaper: *c.hb_font_t,
    buffer: *c.hb_buffer_t,
    /// Pixel size; part of every atlas key.
    size: u32,
    /// Tells this font's glyphs from another's in the atlas.
    id: u32,

    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8, size: u32, id: u32) Error!Font {
        var library: c.FT_Library = null;
        if (c.FT_Init_FreeType(&library) != 0) return error.NoFreeType;
        errdefer _ = c.FT_Done_FreeType(library);
        var face: c.FT_Face = null;
        if (c.FT_New_Face(library, path.ptr, 0, &face) != 0) return error.NoFace;
        errdefer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, size) != 0) return error.NoSize;
        // Referenced: HarfBuzz holds the face, and reads its size from it.
        const shaper = c.hb_ft_font_create_referenced(face) orelse return error.NoShaping;
        errdefer c.hb_font_destroy(shaper);
        const buffer = c.hb_buffer_create() orelse return error.NoShaping;
        if (c.hb_buffer_allocation_successful(buffer) == 0) return error.NoShaping;
        return .{ .allocator = allocator, .library = library, .face = face, .shaper = shaper, .buffer = buffer, .size = size, .id = id };
    }

    fn forget(self: *Font) void {
        var entries = self.runs.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.runs.clearAndFree(self.allocator);
    }

    pub fn deinit(self: *Font) void {
        self.forget();
        c.hb_buffer_destroy(self.buffer);
        c.hb_font_destroy(self.shaper);
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.library);
    }

    /// The distance from one baseline to the next, in pixels.
    pub fn lineHeight(self: *const Font) f32 {
        return @as(f32, @floatFromInt(self.face.*.size.*.metrics.height)) / 64.0;
    }

    /// The glyph's slot, rasterising it into `glyphs` the first time.
    fn slot(self: *Font, allocator: std.mem.Allocator, glyphs: *atlas.Atlas, glyph: u32) Error!atlas.Slot {
        const key: atlas.Key = .{ .font = self.id, .glyph = glyph, .size = self.size };
        if (glyphs.find(key)) |known| return known;
        if (c.FT_Load_Glyph(self.face, glyph, c.FT_LOAD_RENDER) != 0) return error.NoFace;
        const g = self.face.*.glyph;
        const bitmap = g.*.bitmap;
        const pitch: usize = @intCast(@abs(bitmap.pitch));
        const bytes: []const u8 = if (bitmap.buffer) |data| data[0 .. pitch * bitmap.rows] else &.{};
        return (try glyphs.put(allocator, key, bitmap.width, bitmap.rows, pitch, bytes, g.*.bitmap_left, g.*.bitmap_top)) orelse error.AtlasFull;
    }

    /// The run for `utf8`, shaped by HarfBuzz the first time and kept.
    fn shaped(self: *Font, utf8: []const u8) Error![]const Shaped {
        if (self.runs.get(utf8)) |known| return known;
        if (self.runs.count() >= cache_capacity) self.forget();
        c.hb_buffer_clear_contents(self.buffer);
        c.hb_buffer_add_utf8(self.buffer, utf8.ptr, @intCast(utf8.len), 0, @intCast(utf8.len));
        c.hb_buffer_guess_segment_properties(self.buffer);
        c.hb_shape(self.shaper, self.buffer, null, 0);
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(self.buffer, &count);
        const run = try self.allocator.alloc(Shaped, count);
        errdefer self.allocator.free(run);
        for (run, 0..) |*each, index| {
            each.* = .{
                .glyph = infos[index].codepoint,
                .x_offset = @round(@as(f32, @floatFromInt(positions[index].x_offset)) / 64.0),
                .y_offset = @round(@as(f32, @floatFromInt(positions[index].y_offset)) / 64.0),
                .advance = @round(@as(f32, @floatFromInt(positions[index].x_advance)) / 64.0),
            };
        }
        const key = try self.allocator.dupe(u8, utf8);
        errdefer self.allocator.free(key);
        try self.runs.put(self.allocator, key, run);
        return run;
    }

    /// The pen advance of `utf8` in pixels, without drawing it (the run is kept).
    pub fn measure(self: *Font, utf8: []const u8) Error!f32 {
        var width: f32 = 0;
        for (try self.shaped(utf8)) |each| width += each.advance;
        return width;
    }

    /// The longest prefix of `utf8`, cut at a character boundary, that is at most
    /// `limit` pixels wide followed by "…"; `utf8` itself when it fits.
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

    /// Shapes `utf8` and appends its glyphs with the pen starting at `x` on the baseline
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
        var pen: f32 = @round(x);
        const line: f32 = @round(baseline);
        for (run) |each| {
            const placed = try self.slot(allocator, glyphs, each.glyph);
            if (placed.width != 0 and placed.height != 0) {
                try list.glyph(allocator, .{
                    .x = pen + each.x_offset + @as(f32, @floatFromInt(placed.left)),
                    .y = line - each.y_offset - @as(f32, @floatFromInt(placed.top)),
                    .width = @floatFromInt(placed.width),
                    .height = @floatFromInt(placed.height),
                }, placed.uv(), colour);
            }
            pen += each.advance;
        }
        return pen - @round(x);
    }
};
