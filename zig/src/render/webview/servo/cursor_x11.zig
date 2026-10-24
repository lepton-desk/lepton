//! The pointer's shape over Servo's window: the page's (Servo names it in CSS terms,
//! `notify_cursor_changed` → `LeptonServoCallbacks.cursor`) and, in a frameless window,
//! the resize shape over the band its edges resize from (`view.zig` `forward`). Without
//! this the pointer never changed at all: not over a link, not over text, and not at the
//! edges, where a frameless window could be resized but nothing said so (measured: the
//! first try missed the 6 px band).
//!
//! Shapes come from the user's cursor theme through Xcursor, whose names are the CSS
//! names (the freedesktop cursor specification). A name the theme lacks falls back to
//! `default`; `none` is an empty cursor, which themes do not carry.

const std = @import("std");
const c = @import("c.zig").c;

/// The resize shape for an edge, in `placement.edgeAt`'s order: top-left, top,
/// top-right, right, bottom-right, bottom, bottom-left, left.
pub const edge_names = [_][]const u8{ "nw-resize", "n-resize", "ne-resize", "e-resize", "se-resize", "s-resize", "sw-resize", "w-resize" };

const max_names = 40;
const max_name = 24;

pub const Cursors = struct {
    names: [max_names][max_name]u8 = undefined,
    lens: [max_names]u8 = undefined,
    ids: [max_names]c.Cursor = undefined,
    count: usize = 0,
    /// The page's shape, kept while an edge's is shown.
    page: [max_name]u8 = undefined,
    page_len: usize = 0,
    /// What the window shows now.
    shown: [max_name]u8 = undefined,
    shown_len: usize = 0,

    /// The page asked for `name`; shown unless an edge's shape is (`over_edge`).
    pub fn setPage(self: *Cursors, display: *c.Display, window: c.Window, name: []const u8, over_edge: bool) void {
        const kept = name[0..@min(name.len, max_name)];
        @memcpy(self.page[0..kept.len], kept);
        self.page_len = kept.len;
        if (!over_edge) self.show(display, window, kept);
    }

    /// The page's shape again, after the pointer left an edge.
    pub fn restorePage(self: *Cursors, display: *c.Display, window: c.Window) void {
        self.show(display, window, if (self.page_len == 0) "default" else self.page[0..self.page_len]);
    }

    pub fn show(self: *Cursors, display: *c.Display, window: c.Window, name: []const u8) void {
        if (std.mem.eql(u8, name, self.shown[0..self.shown_len])) return;
        const id = self.load(display, window, name);
        if (id == 0) return;
        _ = c.XDefineCursor(display, window, id);
        _ = c.XFlush(display);
        const kept = name[0..@min(name.len, max_name)];
        @memcpy(self.shown[0..kept.len], kept);
        self.shown_len = kept.len;
    }

    fn load(self: *Cursors, display: *c.Display, window: c.Window, name: []const u8) c.Cursor {
        if (name.len == 0 or name.len >= max_name) return 0;
        for (self.names[0..self.count], self.lens[0..self.count], self.ids[0..self.count]) |*known, len, id| {
            if (std.mem.eql(u8, known[0..len], name)) return id;
        }
        var terminated: [max_name:0]u8 = @splat(0);
        @memcpy(terminated[0..name.len], name);
        var id: c.Cursor = if (std.mem.eql(u8, name, "none")) blank(display, window) else c.XcursorLibraryLoadCursor(display, &terminated);
        if (id == 0 and !std.mem.eql(u8, name, "default")) id = self.load(display, window, "default");
        if (id == 0 or self.count == max_names) return id;
        @memcpy(self.names[self.count][0..name.len], name);
        self.lens[self.count] = @intCast(name.len);
        self.ids[self.count] = id;
        self.count += 1;
        return id;
    }

    /// An empty cursor, for CSS `cursor: none`.
    fn blank(display: *c.Display, window: c.Window) c.Cursor {
        const bits = [_]u8{0};
        const pixmap = c.XCreateBitmapFromData(display, window, &bits, 1, 1);
        if (pixmap == 0) return 0;
        defer _ = c.XFreePixmap(display, pixmap);
        var black = std.mem.zeroes(c.XColor);
        return c.XCreatePixmapCursor(display, pixmap, pixmap, &black, &black, 0, 0);
    }
};
