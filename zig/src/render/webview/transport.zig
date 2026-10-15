//! The page's end of the channel: `globalThis.__lepton`, injected at document start.
//!
//! The frontend SDK (`lepton.ts`) reads the core's outbound ring through a
//! `ChannelTransport`. A web page cannot map this process's shared memory, so the
//! transport keeps one fixed `Uint8Array` the size of the ring and refreshes it from
//! `/__lepton/region` on the document's own origin, which the bridge answers straight
//! from the mapping. One copy reaches the page — WebKit's, into the web process — and
//! none is made on the core's side.
//!
//! The ring's layout is not written into JavaScript by hand. Every offset the page reads
//! is taken here, at compile time, from the `extern struct`s the core itself writes
//! (`ring.Header`, `ring.CellHeader`, `wire.Header`, `wire.Sample`) and handed to the
//! page as `__lepton.layout`. The SDK's first version guessed the layout (cell count at
//! offset 0, cells from the region's first byte) and could never have read a frame; a
//! layout taken from the structs cannot drift from them.

const std = @import("std");
const ring = @import("../../ipc/ring.zig");
const wire = @import("../../ipc/wire.zig");
const invoke = @import("invoke.zig");
const registry = @import("registry.zig");
const events = @import("events.zig");

/// The path the page fetches the ring snapshot from, on its own origin.
pub const region_path = "/__lepton/region";
/// The path the page asks on when it is closing.
pub const close_path = "/__lepton/close";

/// Absolute, on the core's own origin. Same-origin for a packaged page (served from
/// `lepton://localhost/`); a cross-origin read for a page served by the dev server,
/// which the bridge allows for that one origin (`Bridge.allowOriginOf`).
pub const core_origin = "lepton://localhost";

/// How often the page refreshes its snapshot, in milliseconds. Four times a second:
/// the template redraws once a second, and a quarter-second lag is not visible there.
pub const refresh_ms: u32 = 250;

pub const layout_object = std.fmt.comptimePrint(
    "{{headerBytes:{d},cellCountOffset:{d},cellStrideOffset:{d},enqueueOffset:{d}," ++
        "cellHeaderBytes:{d},cellSeqOffset:{d},cellLenOffset:{d}," ++
        "wireHeaderBytes:{d},wireProtocolOffset:{d},wireKindOffset:{d},protocol:{d},kindSample:{d}," ++
        "sample:{{timestampNs:{d},rssBytes:{d},heapHighWaterBytes:{d},heapInUseBytes:{d}," ++
        "ringFreeCells:{d},ringCapacityCells:{d},roundTripNs:{d},roundTripMaxNs:{d}}},invoke:{s},events:{s}}}",
    .{
        ring.header_bytes,
        @offsetOf(ring.Header, "cell_count"),
        @offsetOf(ring.Header, "cell_stride"),
        @offsetOf(ring.Header, "enqueue_pos"),
        ring.cell_header_bytes,
        @offsetOf(ring.CellHeader, "seq"),
        @offsetOf(ring.CellHeader, "len"),
        wire.header_bytes,
        @offsetOf(wire.Header, "protocol"),
        @offsetOf(wire.Header, "kind"),
        wire.version,
        @intFromEnum(wire.Kind.sample),
        @offsetOf(wire.Sample, "timestamp_ns"),
        @offsetOf(wire.Sample, "rss_bytes"),
        @offsetOf(wire.Sample, "heap_high_water_bytes"),
        @offsetOf(wire.Sample, "heap_in_use_bytes"),
        @offsetOf(wire.Sample, "ring_free_cells"),
        @offsetOf(wire.Sample, "ring_capacity_cells"),
        @offsetOf(wire.Sample, "round_trip_ns"),
        @offsetOf(wire.Sample, "round_trip_max_ns"),
        invoke_object,
        events_object,
    },
);

/// `{"core.ping":1,...}`, from `invoke.Command` — the only place command ids are spelled.
const command_table = blk: {
    var text: []const u8 = "{";
    for (invoke.commands, 0..) |command, index| {
        if (index != 0) text = text ++ ",";
        text = text ++ std.fmt.comptimePrint("\"{s}\":{d}", .{ command.publicName(), @intFromEnum(command) });
    }
    break :blk text ++ "}";
};

/// `{"1":"malformed",...}`, from `invoke.Status`, so an error names its cause.
const status_table = blk: {
    var text: []const u8 = "{";
    for (@typeInfo(invoke.Status).@"enum".fields, 0..) |field, index| {
        if (index != 0) text = text ++ ",";
        text = text ++ std.fmt.comptimePrint("\"{d}\":\"{s}\"", .{ field.value, field.name });
    }
    break :blk text ++ "}";
};

/// What the SDK needs to read event frames, and the window-state bits they carry.
const events_object = std.fmt.comptimePrint(
    "{{url:\"{s}\",holdMs:{d},kindNotice:{d},noticeBytes:{d},noticeNameLenOffset:{d},noticeDataLenOffset:{d}," ++
        "windowState:{{fullscreen:{d},maximized:{d},active:{d}}}}}",
    .{
        core_origin ++ events.path,
        events.hold_ms,
        @intFromEnum(wire.Kind.notice),
        @sizeOf(wire.Notice),
        @offsetOf(wire.Notice, "name_len"),
        @offsetOf(wire.Notice, "data_len"),
        invoke.WindowState.fullscreen,
        invoke.WindowState.maximized,
        invoke.WindowState.active,
    },
);

/// `packages/api/src/commands.gen.ts`: the built-in command names and status names as
/// TypeScript types, from the same enums the core dispatches on. The SDK's test fails if
/// the checked-in file differs from this.
pub const command_types = blk: {
    var text: []const u8 =
        "// Generated from the core's `invoke.Command` and `invoke.Status` by\n" ++
        "// `lepton-invoke-check types`. Do not edit; `pnpm run generate` rewrites it.\n\n" ++
        "/** The core's built-in commands. */\nexport interface BuiltinCommands {\n";
    for (invoke.commands) |command| text = text ++ "  \"" ++ command.publicName() ++ "\": true;\n";
    text = text ++ "}\n\n/** The events the core itself emits. */\nexport interface BuiltinEvents {\n";
    for (events.builtin) |name| text = text ++ "  \"" ++ name ++ "\": true;\n";
    text = text ++ "}\n\n/** Every status, by name; `ok` is success. */\nexport const statusNames = [";
    for (@typeInfo(invoke.Status).@"enum".fields) |field| text = text ++ "\n  \"" ++ field.name ++ "\",";
    break :blk text ++ "\n] as const;\n\n/** Why a call failed, by name. */\nexport type StatusName = (typeof statusNames)[number];\n";
};

/// What the SDK needs to build a request frame and read a reply, from the structs.
const invoke_object = std.fmt.comptimePrint(
    "{{url:\"{s}\",maxRequest:{d},kindRequest:{d},kindReply:{d}," ++
        "headerPayloadLenOffset:{d},headerSequenceOffset:{d}," ++
        "requestBytes:{d},requestCommandOffset:{d},requestArgumentLenOffset:{d},requestArgumentOffOffset:{d}," ++
        "replyBytes:{d},replySequenceOffset:{d},replyStatusOffset:{d},replyResultLenOffset:{d},replyResultOffOffset:{d}," ++
        "commands:{s},statuses:{s}}}",
    .{
        core_origin ++ invoke.path,
        invoke.max_request,
        @intFromEnum(wire.Kind.request),
        @intFromEnum(wire.Kind.reply),
        @offsetOf(wire.Header, "payload_len"),
        @offsetOf(wire.Header, "sequence"),
        @sizeOf(wire.Request),
        @offsetOf(wire.Request, "command"),
        @offsetOf(wire.Request, "argument_len"),
        @offsetOf(wire.Request, "argument_off"),
        @sizeOf(wire.Reply),
        @offsetOf(wire.Reply, "request_sequence"),
        @offsetOf(wire.Reply, "status"),
        @offsetOf(wire.Reply, "result_len"),
        @offsetOf(wire.Reply, "result_off"),
        command_table,
        status_table,
    },
);

/// Writes the user script for a ring of `region_len` bytes into `out`.
///
/// Frozen object, fixed buffer: the SDK builds one `DataView` over `bytes` when its
/// module loads, so the array is allocated once and refreshed in place with `set`. A
/// replaced array would leave the SDK reading the first snapshot forever.
pub fn script(out: []u8, region_len: usize, commands: *const registry.Registry) error{NoSpaceLeft}![:0]const u8 {
    // The application's commands are known when the application is built, not when the
    // core is, so their table is written here at run time beside the comptime layout.
    var app_table: [2048]u8 = undefined;
    const app = try registry.writeAppTable(commands, &app_table);
    return std.fmt.bufPrintZ(out,
        \\(() => {{
        \\  "use strict";
        \\  if (globalThis.__lepton !== undefined) return;
        \\  const layout = Object.freeze({s});
        \\  const bytes = new Uint8Array({d});
        \\  const view = new DataView(bytes.buffer);
        \\  const listeners = new Set();
        \\  let newest = 0n;
        \\  let connected = false;
        \\  let closed = false;
        \\  const refresh = async () => {{
        \\    if (closed) return;
        \\    try {{
        \\      const answer = await fetch("{s}", {{ cache: "no-store" }});
        \\      if (!answer.ok) throw new Error(String(answer.status));
        \\      const got = new Uint8Array(await answer.arrayBuffer());
        \\      if (got.byteLength !== bytes.byteLength) throw new Error("region size changed");
        \\      bytes.set(got);
        \\      connected = true;
        \\      const position = view.getBigUint64(layout.enqueueOffset, true);
        \\      if (position !== newest) {{
        \\        newest = position;
        \\        for (const listener of listeners) listener(position);
        \\      }}
        \\    }} catch {{
        \\      connected = false;
        \\    }}
        \\    setTimeout(refresh, {d});
        \\  }};
        \\  Object.defineProperty(globalThis, "__lepton", {{
        \\    value: Object.freeze({{
        \\      layout,
        \\      appCommands: Object.freeze({s}),
        \\      bytes,
        \\      newestSequence: () => newest,
        \\      onPublished(listener) {{
        \\        listeners.add(listener);
        \\        return () => listeners.delete(listener);
        \\      }},
        \\      isConnected: () => connected,
        \\      close() {{
        \\        closed = true;
        \\        return fetch("{s}", {{ cache: "no-store" }}).then(() => undefined, () => undefined);
        \\      }},
        \\    }}),
        \\  }});
        \\  refresh();
        \\}})();
        \\
    , .{ layout_object, region_len, core_origin ++ region_path, refresh_ms, app, core_origin ++ close_path });
}

// --- Injection ------------------------------------------------------------------

const e_user_content_manager = @extern(
    *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_web_view_get_user_content_manager" },
);
const e_user_script_new = @extern(
    *const fn ([*:0]const u8, c_int, c_int, ?*const anyopaque, ?*const anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "webkit_user_script_new" },
);
const e_add_script = @extern(
    *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_user_content_manager_add_script" },
);
const e_user_script_unref = @extern(
    *const fn (?*anyopaque) callconv(.c) void,
    .{ .name = "webkit_user_script_unref" },
);

/// `WEBKIT_USER_CONTENT_INJECT_TOP_FRAME` and `WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`
/// (`WebKitUserContent.h`, WPE 2.54.1). The top frame only: an embedded frame is someone
/// else's page and gets no channel.
const inject_top_frame: c_int = 1;
const at_document_start: c_int = 0;

/// Adds the transport to `web_view` for every document it loads from now on.
///
/// Returns whether the engine accepted it. WebKit copies the source, so the buffer the
/// script was written into may go away after this returns.
pub fn inject(web_view: ?*anyopaque, source: [:0]const u8) bool {
    const manager = e_user_content_manager(web_view) orelse return false;
    const user_script = e_user_script_new(source.ptr, inject_top_frame, at_document_start, null, null) orelse return false;
    e_add_script(manager, user_script);
    e_user_script_unref(user_script);
    return true;
}

const no_commands: registry.Registry = .{};

fn scriptFor(out: []u8, region_len: usize) error{NoSpaceLeft}![:0]const u8 {
    return script(out, region_len, &no_commands);
}

test "the application's commands reach the page by name" {
    const app = [_]registry.Command(Notes){.{ .name = "notes.save", .run = &saveNothing }};
    var notes: Notes = .{};
    const commands = (comptime registry.checked(Notes, &app, registry.permissionList("notes.save"))).bind(&notes);
    var buffer: [16384]u8 = undefined;
    const text = try script(&buffer, 1, &commands);
    try std.testing.expect(std.mem.indexOf(u8, text, "appCommands: Object.freeze({\"notes.save\":1000})") != null);
}

const Notes = struct {};

fn saveNothing(_: *Notes, _: []const u8, _: []u8) registry.HandlerError!usize {
    return 0;
}

test "the page gets the event frame layout and the window-state bits" {
    var buffer: [16384]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    try std.testing.expect(std.mem.indexOf(u8, text, "url:\"lepton://localhost/__lepton/events\"") != null);
    var needle: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "kindNotice:{d}", .{@intFromEnum(wire.Kind.notice)})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "maximized:{d}", .{invoke.WindowState.maximized})) != null);
}

test "the generated types name every built-in command and status" {
    inline for (0..invoke.commands.len) |index| {
        const line = comptime "\"" ++ invoke.commands[index].publicName() ++ "\": true;";
        try std.testing.expect(std.mem.indexOf(u8, command_types, line) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, command_types, "\"denied\",") != null);
    try std.testing.expect(std.mem.indexOf(u8, command_types, "export interface BuiltinEvents {\n  \"window.state\": true;\n  \"window.resized\": true;\n}") != null);
}

test "the layout the page reads is the layout the core writes" {
    var buffer: [8192]u8 = undefined;
    const text = try scriptFor(&buffer, 4096);
    try std.testing.expect(std.mem.indexOf(u8, text, "new Uint8Array(4096)") != null);
    // The Vyukov cursor and the cell grammar, as the structs lay them out.
    var needle: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "enqueueOffset:{d}", .{@offsetOf(ring.Header, "enqueue_pos")})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "headerBytes:{d}", .{ring.header_bytes})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "wireHeaderBytes:{d}", .{wire.header_bytes})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "roundTripMaxNs:{d}", .{@offsetOf(wire.Sample, "round_trip_max_ns")})) != null);
}

test "the page gets invoke's offsets and command ids from the structs" {
    var buffer: [8192]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    var needle: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, "url:\"lepton://localhost/__lepton/invoke\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "\"window.close\":{d}", .{@intFromEnum(invoke.Command.window_close)})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "replyStatusOffset:{d}", .{@offsetOf(wire.Reply, "status")})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&needle, "requestBytes:{d}", .{@sizeOf(wire.Request)})) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"2\":\"unknown_command\"") != null);
}

test "the script is terminated for the C side and fits its buffer or refuses" {
    var buffer: [8192]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    try std.testing.expectEqual(@as(u8, 0), buffer[text.len]);
    var tiny: [64]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, scriptFor(&tiny, 1));
}

test "the page fetches the core's origin by absolute address, never a wildcard" {
    // Absolute so a page on the dev server (`http://127.0.0.1:5173`) reaches the core
    // rather than asking Vite for `/__lepton/region` and getting a 404.
    var buffer: [8192]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    try std.testing.expect(std.mem.indexOf(u8, text, "fetch(\"lepton://localhost/__lepton/region\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "*") == null);
}
