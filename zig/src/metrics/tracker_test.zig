//! Tests for the latency tracker.
//!
//! The bucket arithmetic is checked against exact expectations rather than
//! against itself: a percentile that is merely self-consistent would pass while
//! reporting the wrong number, which is the one failure mode this instrument
//! cannot have.

const std = @import("std");
const testing = std.testing;
const latency = @import("latency.zig");

test "an empty tracker reports zero rather than a fabricated percentile" {
    const t = latency.Tracker.empty;
    try testing.expectEqual(@as(u64, 0), t.count());
    try testing.expectEqual(@as(u64, 0), t.percentile(0.50));
    try testing.expectEqual(@as(u64, 0), t.percentile(0.99));
    try testing.expectEqual(@as(u64, 0), t.mean());
    try testing.expect(!t.isSaturated());
}

test "percentiles of a known distribution land where they should" {
    var t = latency.Tracker.empty;
    // 1..=100 microseconds, one sample each.
    var i: u64 = 1;
    while (i <= 100) : (i += 1) t.record(i * 1_000);

    try testing.expectEqual(@as(u64, 100), t.count());

    const p50 = t.percentile(0.50);
    const p99 = t.percentile(0.99);

    // The median of a uniform 1..100us distribution is 50us. The histogram
    // reports a bucket ceiling, so the answer is at or above the true value —
    // never below, because rounding down is the failure this instrument cannot
    // have. The upper bound is the bucket width: at 50us the containing octave is
    // [32us, 64us) split into sixteenths, which is 2us per bucket.
    try testing.expect(p50 >= 50_000);
    try testing.expect(p50 <= 52_000);

    // At 99us the octave is [64us, 128us), so buckets are 4us wide.
    try testing.expect(p99 >= 99_000);
    try testing.expect(p99 <= 104_000);

    // The tail must never be smaller than the median.
    try testing.expect(p99 >= p50);
}

test "a single sample is reported at or above its own value" {
    var t = latency.Tracker.empty;
    t.record(4_200);
    const p = t.percentile(0.50);
    try testing.expect(p >= 4_200);
    try testing.expect(p < 4_200 * 2);
}

test "min, max and mean describe the samples exactly" {
    var t = latency.Tracker.empty;
    t.record(100);
    t.record(300);
    t.record(200);

    const ex = t.extremes();
    try testing.expectEqual(@as(u64, 100), ex.min_ns);
    try testing.expectEqual(@as(u64, 300), ex.max_ns);
    try testing.expectEqual(@as(u64, 200), t.mean());
}

test "a sample beyond the histogram range is counted, not discarded" {
    var t = latency.Tracker.empty;
    t.record(10_000);
    // Far past the ~1.07s ceiling.
    t.record(latency.max_latency_ns * 4);

    try testing.expectEqual(@as(u64, 2), t.count());
    // The overflow is visible, because a saturated histogram means the reported
    // percentiles no longer describe the whole distribution.
    try testing.expect(t.isSaturated());
    // Extremes still carry the true value, so the panel cannot hide behind the
    // histogram.
    try testing.expectEqual(@as(u64, latency.max_latency_ns * 4), t.extremes().max_ns);
}

test "zero latency is recorded rather than lost to a log scale" {
    var t = latency.Tracker.empty;
    t.record(0);
    try testing.expectEqual(@as(u64, 1), t.count());
    // Zero and one nanosecond share the first bucket. Its ceiling is two
    // nanoseconds, because that is the smallest value the next bucket holds. A
    // zero round trip means the clock did not advance; the tracker reports it
    // rather than discarding it, and its ceiling never understates.
    try testing.expectEqual(@as(u64, 2), t.percentile(0.50));
    try testing.expectEqual(@as(u64, 0), t.extremes().min_ns);
    try testing.expectEqual(@as(u64, 0), t.extremes().max_ns);
    try testing.expectEqual(@as(u64, 0), t.mean());
}

test "the summary names the figures it reports" {
    var t = latency.Tracker.empty;
    t.record(1_000);
    t.record(2_000);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.summary(&w);
    const line = w.buffered();

    // Each reported figure must appear in the text, so the CLI cannot print a
    // label whose value it computed differently.
    for ([_][]const u8{ "n=2", "min=", "p50=", "p99=", "max=" }) |needle| {
        try testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }

    var empty_buf: [64]u8 = undefined;
    var ew = std.Io.Writer.fixed(&empty_buf);
    try latency.Tracker.empty.summary(&ew);
    try testing.expectEqualStrings("no round trips recorded", ew.buffered());
}
