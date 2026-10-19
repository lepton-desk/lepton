//! File dialogs through the Windows shell (`IFileOpenDialog`, `IFileSaveDialog`), for
//! `@lepton-desk/plugin-dialog` — the counterpart of `platform/linux/portal.zig`, with the
//! same `Options`, the same reply (an `Outcome` byte, then each path ended by a NUL) and
//! the same grants, so the plugin is one file on both systems.
//!
//! The dialog is modal and runs its own message loop until the user is done. It is not
//! shown from inside the command: the command runs in WebView2's `WebResourceRequested`
//! handler, and WebView2 does not support a nested message loop there. So the request is
//! copied, the page's `invoke` is held open (`invoke.takeLater`), and a zero-delay timer
//! shows the dialog once the handler has returned; the reply finishes the held request.
//!
//! Gated like the portal: without WebView2 nothing here is analysed and [`choose`]
//! answers `failed`.

const std = @import("std");
const build_options = @import("build_options");
const invoke = @import("../../render/webview/invoke.zig");
const grants = @import("../grants.zig");
const shared = @import("../linux/portal.zig");

pub const available = build_options.have_webview2 and !build_options.native_render;

pub const Mode = shared.Mode;
pub const Filter = shared.Filter;
pub const Options = shared.Options;
pub const Outcome = shared.Outcome;

const c = if (available) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("shobjidl.h");
}) else struct {};

/// One dialog asked for and not yet answered. Its text is copied here: the page's
/// argument is gone once the command returns, and the dialog is shown after that.
const Pending = struct {
    later: ?invoke.Later = null,
    timer: usize = 0,
    mode: Mode = .open,
    multiple: bool = false,
    directory: bool = false,
    text: [8192]u8 = undefined,
    used: usize = 0,
    title: Span = .{},
    accept_label: Span = .{},
    current_name: Span = .{},
    current_folder: Span = .{},
    /// Each filter's name, and its patterns joined by `;` as the shell wants them.
    filter_names: [16]Span = undefined,
    filter_patterns: [16]Span = undefined,
    filter_count: usize = 0,
    grant_to: [256]u8 = undefined,
    grant_to_len: usize = 0,

    const Span = struct { start: usize = 0, len: usize = 0 };

    fn keep(slot: *Pending, parts: []const []const u8, joiner: []const u8) error{TooLarge}!Span {
        const begin = slot.used;
        for (parts, 0..) |part, index| {
            const extra = part.len + if (index > 0) joiner.len else 0;
            if (slot.used + extra > slot.text.len) return error.TooLarge;
            if (index > 0) {
                @memcpy(slot.text[slot.used..][0..joiner.len], joiner);
                slot.used += joiner.len;
            }
            @memcpy(slot.text[slot.used..][0..part.len], part);
            slot.used += part.len;
        }
        return .{ .start = begin, .len = slot.used - begin };
    }

    fn get(slot: *const Pending, span: Span) []const u8 {
        return slot.text[span.start..][0..span.len];
    }
};

var pending: [8]Pending = @splat(.{});

/// Opens the shell's file dialog and answers `later` when the user is done: `ok` with
/// an [`Outcome`] byte and the chosen paths. Answers at once with `failed` when it cannot.
pub fn choose(options: Options, later: invoke.Later) void {
    if (comptime !available) return later.finish(.failed, &.{});
    start(options, later) catch later.finish(.failed, &.{});
}

fn start(options: Options, later: invoke.Later) error{ Unavailable, TooLarge }!void {
    const slot = for (&pending) |*candidate| {
        if (candidate.later == null) break candidate;
    } else return error.Unavailable;
    slot.* = .{ .mode = options.mode, .multiple = options.multiple, .directory = options.directory };
    errdefer slot.* = .{};
    slot.title = try slot.keep(&.{options.title}, "");
    slot.accept_label = try slot.keep(&.{options.accept_label}, "");
    slot.current_name = try slot.keep(&.{options.current_name}, "");
    slot.current_folder = try slot.keep(&.{options.current_folder}, "");
    if (options.filters.len > slot.filter_names.len) return error.TooLarge;
    for (options.filters, 0..) |filter, index| {
        slot.filter_names[index] = try slot.keep(&.{filter.name}, "");
        slot.filter_patterns[index] = try slot.keep(filter.patterns, ";");
    }
    slot.filter_count = options.filters.len;
    const grant_len = @min(options.grant_to.len, slot.grant_to.len);
    @memcpy(slot.grant_to[0..grant_len], options.grant_to[0..grant_len]);
    slot.grant_to_len = grant_len;
    slot.timer = c.SetTimer(null, 0, 0, &onTimer);
    if (slot.timer == 0) return error.Unavailable;
    slot.later = later;
}

fn onTimer(_: c.HWND, _: c.UINT, id: c.UINT_PTR, _: c.DWORD) callconv(.winapi) void {
    _ = c.KillTimer(null, id);
    for (&pending) |*slot| {
        if (slot.later == null or slot.timer != id) continue;
        show(slot);
        return;
    }
}

const clsid_file_open_dialog = guid(0xDC1C5A9C, 0xE88A, 0x4DDE, .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 });
const clsid_file_save_dialog = guid(0xC0B4E2F3, 0xBA21, 0x4773, .{ 0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B });
const iid_file_open_dialog = guid(0xD57C7288, 0xD4AD, 0x4768, .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 });
const iid_file_save_dialog = guid(0x84BCCD23, 0x5FDE, 0x4CDB, .{ 0xAE, 0xA4, 0xAF, 0x64, 0xB8, 0x3D, 0x78, 0xAB });
const iid_shell_item = guid(0x43826D1E, 0xE718, 0x42EE, .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE });

fn guid(a: u32, b: u16, d: u16, e: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = d, .Data4 = e };
}

const fos_overwrite_prompt = 0x2;
const fos_no_change_dir = 0x8;
const fos_pick_folders = 0x20;
const fos_force_file_system = 0x40;
const fos_allow_multiselect = 0x200;
const fos_path_must_exist = 0x800;
const fos_file_must_exist = 0x1000;
const sigdn_file_sys_path: c.SIGDN = @bitCast(@as(u32, 0x80058000));
/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`: the user closed the dialog.
const hresult_cancelled: c.HRESULT = @bitCast(@as(u32, 0x800704C7));

/// UTF-8 to a NUL-ended UTF-16 string in `out`.
fn wide(text: []const u8, out: []u16) ?[*:0]const u16 {
    if (text.len >= out.len) return null;
    const len = std.unicode.utf8ToUtf16Le(out, text) catch return null;
    out[len] = 0;
    return out[0..len :0];
}

fn show(slot: *Pending) void {
    const outcome = if (slot.mode == .save) run(c.IFileSaveDialog, slot) else run(c.IFileOpenDialog, slot);
    if (outcome) |_| {} else |_| settle(slot, .failed, &.{});
}

/// The paths the user chose, each ended by a NUL, written by [`run`].
var chosen: [invoke.max_reply - 64]u8 = undefined;

fn run(comptime Dialog: type, slot: *Pending) error{Failed}!void {
    const save = Dialog == c.IFileSaveDialog;
    var dialog: ?*Dialog = null;
    if (c.CoCreateInstance(if (save) &clsid_file_save_dialog else &clsid_file_open_dialog, null, c.CLSCTX_INPROC_SERVER, if (save) &iid_file_save_dialog else &iid_file_open_dialog, @ptrCast(&dialog)) != c.S_OK) return error.Failed;
    const it = dialog orelse return error.Failed;
    defer _ = it.lpVtbl.*.Release.?(it);
    const v = it.lpVtbl.*;

    var flags: c.FILEOPENDIALOGOPTIONS = 0;
    _ = v.GetOptions.?(it, &flags);
    flags |= fos_force_file_system | fos_no_change_dir | fos_path_must_exist;
    if (save) flags |= fos_overwrite_prompt else flags |= fos_file_must_exist;
    if (slot.directory) flags |= fos_pick_folders;
    if (slot.multiple and !save) flags |= fos_allow_multiselect;
    _ = v.SetOptions.?(it, flags);

    var buffer: [1024]u16 = undefined;
    if (slot.title.len > 0) if (wide(slot.get(slot.title), &buffer)) |text| {
        _ = v.SetTitle.?(it, text);
    };
    if (slot.accept_label.len > 0) if (wide(slot.get(slot.accept_label), &buffer)) |text| {
        _ = v.SetOkButtonLabel.?(it, text);
    };
    if (slot.current_name.len > 0) if (wide(slot.get(slot.current_name), &buffer)) |text| {
        _ = v.SetFileName.?(it, text);
    };
    if (slot.current_folder.len > 0) if (wide(slot.get(slot.current_folder), &buffer)) |text| {
        var folder: ?*c.IShellItem = null;
        if (c.SHCreateItemFromParsingName(text, null, &iid_shell_item, @ptrCast(&folder)) == c.S_OK) {
            if (folder) |item| {
                _ = v.SetFolder.?(it, item);
                _ = item.lpVtbl.*.Release.?(item);
            }
        }
    };
    if (slot.filter_count > 0 and !slot.directory) {
        var names: [16][256]u16 = undefined;
        var patterns: [16][512]u16 = undefined;
        var specs: [16]c.COMDLG_FILTERSPEC = undefined;
        for (0..slot.filter_count) |index| {
            specs[index] = .{
                .pszName = wide(slot.get(slot.filter_names[index]), &names[index]) orelse return error.Failed,
                .pszSpec = wide(slot.get(slot.filter_patterns[index]), &patterns[index]) orelse return error.Failed,
            };
        }
        _ = v.SetFileTypes.?(it, @intCast(slot.filter_count), &specs);
    }

    const shown = v.Show.?(it, c.GetActiveWindow());
    if (shown == hresult_cancelled) return settle(slot, .cancelled, &.{});
    if (shown != c.S_OK) return error.Failed;

    var len: usize = 0;
    if (!save and slot.multiple) {
        var items: ?*c.IShellItemArray = null;
        if (v.GetResults.?(it, &items) != c.S_OK) return error.Failed;
        const array = items orelse return error.Failed;
        defer _ = array.lpVtbl.*.Release.?(array);
        var count: c.DWORD = 0;
        _ = array.lpVtbl.*.GetCount.?(array, &count);
        for (0..count) |index| {
            var item: ?*c.IShellItem = null;
            if (array.lpVtbl.*.GetItemAt.?(array, @intCast(index), &item) != c.S_OK) continue;
            const shell_item = item orelse continue;
            defer _ = shell_item.lpVtbl.*.Release.?(shell_item);
            len = try append(shell_item, len);
        }
    } else {
        var item: ?*c.IShellItem = null;
        if (v.GetResult.?(it, &item) != c.S_OK) return error.Failed;
        const shell_item = item orelse return error.Failed;
        defer _ = shell_item.lpVtbl.*.Release.?(shell_item);
        len = try append(shell_item, len);
    }
    settle(slot, .chosen, chosen[0..len]);
}

/// Adds the item's file system path to [`chosen`] after `len` bytes.
fn append(item: *c.IShellItem, len: usize) error{Failed}!usize {
    var name: c.LPWSTR = null;
    if (item.lpVtbl.*.GetDisplayName.?(item, sigdn_file_sys_path, &name) != c.S_OK) return error.Failed;
    defer c.CoTaskMemFree(name);
    const path = std.mem.span(@as([*:0]const u16, @ptrCast(name orelse return error.Failed)));
    if (len + path.len * 3 + 1 > chosen.len) return error.Failed;
    const written = std.unicode.wtf16LeToWtf8(chosen[len..], path);
    chosen[len + written] = 0;
    return len + written + 1;
}

/// Answers the page, granting what was chosen first so its first read already succeeds.
fn settle(slot: *Pending, outcome: Outcome, paths: []const u8) void {
    const later = slot.later orelse return;
    const grant_to_buffer = slot.grant_to;
    const grant_to = grant_to_buffer[0..slot.grant_to_len];
    const kind: grants.Kind = if (slot.directory) .directory else .file;
    slot.* = .{};
    var reply: [invoke.max_reply - 64]u8 = undefined;
    reply[0] = @intFromEnum(outcome);
    if (1 + paths.len > reply.len) return later.finish(.too_large, &.{});
    @memcpy(reply[1..][0..paths.len], paths);
    if (grant_to.len != 0) {
        var each = std.mem.splitScalar(u8, paths, 0);
        while (each.next()) |path| {
            if (path.len != 0) grants.add(grant_to, kind, path);
        }
    }
    later.finish(.ok, reply[0 .. 1 + paths.len]);
}

/// Nothing to close: a shell dialog is modal and ends with its loop.
pub fn closeAll() void {}

test "a request's text is kept in its slot, and too much is refused" {
    var slot: Pending = .{};
    const name = try slot.keep(&.{"Metin"}, "");
    const patterns = try slot.keep(&.{ "*.txt", "*.md" }, ";");
    try std.testing.expectEqualStrings("Metin", slot.get(name));
    try std.testing.expectEqualStrings("*.txt;*.md", slot.get(patterns));
    const huge = [_]u8{'a'} ** 9000;
    try std.testing.expectError(error.TooLarge, slot.keep(&.{&huge}, ""));
}
