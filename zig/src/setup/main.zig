//! setup.exe: a Lepton application's installer for Windows, without a web engine.
//!
//! The program is the same for every application. `lepton package` appends the
//! application as a zip (`payload.zig`), so this file is built once, here, and shipped as
//! `@lepton-desk/setup-windows-x64`. Started with that zip after it, it installs; without
//! one it is the `uninstall.exe` an install left in the program's folder, and it removes
//! what `.lepton-setup` beside it names.
//!
//! `/S` does either without a window. Exit codes: 0 done, 1 failed, 2 a newer version is
//! installed, 3 the folder holds something this setup did not install, 4 the program is
//! running, 5 this file is damaged, 6 cancelled.

const std = @import("std");
const install = @import("install.zig");
const payload = @import("payload.zig");
const text = @import("text.zig");
const win = @import("win.zig");
const window = @import("window.zig");
const c = win.c;
const W = win.W;

extern "shell32" fn CommandLineToArgvW(line: [*:0]const u16, count: *c_int) callconv(.winapi) ?[*][*:0]u16;

pub fn main() u8 {
    var silent = false;
    var count: c_int = 0;
    if (CommandLineToArgvW(c.GetCommandLineW(), &count)) |args| {
        defer _ = c.LocalFree(@ptrCast(args));
        for (args[1..@intCast(count)]) |arg| {
            const value = std.mem.span(arg);
            if (value.len == 2 and value[0] == '/' and (value[1] == 'S' or value[1] == 's')) silent = true;
        }
    }
    // LANG_TURKISH in the user's display language.
    const language: text.Language = if (c.GetUserDefaultUILanguage() & 0x3ff == 0x1f) .turkish else .english;

    const own = win.ownPath() catch return 5;
    const bytes = win.mapFile(&own) catch return 5;
    if (install.plan(bytes)) |plan| {
        if (!silent) return window.runInstall(&plan, language);
        install.install(&plan, .{}) catch |err| return code(err);
        return 0;
    } else |err| switch (err) {
        error.NoArchive => {},
        else => {
            if (!silent) message(language, .damaged);
            return 5;
        },
    }

    // `uninstall.exe`, in the folder it removes.
    const dir = own.parent();
    const manifest = install.readInstalled(&dir) orelse {
        if (!silent) message(language, .not_installed);
        return 1;
    };
    if (!silent) return window.runUninstall(&dir, manifest, language);
    install.uninstall(&dir, manifest, false, .{}) catch |err| return code(err);
    return 0;
}

fn code(err: install.Error) u8 {
    return switch (err) {
        error.Newer => 2,
        error.Foreign => 3,
        error.InUse => 4,
        error.CrcMismatch, error.Damaged, error.NoArchive, error.BadName, error.Unsupported, error.NoManifest, error.BadManifest => 5,
        error.Cancelled => 6,
        else => 1,
    };
}

/// A message box for what goes wrong before a window has anything to show.
fn message(language: text.Language, id: text.Id) void {
    var out: [512]u16 = undefined;
    const body = text.format(&out, language, id, .{ .p = W("") });
    _ = c.MessageBoxW(null, body.ptr, W("Setup"), c.MB_OK | c.MB_ICONERROR);
}
