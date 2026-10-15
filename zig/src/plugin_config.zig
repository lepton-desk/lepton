//! A plugin's settings from `lepton.config.json`, read at compile time.
//!
//! The CLI flattens the `plugins` section into lines — `"plugins": { "fs": { "scope":
//! ["$APPDATA", "$DOCUMENT"] } }` becomes `fs.scope=$APPDATA` and `fs.scope=$DOCUMENT`,
//! one line per array item — adds `app.identifier=<identifier>`, and hands the text to
//! the build as `-Dplugin-config`. The project's `build.zig` makes it the module
//! `lepton_plugin_config` (`pub const text`), which every plugin may import. Lines rather
//! than JSON because the values are only ever strings and the reading happens in
//! `comptime`, where a JSON parser would cost every build.

const std = @import("std");

/// Every value of `key`, in order.
pub fn values(comptime text: []const u8, comptime key: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var found: []const []const u8 = &.{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line[0..equals], key)) found = found ++ .{line[equals + 1 ..]};
        }
        return found;
    }
}

/// The single value of `key`, or null; more than one is a compile error.
pub fn value(comptime text: []const u8, comptime key: []const u8) ?[]const u8 {
    const all = values(text, key);
    if (all.len > 1) @compileError("plugin setting \"" ++ key ++ "\" is given more than once");
    return if (all.len == 1) all[0] else null;
}

test "settings are read by key, every value in order" {
    const text = "app.identifier=style.notes\nfs.scope=$APPDATA\nfs.scope=$DOCUMENT/notlar\nfs.other=x";
    const scope = comptime values(text, "fs.scope");
    try std.testing.expectEqual(@as(usize, 2), scope.len);
    try std.testing.expectEqualStrings("$APPDATA", scope[0]);
    try std.testing.expectEqualStrings("$DOCUMENT/notlar", scope[1]);
    try std.testing.expectEqualStrings("style.notes", comptime value(text, "app.identifier").?);
    try std.testing.expect(comptime value(text, "missing") == null);
    try std.testing.expectEqual(@as(usize, 0), (comptime values("", "fs.scope")).len);
}
