//! Tests for the machine probe.
//!
//! These read this process's real `/proc/self/statm` and the real monotonic
//! clock. Nothing is simulated: the resident set a test asserts on is the one the
//! kernel reports for the test binary while it is running.

const std = @import("std");
const testing = std.testing;
const probe = @import("probe.zig");

test "resident set is read from the kernel and is a plausible size" {
    const rss = try probe.residentSetBytes();

    // A live process has a resident set; zero would mean the read silently
    // produced nothing, which is the failure this guards.
    try testing.expect(rss > 0);

    // The kernel's accounting cannot exceed the machine's memory, so that is an
    // honest upper bound. A read that returned more would be a parse bug.
    const total = totalPhysicalBytes() orelse return;
    try testing.expect(rss <= total);
}

test "the reading carries the real resident set and the ring geometry it was given" {
    var p = probe.Probe.init();
    const reading = try p.read(60, 64);

    try testing.expectEqual(@as(u32, 60), reading.ring_free_cells);
    try testing.expectEqual(@as(u32, 64), reading.ring_capacity_cells);
    // The test binary is resident, so this must be non-zero.
    try testing.expect(reading.rss_bytes > 0);
}

test "round trips are remembered, and the worst one is kept" {
    var p = probe.Probe.init();

    p.recordRoundTrip(1_000);
    p.recordRoundTrip(9_000);
    p.recordRoundTrip(4_000);

    const reading = try p.read(0, 0);
    // The most recent figure is what the panel shows; the worst never decreases.
    try testing.expectEqual(@as(u64, 4_000), reading.round_trip_ns);
    try testing.expectEqual(@as(u64, 9_000), reading.round_trip_max_ns);
}

test "uptime advances between readings and never goes backwards" {
    var p = probe.Probe.init();
    const first = try p.read(0, 0);

    // Enough real work that the monotonic clock must have moved.
    var sink: u64 = 0;
    for (0..200_000) |i| sink +%= i;
    try testing.expect(sink > 0);

    const second = try p.read(0, 0);
    try testing.expect(second.uptime_ns >= first.uptime_ns);
}

/// Total physical memory, from `sysconf(_SC_PHYS_PAGES)`. Returns null when the
/// platform does not report it, so the caller skips the comparison rather than
/// asserting against a fabricated bound.
fn totalPhysicalBytes() ?u64 {
    const c = std.c;
    if (@hasDecl(c, "sysconf")) {
        const pages = c.sysconf(@as(c_int, 85)); // _SC_PHYS_PAGES on Linux/glibc
        if (pages > 0) return @as(u64, @intCast(pages)) * probe.page_bytes;
    }
    return null;
}

test "the C heap counters move with a real allocation" {
    const before = probe.heapBytes();
    // Above glibc's mmap threshold, so it is served by `mmap` and shows in `hblkhd`.
    const size = 4 * 1024 * 1024;
    const block: [*]u8 = @ptrCast(std.c.malloc(size) orelse return error.OutOfMemory);
    @memset(block[0..size], 0xA5);
    const during = probe.heapBytes();
    std.c.free(block);

    try std.testing.expect(during.in_use >= before.in_use + size);
    try std.testing.expect(during.reserved >= during.in_use - before.in_use);
    try std.testing.expect(probe.heapBytes().in_use < during.in_use);
}
