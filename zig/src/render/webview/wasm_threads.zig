//! `wasm.threads` (`lepton.config.json`): WebAssembly threads in the page.
//!
//! A page gets `SharedArrayBuffer` only when it is cross-origin isolated: every answer
//! the core gives carries `Cross-Origin-Opener-Policy: same-origin` and
//! `Cross-Origin-Embedder-Policy: require-corp` (web.dev, "Making your website
//! cross-origin isolated"). WPE 2.54.2 needs more (measured, `docs/plans/wasm.md`): with
//! the headers `crossOriginIsolated` is true and `SharedArrayBuffer` still absent, and it
//! appears only with JavaScriptCore's `useSharedArrayBuffer` option, which the web process
//! reads from its environment. That option is JavaScriptCore-wide, not per origin: it
//! turns `SharedArrayBuffer` on without the headers too. Off unless the project asks.

const std = @import("std");

pub const enabled = @import("build_options").wasm_threads;

/// The two headers, as name and value.
pub const headers = [_][2][:0]const u8{
    .{ "Cross-Origin-Opener-Policy", "same-origin" },
    .{ "Cross-Origin-Embedder-Policy", "require-corp" },
};

/// Sets JavaScriptCore's option for the web processes the engine starts after this call.
/// WPE only; a no-op unless the project turned threads on.
pub fn prepareJavaScriptCore() void {
    if (!enabled) return;
    _ = @import("wpe_view.zig").setenv("JSC_useSharedArrayBuffer", "1", 1);
}

/// The headers as lines for a WebView2 header block, each ending in `\r\n`.
pub fn headerLines(out: []u8) error{NoSpaceLeft}![]const u8 {
    if (!enabled) return out[0..0];
    var used: usize = 0;
    for (headers) |header| {
        const line = try std.fmt.bufPrint(out[used..], "{s}: {s}\r\n", .{ header[0], header[1] });
        used += line.len;
    }
    return out[0..used];
}

test "the header lines follow the build's setting" {
    var out: [128]u8 = undefined;
    const lines = try headerLines(&out);
    if (enabled) {
        try std.testing.expectEqualStrings("Cross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\n", lines);
    } else {
        try std.testing.expectEqualStrings("", lines);
    }
}
