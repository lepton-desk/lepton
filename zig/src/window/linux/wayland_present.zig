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

/// Allocates the shared-memory buffer a frame is drawn into.
///
/// A memfd is used rather than a named shm object: the compositor needs a file
/// descriptor, not a name, and an anonymous one cannot be reached by another
/// process on the machine.
pub fn allocBuffer(self: *WaylandWindow, size: Size, format: window.PixelFormat) Error![*]u8 {
    self.releaseBuffer();

    const bytes = size.frameBytes(format);
    if (bytes == 0) return error.SizeRefused;
    if (self.shm == null) return error.BufferRefused;

    const fd = memfd() catch return error.BufferRefused;
    errdefer _ = linux.close(fd);

    // `ftruncate` then `mmap`: the compositor maps the same pages this process
    // writes, so a frame reaches the screen without a copy.
    if (linux.ftruncate(fd, @intCast(bytes)) != 0) return error.BufferRefused;

    const mapped = posix.mmap(null, bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch
        return error.BufferRefused;

    self.buffer_fd = fd;
    self.buffer_ptr = mapped.ptr;
    self.buffer_len = bytes;
    return mapped.ptr;
}

/// Attaches the current buffer to the surface and commits it.
///
/// Returns the pool and buffer objects so the caller can destroy them, or null
/// when the compositor's error is already latched — in which case the frame is
/// dropped rather than drawn into a surface nobody will show.
pub fn present(self: *WaylandWindow, size: Size) Error!void {
    const surface = self.surface orelse return error.DisplayLost;
    if (self.buffer_ptr == null) return error.BufferRefused;
    const shm = self.shm orelse return error.BufferRefused;

    const pool = wl.wl_shm_create_pool(shm, self.buffer_fd, @intCast(self.buffer_len));
    const stride = size.stride(.argb8888);
    const buffer = wl.wl_shm_pool_create_buffer(
        pool,
        0,
        @intCast(size.width),
        @intCast(size.height),
        @intCast(stride),
        self.wl_format,
    );

    wl.wl_surface_attach(surface, buffer, 0, 0);
    wl.wl_surface_damage_buffer(surface, 0, 0, @intCast(size.width), @intCast(size.height));
    wl.wl_surface_commit(surface);

    // The pool only has to outlive the buffer's creation; the compositor holds
    // its own mapping of the pages.
    wl.wl_shm_pool_destroy(pool);
    wl.wl_buffer_destroy(buffer);

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
    if (!self.gpu_settled) {
        self.gpu = presenter.open(
            @ptrCast(self.display),
            @ptrCast(self.surface),
            frame.width,
            frame.height,
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
    if (!self.gpu_settled) {
        self.gpu = presenter.open(@ptrCast(self.display), @ptrCast(self.surface), frame.width, frame.height);
        self.gpu_settled = true;
    }
    const gpu = if (self.gpu) |*gpu| gpu else return error.GpuRefused;
    gpu.presentScene(list, glyphs, clear, frame.width, frame.height, before_swap) catch return error.GpuRefused;
}

/// Unmaps the framebuffer and closes its descriptor.
pub fn releaseBuffer(self: *WaylandWindow) void {
    if (self.buffer_ptr) |ptr| posix.munmap(@as([*]align(4096) const u8, @ptrCast(@alignCast(ptr)))[0..self.buffer_len]);
    if (self.buffer_fd >= 0) _ = linux.close(self.buffer_fd);
    self.buffer_ptr = null;
    self.buffer_fd = -1;
    self.buffer_len = 0;
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
