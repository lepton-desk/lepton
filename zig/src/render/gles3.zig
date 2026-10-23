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
pub const atlas = @import("atlas.zig");
pub const glyph_text = @import("glyph_text.zig");
/// This build can draw the command list on the GPU (`core.gles3.available`).
pub const available = true;

const c = @import("c_gles3");

/// `EGL_OPENGL_ES3_BIT` (EGL 1.5 / `EGL_KHR_create_context`), not in every `egl.h`.
const egl_opengl_es3_bit: c.EGLint = 0x0040;

pub const Error = error{ NoDisplay, NoConfig, NoSurface, NoContext, NoCurrent, NoShader, NoProgram, NoBuffer };

const glsl = @import("scene_glsl.zig");
const vertex_source: [:0]const u8 = "#version 300 es\n" ++ glsl.vertex_body;
const fragment_source: [:0]const u8 = "#version 300 es\nprecision highp float;\n" ++ glsl.fragment_body;

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
    /// The glyph atlas on the GPU (`GL_R8`, `atlas.side` square).
    atlas_texture: c.GLuint,
    /// Atlas bytes sent by `syncAtlas`, all frames: only glyphs seen for the first time.
    atlas_uploaded: u64 = 0,
    width: u32,
    height: u32,
    /// Bytes handed to the driver by `draw`, all frames: the figure this path exists for.
    uploaded: u64 = 0,

    pub fn deinit(self: *Renderer) void {
        c.glDeleteTextures(1, &self.atlas_texture);
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
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glBindVertexArray(self.vertex_array);
        c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(list.instances.items.len));
        c.glBindVertexArray(0);
    }

    /// Sends the part of `glyphs` that changed since the last call: one sub-image upload.
    pub fn syncAtlas(self: *Renderer, glyphs: *atlas.Atlas) void {
        const region = glyphs.takeDirty() orelse return;
        c.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, atlas.side);
        const first = glyphs.pixels[region.y * atlas.side + region.x ..];
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, @intCast(region.x), @intCast(region.y), @intCast(region.width), @intCast(region.height), c.GL_RED, c.GL_UNSIGNED_BYTE, first.ptr);
        c.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
        self.atlas_uploaded += @as(u64, region.width) * region.height;
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

    var atlas_texture: c.GLuint = 0;
    c.glGenTextures(1, &atlas_texture);
    if (atlas_texture == 0) return error.NoBuffer;
    c.glBindTexture(c.GL_TEXTURE_2D, atlas_texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, atlas.side, atlas.side, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, null);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    c.glUseProgram(program);
    c.glUniform1i(c.glGetUniformLocation(program, "u_atlas"), 0);

    return .{
        .display = display,
        .surface = surface,
        .context = context,
        .owns_egl = owns,
        .program = program,
        .vertex_array = vertex_array,
        .instances = instances,
        .size_location = c.glGetUniformLocation(program, "u_size"),
        .atlas_texture = atlas_texture,
        .width = width,
        .height = height,
    };
}

/// A renderer on a window's EGL display, surface and ES 3 context, borrowed from the
/// presenter (`gpu/presenter.zig`), which keeps them. The context must be current.
pub fn attach(display: c.EGLDisplay, surface: c.EGLSurface, context: c.EGLContext, width: u32, height: u32) Error!Renderer {
    return setup(display, surface, context, false, width, height);
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

test "a glyph is the atlas's coverage, tinted" {
    var glyphs = try atlas.Atlas.init(std.testing.allocator);
    defer glyphs.deinit(std.testing.allocator);
    // A 4×4 coverage block: left half full, right half none.
    const bitmap = comptime blk: {
        var bytes: [16]u8 = undefined;
        for (0..4) |at| @memcpy(bytes[at * 4 ..][0..4], &[_]u8{ 255, 255, 0, 0 });
        break :blk bytes;
    };
    const slot = (try glyphs.put(std.testing.allocator, .{ .font = 0, .glyph = 1, .size = 4 }, 4, 4, 4, &bitmap, 0, 4)).?;
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);
    // Drawn 4× larger: 16×16, so the halves are 8 pixels wide.
    try list.glyph(std.testing.allocator, .{ .x = 40, .y = 20, .width = 16, .height = 16 }, slot.uv(), scene.rgba(0xff0000ff));
    var renderer = try open(test_width, test_height);
    defer renderer.deinit();
    renderer.syncAtlas(&glyphs);
    try std.testing.expectEqual(@as(u64, 16), renderer.atlas_uploaded);
    renderer.draw(&list, scene.rgba(0x000000ff));
    renderer.finish();
    var frame: [test_width * test_height * 4]u8 = undefined;
    renderer.read(&frame);
    try std.testing.expect(near(pixel(&frame, 42, 28), .{ 255, 0, 0, 255 }, 2));
    try std.testing.expect(near(pixel(&frame, 53, 28), .{ 0, 0, 0, 255 }, 2));
    // Nothing more to send until a new glyph arrives.
    renderer.syncAtlas(&glyphs);
    try std.testing.expectEqual(@as(u64, 16), renderer.atlas_uploaded);
}

test "text is shaped, rasterised once and drawn where the pen put it" {
    const text = @import("glyph_text.zig");
    var path_buffer: [1024]u8 = undefined;
    const path = try text.find("sans", &path_buffer);
    var font = try text.Font.open(std.testing.allocator, path, 20, 0);
    defer font.deinit();
    var glyphs = try atlas.Atlas.init(std.testing.allocator);
    defer glyphs.deinit(std.testing.allocator);
    var list: scene.List = .{};
    defer list.deinit(std.testing.allocator);

    const advance = try font.draw(std.testing.allocator, &glyphs, &list, "Lepton", 6, 40, scene.rgba(0x000000ff));
    try std.testing.expectEqual(@as(usize, 6), list.instances.items.len);
    try std.testing.expect(advance > 40 and advance < 90);

    var renderer = try open(test_width, test_height);
    defer renderer.deinit();
    renderer.syncAtlas(&glyphs);
    const first_upload = renderer.atlas_uploaded;
    renderer.draw(&list, scene.rgba(0xffffffff));
    renderer.finish();
    var frame: [test_width * test_height * 4]u8 = undefined;
    renderer.read(&frame);

    // Ink between the pen's start and its end, above the baseline; none below the
    // descender line or past the advance.
    var ink: usize = 0;
    var stray: usize = 0;
    for (0..test_height) |y| {
        for (0..test_width) |x| {
            const dark = pixel(&frame, x, y)[0] < 128;
            const inside = x >= 6 and x <= 6 + @as(usize, @intFromFloat(advance)) and y >= 40 - 20 and y <= 40 + 6;
            if (dark and inside) ink += 1;
            if (dark and !inside) stray += 1;
        }
    }
    try std.testing.expect(ink > 80);
    try std.testing.expectEqual(@as(usize, 0), stray);

    // The same text again: every glyph is in the atlas, nothing more to send.
    list.clear();
    _ = try font.draw(std.testing.allocator, &glyphs, &list, "Lepton", 6, 40, scene.rgba(0x000000ff));
    renderer.syncAtlas(&glyphs);
    // Shaped once, kept by its text.
    try std.testing.expectEqual(@as(u32, 1), font.runs.count());
    try std.testing.expect(first_upload > 0);
    try std.testing.expectEqual(first_upload, renderer.atlas_uploaded);
}
