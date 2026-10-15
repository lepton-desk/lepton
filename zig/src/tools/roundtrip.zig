//! Measures the real IPC round trip over the shared ring.
//!
//! This exists because the framework's central claim — that the channel is fast
//! enough to be invisible — is a number, and a number has to be measured on the
//! path the product actually uses. The measurement below drives the real
//! `shm_open`, the real mapping, the real frame grammar and the real cell release
//! on both ends. The one thing it does not include is the process hop between the
//! window and the webview, which is stated in the output rather than glossed
//! over.
//!
//! Run with `zig build roundtrip`.

const std = @import("std");
const core = @import("lepton_core");

const round_count = 20_000;
const channel_name = "/lepton-roundtrip-bench";

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io(), &stdout_buffer);
    const out = &stdout.interface;

    var window = try core.channel.create(allocator, channel_name, .{});
    defer window.deinit(allocator);
    var webview = try core.channel.attach(allocator, channel_name);
    defer webview.deinit(allocator);

    var payload: core.wire.Sample = .{
        .timestamp_ns = 0,
        .rss_bytes = 0,
        .heap_high_water_bytes = 0,
        .heap_in_use_bytes = 0,
        .ring_free_cells = 0,
        .ring_capacity_cells = 0,
        .round_trip_ns = 0,
        .round_trip_max_ns = 0,
    };
    var tracker: core.latency.Tracker = .{};

    // Warm the mapping and the ring's cache lines so the first samples measure the
    // channel rather than first-touch page faults.
    for (0..256) |_| _ = try oneRoundTrip(&window, &webview, &payload);
    tracker = .{};

    var i: u64 = 0;
    while (i < round_count) : (i += 1) {
        payload.timestamp_ns = i;
        const start = std.Io.Clock.Timestamp.now(io(), .awake);
        _ = try oneRoundTrip(&window, &webview, &payload);
        core.latency.measure(start, std.Io.Clock.Timestamp.now(io(), .awake), &tracker);
    }

    try out.print("lepton ipc round trip\n", .{});
    try out.print("  samples   {d}\n", .{tracker.count()});
    try out.print("  ring      {d} cells x {d} bytes, one per direction\n", .{
        window.capacity(),
        window.out.payload_capacity,
    });
    try out.print("  path      shared memory, frame composed in place, read in place\n", .{});
    try out.writeAll("  excludes  the process hop between window and webview\n");
    try out.writeAll("  ");
    try tracker.summary(out);
    try out.writeAll("\n");
    try out.flush();
}

/// One frame out and the echo back, timed by the caller.
///
/// The reply echoes the request's sequence, which is what proves the sample that
/// came back is the one that was sent rather than a stale frame.
fn oneRoundTrip(
    window: *core.channel.Channel,
    webview: *core.channel.Channel,
    payload: *core.wire.Sample,
) !core.wire.Sample {
    const request = try window.send(.sample, payload, .{});

    var frame = (try webview.receive()) orelse return error.NoRequestArrived;
    defer frame.release();
    if (frame.header.sequence != request) return error.SequenceMismatch;

    // The peer's echo carries the request's sequence, so the window can tell its
    // own reply apart from anything else that arrived in between.
    const echoed = try frame.as(core.wire.Sample);
    _ = try webview.send(.sample, &echoed, .{ .sequence = request, .reply = true });

    var back = (try window.receive()) orelse return error.NoReplyArrived;
    defer back.release();
    if (!core.wire.flagOf(back.header, .reply)) return error.NotAReply;
    if (back.header.sequence != request) return error.SequenceMismatch;

    return try back.as(core.wire.Sample);
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
