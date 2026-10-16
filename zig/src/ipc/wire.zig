//! The frame format carried by every ring cell.
//!
//! Lepton does not serialise to text. A frame is a fixed-layout header followed
//! by a payload whose shape the `kind` determines, so a reader indexes into the
//! bytes it already has rather than parsing a document. That is what keeps the
//! IPC path free of allocation and of the string handling that made Electron's
//! bridge a bottleneck in the first place.
//!
//! Every field is little-endian and fixed-width, and the header is padded to
//! eight bytes so a payload that wants 8-byte alignment can start at offset 24.
//! Both endpoints are Lepton builds on the same machine, so byte order is fixed
//! by the platform rather than negotiated.

const std = @import("std");

/// Bumped when the meaning of an existing `kind` changes. Additive kinds do not
/// bump it, because a reader that meets an unknown kind can skip the payload.
pub const version: u16 = 1;

/// Total header size, including trailing padding.
pub const header_bytes: usize = 24;

/// What a payload means. `_` is reserved so a newer core's frame is skipped
/// rather than misread by an older one.
pub const Kind = enum(u16) {
    /// Handshake. Payload is `Hello`.
    hello = 1,
    /// A machine reading. Payload is `Sample`.
    sample = 2,
    /// One discrete event. Payload is `Event`.
    event = 3,
    /// A request with a reply. Payload is `Request`.
    request = 4,
    /// A reply. Payload is `Reply`.
    reply = 5,
    /// A named event for the page, with bytes. Payload is `Notice`, then the name, then
    /// the data. Additive: an older reader skips it by `payload_len`.
    notice = 6,
    _,

    /// Whether a reader that does not know this kind can still walk past the
    /// frame using `payload_len` alone.
    pub fn isSkippable(self: Kind) bool {
        return switch (self) {
            .hello, .sample, .event, .request, .reply, .notice => false,
            _ => true,
        };
    }
};

/// The frame header. `extern struct` because its layout is the contract.
pub const Header = extern struct {
    protocol: u16,
    kind: Kind,
    /// `reply` and `fragment` occupy the top two bits of `reserved`, so the
    /// flags live in a `u16` rather than in `u1` fields, which `extern struct`
    /// cannot carry.
    reserved: u16 = 0,
    /// Padding, named so it is written as zeros: an unnamed gap is whatever the stack
    /// held, and every frame carried it to the page (a replay caught a stack address).
    _pad0: u16 = 0,
    /// Payload bytes following the header. Bounded by the cell capacity.
    payload_len: u32,
    _pad1: u32 = 0,
    /// Monotonic per-channel counter. Zero on a `hello`.
    sequence: u64,
};

/// `hello` payload: who is on the other end, and what it can do.
pub const Hello = extern struct {
    /// Core build id the sender was compiled as.
    build: u64,
    /// Render path the sender drives: webview or pure native.
    mode: u16,
    _pad0: u16 = 0,
    _pad1: u32 = 0,
    /// Bit per capability the sender supports.
    capabilities: u64,
};

/// Render path. Part of the handshake because it decides which window the core
/// opens, and the two paths share nothing below the channel.
pub const Mode = enum(u16) {
    webview = 0,
    native = 1,
    _,
};

/// `sample` payload: one reading, delivered whole.
///
/// Fixed-width so the webview can read any field from the mapped bytes with a
/// single load and no intermediate object. `timestamp_ns` is monotonic on the
/// sending machine, which is what makes the latency figures comparable.
pub const Sample = extern struct {
    timestamp_ns: u64,
    /// Resident set size of the core process, in bytes.
    rss_bytes: u64,
    /// Peak heap the allocator has handed out.
    heap_high_water_bytes: u64,
    /// Bytes currently reserved by the allocator.
    heap_in_use_bytes: u64,
    /// Free cells in the shared ring at send time.
    ring_free_cells: u32,
    /// Total cells in the shared ring.
    ring_capacity_cells: u32,
    /// Round-trip of the previous request/reply pair.
    round_trip_ns: u64,
    /// Worst round-trip observed since the last reset.
    round_trip_max_ns: u64,
};

/// `event` payload: something happened that the operator should see.
pub const Event = enum(u32) {
    window_resized = 1,
    window_focused = 2,
    webview_ready = 3,
    webview_navigated = 4,
    render_surface_lost = 5,
    channel_overflow = 6,
    permission_denied = 7,
    _,

    /// Events the operator panel shows as a line. Everything else is debug-only,
    /// which is what keeps the event stream readable instead of a firehose.
    pub fn isOperatorVisible(self: Event) bool {
        return switch (self) {
            .window_resized, .window_focused, .webview_ready, .render_surface_lost, .channel_overflow, .permission_denied => true,
            _ => false,
        };
    }
};

/// `request` payload: an id the reply must echo.
pub const Request = extern struct {
    /// Application-defined command id, from the capabilities table.
    command: u32,
    /// Bytes of inline argument following this struct.
    argument_len: u32,
    argument_off: u32,
    reserved: u32,
};

/// `reply` payload: the outcome of a request. `status` is zero on success.
pub const Reply = extern struct {
    request_sequence: u64,
    status: u32,
    reserved: u32,
    result_len: u32,
    result_off: u32,
    _pad: u32,
    /// The struct is 8-aligned: without this the last four bytes are a gap.
    _pad1: u32 = 0,
};

/// `notice` payload: the lengths of the name and data that follow it, in that order.
pub const Notice = extern struct {
    name_len: u16,
    reserved: u16,
    data_len: u32,
};

/// Flags a frame header can carry. The header has two spare bits beside these,
/// kept as `reserved` so a later flag does not shift the layout.
pub const Flags = struct {
    /// Set on the frame that acknowledges a `request`.
    reply: bool = false,
    /// Set when the payload is a prefix of a larger logical message.
    fragment: bool = false,
};

/// Reads a flag back out of a decoded header. Present so a caller never has to
/// know which bit of `reserved` a flag occupies.
pub fn flagOf(h: Header, comptime flag: enum { reply, fragment }) bool {
    return switch (flag) {
        .reply => (h.reserved & flag_reply) != 0,
        .fragment => (h.reserved & flag_fragment) != 0,
    };
}

/// Bit positions of `Flags` inside `Header.reserved`.
const flag_reply: u16 = 1 << 11;
const flag_fragment: u16 = 1 << 10;

/// Composes a frame header. Kept as a function so no caller can build one with
/// an inconsistent header/payload pair, and so the flag bits are set in one
/// place rather than at each call site.
pub fn header(kind: Kind, payload_len: u32, sequence: u64, opts: Flags) Header {
    var reserved: u16 = 0;
    if (opts.reply) reserved |= flag_reply;
    if (opts.fragment) reserved |= flag_fragment;
    return .{
        .protocol = version,
        .kind = kind,
        .reserved = reserved,
        .payload_len = payload_len,
        .sequence = sequence,
    };
}

/// Decodes a header from the front of a payload-bearing buffer.
///
/// Returns `error.ShortFrame` rather than reading past the end, because the
/// buffer may hold fewer bytes than a header when a cell is being written.
pub fn readHeader(bytes: []const u8) DecodeError!Header {
    if (bytes.len < header_bytes) return error.ShortFrame;
    const h: Header = @bitCast(bytes[0..header_bytes].*);
    if (h.protocol != version) return error.UnsupportedProtocol;
    return h;
}

/// The payload slice a header describes.
pub fn payloadOf(bytes: []const u8, h: Header) DecodeError![]const u8 {
    const start = header_bytes;
    const end = start + @as(usize, h.payload_len);
    if (bytes.len < end) return error.ShortFrame;
    return bytes[start..end];
}

/// Reads a fixed-layout payload from a slice, refusing a short one.
pub fn readPayload(comptime T: type, payload: []const u8) DecodeError!T {
    if (payload.len < @sizeOf(T)) return error.ShortPayload;
    const value: T = @bitCast(payload[0..@sizeOf(T)].*);
    return value;
}

pub const DecodeError = error{
    ShortFrame,
    ShortPayload,
    UnsupportedProtocol,
};

/// The payload type a kind carries, so `Channel.send` can type-check a payload
/// against its kind at the call site.
///
/// A kind this build does not know has no payload type, which is deliberate:
/// the compiler refuses to send a frame whose meaning cannot be established here,
/// and a receiver instead skips an unknown frame using its `payload_len`.
pub fn PayloadFor(comptime kind: Kind) type {
    return switch (kind) {
        .hello => Hello,
        .sample => Sample,
        .event => Event,
        .request => Request,
        .reply => Reply,
        .notice => Notice,
        else => FrameAbsent,
    };
}

/// The payload of a kind with no payload type in this build. Only reachable when
/// a `Kind` is manufactured rather than named literally, which is why it is a
/// distinct type rather than `void`: a zero-sized payload cannot be sent by
/// accident through the same path as a real one.
pub const FrameAbsent = enum {};

/// Whether `T`'s fields cover every byte of it: a gap the compiler inserts is never
/// written, so it would carry whatever memory held before.
fn coversEveryByte(comptime T: type) bool {
    var covered: usize = 0;
    for (@typeInfo(T).@"struct".fields) |field| covered += @sizeOf(field.type);
    return covered == @sizeOf(T);
}

test "no frame struct has a gap that would carry stale memory" {
    inline for (.{ Header, Hello, Sample, Request, Reply, Notice }) |T| {
        try std.testing.expect(comptime coversEveryByte(T));
    }
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Header, "sequence"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Header, "payload_len"));
}
