//! Opens a real window and reports what the display server said about it.
//!
//! This is the check that the window layer is a window layer and not a plausible
//! looking struct: it connects to whatever compositor or X server the machine has,
//! asks for a window, and prints the size that came back. On a headless host it
//! says so and exits, rather than reporting a geometry it invented.
//!
//! Run with `zig build window-check`.

const std = @import("std");
const core = @import("lepton_core");

const check_timeout_ms = 2_000;

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io(), &stdout_buffer);
    const out = &stdout.interface;

    const display = core.display.Display.probe(core.display.processGetenv, null) catch |e| {
        try out.print("no display server: {t}\n", .{e});
        try out.flush();
        return 1;
    };

    try out.print("session      {s}\n", .{display.session.label()});
    try out.print("screen       {d}x{d}\n", .{ display.width, display.height });
    try out.print("refresh      ", .{});
    if (display.refresh_mhz == 0) {
        try out.writeAll("not reported by the server\n");
    } else {
        try out.print("{d}.{d} Hz\n", .{ display.refresh_mhz / 1000, (display.refresh_mhz % 1000) / 100 });
    }

    var request: core.window.Request = .{
        .title = "Lepton window check",
        .app_id = "dev.lepton.windowcheck",
        .size = .{ .width = 900, .height = 640 },
    };

    switch (display.session) {
        .wayland => {
            var w: core.waylandWindow.WaylandWindow = undefined;
            try w.open(allocator, request);
            defer w.close();

            const requested = request.size;
            const configured = w.currentSize();
            try out.print("requested    {d}x{d}\n", .{ requested.width, requested.height });
            try out.print("configured   {d}x{d}\n", .{ configured.width, configured.height });
            try out.print("title        \"{s}\"\n", .{std.mem.sliceTo(&w.title, 0)});

            // A compositor that accepted the window is the only evidence that the
            // xdg-shell handshake worked. A size of zero would mean it did not.
            if (configured.isEmpty()) {
                try out.writeAll("result       no configure received — the window was not mapped\n");
                try out.flush();
                return 2;
            }

            // Allocate a real buffer and present it, which exercises the shm path
            // end to end: memfd, mmap, pool, buffer, attach, commit.
            const pixels = try w.allocBuffer(configured, request.format);
            const pixel = request.format.pixelWord();
            const stride = configured.stride(request.format);
            for (0..configured.height) |y| {
                var row: usize = 0;
                while (row < configured.width) : (row += 1) {
                    std.mem.writeInt(u32, pixels[y * stride + row * 4 ..][0..4], pixel, .little);
                }
            }
            try w.present(configured);
            try out.print("framebuffer  {d} bytes, presented\n", .{configured.frameBytes(request.format)});

            try out.writeAll("result       window mapped and a frame committed\n");
        },
        .x11 => {
            var w = try core.x11Window.X11Window.open(request);
            defer w.close();

            const configured = w.currentSize();
            try out.print("requested    {d}x{d}\n", .{ request.size.width, request.size.height });
            try out.print("configured   {d}x{d}\n", .{ configured.width, configured.height });
            if (configured.isEmpty()) {
                try out.writeAll("result       no geometry returned — the window was not created\n");
                try out.flush();
                return 2;
            }
            try out.writeAll("result       window created and mapped\n");
        },
    }

    try out.flush();
    return 0;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
