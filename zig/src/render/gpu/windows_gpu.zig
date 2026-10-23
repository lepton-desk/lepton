//! Which GPU backend draws the native path on Windows, and the one surface the template
//! calls whichever it is (`docs/plans/windows.md`): Vulkan on a device past the threshold
//! (`vulkan_threshold.zig`), then Direct3D 11, then OpenGL 3.3 core, tried in that order; a
//! refusal moves to the next, and the last refusal is the CPU path.
//! `LEPTON_GPU=vulkan|d3d11|gl|cpu` names one (to measure or compare it), and only that one
//! is tried — Vulkan then without the threshold.

const std = @import("std");
const scene = @import("../scene.zig");
const atlas = @import("../atlas.zig");
pub const vulkan = @import("vulkan.zig");
pub const d3d11 = @import("d3d11.zig");
pub const gl33 = @import("gl33.zig");

const c = @import("c_windows");

pub const Pacing = @import("../../window/window.zig").Pacing;

pub const Backend = enum { vulkan, d3d11, gl };

/// What `LEPTON_GPU` asks for: one backend, the CPU, or (unset or unknown) the order above.
pub const Choice = union(enum) { cascade, only: Backend, cpu };

pub fn choice() Choice {
    const value = std.c.getenv("LEPTON_GPU") orelse return .cascade;
    return choose(std.mem.span(value));
}

fn choose(name: []const u8) Choice {
    if (std.mem.eql(u8, name, "cpu")) return .cpu;
    if (std.meta.stringToEnum(Backend, name)) |backend| return .{ .only = backend };
    return .cascade;
}

pub const Size = struct { width: u32, height: u32 };

pub const Renderer = union(Backend) {
    vulkan: vulkan.Renderer,
    d3d11: d3d11.Renderer,
    gl: gl33.Renderer,

    /// Why each backend tried before the one that opened refused, for the caller to report.
    pub const Refusal = struct { backend: Backend, reason: anyerror };
    pub const Refusals = struct {
        items: [std.enums.values(Backend).len]Refusal = undefined,
        len: usize = 0,

        pub fn slice(self: *const Refusals) []const Refusal {
            return self.items[0..self.len];
        }
    };

    /// The first backend of `choice` that opens on `window`. Null with `refused` filled when
    /// none did (or `LEPTON_GPU=cpu`): the caller draws on the CPU.
    pub fn open(window: c.HWND, width: u32, height: u32, pacing: Pacing, refused: *Refusals) ?Renderer {
        const chosen = choice();
        const order: []const Backend = switch (chosen) {
            .cpu => return null,
            .only => |backend| &.{backend},
            .cascade => &.{ .vulkan, .d3d11, .gl },
        };
        for (order) |backend| {
            const opened: anyerror!Renderer = switch (backend) {
                .vulkan => if (vulkan.Renderer.open(window, width, height, pacing, chosen == .cascade)) |r| .{ .vulkan = r } else |err| err,
                .d3d11 => if (d3d11.Renderer.open(window, width, height, pacing)) |r| .{ .d3d11 = r } else |err| err,
                .gl => if (gl33.Renderer.open(window, width, height, pacing)) |r| .{ .gl = r } else |err| err,
            };
            if (opened) |renderer| return renderer else |err| {
                refused.items[refused.len] = .{ .backend = backend, .reason = err };
                refused.len += 1;
            }
        }
        return null;
    }

    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            inline else => |*renderer| renderer.deinit(),
        }
    }

    /// What the window waits on between frames, if anything (`NativeWindow.setFrameWait`).
    pub fn frameWait(self: *const Renderer) ?*anyopaque {
        return switch (self.*) {
            .d3d11 => |*renderer| renderer.frameWait(),
            .vulkan, .gl => null,
        };
    }

    /// Whether the present waits for the display itself (`NativeWindow.setPresentPaces`).
    pub fn pacesItself(self: *const Renderer) bool {
        return switch (self.*) {
            inline else => |*renderer| renderer.pacesItself(),
        };
    }

    pub fn draw(self: *Renderer, list: *const scene.List, glyphs: *atlas.Atlas, clear: [4]f32, size: Size) !void {
        switch (self.*) {
            inline else => |*renderer| try renderer.draw(list, glyphs, clear, .{ .width = size.width, .height = size.height }),
        }
    }

    /// "vulkan", "d3d11" or "gl", as `LEPTON_GPU` names it and the template prints it.
    pub fn name(self: *const Renderer) []const u8 {
        return @tagName(self.*);
    }
};

test "LEPTON_GPU names one backend or the CPU, and anything else is the cascade" {
    try std.testing.expectEqual(Choice.cpu, choose("cpu"));
    try std.testing.expectEqual(Choice{ .only = .vulkan }, choose("vulkan"));
    try std.testing.expectEqual(Choice{ .only = .d3d11 }, choose("d3d11"));
    try std.testing.expectEqual(Choice{ .only = .gl }, choose("gl"));
    try std.testing.expectEqual(Choice.cascade, choose("gles"));
    try std.testing.expectEqual(Choice.cascade, choose(""));
}
