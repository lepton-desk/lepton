//! What the page is sent of the outbound ring: the frames it has not seen, not the ring.
//!
//! The page keeps one copy of the ring (`__lepton.bytes`) and asks
//! `/__lepton/region?after=N` with the enqueue position its copy is at. Re-sending the
//! whole mapping (532 608 bytes in the template) four times a second made WebKit
//! allocate a fresh `ArrayBuffer` per read: a 6–32 MiB `[anon:JSGigacage]` sawtooth and
//! 2.9% of a core on an idle page (PRODUCT.md, 2026-10-17). Now the answer is the ring
//! header followed by each frame published since `N` — cell header plus the bytes the
//! frame used, back to back, oldest first — and the page writes each one into its copy
//! at that position's cell. The whole mapping is still the answer when the page has
//! nothing yet or fell a lap behind; the page tells the two apart by length, since a
//! delta holds fewer than `cell_count` cells and is always shorter than the mapping.
//!
//! Pure: the bridge does the holding and answering; this file is tested alone.

const std = @import("std");
const ring = @import("../../ipc/ring.zig");

const enqueue_offset = @offsetOf(ring.Header, "enqueue_pos");
const count_offset = @offsetOf(ring.Header, "cell_count");
const stride_offset = @offsetOf(ring.Header, "cell_stride");
const capacity_offset = @offsetOf(ring.Header, "payload_capacity");
const seq_offset = @offsetOf(ring.CellHeader, "seq");
const len_offset = @offsetOf(ring.CellHeader, "len");

/// How many frames the core has ever published into the ring at the start of `region`.
pub fn position(region: []const u8) u64 {
    if (region.len < ring.header_bytes) return 0;
    return std.mem.readInt(u64, region[enqueue_offset..][0..8], .little);
}

/// The answer to `after`: the delta's length, or null when the page needs the whole
/// mapping (it has nothing, fell a lap behind, or the ring is not what it should be).
pub fn deltaLen(region: []const u8, after: u64) ?usize {
    const newest = position(region);
    if (after == 0 or after > newest) return null;
    const count: u64 = std.mem.readInt(u32, region[count_offset..][0..4], .little);
    const stride: usize = std.mem.readInt(u32, region[stride_offset..][0..4], .little);
    const capacity: u32 = std.mem.readInt(u32, region[capacity_offset..][0..4], .little);
    if (count < 2 or stride < ring.cell_header_bytes or newest - after >= count) return null;
    if (ring.header_bytes + stride * count > region.len) return null;
    var total: usize = ring.header_bytes;
    var at = after;
    while (at < newest) : (at += 1) {
        const cell = region[ring.header_bytes + @as(usize, @intCast(at % count)) * stride ..];
        // A cell whose sequence is not `at + 1` was not published at `at`: the page
        // would take it for a frame it is not, so it gets the mapping instead.
        if (std.mem.readInt(u64, cell[seq_offset..][0..8], .little) != at + 1) return null;
        const len = std.mem.readInt(u32, cell[len_offset..][0..4], .little);
        if (len > capacity) return null;
        total += ring.cell_header_bytes + len;
    }
    return total;
}

/// Writes the delta for `after` into `out`, which holds exactly `deltaLen(region, after)`.
pub fn writeDelta(region: []const u8, after: u64, out: []u8) void {
    const newest = position(region);
    const count: u64 = std.mem.readInt(u32, region[count_offset..][0..4], .little);
    const stride: usize = std.mem.readInt(u32, region[stride_offset..][0..4], .little);
    @memcpy(out[0..ring.header_bytes], region[0..ring.header_bytes]);
    var used: usize = ring.header_bytes;
    var at = after;
    while (at < newest) : (at += 1) {
        const cell = region[ring.header_bytes + @as(usize, @intCast(at % count)) * stride ..];
        const len = ring.cell_header_bytes + std.mem.readInt(u32, cell[len_offset..][0..4], .little);
        @memcpy(out[used..][0..len], cell[0..len]);
        used += len;
    }
}

/// What the page does with an answer, in Zig, so the format is tested where it is
/// written. The injected script (`transport.zig`) is this function line for line.
fn apply(copy: []u8, after: u64, answer: []const u8) void {
    if (answer.len == copy.len) {
        @memcpy(copy, answer);
        return;
    }
    @memcpy(copy[0..ring.header_bytes], answer[0..ring.header_bytes]);
    const count: u64 = std.mem.readInt(u32, copy[count_offset..][0..4], .little);
    const stride: usize = std.mem.readInt(u32, copy[stride_offset..][0..4], .little);
    var used: usize = ring.header_bytes;
    var at = after;
    while (used < answer.len) : (at += 1) {
        const len = ring.cell_header_bytes + std.mem.readInt(u32, answer[used + len_offset ..][0..4], .little);
        @memcpy(copy[ring.header_bytes + @as(usize, @intCast(at % count)) * stride ..][0..len], answer[used..][0..len]);
        used += len;
    }
}

fn publishByte(r: *ring.Ring, value: u8, len: usize) !void {
    var slot = try r.claim();
    var w = slot.writer();
    var i: usize = 0;
    while (i < len) : (i += 1) try w.writeByte(value);
    r.publish(slot, len);
}

/// A full ring gives up its oldest frame, as `Channel.publishLatest` does.
fn publishLatest(r: *ring.Ring, value: u8, len: usize) !void {
    publishByte(r, value, len) catch |failure| switch (failure) {
        error.Full => {
            var oldest = try r.claimOldest();
            r.release(&oldest);
            try publishByte(r, value, len);
        },
        else => return failure,
    };
}

const test_count = 4;
const test_capacity = 64;

/// The cells the page reads: every published one, compared byte for byte.
fn expectSameCells(live: []const u8, copy: []const u8) !void {
    const newest = position(live);
    try std.testing.expectEqual(newest, position(copy));
    const stride = (live.len - ring.header_bytes) / test_count;
    var back: u64 = 1;
    while (back <= test_count and back <= newest) : (back += 1) {
        const at = ring.header_bytes + @as(usize, @intCast((newest - back) % test_count)) * stride;
        const len = ring.cell_header_bytes + std.mem.readInt(u32, live[at + len_offset ..][0..4], .little);
        try std.testing.expectEqualSlices(u8, live[at..][0..len], copy[at..][0..len]);
    }
}

test "a page kept up to date by deltas reads what the ring holds" {
    var live: [ring.regionSize(test_count, test_capacity)]u8 align(64) = undefined;
    var r = try ring.init(&live, test_count, test_capacity);
    var copy: [live.len]u8 = undefined;
    // The first answer is the mapping.
    try std.testing.expectEqual(@as(?usize, null), deltaLen(&live, 0));
    @memcpy(&copy, &live);

    var out: [live.len]u8 = undefined;
    var value: u8 = 1;
    while (value < 12) : (value += 1) {
        const after = position(&copy);
        try publishLatest(&r, value, value);
        const len = deltaLen(&live, after) orelse {
            @memcpy(&copy, &live);
            continue;
        };
        try std.testing.expect(len < live.len);
        writeDelta(&live, after, out[0..len]);
        apply(&copy, after, out[0..len]);
        try expectSameCells(&live, &copy);
    }
    // One frame: the header and one cell holding 11 bytes, nothing else.
    try std.testing.expectEqual(@as(?usize, ring.header_bytes + ring.cell_header_bytes + 11), deltaLen(&live, position(&live) - 1));
}

test "a page a lap behind, or ahead of the ring, gets the mapping" {
    var live: [ring.regionSize(test_count, test_capacity)]u8 align(64) = undefined;
    var r = try ring.init(&live, test_count, test_capacity);
    try publishByte(&r, 1, 1);
    try std.testing.expect(deltaLen(&live, 1) != null);
    try std.testing.expectEqual(@as(?usize, null), deltaLen(&live, 2));
    var i: u8 = 0;
    while (i < test_count) : (i += 1) try publishLatest(&r, i, 1);
    // Five published, the page at one: four frames behind is a whole lap.
    try std.testing.expectEqual(@as(?usize, null), deltaLen(&live, 1));
    try std.testing.expect(deltaLen(&live, 2) != null);
}

test "nothing new is a header and no cells" {
    var live: [ring.regionSize(test_count, test_capacity)]u8 align(64) = undefined;
    var r = try ring.init(&live, test_count, test_capacity);
    try publishByte(&r, 7, 3);
    try std.testing.expectEqual(@as(?usize, ring.header_bytes), deltaLen(&live, 1));
}
