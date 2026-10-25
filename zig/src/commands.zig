//! An application's commands: what its `main.zig` and its plugins register, and what a
//! command uses to answer. Engine-neutral names for them — a web view's page calls these
//! today, a native app's script will in 0.2.0 — so `main.zig` does not name the web view.
//! `core.webviewRegistry` and `core.webviewInvoke.takeLater` stay, the same declarations
//! under their first names.

const registry = @import("render/webview/registry.zig");
const invoke = @import("render/webview/invoke.zig");

pub const HandlerError = registry.HandlerError;
pub const Command = registry.Command;
pub const PluginCommand = registry.PluginCommand;
pub const Registry = registry.Registry;
pub const checked = registry.checked;
pub const checkedWith = registry.checkedWith;
pub const pluginCommands = registry.pluginCommands;
pub const permissionList = registry.permissionList;

/// A reply a command owes and gives later (a dialog waits for the user): `takeLater`
/// inside the command, `Later.finish` when the answer is there.
pub const Later = invoke.Later;
pub const takeLater = invoke.takeLater;

test {
    _ = checkedWith;
    _ = takeLater;
}
