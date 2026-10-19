//! Downloads on WebView2, reported as on Linux (`../downloads.zig`): `download.started`
//! (id, file name), `download.progress` (id, 0, received, expected — at most four a
//! second), `download.finished` (id, full path), `download.failed` (id, reason).
//!
//! WebView2 picks the destination itself — the user's Downloads folder, under the
//! server's name made unique with " (1)" — and its own flyout is hidden (`Handled`): the
//! application, told through the events, is the one interface.

const std = @import("std");
const wv = @import("c.zig");
const c = wv.c;
const shared = @import("../downloads.zig");
const events = @import("../events.zig");
const Bridge = @import("../bridge.zig").Bridge;

/// One download in flight; its handlers are embedded so each finds its own entry.
const Active = struct {
    operation: ?*c.ICoreWebView2DownloadOperation = null,
    id: u32 = 0,
    last_progress_ns: ?u64 = null,
    bytes_changed: c.ICoreWebView2BytesReceivedChangedEventHandler = BytesChanged.make(),
    state_changed: c.ICoreWebView2StateChangedEventHandler = StateChanged.make(),
};
var active: [16]Active = @splat(.{});
var next_id: u32 = 1;
var bridge: ?*Bridge = null;

pub const Handler = wv.Handler(
    c.ICoreWebView2DownloadStartingEventHandler,
    c.ICoreWebView2DownloadStartingEventHandlerVtbl,
    &c.IID_ICoreWebView2DownloadStartingEventHandler,
    onStarting,
);
const BytesChanged = wv.Handler(
    c.ICoreWebView2BytesReceivedChangedEventHandler,
    c.ICoreWebView2BytesReceivedChangedEventHandlerVtbl,
    &c.IID_ICoreWebView2BytesReceivedChangedEventHandler,
    onBytes,
);
const StateChanged = wv.Handler(
    c.ICoreWebView2StateChangedEventHandler,
    c.ICoreWebView2StateChangedEventHandlerVtbl,
    &c.IID_ICoreWebView2StateChangedEventHandler,
    onState,
);

/// Takes this view's downloads (`ICoreWebView2_4`, runtime 1.0.902+).
pub fn watch(webview: *c.ICoreWebView2, owner: *Bridge, handler: *c.ICoreWebView2DownloadStartingEventHandler) void {
    bridge = owner;
    var fourth: ?*c.ICoreWebView2_4 = null;
    if (!wv.ok(webview.lpVtbl.*.QueryInterface.?(webview, &c.IID_ICoreWebView2_4, @ptrCast(&fourth)))) return;
    const view = fourth orelse return;
    defer _ = view.lpVtbl.*.Release.?(view);
    var token: c.EventRegistrationToken = undefined;
    _ = view.lpVtbl.*.add_DownloadStarting.?(view, handler, &token);
}

fn nowNs() u64 {
    return @as(u64, c.GetTickCount64()) * std.time.ns_per_ms;
}

fn emit(name: []const u8, data: []const u8) void {
    if (bridge) |owner| _ = owner.emit(name, data) catch {};
}

fn pathOf(operation: *c.ICoreWebView2DownloadOperation, out: []u8) []const u8 {
    var wide: c.LPWSTR = null;
    if (!wv.ok(operation.lpVtbl.*.get_ResultFilePath.?(operation, &wide))) return "";
    return wv.takeString(wide, out);
}

fn onStarting(
    _: [*c]c.ICoreWebView2DownloadStartingEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2DownloadStartingEventArgs,
) callconv(.winapi) c.HRESULT {
    _ = args.*.lpVtbl.*.put_Handled.?(args, c.TRUE);
    var raw: [*c]c.ICoreWebView2DownloadOperation = null;
    if (!wv.ok(args.*.lpVtbl.*.get_DownloadOperation.?(args, &raw)) or raw == null) return c.S_OK;
    const operation: *c.ICoreWebView2DownloadOperation = raw;
    const slot = for (&active) |*entry| {
        if (entry.operation == null) break entry;
    } else {
        // Sixteen at once already: refused rather than run unreported.
        _ = args.*.lpVtbl.*.put_Cancel.?(args, c.TRUE);
        _ = operation.lpVtbl.*.Release.?(operation);
        return c.S_OK;
    };
    slot.operation = operation;
    slot.id = next_id;
    slot.last_progress_ns = null;
    next_id = if (next_id == std.math.maxInt(u32)) 1 else next_id + 1;
    var token: c.EventRegistrationToken = undefined;
    _ = operation.lpVtbl.*.add_BytesReceivedChanged.?(operation, &slot.bytes_changed, &token);
    _ = operation.lpVtbl.*.add_StateChanged.?(operation, &slot.state_changed, &token);

    var path: [c.MAX_PATH * 3]u8 = undefined;
    var wide: c.LPWSTR = null;
    const chosen = if (wv.ok(args.*.lpVtbl.*.get_ResultFilePath.?(args, &wide))) wv.takeString(wide, &path) else "";
    var payload: [events.max_data]u8 = undefined;
    emit(events.download_started, shared.textPayload(slot.id, std.fs.path.basename(chosen), &payload));
    return c.S_OK;
}

fn slotOf(comptime field: []const u8, handler: anytype) *Active {
    const typed: *@FieldType(Active, field) = @ptrCast(handler);
    return @alignCast(@fieldParentPtr(field, typed));
}

fn onBytes(this: [*c]c.ICoreWebView2BytesReceivedChangedEventHandler, operation: [*c]c.ICoreWebView2DownloadOperation, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    const slot = slotOf("bytes_changed", this);
    const now = nowNs();
    if (!shared.progressDue(slot.last_progress_ns, now)) return c.S_OK;
    slot.last_progress_ns = now;
    var received: i64 = 0;
    var expected: i64 = 0;
    _ = operation.*.lpVtbl.*.get_BytesReceived.?(operation, &received);
    _ = operation.*.lpVtbl.*.get_TotalBytesToReceive.?(operation, &expected);
    const bytes = shared.progressPayload(slot.id, @intCast(@max(received, 0)), @intCast(@max(expected, 0)));
    emit(events.download_progress, &bytes);
    return c.S_OK;
}

fn onState(this: [*c]c.ICoreWebView2StateChangedEventHandler, operation: [*c]c.ICoreWebView2DownloadOperation, _: [*c]c.IUnknown) callconv(.winapi) c.HRESULT {
    const slot = slotOf("state_changed", this);
    var state: c.COREWEBVIEW2_DOWNLOAD_STATE = c.COREWEBVIEW2_DOWNLOAD_STATE_IN_PROGRESS;
    _ = operation.*.lpVtbl.*.get_State.?(operation, &state);
    var payload: [events.max_data]u8 = undefined;
    switch (state) {
        c.COREWEBVIEW2_DOWNLOAD_STATE_COMPLETED => {
            var path: [c.MAX_PATH * 3]u8 = undefined;
            emit(events.download_finished, shared.textPayload(slot.id, pathOf(operation, &path), &payload));
        },
        c.COREWEBVIEW2_DOWNLOAD_STATE_INTERRUPTED => {
            var reason: c.COREWEBVIEW2_DOWNLOAD_INTERRUPT_REASON = 0;
            _ = operation.*.lpVtbl.*.get_InterruptReason.?(operation, &reason);
            var text: [64]u8 = undefined;
            const message = std.fmt.bufPrint(&text, "interrupted (WebView2 reason {d})", .{reason}) catch "interrupted";
            emit(events.download_failed, shared.textPayload(slot.id, message, &payload));
        },
        else => return c.S_OK,
    }
    // Done either way: the slot is free for the next download.
    if (slot.operation) |held| _ = held.lpVtbl.*.Release.?(held);
    slot.operation = null;
    return c.S_OK;
}
