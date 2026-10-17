//! Text for the draw command list: HarfBuzz shapes, FreeType rasterises, the atlas keeps.
//!
//! `Font.draw` shapes a UTF-8 run (ligatures, kerning, any script HarfBuzz knows), puts
//! each glyph it has not seen at this size into the atlas once, and appends one
//! `scene.Kind.glyph` instance per glyph. Pens are rounded to whole pixels, so a glyph's
//! one rasterisation is reused wherever it appears. The font file is found through
//! fontconfig (`find`), as the desktop finds it.

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

pub const Font = struct {
    library: c.FT_Library,
    face: c.FT_Face,
    shaper: *c.hb_font_t,
    buffer: *c.hb_buffer_t,
    /// Pixel size; part of every atlas key.
    size: u32,
    /// Tells this font's glyphs from another's in the atlas.
    id: u32,

    pub fn open(path: [:0]const u8, size: u32, id: u32) Error!Font {
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
        return .{ .library = library, .face = face, .shaper = shaper, .buffer = buffer, .size = size, .id = id };
    }

    pub fn deinit(self: *Font) void {
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
        c.hb_buffer_clear_contents(self.buffer);
        c.hb_buffer_add_utf8(self.buffer, utf8.ptr, @intCast(utf8.len), 0, @intCast(utf8.len));
        c.hb_buffer_guess_segment_properties(self.buffer);
        c.hb_shape(self.shaper, self.buffer, null, 0);
        var count: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(self.buffer, &count);
        if (count == 0) return 0;

        var pen: f32 = @round(x);
        const line: f32 = @round(baseline);
        for (infos[0..count], positions[0..count]) |info, position| {
            const placed = try self.slot(allocator, glyphs, info.codepoint);
            if (placed.width != 0 and placed.height != 0) {
                const left = pen + @round(@as(f32, @floatFromInt(position.x_offset)) / 64.0) + @as(f32, @floatFromInt(placed.left));
                const top = line - @round(@as(f32, @floatFromInt(position.y_offset)) / 64.0) - @as(f32, @floatFromInt(placed.top));
                try list.glyph(allocator, .{
                    .x = left,
                    .y = top,
                    .width = @floatFromInt(placed.width),
                    .height = @floatFromInt(placed.height),
                }, placed.uv(), colour);
            }
            pen += @round(@as(f32, @floatFromInt(position.x_advance)) / 64.0);
        }
        return pen - @round(x);
    }
};
