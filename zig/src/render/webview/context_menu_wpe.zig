//! The default context menu under WPE (`context_menu.zig`).
//!
//! WPE emits `context-menu` for a right click the page did not take and draws nothing:
//! the menu is the embedder's, and WPE's Wayland surfaces are WPE's own, so the core
//! cannot open a popup beside them. The menu is drawn into the page instead
//! (`context_menu.js`), in a script world of its own (`lepton-menu`): the handler that
//! carries the choice back exists only there, so the page's scripts cannot choose for
//! the user, and the menu sits in a closed shadow root in the top layer. The chosen
//! action is WebKit's own editing command on the focused field or the selection.

const std = @import("std");
const menu = @import("context_menu.zig");

const e_signal_connect = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    .{ .name = "g_signal_connect_data" },
);
const e_get_user_content_manager = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "webkit_web_view_get_user_content_manager" });
const e_register_handler = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    .{ .name = "webkit_user_content_manager_register_script_message_handler" },
);
const e_hit_is_editable = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_hit_test_result_context_is_editable" });
const e_hit_is_selection = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_hit_test_result_context_is_selection" });
const e_menu_position = @extern(*const fn (?*anyopaque, *c_int, *c_int) callconv(.c) c_int, .{ .name = "webkit_context_menu_get_position" });
const e_evaluate = @extern(
    *const fn (?*anyopaque, [*]const u8, isize, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, ?*const anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_web_view_evaluate_javascript" },
);
const e_execute_editing = @extern(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void, .{ .name = "webkit_web_view_execute_editing_command" });
const e_toggle_inspector = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_web_view_toggle_inspector" });
const e_value_to_int32 = @extern(*const fn (?*anyopaque) callconv(.c) i32, .{ .name = "jsc_value_to_int32" });

/// The script world the menu lives in, and the handler's name there.
const world = "lepton-menu";
const handler = "leptonMenu";

/// `context_menu.js`: an expression, called below with the point and the entries.
const script = @embedFile("context_menu.js");

/// The view whose menu is open: the choice arrives on the content manager, which views
/// opened with `window.open` share, so it names no view.
var showing: ?*anyopaque = null;

/// Answers `web_view`'s right clicks with the default menu, unless the application
/// turned it off.
pub fn apply(web_view: *anyopaque) void {
    if (comptime !menu.enabled) return;
    _ = e_signal_connect(web_view, "context-menu", @ptrCast(&onContextMenu), null, null, 0);
    const manager = e_get_user_content_manager(web_view) orelse return;
    // Once per manager: a second registration of the name is refused, and the views a
    // page opens share their opener's manager and its connection.
    if (e_register_handler(manager, handler, world) != 0) {
        _ = e_signal_connect(manager, "script-message-received::" ++ handler, @ptrCast(&onChosen), null, null, 0);
    }
}

fn onContextMenu(web_view: ?*anyopaque, context_menu: ?*anyopaque, hit: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    var x: c_int = 0;
    var y: c_int = 0;
    _ = e_menu_position(context_menu, &x, &y);
    var entries: [menu.max_entries]menu.Entry = undefined;
    const shown = menu.entries(.{
        .editable = e_hit_is_editable(hit) != 0,
        .selection = e_hit_is_selection(hit) != 0,
    }, menu.inspect, &entries);

    var buffer: [script.len + 256]u8 = undefined;
    const call = callText(&buffer, x, y, shown, menu.turkish()) catch return 1;
    showing = web_view;
    e_evaluate(web_view, call.ptr, @intCast(call.len), world, null, null, null, null);
    // Handled: WebKit shows nothing of its own either way, and says so.
    return 1;
}

/// `context_menu.js` called with the point and the entries as `[id, enabled, label]`.
fn callText(buffer: []u8, x: c_int, y: c_int, entries: []const menu.Entry, turkish: bool) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.print("{s}({d},{d},[", .{ script, x, y });
    for (entries, 0..) |entry, index| {
        if (index > 0) try writer.writeByte(',');
        const action = entry.action orelse {
            try writer.writeAll("[0,true,\"\"]");
            continue;
        };
        // The labels are this file's own words: no quote or backslash to escape.
        try writer.print("[{d},{s},\"{s}\"]", .{ @intFromEnum(action), if (entry.enabled) "true" else "false", menu.label(action, turkish) });
    }
    try writer.writeAll("])");
    return writer.buffered();
}

fn onChosen(_: ?*anyopaque, value: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const web_view = showing orelse return;
    showing = null;
    const action = menu.Action.fromId(e_value_to_int32(value)) orelse return;
    switch (action) {
        .cut => e_execute_editing(web_view, "Cut"),
        .copy => e_execute_editing(web_view, "Copy"),
        .paste => e_execute_editing(web_view, "Paste"),
        .select_all => e_execute_editing(web_view, "SelectAll"),
        .inspect => if (comptime menu.inspect) e_toggle_inspector(web_view),
    }
}

test "the call names the point and each entry" {
    var entries: [menu.max_entries]menu.Entry = undefined;
    const shown = menu.entries(.{ .editable = true, .selection = false }, true, &entries);
    var buffer: [script.len + 256]u8 = undefined;
    const call = try callText(&buffer, 12, 340, shown, false);
    try std.testing.expect(std.mem.startsWith(u8, call, script));
    try std.testing.expectEqualStrings(
        \\(12,340,[[1,false,"Cut"],[2,false,"Copy"],[3,true,"Paste"],[4,true,"Select All"],[0,true,""],[5,true,"Inspect"]])
    , call[script.len..]);
}

/// WebKit is linked: the webview builds.
const build_options = @import("build_options");
const available = build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render;

test "the engine callbacks are compiled" {
    if (comptime !available) return error.SkipZigTest;
    _ = &apply;
    _ = &onContextMenu;
    _ = &onChosen;
}
