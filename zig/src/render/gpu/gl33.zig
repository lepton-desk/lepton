//! The draw command list (`render/scene.zig`) on OpenGL 3.3 core: the Windows GPU path for a
//! machine with neither Vulkan past the threshold nor Direct3D 11 (`docs/plans/windows.md`).
//! The GLES 3 backend's shaders (`render/scene_glsl.zig`) under `#version 330 core`, the same
//! 64-byte instances, one instanced draw a frame, on a WGL context made on the window.
//!
//! opengl32.dll exports only OpenGL 1.1; every later function is asked for with
//! `wglGetProcAddress` once the context is current (`Gl.load`), and a missing one is a
//! refusal like any other — the caller falls back to the CPU. Frames are paced by the swap
//! interval (`wglSwapIntervalEXT`): 1 waits for the display inside `SwapBuffers`, 0 is
//! `unlimited` pacing.

const std = @import("std");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");
const glsl = @import("../scene_glsl.zig");

const c = @import("c_windows");

pub const Pacing = @import("../../window/window.zig").Pacing;

pub const Error = error{ NoPixelFormat, NoContext, NoCurrent, NoFunction, NoShader, NoProgram, NoBuffer, DeviceLost };

const vertex_source: [:0]const u8 = "#version 330 core\n" ++ glsl.vertex_body;
const fragment_source: [:0]const u8 = "#version 330 core\n" ++ glsl.fragment_body;

/// The OpenGL functions this backend calls, by their GL names: each field is loaded by its
/// own name (`load`), typed by its `PFN…PROC` from `glcorearb.h`.
const names = [_][:0]const u8{
    "glViewport",            "glClearColor",          "glClear",                   "glEnable",
    "glBlendFunc",           "glGenTextures",         "glBindTexture",             "glTexImage2D",
    "glTexParameteri",       "glTexSubImage2D",       "glPixelStorei",             "glDeleteTextures",
    "glGetString",           "glFinish",              "glReadPixels",              "glCreateShader",
    "glShaderSource",        "glCompileShader",       "glGetShaderiv",             "glGetShaderInfoLog",
    "glDeleteShader",        "glCreateProgram",       "glAttachShader",            "glLinkProgram",
    "glGetProgramiv",        "glDeleteProgram",       "glUseProgram",              "glGetUniformLocation",
    "glUniform1i",           "glUniform2f",           "glGenVertexArrays",         "glBindVertexArray",
    "glDeleteVertexArrays",  "glGenBuffers",          "glBindBuffer",              "glBufferData",
    "glBufferSubData",       "glDeleteBuffers",       "glEnableVertexAttribArray", "glVertexAttribPointer",
    "glVertexAttribDivisor", "glDrawArraysInstanced", "glActiveTexture",           "glGenQueries",
    "glDeleteQueries",       "glQueryCounter",        "glGetQueryObjectui64v",
};

fn pfnName(comptime name: []const u8) []const u8 {
    comptime var upper: [name.len]u8 = undefined;
    inline for (name, 0..) |char, at| upper[at] = std.ascii.toUpper(char);
    const fixed = upper;
    return "PFN" ++ fixed ++ "PROC";
}

/// One field per entry of `names`, a non-null function pointer.
pub const Gl = blk: {
    @setEvalBranchQuota(20_000);
    var types: [names.len]type = undefined;
    for (names, 0..) |name, at| types[at] = @typeInfo(@field(c, pfnName(name))).optional.child;
    // `@Struct`: Zig 0.16 replaced `@Type` with one builtin per kind (measured).
    const attributes: [names.len]std.builtin.Type.StructField.Attributes = @splat(.{});
    break :blk @Struct(.auto, null, &names, &types, &attributes);
};

/// Every function of `Gl`, from the current context (`wglGetProcAddress`), or opengl32.dll
/// itself for OpenGL 1.1's, which `wglGetProcAddress` does not answer.
fn load() Error!Gl {
    const library = c.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll")) orelse return error.NoFunction;
    var gl: Gl = undefined;
    inline for (names) |name| {
        const found: ?*const anyopaque = blk: {
            const asked = c.wglGetProcAddress(name.ptr);
            // Some drivers answer 1, 2, 3 or -1 for a name they do not have.
            const value = @intFromPtr(asked);
            if (asked != null and value > 3 and value != std.math.maxInt(usize)) break :blk @ptrCast(asked);
            break :blk @ptrCast(c.GetProcAddress(library, name.ptr));
        };
        @field(gl, name) = @ptrCast(found orelse return error.NoFunction);
    }
    return gl;
}

pub const Renderer = struct {
    window: c.HWND,
    dc: c.HDC,
    context: c.HGLRC,
    gl: Gl,
    pacing: Pacing,
    program: c.GLuint,
    vertex_array: c.GLuint,
    instances: c.GLuint,
    /// Bytes the instance buffer holds; it grows, never shrinks.
    capacity: usize = 0,
    size_location: c.GLint,
    atlas_texture: c.GLuint,
    width: u32,
    height: u32,
    /// Bytes handed to the driver by `draw`, all frames: the instances, and the atlas regions
    /// seen for the first time.
    uploaded: u64 = 0,
    /// "3.3.14761 Core Profile Context 21.40.11.03", as the driver reports it.
    version: []const u8 = "",
    renderer_name: []const u8 = "",

    /// A 3.3 core context on `window` (whose pixel format is set here: a window can take one
    /// pixel format in its life, so a window that tried another backend first is fine only
    /// if that backend set none). Any refusal is an error, and the caller tries the next.
    pub fn open(window: c.HWND, width: u32, height: u32, pacing: Pacing) Error!Renderer {
        const dc = c.GetDC(window) orelse return error.NoPixelFormat;
        errdefer _ = c.ReleaseDC(window, dc);
        var format = std.mem.zeroes(c.PIXELFORMATDESCRIPTOR);
        format.nSize = @sizeOf(c.PIXELFORMATDESCRIPTOR);
        format.nVersion = 1;
        format.dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER;
        format.iPixelType = c.PFD_TYPE_RGBA;
        format.cColorBits = 32;
        format.cAlphaBits = 8;
        format.iLayerType = c.PFD_MAIN_PLANE;
        const chosen = c.ChoosePixelFormat(dc, &format);
        if (chosen == 0 or c.SetPixelFormat(dc, chosen, &format) == 0) return error.NoPixelFormat;

        // A legacy context first: `wglCreateContextAttribsARB`, which makes the core one, is
        // only answered while some context is current.
        const legacy = c.wglCreateContext(dc) orelse return error.NoContext;
        defer _ = c.wglDeleteContext(legacy);
        if (c.wglMakeCurrent(dc, legacy) == 0) return error.NoCurrent;
        const create: c.PFNWGLCREATECONTEXTATTRIBSARBPROC = @ptrCast(c.wglGetProcAddress("wglCreateContextAttribsARB"));
        const attributes = [_]c_int{
            c.WGL_CONTEXT_MAJOR_VERSION_ARB, 3,
            c.WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            c.WGL_CONTEXT_PROFILE_MASK_ARB,  c.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const context = if (create) |make| make(dc, null, &attributes) else null;
        _ = c.wglMakeCurrent(null, null);
        const core = context orelse return error.NoContext;
        errdefer _ = c.wglDeleteContext(core);
        if (c.wglMakeCurrent(dc, core) == 0) return error.NoCurrent;
        errdefer _ = c.wglMakeCurrent(null, null);

        const interval: c.PFNWGLSWAPINTERVALEXTPROC = @ptrCast(c.wglGetProcAddress("wglSwapIntervalEXT"));
        if (interval) |set| _ = set(if (pacing == .unlimited) 0 else 1);

        var self: Renderer = .{
            .window = window,
            .dc = dc,
            .context = core,
            .gl = try load(),
            .pacing = pacing,
            .program = 0,
            .vertex_array = 0,
            .instances = 0,
            .size_location = -1,
            .atlas_texture = 0,
            .width = width,
            .height = height,
        };
        try self.setup();
        self.version = self.string(c.GL_VERSION);
        self.renderer_name = self.string(c.GL_RENDERER);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const gl = &self.gl;
        gl.glDeleteTextures(1, &self.atlas_texture);
        gl.glDeleteBuffers(1, &self.instances);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
        gl.glDeleteProgram(self.program);
        _ = c.wglMakeCurrent(null, null);
        _ = c.wglDeleteContext(self.context);
        _ = c.ReleaseDC(self.window, self.dc);
        self.* = undefined;
    }

    /// The swap interval waits for the display inside `SwapBuffers`: the window must not
    /// wait a frame period as well (`NativeWindow.present_paces`).
    pub fn pacesItself(_: *const Renderer) bool {
        return true;
    }

    /// Draws `list` over `clear` at `size` and swaps it onto the window.
    pub fn draw(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) Error!void {
        try self.record(list, glyphs, clear, size);
        try self.present();
    }

    /// `draw` up to the swap (`tools/windows_gpu_rate.zig` times this part alone).
    pub fn record(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) Error!void {
        const gl = &self.gl;
        if (size.width != 0 and size.height != 0) {
            self.width = size.width;
            self.height = size.height;
        }
        self.syncAtlas(glyphs);
        gl.glViewport(0, 0, @intCast(self.width), @intCast(self.height));
        gl.glClearColor(clear[0] * clear[3], clear[1] * clear[3], clear[2] * clear[3], clear[3]);
        gl.glClear(c.GL_COLOR_BUFFER_BIT);
        const bytes = list.bytes();
        if (bytes.len == 0) return;
        gl.glBindBuffer(c.GL_ARRAY_BUFFER, self.instances);
        if (bytes.len > self.capacity) {
            gl.glBufferData(c.GL_ARRAY_BUFFER, @intCast(bytes.len), bytes.ptr, c.GL_STREAM_DRAW);
            self.capacity = bytes.len;
        } else {
            gl.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(bytes.len), bytes.ptr);
        }
        self.uploaded += bytes.len;
        gl.glUseProgram(self.program);
        gl.glUniform2f(self.size_location, @floatFromInt(self.width), @floatFromInt(self.height));
        gl.glActiveTexture(c.GL_TEXTURE0);
        gl.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        gl.glEnable(c.GL_BLEND);
        gl.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        gl.glBindVertexArray(self.vertex_array);
        gl.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(list.instances.items.len));
        gl.glBindVertexArray(0);
    }

    /// Shows the frame `record` drew, as the swap interval says.
    pub fn present(self: *Renderer) Error!void {
        if (c.SwapBuffers(self.dc) == 0) return error.DeviceLost;
    }

    pub const Size = struct { width: u32, height: u32 };

    /// Sends the atlas region glyphs were added to since the last frame, and nothing else.
    fn syncAtlas(self: *Renderer, glyphs: *atlas.Atlas) void {
        const region = glyphs.takeDirty() orelse return;
        const gl = &self.gl;
        gl.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        gl.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        gl.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, atlas.side);
        const first = glyphs.pixels[@as(usize, region.y) * atlas.side + region.x ..];
        gl.glTexSubImage2D(c.GL_TEXTURE_2D, 0, @intCast(region.x), @intCast(region.y), @intCast(region.width), @intCast(region.height), c.GL_RED, c.GL_UNSIGNED_BYTE, first.ptr);
        gl.glPixelStorei(c.GL_UNPACK_ROW_LENGTH, 0);
        self.uploaded += @as(u64, region.width) * region.height;
    }

    fn string(self: *Renderer, name: c.GLenum) []const u8 {
        const text: [*:0]const u8 = @ptrCast(self.gl.glGetString(name) orelse return "unknown");
        return std.mem.span(text);
    }

    fn compile(self: *Renderer, kind: c.GLenum, source: [:0]const u8) Error!c.GLuint {
        const gl = &self.gl;
        const shader = gl.glCreateShader(kind);
        if (shader == 0) return error.NoShader;
        const sources = [_][*c]const u8{source.ptr};
        gl.glShaderSource(shader, 1, &sources, null);
        gl.glCompileShader(shader);
        var ok: c.GLint = 0;
        gl.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            var log: [1024]u8 = undefined;
            var len: c.GLsizei = 0;
            gl.glGetShaderInfoLog(shader, log.len, &len, &log);
            std.debug.print("gl33         shader: {s}\n", .{log[0..@intCast(len)]});
            gl.glDeleteShader(shader);
            return error.NoShader;
        }
        return shader;
    }

    /// The program, the instance buffer and its attributes, the atlas texture.
    fn setup(self: *Renderer) Error!void {
        const gl = &self.gl;
        const vertex = try self.compile(c.GL_VERTEX_SHADER, vertex_source);
        defer gl.glDeleteShader(vertex);
        const fragment = try self.compile(c.GL_FRAGMENT_SHADER, fragment_source);
        defer gl.glDeleteShader(fragment);
        const program = gl.glCreateProgram();
        gl.glAttachShader(program, vertex);
        gl.glAttachShader(program, fragment);
        gl.glLinkProgram(program);
        var linked: c.GLint = 0;
        gl.glGetProgramiv(program, c.GL_LINK_STATUS, &linked);
        if (linked == 0) {
            gl.glDeleteProgram(program);
            return error.NoProgram;
        }
        self.program = program;

        gl.glGenVertexArrays(1, &self.vertex_array);
        gl.glGenBuffers(1, &self.instances);
        if (self.vertex_array == 0 or self.instances == 0) return error.NoBuffer;
        gl.glBindVertexArray(self.vertex_array);
        gl.glBindBuffer(c.GL_ARRAY_BUFFER, self.instances);
        const stride: c.GLsizei = @sizeOf(scene.Instance);
        const offsets = [_]usize{
            @offsetOf(scene.Instance, "rect"),
            @offsetOf(scene.Instance, "fill"),
            @offsetOf(scene.Instance, "border_colour"),
            @offsetOf(scene.Instance, "params"),
        };
        for (offsets, 0..) |offset, location| {
            gl.glEnableVertexAttribArray(@intCast(location));
            gl.glVertexAttribPointer(@intCast(location), 4, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(offset));
            gl.glVertexAttribDivisor(@intCast(location), 1);
        }
        gl.glBindVertexArray(0);

        gl.glGenTextures(1, &self.atlas_texture);
        if (self.atlas_texture == 0) return error.NoBuffer;
        gl.glBindTexture(c.GL_TEXTURE_2D, self.atlas_texture);
        gl.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, atlas.side, atlas.side, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        gl.glUseProgram(program);
        gl.glUniform1i(gl.glGetUniformLocation(program, "u_atlas"), 0);
        self.size_location = gl.glGetUniformLocation(program, "u_size");
    }
};
