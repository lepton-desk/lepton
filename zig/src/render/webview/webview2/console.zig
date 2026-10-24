//! The page's `console` in the terminal, in a Debug build, as WPE's
//! `write_console_messages_to_stdout` does on Linux (`features.zig`). WebView2 has no such
//! setting: the DevTools protocol's `Runtime.consoleAPICalled` is listened to instead, after
//! `Runtime.enable`, and each call is printed as `console.<kind>  <arguments>`.

const std = @import("std");
const builtin = @import("builtin");
const wv = @import("c.zig");
const c = wv.c;

/// Listens on `webview` when this is a Debug build; a release build prints nothing.
pub fn watch(webview: *c.ICoreWebView2, handler: *c.ICoreWebView2DevToolsProtocolEventReceivedEventHandler, enabled: *c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandler) void {
    if (builtin.mode != std.builtin.OptimizeMode.Debug) return;
    var receiver: ?*c.ICoreWebView2DevToolsProtocolEventReceiver = null;
    if (!wv.ok(webview.lpVtbl.*.GetDevToolsProtocolEventReceiver.?(webview, wv.W("Runtime.consoleAPICalled"), @ptrCast(&receiver)))) return;
    const events = receiver orelse return;
    defer _ = events.lpVtbl.*.Release.?(events);
    var token: c.EventRegistrationToken = undefined;
    _ = events.lpVtbl.*.add_DevToolsProtocolEventReceived.?(events, handler, &token);
    _ = webview.lpVtbl.*.CallDevToolsProtocolMethod.?(webview, wv.W("Runtime.enable"), wv.W("{}"), enabled);
}

pub const Received = wv.Handler(
    c.ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
    c.ICoreWebView2DevToolsProtocolEventReceivedEventHandlerVtbl,
    &c.IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
    onReceived,
);

pub const Enabled = wv.Handler(
    c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
    c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandlerVtbl,
    &c.IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
    onEnabled,
);

fn onEnabled(_: [*c]c.ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, _: c.HRESULT, _: c.LPCWSTR) callconv(.winapi) c.HRESULT {
    return c.S_OK;
}

fn onReceived(
    _: [*c]c.ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
    _: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2DevToolsProtocolEventReceivedEventArgs,
) callconv(.winapi) c.HRESULT {
    var wide: c.LPWSTR = null;
    if (!wv.ok(args.*.lpVtbl.*.get_ParameterObjectAsJson.?(args, &wide))) return c.S_OK;
    var json: [16 * 1024]u8 = undefined;
    const text = wv.takeString(wide, &json);
    var line: [4096]u8 = undefined;
    std.debug.print("{s}\n", .{describe(text, &line)});
    return c.S_OK;
}

/// One `Runtime.consoleAPICalled` as a line: `console.<type>` and each argument's value
/// (its `description` for an object), separated by spaces. The JSON itself when it does
/// not parse.
fn describe(text: []const u8, out: []u8) []const u8 {
    var scratch: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, fixed.allocator(), text, .{}) catch return text;
    var writer = std.Io.Writer.fixed(out);
    const object = switch (parsed) {
        .object => |object| object,
        else => return text,
    };
    const kind = if (object.get("type")) |value| switch (value) {
        .string => |name| name,
        else => "log",
    } else "log";
    writer.print("console.{s} ", .{kind}) catch return writer.buffered();
    const list = if (object.get("args")) |value| switch (value) {
        .array => |array| array.items,
        else => &.{},
    } else &.{};
    for (list) |argument| {
        const fields = switch (argument) {
            .object => |fields| fields,
            else => continue,
        };
        writer.writeByte(' ') catch break;
        if (fields.get("value")) |value| switch (value) {
            .string => |string| writer.writeAll(string) catch break,
            .integer => |number| writer.print("{d}", .{number}) catch break,
            .float => |number| writer.print("{d}", .{number}) catch break,
            .bool => |flag| writer.writeAll(if (flag) "true" else "false") catch break,
            .null => writer.writeAll("null") catch break,
            else => writer.writeAll("[value]") catch break,
        } else if (fields.get("description")) |value| switch (value) {
            .string => |string| writer.writeAll(string) catch break,
            else => writer.writeAll("[object]") catch break,
        } else if (fields.get("type")) |value| switch (value) {
            .string => |string| writer.writeAll(string) catch break,
            else => {},
        };
    }
    return writer.buffered();
}

test "a console call is its kind and its arguments' values" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "console.log  hello 3 true",
        describe(
            \\{"type":"log","args":[{"type":"string","value":"hello"},{"type":"number","value":3,"description":"3"},{"type":"boolean","value":true}],"executionContextId":1}
        , &out),
    );
    try std.testing.expectEqualStrings(
        "console.error  Error: broken",
        describe(
            \\{"type":"error","args":[{"type":"object","subtype":"error","description":"Error: broken"}]}
        , &out),
    );
    // `console.warn` is "warning" in the protocol; `undefined` has a type and no value.
    try std.testing.expectEqualStrings(
        "console.warning  undefined",
        describe(
            \\{"type":"warning","args":[{"type":"undefined"}]}
        , &out),
    );
}
