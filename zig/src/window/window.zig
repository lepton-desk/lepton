//! What a window is, independent of the window system behind it.
//!
//! The two render modes do not share a window implementation, but they do share
//! what a caller asks of one: a size, a title, a place to put pixels, and a way
//! to learn that the system wants something different. That contract lives here
//! so the surface that drives the window and the backend that fulfils it never
//! both define it.
//!
//! Dimensions are in physical pixels, not logical ones. On a scaled display the
//! two differ, and a framebuffer is addressed in physical pixels; keeping one unit
//! throughout the layer is what stops a scaled display from producing a window
//! that is the wrong size by exactly the scale factor.

const std = @import("std");
const builtin = @import("builtin");

/// The native render path's window on Windows (`windows/native_window.zig`); absent
/// elsewhere. Reached from here so a probe rooted at this file can open one.
pub const win32 = if (builtin.os.tag == .windows) @import("windows/native_window.zig") else struct {};

pub const Error = error{
    /// The window system refused the size, usually because it exceeds what the
    /// display can offer.
    SizeRefused,
    /// The window system asked for a state the layer does not implement yet.
    UnsupportedState,

    /// A GPU presenter accepted this window and then failed to draw or hand over a frame.
    ///
    /// Distinct from a refusal at open time, which is a normal answer and sends the frame
    /// down the shared-memory path instead. This one means the GPU path was chosen and
    /// then broke, so it is a fault rather than a fallback.
    GpuRefused,
    /// The connection to the display server was lost mid-flight.
    DisplayLost,
    /// The frame handed to `present` is smaller than the size it claims.
    ///
    /// Its own variant because the two look identical from outside and are fixed
    /// differently: a `SizeRefused` is the window system saying no, and this is the
    /// renderer and the window disagreeing about how big the window is — which is a
    /// bug in the renderer, not a refusal by the server.
    FrameTruncated,
};

/// Physical pixels.
pub const Size = struct {
    width: u32,
    height: u32,

    pub fn isEmpty(self: Size) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Bytes per row for a given pixel format, rounded up as a buffer stride must
    /// be. Rounding here rather than at each use site is what keeps a stride from
    /// drifting from the width it was computed for.
    pub fn stride(self: Size, format: PixelFormat) usize {
        return std.mem.alignForward(usize, self.width * format.bytesPerPixel(), format.alignment());
    }

    /// Bytes a full framebuffer of this size occupies.
    pub fn frameBytes(self: Size, format: PixelFormat) usize {
        return self.stride(format) * self.height;
    }
};

/// Where the window is on the display, in physical pixels.
pub const Position = struct {
    x: i32,
    y: i32,
};

/// The pixel layouts the layer can put bytes into.
///
/// Both are 32-bit and both are what a display server and a compositor actually
/// accept. `argb` is listed first because it carries alpha; `xrgb` is preferred
/// when the surface is opaque, because an opaque window that carries an alpha
/// channel costs a channel nobody reads.
pub const PixelFormat = enum {
    argb8888,
    xrgb8888,

    /// Both formats are 32 bits wide, which is why a stride only ever rounds.
    pub const bits_per_pixel: usize = 32;

    pub fn bytesPerPixel(_: PixelFormat) usize {
        return bits_per_pixel / 8;
    }

    /// Stride alignment a buffer of this format requires. Both formats need a
    /// four-byte boundary, which any 32-bit pixel count already satisfies, so this
    /// is a named constant rather than a per-format decision.
    pub fn alignment(_: PixelFormat) usize {
        return 4;
    }

    /// The word a caller writes into a framebuffer for one fully opaque pixel.
    ///
    /// Composed from shifted bytes rather than written as a hex literal, because
    /// `0xAARRGGBB` is not a number Zig can parse — the channel letters are a
    /// notation, not digits. Stored little-endian, so the bytes land blue, green,
    /// red, alpha in memory, which is the order the display server reads.
    pub fn pixelWord(self: PixelFormat) u32 {
        const blue: u32 = 0xBB;
        const green: u32 = 0x88;
        const red: u32 = 0x88;
        const alpha: u32 = switch (self) {
            // An opaque window that carries an alpha channel spends a channel
            // nobody reads, so the opaque format leaves it zero: that is also what
            // tells the server there is no transparency to blend.
            .argb8888 => 0xFF,
            .xrgb8888 => 0x00,
        };
        return (alpha << 24) | (red << 16) | (green << 8) | blue;
    }
};

/// What the window system has asked for.
pub const Configure = struct {
    /// The size the window system wants. Zero on either axis means "you choose",
    /// which is what a compositor sends before the first real configure.
    size: Size,
    /// True when the window system has decided the size and is not asking.
    activated: bool = false,
};

/// A window, as the layer above the backends sees it.
pub const Window = struct {
    /// The backend that fulfils requests. Not a vtable: each backend is a
    /// distinct type behind this handle, and `backend` is which one.
    backend: Backend,

    /// The window systems of the system this is built for: Win32 on Windows, Wayland and
    /// X11 elsewhere. Chosen at compile time, so a Windows build never analyses the Linux
    /// backends (their headers translate to nothing there) and a Linux build is unchanged.
    pub const Backend = if (builtin.os.tag == .windows) Win32Backend else LinuxBackend;

    pub const Win32Backend = union(enum) {
        win32: *anyopaque,

        const native = @import("windows/native_window.zig");

        pub fn resize(w: Win32Backend, requested: Size) Error!void {
            return native.resize(w.win32, requested);
        }

        pub fn title(w: Win32Backend, text: []const u8) Error!void {
            return native.setTitle(w.win32, text);
        }

        pub fn size(w: Win32Backend) Size {
            return native.currentSize(w.win32);
        }

        pub fn wait(w: Win32Backend, timeout_ms: i32) Error!void {
            return native.wait(w.win32, timeout_ms);
        }

        pub fn presentPixels(w: Win32Backend, pixels: []const u8, frame: Size, format: PixelFormat) Error!void {
            return native.presentPixels(w.win32, pixels, frame, format);
        }

        pub fn takeConfigure(w: Win32Backend) ?Configure {
            return native.takeConfigure(w.win32);
        }
    };

    pub const LinuxBackend = union(enum) {
        wayland: *anyopaque,
        x11: *anyopaque,

        /// Forwards a call to whichever backend this window has. Dispatching on
        /// the tag here is what keeps `Window` from growing one method per backend
        /// and becoming a wrapper around both.
        pub fn resize(w: Backend, requested: Size) Error!void {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").resize(@ptrCast(@alignCast(w.wayland)), requested),
                .x11 => @import("linux/x11_window.zig").resize(@ptrCast(@alignCast(w.x11)), requested),
            };
        }

        pub fn title(w: Backend, text: []const u8) Error!void {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").setTitle(@ptrCast(@alignCast(w.wayland)), text),
                .x11 => @import("linux/x11_window.zig").setTitle(@ptrCast(@alignCast(w.x11)), text),
            };
        }

        /// The size the window currently occupies, which after a compositor
        /// resize is whatever the window system last asked for.
        pub fn size(w: Backend) Size {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").currentSize(@ptrCast(@alignCast(w.wayland))),
                .x11 => @import("linux/x11_window.zig").currentSize(@ptrCast(@alignCast(w.x11))),
            };
        }

        /// Waits for the next event from the display server.
        pub fn wait(w: Backend, timeout_ms: i32) Error!void {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").wait(@ptrCast(@alignCast(w.wayland)), timeout_ms),
                .x11 => @import("linux/x11_window.zig").wait(@ptrCast(@alignCast(w.x11)), timeout_ms),
            };
        }

        /// Shows a rendered frame.
        ///
        /// The window layer's whole drawing interface, and it is deliberately only
        /// that: pixels in, nothing out. A renderer that knew about surfaces or
        /// drawables would need a branch per backend, and the pure native path would
        /// carry a dependency on a window-system protocol in order to fill a
        /// rectangle.
        ///
        /// `pixels` is one frame of `size` in `format`. A frame from a renderer that
        /// believes the window is a different size is refused rather than truncated,
        /// because a truncated frame looks like a drawing bug.
        pub fn presentPixels(w: Backend, pixels: []const u8, frame: Size, format: PixelFormat) Error!void {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").presentPixels(@ptrCast(@alignCast(w.wayland)), pixels, frame, format),
                .x11 => @import("linux/x11_window.zig").presentPixels(@ptrCast(@alignCast(w.x11)), pixels, frame, format),
            };
        }

        /// Takes the pending configure, if the display server sent one.
        pub fn takeConfigure(w: Backend) ?Configure {
            return switch (w) {
                .wayland => @import("linux/wayland_window.zig").takeConfigure(@ptrCast(@alignCast(w.wayland))),
                .x11 => @import("linux/x11_window.zig").takeConfigure(@ptrCast(@alignCast(w.x11))),
            };
        }
    };

    pub fn resize(self: *Window, requested: Size) Error!void {
        return self.backend.resize(requested);
    }

    pub fn setTitle(self: *Window, text: []const u8) Error!void {
        return self.backend.title(text);
    }

    pub fn size(self: *Window) Size {
        return self.backend.size();
    }

    /// Blocks until the display server has something to say, or the timeout
    /// elapses. A negative timeout waits indefinitely.
    pub fn wait(self: *Window, timeout_ms: i32) Error!void {
        return self.backend.wait(timeout_ms);
    }

    /// The configure the display server sent, or null when it sent none. Taking
    /// it clears it, so a resize is acted on exactly once.
    pub fn takeConfigure(self: *Window) ?Configure {
        return self.backend.takeConfigure();
    }

    /// Shows a frame the render layer produced.
    pub fn present(self: *Window, pixels: []const u8, frame: Size, format: PixelFormat) Error!void {
        return self.backend.presentPixels(pixels, frame, format);
    }
};

/// What a caller asks for when opening a window.
pub const Request = struct {
    title: []const u8 = "Lepton",
    /// Identifier the desktop uses to match the window to its application icon
    /// and entry. Not decoration: it is how a window manager groups windows.
    app_id: []const u8 = "dev.lepton.app",
    size: Size = .{ .width = 1200, .height = 800 },
    format: PixelFormat = .argb8888,
    /// Whether `open` shows the window. False leaves it to the window's `map`, after its
    /// size and place are set: an X window manager places a window when it is mapped and
    /// keeps it there (measured on COSMIC's XWayland).
    mapped: bool = true,
    /// The colour the window's content starts with at its top, for a title bar the system
    /// draws (Windows): dark or light to match on Windows 10, this colour on Windows 11.
    /// Null keeps the system's. Linux's native windows draw their own bar and ignore it.
    title_colour: ?[3]u8 = null,
    /// How often frames are drawn (`Pacing`).
    pacing: Pacing = .display,
};

/// How often the native path draws a frame. `display` follows the screen's refresh (every
/// frame drawn is shown); `unlimited` draws as fast as the machine can, for those who want
/// the number — frames the screen cannot show are dropped or torn, and the CPU or GPU runs
/// flat out. Chosen in `lepton.config.json` (`window.frameRate`), overridden at run time by
/// `LEPTON_FRAME_RATE=display|unlimited` (`Pacing.chosen`).
pub const Pacing = enum {
    display,
    unlimited,

    /// `built` unless `LEPTON_FRAME_RATE` names the other one; an unknown value keeps `built`.
    pub fn chosen(built: Pacing) Pacing {
        const name = std.c.getenv("LEPTON_FRAME_RATE") orelse return built;
        return std.meta.stringToEnum(Pacing, std.mem.span(name)) orelse built;
    }
};

test {
    _ = @import("window_test.zig");
}
