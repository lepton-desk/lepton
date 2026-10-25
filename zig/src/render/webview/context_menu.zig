//! The default context menu: what a right click offers where the page did not take it
//! (`contextmenu` with `preventDefault()`), on every engine. The application turns it
//! off with `window.contextMenu: false` (`-Dcontext-menu=false`).
//!
//! Editing only, as a desktop application's own menu does: Cut, Copy, Paste and Select
//! All, each disabled where it would do nothing; a developer's build adds Inspect. No
//! Back, Forward or Reload: an application is one page, not a browser tab.
//!
//! Engine-neutral and pure: each engine shows these entries its own way and performs the
//! chosen action with its own editing commands (`context_menu_wpe.zig`, Servo's and
//! WebView2's halves).

const std = @import("std");
const builtin = @import("builtin");

/// Whether this build shows the menu: `window.contextMenu` (`-Dcontext-menu`).
pub const enabled = @import("build_options").context_menu;

/// Whether the menu offers Inspect: a developer's build (`lepton dev`, `lepton run`),
/// as the inspector itself (`features.developer_tools`).
pub const inspect = builtin.mode == std.builtin.OptimizeMode.Debug;

/// An entry's action; the number is what the menu reports back.
pub const Action = enum(u8) {
    cut = 1,
    copy = 2,
    paste = 3,
    select_all = 4,
    inspect = 5,

    pub fn fromId(number: i64) ?Action {
        return switch (number) {
            1 => .cut,
            2 => .copy,
            3 => .paste,
            4 => .select_all,
            5 => .inspect,
            else => null,
        };
    }
};

/// The words the menu shows: Turkish for a Turkish locale, English otherwise.
pub fn label(action: Action, in_turkish: bool) []const u8 {
    return switch (action) {
        .cut => if (in_turkish) "Kes" else "Cut",
        .copy => if (in_turkish) "Kopyala" else "Copy",
        .paste => if (in_turkish) "Yapıştır" else "Paste",
        .select_all => if (in_turkish) "Tümünü seç" else "Select All",
        .inspect => if (in_turkish) "İncele" else "Inspect",
    };
}

/// Whether the user's language is Turkish: the first of `LC_ALL`, `LC_MESSAGES` and
/// `LANG` that is set, as POSIX reads them for messages.
pub fn turkish() bool {
    for ([_][*:0]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" }) |name| {
        const value = std.c.getenv(name) orelse continue;
        const text = std.mem.span(value);
        if (text.len == 0) continue;
        return isTurkish(text);
    }
    return false;
}

fn isTurkish(locale: []const u8) bool {
    return std.mem.startsWith(u8, locale, "tr_") or std.mem.eql(u8, locale, "tr") or std.mem.startsWith(u8, locale, "tr.");
}

/// `shown` as `window.menu`'s list (`menu.zig`), for an engine that draws that list
/// (Servo's `menu_x11.zig`). An item's id is its action's number.
pub fn encode(shown: []const Entry, in_turkish: bool, out: []u8) ![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    try writer.writeByte(@intCast(shown.len));
    for (shown) |entry| {
        const action = entry.action orelse {
            try writer.writeInt(u16, 0, .little);
            try writer.writeByte(list.Flag.separator);
            try writer.writeInt(u16, 0, .little);
            continue;
        };
        const text = label(action, in_turkish);
        try writer.writeInt(u16, @intFromEnum(action), .little);
        try writer.writeByte(if (entry.enabled) 0 else list.Flag.disabled);
        try writer.writeInt(u16, @intCast(text.len), .little);
        try writer.writeAll(text);
    }
    return writer.buffered();
}

const list = @import("menu.zig");

/// One line of the menu: an action, or a separator (`null`).
pub const Entry = struct {
    action: ?Action,
    enabled: bool = true,
};

/// What was right-clicked.
pub const Target = struct {
    /// A field the user can type into.
    editable: bool,
    /// Text is selected there.
    selection: bool,
};

pub const max_entries = 6;

/// The menu for `target`; `developer` adds Inspect after a separator.
pub fn entries(target: Target, developer: bool, out: *[max_entries]Entry) []const Entry {
    out[0] = .{ .action = .cut, .enabled = target.editable and target.selection };
    out[1] = .{ .action = .copy, .enabled = target.selection };
    out[2] = .{ .action = .paste, .enabled = target.editable };
    out[3] = .{ .action = .select_all };
    if (!developer) return out[0..4];
    out[4] = .{ .action = null };
    out[5] = .{ .action = .inspect };
    return out[0..6];
}

test "cut needs a selection in a field, copy a selection, paste a field" {
    var buffer: [max_entries]Entry = undefined;
    const plain = entries(.{ .editable = false, .selection = false }, false, &buffer);
    try std.testing.expectEqual(@as(usize, 4), plain.len);
    try std.testing.expect(!plain[0].enabled and !plain[1].enabled and !plain[2].enabled and plain[3].enabled);

    const selected = entries(.{ .editable = false, .selection = true }, false, &buffer);
    try std.testing.expect(!selected[0].enabled and selected[1].enabled and !selected[2].enabled);

    const field = entries(.{ .editable = true, .selection = true }, false, &buffer);
    try std.testing.expect(field[0].enabled and field[1].enabled and field[2].enabled);
}

test "a developer's build adds inspect after a separator" {
    var buffer: [max_entries]Entry = undefined;
    const menu = entries(.{ .editable = false, .selection = false }, true, &buffer);
    try std.testing.expectEqual(@as(usize, 6), menu.len);
    try std.testing.expectEqual(@as(?Action, null), menu[4].action);
    try std.testing.expectEqual(@as(?Action, .inspect), menu[5].action);
}

test "every action's number reads back as itself" {
    for ([_]Action{ .cut, .copy, .paste, .select_all, .inspect }) |action| {
        try std.testing.expectEqual(@as(?Action, action), Action.fromId(@intFromEnum(action)));
    }
    try std.testing.expectEqual(@as(?Action, null), Action.fromId(0));
    try std.testing.expectEqual(@as(?Action, null), Action.fromId(6));
}

test "the list is window.menu's, ids are the actions, disabled ones marked" {
    var buffer: [max_entries]Entry = undefined;
    const shown = entries(.{ .editable = false, .selection = true }, true, &buffer);
    var bytes: [512]u8 = undefined;
    const encoded = try encode(shown, true, &bytes);
    try std.testing.expect(list.valid(encoded));
    var read = list.items(encoded);
    const cut = read.next().?;
    try std.testing.expectEqual(@as(u16, 1), cut.id);
    try std.testing.expectEqual(list.Flag.disabled, cut.flags);
    try std.testing.expectEqualStrings("Kes", cut.label);
    const copy = read.next().?;
    try std.testing.expectEqual(@as(u8, 0), copy.flags);
    _ = read.next();
    _ = read.next();
    try std.testing.expect(read.next().?.isSeparator());
    try std.testing.expectEqualStrings("İncele", read.next().?.label);
}

test "a Turkish locale is tr, tr_TR or tr.UTF-8; others are English" {
    try std.testing.expect(isTurkish("tr_TR.UTF-8"));
    try std.testing.expect(isTurkish("tr"));
    try std.testing.expect(!isTurkish("trk_XX"));
    try std.testing.expect(!isTurkish("en_US.UTF-8"));
    try std.testing.expect(!isTurkish("C"));
}
