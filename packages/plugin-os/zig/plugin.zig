//! `@lepton-desk/plugin-os`, the core side: one command per fact, each answering UTF-8.
//!
//! Compiled into the application by its build (`-Dplugins`, written by `lepton`); a page
//! may call a command only when the application lists it under `permissions`.

const core = @import("lepton_core");
const os = @import("os.zig");

const Registry = core.webviewRegistry;

pub const commands = [_]Registry.PluginCommand{
    .{ .name = "os.platform", .run = &platform },
    .{ .name = "os.arch", .run = &arch },
    .{ .name = "os.family", .run = &family },
    .{ .name = "os.version", .run = &version },
    .{ .name = "os.hostname", .run = &hostname },
    .{ .name = "os.locale", .run = &locale },
    .{ .name = "os.exe_extension", .run = &exeExtension },
};

/// The host name often carries the user's name.
pub const private = .{"os.hostname"};

fn text(value: []const u8, out: []u8) Registry.HandlerError!usize {
    if (value.len > out.len) return error.TooLarge;
    @memcpy(out[0..value.len], value);
    return value.len;
}

fn platform(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return text(os.platform(), out);
}

fn arch(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return text(os.arch(), out);
}

fn family(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return text(os.family(), out);
}

fn exeExtension(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return text(os.exeExtension(), out);
}

fn version(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return (os.version(out) catch return error.TooLarge).len;
}

fn hostname(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return (os.hostname(out) catch return error.TooLarge).len;
}

fn locale(_: []const u8, out: []u8) Registry.HandlerError!usize {
    return (os.locale(out) catch return error.TooLarge).len;
}
