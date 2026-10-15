//! Loading and keeping the Lepton display module resident.
//!
//! `wpe_display_get_default()` selects a display through a GIO extension point, and GIO
//! fills that point by `dlopen`-ing every module under `WPE_PLATFORMS_PATH`. Two things
//! must be arranged before the engine asks, and neither is the engine's job:
//!
//! 1. **Selection.** `WPE_PLATFORM=lepton` names this framework's implementation. It has
//!    to be set before anything calls `wpe_display_get_default()`, because the extension
//!    list is loaded and then cached behind a one-shot flag.
//!
//! 2. **Residency.** GIO frees its module scope after scanning and closes what it
//!    opened. A GType registered from a closed library keeps pointing at unmapped code,
//!    and the first virtual call faults — at the address of the function itself, which
//!    makes it look like a bad signature rather than an unloaded library. Holding our
//!    own `dlopen` reference is what prevents that, and the handle is never closed.
//!
//! Both are process-global by nature — environment and loaded libraries are — so this
//! happens once, before the engine starts, and remembers that it did.
//!
//! **Where the module is.** Searched in the order that matches how the module is actually
//! deployed: `LEPTON_PLATFORM_MODULE_DIR` if set, then next to this framework's own
//! executable, then the install prefix the build recorded. A shipped module belongs beside
//! the binary that needs it; the prefix is the fallback for a tree that has been installed
//! but whose binaries were moved, and the override is what lets a development run find a
//! freshly built module without installing it first.

const std = @import("std");
const build_options = @import("build_options");
const counters_mod = @import("counters.zig");

pub const Counters = counters_mod.Counters;

pub const Error = error{
    /// The module file is not where it was looked for.
    ModuleMissing,
    /// The loader refused the module. The reason is available from `loadFailure`; this
    /// framework does not guess at it.
    ModuleRefused,
    /// The override pointed somewhere that does not exist.
    BadModuleDirectory,
};

/// The value `WPE_PLATFORM` must carry for the engine to pick this implementation.
pub const platform_selector = "lepton";

/// GObject's `RTLD_NOW`, spelled out rather than imported from `dlfcn.h`, because this
/// framework declares its own ABI — see `wpe_abi.zig` for why `wpe_view.zig` does the
/// same. `RTLD_LOCAL` is zero and is named for symmetry, not because it needs naming:
/// binding locally keeps this module's symbols out of the global namespace, which is
/// what a plugin should do.
const rtld_now: c_int = 2;
const rtld_local: c_int = 0;

const dlopen = @extern(
    *const fn ([*:0]const u8, c_int) callconv(.c) ?*anyopaque,
    .{ .name = "dlopen" },
);

const dlsym = @extern(
    *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    .{ .name = "dlsym" },
);

const dlerror = @extern(
    *const fn () callconv(.c) ?[*:0]const u8,
    .{ .name = "dlerror" },
);

const getenv = @extern(
    *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8,
    .{ .name = "getenv" },
);

const setenv = @extern(
    *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int,
    .{ .name = "setenv" },
);

const directory_override = "LEPTON_PLATFORM_MODULE_DIR";

/// Kept for the life of the process. That is the whole reason this handle exists.
var resident: ?*anyopaque = null;
var selected = false;

/// The module's file name, as the build recorded it.
pub fn moduleFileName() []const u8 {
    return build_options.lepton_platform_module_name;
}

/// Points the engine at Lepton's display. Must run before `wpe_view.View.open()`.
///
/// Idempotent by doing nothing after the first call: the engine caches the default
/// display, so a later attempt would change nothing while appearing to succeed.
pub fn ensureSelected(allocator: std.mem.Allocator, io: std.Io) !void {
    if (selected) return;

    const directory = try moduleDirectory(allocator, io);
    defer allocator.free(directory);

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{
        directory,
        moduleFileName(),
    }) catch return Error.ModuleMissing;

    // Opened before the engine is ever asked, for both reasons at once: the handle keeps
    // the library resident, and its `g_io_module_load` runs while the extension point
    // exists.
    resident = dlopen(path.ptr, rtld_now | rtld_local) orelse return Error.ModuleRefused;

    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buffer, "{s}", .{directory}) catch
        return Error.ModuleMissing;

    // Both variables go in together, because either alone is a broken state: a path with
    // no selection leaves the engine to pick Wayland, and a selection with no path makes
    // WebKit abort looking for an implementation it cannot find.
    if (setenv("WPE_PLATFORMS_PATH", dir_z.ptr, 1) != 0) return Error.ModuleRefused;
    if (setenv("WPE_PLATFORM", platform_selector, 1) != 0) return Error.ModuleRefused;

    selected = true;
}

/// Why the loader refused, as the loader says it. Nothing when there was no failure, so
/// a caller reporting a refusal never invents a reason.
pub fn loadFailure() ?[]const u8 {
    if (resident != null) return null;
    const message = dlerror() orelse return null;
    return std.mem.span(message);
}

/// The module's counters, or nothing when the module was never loaded.
///
/// Read through `dlsym` on the handle this file already holds, which is the only reason
/// that handle exists. Returns nothing rather than a zeroed block when there is no module,
/// so a caller cannot mistake "not loaded" for "did nothing".
pub fn counters() ?*const counters_mod.Counters {
    const handle = resident orelse return null;
    const symbol = dlsym(handle, counters_mod.symbol_name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

/// Whether this process was asked to use Lepton's display at all.
///
/// A separate question from `isSelected`, and the reason they are separate: whether the
/// engine can be pointed at Lepton's display, and whether this particular run wants to be,
/// are different decisions. Every check tool wants the first answered and only some of them
/// want the second taken.
pub fn requested() bool {
    return getenv("LEPTON_PLATFORM") != null;
}

/// Whether the engine has been pointed at Lepton's display.
pub fn isSelected() bool {
    return selected;
}

/// Resolves the directory holding the module, in deployment order.
fn moduleDirectory(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (getenv(directory_override)) |override| return allocator.dupe(u8, std.mem.span(override));

    // If our own path cannot be read, the install prefix is still a defined answer and
    // is the right one: a program that cannot locate itself is usually a program that was
    // launched in a way that broke that assumption, and the prefix is what the build
    // recorded as correct.
    const executable = std.process.executablePathAlloc(io, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return allocator.dupe(u8, build_options.lepton_platform_module_dir),
    };
    defer allocator.free(executable);

    if (std.fs.path.dirname(executable)) |dir| return allocator.dupe(u8, dir);

    return allocator.dupe(u8, build_options.lepton_platform_module_dir);
}