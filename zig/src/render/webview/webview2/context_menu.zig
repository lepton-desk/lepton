//! The default context menu on WebView2 (`../context_menu.zig`): WebView2's own menu,
//! kept to its editing items — Cut, Copy, Paste, Select All, and Inspect in a developer's
//! build — so it has WebView2's labels, shortcuts and enabled states, and WebView2
//! performs the choice. Everything else (Back, Reload, Save as, Print, Share, links,
//! images) is removed, and so is a separator left at an end or beside another.
//!
//! WebView2 lists an editing item only where it applies (no Paste outside a field), where
//! the WPE and Servo menus show it disabled; a menu with nothing left is not shown.
//!
//! Item names are WebView2's unlocalized ones, "the English label of the menu item in
//! lower camel case" (`ICoreWebView2ContextMenuItem::get_Name`): `cut`, `copy` and
//! `paste` are the reference's own examples; `selectAll`, `inspect` and `inspectElement`
//! follow its rule and are not yet measured (`docs/durum.md`).

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const menu = @import("../context_menu.zig");

const Handler = wv.Handler(
    c.ICoreWebView2ContextMenuRequestedEventHandler,
    c.ICoreWebView2ContextMenuRequestedEventHandlerVtbl,
    &c.IID_ICoreWebView2ContextMenuRequestedEventHandler,
    onRequested,
);

/// One for every view: it keeps no state of its own.
var handler: c.ICoreWebView2ContextMenuRequestedEventHandler = Handler.make();

/// Filters `webview`'s right-click menu (`ICoreWebView2_11`, runtime 1.0.1185+).
pub fn watch(webview: *c.ICoreWebView2) void {
    var eleventh: ?*c.ICoreWebView2_11 = null;
    if (!wv.ok(webview.lpVtbl.*.QueryInterface.?(webview, &c.IID_ICoreWebView2_11, @ptrCast(&eleventh)))) return;
    const view = eleventh orelse return;
    defer _ = view.lpVtbl.*.Release.?(view);
    var token: c.EventRegistrationToken = undefined;
    _ = view.lpVtbl.*.add_ContextMenuRequested.?(view, &handler, &token);
}

/// Whether the item WebView2 calls `name` stays in the menu.
pub fn keeps(name: []const u8, developer: bool) bool {
    const editing = [_][]const u8{ "cut", "copy", "paste", "selectAll" };
    for (editing) |kept| if (std.mem.eql(u8, name, kept)) return true;
    return developer and (std.mem.eql(u8, name, "inspect") or std.mem.eql(u8, name, "inspectElement"));
}

fn onRequested(
    _: [*c]c.ICoreWebView2ContextMenuRequestedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2ContextMenuRequestedEventArgs,
) callconv(.winapi) c.HRESULT {
    var raw: [*c]c.ICoreWebView2ContextMenuItemCollection = null;
    if (!wv.ok(args.*.lpVtbl.*.get_MenuItems.?(args, &raw)) or raw == null) return c.S_OK;
    const items: *c.ICoreWebView2ContextMenuItemCollection = raw;
    defer _ = items.lpVtbl.*.Release.?(items);

    // Backwards, so a removal does not move the items still to be read.
    var index = count(items);
    while (index > 0) {
        index -= 1;
        switch (kindAt(items, index)) {
            .separator => {},
            .kept => {},
            .dropped => _ = items.lpVtbl.*.RemoveValueAtIndex.?(items, index),
        }
    }
    // Separators at either end or beside another go.
    index = count(items);
    var after_separator = true;
    while (index > 0) {
        index -= 1;
        const separator = kindAt(items, index) == .separator;
        if (separator and (after_separator or index == 0)) {
            _ = items.lpVtbl.*.RemoveValueAtIndex.?(items, index);
            continue;
        }
        after_separator = separator;
    }
    if (count(items) == 0) _ = args.*.lpVtbl.*.put_Handled.?(args, c.TRUE);
    return c.S_OK;
}

fn count(items: *c.ICoreWebView2ContextMenuItemCollection) c.UINT32 {
    var value: c.UINT32 = 0;
    if (!wv.ok(items.lpVtbl.*.get_Count.?(items, &value))) return 0;
    return value;
}

const Kind = enum { separator, kept, dropped };

fn kindAt(items: *c.ICoreWebView2ContextMenuItemCollection, index: c.UINT32) Kind {
    var raw: [*c]c.ICoreWebView2ContextMenuItem = null;
    if (!wv.ok(items.lpVtbl.*.GetValueAtIndex.?(items, index, &raw)) or raw == null) return .dropped;
    const item: *c.ICoreWebView2ContextMenuItem = raw;
    defer _ = item.lpVtbl.*.Release.?(item);
    var kind: c.COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND = undefined;
    if (wv.ok(item.lpVtbl.*.get_Kind.?(item, &kind)) and kind == c.COREWEBVIEW2_CONTEXT_MENU_ITEM_KIND_SEPARATOR) return .separator;
    var wide: c.LPWSTR = null;
    if (!wv.ok(item.lpVtbl.*.get_Name.?(item, &wide))) return .dropped;
    var name: [64]u8 = undefined;
    return if (keeps(wv.takeString(wide, &name), menu.inspect)) .kept else .dropped;
}

test "the editing items stay, inspect only in a developer's build" {
    try std.testing.expect(keeps("cut", false));
    try std.testing.expect(keeps("selectAll", false));
    try std.testing.expect(!keeps("reload", true));
    try std.testing.expect(!keeps("saveAs", true));
    try std.testing.expect(!keeps("inspectElement", false));
    try std.testing.expect(keeps("inspectElement", true));
}
