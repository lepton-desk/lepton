//! `@lepton-desk/plugin-dialog`, the core side: the desktop's own file dialogs.
//!
//! The dialog is the desktop's, through xdg-desktop-portal (`core.portal`); the command
//! answers when the user has chosen, so it holds the page's request open
//! (`core.webviewInvoke.takeLater`). In a native application, or with eight dialogs
//! already open, it answers `failed` at once.

const std = @import("std");
const core = @import("lepton_core");
const request = @import("request.zig");

const Registry = core.webviewRegistry;

pub const commands = [_]Registry.PluginCommand{
    .{ .name = "dialog.open", .run = &open },
    .{ .name = "dialog.save", .run = &save },
};

/// The chosen paths are the user's own: a recording keeps their sizes, not their bytes.
pub const private = .{ "dialog.open", "dialog.save" };

fn open(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    return ask(.open, argument);
}

fn save(argument: []const u8, _: []u8) Registry.HandlerError!usize {
    return ask(.save, argument);
}

fn ask(mode: core.portal.Mode, argument: []const u8) Registry.HandlerError!usize {
    var storage: request.Storage = .{};
    const asked = request.decode(argument, &storage) catch return error.Failed;
    if (comptime !core.portal.available) return error.Failed;
    var filters: [request.max_filters]core.portal.Filter = undefined;
    for (asked.filters, 0..) |filter, index| filters[index] = .{ .name = filter.name, .patterns = filter.patterns };
    const later = core.webviewInvoke.takeLater() orelse return error.Failed;
    var options: core.portal.Options = .{
        .mode = mode,
        .title = asked.title,
        .accept_label = asked.accept_label,
        .multiple = asked.multiple,
        .directory = asked.directory,
        .current_name = asked.current_name,
        .current_folder = asked.current_folder,
        .filters = filters[0..asked.filters.len],
    };
    // `"plugins": { "fs": { "chosen": true } }`: what the user picks joins plugin-fs's
    // scope. Nothing is recorded otherwise. (A core from before grants has no such field.)
    if (comptime chosen and @hasField(core.portal.Options, "grant_to")) options.grant_to = identifier;
    core.portal.choose(options, later);
    return 0;
}

const config = @import("lepton_plugin_config").text;
const chosen = std.mem.eql(u8, core.pluginConfig.value(config, "fs.chosen") orelse "false", "true");
const identifier: []const u8 = core.pluginConfig.value(config, "app.identifier") orelse "";
