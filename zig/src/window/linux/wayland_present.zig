//! Frame presentation for the Wayland window: the shared-memory buffer the compositor
//! maps, and the GPU presenter that replaces it when the driver accepts one.
//!
//! Split out of `wayland_window.zig` by responsibility; `WaylandWindow`'s methods of the
//! same names forward here, so callers see no change.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const wl = @import("wayland_c.zig").wl;
const presenter = @import("../../render/gpu/presenter.zig");
const window = @import("../window.zig");
const wayland_window = @import("wayland_window.zig");

const WaylandWindow = wayland_window.WaylandWindow;
const Error = wayland_window.Error;
const Size = window.Size;

/// Whether this build can present through the GPU at all. EGL, GLESv2 and wayland-egl
/// are linked into the core only for the native render path (`build.zig`), so a webview
/// build that merely *referenced* the presenter failed to link: `window-check` never
/// presents through it, yet `WaylandWindow.close`'s `gpu.deinit()` alone left ten EGL/GL
/// symbols undefined (measured 2026-10-18). Compiled out, every frame takes shared memory.
/// A native build without EGL's headers has no presenter either (`have_egl`).
pub const gpu_present = @import("build_options").native_render and @import("build_options").have_egl;

/// One shared-memory buffer: a memfd mapped here and by the compositor, its pool and its
/// `wl_buffer`, kept while the window keeps its size.
///
/// Measured before this (2026-10-18, `strace -c`, 8 s of a native app with
/// `LEPTON_PRESENT=shm`): every frame made a new memfd, `ftruncate`, `mmap`, pool and buffer
/// and threw them away (2301 `memfd_create` in ~7 s), and nothing paced the loop, so it
/// painted ~300 frames a second for a 60 Hz screen — 9.06 s of CPU in 10 s. The buffer
/// was also destroyed right after its commit and its memory drawn over by the next frame
/// while the compositor could still be reading it.
pub const ShmFrame = struct {
    fd: linux.fd_t = -1,
    ptr: ?[*]u8 = null,
    len: usize = 0,
    pool: ?*wl.wl_shm_pool = null,
    buffer: ?*wl.wl_buffer = null,
    size: Size = .{ .width = 0, .height = 0 },
    /// Committed and not yet released by the compositor: not to be drawn into.
    busy: bool = false,

    fn destroy(self: *ShmFrame) void {
        if (self.buffer) |buffer| wl.wl_buffer_destroy(buffer);
        if (self.pool) |pool| wl.wl_shm_pool_destroy(pool);
        if (self.ptr) |ptr| posix.munmap(@as([*]align(4096) const u8, @ptrCast(@alignCast(ptr)))[0..self.len]);
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.* = .{};
    }
};

/// How long a present waits for the compositor before going ahead: a hidden or minimised
/// window gets no frame callbacks, and must not stop the loop.
const pace_limit_ms = 100;

fn onRelease(data: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {
    const frame: *ShmFrame = @ptrCast(@alignCast(data orelse return));
    frame.busy = false;
}

fn onFrameDone(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data orelse return));
    if (callback) |done| wl.wl_callback_destroy(done);
    self.frame_callback = null;
}

const buffer_listener = wl.wl_buffer_listener{ .release = onRelease };
const frame_listener = wl.wl_callback_listener{ .done = onFrameDone };

fn now() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake);
}

/// Dispatches the connection until `done` holds or `pace_limit_ms` has passed.
fn waitUntil(self: *WaylandWindow, comptime done: fn (*WaylandWindow) bool) Error!void {
    const started = now();
    while (!done(self)) {
        const waited = started.durationTo(now()).raw.nanoseconds;
        const left = pace_limit_ms - @divTrunc(@max(waited, 0), std.time.ns_per_ms);
        if (left <= 0) return;
        try self.waitEvents(@intCast(left));
    }
}

fn hasFreeFrame(self: *WaylandWindow) bool {
    return !self.frames[0].busy or !self.frames[1].busy;
}

fn frameShown(self: *WaylandWindow) bool {
    return self.frame_callback == null;
}

/// The memory the next frame is drawn into: a buffer the compositor is not reading,
/// made again only when the size changed.
///
/// A memfd is used rather than a named shm object: the compositor needs a file
/// descriptor, not a name, and an anonymous one cannot be reached by another
/// process on the machine.
pub fn allocBuffer(self: *WaylandWindow, size: Size, format: window.PixelFormat) Error![*]u8 {
    const bytes = size.frameBytes(format);
    if (bytes == 0) return error.SizeRefused;
    const shm = self.shm orelse return error.BufferRefused;

    if (!hasFreeFrame(self)) try waitUntil(self, hasFreeFrame);
    // Both still held past the limit (a compositor that never releases): the older one
    // is drawn over rather than the loop stopping.
    const index: usize = if (!self.frames[0].busy) 0 else if (!self.frames[1].busy) 1 else 0;
    const frame = &self.frames[index];
    self.drawing = index;
    if (frame.ptr != null and frame.size.width == size.width and frame.size.height == size.height) {
        return frame.ptr orelse error.BufferRefused;
    }

    frame.destroy();
    const fd = memfd() catch return error.BufferRefused;
    errdefer _ = linux.close(fd);
    // `ftruncate` then `mmap`: the compositor maps the same pages this process
    // writes, so a frame reaches the screen without a copy.
    if (linux.ftruncate(fd, @intCast(bytes)) != 0) return error.BufferRefused;
    const mapped = posix.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
        return error.BufferRefused;

    const pool = wl.wl_shm_create_pool(shm, fd, @intCast(bytes));
    const buffer = wl.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(size.width),
        @intCast(size.height),
        @intCast(size.stride(format)),
        self.wl_format,
    );
    frame.* = .{ .fd = fd, .ptr = mapped.ptr, .len = bytes, .pool = pool, .buffer = buffer, .size = size };
    // The frame's address is final: it lives in the window, which does not move once open.
    _ = wl.wl_buffer_add_listener(buffer, &buffer_listener, frame);
    return mapped.ptr;
}

/// Commits the buffer `allocBuffer` handed out, once the compositor has shown the last
/// one (its frame callback), so the loop runs at the screen's rate.
pub fn present(self: *WaylandWindow, size: Size) Error!void {
    const surface = self.surface orelse return error.DisplayLost;
    const index = self.drawing orelse return error.BufferRefused;
    const frame = &self.frames[index];
    const buffer = frame.buffer orelse return error.BufferRefused;
    if (frame.size.width != size.width or frame.size.height != size.height) return error.BufferRefused;

    // Unlimited: the next frame does not wait for this one to be shown; a frame the
    // compositor never showed is replaced (its buffer released) by the next commit.
    if (self.pacing == .display and !frameShown(self)) try waitUntil(self, frameShown);
    // A callback still outstanding past the limit is dropped; a new one is asked for.
    if (self.frame_callback) |stale| wl.wl_callback_destroy(stale);
    self.frame_callback = wl.wl_surface_frame(surface);
    if (self.frame_callback) |callback| _ = wl.wl_callback_add_listener(callback, &frame_listener, self);

    wl.wl_surface_attach(surface, buffer, 0, 0);
    wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(size.width), @intCast(size.height));
    wl.wl_surface_commit(surface);
    frame.busy = true;
    self.drawing = null;
    _ = wl.wl_display_flush(self.display);

    if (wl.wl_display_get_error(self.display) != 0) return error.DisplayLost;
}

/// Copies a rendered frame into shared memory and shows it.
///
/// The copy is the price of the boundary: a renderer fills a buffer it owns, and
/// the compositor needs a mapping it can read. It is one copy per frame of pixels
/// that were going to be read by another process anyway — the alternative, giving
/// the renderer the mapping directly, would put a window-system protocol in the
/// middle of the render layer, which is the dependency the split exists to avoid.
pub fn presentPixels(self: *WaylandWindow, pixels: []const u8, frame: Size, format: window.PixelFormat) Error!void {
    // The GPU is the default and shared memory is the fallback, so the question is
    // asked once and the answer decides every frame after it.
    if (comptime gpu_present) {
        if (!self.gpu_settled) {
            self.gpu = presenter.open(
                @ptrCast(self.display),
                @ptrCast(self.surface),
                frame.width,
                frame.height,
                self.pacing,
            );
            self.gpu_settled = true;
        }
        if (self.gpu) |*gpu| {
            // `arenaAlloc`/`arenaFree` do not apply here: the GPU uploads the caller's
            // pixels directly, so there is no per-frame copy to make room for and none of
            // the shm buffer is touched on this path.
            // The reason the presenter gives is folded into one window error on purpose:
            // the caller needs to know the GPU path broke, not which of six shader and
            // surface errors it was, and a wider error set would let every caller grow a
            // branch for a failure only this path can produce.
            gpu.present(pixels, frame.width, frame.height) catch return error.GpuRefused;
            return;
        }
    } else self.gpu_settled = true;

    const target = try self.allocBuffer(frame, format);

    // Compared before the copy, not after: a frame from a renderer that thought
    // the window was a different size would otherwise be truncated silently, and a
    // truncated frame looks like a drawing bug rather than a size disagreement.
    if (pixels.len < frame.frameBytes(format)) return error.FrameTruncated;

    // `pixels` may be longer than the frame: a `Surface` keeps its capacity when it
    // shrinks, so after a resize to a smaller window the slice is the old size. Copying
    // the whole slice was a length mismatch the first time a configure ever arrived.
    const n = frame.frameBytes(format);
    @memcpy(target[0..n], pixels[0..n]);
    try self.present(frame);
}

/// Shows a draw command list, drawn by the GPU (`render/gles3.zig`). `GpuRefused` when
/// this window has no ES 3 presenter: the caller paints with the CPU instead.
pub fn presentScene(
    self: *WaylandWindow,
    list: *const presenter.Scene,
    glyphs: *presenter.Atlas,
    clear: [4]f32,
    frame: Size,
    before_swap: ?[]u8,
) Error!void {
    // A build without the GPU presenter has no ES 3 path: the caller's CPU fallback runs.
    if (comptime !gpu_present) {
        self.gpu_settled = true;
        return error.GpuRefused;
    }
    if (!self.gpu_settled) {
        self.gpu = presenter.open(@ptrCast(self.display), @ptrCast(self.surface), frame.width, frame.height, self.pacing);
        self.gpu_settled = true;
    }
    const gpu = if (self.gpu) |*gpu| gpu else return error.GpuRefused;
    gpu.presentScene(list, glyphs, clear, frame.width, frame.height, before_swap) catch return error.GpuRefused;
}

/// Releases both shared-memory buffers and any outstanding frame callback.
pub fn releaseBuffer(self: *WaylandWindow) void {
    if (self.frame_callback) |callback| wl.wl_callback_destroy(callback);
    self.frame_callback = null;
    for (&self.frames) |*frame| frame.destroy();
    self.drawing = null;
}

/// An anonymous, close-on-exec file the compositor can map.
///
/// `memfd_create` is a raw syscall in this standard library, so the descriptor has
/// to be told apart from an error code by the same rule every syscall return uses:
/// a small negative value. A frame buffer needs `CLOEXEC` so a frame in flight
/// cannot leak into a process this one spawns.
fn memfd() !posix.fd_t {
    const name: [:0]const u8 = "lepton-frame";
    const rc = linux.memfd_create(name.ptr, linux.MFD.CLOEXEC);
    // Linux reports failure as the negated errno in the low bits of the return.
    if (@as(isize, @bitCast(rc)) < 0 and @as(isize, @bitCast(rc)) > -4096) {
        return error.BufferRefused;
    }
    return @intCast(rc);
}

/// The protocol constant for a pixel format.
pub fn formatConstant(format: window.PixelFormat) u32 {
    return switch (format) {
        .argb8888 => wl.WL_SHM_FORMAT_ARGB8888,
        .xrgb8888 => wl.WL_SHM_FORMAT_XRGB8888,
    };
}
