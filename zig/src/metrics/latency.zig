//! Round-trip latency measurement over the shared ring.
//!
//! The operator panel promises a `p50` and a `p99` for IPC round trip. Those two
//! numbers are the framework's central claim, so they are measured here rather
//! than estimated, and the measurement is built the way a real one has to be:
//! over the actual mapping, with the actual frame grammar, including the cost of
//! the consumer's release.
//!
//! Percentiles come from a fixed histogram rather than a sorted sample list. A
//! bounded histogram keeps the cost of recording a sample constant, which is what
//! makes it safe to call `record` on a path that is already doing work — sorting
//! every sample would make the instrument heavier than the thing it measures.
//! Latencies are bucketed logarithmically, which is the right shape for a
//! quantity whose interesting range spans three orders of magnitude: a few
//! microseconds to a few milliseconds.
//!
//! The histogram's upper bound is a hard `OutOfMemory`-free clamp rather than an
//! error: a sample slower than the last bucket is recorded as being in the last
//! bucket, and the tracker also counts how many that was, so a saturated
//! histogram is visible instead of silently flattening the tail.

const std = @import("std");

/// Buckets per power of two, giving 1/16th-octave resolution.
pub const buckets_per_octave: u32 = 16;

/// Nanoseconds at the top of the histogram's range. Anything slower lands in the
/// final bucket and is counted as an overflow.
pub const max_latency_ns: u64 = 1 << 30; // ~1.07s

/// Octaves spanned, from one nanosecond up to `max_latency_ns`.
///
/// Computed on `usize` explicitly: `log2_int` returns a `u6`, so mixing it with
/// `@bitSizeOf` would force the subtraction into a six-bit type that cannot hold
/// 64.
const octave_span: usize = @bitSizeOf(u64) - @as(usize, std.math.log2_int(u64, max_latency_ns));

pub const bucket_count: usize = @as(usize, octave_span) * buckets_per_octave;

/// What one recorded sample costs: one atomic add. That is the whole reason the
/// histogram is used instead of a sorted list.
pub const Sample = struct {
    latency_ns: u64,
};

/// Records round-trip latencies and reports percentiles from them.
///
/// Not thread-safe by itself: each endpoint measures its own view of the round
/// trip, so there is one tracker per thread rather than one shared.
pub const Tracker = struct {
    buckets: [bucket_count]u32 = @splat(0),
    samples: u64 = 0,
    /// Samples slower than `max_latency_ns`, which the histogram cannot place.
    overflow: u64 = 0,
    /// Running extremes, kept alongside the histogram because a percentile of a
    /// saturated histogram is only meaningful next to the true maximum.
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    sum_ns: u64 = 0,

    pub const empty: Tracker = .{};

    /// Records one round trip. Constant time, no allocation.
    pub fn record(self: *Tracker, latency_ns: u64) void {
        self.samples += 1;
        self.sum_ns +%= latency_ns;
        if (latency_ns < self.min_ns) self.min_ns = latency_ns;
        if (latency_ns > self.max_ns) self.max_ns = latency_ns;
        if (latency_ns >= max_latency_ns) {
            self.overflow += 1;
            self.buckets[bucket_count - 1] += 1;
            return;
        }
        self.buckets[indexFor(latency_ns)] += 1;
    }

    /// Samples recorded so far.
    pub fn count(self: *const Tracker) u64 {
        return self.samples;
    }

    /// The percentile latency in nanoseconds, or zero when nothing was recorded.
    ///
    /// `q` is a fraction: `0.50` for the median, `0.99` for the tail. The result
    /// is the bucket's *upper* bound, so it never understates the true value —
    /// a latency panel that rounds down would be the one place the framework lies.
    pub fn percentile(self: *const Tracker, q: f64) u64 {
        if (self.samples == 0) return 0;

        const target = @as(u64, @intFromFloat(@ceil(q * @as(f64, @floatFromInt(self.samples)))));
        const want = if (target == 0) 1 else @min(target, self.samples);

        var seen: u64 = 0;
        for (self.buckets, 0..) |n, i| {
            if (n == 0) continue;
            seen += n;
            if (seen >= want) return bucketCeiling(i);
        }
        return self.max_ns;
    }

    /// Mean round trip. Reported beside the percentiles because a mean alone
    /// hides exactly the tail the panel exists to show.
    pub fn mean(self: *const Tracker) u64 {
        if (self.samples == 0) return 0;
        return self.sum_ns / self.samples;
    }

    /// The fastest and slowest round trips seen.
    pub fn extremes(self: *const Tracker) struct { min_ns: u64, max_ns: u64 } {
        return .{ .min_ns = if (self.samples == 0) 0 else self.min_ns, .max_ns = self.max_ns };
    }

    /// True when samples exceeded the histogram's range, which means the reported
    /// percentiles do not describe the whole distribution.
    pub fn isSaturated(self: *const Tracker) bool {
        return self.overflow > 0;
    }

    /// A one-line summary for the CLI. Kept here so the format and the numbers
    /// it reports cannot drift apart.
    pub fn summary(self: *const Tracker, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.samples == 0) {
            try writer.writeAll("no round trips recorded");
            return;
        }
        const ex = self.extremes();
        try writer.print(
            "n={d} min={d}ns p50={d}ns p99={d}ns max={d}ns mean={d}ns",
            .{ self.samples, ex.min_ns, self.percentile(0.50), self.percentile(0.99), ex.max_ns, self.mean() },
        );
        if (self.isSaturated()) try writer.print(" ({d} beyond histogram range)", .{self.overflow});
    }

    /// Index of the bucket a latency falls in.
    ///
    /// Each octave is split into sixteenths. For an octave of width `2^o`, the
    /// sub-bucket is the top four bits of the value below the leading one, which
    /// is the same as dividing the offset into the octave by `2^(o-4)`. Below the
    /// fourth octave there is no room for four mantissa bits, so the offset is
    /// used directly — that is why zero and one nanosecond share a bucket.
    fn indexFor(latency_ns: u64) usize {
        if (latency_ns <= 1) return 0;
        const octaves: u6 = std.math.log2_int(u64, latency_ns);
        const base = @as(u64, 1) << @intCast(octaves);
        const offset = latency_ns - base;

        const sub: u64 = if (octaves >= 4)
            offset >> @intCast(octaves - 4)
        else
            offset;

        const idx = @as(usize, octaves) * buckets_per_octave + @as(usize, sub);
        return @min(idx, bucket_count - 1);
    }

    /// Exclusive upper bound of a bucket: the smallest latency that would fall in
    /// the next bucket up.
    fn bucketCeiling(index: usize) u64 {
        const octaves: u6 = @intCast(index / buckets_per_octave);
        const sub: u64 = index % buckets_per_octave;
        const base = @as(u64, 1) << @intCast(octaves);

        // Below the fourth octave one sub-bucket is a single nanosecond.
        const width: u64 = if (octaves >= 4) base >> 4 else 1;
        return base + (sub + 1) * width;
    }
};

/// Measures a round trip between two instants on the monotonic clock.
///
/// Takes the clock as a value rather than reading it itself, so the same
/// `Tracker` can measure against whichever clock the caller already holds and a
/// test can measure against a real one without a second implementation.
pub fn measure(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp, tracker: *Tracker) void {
    const d = start.durationTo(end);
    const ns: i128 = d.raw.nanoseconds;
    tracker.record(if (ns < 0) 0 else @intCast(ns));
}

test {
    _ = @import("tracker_test.zig");
}
