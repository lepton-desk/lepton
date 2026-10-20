//! Opens a real Win32 window, puts WebView2 in it, loads a page and reports what reached it.
//!
//! The probe before any Windows backend: it measures, on this machine, the whole path a
//! Lepton window will take — STA COM, the installed runtime found without Microsoft's
//! loader, the environment, the controller, a navigation, a script round trip and a
//! captured frame written as a PNG. Each stage prints how long it took; a stage that fails
//! prints its HRESULT and the probe exits 1. Nothing here is imported by the core.
//!
//! The loader: `WebView2Loader.dll` is not shipped. The runtime directory is the
//! `EBWebView` value under `SOFTWARE\Microsoft\EdgeUpdate\ClientState\{F3017226-…}` (the
//! stable channel, 32-bit registry view, HKLM then HKCU), and its
//! `EBWebView\x64\EmbeddedBrowserWebView.dll` exports
//! `CreateWebViewEnvironmentWithOptionsInternal` (measured on 155.0.4283.62).
//!
//! Run with `zig build webview2-check` (Windows only).

const std = @import("std");

const c = @import("c_webview2_check");

const W = std.unicode.utf8ToUtf16LeStringLiteral;

const timeout_ms = 20_000;
const client_state = W("SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}");

/// What the page shows and what the script reads back: a title, a colour block and the
/// viewport, so the captured PNG can be checked by eye and the script result by text.
const page = page: {
    @setEvalBranchQuota(20_000);
    break :page W(
        \\<!doctype html><html><head><meta charset="utf-8"><title>lepton-webview2-check</title>
        \\<style>html,body{margin:0;height:100%;font:24px system-ui;background:#101418;color:#e8e6e3}
        \\#mark{background:#2f81f7;color:#fff;padding:32px}</style></head>
        \\<body><div id="mark">Lepton WebView2 check</div><p id="size"></p>
        \\<script>document.getElementById('size').textContent=innerWidth+'x'+innerHeight</script></body></html>
    );
};
const script = W("document.title + '|' + innerWidth + 'x' + innerHeight + '|' + navigator.userAgent");

/// `CreateWebViewEnvironmentWithOptionsInternal`: the first argument is always `true` in
/// the open-source loaders, the second is the runtime kind (0 = installed, 1 = embedded).
const CreateInternal = *const fn (
    bool,
    c_int,
    ?[*:0]const u16,
    ?*c.IUnknown,
    ?*c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
) callconv(.winapi) c.HRESULT;

const Probe = struct {
    window: c.HWND = null,
    started: u64 = 0,
    environment: ?*c.ICoreWebView2Environment = null,
    controller: ?*c.ICoreWebView2Controller = null,
    view: ?*c.ICoreWebView2 = null,
    stream: ?*c.IStream = null,
    capture_path: [c.MAX_PATH:0]u16 = undefined,
    failed: bool = false,
};

var probe: Probe = .{};

var out_buffer: [4096]u8 = undefined;
var out_writer: std.Io.File.Writer = undefined;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn say(comptime fmt: []const u8, args: anytype) void {
    out_writer.interface.print(fmt ++ "\n", args) catch {};
    out_writer.interface.flush() catch {};
}

fn elapsed() u64 {
    return c.GetTickCount64() - probe.started;
}

/// Prints a failed stage and ends the message loop with a failure.
fn fail(stage: []const u8, hr: c.HRESULT) void {
    say("{s:<13}failed, HRESULT 0x{x:0>8}", .{ stage, @as(u32, @bitCast(hr)) });
    probe.failed = true;
    c.PostQuitMessage(1);
}

fn utf8(text: [*:0]const u16, buffer: []u8) []const u8 {
    const len = std.unicode.utf16LeToUtf8(buffer, std.mem.sliceTo(text, 0)) catch return "(not UTF-16)";
    return buffer[0..len];
}

// --- the runtime, found without WebView2Loader.dll ---------------------------------------

/// The predefined roots are pseudo-handles (`0x80000001`, `0x80000002`) that no aligned
/// `HKEY` can hold — translate-c refuses them — so `RegGetValueW` is declared here with the
/// root as the pointer-sized integer it is. The other parameters keep WebView2.h's types.
extern "advapi32" fn RegGetValueW(
    root: usize,
    sub_key: c.LPCWSTR,
    value: c.LPCWSTR,
    flags: c.DWORD,
    kind: ?*c.DWORD,
    data: ?*anyopaque,
    size: ?*c.DWORD,
) callconv(.winapi) c.LSTATUS;

const hkey_current_user: usize = 0x80000001;
const hkey_local_machine: usize = 0x80000002;

fn runtimeDirectory(buffer: *[c.MAX_PATH]u16) ?[]const u16 {
    for ([_]usize{ hkey_local_machine, hkey_current_user }) |root| {
        var size: c.DWORD = @sizeOf(@TypeOf(buffer.*));
        const status = RegGetValueW(
            root,
            client_state,
            W("EBWebView"),
            c.RRF_RT_REG_SZ | c.RRF_SUBKEY_WOW6432KEY,
            null,
            buffer,
            &size,
        );
        if (status == c.ERROR_SUCCESS and size > 2) return buffer[0 .. size / 2 - 1];
    }
    return null;
}

fn loadCreateInternal(directory: []const u16) ?CreateInternal {
    const tail = W("\\EBWebView\\x64\\EmbeddedBrowserWebView.dll");
    var path: [c.MAX_PATH:0]u16 = undefined;
    if (directory.len + tail.len >= path.len) return null;
    @memcpy(path[0..directory.len], directory);
    @memcpy(path[directory.len..][0..tail.len], tail);
    path[directory.len + tail.len] = 0;
    const library = c.LoadLibraryW(&path) orelse return null;
    const symbol = c.GetProcAddress(library, "CreateWebViewEnvironmentWithOptionsInternal") orelse return null;
    return @ptrCast(symbol);
}

// --- COM handlers: one static object per callback, vtables typed by WebView2.h -----------

/// IUnknown for a handler that lives for the whole process: no counting, no freeing.
fn Unknown(comptime Interface: type, comptime iid: *const c.IID) type {
    return struct {
        fn queryInterface(self: [*c]Interface, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.winapi) c.HRESULT {
            const asked: *const c.IID = riid;
            const wanted = std.mem.asBytes(asked);
            if (std.mem.eql(u8, wanted, std.mem.asBytes(iid)) or
                std.mem.eql(u8, wanted, std.mem.asBytes(&c.IID_IUnknown)))
            {
                out.* = @ptrCast(self);
                return c.S_OK;
            }
            out.* = null;
            return c.E_NOINTERFACE;
        }
        fn addRef(_: [*c]Interface) callconv(.winapi) c.ULONG {
            return 1;
        }
        fn release(_: [*c]Interface) callconv(.winapi) c.ULONG {
            return 1;
        }
    };
}

const EnvironmentDone = Unknown(c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, &c.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler);
const environment_vtbl: c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandlerVtbl = .{
    .QueryInterface = EnvironmentDone.queryInterface,
    .AddRef = EnvironmentDone.addRef,
    .Release = EnvironmentDone.release,
    .Invoke = environmentReady,
};
var environment_done: c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = .{ .lpVtbl = @constCast(&environment_vtbl) };

const ControllerDone = Unknown(c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, &c.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
const controller_vtbl: c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandlerVtbl = .{
    .QueryInterface = ControllerDone.queryInterface,
    .AddRef = ControllerDone.addRef,
    .Release = ControllerDone.release,
    .Invoke = controllerReady,
};
var controller_done: c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = .{ .lpVtbl = @constCast(&controller_vtbl) };

const NavigationDone = Unknown(c.ICoreWebView2NavigationCompletedEventHandler, &c.IID_ICoreWebView2NavigationCompletedEventHandler);
const navigation_vtbl: c.ICoreWebView2NavigationCompletedEventHandlerVtbl = .{
    .QueryInterface = NavigationDone.queryInterface,
    .AddRef = NavigationDone.addRef,
    .Release = NavigationDone.release,
    .Invoke = navigationCompleted,
};
var navigation_done: c.ICoreWebView2NavigationCompletedEventHandler = .{ .lpVtbl = @constCast(&navigation_vtbl) };

const ScriptDone = Unknown(c.ICoreWebView2ExecuteScriptCompletedHandler, &c.IID_ICoreWebView2ExecuteScriptCompletedHandler);
const script_vtbl: c.ICoreWebView2ExecuteScriptCompletedHandlerVtbl = .{
    .QueryInterface = ScriptDone.queryInterface,
    .AddRef = ScriptDone.addRef,
    .Release = ScriptDone.release,
    .Invoke = scriptCompleted,
};
var script_done: c.ICoreWebView2ExecuteScriptCompletedHandler = .{ .lpVtbl = @constCast(&script_vtbl) };

const CaptureDone = Unknown(c.ICoreWebView2CapturePreviewCompletedHandler, &c.IID_ICoreWebView2CapturePreviewCompletedHandler);
const capture_vtbl: c.ICoreWebView2CapturePreviewCompletedHandlerVtbl = .{
    .QueryInterface = CaptureDone.queryInterface,
    .AddRef = CaptureDone.addRef,
    .Release = CaptureDone.release,
    .Invoke = captureCompleted,
};
var capture_done: c.ICoreWebView2CapturePreviewCompletedHandler = .{ .lpVtbl = @constCast(&capture_vtbl) };

// --- the stages, in the order WebView2 calls them back ------------------------------------

fn environmentReady(
    _: [*c]c.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
    hr: c.HRESULT,
    environment: [*c]c.ICoreWebView2Environment,
) callconv(.winapi) c.HRESULT {
    if (hr != c.S_OK or environment == null) {
        fail("environment", hr);
        return c.S_OK;
    }
    say("environment  {d} ms", .{elapsed()});
    _ = environment.*.lpVtbl.*.AddRef.?(environment);
    probe.environment = environment;
    const created = environment.*.lpVtbl.*.CreateCoreWebView2Controller.?(environment, probe.window, &controller_done);
    if (created != c.S_OK) fail("controller", created);
    return c.S_OK;
}

fn controllerReady(
    _: [*c]c.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
    hr: c.HRESULT,
    controller: [*c]c.ICoreWebView2Controller,
) callconv(.winapi) c.HRESULT {
    if (hr != c.S_OK or controller == null) {
        fail("controller", hr);
        return c.S_OK;
    }
    say("controller   {d} ms", .{elapsed()});
    _ = controller.*.lpVtbl.*.AddRef.?(controller);
    probe.controller = controller;
    fitToWindow();

    var view: [*c]c.ICoreWebView2 = null;
    const got = controller.*.lpVtbl.*.get_CoreWebView2.?(controller, &view);
    if (got != c.S_OK or view == null) {
        fail("webview", got);
        return c.S_OK;
    }
    probe.view = view;

    var token: c.EventRegistrationToken = undefined;
    const added = view.*.lpVtbl.*.add_NavigationCompleted.?(view, &navigation_done, &token);
    if (added != c.S_OK) {
        fail("subscribe", added);
        return c.S_OK;
    }
    const navigated = view.*.lpVtbl.*.NavigateToString.?(view, page);
    if (navigated != c.S_OK) fail("navigate", navigated);
    return c.S_OK;
}

fn navigationCompleted(
    _: [*c]c.ICoreWebView2NavigationCompletedEventHandler,
    sender: [*c]c.ICoreWebView2,
    args: [*c]c.ICoreWebView2NavigationCompletedEventArgs,
) callconv(.winapi) c.HRESULT {
    var success: c.BOOL = 0;
    _ = args.*.lpVtbl.*.get_IsSuccess.?(args, &success);
    if (success == 0) {
        var status: c.COREWEBVIEW2_WEB_ERROR_STATUS = 0;
        _ = args.*.lpVtbl.*.get_WebErrorStatus.?(args, &status);
        say("navigation   failed, web error status {d}", .{status});
        probe.failed = true;
        c.PostQuitMessage(1);
        return c.S_OK;
    }
    say("navigation   {d} ms", .{elapsed()});
    const ran = sender.*.lpVtbl.*.ExecuteScript.?(sender, script, &script_done);
    if (ran != c.S_OK) fail("script", ran);
    return c.S_OK;
}

fn scriptCompleted(
    _: [*c]c.ICoreWebView2ExecuteScriptCompletedHandler,
    hr: c.HRESULT,
    result: c.LPCWSTR,
) callconv(.winapi) c.HRESULT {
    if (hr != c.S_OK or result == null) {
        fail("script", hr);
        return c.S_OK;
    }
    var text: [1024]u8 = undefined;
    say("script       {d} ms  {s}", .{ elapsed(), utf8(result, &text) });

    // A captured frame is the evidence pixels exist: the page composited, not just parsed.
    const view = probe.view orelse return c.S_OK;
    var stream: [*c]c.IStream = null;
    const opened = c.SHCreateStreamOnFileEx(&probe.capture_path, c.STGM_CREATE | c.STGM_WRITE, c.FILE_ATTRIBUTE_NORMAL, c.TRUE, null, &stream);
    if (opened != c.S_OK or stream == null) {
        fail("capture file", opened);
        return c.S_OK;
    }
    probe.stream = stream;
    const captured = view.*.lpVtbl.*.CapturePreview.?(view, c.COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream, &capture_done);
    if (captured != c.S_OK) fail("capture", captured);
    return c.S_OK;
}

fn captureCompleted(_: [*c]c.ICoreWebView2CapturePreviewCompletedHandler, hr: c.HRESULT) callconv(.winapi) c.HRESULT {
    if (probe.stream) |stream| {
        _ = stream.*.lpVtbl.*.Release.?(stream);
        probe.stream = null;
    }
    if (hr != c.S_OK) {
        fail("capture", hr);
        return c.S_OK;
    }
    var path: [c.MAX_PATH * 3]u8 = undefined;
    say("capture      {d} ms  {s}", .{ elapsed(), utf8(&probe.capture_path, &path) });
    c.PostQuitMessage(0);
    return c.S_OK;
}

// --- the window ---------------------------------------------------------------------------

fn fitToWindow() void {
    const controller = probe.controller orelse return;
    var rect: c.RECT = undefined;
    if (c.GetClientRect(probe.window, &rect) != 0) _ = controller.*.lpVtbl.*.put_Bounds.?(controller, rect);
}

fn windowProc(window: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_SIZE => fitToWindow(),
        c.WM_TIMER => {
            say("timeout      nothing finished within {d} ms", .{timeout_ms});
            probe.failed = true;
            c.PostQuitMessage(1);
        },
        c.WM_DESTROY => c.PostQuitMessage(if (probe.failed) 1 else 0),
        else => {},
    }
    return c.DefWindowProcW(window, message, wparam, lparam);
}

fn openWindow() bool {
    const instance = c.GetModuleHandleW(null);
    const class_name = W("LeptonWebView2Check");
    const class: c.WNDCLASSEXW = .{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, @ptrFromInt(32512)), // IDC_ARROW
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (c.RegisterClassExW(&class) == 0) return false;
    probe.window = c.CreateWindowExW(0, class_name, W("Lepton WebView2 check"), c.WS_OVERLAPPEDWINDOW, c.CW_USEDEFAULT, c.CW_USEDEFAULT, 900, 640, null, null, instance, null);
    if (probe.window == null) return false;
    _ = c.ShowWindow(probe.window, c.SW_SHOW);
    _ = c.SetTimer(probe.window, 1, timeout_ms, null);
    return true;
}

/// `%TEMP%\lepton-webview2-check\` + `name`; the user data folder and the capture live there.
fn tempPath(name: []const u16, into: *[c.MAX_PATH:0]u16) bool {
    const sub = W("lepton-webview2-check\\");
    const base = c.GetTempPathW(c.MAX_PATH, into);
    if (base == 0 or base + sub.len + name.len >= c.MAX_PATH) return false;
    @memcpy(into[base..][0..sub.len], sub);
    @memcpy(into[base + sub.len ..][0..name.len], name);
    into[base + sub.len + name.len] = 0;
    return true;
}

pub fn main() u8 {
    out_writer = std.Io.File.stdout().writer(io(), &out_buffer);
    probe.started = c.GetTickCount64();

    var version: [c.MAX_PATH]u16 = undefined;
    const directory = runtimeDirectory(&version) orelse {
        say("runtime      not installed (no EBWebView value under ClientState)", .{});
        return 1;
    };
    var text: [c.MAX_PATH * 3]u8 = undefined;
    say("runtime      {s}", .{utf8(@ptrCast(directory.ptr), &text)});
    const create = loadCreateInternal(directory) orelse {
        say("runtime      EmbeddedBrowserWebView.dll or its export is missing", .{});
        return 1;
    };

    const com = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    if (com != c.S_OK and com != c.S_FALSE) {
        fail("com", com);
        return 1;
    }
    defer c.CoUninitialize();

    if (!openWindow()) {
        say("window       could not be created (error {d})", .{c.GetLastError()});
        return 1;
    }
    say("window       {d} ms", .{elapsed()});

    var user_data: [c.MAX_PATH:0]u16 = undefined;
    if (!tempPath(W("data"), &user_data) or !tempPath(W("capture.png"), &probe.capture_path)) {
        say("paths        %TEMP% is too long", .{});
        return 1;
    }
    var folder: [c.MAX_PATH:0]u16 = undefined;
    if (tempPath(W(""), &folder)) _ = c.CreateDirectoryW(&folder, null);

    const started = create(true, 0, &user_data, null, &environment_done);
    if (started != c.S_OK) {
        fail("environment", started);
        return 1;
    }

    var message: c.MSG = undefined;
    while (c.GetMessageW(&message, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&message);
        _ = c.DispatchMessageW(&message);
    }

    var counters: c.PROCESS_MEMORY_COUNTERS = undefined;
    if (c.K32GetProcessMemoryInfo(c.GetCurrentProcess(), &counters, @sizeOf(c.PROCESS_MEMORY_COUNTERS)) != 0) {
        say("working set  {d} KiB (this process; the engine runs in msedgewebview2.exe children)", .{counters.WorkingSetSize / 1024});
    }
    if (probe.controller) |controller| _ = controller.*.lpVtbl.*.Close.?(controller);
    say("result       {s}", .{if (probe.failed) "failed" else "page loaded, script answered, frame captured"});
    return if (probe.failed) 1 else 0;
}
