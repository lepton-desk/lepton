//! Build-time support for `build.zig`: what the machine has (pkg-config) and the
//! Wayland protocol bindings generated from the vendored XML.

const std = @import("std");

pub const Protocol = struct {
    /// Interface name, matching the XML's directory.
    name: []const u8,
    /// Version of the interface to generate. `0` asks the scanner for every
    /// version the XML declares.
    version: u16,
};

/// True when the build machine's `pkg-config` knows `pkg`.
///
/// The exit status is the answer. A missing `pkg-config`, a missing `.pc` file
/// and a non-zero probe are all the same fact to this build: the library is not
/// available here, so the module compiles without it and the runtime probe
/// reports the absence.
/// True when the build machine's `pkg-config` knows `pkg`.
///
/// The exit status is the answer. A missing `pkg-config`, a missing `.pc` file
/// and a non-zero probe are all the same fact to this build: the library is not
/// available here, so the module compiles without it and the runtime probe
/// reports the absence.
pub fn hasPkgConfig(b: *std.Build, pkg: []const u8) bool {
    const found = b.findProgram(&.{"pkg-config"}, &.{}) catch return false;
    var code: u8 = 0;
    // `--exists` takes the leading dashes; the bare word exits non-zero even for a
    // package pkg-config can resolve, which would report every host as lacking
    // both display libraries. Only the exit status is read, so the complaint on
    // failure is discarded rather than inherited into the build log.
    const outcome = b.runAllowFail(&.{ found, "--exists", pkg }, &code, .ignore);
    // A successful probe leaves `code` at zero; a failing one sets it and returns
    // `ExitCodeFailure`. Anything else means the probe could not run at all, which
    // for this purpose is the same answer: not available here.
    if (outcome) |_| {
        return code == 0;
    } else |_| {
        return false;
    }
}

/// The installed engine's version, as `pkg-config --modversion` reports it.
///
/// Read from packaging rather than from a symbol probe because the question being asked
/// is "which ABI does this engine speak", and the version is what upstream draws the
/// boundary at. A distribution that backported either way is a case worth reading the
/// linker message for, not worth guessing about here.
pub fn pkgConfigVersion(b: *std.Build, pkg: []const u8) ?[]const u8 {
    const found = b.findProgram(&.{"pkg-config"}, &.{}) catch return null;
    var code: u8 = 0;
    const stdout = b.runAllowFail(&.{ found, "--modversion", pkg }, &code, .ignore) catch return null;
    if (code != 0) return null;
    return std.mem.trim(u8, stdout, " \t\r\n");
}

/// Whether `pkg` is installed at `major`.`minor` or newer.
///
/// A version that does not parse is not treated as new: refusing a working build over a
/// version string this code failed to read would be a worse failure than the one it is
/// guarding against.
pub fn engineIsAtLeast(b: *std.Build, pkg: []const u8, major: u32, minor: u32) bool {
    const text = pkgConfigVersion(b, pkg) orelse return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    const found_major = std.fmt.parseInt(u32, parts.next() orelse return false, 10) catch return false;
    const found_minor = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    return found_major > major or (found_major == major and found_minor >= minor);
}

/// Copies GLib's headers with `_Pragma` and `__pragma` neutralised, and returns the
/// directory to add to a module's include path.
///
/// The rewrite is mechanical and total: every occurrence of either construct is
/// removed, not just the one that happens to break today. A GLib update that adds a
/// new use is handled by the same rule, which is the only reason a header-rewriting
/// step is safe to keep in a build.
///
/// Idempotent by hash: the copy is written only when GLib's own headers have changed,
/// so an unchanged checkout does not re-copy several megabytes on every build.
/// The library file name a backend's `.pc` file links, or null if it is not installed.
///
/// `pkg-config --libs-only-L wpebackend-fdo-1.0` answers `-lWPEBackend-fdo-1.0`, and the
/// loader needs `libWPEBackend-fdo-1.0.so`. Deriving one from the other keeps the ABI
/// number out of this file, where it would be a constant that is right until it is
/// not, and wrong in the same way a missing backend is wrong.
pub fn wpeBackendLibrary(b: *std.Build, pkg: []const u8) ?[]const u8 {
    const found = b.findProgram(&.{"pkg-config"}, &.{}) catch return null;
    const reported = b.run(&.{ found, "--libs-only-l", pkg });

    var flags = std.mem.tokenizeAny(u8, reported, " \t\r\n");
    while (flags.next()) |flag| {
        if (!std.mem.startsWith(u8, flag, "-l")) continue;
        const name = flag[2..];
        if (!std.mem.startsWith(u8, name, "WPEBackend-")) continue;

        return b.fmt("lib{s}.so", .{name});
    }

    return null;
}

/// Adds every `-I` a package's `pkg-config` reports to `module`.
///
/// Split from `hasPkgConfig` because the two answers are different: one says "is this
/// here", the other says "and here is where its headers are", and a build that had
/// only the first would compile `@cImport` against a header set that does not exist.
pub fn addPkgConfigIncludes(b: *std.Build, module: *std.Build.Module, pkg: []const u8) void {
    const found = b.findProgram(&.{"pkg-config"}, &.{}) catch return;
    var code: u8 = 0;
    const outcome = b.runAllowFail(&.{ found, "--cflags-only-I", pkg }, &code, .ignore) catch return;
    if (code != 0) return;

    // Split on whitespace rather than assuming one flag per line: pkg-config puts
    // them all on one, and a `-I` with a space in the path is legal.
    var flags = std.mem.tokenizeAny(u8, outcome, " \t\r\n");
    while (flags.next()) |flag| {
        if (!std.mem.startsWith(u8, flag, "-I")) continue;
        addIncludeDirectory(b, module, flag[2..]);
    }
}

/// Adds one `-I` directory to `module`.
pub fn addIncludeDirectory(b: *std.Build, module: *std.Build.Module, directory: []const u8) void {
    if (directory.len == 0) return;

    // System include directories are absolute, and `b.path` refuses those. A
    // directory under the build root is the case `b.path` exists for, so only
    // that one goes through it; everything else is a `LazyPath` built from the
    // absolute form, which is what the compiler is handed anyway.
    if (std.fs.path.isAbsolute(directory)) {
        module.addIncludePath(.{ .cwd_relative = directory });
    } else {
        module.addIncludePath(b.path(directory));
    }
}

/// Directory the generated protocol bindings are written into.
///
/// Under the build root rather than in Zig's cache, because the bindings are
/// produced by a command that writes files itself rather than through the cache:
/// the scanner has no notion of inputs and outputs, only of a path.
pub const generated_protocol_dir = ".zig-cache/protocols";

/// Runs `wayland-scanner` over each vendored protocol, returning the directory
/// holding the generated bindings and a step that must finish before anything
/// compiles against them.
///
/// The scanner is required rather than optional: it is a build-time code
/// generator, not a runtime dependency, and a host that lacks it cannot produce
/// correct protocol bindings by any other means. Failing loudly here beats a
/// build that silently omits xdg-shell and then cannot map a window.
///
/// `private-code` emits the interface descriptor table and `client-header` emits
/// the inline request helpers. Both are needed and both must land in the same
/// directory: the helpers marshal through the descriptor, so one without the
/// other will not link, and `@cInclude` resolves against one include path.
pub const ProtocolBindings = struct {
    include_dir: std.Build.LazyPath,
    /// Must finish before anything compiles against the bindings.
    step: *std.Build.Step,
    /// Kept so the generated C file can be added to a compilation, which needs the
    /// build graph it was created from.
    modules: *std.Build,

    /// The generated C translation unit for a protocol, which defines the
    /// interface descriptors the inline helpers marshal through.
    pub fn sourceFile(bindings: ProtocolBindings, name: []const u8) std.Build.LazyPath {
        const b = bindings.modules;
        return b.path(b.fmt("{s}/{s}-protocol.c", .{ generated_protocol_dir, name }));
    }
};

pub fn generateProtocols(b: *std.Build, root: []const u8, protocols: []const Protocol) ProtocolBindings {
    const scanner = b.findProgram(&.{"wayland-scanner"}, &.{}) catch
        @panic("wayland-scanner is required to build the Wayland path; " ++
            "install it, or build for a target that does not use Wayland");

    const modes = [_]struct { mode: []const u8, suffix: []const u8 }{
        .{ .mode = "private-code", .suffix = "-protocol.c" },
        .{ .mode = "client-header", .suffix = "-client-protocol.h" },
    };

    // One step for the whole group. Every scanner depends on it, and every
    // compilation depends on it, so no scanner can end up unreached: a step the
    // top level does not depend on never runs, which is how a generated header
    // ends up missing on a clean build with no error to explain it.
    const group = b.step("protocol-bindings", "Generate Wayland protocol bindings");

    // The scanner writes into a directory it does not create, so the directory is
    // made first and the scanners are ordered after it.
    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", generated_protocol_dir });
    group.dependOn(&mkdir.step);

    for (protocols) |protocol| {
        const xml = b.path(
            b.pathJoin(&.{ root, "protocols", "stable", protocol.name, b.fmt("{s}.xml", .{protocol.name}) }),
        );

        for (modes) |m| {
            const run = b.addSystemCommand(&.{ scanner, m.mode });
            // Input first, output second: that is the order the scanner parses,
            // and swapping them fails with a message about the input file.
            run.addFileArg(xml);
            run.addArg(b.fmt("{s}/{s}{s}", .{ generated_protocol_dir, protocol.name, m.suffix }));
            // The bindings are inputs to a compilation rather than a cached
            // result, so the command must rerun whenever the protocol XML changes.
            run.has_side_effects = true;
            run.step.dependOn(&mkdir.step);
            group.dependOn(&run.step);
        }
    }

    return .{
        .include_dir = b.path(generated_protocol_dir),
        .step = group,
        .modules = b,
    };
}
