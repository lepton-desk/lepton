//! `webPermissions` on WebView2: the same policy as on Linux (`../permissions.zig`), applied
//! to `PermissionRequested`.
//!
//! WebView2's own answer to a request left at `DEFAULT` is a browser prompt, so every
//! request is settled here: `allow`, `deny`, or `ask` — a deferral held until the page
//! answers `permission.request` with `permission.respond`, denied after a minute. The
//! decision is not saved in the profile (`SavesInProfile` false): WebView2 would otherwise
//! answer the next request itself and an edit to `lepton.config.json` would change nothing.
//! What the page reads before asking is written into the profile at start (`stateFor`).
//!
//! Kinds Linux has no name for (sensors, clipboard read, MIDI, fonts, window management…)
//! are denied, as an unlisted kind is.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const policy = @import("../permissions.zig");
const request = @import("request.zig");
const Bridge = @import("../bridge.zig").Bridge;

const answer_within_ms = 60_000;

/// The Linux name of a WebView2 kind, or null for one Lepton does not grant.
pub fn kindOf(kind: c.COREWEBVIEW2_PERMISSION_KIND) ?policy.Kind {
    return switch (kind) {
        c.COREWEBVIEW2_PERMISSION_KIND_MICROPHONE => .microphone,
        c.COREWEBVIEW2_PERMISSION_KIND_CAMERA => .camera,
        c.COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION => .geolocation,
        c.COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS => .notifications,
        else => null,
    };
}

const Asked = struct {
    args: ?*c.ICoreWebView2PermissionRequestedEventArgs = null,
    deferral: ?*c.ICoreWebView2Deferral = null,
    id: u32 = 0,
};
var asked: [8]Asked = @splat(.{});
var bridge: ?*Bridge = null;

pub fn watch(webview: *c.ICoreWebView2, owner: *Bridge, handler: *c.ICoreWebView2PermissionRequestedEventHandler) void {
    bridge = owner;
    var token: c.EventRegistrationToken = undefined;
    _ = webview.lpVtbl.*.add_PermissionRequested.?(webview, handler, &token);
    stateFor(webview, transport_origin);
    if (owner.devOrigin().len > 0) stateFor(webview, owner.devOrigin());
}

const transport_origin = @import("../transport.zig").core_origin;

/// What the page sees before it asks: `PermissionRequested` settles a request, but
/// `Notification.permission` and `navigator.permissions.query` read the profile, which
/// knew nothing of `webPermissions` — with notifications on `allow` the page read
/// `default` / `prompt`, and a `new Notification` before `requestPermission` failed
/// (measured). Each kind WebView2 shares with Linux is written for the page's origin:
/// `allow` and `deny` (an unlisted kind too) as they are, `ask` as `DEFAULT`, which also
/// erases a state an earlier build left in the profile.
fn stateFor(webview: *c.ICoreWebView2, origin: []const u8) void {
    var thirteenth: ?*c.ICoreWebView2_13 = null;
    if (!wv.ok(webview.lpVtbl.*.QueryInterface.?(webview, &c.IID_ICoreWebView2_13, @ptrCast(&thirteenth)))) return;
    const view = thirteenth orelse return;
    defer _ = view.lpVtbl.*.Release.?(view);
    var profile: ?*c.ICoreWebView2Profile = null;
    if (!wv.ok(view.lpVtbl.*.get_Profile.?(view, @ptrCast(&profile)))) return;
    const base = profile orelse return;
    defer _ = base.lpVtbl.*.Release.?(base);
    var fourth: ?*c.ICoreWebView2Profile4 = null;
    if (!wv.ok(base.lpVtbl.*.QueryInterface.?(base, &c.IID_ICoreWebView2Profile4, @ptrCast(&fourth)))) return;
    const settings = fourth orelse return;
    defer _ = settings.lpVtbl.*.Release.?(settings);
    var wide: [256:0]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], origin) catch return;
    wide[units] = 0;
    for (shared_kinds) |raw| {
        const kind = kindOf(raw) orelse continue;
        _ = settings.lpVtbl.*.SetPermissionState.?(settings, raw, &wide, profileState(policy.policyFor(&.{kind})), &state_written);
    }
}

const shared_kinds = [_]c.COREWEBVIEW2_PERMISSION_KIND{
    c.COREWEBVIEW2_PERMISSION_KIND_MICROPHONE,
    c.COREWEBVIEW2_PERMISSION_KIND_CAMERA,
    c.COREWEBVIEW2_PERMISSION_KIND_GEOLOCATION,
    c.COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS,
};

fn profileState(of: policy.Policy) c.COREWEBVIEW2_PERMISSION_STATE {
    return switch (of) {
        .allow => c.COREWEBVIEW2_PERMISSION_STATE_ALLOW,
        .deny => c.COREWEBVIEW2_PERMISSION_STATE_DENY,
        .ask => c.COREWEBVIEW2_PERMISSION_STATE_DEFAULT,
    };
}

var state_written: c.ICoreWebView2SetPermissionStateCompletedHandler = StateWritten.make();
const StateWritten = wv.Handler(
    c.ICoreWebView2SetPermissionStateCompletedHandler,
    c.ICoreWebView2SetPermissionStateCompletedHandlerVtbl,
    &c.IID_ICoreWebView2SetPermissionStateCompletedHandler,
    onStateWritten,
);

fn onStateWritten(_: [*c]c.ICoreWebView2SetPermissionStateCompletedHandler, _: c.HRESULT) callconv(.winapi) c.HRESULT {
    return c.S_OK;
}

pub const Handler = wv.Handler(
    c.ICoreWebView2PermissionRequestedEventHandler,
    c.ICoreWebView2PermissionRequestedEventHandlerVtbl,
    &c.IID_ICoreWebView2PermissionRequestedEventHandler,
    onRequest,
);

fn onRequest(
    _: [*c]c.ICoreWebView2PermissionRequestedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2PermissionRequestedEventArgs,
) callconv(.winapi) c.HRESULT {
    notSaved(args);
    var raw: c.COREWEBVIEW2_PERMISSION_KIND = c.COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
    _ = args.*.lpVtbl.*.get_PermissionKind.?(args, &raw);
    const one = kindOf(raw);
    const kinds: []const policy.Kind = if (one) |kind| &.{kind} else &.{};
    switch (policy.policyFor(kinds)) {
        .allow => _ = args.*.lpVtbl.*.put_State.?(args, c.COREWEBVIEW2_PERMISSION_STATE_ALLOW),
        .deny => _ = args.*.lpVtbl.*.put_State.?(args, c.COREWEBVIEW2_PERMISSION_STATE_DENY),
        .ask => ask(args, kinds),
    }
    return c.S_OK;
}

fn notSaved(args: *c.ICoreWebView2PermissionRequestedEventArgs) void {
    var third: ?*c.ICoreWebView2PermissionRequestedEventArgs3 = null;
    if (!wv.ok(args.lpVtbl.*.QueryInterface.?(args, &c.IID_ICoreWebView2PermissionRequestedEventArgs3, @ptrCast(&third)))) return;
    const later = third orelse return;
    _ = later.lpVtbl.*.put_SavesInProfile.?(later, c.FALSE);
    _ = later.lpVtbl.*.Release.?(later);
}

fn ask(args: *c.ICoreWebView2PermissionRequestedEventArgs, kinds: []const policy.Kind) void {
    const deny = c.COREWEBVIEW2_PERMISSION_STATE_DENY;
    const owner = bridge orelse {
        _ = args.lpVtbl.*.put_State.?(args, deny);
        return;
    };
    const slot = for (&asked) |*entry| {
        if (entry.args == null) break entry;
    } else {
        _ = args.lpVtbl.*.put_State.?(args, deny);
        return;
    };
    var deferral: [*c]c.ICoreWebView2Deferral = null;
    if (!wv.ok(args.lpVtbl.*.GetDeferral.?(args, &deferral)) or deferral == null) {
        _ = args.lpVtbl.*.put_State.?(args, deny);
        return;
    }
    _ = args.lpVtbl.*.AddRef.?(args);
    slot.* = .{ .args = args, .deferral = deferral, .id = policy.nextId() };
    var payload: [@import("../events.zig").max_data]u8 = undefined;
    _ = owner.emit(policy.request_event, policy.requestPayload(slot.id, kinds, &payload)) catch {
        settle(slot, false);
        return;
    };
    request.timeoutOnce(answer_within_ms, &onUnanswered, @ptrFromInt(@as(usize, slot.id)));
}

fn settle(slot: *Asked, allow: bool) void {
    const args = slot.args orelse return;
    _ = args.lpVtbl.*.put_State.?(args, if (allow) c.COREWEBVIEW2_PERMISSION_STATE_ALLOW else c.COREWEBVIEW2_PERMISSION_STATE_DENY);
    if (slot.deferral) |deferral| {
        _ = deferral.lpVtbl.*.Complete.?(deferral);
        _ = deferral.lpVtbl.*.Release.?(deferral);
    }
    _ = args.lpVtbl.*.Release.?(args);
    slot.* = .{};
}

fn onUnanswered(data: ?*anyopaque) callconv(.c) c_int {
    const id: u32 = @intCast(@intFromPtr(data) & std.math.maxInt(u32));
    _ = answer(id, false);
    return 0;
}

/// `permission.respond`: the page's answer to request `id`.
pub fn answer(id: u32, allow: bool) bool {
    for (&asked) |*slot| {
        if (slot.args != null and slot.id == id) {
            settle(slot, allow);
            return true;
        }
    }
    return false;
}

test "WebView2's kinds map onto the names webPermissions uses" {
    try std.testing.expectEqual(policy.Kind.camera, kindOf(c.COREWEBVIEW2_PERMISSION_KIND_CAMERA).?);
    try std.testing.expectEqual(policy.Kind.microphone, kindOf(c.COREWEBVIEW2_PERMISSION_KIND_MICROPHONE).?);
    try std.testing.expectEqual(policy.Kind.notifications, kindOf(c.COREWEBVIEW2_PERMISSION_KIND_NOTIFICATIONS).?);
    try std.testing.expect(kindOf(c.COREWEBVIEW2_PERMISSION_KIND_CLIPBOARD_READ) == null);
    for (shared_kinds) |raw| try std.testing.expect(kindOf(raw) != null);
}

test "the profile holds allow and deny, and nothing for ask" {
    try std.testing.expect(profileState(.allow) == c.COREWEBVIEW2_PERMISSION_STATE_ALLOW);
    try std.testing.expect(profileState(.deny) == c.COREWEBVIEW2_PERMISSION_STATE_DENY);
    try std.testing.expect(profileState(.ask) == c.COREWEBVIEW2_PERMISSION_STATE_DEFAULT);
    // The whole path, so the vtable calls are compiled.
    _ = &stateFor;
}
