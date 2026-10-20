//! File dialogs through xdg-desktop-portal (`org.freedesktop.portal.FileChooser`), for
//! `@lepton-desk/plugin-dialog`.
//!
//! No toolkit: the desktop draws its own dialog (COSMIC, GNOME, KDE each ship a portal
//! backend), so the dialog looks like the desktop's, works the same under Wayland and X11,
//! and needs nothing linked beyond GIO, which WPE already brings. The protocol is
//! asynchronous: `OpenFile`/`SaveFile` return a request object at once, and the answer
//! arrives later as that object's `Response(u response, a{sv} results)` signal — after the
//! user chose, which may be minutes. So the page's `invoke` is held open
//! (`invoke.takeLater`) and finished from the signal.
//!
//! The signal is subscribed before the call, at the path the portal will use
//! (`/org/freedesktop/portal/desktop/request/<sender>/<handle_token>`, FileChooser ≥ 2):
//! subscribing after the reply could miss a response that came first.
//!
//! Gated like the clipboard: without the 2.54 platform ABI nothing here is analysed and
//! [`choose`] answers `failed`.

const std = @import("std");
const build_options = @import("build_options");
const invoke = @import("../../render/webview/invoke.zig");

pub const available = build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render;

pub const Mode = enum(u8) { open = 0, save = 1 };

pub const Filter = struct {
    name: []const u8,
    /// Glob patterns: `*.txt`.
    patterns: []const []const u8,
};

pub const Options = struct {
    mode: Mode = .open,
    title: []const u8 = "",
    /// The button's label; empty for the desktop's own.
    accept_label: []const u8 = "",
    multiple: bool = false,
    directory: bool = false,
    /// Save: the proposed file name.
    current_name: []const u8 = "",
    /// The folder the dialog starts in, absolute; empty for the desktop's choice.
    current_folder: []const u8 = "",
    filters: []const Filter = &.{},
    /// An application identifier: what the user picks is granted to it and remembered
    /// (`grants.zig`) — set only when the application opted in (`fs` `chosen`).
    grant_to: []const u8 = "",
};

/// The first byte of the reply; then the chosen paths, each ended by a NUL.
pub const Outcome = enum(u8) { chosen = 0, cancelled = 1, failed = 2 };

const GVariant = anyopaque;
const SignalCallback = *const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*GVariant, ?*anyopaque) callconv(.c) void;
const ReadyCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

const g = struct {
    const bus_get_sync = @extern(*const fn (c_int, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "g_bus_get_sync" });
    const unique_name = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "g_dbus_connection_get_unique_name" });
    const subscribe = @extern(*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, c_int, SignalCallback, ?*anyopaque, ?*anyopaque) callconv(.c) c_uint, .{ .name = "g_dbus_connection_signal_subscribe" });
    const unsubscribe = @extern(*const fn (?*anyopaque, c_uint) callconv(.c) void, .{ .name = "g_dbus_connection_signal_unsubscribe" });
    const call = @extern(*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*GVariant, ?[*:0]const u8, c_int, c_int, ?*anyopaque, ReadyCallback, ?*anyopaque) callconv(.c) void, .{ .name = "g_dbus_connection_call" });
    const call_sync = @extern(*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*GVariant, ?[*:0]const u8, c_int, c_int, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*GVariant, .{ .name = "g_dbus_connection_call_sync" });
    const call_finish = @extern(*const fn (?*anyopaque, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*GVariant, .{ .name = "g_dbus_connection_call_finish" });
    const new_string = @extern(*const fn ([*:0]const u8) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_string" });
    const new_boolean = @extern(*const fn (c_int) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_boolean" });
    const new_uint32 = @extern(*const fn (u32) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_uint32" });
    const new_bytestring = @extern(*const fn ([*:0]const u8) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_bytestring" });
    const new_variant = @extern(*const fn (?*GVariant) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_variant" });
    const new_dict_entry = @extern(*const fn (?*GVariant, ?*GVariant) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_dict_entry" });
    const new_array = @extern(*const fn (?[*:0]const u8, [*]const ?*GVariant, usize) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_array" });
    const new_tuple = @extern(*const fn ([*]const ?*GVariant, usize) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_tuple" });
    const child = @extern(*const fn (?*GVariant, usize) callconv(.c) ?*GVariant, .{ .name = "g_variant_get_child_value" });
    const get_uint32 = @extern(*const fn (?*GVariant) callconv(.c) u32, .{ .name = "g_variant_get_uint32" });
    const get_string = @extern(*const fn (?*GVariant, ?*usize) callconv(.c) [*:0]const u8, .{ .name = "g_variant_get_string" });
    const lookup = @extern(*const fn (?*GVariant, [*:0]const u8, ?[*:0]const u8) callconv(.c) ?*GVariant, .{ .name = "g_variant_lookup_value" });
    const strv = @extern(*const fn (?*GVariant, ?*usize) callconv(.c) ?[*]?[*:0]const u8, .{ .name = "g_variant_get_strv" });
    const unref = @extern(*const fn (?*GVariant) callconv(.c) void, .{ .name = "g_variant_unref" });
    const new_int32 = @extern(*const fn (i32) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_int32" });
    const filename_from_uri = @extern(*const fn ([*:0]const u8, ?*?[*:0]u8, ?*?*anyopaque) callconv(.c) ?[*:0]u8, .{ .name = "g_filename_from_uri" });
    const free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_free" });
    const error_free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_error_free" });
};

const bus_session: c_int = 2; // G_BUS_TYPE_SESSION
const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";

/// One dialog the user has not answered yet. Lives in a static table: GLib keeps its
/// address as the callbacks' user data, so it must not move.
const Pending = struct {
    later: ?invoke.Later = null,
    subscription: c_uint = 0,
    /// The request object, for `Request.Close` when the application ends first.
    path: [256]u8 = undefined,
    path_len: usize = 0,
    grant_to: [256]u8 = undefined,
    grant_to_len: usize = 0,
    /// Folders were asked for: what comes back is granted as folders.
    directories: bool = false,
};

var pending: [8]Pending = @splat(.{});
var connection: ?*anyopaque = null;
var tokens: u32 = 0;

/// Opens the desktop's file dialog and answers `later` when the user is done: `ok` with
/// an [`Outcome`] byte and the chosen paths. Answers at once with `failed` when the
/// portal cannot be asked.
pub fn choose(options: Options, later: invoke.Later) void {
    if (comptime !available) return later.finish(.failed, &.{});
    start(options, later) catch later.finish(.failed, &.{});
}

fn start(options: Options, later: invoke.Later) error{Unavailable}!void {
    const bus = connection orelse blk: {
        var failure: ?*anyopaque = null;
        const opened = g.bus_get_sync(bus_session, null, &failure) orelse {
            if (failure) |owned| g.error_free(owned);
            return error.Unavailable;
        };
        connection = opened;
        break :blk opened;
    };
    const slot = for (&pending) |*candidate| {
        if (candidate.later == null) break candidate;
    } else return error.Unavailable;

    tokens +%= 1;
    var token_buffer: [32]u8 = undefined;
    const token = std.fmt.bufPrintZ(&token_buffer, "lepton{d}", .{tokens}) catch return error.Unavailable;
    var path_buffer: [256]u8 = undefined;
    const sender = std.mem.span(g.unique_name(bus) orelse return error.Unavailable);
    const request_path = requestPath(&path_buffer, sender, token) catch return error.Unavailable;

    slot.later = later;
    @memcpy(slot.path[0 .. request_path.len + 1], request_path.ptr[0 .. request_path.len + 1]);
    slot.path_len = request_path.len;
    const grant_len = @min(options.grant_to.len, slot.grant_to.len);
    @memcpy(slot.grant_to[0..grant_len], options.grant_to[0..grant_len]);
    slot.grant_to_len = grant_len;
    // A save dialog chooses a file, whatever `directory` the page passed: recorded as a
    // folder, it granted everything beside the saved file (audit, 2026-10-20).
    slot.directories = options.directory and options.mode == .open;
    slot.subscription = g.subscribe(bus, portal_name, "org.freedesktop.portal.Request", "Response", request_path.ptr, null, 0, &onResponse, slot, null);

    var z: Strings = .{};
    const parameters = buildParameters(options, token, &z) orelse {
        g.unsubscribe(bus, slot.subscription);
        slot.* = .{};
        return error.Unavailable;
    };
    const method: [*:0]const u8 = if (options.mode == .save) "SaveFile" else "OpenFile";
    g.call(bus, portal_name, portal_path, "org.freedesktop.portal.FileChooser", method, parameters, "(o)", 0, -1, null, &onCalled, slot);
}

/// Closes every dialog still open. The portal does not do it when the application goes
/// away — measured on COSMIC: a dialog outlived its killed application and stayed on
/// screen with nobody to answer — so the view calls this as it closes.
/// Opens `uri` in the desktop's handler for it (the browser, the mail client) through
/// the `OpenURI` portal. Not `g_app_info_launch_default_for_uri`: that starts the browser
/// as this process's child with this process's stdout and stderr, and a browser that
/// stays open then holds `lepton run`'s pipes — measured: Helium's helper `cat`s kept
/// them, `lepton run` never saw the application end, the application stayed a zombie and
/// its channel read as held. The portal starts it outside this process.
pub fn openUri(uri: [*:0]const u8) bool {
    if (comptime !available) return false;
    const bus = connection orelse blk: {
        var failure: ?*anyopaque = null;
        const opened = g.bus_get_sync(bus_session, null, &failure) orelse {
            if (failure) |owned| g.error_free(owned);
            return false;
        };
        connection = opened;
        break :blk opened;
    };
    const no_options = [_]?*GVariant{};
    const arguments = [_]?*GVariant{
        g.new_string(""),
        g.new_string(uri),
        g.new_array("{sv}", &no_options, 0),
    };
    // Asynchronous: the answer is only a request handle, and the portal reports a failure
    // to the user itself.
    g.call(bus, portal_name, portal_path, "org.freedesktop.portal.OpenURI", "OpenURI", g.new_tuple(&arguments, arguments.len), null, 0, -1, null, &openUriDone, null);
    return true;
}

fn openUriDone(source: ?*anyopaque, result: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    var failure: ?*anyopaque = null;
    if (g.call_finish(source, result, &failure)) |reply| g.unref(reply);
    if (failure) |owned| g.error_free(owned);
}

/// Shows a desktop notification (`org.freedesktop.Notifications.Notify`, the
/// notification server every Linux desktop runs). `desktop_entry` lets the desktop show
/// the application's own name and icon.
pub fn notify(app_name: [*:0]const u8, desktop_entry: [*:0]const u8, summary: [*:0]const u8, body: [*:0]const u8) bool {
    if (comptime !available) return false;
    const bus = connection orelse blk: {
        var failure: ?*anyopaque = null;
        const opened = g.bus_get_sync(bus_session, null, &failure) orelse {
            if (failure) |owned| g.error_free(owned);
            return false;
        };
        connection = opened;
        break :blk opened;
    };
    const no_actions = [_]?*GVariant{};
    const hints = [_]?*GVariant{g.new_dict_entry(g.new_string("desktop-entry"), g.new_variant(g.new_string(desktop_entry)))};
    const arguments = [_]?*GVariant{
        g.new_string(app_name),
        g.new_uint32(0),
        g.new_string(""),
        g.new_string(summary),
        g.new_string(body),
        g.new_array("s", &no_actions, 0),
        g.new_array("{sv}", &hints, hints.len),
        g.new_int32(-1),
    };
    g.call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", g.new_tuple(&arguments, arguments.len), null, 0, -1, null, &openUriDone, null);
    return true;
}

pub fn closeAll() void {
    if (comptime !available) return;
    const bus = connection orelse return;
    for (&pending) |*slot| {
        if (slot.later == null) continue;
        g.unsubscribe(bus, slot.subscription);
        var failure: ?*anyopaque = null;
        const path: [*:0]const u8 = @ptrCast(&slot.path);
        if (g.call_sync(bus, portal_name, path, "org.freedesktop.portal.Request", "Close", null, null, 0, 1000, null, &failure)) |reply| g.unref(reply);
        if (failure) |owned| g.error_free(owned);
        slot.* = .{};
    }
}

/// `/org/freedesktop/portal/desktop/request/<sender without ':' and with '.' as '_'>/<token>`.
pub fn requestPath(out: []u8, sender: []const u8, token: []const u8) error{NoSpaceLeft}![:0]const u8 {
    const prefix = "/org/freedesktop/portal/desktop/request/";
    const name = if (sender.len > 0 and sender[0] == ':') sender[1..] else sender;
    if (prefix.len + name.len + 1 + token.len + 1 > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..prefix.len], prefix);
    for (name, 0..) |ch, index| out[prefix.len + index] = if (ch == '.') '_' else ch;
    var at = prefix.len + name.len;
    out[at] = '/';
    at += 1;
    @memcpy(out[at..][0..token.len], token);
    at += token.len;
    out[at] = 0;
    return out[0..at :0];
}

/// NUL-terminated copies of the option strings, alive until the call has built its
/// message (GLib copies them into the GVariant).
const Strings = struct {
    buffer: [8192]u8 = undefined,
    used: usize = 0,

    fn z(self: *Strings, text: []const u8) ?[*:0]const u8 {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
        if (self.used + text.len + 1 > self.buffer.len) return null;
        const begin = self.used;
        @memcpy(self.buffer[begin..][0..text.len], text);
        self.buffer[begin + text.len] = 0;
        self.used += text.len + 1;
        return self.buffer[begin .. begin + text.len :0].ptr;
    }
};

fn entry(key: [*:0]const u8, value: ?*GVariant) ?*GVariant {
    return g.new_dict_entry(g.new_string(key), g.new_variant(value));
}

/// `(sa(us))`: a filter's name and its glob patterns (type 0).
fn buildFilter(filter: Filter, strings: *Strings) ?*GVariant {
    var patterns: [16]?*GVariant = undefined;
    if (filter.patterns.len > patterns.len or filter.patterns.len == 0) return null;
    for (filter.patterns, 0..) |pattern, at| {
        const pair = [_]?*GVariant{ g.new_uint32(0), g.new_string(strings.z(pattern) orelse return null) };
        patterns[at] = g.new_tuple(&pair, 2);
    }
    const named = [_]?*GVariant{
        g.new_string(strings.z(filter.name) orelse return null),
        g.new_array("(us)", &patterns, filter.patterns.len),
    };
    return g.new_tuple(&named, 2);
}

/// `(ssa{sv})`: parent window, title, options.
fn buildParameters(options: Options, token: [:0]const u8, strings: *Strings) ?*GVariant {
    var items: [16]?*GVariant = undefined;
    var count: usize = 0;
    items[count] = entry("handle_token", g.new_string(token.ptr));
    count += 1;
    items[count] = entry("modal", g.new_boolean(1));
    count += 1;
    if (options.accept_label.len > 0) {
        items[count] = entry("accept_label", g.new_string(strings.z(options.accept_label) orelse return null));
        count += 1;
    }
    if (options.mode == .open) {
        items[count] = entry("multiple", g.new_boolean(@intFromBool(options.multiple)));
        count += 1;
        items[count] = entry("directory", g.new_boolean(@intFromBool(options.directory)));
        count += 1;
    } else if (options.current_name.len > 0) {
        items[count] = entry("current_name", g.new_string(strings.z(options.current_name) orelse return null));
        count += 1;
    }
    if (options.current_folder.len > 0) {
        // `ay`, NUL-terminated, as the portal documents.
        items[count] = entry("current_folder", g.new_bytestring(strings.z(options.current_folder) orelse return null));
        count += 1;
    }
    if (options.filters.len > 0) {
        var filters: [16]?*GVariant = undefined;
        if (options.filters.len > filters.len) return null;
        for (options.filters, 0..) |filter, index| {
            filters[index] = buildFilter(filter, strings) orelse return null;
        }
        items[count] = entry("filters", g.new_array("(sa(us))", &filters, options.filters.len));
        count += 1;
        // The list alone is only what the user may switch to: COSMIC opened unfiltered,
        // showing every file, until `current_filter` named the one in force — which is
        // what GTK sends too (measured with dbus-monitor).
        items[count] = entry("current_filter", buildFilter(options.filters[0], strings) orelse return null);
        count += 1;
    }
    const fields = [_]?*GVariant{
        g.new_string(""), // parent window: none (an xdg-foreign handle would make it modal to ours)
        g.new_string(strings.z(options.title) orelse return null),
        g.new_array("{sv}", &items, count),
    };
    return g.new_tuple(&fields, 3);
}

/// The method call's own reply: only failure matters — success is the request path,
/// whose `Response` is already subscribed.
fn onCalled(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const slot: *Pending = @ptrCast(@alignCast(data orelse return));
    var failure: ?*anyopaque = null;
    if (g.call_finish(source, result, &failure)) |reply| {
        g.unref(reply);
        return;
    }
    if (failure) |owned| g.error_free(owned);
    settle(slot, .failed, null);
}

/// `Response(u response, a{sv} results)`: 0 chosen, 1 cancelled, 2 ended otherwise.
fn onResponse(_: ?*anyopaque, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, parameters: ?*GVariant, data: ?*anyopaque) callconv(.c) void {
    const slot: *Pending = @ptrCast(@alignCast(data orelse return));
    const code_value = g.child(parameters, 0);
    const code = g.get_uint32(code_value);
    g.unref(code_value);
    const outcome: Outcome = switch (code) {
        0 => .chosen,
        1 => .cancelled,
        else => .failed,
    };
    const results = g.child(parameters, 1);
    defer g.unref(results);
    settle(slot, outcome, if (outcome == .chosen) results else null);
}

fn settle(slot: *Pending, outcome: Outcome, results: ?*GVariant) void {
    const later = slot.later orelse return;
    if (connection) |bus| g.unsubscribe(bus, slot.subscription);
    const grant_to_buffer = slot.grant_to;
    const grant_to = grant_to_buffer[0..slot.grant_to_len];
    const kind: @import("../grants.zig").Kind = if (slot.directories) .directory else .file;
    slot.* = .{};

    var reply: [invoke.max_reply - 64]u8 = undefined;
    reply[0] = @intFromEnum(outcome);
    var len: usize = 1;
    if (results) |dict| {
        if (g.lookup(dict, "uris", "as")) |uris| {
            defer g.unref(uris);
            var count: usize = 0;
            const list = g.strv(uris, &count);
            defer g.free(@ptrCast(list));
            if (list) |items| for (items[0..count]) |maybe| {
                const uri = maybe orelse continue;
                const path = g.filename_from_uri(uri, null, null) orelse continue;
                defer g.free(path);
                const bytes = std.mem.span(path);
                // The user chose it in the desktop's own dialog: granted now, before the page
                // hears of it, so its first read of the path already succeeds.
                if (grant_to.len != 0) @import("../grants.zig").add(grant_to, kind, bytes);
                if (len + bytes.len + 1 > reply.len) return later.finish(.too_large, &.{});
                @memcpy(reply[len..][0..bytes.len], bytes);
                reply[len + bytes.len] = 0;
                len += bytes.len + 1;
            };
        }
    }
    later.finish(.ok, reply[0..len]);
}

test "the request path is the portal's, from the sender's unique name" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_234/lepton7",
        try requestPath(&out, ":1.234", "lepton7"),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, requestPath(&tiny, ":1.234", "lepton7"));
}

test "the dialog path is compiled in this build" {
    _ = &choose;
    if (comptime !available) return;
    _ = &start;
    _ = &onResponse;
    _ = &onCalled;
    _ = &closeAll;
}
