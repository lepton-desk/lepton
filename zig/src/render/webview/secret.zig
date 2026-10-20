//! The run's key to the core's own paths.
//!
//! The core answers `invoke`, events, the ring and `close` for the application's own page
//! only. Asking the request who sent it is not enough: WPE 2.54 sends no `Origin` on the
//! page's own `invoke` POST, and a sandboxed `srcdoc` iframe's POST reached the core with
//! none either (measured with `LEPTON_TRACE_REQUESTS=1`, 2026-10-20). So each run makes a
//! random key; the core's paths are `/__lepton/<key>/…`; the key is written only into the
//! transport (`transport.zig`), which defines itself only in the application's own page.
//! A page that has no transport cannot name a path the core answers.

const std = @import("std");

/// Hex characters in the key: 16 random bytes.
pub const length = 32;

/// Where the key goes in text written before it exists (the comptime layout); replaced in
/// place, so it has the key's length.
pub const marker: *const [length]u8 = "#" ** length;

var key: [length]u8 = undefined;
var made = false;

/// The key, made on first use from the operating system's entropy.
pub fn get() *const [length]u8 {
    if (!made) {
        var raw: [length / 2]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        io.randomSecure(&raw) catch io.random(&raw);
        key = std.fmt.bytesToHex(raw, .lower);
        made = true;
    }
    return &key;
}

/// Replaces every `marker` in `text` with the key, in place.
pub fn fill(text: []u8) void {
    const value = get();
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, marker)) |found| {
        @memcpy(text[found..][0..length], value);
        at = found + length;
    }
}

/// The name after `/__lepton/<key>` when `path` is one of the core's own, else null:
/// `/__lepton/<key>/invoke` → `/invoke`. Compared in constant time.
pub fn corePath(path: []const u8) ?[]const u8 {
    const prefix = "/__lepton/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len < length + 1 or rest[length] != '/') return null;
    const given: *const [length]u8 = rest[0..length];
    if (!std.crypto.timing_safe.eql([length]u8, given.*, get().*)) return null;
    return rest[length..];
}

test "the key is hex, stable within a run, and opens only its own paths" {
    const first = get().*;
    try std.testing.expectEqualSlices(u8, &first, get());
    for (first) |char| try std.testing.expect(std.ascii.isHex(char));

    var path_buffer: [64]u8 = undefined;
    const own = try std.fmt.bufPrint(&path_buffer, "/__lepton/{s}/invoke", .{first});
    try std.testing.expectEqualStrings("/invoke", corePath(own).?);
    try std.testing.expect(corePath("/__lepton/invoke") == null);
    try std.testing.expect(corePath("/__lepton/" ++ "0" ** length ++ "/invoke") == null or
        std.mem.eql(u8, &first, "0" ** length));
    try std.testing.expect(corePath("/assets/app.js") == null);

    var text = ("url:\"lepton://localhost/__lepton/" ++ "#" ** length ++ "/invoke\"").*;
    fill(&text);
    try std.testing.expect(std.mem.indexOf(u8, &text, &first) != null);
    try std.testing.expect(std.mem.indexOf(u8, &text, "#") == null);
}
