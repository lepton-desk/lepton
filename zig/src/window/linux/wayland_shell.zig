//! The xdg-shell side of the Wayland window: registry binding and the surface and
//! toplevel listeners that carry configure, bounds and close.
//!
//! Split out of `wayland_window.zig` by responsibility. The listener tables are
//! file-level for the reason given below; `WaylandWindow.open` installs them.

const std = @import("std");

const wl = @import("wayland_c.zig").wl;
const placement = @import("placement.zig");
const window = @import("../window.zig");
const WaylandWindow = @import("wayland_window.zig").WaylandWindow;

const Size = window.Size;
const Configure = window.Configure;

/// Globals the compositor must offer. Recorded during the registry round trip so
/// binding happens once, in a fixed order, rather than as each global is seen.
pub const Globals = struct {
    compositor: ?*wl.wl_compositor = null,
    shm: ?*wl.wl_shm = null,
    wm_base: ?*wl.xdg_wm_base = null,

    /// The seat that carries input for this session.
    ///
    /// Bound at version 5 and no higher because that is the first version with
    /// `wl_keyboard.keymap`, and there is nothing below it that can produce a key at all.
    /// A version above 5 is not a protocol error — the compositor keeps announcing what it
    /// has — but binding it would promise a request this build cannot make.
    seat: ?*wl.wl_seat = null,
};

/// Accumulated during the registry round trip.
pub const RegistryState = struct {
    globals: Globals = .{},
    /// Highest xdg-shell version the compositor announced, clamped to what this
    /// build knows how to speak.
    wm_base_version: u32 = 0,
};

/// The registry listener. File-level for the same reason as the xdg tables below, even
/// though `open` destroys the registry before returning.
pub const registry_listener = wl.wl_registry_listener{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

/// The contents of a `wl_array` as a byte slice.
///
/// `wl_array` is declared opaque, but its layout is part of the protocol's ABI —
/// a byte count followed by a pointer — and a client cannot read one otherwise.
/// Mirrored here rather than assumed, with the length taken from the array itself
/// so a value beyond the payload is never dereferenced.
pub fn wireArray(array: [*c]wl.wl_array) ?[]const u8 {
    // The C type, not a mirror of it. `struct wl_array` is `size`, `alloc`, `data`; the
    // hand-written mirror this replaced left out `alloc`, so it read the allocation size
    // as the data pointer. The configure states were never parsed: a maximised window
    // never knew it was maximised, and maximise / double-click could not restore it
    // (measured on COSMIC with the window's own buttons).
    if (array == null) return null;
    const bytes: [*]const u8 = @ptrCast(array.*.data orelse return null);
    return bytes[0..array.*.size];
}

// Listener tables live here rather than in the call that installs them.
//
// libwayland stores the pointer it is given and calls through it whenever an event for
// that proxy arrives — which, once the event loop actually runs, is long after `open`
// has returned. A table declared as a local in `open` is a pointer into a stack frame
// that no longer exists, so the first dispatched event calls into freed memory. This was
// invisible while the only dispatch was the round trip inside `open`, where the frame was
// still alive; the symptom once draining was added was "listener function for opcode 0
// of xdg_surface is NULL", which is the library reading a table whose memory had been
// reused for something else.
pub var xdg_surface_listener_table = wl.xdg_surface_listener{ .configure = onXdgConfigure };
pub var xdg_toplevel_listener_table = wl.xdg_toplevel_listener{
    .configure = onToplevelConfigure,
    .close = onToplevelClose,
    .configure_bounds = onToplevelConfigureBounds,
    .wm_capabilities = onToplevelCapabilities,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: ?*wl.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const state: *RegistryState = @ptrCast(@alignCast(data.?));
    const reg = registry.?;
    const which = std.mem.span(interface);

    // Each global is bound at the version the compositor announced, clamped to what
    // this build knows: requesting more is a protocol error. `wl_registry_bind` is
    // declared to return `void *`, so the concrete proxy type is restored here.
    const version_clamped = @min(version, 4);
    if (std.mem.eql(u8, which, "wl_compositor")) {
        const bound = wl.wl_registry_bind(reg, name, &wl.wl_compositor_interface, version_clamped) orelse return;
        state.globals.compositor = @ptrCast(@alignCast(bound));
    } else if (std.mem.eql(u8, which, "wl_shm")) {
        const bound = wl.wl_registry_bind(reg, name, &wl.wl_shm_interface, 1) orelse return;
        state.globals.shm = @ptrCast(@alignCast(bound));
    } else if (std.mem.eql(u8, which, "wl_seat")) {
        const bound = wl.wl_registry_bind(reg, name, &wl.wl_seat_interface, @min(version, 5)) orelse return;
        state.globals.seat = @ptrCast(@alignCast(bound));
    } else if (std.mem.eql(u8, which, "xdg_wm_base")) {
        state.wm_base_version = version_clamped;
        const bound = wl.wl_registry_bind(reg, name, &wl.xdg_wm_base_interface, version_clamped) orelse return;
        state.globals.wm_base = @ptrCast(@alignCast(bound));
    }
}

fn onGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

/// `xdg_surface.configure` — the compositor stating the size it wants.
fn onXdgConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*wl.xdg_surface,
    serial: u32,
) callconv(.c) void {
    // The acknowledgement is mandatory and must carry the serial: a configure left
    // unacknowledged means the compositor stops sending them. The size itself
    // arrives on the toplevel, so this listener needs no state of its own.
    wl.xdg_surface_ack_configure(xdg_surface.?, serial);
    _ = data;
}

fn onToplevelConfigure(
    data: ?*anyopaque,
    _: ?*wl.xdg_toplevel,
    width: i32,
    height: i32,
    states: [*c]wl.wl_array,
) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));

    var activated = false;
    var maximized = false;
    const array = wireArray(states);
    if (array) |bytes| {
        var offset: usize = 0;
        // Each state is one 32-bit word on the wire, so the walk is by element and
        // by the array's own byte length rather than by a sentinel. Both states are read
        // on every pass rather than looking only for one: the array carries the complete
        // current state, so a window that was maximised and has just been restored has no
        // mention of it, and a check that only ever looked for `maximized` would keep
        // believing it was still full-screen.
        while (offset + 4 <= bytes.len) : (offset += 4) {
            const word = std.mem.readInt(u32, bytes[offset..][0..4], .native);
            if (word == wl.XDG_TOPLEVEL_STATE_ACTIVATED) activated = true;
            if (word == wl.XDG_TOPLEVEL_STATE_MAXIMIZED) maximized = true;
        }
    }
    self.maximized = maximized;

    // A zero on either axis is the compositor saying "you choose", not a request
    // for a zero-sized window.
    if (width > 0 and height > 0) {
        self.size = .{ .width = @intCast(width), .height = @intCast(height) };
        // The zones are measured against the window the compositor actually gave, not the
        // one that was asked for: a maximise changes the width, and controls placed from
        // the requested size would sit off the right edge after it.
        self.input.width = self.size.width;
        self.input.height = self.size.height;
        self.pending = .{ .size = self.size, .activated = activated };
    } else {
        // "You choose" — but within the bounds the compositor announced just before.
        // Keeping a size larger than the work area puts the titlebar's controls off
        // screen, where the window can be neither closed nor dragged back.
        const fitted = placement.fit(self.size, self.bounds);
        if (!std.meta.eql(fitted, self.size)) {
            self.size = fitted;
            self.input.width = fitted.width;
            self.input.height = fitted.height;
            if (self.xdg_surface) |xdg| {
                wl.xdg_surface_set_window_geometry(xdg, 0, 0, @intCast(fitted.width), @intCast(fitted.height));
            }
            self.pending = .{ .size = fitted, .activated = activated };
        }
    }
}

fn onToplevelClose(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    // Reported as a configure with an empty size, which is how the layer above
    // learns the window is gone without needing a second event type.
    self.pending = Configure{ .size = Size{ .width = 0, .height = 0 }, .activated = false };
}

fn onToplevelConfigureBounds(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32) callconv(.c) void {
    // Sent before the configure it applies to; stored so that configure can fit to it.
    const self: *WaylandWindow = @ptrCast(@alignCast(data.?));
    self.bounds = placement.Bounds.fromWire(width, height);
}

fn onToplevelCapabilities(_: ?*anyopaque, _: ?*wl.xdg_toplevel, _: ?*wl.wl_array) callconv(.c) void {
    // Window menu geometry is a hint too, and Lepton has no window menu.
}

test "configure states are read from a real wl_array" {
    // Built with libwayland's own array functions, so the layout is the library's.
    var array: wl.wl_array = undefined;
    wl.wl_array_init(&array);
    defer wl.wl_array_release(&array);
    const maximized: u32 = @intCast(wl.XDG_TOPLEVEL_STATE_MAXIMIZED);
    const activated: u32 = @intCast(wl.XDG_TOPLEVEL_STATE_ACTIVATED);
    const states = [_]u32{ maximized, activated };
    for (states) |state| {
        const slot: *u32 = @ptrCast(@alignCast(wl.wl_array_add(&array, @sizeOf(u32)) orelse return error.OutOfMemory));
        slot.* = state;
    }

    const bytes = wireArray(&array) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqual(maximized, std.mem.readInt(u32, bytes[0..4], .native));
    try std.testing.expectEqual(activated, std.mem.readInt(u32, bytes[4..8], .native));
}

test "an empty or missing array has no states" {
    var array: wl.wl_array = undefined;
    wl.wl_array_init(&array);
    try std.testing.expect(wireArray(&array) == null);
    try std.testing.expect(wireArray(null) == null);
}
