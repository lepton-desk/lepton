//! A frame the render layer draws into.
//!
//! ## Why this exists
//!
//! The window layer opens windows and shows buffers; the render layer draws. Neither
//! should know about the other. If the renderers were handed a Wayland surface or an
//! X11 drawable, every one of them would need both backends, and the pure native path
//! would carry a dependency on a window system protocol in order to fill a rectangle.
//!
//! So the boundary is a plain `[]u8` of 32-bit pixels. A renderer fills it, the
//! window layer presents it. That is also why the native path's memory cost is a
//! function of the window's size and nothing else: one framebuffer, allocated once,
//! reused for every frame.
//!
//! ## Allocation
//!
//! The buffer is owned by the surface and reused across frames. A desktop application
//! repaints on every event, and a frame that allocated would put the allocator on the
//! path between a window event and a pixel reaching the screen — which is the thing
//! the whole framework is built to keep short.

const std = @import("std");
const window = @import("../window/window.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The requested size is not a size a framebuffer can have.
    ///
    /// Zero on either axis is refused rather than producing an empty frame: a window
    /// reports zero while a compositor is still deciding, and allocating for it would
    /// allocate nothing and then write to it.
    InvalidSize,
    /// The allocator refused.
    OutOfMemory,
};

/// One frame of pixels, in a fixed layout.
pub const Surface = struct {
    pixels: []u8,
    size: window.Size,
    format: window.PixelFormat,
    stride: usize,
    allocator: Allocator,

    /// Allocates a surface for `size`, without drawing anything into it.
    pub fn init(
        allocator: Allocator,
        size: window.Size,
        format: window.PixelFormat,
    ) Error!Surface {
        if (size.isEmpty()) {
            return Error.InvalidSize;
        }

        const stride = size.stride(format);
        // `alloc` rather than `calloc`: the first frame is filled before it is
        // presented, so zeroing a megabyte to overwrite it a moment later is work
        // done for nothing on the slowest path in the application.
        const pixels = try allocator.alloc(u8, stride * size.height);

        return .{
            .pixels = pixels,
            .size = size,
            .format = format,
            .stride = stride,
            .allocator = allocator,
        };
    }

    /// Releases the buffer.
    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.pixels);
        self.pixels = &[_]u8{};
        self.size = .{ .width = 0, .height = 0 };
    }

    /// Resizes, keeping the buffer if the new size fits in the old allocation.
    ///
    /// Reallocation only when it has to: a window being dragged sends a configure
    /// every frame, and reallocating per frame would put the allocator back on the
    /// event path that this whole design exists to keep clear.
    pub fn resize(self: *Surface, size: window.Size) Error!void {
        if (size.isEmpty()) {
            return Error.InvalidSize;
        }

        const stride = size.stride(self.format);
        const needed = stride * size.height;

        if (needed > self.pixels.len) {
            self.allocator.free(self.pixels);
            self.pixels = self.allocator.alloc(u8, needed) catch {
                // The old buffer is already gone at this point, so the surface is
                // left empty rather than pointing at freed memory. A surface that
                // reports zero size is one the caller can see and act on.
                self.pixels = &[_]u8{};
                self.size = .{ .width = 0, .height = 0 };
                self.stride = 0;
                return Error.OutOfMemory;
            };
        }

        self.size = size;
        self.stride = stride;
    }

    /// The byte offset of one pixel, or null when it lies outside the frame.
    pub fn offsetOf(self: Surface, x: u32, y: u32) ?usize {
        if (x >= self.size.width or y >= self.size.height) {
            return null;
        }
        return y * self.stride + x * self.format.bytesPerPixel();
    }

    /// One pixel as a colour word, or null when it lies outside the frame.
    ///
    /// Read as a single 32-bit word rather than four bytes because the formats are
    /// defined as 32-bit and a four-byte read would be an alignment assumption the
    /// stride does not promise for every x.
    pub fn pixelAt(self: Surface, x: u32, y: u32) ?Colour {
        const offset = self.offsetOf(x, y) orelse return null;
        const word = std.mem.readInt(u32, self.pixels[offset..][0..4], .little);
        return Colour.fromWord(word, self.format);
    }

    /// Writes one pixel.
    pub fn setPixel(self: Surface, x: u32, y: u32, colour: Colour) Error!void {
        const offset = self.offsetOf(x, y) orelse return Error.InvalidSize;
        std.mem.writeInt(u32, self.pixels[offset..][0..4], colour.toWord(self.format), .little);
    }

    /// Fills the whole frame with one colour.
    ///
    /// Row by row rather than as one run over the whole buffer. With the 32-bit
    /// formats this layer supports today the stride is exactly the visible width in
    /// bytes, so the two are the same work; the row loop exists because that is a
    /// property of the current formats and not of the loop, and a format with a
    /// wider alignment would otherwise paint bytes past the last pixel.
    pub fn fill(self: Surface, colour: Colour) void {
        const word = colour.toWord(self.format);
        const bytes = std.mem.asBytes(&word);
        const per_pixel = self.format.bytesPerPixel();

        var y: u32 = 0;
        while (y < self.size.height) : (y += 1) {
            const row_start = y * self.stride;
            var x: usize = 0;
            while (x < self.size.width * per_pixel) : (x += per_pixel) {
                @memcpy(self.pixels[row_start + x ..][0..per_pixel], bytes);
            }
        }
    }

    /// Fills a rectangle, clipped to the frame.
    ///
    /// Clipping here rather than in every caller: a panel that runs past the edge of
    /// a window a compositor just resized is the normal case, not an error, and it is
    /// exactly the case that a layout bug would turn into a heap overflow.
    pub fn fillRect(self: Surface, x: i32, y: i32, width: i32, height: i32, colour: Colour) void {
        const clipped = clip(self, x, y, width, height) orelse return;
        const word = colour.toWord(self.format);
        const bytes = std.mem.asBytes(&word);
        const per_pixel = self.format.bytesPerPixel();

        var row: u32 = clipped.y;
        while (row < clipped.y + clipped.height) : (row += 1) {
            const row_start = row * self.stride + clipped.x * per_pixel;
            var offset: usize = 0;
            while (offset < clipped.width * per_pixel) : (offset += per_pixel) {
                @memcpy(self.pixels[row_start + offset ..][0..per_pixel], bytes);
            }
        }
    }

    /// A horizontal rule one pixel tall.
    ///
    /// Its own method because a hairline is the most-requested primitive in a layout
    /// built on a baseline grid, and each call site getting the rounding right is
    /// three places to be wrong.
    pub fn hLine(self: Surface, x: i32, y: i32, length: i32, colour: Colour) void {
        self.fillRect(x, y, length, 1, colour);
    }

    /// A vertical rule one pixel wide.
    pub fn vLine(self: Surface, x: i32, y: i32, length: i32, colour: Colour) void {
        self.fillRect(x, y, 1, length, colour);
    }

    /// An unfilled rectangle outline, one pixel wide.
    pub fn strokeRect(self: Surface, x: i32, y: i32, width: i32, height: i32, colour: Colour) void {
        if (width <= 0 or height <= 0) {
            return;
        }
        self.hLine(x, y, width, colour);
        self.hLine(x, y + height - 1, width, colour);
        self.vLine(x, y, height, colour);
        self.vLine(x + width - 1, y, height, colour);
    }
};

/// A rectangle in surface coordinates.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Clips a rectangle to the frame, or null when it lies entirely outside.
///
/// Signed in and unsigned out because the caller thinks in layout coordinates that
/// may be negative, and the buffer indexer needs a position that is known to be
/// inside. The conversion is where the sign is dealt with, once.
pub fn clip(surface: Surface, x: i32, y: i32, width: i32, height: i32) ?Rect {
    if (width <= 0 or height <= 0) {
        return null;
    }

    // Clamped against the frame in the caller's coordinates first, so an overflow of
    // `x + width` cannot wrap before it is compared.
    const left = @max(x, 0);
    const top = @max(y, 0);
    const right = @min(x +| width, @as(i32, @intCast(surface.size.width)));
    const bottom = @min(y +| height, @as(i32, @intCast(surface.size.height)));

    if (right <= left or bottom <= top) {
        return null;
    }

    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

/// A colour, independent of any pixel format.
///
/// Channels are 8-bit because that is what a 32-bit pixel carries and what cairo
/// asks for, and doubling the work at the boundary of every conversion is how a red
/// channel ends up at 0xAA instead of 0xFF.
pub const Colour = struct {
    r: u8,
    g: u8,
    b: u8,
    /// Ignored for a format with no alpha, and carried anyway so one colour can be
    /// reused across both without the caller knowing which format it is heading for.
    a: u8 = 0xFF,

    /// Builds from 8-bit channels.
    pub fn rgb(r: u8, g: u8, b: u8) Colour {
        return .{ .r = r, .g = g, .b = b, .a = 0xFF };
    }

    /// Builds from a colour with alpha.
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Colour {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Unpacks a pixel word read out of a frame.
    pub fn fromWord(word: u32, format: window.PixelFormat) Colour {
        return switch (format) {
            .argb8888 => .{
                .a = @truncate(word >> 24),
                .r = @truncate(word >> 16),
                .g = @truncate(word >> 8),
                .b = @truncate(word),
            },
            .xrgb8888 => .{
                .a = 0xFF,
                .r = @truncate(word >> 16),
                .g = @truncate(word >> 8),
                .b = @truncate(word),
            },
        };
    }

    /// Packs into a pixel word for a format.
    ///
    /// The opaque formats write zero into the alpha byte. That is not the same as
    /// writing 0xFF: the server reads a zero alpha as "there is nothing to blend",
    /// and a window that reports opaque but is written as translucent gets composited
    /// for no reason.
    pub fn toWord(self: Colour, format: window.PixelFormat) u32 {
        const alpha: u32 = switch (format) {
            .argb8888 => self.a,
            .xrgb8888 => 0x00,
        };
        return (alpha << 24) | (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }

    /// This colour at a different opacity, for a fill behind text.
    pub fn withAlpha(self: Colour, alpha: u8) Colour {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
    }
};

test {
    _ = @import("surface_test.zig");
}
