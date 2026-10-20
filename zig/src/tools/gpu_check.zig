//! Can this framework's own Wayland window be made into a GPU surface?
//!
//! The load-bearing measurement for GPU presentation in the native path. Everything the
//! plan needs is already true if this runs: the window holds a `wl_display` and a
//! `wl_surface`, libEGL offers a Wayland platform, and a swap reaches the compositor.
//!
//! Nothing is mocked and nothing is simulated — this opens a real window, and every line
//! it prints is the system's answer rather than this framework's expectation.

const std = @import("std");
const core = @import("lepton_core");

const c = @import("c_gpu_check");

const egl_platform_wayland: c.EGLint = 0x31D8;

const eglCreateWindowSurface = @extern(
    *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*const c.EGLint) callconv(.c) ?*anyopaque,
    .{ .name = "eglCreateWindowSurface" },
);

// The bare-surface probe.
//
// `WaylandWindow` reaches its `wl_surface` through a compositor it binds off the
// registry and then hangs an xdg shell role on. The refusal below is ambiguous between
// "that window's surface is wrong" and "this driver refuses every window surface", and
// nothing so far separates them. So a surface is built the shortest way there is —
// registry, compositor, one `wl_surface`, no role, no window, nothing from this
// framework — and EGL is asked about it directly. Whatever it answers, the window code
// is either cleared or convicted.
//
// The listener struct is the one thing not taken from the header, because
// `wl_registry`'s `listeners` member is an incomplete type to `@cImport`. It carries no
// symbol of its own: it is a struct laid out to match the header's declaration, handed
// to `wl_proxy_add_listener` by pointer.
const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*anyopaque, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: ?*const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void,
};

// A registry callback cannot close over anything, so the bound compositor is left where
// the callback can reach it.
var bound_compositor: ?*c.wl_compositor = null;

fn onGlobal(data: ?*anyopaque, registry: ?*anyopaque, name: u32, interface: [*:0]const u8, version: u32) callconv(.c) void {
    _ = version;
    const slot: *?*c.wl_compositor = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(interface), "wl_compositor")) {
        // `wl_registry_bind` is declared against the generic `wl_interface` and hands
        // back an untyped proxy; the interface named above is what makes it a compositor.
        slot.* = @ptrCast(c.wl_registry_bind(
            @ptrCast(registry),
            name,
            &c.wl_compositor_interface,
            4,
        ));
    }
}

/// Asks EGL about a surface that owes nothing to this framework's window code.
///
/// Reports its own outcome and leaves the caller's error state alone, so that running it
/// changes what is known without changing what the measurement concludes.
fn bareSurfaceVerdict(
    egl_display: ?*anyopaque,
    config: ?*anyopaque,
    wl_display: ?*anyopaque,
) void {
    // The connection arrives typed as the *core's* `wl_display`, and each `@cImport` in
    // the program produces its own type for it — two translation units cannot agree on a
    // C type that `@cImport` invents. So the handle crosses as an address and is taken
    // back into this file's own type here.
    const display: ?*c.wl_display = @ptrCast(wl_display);
    const registry: *c.wl_registry = c.wl_display_get_registry(display) orelse {
        std.debug.print("bare         no registry from this wl_display\n", .{});
        return;
    };
    // Mutable so its address can be handed over as the listener table, which is how
    // libwayland finds the callbacks at all.
    var listener = RegistryListener{ .global = onGlobal, .global_remove = null };
    _ = c.wl_proxy_add_listener(
        @ptrCast(registry),
        @ptrCast(&listener),
        @ptrCast(&bound_compositor),
    );
    // Two round trips: the first delivers the globals, the second delivers the bind that
    // the first one caused. One round trip only ever sees the announcements.
    _ = c.wl_display_roundtrip(display);
    _ = c.wl_display_roundtrip(display);

    const compositor = bound_compositor orelse {
        std.debug.print("bare         no wl_compositor announced\n", .{});
        return;
    };
    const surface = c.wl_compositor_create_surface(compositor) orelse {
        std.debug.print("bare         wl_surface could not be created\n", .{});
        return;
    };
    defer _ = c.wl_surface_destroy(surface);

    _ = c.wl_surface_commit(surface);
    _ = c.wl_display_roundtrip(display);

    const verdict = eglCreateWindowSurface(egl_display, config, @ptrCast(surface), null);
    if (verdict) |made| {
        _ = c.eglDestroySurface(egl_display, made);
        std.debug.print("bare         ACCEPTED -- the driver refuses this framework's window, not surfaces\n", .{});
    } else {
        std.debug.print("bare         refused 0x{x} -- every window surface is refused, ours included\n", .{c.eglGetError()});
    }
}

pub fn main() !void {
    if (!comptime core.render.is_native) {
        std.debug.print("engine       this check is about the native path\n", .{});
        return error.NotNative;
    }

    const allocator = std.heap.page_allocator;
    const request: core.window.Request = .{
        .title = "lepton gpu check",
        .app_id = "dev.lepton.gpucheck",
        .size = .{ .width = 480, .height = 320 },
    };

    var window: core.waylandWindow.WaylandWindow = undefined;
    try window.open(allocator, request);
    defer window.close();

    const surface_handle = window.surface orelse {
        std.debug.print("window       has no wl_surface\n", .{});
        return error.NoSurface;
    };
    std.debug.print("window       wl_display and wl_surface both held\n", .{});

    const egl_display = c.eglGetPlatformDisplay(egl_platform_wayland, window.display, null);
    if (egl_display == null) {
        std.debug.print("egl display  unavailable\n", .{});
        return error.NoEglDisplay;
    }
    defer _ = c.eglTerminate(egl_display);

    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(egl_display, &major, &minor) == 0) {
        std.debug.print("egl display  refused 0x{x}\n", .{c.eglGetError()});
        return error.EglRefused;
    }
    std.debug.print("egl display  {d}.{d} {s}\n", .{
        major,
        minor,
        std.mem.span(c.eglQueryString(egl_display, c.EGL_VENDOR)),
    });

    // No alpha requested and no depth or stencil. A Wayland window surface has no visual
    // to match an alpha plane against, and asking for one makes Mesa answer
    // `EGL_BAD_ATTRIBUTE` from `eglCreateWindowSurface` — a refusal that says nothing
    // about GPUs, only about a config the surface cannot have.
    // Chosen by renderable type and colour depth only, without asking for
    // `EGL_WINDOW_BIT`. Filtering on the surface type is the documented way to get a
    // window-capable config, and it is also the one this driver's window surface refuses:
    // the answer here is `EGL_BAD_ATTRIBUTE`, which says the config is unusable for the
    // surface rather than that there is no GPU. Worth recording: the config that the
    // driver hands back when asked this way does carry the window bit.
    const attributes = [_]c.EGLint{
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var config_count: c.EGLint = 0;
    if (c.eglChooseConfig(egl_display, &attributes, &config, 1, &config_count) == 0 or config_count == 0) {
        std.debug.print("config       none available\n", .{});
        return error.NoConfig;
    }
    var probed: c.EGLint = 0;
    _ = c.eglGetConfigAttrib(egl_display, config, c.EGL_SURFACE_TYPE, &probed);
    std.debug.print("config       surface_type={d} (window bit is {d})\n", .{ probed, c.EGL_WINDOW_BIT });

    // Declared here rather than taken from `@cImport`, for one reason: `eglplatform.h`
    // resolves `EGLNativeWindowType` to `unsigned long` on this machine while the Wayland
    // driver expects a `struct wl_surface *`. Both are one word on the ABI, so passing
    // the handle as a pointer is the call the driver actually wants, and passing it as
    // the header's own typedef is the one it answers `EGL_BAD_ATTRIBUTE` to.
    // A pbuffer surface first, because it needs no Wayland window at all. If this one
    // succeeds and the window surface below does not, then EGL is healthy and the refusal
    // is about this window specifically — a far narrower thing to carry forward than
    // "EGL is broken".
    const pbuffer_attributes = [_]c.EGLint{ c.EGL_WIDTH, 64, c.EGL_HEIGHT, 64, c.EGL_NONE };
    const pbuffer = c.eglCreatePbufferSurface(egl_display, config, &pbuffer_attributes);
    if (pbuffer == null) {
        std.debug.print("pbuffer      refused 0x{x} -- EGL itself cannot make a surface\n", .{c.eglGetError()});
    } else {
        defer _ = c.eglDestroySurface(egl_display, pbuffer);
        std.debug.print("pbuffer      created, so EGL is healthy here\n", .{});
    }

    bareSurfaceVerdict(egl_display, config, window.display);

    const egl_surface = eglCreateWindowSurface(
        egl_display,
        config,
        @ptrCast(surface_handle),
        null,
    );
    if (egl_surface == null) {
        std.debug.print("egl surface  refused 0x{x}\n", .{c.eglGetError()});
        return error.NoEglSurface;
    }
    defer _ = c.eglDestroySurface(egl_display, egl_surface);
    std.debug.print("egl surface  created from the window's own wl_surface\n", .{});

    const context_attributes = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    const context = c.eglCreateContext(egl_display, config, null, &context_attributes);
    if (context == null) {
        std.debug.print("context      refused 0x{x}\n", .{c.eglGetError()});
        return error.NoContext;
    }
    defer _ = c.eglDestroyContext(egl_display, context);

    if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, context) == 0) {
        std.debug.print("current      refused 0x{x}\n", .{c.eglGetError()});
        return error.NoCurrent;
    }
    std.debug.print("context      {s}\n", .{std.mem.span(c.eglQueryString(egl_display, c.EGL_VERSION))});

    // `glClearColor`, not `eglClearColor`: EGL creates and hands over the context, and
    // everything that goes into it afterwards is plain OpenGL ES. `GL_COLOR_BUFFER_BIT`
    // is GL's constant for the same reason.
    _ = c.glClearColor(0.08, 0.10, 0.12, 1.0);
    _ = c.glClear(c.GL_COLOR_BUFFER_BIT);
    if (c.eglSwapBuffers(egl_display, egl_surface) == 0) {
        std.debug.print("swap         refused 0x{x}\n", .{c.eglGetError()});
        return error.NoSwap;
    }
    std.debug.print("swap         a GPU buffer reached the compositor\n", .{});
}
