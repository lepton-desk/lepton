//! The page's end of the channel: `globalThis.__lepton`, injected at document start.
//!
//! The frontend SDK (`lepton.ts`) reads the core's outbound ring through a
//! `ChannelTransport`. A web page cannot map this process's shared memory, so the
//! transport keeps one fixed `Uint8Array` the size of the ring and keeps it current from
//! `/__lepton/region?after=N`: the bridge holds that request until the core publishes
//! past `N` and answers with only the new frames (`region.zig`), which the page writes
//! into its copy. The first answer, and one after the page fell a lap behind, is the
//! mapping itself. A page with nothing new to read sleeps: the 250 ms re-read this
//! replaced kept an idle page at 2.9% of a core with a 6–32 MiB heap sawtooth.
//!
//! The ring's layout is not written into JavaScript by hand. Every offset the page reads
//! is taken here, at compile time, from the `extern struct`s the core itself writes
//! (`ring.Header`, `ring.CellHeader`, `wire.Header`, `wire.Sample`) and handed to the
//! page as `__lepton.layout`. The SDK's first version guessed the layout (cell count at
//! offset 0, cells from the region's first byte) and could never have read a frame; a
//! layout taken from the structs cannot drift from them.

const std = @import("std");
const compat = @import("../../compat.zig");
const ring = @import("../../ipc/ring.zig");
const wire = @import("../../ipc/wire.zig");
const invoke = @import("invoke.zig");
const registry = @import("registry.zig");
const events = @import("events.zig");
const secret = @import("secret.zig");

/// The core's own paths, after `/__lepton/<this run's key>` (`secret.zig`): the ring
/// snapshot, the close request, the event log and `invoke`.
pub const region_name = "/region";
pub const close_name = "/close";
pub const events_name = "/events";
pub const invoke_name = "/invoke";

/// A core URL as written into the comptime layout: the key's place is `secret.marker`,
/// filled in when the script is written (`script`).
fn coreUrl(comptime name: []const u8) []const u8 {
    return core_origin ++ "/__lepton/" ++ secret.marker ++ name;
}

/// Absolute, on the core's own origin. Same-origin for a packaged page (served from
/// `lepton://localhost/`); a cross-origin read for a page served by the dev server,
/// which the bridge allows for that one origin (`Bridge.allowOriginOf`).
/// Windows: `http://lepton.localhost`, which the WebView2 view filters and answers
/// (`webview2/view.zig`) — WebView2 takes no custom scheme without its loader.
pub const core_origin = if (@import("builtin").os.tag == .windows) "http://lepton.localhost" else "lepton://localhost";

/// How long the page waits before asking again after a failed read, in milliseconds:
/// the core is gone or going, and asking at once would spin.
pub const retry_ms: u32 = 1000;

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
    for (compat.enumNames(invoke.Status), compat.enumValues(invoke.Status), 0..) |name, value, index| {
        if (index != 0) text = text ++ ",";
        text = text ++ std.fmt.comptimePrint("\"{d}\":\"{s}\"", .{ value, name });
    }
    break :blk text ++ "}";
};

/// What the SDK needs to read event frames, and the window-state bits they carry.
const events_object = std.fmt.comptimePrint(
    "{{url:\"{s}\",holdMs:{d},kindNotice:{d},noticeBytes:{d},noticeNameLenOffset:{d},noticeDataLenOffset:{d}," ++
        "windowState:{{fullscreen:{d},maximized:{d},active:{d}}}}}",
    .{
        coreUrl(events_name),
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
    for (compat.enumNames(invoke.Status)) |name| text = text ++ "\n  \"" ++ name ++ "\",";
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
        coreUrl(invoke_name),
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

/// The dev server's origin as the script may quote it: `scheme://host[:port]` characters
/// only, or "" (a packaged page, or anything else, which then gets no exception).
fn quotableOrigin(page_origin: []const u8) []const u8 {
    for (page_origin) |char| {
        const fine = std.ascii.isAlphanumeric(char) or std.mem.indexOfScalar(u8, ":/.-[]", char) != null;
        if (!fine) return "";
    }
    return page_origin;
}

/// `document.cookie` for a page on the core's own scheme, which WPE WebKit and Servo give
/// no cookies (`cookie_shim.js`). It installs nothing on an http(s) page.
/// Its comment lines stay in the file and out of every page.
const cookie_shim = withoutCommentLines(@embedFile("cookie_shim.js"));

fn withoutCommentLines(comptime source: []const u8) []const u8 {
    @setEvalBranchQuota(200_000);
    comptime var kept: []const u8 = "";
    comptime var lines = std.mem.splitScalar(u8, source, '\n');
    inline while (comptime lines.next()) |line| {
        if (comptime !std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//")) kept = kept ++ line ++ "\n";
    }
    return kept;
}

/// Who the application is, as the page reads it from `__lepton.app`
/// (`@lepton-desk/api/app` `info()`, `@lepton-desk/api/window` `title()`). The template's
/// `main.zig` sets it on the bridge (`Bridge.application`) from `lepton.config.json`; a
/// `main.zig` that predates it leaves every field empty. Fixed for the run, so the page
/// reads it without asking the core.
pub const Application = struct {
    /// `productName`.
    name: []const u8 = "",
    /// `version`.
    version: []const u8 = "",
    identifier: []const u8 = "",
    /// `window.title`: the window's name while the page has no `document.title`.
    title: []const u8 = "",
};

/// Longest field written into the page, in bytes; a longer one is cut at a character.
const max_application_field = 256;

/// `application` as a frozen object literal of JSON strings into `out`.
pub fn writeApplication(out: []u8, application: Application) error{NoSpaceLeft}![]const u8 {
    var used: usize = 0;
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "name", application.name },
        .{ "version", application.version },
        .{ "identifier", application.identifier },
        .{ "title", application.title },
    };
    used += (try std.fmt.bufPrint(out[used..], "Object.freeze({{", .{})).len;
    for (fields, 0..) |field, index| {
        if (index != 0) used += (try std.fmt.bufPrint(out[used..], ",", .{})).len;
        used += (try std.fmt.bufPrint(out[used..], "{s}:", .{field[0]})).len;
        used += (try writeJsonString(out[used..], cutAtCharacter(field[1], max_application_field))).len;
    }
    used += (try std.fmt.bufPrint(out[used..], "}})", .{})).len;
    return out[0..used];
}

/// `text`, at most `limit` bytes, never ending inside a UTF-8 sequence.
fn cutAtCharacter(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

/// `text` as a double-quoted string the script can carry whatever the configuration says:
/// quotes, backslashes, control characters and the two line separators escaped.
fn writeJsonString(out: []u8, text: []const u8) error{NoSpaceLeft}![]const u8 {
    var used: usize = 0;
    used += (try std.fmt.bufPrint(out[used..], "\"", .{})).len;
    var at: usize = 0;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (char == '"' or char == '\\') {
            used += (try std.fmt.bufPrint(out[used..], "\\{c}", .{char})).len;
        } else if (char < 0x20) {
            used += (try std.fmt.bufPrint(out[used..], "\\u{x:0>4}", .{char})).len;
        } else if (char == 0xe2 and at + 2 < text.len and text[at + 1] == 0x80 and (text[at + 2] == 0xa8 or text[at + 2] == 0xa9)) {
            used += (try std.fmt.bufPrint(out[used..], "\\u202{c}", .{@as(u8, if (text[at + 2] == 0xa8) '8' else '9')})).len;
            at += 2;
        } else {
            used += (try std.fmt.bufPrint(out[used..], "{c}", .{char})).len;
        }
    }
    used += (try std.fmt.bufPrint(out[used..], "\"", .{})).len;
    return out[0..used];
}

/// Writes the user script for a ring of `region_len` bytes into `out`.
///
/// Frozen object, fixed buffer: the SDK builds one `DataView` over `bytes` when its
/// module loads, so the array is allocated once and refreshed in place with `set`. A
/// replaced array would leave the SDK reading the first snapshot forever.
///
/// The transport, for the application's own page only: `page_origin` is the dev server's
/// origin ("" for a packaged page served from `core_origin`). In any other document — a
/// page the window navigated to, `about:srcdoc`, an embedded frame — it defines nothing,
/// so that document has neither `__lepton` nor the run's key (`secret.zig`), nor the
/// cookie shim.
pub fn script(out: []u8, region_len: usize, commands: *const registry.Registry, page_origin: []const u8, application: Application) error{NoSpaceLeft}![:0]const u8 {
    // The application's commands are known when the application is built, not when the
    // core is, so their table is written here at run time beside the comptime layout.
    var app_table: [2048]u8 = undefined;
    const app = try registry.writeAppTable(commands, &app_table);
    var who_buffer: [4 * (max_application_field * 6 + 16) + 32]u8 = undefined;
    const who = try writeApplication(&who_buffer, application);
    const written = try std.fmt.bufPrintSentinel(out,
        \\(() => {{
        \\  "use strict";
        \\  if (globalThis.__lepton !== undefined) return;
        \\  const own = location.href.startsWith("{s}/") || ("{s}" !== "" && location.origin === "{s}");
        \\  if (!own) return;
        \\{s}
        \\  const layout = Object.freeze({s});
        \\  const bytes = new Uint8Array({d});
        \\  const view = new DataView(bytes.buffer);
        \\  const listeners = new Set();
        \\  let newest = 0n;
        \\  let connected = false;
        \\  let closed = false;
        \\  const apply = (got) => {{
        \\    if (got.byteLength === bytes.byteLength) {{
        \\      bytes.set(got);
        \\      return;
        \\    }}
        \\    if (got.byteLength < layout.headerBytes) throw new Error("short answer");
        \\    bytes.set(got.subarray(0, layout.headerBytes));
        \\    const count = BigInt(view.getUint32(layout.cellCountOffset, true));
        \\    const stride = view.getUint32(layout.cellStrideOffset, true);
        \\    const cells = new DataView(got.buffer, got.byteOffset, got.byteLength);
        \\    let used = layout.headerBytes;
        \\    for (let at = newest; used < got.byteLength; at += 1n) {{
        \\      const len = layout.cellHeaderBytes + cells.getUint32(used + layout.cellLenOffset, true);
        \\      bytes.set(got.subarray(used, used + len), layout.headerBytes + Math.imul(Number(at % count), stride));
        \\      used += len;
        \\    }}
        \\  }};
        \\  const refresh = async () => {{
        \\    while (!closed) {{
        \\      const controller = new AbortController();
        \\      const timer = setTimeout(() => controller.abort(), layout.events.holdMs);
        \\      try {{
        \\        const answer = await fetch(`{s}?after=${{newest}}`, {{ cache: "no-store", signal: controller.signal }});
        \\        if (!answer.ok) throw new Error(String(answer.status));
        \\        const got = new Uint8Array(await answer.arrayBuffer());
        \\        // Empty: another of this core's pages took the slot this one waited in.
        \\        if (got.byteLength === 0) continue;
        \\        apply(got);
        \\        connected = true;
        \\        const position = view.getBigUint64(layout.enqueueOffset, true);
        \\        if (position !== newest) {{
        \\          newest = position;
        \\          for (const listener of listeners) listener(position);
        \\        }}
        \\      }} catch {{
        \\        if (!controller.signal.aborted) {{
        \\          connected = false;
        \\          await new Promise((wake) => setTimeout(wake, {d}));
        \\        }}
        \\      }} finally {{
        \\        clearTimeout(timer);
        \\      }}
        \\    }}
        \\  }};
        \\  Object.defineProperty(globalThis, "__lepton", {{
        \\    value: Object.freeze({{
        \\      layout,
        \\      appCommands: Object.freeze({s}),
        \\      app: {s},
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
    , .{ core_origin, quotableOrigin(page_origin), quotableOrigin(page_origin), cookie_shim, layout_object, region_len, coreUrl(region_name), retry_ms, app, who, coreUrl(close_name) }, 0);
    secret.fill(out[0..written.len]);
    return written;
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
    return script(out, region_len, &no_commands, "", .{});
}

/// `text` with this run's key where the URLs carry it.
fn keyed(comptime before: []const u8, comptime after: []const u8, out: []u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ before, secret.get(), after });
}

test "the application's commands reach the page by name" {
    const app = [_]registry.Command(Notes){.{ .name = "notes.save", .run = &saveNothing }};
    var notes: Notes = .{};
    const commands = (comptime registry.checked(Notes, &app, registry.permissionList("notes.save"))).bind(&notes);
    var buffer: [16384]u8 = undefined;
    const text = try script(&buffer, 1, &commands, "", .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "appCommands: Object.freeze({\"notes.save\":1000})") != null);
}

const Notes = struct {};

fn saveNothing(_: *Notes, _: []const u8, _: []u8) registry.HandlerError!usize {
    return 0;
}

test "the page gets the event frame layout and the window-state bits" {
    var buffer: [16384]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    var url: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try keyed("url:\"" ++ core_origin ++ "/__lepton/", "/events\"", &url)) != null);
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
    const expected = comptime blk: {
        var text: []const u8 = "export interface BuiltinEvents {\n";
        for (events.builtin) |name| text = text ++ "  \"" ++ name ++ "\": true;\n";
        break :blk text ++ "}";
    };
    try std.testing.expect(std.mem.indexOf(u8, command_types, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, command_types, "\"download.finished\": true;") != null);
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
    var url: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try keyed("url:\"" ++ core_origin ++ "/__lepton/", "/invoke\"", &url)) != null);
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
    var url: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, text, try keyed("fetch(`" ++ core_origin ++ "/__lepton/", "/region?after=", &url)) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"*\"") == null);
}

test "a page on the core's scheme gets document.cookie, without the shim's comments" {
    var buffer: [8192]u8 = undefined;
    const text = try scriptFor(&buffer, 1);
    try std.testing.expect(std.mem.indexOf(u8, text, "Object.defineProperty(globalObject.Document.prototype, \"cookie\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cookie-averse") == null);
    // Installed after the own-page check, so another document gets no shim either.
    try std.testing.expect(std.mem.indexOf(u8, text, "if (!own) return;").? < std.mem.indexOf(u8, text, "__lepton.cookies").?);
}

test "the transport defines itself only in the application's own page" {
    var buffer: [8192]u8 = undefined;
    const packaged = try script(&buffer, 1, &no_commands, "", .{});
    try std.testing.expect(std.mem.indexOf(u8, packaged, "location.href.startsWith(\"" ++ core_origin ++ "/\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, packaged, "if (!own) return;") != null);
    // Every core URL carries the key; none is left as the marker.
    try std.testing.expect(std.mem.indexOf(u8, packaged, secret.marker) == null);

    var dev_buffer: [8192]u8 = undefined;
    const dev = try script(&dev_buffer, 1, &no_commands, "http://127.0.0.1:5173", .{});
    try std.testing.expect(std.mem.indexOf(u8, dev, "location.origin === \"http://127.0.0.1:5173\"") != null);
    // An origin with a quote is not quoted into the script.
    var odd_buffer: [8192]u8 = undefined;
    const odd = try script(&odd_buffer, 1, &no_commands, "http://x\"+alert(1)+\"", .{});
    try std.testing.expect(std.mem.indexOf(u8, odd, "alert") == null);
}

test "the page reads who the application is, whatever the configuration's text" {
    var buffer: [16384]u8 = undefined;
    const text = try script(&buffer, 1, &no_commands, "", .{ .name = "Notes \"2\"", .version = "1.2.3", .identifier = "dev.lepton.notes", .title = "a\\b\nc\u{2028}" });
    try std.testing.expect(std.mem.indexOf(u8, text, "app: Object.freeze({name:\"Notes \\\"2\\\"\",version:\"1.2.3\",identifier:\"dev.lepton.notes\",title:\"a\\\\b\\u000ac\\u2028\"})") != null);
    // Cut at a character, never inside one: 255 ASCII bytes and a two-byte "ğ".
    // (Built with `@memset`: Zig 0.17 has no `**`.)
    var long: [257]u8 = undefined;
    @memset(long[0..255], 'x');
    @memcpy(long[255..], "ğ");
    var cut_buffer: [16384]u8 = undefined;
    const cut = try script(&cut_buffer, 1, &no_commands, "", .{ .name = &long });
    var needle: [270]u8 = undefined;
    const expected = try std.fmt.bufPrint(&needle, "name:\"{s}\",", .{long[0..255]});
    try std.testing.expect(std.mem.indexOf(u8, cut, expected) != null);
}
