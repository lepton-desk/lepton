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

/// The clipboard is the user's own: a recording keeps its sizes, not its text.
pub const private = .{ "clipboard.read_text", "clipboard.write_text" };

/// What the first byte of a `clipboard.read_text` reply says.
pub const Known = enum(u8) {
    /// The compositor has not told this window what the selection is yet: it does so
    /// when the window gains focus, a moment later. Ask again.
    not_yet = 0,
    /// The text follows (possibly empty: the clipboard holds no text).
    text = 1,
};

/// No argument. Answers one [`Known`] byte, then the clipboard's text.
///
/// WPE's change count is 0 until the first `wl_data_device.selection` arrives — an empty
/// selection counts too (measured) — so 0 is "not told yet", never "empty".
fn readText(_: []const u8, out: []u8) Registry.HandlerError!usize {
    if (out.len == 0) return error.TooLarge;
    if (clipboard.changeCount() == 0) {
        out[0] = @intFromEnum(Known.not_yet);
        return 1;
    }
    out[0] = @intFromEnum(Known.text);
    return 1 + try clipboard.readText(out[1..]);
}

/// The argument is the text; answers nothing.
fn writeText(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    try clipboard.writeText(argument);
    return 0;
}
