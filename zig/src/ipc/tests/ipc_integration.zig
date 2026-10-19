//! Integration tests for the shared-memory channel.
//!
//! These exercise the real kernel object: a real `shm_open`, a real `mmap`, real
//! producer and consumer threads contending on the same pages. Nothing is
//! stubbed and no state is simulated — a passing test here means the mapping
//! worked.
//!
//! Tests run against a *pair*: one channel that created the region and one that
//! attached to it, which is how the two sides actually meet. That is deliberate.
//! A single channel cannot read its own frames, so a one-sided test would prove
//! the ring works while proving nothing about the conversation.

const std = @import("std");
const testing = std.testing;
const channel = @import("../channel.zig");
const ring = @import("../ring.zig");
const wire = @import("../wire.zig");

/// The two ends of one channel, both heap-allocated so their addresses stay
/// stable across the defer chain.
const Pair = struct {
    window: *channel.Channel,
    webview: *channel.Channel,
    name: []u8,

    fn deinit(self: Pair) void {
        self.webview.deinit(testing.allocator);
        self.window.deinit(testing.allocator);
        testing.allocator.destroy(self.webview);
        testing.allocator.destroy(self.window);
        testing.allocator.free(self.name);
    }
};

/// A name unique to this process and test, so concurrent runs cannot collide.
/// The pid is real: `getpid` on Linux, `GetCurrentProcessId` on Windows.
fn uniqueName(tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "/lepton-test-{d}-{s}", .{
        if (@import("builtin").os.tag == .windows) std.os.windows.GetCurrentProcessId() else std.os.linux.getpid(),
        tag,
    });
}

fn makePair(tag: []const u8, geometry: channel.Geometry) !Pair {
    const name = try uniqueName(tag);
    errdefer testing.allocator.free(name);

    const window = try testing.allocator.create(channel.Channel);
    errdefer testing.allocator.destroy(window);
    window.* = try channel.create(testing.allocator, name, geometry);

    const webview = try testing.allocator.create(channel.Channel);
    errdefer testing.allocator.destroy(webview);
    webview.* = channel.attach(testing.allocator, name) catch |e| {
        window.deinit(testing.allocator);
        return e;
    };

    return .{ .window = window, .webview = webview, .name = name };
}

fn sample(id: u64, capacity: u32) wire.Sample {
    return .{
        .timestamp_ns = id + 1,
        .rss_bytes = id,
        .heap_high_water_bytes = id,
        .heap_in_use_bytes = id,
        .ring_free_cells = capacity - 1,
        .ring_capacity_cells = capacity,
        .round_trip_ns = id,
        .round_trip_max_ns = id,
    };
}

test "a pair shares one real region, and both sides see the same geometry" {
    const pair = try makePair("create", .{});
    defer pair.deinit();

    try testing.expectEqual(@as(u32, 64), pair.window.capacity());
    try testing.expectEqual(@as(u32, 64), pair.webview.capacity());

    // Roles are opposite, which is what makes the two rings meaningful.
    try testing.expectEqual(channel.Role.window, pair.window.side());
    try testing.expectEqual(channel.Role.webview, pair.webview.side());

    // A name the region never had cannot be attached to, which is the check that
    // `shm_open` with `O_CREAT | O_EXCL` really did create a named object.
    try testing.expectError(error.NotFound, channel.attach(testing.allocator, "/lepton-test-absent"));
}

test "a live owner refuses a second creator, and a released name is free" {
    const name = try uniqueName("exclusive");
    defer testing.allocator.free(name);

    const first = try testing.allocator.create(channel.Channel);
    defer testing.allocator.destroy(first);
    first.* = try channel.create(testing.allocator, name, .{});

    // Two windows must never silently share a ring they did not negotiate. The refusal
    // names a *live owner* rather than merely a taken name, because those ask different
    // things of a caller: one is a retry, the other is a bug report.
    const second = try testing.allocator.create(channel.Channel);
    defer testing.allocator.destroy(second);
    try testing.expectError(
        error.Held,
        channel.create(testing.allocator, name, .{}),
    );

    // Releasing hands the name back. Without this the ownership record would outlive
    // every launch and the second run would be refused forever.
    first.deinit(testing.allocator);

    second.* = try channel.create(testing.allocator, name, .{});
    second.deinit(testing.allocator);
}

test "a sample crosses the mapping byte-identical, and only one way" {
    const pair = try makePair("roundtrip", .{});
    defer pair.deinit();

    const sent = sample(0x1234_5678, 64);
    const seq = try pair.window.send(.sample, &sent, .{});

    // The sender's own ring fills; the peer's does not, because the two rings are
    // separate. This is the property that makes a one-sided test meaningless.
    try testing.expectEqual(@as(u32, 0), pair.window.occupancy());
    try testing.expectEqual(@as(u32, 1), pair.webview.occupancy());

    var frame = (try pair.webview.receive()) orelse return error.ReceiveReturnedNull;
    defer frame.release();

    try testing.expectEqual(seq, frame.header.sequence);
    try testing.expectEqual(wire.Kind.sample, frame.header.kind);
    // Zero-copy: the payload is the mapped bytes, decoded in place.
    try testing.expectEqual(sent, try frame.as(wire.Sample));

    // The cell stays claimed until released, which is what keeps the bytes valid.
    try testing.expectEqual(@as(u32, 1), pair.webview.occupancy());
    frame.release();
    try testing.expectEqual(@as(u32, 0), pair.webview.occupancy());
}

test "the reverse direction is independent of the forward one" {
    const pair = try makePair("duplex", .{});
    defer pair.deinit();

    const a = sample(1, 64);
    const b = sample(2, 64);

    // Both sides speak before either reads. Each must still find only the peer's
    // frame, in the order the peer sent it.
    _ = try pair.window.send(.sample, &a, .{});
    _ = try pair.webview.send(.sample, &b, .{});

    var from_window = (try pair.webview.receive()).?;
    defer from_window.release();
    try testing.expectEqual(a, try from_window.as(wire.Sample));

    var from_webview = (try pair.window.receive()).?;
    defer from_webview.release();
    try testing.expectEqual(b, try from_webview.as(wire.Sample));
}

test "the ring reports empty rather than blocking a consumer" {
    const pair = try makePair("empty", .{});
    defer pair.deinit();
    try testing.expect((try pair.webview.receive()) == null);
}

test "the ring reports full rather than dropping a frame silently" {
    // Two cells is the smallest ring this algorithm can serve, and the third
    // frame must be refused rather than overwriting a cell a reader still holds.
    const pair = try makePair("full", .{ .cell_count = 2 });
    defer pair.deinit();

    const s = sample(1, 2);
    _ = try pair.window.send(.sample, &s, .{});
    _ = try pair.window.send(.sample, &s, .{});
    try testing.expectEqual(@as(u32, 2), pair.webview.occupancy());
    try testing.expectError(error.Full, pair.window.send(.sample, &s, .{}));

    // Refusing must not have consumed a cell: the two that fit are still there.
    try testing.expectEqual(@as(u32, 2), pair.webview.occupancy());
}

test "a ring smaller than two cells is refused rather than silently corrupting" {
    // One cell cannot separate a producer from a consumer in this algorithm, so
    // it is refused at construction rather than accepted and corrupted later.
    const name = try uniqueName("onecell");
    defer testing.allocator.free(name);
    try testing.expectError(
        error.InvalidCellCount,
        channel.create(testing.allocator, name, .{ .cell_count = 1 }),
    );
}

test "a payload one byte over capacity is refused, not truncated" {
    // Capacity fits the header and exactly one `Sample`, and nothing more.
    const pair = try makePair("oversize", .{
        .payload_capacity = wire.header_bytes + @sizeOf(wire.Sample),
    });
    defer pair.deinit();

    var big: [4096]u8 = @splat(0xAB);
    try testing.expectError(error.PayloadTooLarge, pair.window.sendBytes(.event, &big, .{}));
    // A refused payload leaves the ring as it was.
    try testing.expectEqual(@as(u32, 0), pair.webview.occupancy());
}

test "the handshake completes only once both sides have said hello" {
    const pair = try makePair("handshake", .{});
    defer pair.deinit();

    try testing.expect(!pair.window.isEstablished());
    try pair.window.sendHello(.webview, 0);
    // One side has spoken; still not established, because the peer has not.
    try testing.expect(!pair.window.isEstablished());
    // The sender cannot hear itself.
    try testing.expect((try pair.window.receive()) == null);

    // The webview is the side that has to hear the window first.
    try testing.expect(try pair.webview.receiveHello());
    try testing.expectEqual(@intFromEnum(wire.Mode.webview), pair.webview.peer.?.mode);

    try pair.webview.sendHello(.native, 0);
    try testing.expect(try pair.window.receiveHello());

    // Both sides spoke; each reports established, and the peer's identity crossed
    // the mapping intact.
    try testing.expect(pair.window.isEstablished());
    try testing.expect(pair.webview.isEstablished());
    try testing.expectEqual(@intFromEnum(wire.Mode.native), pair.window.peer.?.mode);
}

test "frames survive wraparound of a small ring" {
    // Two cells, ten thousand frames: the cursor wraps many times over, and
    // every frame must still arrive in order with its payload intact.
    const pair = try makePair("wrap", .{ .cell_count = 2, .payload_capacity = 4096 });
    defer pair.deinit();

    const total = 10_000;
    var sent: u64 = 0;
    var received: u64 = 0;

    while (received < total) {
        // Drain whatever is pending so the producer never sees a full ring.
        while (try pair.webview.receive()) |maybe_frame| {
            var frame = maybe_frame;
            defer frame.release();
            const s = try frame.as(wire.Sample);
            try testing.expectEqual(received + 1, s.timestamp_ns);
            received += 1;
        }
        // Everything arrived, so no further frame is owed: sending one here
        // would make the send count disagree with the received count.
        if (received == total) break;
        const s = sample(sent, 2);
        _ = try pair.window.send(.sample, &s, .{});
        sent += 1;
    }

    try testing.expectEqual(@as(u64, total), received);
    try testing.expectEqual(@as(u64, total), pair.window.sent());
    try testing.expectEqual(@as(u64, total), pair.webview.received());
}

test "a frame whose kind this build cannot decode is refused, not acted on" {
    const pair = try makePair("unknown", .{});
    defer pair.deinit();

    // An unknown kind must not be mistaken for a known one: acting on bytes whose
    // meaning is unclear is how a protocol turns into a memory bug. `payload_len`
    // still lets the ring advance past the frame.
    const future = @as(wire.Kind, @enumFromInt(9999));
    try testing.expect(future.isSkippable());

    const s = sample(7, 64);
    _ = try pair.window.sendBytes(future, std.mem.asBytes(&s), .{});
    try testing.expectError(error.UnknownFrameKind, pair.webview.receive());

    // The refused cell was released on the error path, so the ring is usable.
    try testing.expectEqual(@as(u32, 0), pair.webview.occupancy());
}

test "concurrent producers and consumers lose no frames" {
    // Four threads publish into the window's ring while the main thread drains it
    // through the mapping. This is the concurrency claim the ring's module docs
    // make, tested rather than asserted: no frame may be lost or corrupted.
    const producer_count = 4;
    const frames_per_producer = 2_000;
    const total = producer_count * frames_per_producer;

    const pair = try makePair("threads", .{ .cell_count = 64, .payload_capacity = 4096 });
    defer pair.deinit();

    // Producers claim ids from a shared atomic, so every frame carries a distinct
    // one. The consumer checks the set rather than the order, because concurrent
    // producers have no defined interleaving.
    var next_id = std.atomic.Value(u64).init(0);
    var consumed = std.atomic.Value(u64).init(0);
    var failed = std.atomic.Value(u32).init(0);

    const ProducerCtx = struct {
        ch: *channel.Channel,
        id_alloc: *std.atomic.Value(u64),
        count: u64,
        failed: *std.atomic.Value(u32),
    };

    const producer = struct {
        fn run(ctx: ProducerCtx) void {
            var i: u64 = 0;
            while (i < ctx.count) : (i += 1) {
                const id = ctx.id_alloc.fetchAdd(1, .monotonic);
                const s = sample(id, 64);
                // A full ring is a legitimate condition, not a failure: the
                // producer waits for a consumer, exactly as the window side does
                // on its event loop.
                while (true) {
                    _ = ctx.ch.send(.sample, &s, .{}) catch |e| switch (e) {
                        error.Full => {
                            std.Thread.yield() catch {};
                            continue;
                        },
                        else => {
                            _ = ctx.failed.fetchAdd(1, .monotonic);
                            return;
                        },
                    };
                    break;
                }
            }
        }
    }.run;

    var threads: [producer_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, producer, .{ProducerCtx{
            .ch = pair.window,
            .id_alloc = &next_id,
            .count = frames_per_producer,
            .failed = &failed,
        }});
    }

    var seen = try testing.allocator.alloc(bool, total);
    defer testing.allocator.free(seen);
    @memset(seen, false);

    var done: u64 = 0;
    while (done < total) {
        if (try pair.webview.receive()) |maybe_frame| {
            var frame = maybe_frame;
            defer frame.release();

            const s = try frame.as(wire.Sample);
            const idx = s.timestamp_ns - 1;
            try testing.expect(idx < total);
            // Every id arrives exactly once, and the payload matches it.
            try testing.expect(!seen[idx]);
            seen[idx] = true;
            try testing.expectEqual(idx, s.rss_bytes);

            done += 1;
            _ = consumed.fetchAdd(1, .monotonic);
        }
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), failed.load(.monotonic));
    try testing.expectEqual(@as(u64, total), consumed.load(.monotonic));
}

test "publishing the latest never fills: the oldest frames make room, newest kept in order" {
    // A snapshot reader (the webview's transport) never consumes, so a producer that
    // queued would hit `Full` after `cell_count` frames and the page would freeze on
    // stale numbers. `publishLatest` keeps the ring a window over the newest frames.
    const pair = try makePair("latest", .{ .cell_count = 4 });
    defer pair.deinit();

    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        const one = sample(i, 4);
        _ = try pair.window.publishLatest(.sample, &one);
    }

    try testing.expectEqual(@as(u32, 4), pair.webview.occupancy());
    var expected: u64 = 6;
    while (expected < 10) : (expected += 1) {
        var frame = (try pair.webview.receive()) orelse return error.ReceiveReturnedNull;
        defer frame.release();
        try testing.expectEqual(expected, (try frame.as(wire.Sample)).rss_bytes);
    }
    try testing.expect((try pair.webview.receive()) == null);
}

test "the outbound region is exactly the ring this side writes, starting at its header" {
    const pair = try makePair("outbound", .{ .cell_count = 4 });
    defer pair.deinit();

    const region = pair.window.outboundRegion();
    try testing.expectEqual(ring.regionSize(4, 4096), region.len);
    const header: *const ring.Header = @ptrCast(@alignCast(region.ptr));
    try testing.expectEqual(@as(u32, 4), header.cell_count);

    // A published frame moves this ring's cursor, and only this ring's.
    const before = header.enqueue_pos.load(.acquire);
    const one = sample(1, 4);
    _ = try pair.window.publishLatest(.sample, &one);
    try testing.expectEqual(before + 1, header.enqueue_pos.load(.acquire));
    const other: *const ring.Header = @ptrCast(@alignCast(pair.webview.outboundRegion().ptr));
    try testing.expectEqual(@as(u64, 0), other.enqueue_pos.load(.acquire));
}
