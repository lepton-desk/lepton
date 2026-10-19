//! What a page may ask the engine for — notifications, camera, microphone, location, … —
//! decided by `lepton.config.json`'s `webPermissions` (user's decision, 2026-10-16):
//! `allow`, `deny`, or `ask`, which hands the request to the page as a
//! `permission.request` event (`u32` id, then the kinds, comma-separated) for the
//! application to ask in its own interface and answer with `permission.respond`. A kind
//! not listed is denied; a request nobody answers is denied after a minute.
//!
//! Measured before: with no handler WebKit denied every request without asking anyone
//! (`Notification.requestPermission()` → `denied`, geolocation "User denied").

const std = @import("std");
const build_options = @import("build_options");
const events = @import("events.zig");
const Bridge = @import("bridge.zig").Bridge;

/// The kinds, by the names `webPermissions` uses (the CLI's `WEB_PERMISSION_KINDS`).
pub const Kind = enum(u4) {
    notifications,
    camera,
    microphone,
    geolocation,
    @"pointer-lock",
    @"device-info",
    @"media-keys",
    @"storage-access",
    xr,
};

pub const Policy = enum(u2) { deny, allow, ask };

pub const Policies = struct {
    of: [std.enums.values(Kind).len]Policy = @splat(.deny),

    /// `kind=policy,…`, as `-Dweb-permissions` carries it. A name it does not know is
    /// skipped: the CLI already refused it.
    pub fn parse(text: []const u8) Policies {
        var policies: Policies = .{};
        var pairs = std.mem.splitScalar(u8, text, ',');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const kind = std.meta.stringToEnum(Kind, pair[0..equals]) orelse continue;
            const policy = std.meta.stringToEnum(Policy, pair[equals + 1 ..]) orelse continue;
            policies.of[@intFromEnum(kind)] = policy;
        }
        return policies;
    }

    /// The policy for a request of several kinds (camera and microphone together): the
    /// strictest — any `deny` denies, else any `ask` asks.
    pub fn forAll(self: Policies, kinds: []const Kind) Policy {
        var result: Policy = .allow;
        for (kinds) |kind| {
            switch (self.of[@intFromEnum(kind)]) {
                .deny => return .deny,
                .ask => result = .ask,
                .allow => {},
            }
        }
        return result;
    }
};

/// `navigator.permissions.query({ name })` names → kinds.
pub fn kindOfQuery(name: []const u8) ?Kind {
    if (std.mem.eql(u8, name, "notifications")) return .notifications;
    if (std.mem.eql(u8, name, "geolocation")) return .geolocation;
    if (std.mem.eql(u8, name, "camera")) return .camera;
    if (std.mem.eql(u8, name, "microphone")) return .microphone;
    if (std.mem.eql(u8, name, "storage-access")) return .@"storage-access";
    return null;
}

/// `permission.request`'s payload: the id, then the kinds' names.
pub fn requestPayload(id: u32, kinds: []const Kind, out: *[events.max_data]u8) []const u8 {
    std.mem.writeInt(u32, out[0..4], id, .little);
    var used: usize = 4;
    for (kinds, 0..) |kind, index| {
        const name = @tagName(kind);
        if (index != 0) {
            out[used] = ',';
            used += 1;
        }
        @memcpy(out[used..][0..name.len], name);
        used += name.len;
    }
    return out[0..used];
}

pub const request_event = events.permission_request;

// ── The engine side ─────────────────────────────────────────────────────────────

const e_signal_connect = @extern(
    *const fn (?*anyopaque, [*:0]const u8, ?*const anyopaque, ?*anyopaque, ?*const anyopaque, c_int) callconv(.c) c_ulong,
    .{ .name = "g_signal_connect_data" },
);
const e_is_a = @extern(*const fn (?*anyopaque, usize) callconv(.c) c_int, .{ .name = "g_type_check_instance_is_a" });
const e_ref = @extern(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "g_object_ref" });
const e_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_object_unref" });
const e_allow = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_permission_request_allow" });
const e_deny = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "webkit_permission_request_deny" });
const e_for_audio = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_user_media_permission_is_for_audio_device" });
const e_for_video = @extern(*const fn (?*anyopaque) callconv(.c) c_int, .{ .name = "webkit_user_media_permission_is_for_video_device" });
const e_query_name = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_permission_state_query_get_name" });
const e_query_finish = @extern(*const fn (?*anyopaque, c_int) callconv(.c) void, .{ .name = "webkit_permission_state_query_finish" });
const e_notification_title = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_notification_get_title" });
const e_notification_body = @extern(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, .{ .name = "webkit_notification_get_body" });
const e_timeout_add = @extern(*const fn (c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_uint, .{ .name = "g_timeout_add" });

const t = struct {
    const notification = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_notification_permission_request_get_type" });
    const user_media = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_user_media_permission_request_get_type" });
    const geolocation = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_geolocation_permission_request_get_type" });
    const pointer_lock = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_pointer_lock_permission_request_get_type" });
    const device_info = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_device_info_permission_request_get_type" });
    const media_keys = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_media_key_system_permission_request_get_type" });
    const storage_access = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_website_data_access_permission_request_get_type" });
    const xr = @extern(*const fn () callconv(.c) usize, .{ .name = "webkit_xr_permission_request_get_type" });
};

// `WebKitPermissionState`: GRANTED, DENIED, PROMPT.
const state_granted: c_int = 0;
const state_denied: c_int = 1;
const state_prompt: c_int = 2;

/// How long an asked request waits for the page's answer before it is denied.
const answer_within_ms: c_uint = 60_000;

var current: Policies = .{};
/// Who the desktop's notifications come from: the product's name, and the desktop
/// entry's id (the identifier) for its icon.
var app_name: [*:0]const u8 = "";
var desktop_entry: [*:0]const u8 = "";

/// The application notifications name (`main.zig`).
pub fn setApplication(identifier: [*:0]const u8, product: [*:0]const u8) void {
    desktop_entry = identifier;
    app_name = product;
}
var bridge: ?*Bridge = null;

/// One request the page was asked about. A static table: its address is timeout data.
const Asked = struct {
    request: ?*anyopaque = null,
    id: u32 = 0,
};
var asked: [8]Asked = @splat(.{});
var next_id: u32 = 1;

/// The application's `webPermissions` (`build_options.web_permissions` in `main.zig`).
pub fn setPolicies(text: []const u8) void {
    current = Policies.parse(text);
}

/// The policy for a request of `kinds`: an empty list (a kind this core does not know)
/// is denied, like an unlisted one. Shared with WebView2 (`webview2/permissions.zig`).
pub fn policyFor(kinds: []const Kind) Policy {
    return if (kinds.len == 0) .deny else current.forAll(kinds);
}

/// `ask`'s next id, never 0 (a timer carries it as its data pointer).
pub fn nextId() u32 {
    const id = next_id;
    next_id = if (next_id == std.math.maxInt(u32)) 1 else next_id + 1;
    return id;
}

/// Answers this view's permission requests and queries; `ask`s go through `owner`.
pub fn watch(web_view: *anyopaque, owner: *Bridge) void {
    bridge = owner;
    watchView(web_view);
}

/// A further view of the same application (`window.open`): the same policy and bridge.
pub fn watchView(web_view: *anyopaque) void {
    _ = e_signal_connect(web_view, "permission-request", @ptrCast(&onRequest), null, null, 0);
    _ = e_signal_connect(web_view, "query-permission-state", @ptrCast(&onQuery), null, null, 0);
    _ = e_signal_connect(web_view, "show-notification", @ptrCast(&onNotification), null, null, 0);
}

fn kindsOf(request: ?*anyopaque, out: *[2]Kind) []const Kind {
    const is = struct {
        fn a(instance: ?*anyopaque, get_type: *const fn () callconv(.c) usize) bool {
            return e_is_a(instance, get_type()) != 0;
        }
    };
    if (is.a(request, t.user_media)) {
        var count: usize = 0;
        if (e_for_video(request) != 0) {
            out[count] = .camera;
            count += 1;
        }
        if (e_for_audio(request) != 0) {
            out[count] = .microphone;
            count += 1;
        }
        return out[0..count];
    }
    const single: ?Kind = if (is.a(request, t.notification)) .notifications else if (is.a(request, t.geolocation)) .geolocation else if (is.a(request, t.pointer_lock)) .@"pointer-lock" else if (is.a(request, t.device_info)) .@"device-info" else if (is.a(request, t.media_keys)) .@"media-keys" else if (is.a(request, t.storage_access)) .@"storage-access" else if (is.a(request, t.xr)) .xr else null;
    out[0] = single orelse return out[0..0];
    return out[0..1];
}

fn onRequest(_: ?*anyopaque, request: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    var buffer: [2]Kind = undefined;
    const kinds = kindsOf(request, &buffer);
    // A kind this core does not know, or a screen capture: denied, like an unlisted one.
    const policy = if (kinds.len == 0) Policy.deny else current.forAll(kinds);
    switch (policy) {
        .allow => e_allow(request),
        .deny => e_deny(request),
        .ask => ask(request, kinds),
    }
    return 1;
}

fn ask(request: ?*anyopaque, kinds: []const Kind) void {
    const owner = bridge orelse return e_deny(request);
    const slot = for (&asked) |*entry| {
        if (entry.request == null) break entry;
    } else return e_deny(request); // Eight unanswered already.
    slot.* = .{ .request = e_ref(request), .id = next_id };
    // Never 0: the timer carries the id as its data pointer, and null means nothing.
    next_id = if (next_id == std.math.maxInt(u32)) 1 else next_id + 1;
    var payload: [events.max_data]u8 = undefined;
    _ = owner.emit(request_event, requestPayload(slot.id, kinds, &payload)) catch {
        settle(slot, false);
        return;
    };
    _ = e_timeout_add(answer_within_ms, &onUnanswered, @ptrFromInt(@as(usize, slot.id)));
}

fn settle(slot: *Asked, allow: bool) void {
    const request = slot.request orelse return;
    if (allow) e_allow(request) else e_deny(request);
    e_unref(request);
    slot.* = .{};
}

/// The minute is up: denied, if that id is still waiting. By id rather than by slot, so
/// a request answered in time, whose slot now holds another, is left alone.
fn onUnanswered(data: ?*anyopaque) callconv(.c) c_int {
    const id: u32 = @intCast(@intFromPtr(data) & std.math.maxInt(u32));
    _ = answer(id, false);
    return 0;
}

/// `permission.respond`: the page's answer to request `id`. False for an id that is not
/// waiting (answered, timed out, or never asked).
pub fn answer(id: u32, allow: bool) bool {
    for (&asked) |*slot| {
        if (slot.request != null and slot.id == id) {
            settle(slot, allow);
            return true;
        }
    }
    return false;
}

/// A page's `new Notification(…)`, which WebKit only raises once `notifications` was
/// allowed: shown by the desktop. (Clicking it does not reach the page yet.)
fn onNotification(_: ?*anyopaque, notification: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const title = e_notification_title(notification) orelse "";
    const body = e_notification_body(notification) orelse "";
    return @intFromBool(@import("../../platform/linux/portal.zig").notify(app_name, desktop_entry, title, body));
}

fn onQuery(_: ?*anyopaque, query: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    const name = std.mem.span(e_query_name(query) orelse return 0);
    const kind = kindOfQuery(name) orelse return 0;
    e_query_finish(query, switch (current.of[@intFromEnum(kind)]) {
        .allow => state_granted,
        .deny => state_denied,
        .ask => state_prompt,
    });
    return 1;
}

test "policies parse from the build option, unknown names skipped" {
    const parsed = Policies.parse("notifications=ask,camera=allow,usb=allow,microphone=maybe");
    try std.testing.expectEqual(Policy.ask, parsed.of[@intFromEnum(Kind.notifications)]);
    try std.testing.expectEqual(Policy.allow, parsed.of[@intFromEnum(Kind.camera)]);
    try std.testing.expectEqual(Policy.deny, parsed.of[@intFromEnum(Kind.microphone)]);
    try std.testing.expectEqual(Policy.deny, parsed.of[@intFromEnum(Kind.geolocation)]);
    try std.testing.expectEqual(Policy.deny, Policies.parse("").of[0]);
}

test "a request of several kinds gets the strictest policy" {
    const parsed = Policies.parse("camera=allow,microphone=ask");
    try std.testing.expectEqual(Policy.ask, parsed.forAll(&.{ .camera, .microphone }));
    try std.testing.expectEqual(Policy.allow, parsed.forAll(&.{.camera}));
    const strict = Policies.parse("camera=ask,microphone=deny");
    try std.testing.expectEqual(Policy.deny, strict.forAll(&.{ .camera, .microphone }));
}

test "the page is told the id and the kinds" {
    var out: [events.max_data]u8 = undefined;
    const payload = requestPayload(3, &.{ .camera, .microphone }, &out);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, payload[0..4], .little));
    try std.testing.expectEqualStrings("camera,microphone", payload[4..]);
    try std.testing.expectEqual(Kind.@"storage-access", kindOfQuery("storage-access").?);
    try std.testing.expect(kindOfQuery("midi") == null);
}

test "the permission callbacks are compiled" {
    if (comptime !(build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render)) return error.SkipZigTest;
    _ = &watch;
    _ = &answer;
    _ = &onUnanswered;
}
