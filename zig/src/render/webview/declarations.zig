//! `src/lepton-commands.d.ts`: the names of an application's commands and events, for the
//! page's TypeScript, generated from `main.zig`'s own `commands` and `events`.
//!
//! The first line is what `lepton` checks before replacing the file (`command_types.rs`),
//! so it stays exactly as the first version wrote it.

const std = @import("std");

/// The whole file for `commands` (a `registry.Registered(State)`) and `Events` (a
/// `events.Declared(...)` type).
pub fn file(comptime commands: anytype, comptime Events: type) []const u8 {
    comptime {
        var event_lines: []const u8 = "";
        for (Events.list) |name| event_lines = event_lines ++ "    \"" ++ name ++ "\": true;\n";
        return "// Generated from this application's commands (`main.zig`) by its core build.\n" ++
            "// Do not edit: `lepton build`, `run` and `dev` rewrite it.\n\n" ++
            "declare module \"@lepton-desk/api/core\" {\n  interface AppCommands {\n" ++
            commands.entries ++
            "  }\n}\n\n" ++
            "declare module \"@lepton-desk/api/event\" {\n  interface AppEvents {\n" ++
            event_lines ++
            "  }\n}\n\nexport {};\n";
    }
}

test "commands and events land in their own modules of one file" {
    const registry = @import("registry.zig");
    const events = @import("events.zig");
    const State = struct {};
    const commands = comptime registry.checked(State, &.{}, registry.permissionList(""));
    const text = comptime file(commands, events.Declared(&.{"notes.saved"}));
    try std.testing.expect(std.mem.startsWith(u8, text, "// Generated from this application's commands (`main.zig`)"));
    try std.testing.expect(std.mem.indexOf(u8, text, "declare module \"@lepton-desk/api/event\" {\n  interface AppEvents {\n    \"notes.saved\": true;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "interface AppCommands {\n  }") != null);
}
