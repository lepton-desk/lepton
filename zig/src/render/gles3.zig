//! The GLES 3 backend for the draw command list (`scene.zig`): every shape in one
//! instanced draw, the shape itself computed in the fragment shader.
//!
//! The GPU path below Vulkan (`gpu/vulkan_threshold.zig`): a device that misses the
//! Vulkan threshold, or `LEPTON_GPU=gles`, draws here. Each `scene.Instance` is one
//! instance of a four-vertex strip; the vertex shader places the quad (grown by a shadow's
//! blur), the fragment shader takes the signed distance to the rounded rectangle and turns
//! it into coverage, border and shadow. Nothing is painted on the CPU and no frame-sized
//! texture is uploaded — what crosses per frame is the instance bytes.
//!
//! `open` makes an off-screen ES 3 context, so the output is read back and asserted on
//! (`zig build gpu-test`); a window's context is the presenter's, attached later.

const std = @import("std");
pub const scene = @import("scene.zig");

const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("GLES3/gl3.h");
});

/// `EGL_OPENGL_ES3_BIT` (EGL 1.5 / `EGL_KHR_create_context`), not in every `egl.h`.
const egl_opengl_es3_bit: c.EGLint = 0x0040;

pub const Error = error{ NoDisplay, NoConfig, NoSurface, NoContext, NoCurrent, NoShader, NoProgram, NoBuffer };

const vertex_source: [:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec4 a_rect;
    \\layout(location = 1) in vec4 a_fill;
    \\layout(location = 2) in vec4 a_border_colour;
    \\layout(location = 3) in vec4 a_params;
    \\uniform vec2 u_size;
    \\out vec2 v_local;
    \\flat out vec2 v_half;
    \\flat out vec4 v_fill;
    \\flat out vec4 v_border_colour;
    \\flat out vec4 v_params;
    \\void main() {
    \\    // A shadow reaches `blur` past its edge; every shape gets a pixel for its edge's
    \\    // antialiasing.
    \\    float pad = a_params.z + 1.0;
    \\    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    \\    vec2 origin = a_rect.xy - pad;
    \\    vec2 extent = a_rect.zw + 2.0 * pad;
    \\    vec2 pixel = origin + corner * extent;
    \\    v_half = a_rect.zw * 0.5;
    \\    v_local = pixel - (a_rect.xy + v_half);
    \\    v_fill = a_fill;
    \\    v_border_colour = a_border_colour;
    \\    v_params = a_params;
    \\    gl_Position = vec4(pixel.x / u_size.x * 2.0 - 1.0, 1.0 - pixel.y / u_size.y * 2.0, 0.0, 1.0);
    \\}
;

const fragment_source: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 v_local;
    \\flat in vec2 v_half;
    \\flat in vec4 v_fill;
    \\flat in vec4 v_border_colour;
    \\flat in vec4 v_params;
    \\out vec4 o_colour;
    \\float roundedBox(vec2 p, vec2 half_size, float radius) {
    \\    vec2 q = abs(p) - half_size + radius;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
    \\}
    \\vec4 premultiplied(vec4 c) { return vec4(c.rgb * c.a, c.a); }
    \\void main() {
    \\    float radius = v_params.x;
    \\    float border = v_params.y;
    \\    float blur = v_params.z;
    \\    float d = roundedBox(v_local, v_half, radius);
    \\    if (v_params.w > 0.5) {
    \\        // Shadow: opaque `blur` inside the edge, gone `blur` outside it.
    \\        float a = 1.0 - smoothstep(-blur, blur, d);
    \\        o_colour = premultiplied(v_fill) * a;
    \\        return;
    \\    }
    \\    float coverage = clamp(0.5 - d, 0.0, 1.0);
    \\    vec4 colour = premultiplied(v_fill);
    \\    if (border > 0.0) {
    \\        float in_band = clamp(d + border + 0.5, 0.0, 1.0);
    \\        colour = mix(colour, premultiplied(v_border_colour), in_band);
    \\    }
    \\    o_colour = colour * coverage;
    \\}
;

pub const Renderer = struct {
    display: c.EGLDisplay,
    surface: c.EGLSurface,
    context: c.EGLContext,
    owns_egl: bool,
    program: c.GLuint,
    vertex_array: c.GLuint,
    instances: c.GLuint,
    /// Bytes the instance buffer holds; it grows, never shrinks.
    capacity: usize = 0,
    size_location: c.GLint,
    width: u32,
    height: u32,
    /// Bytes handed to the driver by `draw`, all frames: the figure this path exists for.
    uploaded: u64 = 0,

    pub fn deinit(self: *Renderer) void {
        c.glDeleteBuffers(1, &self.instances);
        c.glDeleteVertexArrays(1, &self.vertex_array);
        c.glDeleteProgram(self.program);
        if (self.owns_egl) {
            _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
            _ = c.eglDestroyContext(self.display, self.context);
            _ = c.eglDestroySurface(self.display, self.surface);
            _ = c.eglTerminate(self.display);
        }
    }

    /// Draws `list` over `clear`, in order. Premultiplied blending: what the shader writes.
    pub fn draw(self: *Renderer, list: *const scene.List, clear: scene.Colour) void {
        c.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
        c.glClearColor(clear[0] * clear[3], clear[1] * clear[3], clear[2] * clear[3], clear[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        const bytes = list.bytes();
        if (bytes.len == 0) return;

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.instances);
        if (bytes.len > self.capacity) {
            c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(bytes.len), bytes.ptr, c.GL_STREAM_DRAW);
            self.capacity = bytes.len;
        } else {
            c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(bytes.len), bytes.ptr);
        }
        self.uploaded += bytes.len;

        c.glUseProgram(self.program);
        c.glUniform2f(self.size_location, @floatFromInt(self.width), @floatFromInt(self.height));
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glBindVertexArray(self.vertex_array);
        c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(list.instances.items.len));
        c.glBindVertexArray(0);
    }

    /// Waits for the GPU: for timing, and before `read`.
    pub fn finish(_: *Renderer) void {
        c.glFinish();
    }

    /// The frame as RGBA bytes, top row first. `out` holds `width * height * 4`.
    pub fn read(self: *Renderer, out: []u8) void {
        const row = self.width * 4;
        c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
        c.glReadPixels(0, 0, @intCast(self.width), @intCast(self.height), c.GL_RGBA, c.GL_UNSIGNED_BYTE, out.ptr);
        // GL's first row is the bottom one.
        var top: usize = 0;
        var bottom: usize = self.height - 1;
        var swap: [4 * 4096]u8 = undefined;
        while (top < bottom) : ({
            top += 1;
            bottom -= 1;
        }) {
            const a = out[top * row ..][0..row];
            const b = out[bottom * row ..][0..row];
            var at: usize = 0;
            while (at < row) : (at += swap.len) {
                const n = @min(swap.len, row - at);
                @memcpy(swap[0..n], a[at..][0..n]);
                @memcpy(a[at..][0..n], b[at..][0..n]);
                @memcpy(b[at..][0..n], swap[0..n]);
            }
        }
    }

    /// The renderer string the driver reports (`AMD Radeon R7 200 Series (radeonsi, …)`).
    pub fn rendererName(_: *Renderer) []const u8 {
        const name: [*:0]const u8 = @ptrCast(c.glGetString(c.GL_RENDERER) orelse return "unknown");
        return std.mem.span(name);
    }
};

fn compile(kind: c.GLenum, source: [:0]const u8) Error!c.GLuint {
    const shader = c.glCreateShader(kind);
    if (shader == 0) return error.NoShader;
    const sources = [_][*c]const u8{source.ptr};
    c.glShaderSource(shader, 1, &sources, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, log.len, &len, &log);
        std.debug.print("gles3        shader: {s}\n", .{log[0..@intCast(len)]});
        c.glDeleteShader(shader);
        return error.NoShader;
    }
    return shader;
}

/// The program, the instance buffer and its attributes, on the current context.
fn setup(display: c.EGLDisplay, surface: c.EGLSurface, context: c.EGLContext, owns: bool, width: u32, height: u32) Error!Renderer {
    const vertex = try compile(c.GL_VERTEX_SHADER, vertex_source);
    defer c.glDeleteShader(vertex);
    const fragment = try compile(c.GL_FRAGMENT_SHADER, fragment_source);
    defer c.glDeleteShader(fragment);
    const program = c.glCreateProgram();
    c.glAttachShader(program, vertex);
    c.glAttachShader(program, fragment);
    c.glLinkProgram(program);
    var linked: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &linked);
    if (linked == 0) {
        c.glDeleteProgram(program);
        return error.NoProgram;
    }

    var vertex_array: c.GLuint = 0;
    c.glGenVertexArrays(1, &vertex_array);
    var instances: c.GLuint = 0;
    c.glGenBuffers(1, &instances);
    if (vertex_array == 0 or instances == 0) return error.NoBuffer;
    c.glBindVertexArray(vertex_array);
    c.glBindBuffer(c.GL_ARRAY_BUFFER, instances);
    const stride: c.GLsizei = @sizeOf(scene.Instance);
    const offsets = [_]usize{
        @offsetOf(scene.Instance, "rect"),
        @offsetOf(scene.Instance, "fill"),
        @offsetOf(scene.Instance, "border_colour"),
        @offsetOf(scene.Instance, "params"),
    };
    for (offsets, 0..) |offset, location| {
        c.glEnableVertexAttribArray(@intCast(location));
        c.glVertexAttribPointer(@intCast(location), 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(offset));
        c.glVertexAttribDivisor(@intCast(location), 1);
    }
    c.glBindVertexArray(0);

    return .{
        .display = display,
        .surface = surface,
        .context = context,
        .owns_egl = owns,
        .program = program,
        .vertex_array = vertex_array,
        .instances = instances,
        .size_location = c.glGetUniformLocation(program, "u_size"),
        .width = width,
        .height = height,
    };
}

/// An off-screen ES 3 renderer of `width`×`height`.
pub fn open(width: u32, height: u32) Error!Renderer {
    const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    if (display == c.EGL_NO_DISPLAY) return error.NoDisplay;
    var major: c.EGLint = 0;
    var minor: c.EGLint = 0;
    if (c.eglInitialize(display, &major, &minor) == 0) return error.NoDisplay;
    errdefer _ = c.eglTerminate(display);
    const attributes = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,    c.EGL_PBUFFER_BIT,
        c.EGL_RENDERABLE_TYPE, egl_opengl_es3_bit,
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_NONE,
    };
    var config: c.EGLConfig = null;
    var count: c.EGLint = 0;
    if (c.eglChooseConfig(display, &attributes, &config, 1, &count) == 0 or count == 0) return error.NoConfig;
    const surface_attributes = [_]c.EGLint{ c.EGL_WIDTH, @intCast(width), c.EGL_HEIGHT, @intCast(height), c.EGL_NONE };
    const surface = c.eglCreatePbufferSurface(display, config, &surface_attributes);
    if (surface == c.EGL_NO_SURFACE) return error.NoSurface;
    errdefer _ = c.eglDestroySurface(display, surface);
    _ = c.eglBindAPI(c.EGL_OPENGL_ES_API);
    const context_attributes = [_]c.EGLint{ c.EGL_CONTEXT_CLIENT_VERSION, 3, c.EGL_NONE };
    const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attributes);
    if (context == c.EGL_NO_CONTEXT) return error.NoContext;
    errdefer _ = c.eglDestroyContext(display, context);
    if (c.eglMakeCurrent(display, surface, surface, context) == 0) return error.NoCurrent;
    return setup(display, surface, context, true, width, height);
}

// ── Tests: real GPU output, read back (`zig build gpu-test`) ──

const test_width = 96;
const test_height = 64;

fn pixel(frame: []const u8, x: usize, y: usize) [4]u8 {
    return frame[(y * test_width + x) * 4 ..][0..4].*;
}

fn near(got: [4]u8, want: [4]u8, tolerance: u8) bool {
    for (got, want) |g, w| {
        if (@max(g, w) - @min(g, w) > tolerance) return false;
    }
    return true;
}

fn render(list: *const scene.List, clear: scene.Colour) ![test_width * test_height * 4]u8 {
    var renderer = try open(test_width, test_height);
    defer renderer.deinit();
    renderer.draw(list, clear);
    renderer.finish();
    var frame: [test_width * test_height * 4]u8 = undefined;
    renderer.read(&frame);
    return frame;
}

test "a rectangle lands where it was put, top row at the top" {
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);
    try list.rect(std.testing.allocator, .{ .x = 8, .y = 4, .width = 40, .height = 20 }, .{ .fill = scene.rgba(0xff0000ff) });
    const frame = try render(&list, scene.rgba(0x000000ff));
    try std.testing.expect(near(pixel(&frame, 28, 14), .{ 255, 0, 0, 255 }, 1));
    // Just outside each edge: the clear colour.
    try std.testing.expect(near(pixel(&frame, 6, 14), .{ 0, 0, 0, 255 }, 1));
    try std.testing.expect(near(pixel(&frame, 28, 2), .{ 0, 0, 0, 255 }, 1));
    try std.testing.expect(near(pixel(&frame, 50, 14), .{ 0, 0, 0, 255 }, 1));
    try std.testing.expect(near(pixel(&frame, 28, 26), .{ 0, 0, 0, 255 }, 1));
}

test "a rounded corner is cut, and its border is drawn in the border colour" {
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);
    try list.rect(std.testing.allocator, .{ .x = 10, .y = 10, .width = 60, .height = 40 }, .{
        .fill = scene.rgba(0xffffffff),
        .radius = 12,
        .border = 3,
        .border_colour = scene.rgba(0x0000ffff),
    });
    const frame = try render(&list, scene.rgba(0x000000ff));
    // The corner pixel of the box's bounds is outside the rounding.
    try std.testing.expect(near(pixel(&frame, 10, 10), .{ 0, 0, 0, 255 }, 1));
    // The middle of the left edge is in the border band; the centre is the fill.
    try std.testing.expect(near(pixel(&frame, 11, 30), .{ 0, 0, 255, 255 }, 1));
    try std.testing.expect(near(pixel(&frame, 40, 30), .{ 255, 255, 255, 255 }, 1));
}

test "a shadow fades with distance from its edge" {
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);
    try list.shadow(std.testing.allocator, .{ .x = 30, .y = 20, .width = 36, .height = 24 }, 4, 8, scene.rgba(0x000000ff));
    const frame = try render(&list, scene.rgba(0xffffffff));
    const inside = pixel(&frame, 48, 32)[0];
    const edge = pixel(&frame, 30, 32)[0];
    const near_out = pixel(&frame, 26, 32)[0];
    const far_out = pixel(&frame, 18, 32)[0];
    // Dark inside, mid-grey at the edge, lighter outward, white past the blur.
    try std.testing.expect(inside < 10);
    try std.testing.expect(edge > 100 and edge < 160);
    try std.testing.expect(near_out > edge);
    try std.testing.expect(far_out > 250);
}

test "later shapes draw over earlier ones, with alpha" {
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);
    try list.rect(std.testing.allocator, .{ .x = 0, .y = 0, .width = 96, .height = 64 }, .{ .fill = scene.rgba(0x0000ffff) });
    try list.rect(std.testing.allocator, .{ .x = 20, .y = 20, .width = 20, .height = 20 }, .{ .fill = scene.rgba(0xff000080) });
    const frame = try render(&list, scene.rgba(0x000000ff));
    // Half red over blue: 128 red, 127 blue.
    try std.testing.expect(near(pixel(&frame, 30, 30), .{ 128, 0, 127, 255 }, 2));
}
