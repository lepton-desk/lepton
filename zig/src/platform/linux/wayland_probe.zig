//! Display information from the Wayland compositor, through `libwayland-client`.
//!
//! The compositor answers a `wl_registry` round trip with its globals. Binding
//! `wl_output` and listening for its `mode` event yields the geometry a window
//! opens on. All of it is the client library's own C API: no wrapper, no
//! abstraction layer to unpick later when the window layer needs something the
//! abstraction happened to omit.

const std = @import("std");

const wl = @import("c_wayland_probe");

pub const Error = error{
    ConnectionFailed,
    HandshakeFailed,
    NoOutputs,
    ConnectionLost,
};

/// One output's current mode.
pub const Output = struct {
    width: u32,
    height: u32,
    /// Refresh in millihertz, so 60Hz is 60000. Zero when the compositor does
    /// not report it.
    refresh_mhz: u32,
};

/// State the registry and output listeners accumulate.
const Probe = struct {
    /// The connection the output was bound on. `wl_output` carries no back
    /// pointer to its display in the client library, so a listener that needs to
    /// round-trip has to be handed it rather than look it up.
    display: ?*wl.wl_display = null,
    /// Outputs seen during the registry round trip.
    output_count: u32 = 0,
    /// The first output whose current mode arrives. A multi-output compositor is
    /// resolved later by the window layer, which chooses an output; the probe
    /// only has to prove one exists and report what it measures.
    chosen: ?Output = null,
};

/// Connects to `socket` and reads the first output's current mode.
///
/// Errors rather than a fallback size: a window opened at an invented geometry is
/// a bug the developer has to chase, while an error here is a fact they can act
/// on.
pub fn probe(socket: [*c]const u8) Error!Output {
    const display = wl.wl_display_connect(socket) orelse return error.ConnectionFailed;
    defer wl.wl_display_disconnect(display);

    if (wl.wl_display_roundtrip(display) < 0) return error.HandshakeFailed;

    const registry = wl.wl_display_get_registry(display) orelse return error.HandshakeFailed;

    // The listeners below read `state` by pointer, so it must outlive every
    // round trip this function performs. It does: it is a local.
    var state: Probe = .{ .display = display };
    var registry_listener = wl.wl_registry_listener{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };
    _ = wl.wl_registry_add_listener(registry, &registry_listener, @ptrCast(&state));

    if (wl.wl_display_roundtrip(display) < 0) return error.HandshakeFailed;
    if (wl.wl_display_get_error(display) != 0) return error.ConnectionLost;
    if (state.output_count == 0) return error.NoOutputs;

    return state.chosen orelse Output{ .width = 0, .height = 0, .refresh_mhz = 0 };
}

/// Called once per global the compositor offers: `(data, registry, id, interface, version)`.
fn onGlobal(
    data: ?*anyopaque,
    registry: ?*wl.wl_registry,
    id: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    const state: *Probe = @ptrCast(@alignCast(data.?));
    if (!std.mem.eql(u8, std.mem.span(interface), "wl_output")) return;
    state.output_count += 1;

    // One output is enough to learn the mode. Binding more would create
    // compositor state the probe has no use for.
    if (state.chosen != null) return;

    const reg = registry.?;
    // Asking for a version the compositor does not offer is a protocol error, so
    // the request is clamped to what was announced.
    // `wl_registry_bind` is declared to return `void *`, so the concrete proxy type
    // has to be restored here rather than being inferred.
    const bound = wl.wl_registry_bind(reg, id, &wl.wl_output_interface, @min(version, 4)) orelse return;
    const output: *wl.wl_output = @ptrCast(@alignCast(bound));
    defer wl.wl_output_destroy(output);

    var output_listener = wl.wl_output_listener{
        .geometry = onOutputGeometry,
        .mode = onOutputMode,
        .done = onOutputDone,
        .scale = onOutputScale,
        .name = onOutputName,
        .description = onOutputDescription,
    };
    _ = wl.wl_output_add_listener(output, &output_listener, @ptrCast(state));

    // Modes arrive as events, and a round trip on the same connection is what
    // delivers them.
    const conn = state.display orelse return;
    if (wl.wl_display_roundtrip(conn) < 0) return;
}

fn onGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

/// `wl_output.mode` — a mode the output reports, flagged as current or not.
fn onOutputMode(
    data: ?*anyopaque,
    _: ?*wl.wl_output,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    const state: *Probe = @ptrCast(@alignCast(data.?));
    if (state.chosen != null) return;

    // Only the current mode is what a window opens on; a preferred or fallback
    // mode describes what the output could do, not what it is doing.
    const current: u32 = 0x1;
    if (flags & current == 0) return;
    if (width <= 0 or height <= 0) return;

    state.chosen = Output{
        .width = @intCast(width),
        .height = @intCast(height),
        // The protocol already reports refresh in millihertz.
        .refresh_mhz = if (refresh > 0) @intCast(refresh) else 0,
    };
}

fn onOutputDone(_: ?*anyopaque, _: ?*wl.wl_output) callconv(.c) void {}

fn onOutputScale(_: ?*anyopaque, _: ?*wl.wl_output, _: i32) callconv(.c) void {}

fn onOutputName(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}

fn onOutputDescription(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}

/// Physical geometry does not affect window size; the current mode does.
fn onOutputGeometry(
    _: ?*anyopaque,
    _: ?*wl.wl_output,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: i32,
    _: [*c]const u8,
    _: [*c]const u8,
    _: i32,
) callconv(.c) void {}

test {
    _ = wl;
    _ = onGlobal;
    _ = onOutputMode;
}
