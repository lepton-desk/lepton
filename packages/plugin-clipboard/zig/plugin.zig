//! `@lepton-desk/plugin-clipboard`, the core side: the system clipboard as UTF-8 text.
//!
//! The WPE calls are the core's (`core.webviewClipboard`), so this file compiles into a
//! native application too, where both commands answer `failed`. A page may call a command
//! only when the application lists it under `permissions`.

const core = @import("lepton_core");

const Registry = core.webviewRegistry;
const clipboard = core.webviewClipboard;

pub const commands = [_]Registry.PluginCommand{
    .{ .name = "clipboard.read_text", .run = &readText },
    .{ .name = "clipboard.write_text", .run = &writeText },
};

/// No argument; answers the clipboard's text, empty when it holds none.
fn readText(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return clipboard.readText(out);
}

/// The argument is the text; answers nothing.
fn writeText(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    try clipboard.writeText(argument);
    return 0;
}
