//! Text on the native path.
//!
//! ## Why Cairo's own text rather than Pango
//!
//! Pango is the better shaper and this module deliberately does not use it, for a
//! reason that is worth stating plainly rather than discovering later: Pango's headers
//! reach through GLib, and GLib uses `_Pragma` in a way Zig 0.16's C translator cannot
//! parse. `@cImport` of `pango/pangocairo.h` fails with `unknown type name 'pragma'`,
//! and defining the macro that guards it does not help, because GLib defines it again
//! itself. That is a property of the toolchain, not a missing dependency.
//!
//! Cairo's toy text API is used instead, and it is enough for this panel: it resolves
//! through fontconfig, it honours a monospace family, and it reports per-glyph advances
//! so a column of figures lines up exactly.
//!
//! ## What it cannot do, stated rather than discovered
//!
//! Cairo's toy API shapes nothing. It does not reorder marks, does not apply
//! ligatures, and does not fall back to another font for a character the chosen face
//! lacks — a combining accent outside Latin will be drawn as a missing glyph rather
//! than composed onto its base. For a panel of labels and numbers in one face, that
//! costs nothing. For a language whose script needs shaping it would be wrong, and the
//! answer there is Pango behind a build that can import it — not a better guess in this
//! file.
//!
//! ## Why the surface is ours
//!
//! Cairo is given our buffer, not one of its own. `cairo_image_surface_create_for_data`
//! wraps memory the caller already has, so a line of type is rasterised straight into
//! the frame that is about to be presented. A Cairo surface of its own followed by a
//! blit would put a second full-frame copy on the path between a layout and a pixel.
//!
//! ## What this costs
//!
//! One image surface, one drawing context, created once. Cairo caches its glyph
//! rasterisations against the image surface, so a panel that redraws the same words
//! every second rasterises nothing new.

const std = @import("std");
const surface = @import("surface.zig");

const cairo = @cImport({
    @cInclude("cairo.h");
});

pub const Error = error{
    /// Cairo refused the buffer, so nothing can be drawn into it.
    SurfaceRefused,
    /// Cairo refused a drawing context for the surface.
    ContextRefused,
};

/// Text on one frame, over that frame's own memory.
pub const Text = struct {
    /// The drawing context, which owns the image surface it was made from. One field
    /// rather than two: the surface is reachable through `cairo_get_target`, and
    /// holding a second reference to it would be one more pointer that could outlive
    /// what it points at.
    context: ?*cairo.cairo_t,
    /// The buffer Cairo draws into, kept so the caller can present the frame without
    /// asking Cairo for it. Cairo does not own this and must not free it.
    pixels: []u8,

    /// Wraps `target`'s buffer so type can be drawn into it.
    ///
    /// `RGB24` rather than `ARGB32` on purpose. The frame formats here are
    /// non-premultiplied and Cairo's alpha formats require premultiplied input, so
    /// asking for one would composite every glyph against a colour the caller never
    /// wrote. An opaque window has nothing to blend, the fourth byte is left as it
    /// was, and the server discards it for a drawable with no alpha visual.
    pub fn init(target: surface.Surface) Error!Text {
        if (target.pixels.len == 0) return error.SurfaceRefused;

        const width: c_int = @intCast(target.size.width);
        const height: c_int = @intCast(target.size.height);
        const stride: c_int = @intCast(target.stride);

        const raw = cairo.cairo_image_surface_create_for_data(
            @ptrCast(@alignCast(target.pixels.ptr)),
            cairo.CAIRO_FORMAT_RGB24,
            width,
            height,
            stride,
        );
        if (cairo.cairo_surface_status(raw) != cairo.CAIRO_STATUS_SUCCESS) {
            _ = cairo.cairo_surface_destroy(raw);
            return error.SurfaceRefused;
        }

        // One context for the whole run rather than one per string: it holds Cairo's
        // operating state and saved stack, so making one per call would put an
        // allocation on the path of every label on the panel.
        const context = cairo.cairo_create(raw);
        if (cairo.cairo_status(context) != cairo.CAIRO_STATUS_SUCCESS) {
            _ = cairo.cairo_surface_destroy(raw);
            return error.ContextRefused;
        }

        // Resolved through fontconfig rather than a path, so the same source renders on
        // a machine with a different set installed. Monospaced because the panel sets
        // figures on a fixed measure and a proportional face would break the column.
        cairo.cairo_select_font_face(
            context,
            "monospace",
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(context, default_size_pt);

        return .{
            .context = context,
            .pixels = target.pixels,
        };
    }

    /// Points the text at `target` again after the frame was resized.
    ///
    /// Cairo's image surface is a view of one buffer at one stride; a resized `Surface`
    /// has a new stride and, when it grew, a new buffer. Kept on the old view, text was
    /// drawn with the old row length (sheared lines in a real window) or into freed
    /// memory. The face and size carry over, so the caller sees no change but the frame.
    pub fn retarget(self: *Text, target: surface.Surface) Error!void {
        const next = try Text.init(target);
        if (self.context) |old| {
            if (next.context) |fresh| {
                cairo.cairo_set_font_face(fresh, cairo.cairo_get_font_face(old));
                var matrix: cairo.cairo_matrix_t = undefined;
                cairo.cairo_get_font_matrix(old, &matrix);
                cairo.cairo_set_font_matrix(fresh, &matrix);
            }
        }
        self.deinit();
        self.* = next;
    }

    /// The size a panel starts with, in Cairo's points.
    ///
    /// Points, not pixels, because that is what Cairo's API takes. The scale factor
    /// between them is the display's, and at the usual desktop settings they coincide
    /// closely enough that a grid measured from one is right on the other.
    const default_size_pt: f64 = 11.0;

    /// Releases the Cairo objects. The frame buffer is untouched: it is the caller's,
    /// and Cairo never owned it.
    pub fn deinit(self: *Text) void {
        if (self.context) |context| _ = cairo.cairo_destroy(context);
        self.* = undefined;
    }

    /// Sets the typeface and size, by family name and points.
    pub fn setFace(self: *Text, family: [*:0]const u8, points: f64) void {
        const context = self.context orelse return;

        cairo.cairo_select_font_face(
            context,
            family,
            cairo.CAIRO_FONT_SLANT_NORMAL,
            cairo.CAIRO_FONT_WEIGHT_NORMAL,
        );
        cairo.cairo_set_font_size(self.context, points);
    }

    /// Where one string sits and how big it is, in pixels.
    ///
    /// `y_bearing` is the distance from the baseline up to the top of the tallest
    /// glyph, and `height` covers the ascent and descent of the face rather than of
    /// this string — which is what makes every row the same height, which is the
    /// point of a grid set on a baseline.
    pub const Extent = struct {
        width: i32,
        height: i32,
        ascent: i32,
        descent: i32,
    };

    /// The longest string this module will draw.
    ///
    /// Cairo's text calls take a NUL-terminated string, so a slice has to be copied
    /// and terminated before it can be handed over. The copy goes in a caller-provided
    /// stack buffer, which means the limit is a compile-time constant rather than an
    /// allocation — and a string past it is refused rather than truncated, because a
    /// label cut off mid-word on a panel of measurements is a wrong number, not a
    /// cosmetic problem.
    pub const max_bytes: usize = 256;

    /// Measures `text` without drawing it.
    ///
    /// Returns null when the text is longer than [`max_bytes`], so a caller can decide
    /// what to do rather than measuring a truncated string and believing it.
    pub fn measure(self: *Text, text: []const u8) ?Extent {
        const context = self.context orelse return null;

        var storage: [max_bytes]u8 = undefined;
        const terminated = terminate(text, &storage) orelse return null;

        var extents: cairo.cairo_text_extents_t = undefined;
        cairo.cairo_text_extents(context, terminated.ptr, &extents);

        // The face's own ascent and descent rather than this string's. A row reading
        // "ns" and a row reading "resident set" then occupy the same band, which is
        // what makes a grid set on a baseline line up; taking the height from the
        // string would make the short rows shorter and the table would step.
        var font: cairo.cairo_font_extents_t = undefined;
        cairo.cairo_font_extents(context, &font);

        return .{
            .width = @intFromFloat(@round(extents.x_advance)),
            .height = @intFromFloat(@round(font.ascent + font.descent)),
            .ascent = @intFromFloat(@round(font.ascent)),
            .descent = @intFromFloat(@round(font.descent)),
        };
    }

    /// Draws `text` with its baseline starting at (`x`, `y`).
    ///
    /// The origin is the baseline because that is the only origin a grid can be set
    /// from: the caller says where the line sits and the font decides where within it
    /// the letters fall.
    ///
    /// Returns false when the text is too long to draw, so a caller that cares can
    /// see that a label was dropped rather than finding a gap later.
    pub fn draw(self: *Text, x: i32, y: i32, text: []const u8, colour: surface.Colour) bool {
        const context = self.context orelse return false;

        var storage: [max_bytes]u8 = undefined;
        const terminated = terminate(text, &storage) orelse return false;

        cairo.cairo_set_source_rgba(
            context,
            @as(f64, @floatFromInt(colour.r)) / 255.0,
            @as(f64, @floatFromInt(colour.g)) / 255.0,
            @as(f64, @floatFromInt(colour.b)) / 255.0,
            @as(f64, @floatFromInt(colour.a)) / 255.0,
        );

        cairo.cairo_move_to(context, @floatFromInt(x), @floatFromInt(y));
        cairo.cairo_show_text(context, terminated.ptr);

        // Flushed rather than finished: `finish` would be right once and wrong for
        // every string after it, and the frame is read from this buffer directly.
        _ = cairo.cairo_surface_flush(cairo.cairo_get_target(context));

        return true;
    }

    /// The advance width of `text`, for laying a row out in columns. Zero when the
    /// text is too long, which a layout reads as "no column here" rather than as a
    /// measurement.
    pub fn widthOf(self: *Text, text: []const u8) i32 {
        const extent = self.measure(text) orelse return 0;
        return extent.width;
    }
};

/// Copies `text` into `storage` with a terminating NUL, or null when it will not fit.
///
/// The bound leaves room for the NUL itself, so a string of exactly `max_bytes` is
/// refused: `storage[max_bytes - 1]` would be the terminator and the last byte would
/// be lost, and a string that lost its last byte silently is worse than one refused.
fn terminate(text: []const u8, storage: *[Text.max_bytes]u8) ?[:0]const u8 {
    if (text.len + 1 > Text.max_bytes) return null;

    @memcpy(storage[0..text.len], text);
    storage[text.len] = 0;

    return storage[0..text.len :0];
}
