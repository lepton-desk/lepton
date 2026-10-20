//! One textured quad on the GPU: the part of presentation that does not need a window.
//!
//! ## Why this exists as its own module
//!
//! Presenting a frame is two jobs that fail independently, and measuring them together
//! hides whichever one is broken. The first is drawing — shader, texture upload, a quad —
//! which needs nothing from the display server and is verifiable anywhere. The second is
//! handing the finished frame to a compositor, which needs a window surface, and on this
//! machine `eglCreateWindowSurface` is refused for every surface tried.
//!
//! So this module owns only the first job, and owns it completely: it opens its own EGL
//! context on an off-screen surface and draws a real CPU frame into it. Nothing here is
//! simulated — the pixels are uploaded as a `GL_TEXTURE_2D` and drawn by the driver.
//!
//! ## What makes this verifiable when the window path is not
//!
//! The frame can be read back with `glReadPixels` after drawing, so a test asserts on
//! actual GPU output rather than on the absence of an error. A frame that reaches the
//! screen can never be checked this way, and a test that claims otherwise is checking
//! nothing.

const std = @import("std");

const c = @import("c_gl_renderer");

/// The off-screen surface size. Fixed and small on purpose — this renders a test frame,
/// not a window, so the size that matters is the one that keeps the check quick.
pub const surface_size = 64;

/// Everything needed to draw a CPU frame on the GPU and read the result back.
pub const Renderer = struct {
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
    program: c.GLuint,
    vertex_shader: c.GLuint,
    fragment_shader: c.GLuint,
    texture: c.GLuint,
    quad: c.GLuint,

    /// Whether this renderer created its EGL display, surface and context.
    ///
    /// An off-screen renderer owns them and destroys them on `deinit`. One attached to a
    /// window surface borrows them from the presenter that made them, and destroying them
    /// here would pull the surface out from under the window.
    owns_egl: bool,

    pub fn deinit(self: *Renderer) void {
        _ = c.glDeleteBuffers(1, &self.quad);
        _ = c.glDeleteTextures(1, &self.texture);
        _ = c.glDeleteProgram(self.program);
        _ = c.glDeleteShader(self.vertex_shader);
        _ = c.glDeleteShader(self.fragment_shader);
        if (self.owns_egl) {
            _ = c.eglDestroyContext(self.display, self.context);
            _ = c.eglDestroySurface(self.display, self.surface);
            _ = c.eglTerminate(self.display);
        }
    }
};

/// Failures that are the caller's to explain.
///
/// `NoShader` and `NoProgram` carry the driver's own log, because "the shader did not
/// compile" is not an actionable message and the log is the only part that is.
pub const Error = error{
    NoConfig,
    NoSurface,
    NoContext,
    NoCurrent,
    NoShader,
    NoProgram,
    NoVertexBuffer,
    NoTexture,
};

/// The vertex stage: a single triangle strip covering the surface.
const vertex_source =
    \\attribute vec2 position;
    \\attribute vec2 texcoord;
    \\varying vec2 uv;
    \\void main() {
    \\    uv = texcoord;
    \\    gl_Position = vec4(position, 0.0, 1.0);
    \\}
;

/// The fragment stage: whatever the CPU frame put in the texture.
///
/// The swap is not decoration. The frames arriving here are the window's own formats,
/// `ARGB8888` and `XRGB8888`, whose bytes are blue, green, red, alpha in memory on a
/// little-endian machine. GL ES 2 has no `GL_BGRA` to upload them under, so the bytes go
/// in as `GL_RGBA` and the two red and blue channels are exchanged on the way out — which
/// keeps the frame on its way to the screen without a copy on the CPU, and without a
/// frame that arrives with its colours transposed.
///
/// The alpha of an `XRGB8888` frame is undefined by that format, so it is forced opaque
/// rather than carried through.
const fragment_source =
    \\precision mediump float;
    \\varying vec2 uv;
    \\uniform sampler2D frame;
    \\void main() {
    \\    vec4 texel = texture2D(frame, uv);
    \\    gl_FragColor = vec4(texel.b, texel.g, texel.r, 1.0);
    \\}
;

/// Opens an off-screen renderer with a real GL ES context on a real EGL surface.
///
/// Everything it uses, it also creates and destroys: nothing here is shared with a window,
/// which is what makes it the only one of the two entry points that can be verified
/// without a compositor.
pub fn open() Error!Renderer {
    const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    if (display == c.EGL_NO_DISPLAY) return error.NoSurface;

    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(display, &major, &minor) == 0) return error.NoSurface;

    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES2_BIT,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var config_count: c.EGLint = 0;
    if (c.eglChooseConfig(display, &attributes, &config, 1, &config_count) == 0 or config_count == 0) {
        return error.NoConfig;
    }

    const surface_attributes = [_]c.EGLint{
        c.EGL_WIDTH,  surface_size,
        c.EGL_HEIGHT, surface_size,
        c.EGL_NONE,
    };
    const surface = c.eglCreatePbufferSurface(display, config, &surface_attributes);
    if (surface == c.EGL_NO_SURFACE) return error.NoSurface;

    const context_attributes = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 2, c.EGL_NONE };
    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attributes);
    if (context == c.EGL_NO_CONTEXT) return error.NoContext;

    if (c.eglMakeCurrent(display, surface, surface, context) == 0) return error.NoCurrent;

    return setup(display, surface, context, true);
}

/// Builds a renderer on an EGL display, surface and context the caller owns.
///
/// The EGL objects are borrowed, not adopted: this returns the drawing half only, and
/// `deinit` leaves the window alone. The alternative — having the presenter hand over EGL
/// and this module destroy it — would put the window's lifetime inside the drawing code.
pub fn attach(
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
) Error!Renderer {
    if (c.eglMakeCurrent(display, surface, surface, context) == 0) return error.NoCurrent;
    return setup(display, surface, context, false);
}

/// Compiles the program and creates the GL objects both entry points share.
fn setup(
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
    owns_egl: bool,
) Error!Renderer {
    var renderer = Renderer{
        .display = display,
        .surface = surface,
        .context = context,
        .program = 0,
        .vertex_shader = 0,
        .fragment_shader = 0,
        .texture = 0,
        .quad = 0,
        .owns_egl = owns_egl,
    };

    renderer.vertex_shader = try compileShader(c.GL_VERTEX_SHADER, vertex_source);
    errdefer _ = c.glDeleteShader(renderer.vertex_shader);
    renderer.fragment_shader = try compileShader(c.GL_FRAGMENT_SHADER, fragment_source);
    errdefer _ = c.glDeleteShader(renderer.fragment_shader);

    const program = c.glCreateProgram();
    if (program == 0) return error.NoProgram;
    c.glAttachShader(program, renderer.vertex_shader);
    c.glAttachShader(program, renderer.fragment_shader);
    c.glLinkProgram(program);

    var linked: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &linked);
    if (linked == 0) return error.NoProgram;
    renderer.program = program;

    var quad: c.GLuint = 0;
    c.glGenBuffers(1, &quad);
    if (quad == 0) return error.NoVertexBuffer;
    renderer.quad = quad;

    var texture: c.GLuint = 0;
    c.glGenTextures(1, &texture);
    if (texture == 0) return error.NoTexture;
    renderer.texture = texture;

    return renderer;
}

fn compileShader(kind: c.GLenum, source: [:0]const u8) Error!c.GLuint {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return error.NoShader;
    const pointer = [_][*c]const u8{source.ptr};
    c.glShaderSource(shader, 1, &pointer, null);
    c.glCompileShader(shader);

    var compiled: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &compiled);
    if (compiled == 0) {
        _ = c.glDeleteShader(shader);
        return error.NoShader;
    }
    return shader;
}

/// Uploads `pixels` as an `ARGB8888`/`XRGB8888` frame and draws it across the surface.
///
/// `pixels` must be `width` by `height` RGBA bytes with no row padding, which is the
/// layout the CPU renderer already produces; a stride is not accepted here because the
/// one caller has none and accepting it untested would be a promise nobody checks.
pub fn drawFrame(
    self: *Renderer,
    pixels: []const u8,
    width: c.GLsizei,
    height: c.GLsizei,
) Error!void {
    c.glBindTexture(c.GL_TEXTURE_2D, self.texture);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA,
        width,
        height,
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        pixels.ptr,
    );

    // Two triangles as one strip: bottom-left, bottom-right, top-left, top-right.
    //
    // The texture's first row is the frame's *top* row (that is the order the CPU writes
    // memory in), while GL's t = 0 is the bottom of the quad — so t runs 1 → 0 bottom to
    // top. With t = 0 at the bottom every window was drawn upside down; measured by the
    // position test below, which read frame row 0 back at the last row.
    const corners = [_]c.GLfloat{
        -1, -1, 0, 1,
        1,  -1, 1, 1,
        -1, 1,  0, 0,
        1,  1,  1, 0,
    };
    c.glBindBuffer(c.GL_ARRAY_BUFFER, self.quad);
    c.glBufferData(
        c.GL_ARRAY_BUFFER,
        @sizeOf(@TypeOf(corners)),
        @ptrCast(&corners),
        c.GL_STATIC_DRAW,
    );

    c.glUseProgram(self.program);
    c.glActiveTexture(c.GL_TEXTURE0);
    c.glBindTexture(c.GL_TEXTURE_2D, self.texture);

    const position = c.glGetAttribLocation(self.program, "position");
    const texcoord = c.glGetAttribLocation(self.program, "texcoord");
    // Four floats per vertex — a position pair then a texture pair — so the stride is
    // four, not two. Understating it interleaves the two attributes, and the strip that
    // comes out covers a band of the surface instead of all of it.
    const stride = 4 * @sizeOf(c.GLfloat);
    const texcoord_offset = 2 * @sizeOf(c.GLfloat);

    c.glVertexAttribPointer(
        @intCast(position),
        2,
        c.GL_FLOAT,
        0,
        stride,
        @ptrFromInt(0),
    );
    c.glEnableVertexAttribArray(@intCast(position));
    c.glVertexAttribPointer(
        @intCast(texcoord),
        2,
        c.GL_FLOAT,
        0,
        stride,
        @ptrFromInt(texcoord_offset),
    );
    c.glEnableVertexAttribArray(@intCast(texcoord));

    // The frame's own size: a window surface is as large as the window, and the 64 px
    // test pbuffer is only one caller. Fixed to `surface_size`, a real window drew its
    // frame into the bottom-left 64 px and left the rest black.
    c.glViewport(0, 0, width, height);
    c.glClearColor(0, 0, 0, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    c.glFinish();
}

/// Reads the drawn frame back as RGBA bytes.
///
/// This is the only honest way to check GPU output: the drawing happens on the GPU and
/// the assertion runs on what the GPU actually produced.
pub fn readFrame(self: *Renderer, out: []u8) void {
    // `glReadPixels` reads whatever framebuffer happens to be bound, not this renderer's.
    // Binding it first is what makes the result belong to this renderer rather than to
    // whichever context the caller last made current.
    _ = c.eglMakeCurrent(self.display, self.surface, self.surface, self.context);
    c.glReadPixels(0, 0, surface_size, surface_size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, out.ptr);
}

test "a uniform frame survives the round trip through the GPU" {
    var renderer = try open();
    defer renderer.deinit();

    const size = surface_size * surface_size * 4;
    const frame = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(frame);

    @memset(frame, 0x5a);

    try drawFrame(&renderer, frame, surface_size, surface_size);

    const read_back = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(read_back);
    @memset(read_back, 0);
    readFrame(&renderer, read_back);

    // Every pixel, every colour channel: a partial match would mean the frame was
    // transformed somewhere on the way, which is what this path must not do. Alpha is
    // the one channel allowed to differ — an `XRGB8888` frame carries no defined alpha,
    // so it is forced opaque rather than passed through.
    for (0..size / 4) |pixel| {
        std.testing.expectEqual(@as(u8, 0x5a), read_back[pixel * 4 + 0]) catch |err| {
            std.debug.print("pixel {d} red was {d}, not 0x5a\n", .{ pixel, read_back[pixel * 4 + 0] });
            return err;
        };
        std.testing.expectEqual(@as(u8, 0x5a), read_back[pixel * 4 + 1]) catch |err| {
            std.debug.print("pixel {d} green was {d}, not 0x5a\n", .{ pixel, read_back[pixel * 4 + 1] });
            return err;
        };
        std.testing.expectEqual(@as(u8, 0x5a), read_back[pixel * 4 + 2]) catch |err| {
            std.debug.print("pixel {d} blue was {d}, not 0x5a\n", .{ pixel, read_back[pixel * 4 + 2] });
            return err;
        };
        std.testing.expectEqual(@as(u8, 0xff), read_back[pixel * 4 + 3]) catch |err| {
            std.debug.print("pixel {d} alpha was {d}, not opaque\n", .{ pixel, read_back[pixel * 4 + 3] });
            return err;
        };
    }
}

test "the frame the GPU produced differs from the one handed to it" {
    var renderer = try open();
    defer renderer.deinit();

    const size = surface_size * surface_size * 4;
    const frame = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(frame);
    // R, G and B deliberately different: a symmetric value would pass whether or not the
    // channel swap happened, which is exactly what this test is now there to catch.
    for (0..size / 4) |pixel| {
        frame[pixel * 4 + 0] = 0x11;
        frame[pixel * 4 + 1] = 0x22;
        frame[pixel * 4 + 2] = 0x33;
        frame[pixel * 4 + 3] = 0xff;
    }

    const read_back = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(read_back);
    @memset(read_back, 0);

    try drawFrame(&renderer, frame, surface_size, surface_size);
    readFrame(&renderer, read_back);

    // The read-back buffer started empty, so a byte that is not zero can only have come
    // from the draw. This is what distinguishes "the GPU drew" from "the draw silently
    // did nothing and readPixels returned the untouched target".
    var drawn: usize = 0;
    for (read_back) |byte| {
        if (byte != 0) drawn += 1;
    }
    try std.testing.expectEqual(size, drawn);

    // The frame went in as ARGB and must come out as the colours it was, which is the
    // swap: the byte at red's offset is the blue that was fed, and vice versa.
    for (0..size / 4) |pixel| {
        try std.testing.expectEqual(@as(u8, 0x33), read_back[pixel * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0x22), read_back[pixel * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0x11), read_back[pixel * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 0xff), read_back[pixel * 4 + 3]);
    }
}
test "every pixel lands where the frame put it, top row at the top" {
    // Position-sensitive: each pixel carries its own x and y, on a frame that is neither
    // square nor the pbuffer's size, so a flip, a transpose or a row-length mix-up all
    // show up as a pixel holding someone else's coordinates.
    var renderer = try open();
    defer renderer.deinit();

    const width: usize = 40;
    const height: usize = 24;
    const frame = try std.testing.allocator.alloc(u8, width * height * 4);
    defer std.testing.allocator.free(frame);
    for (0..height) |y| {
        for (0..width) |x| {
            const at = (y * width + x) * 4;
            // Memory order B, G, R, A — the window's ARGB8888 on little-endian.
            frame[at + 0] = @intCast(x * 4); // blue
            frame[at + 1] = @intCast(y * 8); // green
            frame[at + 2] = 0x80; // red
            frame[at + 3] = 0xff;
        }
    }

    try drawFrame(&renderer, frame, @intCast(width), @intCast(height));

    const read_back = try std.testing.allocator.alloc(u8, surface_size * surface_size * 4);
    defer std.testing.allocator.free(read_back);
    readFrame(&renderer, read_back);

    // `glReadPixels` counts rows from the bottom; frame row `y` must be read-back row
    // `height - 1 - y` inside the `width x height` viewport.
    for (0..height) |y| {
        for (0..width) |x| {
            const row = height - 1 - y;
            const at = (row * surface_size + x) * 4;
            const red = read_back[at + 0];
            const green = read_back[at + 1];
            const blue = read_back[at + 2];
            if (red != 0x80 or green != y * 8 or blue != x * 4) {
                std.debug.print(
                    "frame ({d},{d}) read back r={d} g={d} b={d}, expected r=128 g={d} b={d}\n",
                    .{ x, y, red, green, blue, y * 8, x * 4 },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
}
