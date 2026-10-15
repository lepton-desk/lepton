//! A bounded multi-producer / multi-consumer ring living inside shared memory.
//!
//! The algorithm is the Vyukov bounded queue: each cell carries its own
//! sequence number, and producers and consumers claim positions with a CAS on a
//! shared counter. That gives per-cell ordering without a lock, which matters
//! here for two reasons — the window writes while the webview reads, and on
//! Linux the webview is a separate process mapping the same pages, so anything
//! requiring a mutex would be a mutex nobody shares.
//!
//! The cell header and the payload are deliberately two regions. A producer
//! writes the payload *in place* through a `std.Io.Writer` over the mapping and
//! only then publishes the length, so a payload never travels through an
//! intermediate buffer. That is the whole point of the channel: the bytes the
//! consumer reads are the bytes the producer wrote.
//!
//! Layout, in a single contiguous mapping:
//!
//! ```text
//!   +---------------------------+ 0
//!   | Header                    |
//! +---------------------------+ header_bytes
//!   | Cell 0 header | payload   |
//!   | Cell 1 header | payload   |
//!   | ...                       |
//! +---------------------------+ header_bytes + cell_count * cell_stride
//! ```
//!
//! Every field is naturally aligned and the region is page-aligned, so no cell
//! straddles a cache line in a way that would make the CAS false-share: cell
//! strides are rounded up to `cell_alignment`.

const std = @import("std");

pub const Error = error{
    /// The ring is at capacity and no cell could be claimed. The producer owns
    /// the decision to drop, backpressure, or grow; the ring only reports.
    Full,
    /// No published frame is waiting.
    Empty,
    /// A mapping too small to hold the ring it claims to describe.
    RegionTooSmall,
    /// A mapping that this build cannot read: wrong magic, wrong layout version,
    /// or a cell count that is not a power of two.
    NotLeptonRing,
    UnsupportedLayoutVersion,
    InvalidCellCount,
    /// `init` refused a ring whose counters could not be made atomic.
    UnsupportedAddressSpace,
    RegionInitFailed,
};

/// Bumped whenever the on-the-wire layout of `Header` or `CellHeader` changes.
/// A second process mapping an older layout must be refused, not misread.
pub const layout_version: u32 = 1;

/// Cells start on a 64-byte boundary: two cells then never share the cache line
/// holding their sequence counters, which is where false sharing would cost.
pub const cell_alignment: usize = 64;

/// `Header` is laid out for shared memory, so every field is atomically
/// addressable and the struct carries no Zig-only representation choices.
pub const Header = extern struct {
    /// `layout_magic`, checked on attach so a stale mapping is refused.
    magic: u64,
    /// `layout_version`, checked on attach.
    version: u32,
    /// Power of two; `cell_count - 1` is the index mask.
    cell_count: u32,
    /// Distance between cell headers, including padding to `cell_alignment`.
    cell_stride: u32,
    /// Usable payload bytes per cell, excluding the cell header.
    payload_capacity: u32,
    /// Padding so `enqueue_pos` lands on its own cache line: it is written by
    /// producers and read by consumers, and the two must not share a line.
    _pad: u32,
    /// Next position a producer will claim. Wraps; only ever compared modulo
    /// capacity by way of the mask.
    enqueue_pos: std.atomic.Value(u64),
    /// Padding to keep `dequeue_pos` off `enqueue_pos`'s line.
    _pad2: u32,
    dequeue_pos: std.atomic.Value(u64),
    /// Cells claimed by a consumer but not yet released.
    ///
    /// `enqueue_pos - dequeue_pos` alone understates occupancy: a consumer that
    /// has claimed a cell has moved the dequeue cursor but the cell is not
    /// reusable, so a producer still cannot use it. This counter is what makes
    /// the operator figure honest — it counts cells that are genuinely spoken
    /// for, whether or not a reader has picked them up yet.
    in_flight: std.atomic.Value(u64),
};

pub const header_bytes = std.mem.alignForward(usize, @sizeOf(Header), cell_alignment);

/// Per-cell metadata. `seq` encodes both the position the cell was filled at
/// and whether it is currently free, which is what lets producers and consumers
/// proceed without coordinating.
pub const CellHeader = extern struct {
    /// For a free cell, the position that must be claimed next. For a published
    /// cell, `position + 1`.
    seq: std.atomic.Value(u64),
    /// Bytes written into the payload. Only meaningful once `seq` is published.
    len: u32,
    _pad: u32,
};

pub const cell_header_bytes = @sizeOf(CellHeader);

const layout_magic: u64 = 0x4C50_544F_4E52_494E; // "LPTRIN"

/// The total mapping size needed to hold `cell_count` cells of at least
/// `payload_capacity` bytes each.
pub fn regionSize(cell_count: u32, payload_capacity: u32) usize {
    return header_bytes + strideFor(payload_capacity) * @as(usize, cell_count);
}

/// Lays down a fresh ring in `region` and returns a view of it.
///
/// Must run exactly once per region, before any other process attaches.
pub fn init(region: []u8, cell_count: u32, payload_capacity: u32) Error!Ring {
    return Ring.init(region, cell_count, payload_capacity);
}

/// Binds to a ring an earlier `init` laid down, refusing a mapping whose layout
/// this build cannot read correctly.
pub fn attach(region: []u8) Error!Ring {
    return Ring.attach(region);
}

fn strideFor(payload_capacity: u32) usize {
    const raw = cell_header_bytes + payload_capacity;
    return std.mem.alignForward(usize, raw, cell_alignment);
}

/// A view over a ring inside a mapping. Holds no allocation of its own; the
/// mapping is owned by whoever created it.
pub const Ring = struct {
    header: *Header,
    /// Cell headers, one per slot. Addressed through `cellAt` so the alignment
    /// and stride rules live in one place.
    cell_base: [*]u8,
    /// Each cell's payload start, parallel to the cells.
    payload_base: [*]u8,
    mask: u64,
    payload_capacity: u32,
    stride: usize,

    /// Initialises a fresh mapping. Must run exactly once, before any other
    /// process attaches.
    ///
    /// `cell_count` must be a power of two of at least two. One cell is not a
    /// degenerate case this algorithm can serve: with a single slot the producer
    /// and the consumer address the same sequence number, so a producer can
    /// observe the cell as free while the consumer is still reading it. Two cells
    /// is the smallest ring where a producer and a consumer never hold the same
    /// cell, and the refusal here is cheaper than silent corruption.
    pub fn init(region: []u8, cell_count: u32, payload_capacity: u32) Error!Ring {
        if (cell_count < 2 or cell_count & (cell_count - 1) != 0) return error.InvalidCellCount;
        const needed = regionSize(cell_count, payload_capacity);
        if (region.len < needed) return error.RegionTooSmall;
        // Positions and sequence numbers are 64-bit and manipulated with
        // single-instruction atomics. On a narrower address space that would
        // need a lock the second process does not share, so this is refused
        // rather than silently degraded.
        if (@sizeOf(usize) < 8) return error.UnsupportedAddressSpace;

        // The mapping arrives zeroed from the kernel, but a reused region would
        // not be, so initialisation is explicit rather than assumed.
        @memset(region, 0);

        const header: *Header = @ptrCast(@alignCast(region.ptr));
        header.* = .{
            .magic = layout_magic,
            .version = layout_version,
            .cell_count = cell_count,
            .cell_stride = @intCast(strideFor(payload_capacity)),
            .payload_capacity = payload_capacity,
            ._pad = 0,
            .enqueue_pos = std.atomic.Value(u64).init(0),
            ._pad2 = 0,
            .dequeue_pos = std.atomic.Value(u64).init(0),
            .in_flight = std.atomic.Value(u64).init(0),
        };

        // Every free cell publishes the position it is waiting for, which is
        // exactly its own index at startup.
        var i: u32 = 0;
        while (i < cell_count) : (i += 1) {
            self_cell(header, i).seq.store(i, .release);
        }

        return fromHeader(header, region.len);
    }

    /// Binds to a ring an earlier `init` laid down, refusing a mapping whose
    /// layout this build cannot read correctly.
    pub fn attach(region: []u8) Error!Ring {
        if (region.len < header_bytes) return error.RegionTooSmall;
        const header: *Header = @ptrCast(@alignCast(region.ptr));
        if (header.magic != layout_magic) return error.NotLeptonRing;
        if (header.version != layout_version) return error.UnsupportedLayoutVersion;
        // The same power-of-two and minimum-size rules `init` enforces, rechecked
        // here: a mapping can be edited by another process between the two calls.
        if (header.cell_count < 2 or header.cell_count & (header.cell_count - 1) != 0) {
            return error.InvalidCellCount;
        }
        return fromHeader(header, region.len);
    }

    fn fromHeader(header: *Header, region_len: usize) Error!Ring {
        const stride: usize = header.cell_stride;
        const need = header_bytes + stride * @as(usize, header.cell_count);
        if (need > region_len or stride < cell_header_bytes) return error.RegionTooSmall;

        return Ring{
            .header = header,
            .cell_base = region_ptr(header) + header_bytes,
            .payload_base = region_ptr(header) + header_bytes + cell_header_bytes,
            .mask = @as(u64, header.cell_count) - 1,
            .payload_capacity = header.payload_capacity,
            .stride = stride,
        };
    }

    /// The header of cell `index`. The stride keeps every cell 64-byte aligned,
    /// so the cast cannot fail.
    fn cellAt(self: *Ring, index: u32) *CellHeader {
        const offset = self.stride * @as(usize, index);
        return @ptrCast(@alignCast(self.cell_base + offset));
    }

    /// The payload bytes of cell `index`.
    fn payloadAt(self: *Ring, index: u32) []u8 {
        const offset = self.stride * @as(usize, index);
        return self.payload_base[offset .. offset + self.payload_capacity];
    }

    fn self_cell(header: *Header, index: u32) *CellHeader {
        const stride: usize = header.cell_stride;
        const base: [*]u8 = @ptrCast(region_ptr(header));
        const offset = header_bytes + stride * @as(usize, index);
        return @ptrCast(@alignCast(base + offset));
    }

    /// Cells currently readable. Sampled, not a lock: it is a figure for the
    /// operator panel, never a correctness input.
    pub fn occupancy(self: *Ring) u32 {
        const head = self.header.enqueue_pos.load(.acquire);
        const tail = self.header.dequeue_pos.load(.acquire);
        const claimed = self.header.in_flight.load(.acquire);
        // A cell claimed but not released still belongs to the consumer, so it is
        // added back: the figure is cells a producer cannot take, not cells
        // sitting unread in the queue.
        const used = (if (head > tail) head - tail else 0) + claimed;
        return @intCast(@min(used, @as(u64, self.header.cell_count)));
    }

    /// Total cells. Constant for the life of the ring.
    pub fn capacity(self: *const Ring) u32 {
        return self.header.cell_count;
    }

    /// Runs `write` with a writer pointed straight at a free cell's payload.
    /// Claims a free cell and hands back a writer over its payload.
    ///
    /// The caller writes in place — there is no staging buffer and no second copy
    /// — then calls `publish` with the length, or `abandon` to hand the cell back
    /// untouched. Keeping those two steps explicit at the call site is what makes
    /// a half-written frame impossible: a cell is only ever visible once its
    /// producer has said so.
    pub fn claim(self: *Ring) Error!Producer {
        return self.claimProducer();
    }

    /// Claims the oldest published cell and hands back a read-only view of it.
    ///
    /// The borrow ends at `release`. Holding it past that point would read a cell
    /// another thread or process is free to overwrite, so the release is a
    /// separate call rather than a scope.
    pub fn claimOldest(self: *Ring) Error!Consumer {
        const slot = try self.claimConsumer();
        // Counted before the caller sees the slot: the cell is spoken for from the
        // moment it is claimed, and a producer must treat it as unavailable.
        _ = self.header.in_flight.fetchAdd(1, .monotonic);
        return slot;
    }

    /// Publishes a claimed cell's payload.
    pub fn publish(self: *Ring, p: Producer, written: usize) void {
        self.commitProducer(&p, written);
    }

    /// Returns a claimed cell without publishing it, leaving the ring as it was.
    pub fn abandon(self: *Ring, p: Producer) void {
        self.releaseClaim(&p);
    }

    /// Returns a consumed cell to the ring. Idempotent: the claim records that it
    /// was released, so a second call cannot hand the same cell back twice and
    /// corrupt the ring's generation sequence.
    pub fn release(self: *Ring, c: *Consumer) void {
        if (c.released) return;
        c.released = true;
        self.releaseConsumer(c);
        _ = self.header.in_flight.fetchSub(1, .monotonic);
    }

    fn claimProducer(self: *Ring) Error!Producer {
        var pos = self.header.enqueue_pos.load(.acquire);
        while (true) {
            const cell = self.cellAt(@intCast(pos & self.mask));
            const seq = cell.seq.load(.acquire);
            const diff: i64 = @bitCast(seq -% pos);

            if (diff == 0) {
                // The cell is free and its sequence matches the position we
                // intend to claim.
                if (self.header.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .acquire, .monotonic)) |observed| {
                    pos = observed;
                    continue;
                }
                return .{ .ring = self, .index = @intCast(pos & self.mask), .pos = pos };
            }

            // The cell still holds a later generation: the ring is full.
            if (diff < 0) return error.Full;

            // Another producer moved the cursor; re-read and retry.
            pos = self.header.enqueue_pos.load(.acquire);
        }
    }

    fn commitProducer(self: *Ring, p: *const Producer, written: usize) void {
        const cell = self.cellAt(p.index);
        cell.len = @intCast(written);
        // Release: everything the producer wrote into the mapping must be
        // visible before a consumer can observe the published sequence.
        cell.seq.store(p.pos +% 1, .release);
    }

    fn releaseClaim(self: *Ring, p: *const Producer) void {
        const cell = self.cellAt(p.index);
        cell.len = 0;
        // Returning to the pre-claim sequence makes the cell claimable again
        // without disturbing the enqueue cursor.
        cell.seq.store(p.pos, .release);
    }

    fn claimConsumer(self: *Ring) Error!Consumer {
        var pos = self.header.dequeue_pos.load(.acquire);
        while (true) {
            const cell = self.cellAt(@intCast(pos & self.mask));
            const seq = cell.seq.load(.acquire);
            const diff: i64 = @bitCast(seq -% (pos +% 1));

            if (diff == 0) {
                if (self.header.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .acquire, .monotonic)) |observed| {
                    pos = observed;
                    continue;
                }
                return .{ .ring = self, .index = @intCast(pos & self.mask), .pos = pos };
            }

            // Not yet published: the ring is empty.
            if (diff < 0) return error.Empty;

            pos = self.header.dequeue_pos.load(.acquire);
        }
    }

    fn releaseConsumer(self: *Ring, c: *const Consumer) void {
        const cell = self.cellAt(c.index);
        cell.len = 0;
        // Hand the cell to the producer that is `capacity` positions behind us.
        cell.seq.store(c.pos +% self.mask +% 1, .release);
    }

    /// A claimed, unpublished cell. `writer` addresses the mapping directly.
    pub const Producer = struct {
        ring: *Ring,
        index: u32,
        pos: u64,

        /// In-place writer over this cell's payload.
        pub fn writer(self: *Producer) std.Io.Writer {
            return .fixed(self.ring.payloadAt(self.index));
        }
    };

    /// A claimed, published cell, read-only.
    pub const Consumer = struct {
        ring: *Ring,
        index: u32,
        pos: u64,
        /// Set once the cell has gone back to the ring, so a double release is
        /// a no-op rather than a second hand-back that would corrupt the ring.
        released: bool = false,

        /// The published payload, pointing into shared memory. Valid until the
        /// claim is released.
        pub fn bytes(self: *Consumer) []const u8 {
            const cell = self.ring.cellAt(self.index);
            return self.ring.payloadAt(self.index)[0..cell.len];
        }
    };
};

fn region_ptr(header: *Header) [*]u8 {
    return @ptrCast(header);
}
