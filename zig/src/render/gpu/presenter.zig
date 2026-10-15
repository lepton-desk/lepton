//! Choosing how a finished frame reaches the screen, once, at open time.
//!
//! ## The choice being made
//!
//! A frame can be shown two ways here: by the GPU, or by copying it into a shared-memory
//! buffer and letting the compositor draw it. They are two presentations of the same
//! pixels, not two renderers — the drawing is the same either way, which is why the
//! drawing lives in `gl_renderer` and this module only decides where the result goes.
//!
//! The choice is made once, when the window opens, and then kept. Not because a frame
//! should never be re-tried — but because a driver that refuses one window surface will
//! refuse the next one identically, and re-asking every frame would spend the whole frame
//! budget collecting the same refusal.
//!
//! ## Why the fallback is not a degraded path
//!
//! It draws the same pixels through the same code and shows them with the same window. It
//! is slower per frame and nothing else, and reporting it as a fallback rather than an
//! error is what makes the GPU the default: a machine where the GPU refuses must still
//! show its window, quietly, with the reason recorded.

const std = @import("std");

const gl = @import("gl_renderer.zig");

const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("GLES2/gl2.h");
    // The Wayland types are the caller's connection and surface; nothing here creates
    // them, so the dependency is on the headers alone.
    @cInclude("wayland-client.h");
    // The native window EGL's Wayland platform takes. A bare `wl_surface` is *not* one:
    // Mesa reads the handle as a `struct wl_egl_window`, so passing the surface was
    // undefined behaviour that surfaced as a refused window surface.
    @cInclude("wayland-egl.h");
});

/// `eglCreateWindowSurface` is declared here rather than imported, for one reason:
/// `eglplatform.h` resolves `EGLNativeWindowType` to `unsigned long` on this machine
/// while the Wayland driver expects a `struct wl_surface *`. Both are one word on the
/// ABI, so passing the handle as a pointer is the call the driver wants and passing it
/// through the header's own typedef is the one it answers `EGL_BAD_ATTRIBUTE` to.
const eglCreateWindowSurface = @extern(
    *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*const c.EGLint) callconv(.c) ?*anyopaque,
    .{ .name = "eglCreateWindowSurface" },
);

const egl_platform_wayland: c.EGLint = 0x31D8;

const getenv = @extern(
    *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8,
    .{ .name = "getenv" },
);

/// The variable that chooses the presentation: `shm` or `gpu` (the default).
///
/// A switch rather than a fixed default because the two cost different things and neither
/// wins on both, measured on the reference machine (radeonsi, ReleaseSmall, 910x458):
/// the GPU path holds 85 MB resident against 21 MB for shared memory, and ~64 MB of the
/// difference is Mesa itself — `libLLVM` 33 MB and `libgallium` 13 MB mapped, ~14 MB of
/// driver heap — which no Mesa variable tried moved. The drawing is on the CPU either way,
/// so an application that cares about memory more than upload cost can say so.
pub const variable = "LEPTON_PRESENT";

pub const Choice = enum { gpu, shm };

/// Reads the choice from a value of `LEPTON_PRESENT`.
///
/// An unrecognised value keeps the default but returns `unknown` with it, so a typo is
/// reported rather than quietly meaning "gpu" — the option that is accepted and never read
/// is the bug this project keeps finding.
pub fn choose(value: ?[]const u8) struct { choice: Choice, unknown: bool } {
    const text = value orelse return .{ .choice = .gpu, .unknown = false };
    if (std.mem.eql(u8, text, "shm")) return .{ .choice = .shm, .unknown = false };
    if (std.mem.eql(u8, text, "gpu")) return .{ .choice = .gpu, .unknown = false };
    return .{ .choice = .gpu, .unknown = true };
}

/// The choice this process was started with.
pub fn requested() Choice {
    const raw = getenv(variable);
    const value: ?[]const u8 = if (raw) |text| std.mem.span(text) else null;
    const answer = choose(value);
    if (answer.unknown) {
        std.log.warn("{s}={s} is not shm or gpu; presenting with gpu", .{ variable, value orelse "" });
    }
    return answer.choice;
}

/// A GPU presenter bound to one window.
///
/// Holding this at all means the window surface was accepted. The refusal that sends a
/// machine to the fallback is recorded by `open`, not by this type.
pub const Presenter = struct {
    egl_window: *c.wl_egl_window,
    width: u32,
    height: u32,
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
    renderer: gl.Renderer,

    pub fn deinit(self: *Presenter) void {
        self.renderer.deinit();
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglDestroySurface(self.display, self.surface);
        _ = c.eglTerminate(self.display);
        c.wl_egl_window_destroy(self.egl_window);
    }

    /// Draws the frame and hands it to the compositor.
    ///
    /// A frame of a new size resizes the native window first, so the next swap allocates
    /// buffers of the size the compositor configured.
    pub fn present(self: *Presenter, pixels: []const u8, width: u32, height: u32) !void {
        if (width != self.width or height != self.height) {
            c.wl_egl_window_resize(self.egl_window, @intCast(width), @intCast(height), 0, 0);
            self.width = width;
            self.height = height;
        }
        try gl.drawFrame(&self.renderer, pixels, @intCast(width), @intCast(height));
        if (c.eglSwapBuffers(self.display, self.surface) == 0) return error.SwapRefused;
    }
};

/// Why the GPU path is not available.
///
/// Carried rather than discarded because a machine that fell back should be able to say
/// what the driver said when it said no, and `EGL_BAD_ATTRIBUTE` without its source is
/// the difference between a report and a shrug.
pub const Refusal = enum {
    /// The driver would not give this window an EGL surface at all.
    no_window_surface,

    /// A surface came, but nothing could be drawn into it.
    no_context,
};

/// Attempts a GPU presenter for this window.
///
/// Returns null when the driver refuses, which is a normal answer on this machine and not
/// an error: the same refusal was measured for a bare `wl_surface` that owes nothing to
/// any window code, so it is the driver declining window surfaces generally.
pub fn open(
    wl_display: ?*c.wl_display,
    wl_surface: ?*c.wl_surface,
    width: u32,
    height: u32,
) ?Presenter {
    // Asked before any EGL call: `eglGetPlatformDisplay` is what loads the driver, and the
    // driver's mappings are the memory this switch exists to avoid.
    if (requested() == .shm) return null;
    const display_handle = wl_display orelse return null;
    const surface_handle = wl_surface orelse return null;
    if (width == 0 or height == 0) return null;
    const egl_window = c.wl_egl_window_create(surface_handle, @intCast(width), @intCast(height)) orelse return null;
    // Every refusal below hands the native window back; the presenter owns it on success.
    var owned = true;
    defer if (owned) c.wl_egl_window_destroy(egl_window);

    const display = c.eglGetPlatformDisplay(egl_platform_wayland, display_handle, null);
    if (display == c.EGL_NO_DISPLAY) return null;

    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(display, &major, &minor) == 0) return null;

    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var config_count: c.EGLint = 0;
    if (c.eglChooseConfig(display, &attributes, &config, 1, &config_count) == 0 or config_count == 0) {
        return null;
    }

    const window_surface = eglCreateWindowSurface(
        display,
        config,
        @ptrCast(egl_window),
        null,
    );
    if (window_surface == null) {
        _ = c.eglTerminate(display);
        return null;
    }

    const context_attributes = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attributes);
    if (context == c.EGL_NO_CONTEXT) {
        _ = c.eglDestroySurface(display, window_surface);
        _ = c.eglTerminate(display);
        return null;
    }

    // The renderer borrows the EGL objects; this struct owns and destroys them.
    const renderer = gl.attach(display, window_surface, context) catch {
        _ = c.eglDestroyContext(display, context);
        _ = c.eglDestroySurface(display, window_surface);
        _ = c.eglTerminate(display);
        return null;
    };

    owned = false;
    return Presenter{
        .egl_window = egl_window,
        .width = width,
        .height = height,
        .display = display,
        .surface = window_surface,
        .context = context,
        .renderer = renderer,
    };
}

test "LEPTON_PRESENT picks shm only when asked, and flags a value it does not know" {
    try std.testing.expectEqual(Choice.gpu, choose(null).choice);
    try std.testing.expectEqual(Choice.shm, choose("shm").choice);
    try std.testing.expectEqual(Choice.gpu, choose("gpu").choice);
    try std.testing.expect(!choose("shm").unknown);
    const typo = choose("shmm");
    try std.testing.expectEqual(Choice.gpu, typo.choice);
    try std.testing.expect(typo.unknown);
}

test "a window with no handles gets no presenter rather than a fault" {
    try std.testing.expect(open(null, null, 640, 480) == null);
}