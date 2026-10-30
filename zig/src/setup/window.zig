//! The compact window: the application's icon, its name and version, one line on what
//! will happen, a progress bar while it happens, and two buttons. Plain Win32 controls in
//! the system's message font, themed by Common Controls 6 (`setup.manifest`), laid out
//! again when the window moves to a monitor of another DPI.
//!
//! The work runs on a thread of its own and posts its progress here; the window stays
//! responsive and Cancel is read between files.

const std = @import("std");
const payload = @import("payload.zig");
const install = @import("install.zig");
const text = @import("text.zig");
const win = @import("win.zig");
const c = win.c;
const W = win.W;

pub const Mode = enum { install, uninstall };

const Phase = enum { ready, working, done, failed, refused };

const progress_message = c.WM_APP + 1;
const finished_message = c.WM_APP + 2;

const id_primary = 1; // IDOK: Enter
const id_secondary = 2; // IDCANCEL: Esc
const id_check = 3;

var mode: Mode = .install;
var language: text.Language = .english;
var job: ?*const install.Plan = null;
var installed_dir: win.Path = .{};
var installed: payload.Manifest = .{};
var phase: Phase = .ready;
var outcome: ?install.Error = null;
var cancelled: std.atomic.Value(bool) = .init(false);
var close_when_done = false;
var permille: usize = 0;

var window: c.HWND = null;
var icon_control: c.HWND = null;
var heading: c.HWND = null;
var detail: c.HWND = null;
var check: c.HWND = null;
var bar: c.HWND = null;
var primary: c.HWND = null;
var secondary: c.HWND = null;
var font: c.HFONT = null;
var heading_font: c.HFONT = null;
var app_icon: c.HICON = null;
var icon_bytes: []const u8 = &.{};

extern "user32" fn GetDpiForWindow(window: c.HWND) callconv(.winapi) c.UINT;
extern "user32" fn GetDpiForSystem() callconv(.winapi) c.UINT;
extern "user32" fn SystemParametersInfoForDpi(action: c.UINT, param: c.UINT, value: ?*anyopaque, ini: c.UINT, dpi: c.UINT) callconv(.winapi) c.BOOL;
extern "user32" fn AdjustWindowRectExForDpi(rect: *c.RECT, style: c.DWORD, menu: c.BOOL, ex: c.DWORD, dpi: c.UINT) callconv(.winapi) c.BOOL;
// Resource ids and stock cursors are small integers, which no Zig pointer may hold.
extern "user32" fn LoadImageW(instance: c.HINSTANCE, id: usize, kind: c.UINT, width: c_int, height: c_int, flags: c.UINT) callconv(.winapi) c.HANDLE;
extern "user32" fn LoadCursorW(instance: c.HINSTANCE, id: usize) callconv(.winapi) c.HCURSOR;
extern "user32" fn CreateWindowExW(ex: c.DWORD, class: [*:0]const u16, name: ?[*:0]const u16, style: c.DWORD, x: c_int, y: c_int, w: c_int, h: c_int, parent: c.HWND, menu: usize, instance: c.HINSTANCE, param: ?*anyopaque) callconv(.winapi) c.HWND;

/// Shows the install window for `plan`; returns the exit code.
pub fn runInstall(plan: *const install.Plan, lang: text.Language) u8 {
    mode = .install;
    job = plan;
    language = lang;
    if (plan.manifest.icon.len > 0) if (plan.archive.find(plan.manifest.icon) catch null) |entry| {
        if (std.heap.page_allocator.alloc(u8, entry.size)) |bytes| {
            if (entry.unpack(bytes)) icon_bytes = bytes else |_| {}
        } else |_| {}
    };
    phase = switch (plan.state) {
        .fresh, .upgrade, .same => .ready,
        .newer, .foreign => .refused,
    };
    return run();
}

/// Shows the uninstall window for what `dir` holds; returns the exit code.
pub fn runUninstall(dir: *const win.Path, manifest: payload.Manifest, lang: text.Language) u8 {
    mode = .uninstall;
    installed_dir = dir.*;
    installed = manifest;
    language = lang;
    if (manifest.icon.len > 0) {
        const path = dir.join(manifest.icon) catch null;
        if (path) |*icon| if (std.heap.page_allocator.alloc(u8, 1024 * 1024)) |buffer| {
            if (win.readFile(icon, buffer)) |bytes| icon_bytes = bytes else |_| {}
        } else |_| {};
    }
    return run();
}

fn run() u8 {
    const instance = c.GetModuleHandleW(null);
    var controls: c.INITCOMMONCONTROLSEX = .{ .dwSize = @sizeOf(c.INITCOMMONCONTROLSEX), .dwICC = c.ICC_PROGRESS_CLASS | c.ICC_STANDARD_CLASSES };
    _ = c.InitCommonControlsEx(&controls);

    const class_name = W("LeptonSetup");
    const class: c.WNDCLASSEXW = .{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = procedure,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = LoadCursorW(null, 32512),
        .hbrBackground = c.GetSysColorBrush(c.COLOR_WINDOW),
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (c.RegisterClassExW(&class) == 0) return 1;

    var title: [512]u16 = undefined;
    const caption = format(&title, if (mode == .install) .setup_title else .uninstall_title);
    const dpi = GetDpiForSystem();
    var rect = clientRect(dpi);
    _ = AdjustWindowRectExForDpi(&rect, style, c.FALSE, 0, dpi);
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    var area: c.RECT = undefined;
    _ = c.SystemParametersInfoW(c.SPI_GETWORKAREA, 0, &area, 0);
    window = CreateWindowExW(0, class_name, caption.ptr, style, area.left + @divTrunc(area.right - area.left - width, 2), area.top + @divTrunc(area.bottom - area.top - height, 2), width, height, null, 0, instance, null);
    if (window == null) return 1;

    const child = c.WS_CHILD | c.WS_VISIBLE;
    icon_control = CreateWindowExW(0, W("STATIC"), null, child | c.SS_ICON | c.SS_REALSIZECONTROL, 0, 0, 0, 0, window, 0, instance, null);
    heading = CreateWindowExW(0, W("STATIC"), null, child | c.SS_NOPREFIX | c.SS_ENDELLIPSIS, 0, 0, 0, 0, window, 0, instance, null);
    detail = CreateWindowExW(0, W("STATIC"), null, child | c.SS_NOPREFIX, 0, 0, 0, 0, window, 0, instance, null);
    bar = CreateWindowExW(0, W("msctls_progress32"), null, c.WS_CHILD, 0, 0, 0, 0, window, 0, instance, null);
    _ = c.SendMessageW(bar, c.PBM_SETRANGE32, 0, 1000);
    if (mode == .uninstall) {
        check = CreateWindowExW(0, W("BUTTON"), null, child | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, 0, 0, 0, 0, window, id_check, instance, null);
    }
    primary = CreateWindowExW(0, W("BUTTON"), null, child | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, 0, 0, 0, 0, window, id_primary, instance, null);
    secondary = CreateWindowExW(0, W("BUTTON"), null, child | c.WS_TABSTOP | c.BS_PUSHBUTTON, 0, 0, 0, 0, window, id_secondary, instance, null);

    layout();
    show();
    _ = c.ShowWindow(window, c.SW_SHOWNORMAL);
    _ = c.SetFocus(if (c.IsWindowEnabled(primary) != 0 and c.IsWindowVisible(primary) != 0) primary else secondary);

    var message: c.MSG = undefined;
    while (c.GetMessageW(&message, null, 0, 0) > 0) {
        if (c.IsDialogMessageW(window, &message) != 0) continue;
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }
    return if (phase == .done) 0 else 1;
}

const style: c.DWORD = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;

/// The client area at 96 DPI, scaled.
fn clientRect(dpi: c.UINT) c.RECT {
    return .{ .left = 0, .top = 0, .right = scale(460, dpi), .bottom = scale(176, dpi) };
}

fn scale(value: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, value) * dpi + 48, 96));
}

/// Fonts, icon and positions for the window's DPI.
fn layout() void {
    const dpi = GetDpiForWindow(window);
    var metrics: c.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(c.NONCLIENTMETRICSW);
    if (SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, metrics.cbSize, &metrics, 0, dpi) != 0) {
        if (font != null) _ = c.DeleteObject(font);
        if (heading_font != null) _ = c.DeleteObject(heading_font);
        font = c.CreateFontIndirectW(&metrics.lfMessageFont);
        var big = metrics.lfMessageFont;
        big.lfHeight = @divTrunc(big.lfHeight * 4, 3);
        big.lfWeight = c.FW_SEMIBOLD;
        heading_font = c.CreateFontIndirectW(&big);
    }
    for ([_]c.HWND{ detail, bar, check, primary, secondary }) |control| {
        if (control != null) _ = c.SendMessageW(control, c.WM_SETFONT, @intFromPtr(font), c.TRUE);
    }
    _ = c.SendMessageW(heading, c.WM_SETFONT, @intFromPtr(heading_font), c.TRUE);

    const side = scale(48, dpi);
    if (app_icon != null) _ = c.DestroyIcon(app_icon);
    app_icon = loadIcon(side);
    _ = c.SendMessageW(icon_control, c.STM_SETICON, @intFromPtr(app_icon), 0);
    _ = c.SendMessageW(window, c.WM_SETICON, c.ICON_BIG, @bitCast(@intFromPtr(loadIcon(scale(32, dpi)))));
    _ = c.SendMessageW(window, c.WM_SETICON, c.ICON_SMALL, @bitCast(@intFromPtr(loadIcon(scale(16, dpi)))));

    const client = clientRect(dpi);
    const margin = scale(20, dpi);
    const left = margin + side + scale(16, dpi);
    const width = client.right - left - margin;
    const button_w = scale(96, dpi);
    const button_h = scale(30, dpi);
    const button_y = client.bottom - margin - button_h;
    place(icon_control, margin, margin, side, side);
    place(heading, left, margin, width, scale(26, dpi));
    place(detail, left, margin + scale(30, dpi), width, scale(48, dpi));
    place(bar, left, margin + scale(84, dpi), width, scale(14, dpi));
    if (check != null) place(check, left, margin + scale(80, dpi), width, scale(22, dpi));
    place(secondary, client.right - margin - button_w, button_y, button_w, button_h);
    place(primary, client.right - margin - 2 * button_w - scale(10, dpi), button_y, button_w, button_h);
}

fn place(control: c.HWND, x: c_int, y: c_int, w: c_int, h: c_int) void {
    _ = c.SetWindowPos(control, null, x, y, w, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The application's icon at `side` pixels, else this program's own (resource 1).
fn loadIcon(side: c_int) c.HICON {
    if (payload.iconImage(icon_bytes, @intCast(side))) |image| {
        const made = c.CreateIconFromResourceEx(@constCast(image.ptr), @intCast(image.len), c.TRUE, 0x00030000, side, side, c.LR_DEFAULTCOLOR);
        if (made != null) return made;
    }
    return @ptrCast(@alignCast(LoadImageW(c.GetModuleHandleW(null), 1, c.IMAGE_ICON, side, side, 0)));
}

/// The texts and buttons for the phase.
fn show() void {
    var buffer: [1024]u16 = undefined;
    var version: [64]u16 = undefined;
    const manifest = if (mode == .install) job.?.manifest else installed;
    var name: [256]u16 = undefined;
    const product = win.wide(&name, manifest.product) catch W("");
    const title = win.concat(&buffer, &.{ product, W(" "), win.wide(&version, manifest.version) catch W("") }) catch W("");
    _ = c.SetWindowTextW(heading, title.ptr);

    const line: text.Id = switch (phase) {
        .ready => if (mode == .uninstall) .uninstall_ask else switch (job.?.state) {
            .fresh => .fresh,
            .upgrade => .upgrade,
            .same => .same,
            .newer => .newer,
            .foreign => .foreign,
        },
        .refused => if (job.?.state == .newer) .newer else .foreign,
        .working => if (mode == .install) .installing else .removing,
        .done => if (mode == .install) .installed else .removed,
        .failed => failure(),
    };
    _ = c.SetWindowTextW(detail, format(&buffer, line).ptr);

    _ = c.ShowWindow(bar, if (phase == .working) c.SW_SHOW else c.SW_HIDE);
    if (check != null) {
        _ = c.SetWindowTextW(check, format(&buffer, .remove_data).ptr);
        _ = c.ShowWindow(check, if (phase == .ready) c.SW_SHOW else c.SW_HIDE);
    }

    const first: ?text.Id = switch (phase) {
        .ready => if (mode == .uninstall) .remove else switch (job.?.state) {
            .fresh => .install,
            .upgrade => .update,
            .same => .reinstall,
            .newer, .foreign => null,
        },
        .done => if (mode == .install) .open else null,
        .working, .failed, .refused => null,
    };
    if (first) |id| _ = c.SetWindowTextW(primary, format(&buffer, id).ptr);
    _ = c.ShowWindow(primary, if (first != null) c.SW_SHOW else c.SW_HIDE);
    const second: text.Id = switch (phase) {
        .ready, .working => .cancel,
        .done, .failed, .refused => .close,
    };
    _ = c.SetWindowTextW(secondary, format(&buffer, second).ptr);
    // Removing is not stopped half way: Cancel waits until it is done.
    _ = c.EnableWindow(secondary, @intFromBool(!(phase == .working and mode == .uninstall)));
    if (first == null) _ = c.SendMessageW(secondary, c.BM_SETSTYLE, c.BS_DEFPUSHBUTTON, c.TRUE);
}

fn failure() text.Id {
    const err = outcome orelse return if (mode == .install) .install_failed else .remove_failed;
    return switch (err) {
        error.InUse => .in_use,
        error.CrcMismatch, error.Damaged, error.NoArchive, error.BadName, error.Unsupported, error.NoManifest, error.BadManifest => .damaged,
        else => if (mode == .install) .install_failed else .remove_failed,
    };
}

/// `id` with the job's values.
fn format(out: []u16, id: text.Id) [:0]const u16 {
    const manifest = if (mode == .install) job.?.manifest else installed;
    var names: [4][1024]u16 = undefined;
    var error_text: [512]u16 = undefined;
    const dir = if (mode == .install) job.?.dir.plain() else installed_dir.plain();
    return text.format(out, language, id, .{
        .p = win.wide(&names[0], manifest.product) catch &.{},
        .v = win.wide(&names[1], manifest.version) catch &.{},
        .o = if (mode == .install) (win.wide(&names[2], job.?.installedVersion()) catch &.{}) else &.{},
        .d = dir,
        .e = win.errorText(win.last_error, &error_text),
    });
}

fn start() void {
    phase = .working;
    permille = 0;
    _ = c.SendMessageW(bar, c.PBM_SETPOS, 0, 0);
    const remove_data = check != null and c.SendMessageW(check, c.BM_GETCHECK, 0, 0) == c.BST_CHECKED;
    show();
    const thread = std.Thread.spawn(.{}, work, .{remove_data}) catch {
        outcome = error.OutOfMemory;
        phase = .failed;
        show();
        return;
    };
    thread.detach();
}

fn work(remove_data: bool) void {
    const progress: install.Progress = .{ .step = step, .cancelled = &cancelled };
    const result = switch (mode) {
        .install => install.install(job.?, progress),
        .uninstall => install.uninstall(&installed_dir, installed, remove_data, progress),
    };
    outcome = if (result) |_| null else |err| err;
    _ = c.PostMessageW(window, finished_message, 0, 0);
}

fn step(_: ?*anyopaque, done: u64, total: u64) void {
    const now: usize = if (total == 0) 1000 else @intCast(@min(1000, done * 1000 / total));
    if (now == permille) return;
    permille = now;
    _ = c.PostMessageW(window, progress_message, now, 0);
}

fn procedure(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_COMMAND => {
            const id = wparam & 0xffff;
            if (id == id_primary and c.IsWindowVisible(primary) != 0) {
                switch (phase) {
                    .ready => start(),
                    .done => {
                        openProgram();
                        _ = c.DestroyWindow(hwnd);
                    },
                    else => {},
                }
                return 0;
            }
            if (id == id_secondary) {
                if (phase == .working) {
                    if (mode == .install) {
                        cancelled.store(true, .release);
                        close_when_done = true;
                    }
                } else _ = c.DestroyWindow(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            if (phase == .working) {
                if (mode == .install) cancelled.store(true, .release);
                close_when_done = true;
                return 0;
            }
        },
        progress_message => {
            _ = c.SendMessageW(bar, c.PBM_SETPOS, wparam, 0);
            return 0;
        },
        finished_message => {
            if (outcome) |err| {
                phase = .failed;
                if (err == error.Cancelled) close_when_done = true;
            } else phase = .done;
            if (close_when_done) {
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
            show();
            _ = c.SetFocus(if (c.IsWindowVisible(primary) != 0) primary else secondary);
            return 0;
        },
        c.WM_CTLCOLORSTATIC, c.WM_CTLCOLORBTN => {
            _ = c.SetBkMode(@ptrFromInt(wparam), c.TRANSPARENT);
            return @bitCast(@intFromPtr(c.GetSysColorBrush(c.COLOR_WINDOW)));
        },
        c.WM_DPICHANGED => {
            const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            layout();
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn openProgram() void {
    const plan = job orelse return;
    const program = plan.dir.join(plan.manifest.program) catch return;
    _ = c.ShellExecuteW(null, W("open"), program.plain().ptr, null, plan.dir.plain().ptr, c.SW_SHOWNORMAL);
}
