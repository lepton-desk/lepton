//! The core's own start-up lines, printed as `lepton` prints its facts: `  ◆ label  value`,
//! the label dim and aligned, the value coloured by what it means.
//!
//! Coloured by the same rule as the CLI (`crates/cli/src/style.rs`): never with
//! `NO_COLOR`; always with `FORCE_COLOR` or `CLICOLOR_FORCE`, which `lepton run` and `dev`
//! set for what they stream through a pipe (`crates/orchestrator/src/colour.rs`);
//! otherwise when stderr is a terminal — a packaged application started from a shell.

const std = @import("std");

pub const Tone = enum {
    plain,
    /// It worked: `scope  joined`.
    good,
    /// It did not, and the application carries on without it.
    warn,
    /// The application cannot do what it was asked.
    bad,
};

const violet = "\x1b[38;5;141m";
const dim = "\x1b[38;5;245m";
const reset = "\x1b[0m";

fn open(tone: Tone) []const u8 {
    return switch (tone) {
        .plain => "",
        .good => "\x1b[38;5;79m",
        .warn => "\x1b[38;5;214m",
        .bad => "\x1b[38;5;210m",
    };
}

/// Whether the variable is set to something other than empty or `0`.
fn truthy(name: [*:0]const u8) bool {
    const value = std.mem.span(std.c.getenv(name) orelse return false);
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

/// Decided once: the environment does not change while the application runs.
var decided: ?bool = null;

fn stderrIsTerminal() bool {
    if (@import("builtin").os.tag != .windows) return std.c.isatty(2) != 0;
    // A console (Windows 10 consoles take ANSI colour once virtual terminal processing is
    // on, which Windows Terminal and the IDE terminals have by default).
    return std.Io.File.stderr().isTty(std.Io.Threaded.global_single_threaded.io()) catch false;
}

pub fn colour() bool {
    if (decided) |known| return known;
    const on = if (std.c.getenv("NO_COLOR")) |value|
        std.mem.span(value).len == 0
    else
        truthy("FORCE_COLOR") or truthy("CLICOLOR_FORCE") or stderrIsTerminal();
    decided = on;
    return on;
}

/// `  ◆ scope          joined` on stderr.
pub fn fact(label: []const u8, tone: Tone, comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    line(&stderr.file_writer.interface, colour(), label, tone, format, args) catch return;
}

/// One fact line into `out`, with or without colour.
pub fn line(out: *std.Io.Writer, coloured: bool, label: []const u8, tone: Tone, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    if (coloured) {
        try out.print("  " ++ violet ++ "◆" ++ reset ++ " " ++ dim ++ "{s:<14}" ++ reset ++ " {s}", .{ label, open(tone) });
        try out.print(format, args);
        try out.writeAll(reset ++ "\n");
    } else {
        try out.print("  ◆ {s:<14} ", .{label});
        try out.print(format ++ "\n", args);
    }
    try out.flush();
}

test "a fact line, plain and coloured" {
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try line(&out, false, "scope", .good, "{s}", .{"joined"});
    try std.testing.expectEqualStrings("  ◆ scope          joined\n", out.buffered());

    out = .fixed(&buffer);
    try line(&out, true, "window", .warn, "{s} · {d}×{d}", .{ "wayland", 800, 600 });
    try std.testing.expectEqualStrings(
        "  " ++ violet ++ "◆" ++ reset ++ " " ++ dim ++ "window        " ++ reset ++ " \x1b[38;5;214mwayland · 800×600" ++ reset ++ "\n",
        out.buffered(),
    );
}
