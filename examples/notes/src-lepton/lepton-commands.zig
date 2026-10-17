//! Prints the TypeScript that names this application's commands and events for the page.
//!
//! Built and run by `build.zig` on every core build; its output is installed as
//! `zig-out/lepton-commands.d.ts`, and `lepton build`, `run` and `dev` copy that into
//! `src/`. The lists are `main.zig`'s own `commands` and `events`, so a name added there is
//! one the page's code can `invoke` or `listen` to after the next build — and a removed one
//! is a type error.

const std = @import("std");
const app = @import("app");
const core = @import("lepton_core");

pub fn main() !void {
    const text = comptime core.webviewDeclarations.file(app.commands, app.events);
    var sent: usize = 0;
    while (sent < text.len) {
        const wrote = std.c.write(1, text[sent..].ptr, text.len - sent);
        if (wrote <= 0) return error.WriteFailed;
        sent += @intCast(wrote);
    }
}
