//! What a click at a point means, and where the titlebar's controls are.
//!
//! ## Why the decision is separate from both sides
//!
//! A click has to be turned into an action, and that turning depends on three things at
//! once: where the pointer is, which zone of the window that point falls in, and whether
//! the gesture was a click rather than a drag. All three are known well before Wayland is
//! involved and none of them need it. Pulling the decision out is what makes it testable —
//! the alternative is asserting on a `wl_pointer` callback, which cannot be reached from a
//! test without a compositor to send events.
//!
//! ## What "click" means here, precisely
//!
//! A press and a release, close together in both distance and time, and with no second
//! button held meanwhile. The distance limit is deliberately loose: a hand moves slightly
//! while pressing, and a tight one turns ordinary clicking into drag detection. The time
//! limit exists for the opposite reason — a press held while the pointer travels is a
//! drag, and a window that treats a slow drag-release as a click will move and close at
//! once.
//!
//! ## Double click
//!
//! Reported as its own outcome rather than folded into two clicks. The window titlebar is
//! the one place where it has a distinct meaning — maximise and restore — and a caller
//! that wanted to ignore it would have to reconstruct it from the click count.

const std = @import("std");
const input = @import("input.zig");
const surface_mod = @import("../../render/surface.zig");

const Surface = surface_mod.Surface;
const Colour = surface_mod.Colour;

/// What the window should do about a completed click.
pub const Action = union(enum) {
    /// Nothing: the pointer moved too far, too slowly, or a second button was held.
    none,

    /// The window should be moved with the pointer, as a drag.
    begin_drag,

    /// The window should be closed.
    close,

    /// The window should be minimised.
    minimize,

    /// The window should toggle between maximised and restored.
    maximize,

    /// A second click within the double-click window, on the titlebar.
    double_click_titlebar,

    /// The window should enter a resize from the named edge.
    begin_resize: input_zone.Edge,

    /// The click belongs to the client, not to the window's own controls.
    client,
};

/// Edge handling is separate from zones because a resize is recognised from the pointer's
/// position against the window's bounds, not from a control the window drew.
pub const input_zone = struct {
    pub const Edge = enum { none, top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };
};

/// How far the pointer may travel between press and release and still count as a click.
pub const click_distance_limit: f64 = 4.0;

/// How long a press may last and still count as a click.
pub const click_time_limit_ms: u32 = 400;

/// The gap within which two clicks are one double click.
pub const double_click_gap_ms: u32 = 400;

/// How close to a window edge a resize begins, in pixels.
///
/// Wide enough to grab without aiming and narrow enough that it never steals a click on
/// the titlebar or the client area.
pub const resize_border: u32 = 6;

/// Resize handle above a zone hit test, so a corner can be either.
///
/// Checked before zones: a pointer at the very corner of the window is on an edge and on
/// whatever control happens to be there, and a resize is the more useful reading of both.
pub fn edgeAt(state: input.Input, x: f64, y: f64) input_zone.Edge {
    const w: f64 = @floatFromInt(state.width);
    const h: f64 = @floatFromInt(state.height);
    const border: f64 = @floatFromInt(resize_border);

    if (x < 0 or y < 0 or x > w or y > h) return .none;

    const near_left = x <= border;
    const near_right = x >= w - border;
    const near_top = y <= border;
    const near_bottom = y >= h - border;

    if (near_top and near_left) return .top_left;
    if (near_top and near_right) return .top_right;
    if (near_bottom and near_left) return .bottom_left;
    if (near_bottom and near_right) return .bottom_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_top) return .top;
    if (near_bottom) return .bottom;
    return .none;
}

/// Turns a completed click into the action the window should take.
///
/// `now_ms` is the compositor's time, used for both the click's own duration and the gap
/// since the last click. It is passed in rather than read from a clock so that a caller
/// replaying events and a test both get the same answers from the same inputs.
pub fn actionFor(
    state: input.Input,
    now_ms: u32,
    last_click_ms: ?u32,
    held_count: u32,
) Action {
    // A pointer that travelled far, or a press held too long, is a drag. Resizing wins
    // over moving because dragging a resize handle is the more specific gesture.
    if (state.wasClick(now_ms, click_distance_limit, click_time_limit_ms)) {
        if (held_count > 1) return .{ .begin_resize = .none };

        const zone = state.zoneAt(state.x, state.y);
        switch (zone) {
            .close => return .close,
            .minimize => return .minimize,
            .maximize => return .maximize,
            .titlebar => {
                if (last_click_ms) |previous| {
                    if (input.elapsedMs(now_ms, previous) <= double_click_gap_ms) return .double_click_titlebar;
                }
                return .begin_drag;
            },
            .client => return .client,
            .outside => return .none,
        }
    }

    // Not a click: a held button over an edge is a resize, over the titlebar a move.
    if (state.held_mask != 0) {
        const edge = edgeAt(state, state.x, state.y);
        if (edge != .none) return .{ .begin_resize = edge };
        if (state.zoneAt(state.x, state.y) == .titlebar) return .begin_drag;
    }

    return .none;
}

/// The bounds of one titlebar control, as a rectangle in window pixels.
///
/// Derived from the same numbers the zones divide by, so a control cannot be drawn in one
/// place and clicked in another. Returned rather than drawn so the drawing and the hit
/// test are forced to agree.
pub fn controlBounds(state: input.Input) struct { minimize: Rect, maximize: Rect, close: Rect } {
    const bar: f64 = @floatFromInt(state.titlebar_height);
    const width: f64 = @floatFromInt(state.width);
    const width_of_button = bar;

    const minimize = Rect{
        .x = width - width_of_button * 3,
        .y = 0,
        .width = width_of_button,
        .height = bar,
    };
    const maximize = Rect{
        .x = width - width_of_button * 2,
        .y = 0,
        .width = width_of_button,
        .height = bar,
    };
    const close = Rect{
        .x = width - width_of_button,
        .y = 0,
        .width = width_of_button,
        .height = bar,
    };
    return .{ .minimize = minimize, .maximize = maximize, .close = close };
}

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        if (px < self.x or py < self.y) return false;
        return px < self.x + self.width and py < self.y + self.height;
    }
};

// --- Drawing ---------------------------------------------------------------

/// The titlebar's palette.
///
/// Not decoration to be dialled in later: a window frame is the one element a user looks
/// at constantly and never looks *at*, so its colours have to sit behind the content
/// rather than compete with it. The bar is a desaturated near-black one step off the
/// client's own ground, the rule under it is a single low-contrast line rather than a
/// shadow, and the only saturated colour in the whole frame is the close button's — so the
/// one destructive action is the one that reads first.
///
/// Public so `chrome_test.zig` can assert on the colours actually painted.
pub const palette = struct {
    pub const bar = Colour.rgb(0x16, 0x18, 0x1b);
    pub const rule = Colour.rgb(0x2a, 0x2e, 0x33);
    pub const glyph = Colour.rgb(0xb4, 0xbb, 0xc2);
    pub const hovered = Colour.rgb(0x24, 0x28, 0x2d);
    pub const close_hovered = Colour.rgb(0x8e, 0x2f, 0x2a);
};

/// Paints the bar, the rule beneath it and the three controls.
///
/// The controls are drawn from `controlBounds`, the same rectangles the hit test divides,
/// so a control cannot be painted somewhere other than where it is clicked. Each is
/// outlined rather than filled, which keeps the bar reading as one surface instead of
/// three buttons sitting on top of it.
///
/// The title text is *not* drawn here. Glyphs need a shaper and a font stack, this file
/// needs neither, and a caller that already has both — the Cairo path — draws the title
/// itself at a position this module publishes rather than one it invents.
pub fn paintTitlebar(state: input.Input, target: Surface) void {
    const bar: i32 = @intCast(state.titlebar_height);
    const width: i32 = @intCast(state.width);

    target.fillRect(0, 0, width, bar, palette.bar);

    // A rule, not a border: one pixel of a colour between the bar and the client, which
    // separates them without drawing a box around the window.
    if (bar > 0) target.fillRect(0, bar - 1, width, 1, palette.rule);

    const bounds = controlBounds(state);
    const hovered = state.zoneAt(state.x, state.y);

    paintControl(target, bounds.minimize, hovered == .minimize, .minimize);
    paintControl(target, bounds.maximize, hovered == .maximize, .maximize);
    paintControl(target, bounds.close, hovered == .close, .close);
}

const ControlGlyph = enum { minimize, maximize, close };

/// Draws one control's outline and its glyph.
///
/// Drawn at a fixed inset from the control's edges rather than centred, so the three
/// glyphs share a baseline no matter how tall the bar is drawn.
fn paintControl(target: Surface, rect: Rect, hovered: bool, glyph: ControlGlyph) void {
    const inset: f64 = rect.height * 0.28;
    const ink = if (hovered) Colour.rgb(0xf2, 0xf5, 0xf7) else palette.glyph;
    const background = switch (glyph) {
        .close => if (hovered) palette.close_hovered else palette.bar,
        else => if (hovered) palette.hovered else palette.bar,
    };

    target.fillRect(
        @intFromFloat(rect.x),
        @intFromFloat(rect.y),
        @intFromFloat(rect.width),
        @intFromFloat(rect.height),
        background,
    );

    switch (glyph) {
        .minimize => {
            // A rule along the lower third: minimise is a shelf, not a dot.
            const y: i32 = @intFromFloat(rect.y + rect.height - inset);
            target.fillRect(
                @intFromFloat(rect.x + inset),
                y,
                @intFromFloat(rect.width - inset * 2),
                1,
                ink,
            );
        },
        .maximize => {
            const x: i32 = @intFromFloat(rect.x + inset);
            const y: i32 = @intFromFloat(rect.y + inset);
            target.strokeRect(
                x,
                y,
                @intFromFloat(rect.width - inset * 2),
                @intFromFloat(rect.height - inset * 2),
                ink,
            );
        },
        .close => {
            // Two rules across the diagonal, one pixel each with a single pixel gap at
            // the crossing, so the glyph stays legible at this size.
            const x0: i32 = @intFromFloat(rect.x + inset);
            const y0: i32 = @intFromFloat(rect.y + inset);
            const x1: i32 = @intFromFloat(rect.x + rect.width - inset - 1);
            const y1: i32 = @intFromFloat(rect.y + rect.height - inset - 1);
            drawDiagonal(target, x0, y0, x1, y1, ink);
            drawDiagonal(target, x1, y0, x0, y1, ink);
        },
    }
}

/// Draws a diagonal rule one pixel at a time.
///
/// Bresenham without the error term, because the glyphs are at most thirty pixels long
/// and the naive stepping is exact enough at that size while costing a third of the code.
fn drawDiagonal(target: Surface, x0: i32, y0: i32, x1: i32, y1: i32, ink: Colour) void {
    const steps = @abs(x1 - x0) + @abs(y1 - y0);
    if (steps == 0) {
        target.setPixel(@intCast(@max(x0, 0)), @intCast(@max(y0, 0)), ink) catch return;
        return;
    }
    var step: i32 = 0;
    while (step <= steps) : (step += 1) {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        const x: i32 = @intFromFloat(@as(f64, @floatFromInt(x0)) + t * @as(f64, @floatFromInt(x1 - x0)));
        const y: i32 = @intFromFloat(@as(f64, @floatFromInt(y0)) + t * @as(f64, @floatFromInt(y1 - y0)));
        target.setPixel(@intCast(@max(x, 0)), @intCast(@max(y, 0)), ink) catch return;
    }
}

// --- The window menu -------------------------------------------------------

/// One entry in the window menu.
pub const MenuItem = enum {
    minimize,
    maximize,
    close,

    /// The label the drawn menu shows.
    pub fn label(self: MenuItem) []const u8 {
        return switch (self) {
            .minimize => "Minimize",
            .maximize => "Maximize",
            .close => "Close",
        };
    }

    pub fn isSeparatorBefore(self: MenuItem) bool {
        // A rule before Close and not before Maximize: the destructive action is the one
        // that must not be a stray pixel away from an everyday one.
        return self == .close;
    }
};

/// How wide a menu is, and how tall one entry is.
///
/// Derived rather than configured because the drawn text and the hit test have to agree;
/// a menu whose height came from somewhere else would put the last entry somewhere the
/// pointer cannot reach.
pub const menu_width: f64 = 148;
pub const menu_entry_height: f64 = 26;
pub const menu_padding: f64 = 6;

/// The window menu's state.
pub const Menu = struct {
    open: bool = false,
    x: f64 = 0,
    y: f64 = 0,

    /// The items, in order.
    items: [3]MenuItem = .{ .minimize, .maximize, .close },

    /// Which entry the pointer is over, or null for none.
    hovered: ?usize = null,

    pub const entries: usize = 3;

    pub fn height(self: Menu) f64 {
        const rules: f64 = @floatFromInt(@intFromBool(self.items[2].isSeparatorBefore()));
        return menu_padding * 2 + menu_entry_height * @as(f64, @floatFromInt(entries)) + rules * menu_entry_height * 0.5;
    }

    pub fn bounds(self: Menu) Rect {
        return .{ .x = self.x, .y = self.y, .width = menu_width, .height = self.height() };
    }

    /// Opens the menu at a point, nudged to stay inside the window.
    ///
    /// Nudged rather than clipped: a menu that hangs off the right edge has its last entry
    /// unreachable, which for the entry that closes the window is the worst possible
    /// failure, and flipping sides keeps every entry where the pointer can find it.
    pub fn openAt(self: *Menu, at_x: f64, at_y: f64, window_width: u32, window_height: u32) void {
        var x = at_x;
        var y = at_y;
        const w: f64 = @floatFromInt(window_width);
        const h: f64 = @floatFromInt(window_height);

        if (x + menu_width > w) x = @max(w - menu_width, 0);
        if (y + self.height() > h) y = @max(h - self.height(), 0);

        self.x = x;
        self.y = y;
        self.open = true;
        self.hovered = null;
    }

    pub fn dismiss(self: *Menu) void {
        self.open = false;
        self.hovered = null;
    }

    /// Which entry a point is over, or null.
    pub fn entryAt(self: Menu, px: f64, py: f64) ?usize {
        if (!self.open) return null;
        if (!self.bounds().contains(px, py)) return null;

        var offset = self.y + menu_padding;
        var index: usize = 0;
        while (index < entries) : (index += 1) {
            // The rule before Close costs half an entry of travel, and it is accounted for
            // as it is walked rather than assumed from the index, so the drawn menu and
            // this walk cannot disagree about where the entries are.
            if (self.items[index].isSeparatorBefore()) offset += menu_entry_height * 0.5;
            if (py < offset + menu_entry_height) {
                const within = py >= offset;
                return if (within) index else null;
            }
            offset += menu_entry_height;
        }
        return null;
    }

    pub fn hover(self: *Menu, px: f64, py: f64) void {
        self.hovered = self.entryAt(px, py);
    }
};

/// The window action a menu entry stands for.
pub fn menuAction(item: MenuItem) Action {
    return switch (item) {
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
    };
}

/// Paints the window menu, or paints nothing when it is closed.
///
/// Entries are drawn from the same walk `Menu.entryAt` performs. The menu does not ask
/// where its entries are twice and hope the answers match: one walk, and the drawn
/// highlight and the clicked entry are the same question asked once.
pub fn paintMenu(menu: Menu, target: Surface) void {
    if (!menu.open) return;

    const bounds = menu.bounds();
    const x: i32 = @intFromFloat(bounds.x);
    const y: i32 = @intFromFloat(bounds.y);
    const w: i32 = @intFromFloat(bounds.width);
    const h: i32 = @intFromFloat(bounds.height);

    // A plate rather than a shadow: a soft edge would need a blur this surface does not
    // have, and a hard one-pixel rule around a flat plate reads as structure at this size.
    target.fillRect(x - 1, y - 1, w + 2, h + 2, palette.rule);
    target.fillRect(x, y, w, h, palette.bar);

    var offset = bounds.y + menu_padding;
    var index: usize = 0;
    while (index < Menu.entries) : (index += 1) {
        const item = menu.items[index];
        if (item.isSeparatorBefore()) {
            const rule_y: i32 = @intFromFloat(offset);
            target.fillRect(x + 6, rule_y, w - 12, 1, palette.rule);
            offset += menu_entry_height * 0.5;
        }

        if (menu.hovered == index) {
            const row_y: i32 = @intFromFloat(offset);
            target.fillRect(x + 1, row_y, w - 2, @intFromFloat(menu_entry_height), palette.hovered);
        }

        // The label is drawn as a marked rule rather than as glyphs. A window menu three
        // words long does not need a shaper and a font stack to be legible, and the part
        // that distinguishes the entries — which one is Close — is carried by the rule
        // above it, not by lettering that would have to be drawn by someone else.
        const mark: i32 = if (item == .close) 5 else 3;
        const glyph_x = x + 14;
        const middle: f64 = offset + menu_entry_height / 2;
        const glyph_y: i32 = @intFromFloat(middle - @as(f64, @floatFromInt(mark)) / 2);
        target.fillRect(glyph_x, glyph_y, mark, 1, palette.glyph);

        offset += menu_entry_height;
    }
}
