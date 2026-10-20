//! The application's own systemd scope, so a task manager shows it — the core and the
//! WebKit processes it starts — as one application under its own name.
//!
//! Measured before this: a Lepton application started from a terminal or an IDE stayed
//! in that program's cgroup (`app-com.anthropic.Claude-2214.scope`), so system monitors
//! that group by cgroup counted it, its `WPEWebProcess` and `WPENetworkProcess`, as part
//! of the terminal. Chromium and Claude Desktop move themselves the same way:
//! `app-org.chromium.Chromium-<pid>.scope`.
//!
//! The name follows systemd's desktop-environment convention, `app-<ID>-<RANDOM>.scope`,
//! with `<ID>` the desktop entry's ID escaped (`-` is the separator, so it becomes
//! `\x2d`); the entry `lepton run` writes is `<identifier>.desktop`, so the monitor finds
//! the application's name and icon there. Started from a launcher that already made a
//! scope for this ID (`app-cosmic-<ID>-<n>.scope`), nothing changes.
//!
//! WebKit's processes inherit the cgroup when they are forked, so `enter` must run before
//! the engine starts; it waits until the kernel shows the move.

const std = @import("std");
const build_options = @import("build_options");

/// GIO is linked: the webview builds.
pub const available = build_options.have_wpe and build_options.wpe_platform_abi and !build_options.native_render;

pub const Outcome = enum {
    /// Moved into `app-<ID>-<pid>.scope`.
    joined,
    /// Already in a scope made for this ID (a launcher's), left there.
    already,
    /// No systemd user manager, no session bus, or GIO is not linked: left where it was.
    unavailable,
};

/// Writes `identifier` escaped as systemd escapes a name part: ASCII letters, digits,
/// `:`, `_` and `.` stay (a leading `.` does not), everything else becomes `\xNN`.
pub fn escape(identifier: []const u8, out: []u8) error{NoSpaceLeft}![]const u8 {
    var used: usize = 0;
    for (identifier, 0..) |ch, index| {
        const plain = std.ascii.isAlphanumeric(ch) or ch == ':' or ch == '_' or (ch == '.' and index != 0);
        if (plain) {
            if (used + 1 > out.len) return error.NoSpaceLeft;
            out[used] = ch;
            used += 1;
        } else {
            const written = try std.fmt.bufPrint(out[used..], "\\x{x:0>2}", .{ch});
            used += written.len;
        }
    }
    return out[0..used];
}

/// `app-<escaped identifier>-<pid>.scope`, NUL-terminated for D-Bus.
pub fn unitName(identifier: []const u8, pid: i32, out: []u8) error{NoSpaceLeft}![:0]const u8 {
    var escaped_buffer: [256]u8 = undefined;
    const escaped = try escape(identifier, &escaped_buffer);
    return std.fmt.bufPrintSentinel(out, "app-{s}-{d}.scope", .{ escaped, pid }, 0);
}

/// The unit the process is in, from `/proc/self/cgroup`'s unified line (`0::/…`): the
/// last path element.
pub fn currentUnit(cgroup: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, cgroup, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const path = line[3..];
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        const unit = path[slash + 1 ..];
        return if (unit.len == 0) null else unit;
    }
    return null;
}

/// Whether `unit` is an application unit made for `escaped` — `app-<ID>-…`,
/// `app-<launcher>-<ID>-…`, or `app-…-<ID>@….service`.
pub fn isOwn(unit: []const u8, escaped: []const u8) bool {
    if (!std.mem.startsWith(u8, unit, "app-")) return false;
    var at: usize = 3; // the `-` after `app`
    while (std.mem.indexOfPos(u8, unit, at, escaped)) |found| : (at = found + 1) {
        if (unit[found - 1] != '-') continue;
        const after = found + escaped.len;
        if (after == unit.len) return false;
        const rest = unit[after..];
        if (rest[0] == '-' or rest[0] == '@') return true;
        if (std.mem.eql(u8, rest, ".scope") or std.mem.eql(u8, rest, ".service")) return true;
    }
    return false;
}

const GVariant = anyopaque;
const g = struct {
    const bus_get_sync = @extern(*const fn (c_int, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque, .{ .name = "g_bus_get_sync" });
    const call_sync = @extern(*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*GVariant, ?[*:0]const u8, c_int, c_int, ?*anyopaque, ?*?*anyopaque) callconv(.c) ?*GVariant, .{ .name = "g_dbus_connection_call_sync" });
    const new_string = @extern(*const fn ([*:0]const u8) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_string" });
    const new_uint32 = @extern(*const fn (u32) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_uint32" });
    const new_variant = @extern(*const fn (?*GVariant) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_variant" });
    const new_array = @extern(*const fn (?[*:0]const u8, [*]const ?*GVariant, usize) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_array" });
    const new_tuple = @extern(*const fn ([*]const ?*GVariant, usize) callconv(.c) ?*GVariant, .{ .name = "g_variant_new_tuple" });
    const unref = @extern(*const fn (?*GVariant) callconv(.c) void, .{ .name = "g_variant_unref" });
    const object_unref = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_object_unref" });
    const error_free = @extern(*const fn (?*anyopaque) callconv(.c) void, .{ .name = "g_error_free" });
};

const bus_session: c_int = 2; // G_BUS_TYPE_SESSION

fn readCgroup(out: []u8) []const u8 {
    const fd = std.c.open("/proc/self/cgroup", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return "";
    defer _ = std.c.close(fd);
    const read = std.c.read(fd, out.ptr, out.len);
    return if (read <= 0) "" else out[0..@intCast(read)];
}

/// `(sv)`: one transient-unit property.
fn property(name: [*:0]const u8, value: ?*GVariant) ?*GVariant {
    const pair = [_]?*GVariant{ g.new_string(name), g.new_variant(value) };
    return g.new_tuple(&pair, pair.len);
}

/// Moves this process into its own `app-<identifier>-<pid>.scope`, described as
/// `description` (the product's name), unless a launcher already put it in one. Call
/// before the engine starts.
pub fn enter(identifier: []const u8, description: [*:0]const u8) Outcome {
    if (comptime !available) return .unavailable;
    var escaped_buffer: [256]u8 = undefined;
    const escaped = escape(identifier, &escaped_buffer) catch return .unavailable;
    var cgroup_buffer: [1024]u8 = undefined;
    if (currentUnit(readCgroup(&cgroup_buffer))) |unit| {
        if (isOwn(unit, escaped)) return .already;
    }

    var name_buffer: [320]u8 = undefined;
    const pid = std.c.getpid();
    const name = unitName(identifier, pid, &name_buffer) catch return .unavailable;

    var failure: ?*anyopaque = null;
    const bus = g.bus_get_sync(bus_session, null, &failure) orelse {
        if (failure) |owned| g.error_free(owned);
        return .unavailable;
    };
    defer g.object_unref(bus);

    const pids = [_]?*GVariant{g.new_uint32(@intCast(pid))};
    const properties = [_]?*GVariant{
        property("PIDs", g.new_array("u", &pids, pids.len)),
        property("Description", g.new_string(description)),
        property("Slice", g.new_string("app.slice")),
        // A scope that ended badly is removed rather than kept as `failed`.
        property("CollectMode", g.new_string("inactive-or-failed")),
    };
    const no_aux = [_]?*GVariant{};
    const arguments = [_]?*GVariant{
        g.new_string(name.ptr),
        g.new_string("fail"),
        g.new_array("(sv)", &properties, properties.len),
        g.new_array("(sa(sv))", &no_aux, 0),
    };
    const reply = g.call_sync(
        bus,
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        g.new_tuple(&arguments, arguments.len),
        "(o)",
        0,
        2000,
        null,
        &failure,
    ) orelse {
        if (failure) |owned| g.error_free(owned);
        return .unavailable;
    };
    g.unref(reply);

    // The job is queued; the move is visible in `/proc/self/cgroup` once it ran. Up to a
    // second, in 5 ms steps.
    var waited: u32 = 0;
    while (waited < 200) : (waited += 1) {
        if (currentUnit(readCgroup(&cgroup_buffer))) |unit| {
            if (std.mem.eql(u8, unit, name)) return .joined;
        }
        const pause: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&pause, null);
    }
    return .unavailable;
}

test "an identifier is escaped as systemd escapes a unit name part" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("com.example.notes", try escape("com.example.notes", &buffer));
    try std.testing.expectEqualStrings("rec\\x2dapp", try escape("rec-app", &buffer));
    try std.testing.expectEqualStrings("\\x2edot", try escape(".dot", &buffer));
    var name: [128]u8 = undefined;
    try std.testing.expectEqualStrings("app-rec\\x2dapp-42.scope", try unitName("rec-app", 42, &name));
}

test "the current unit is read from the unified cgroup line" {
    const text = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-com.anthropic.Claude-2214.scope\n";
    try std.testing.expectEqualStrings("app-com.anthropic.Claude-2214.scope", currentUnit(text).?);
    try std.testing.expect(currentUnit("12:cpu:/x\n") == null);
}

test "a launcher's scope for this application is its own, another application's is not" {
    try std.testing.expect(isOwn("app-rec\\x2dapp-42.scope", "rec\\x2dapp"));
    try std.testing.expect(isOwn("app-cosmic-rec\\x2dapp-9.scope", "rec\\x2dapp"));
    try std.testing.expect(isOwn("app-gnome-rec\\x2dapp@1.service", "rec\\x2dapp"));
    try std.testing.expect(!isOwn("app-com.anthropic.Claude-2214.scope", "rec\\x2dapp"));
    // A longer identifier that starts with this one is another application.
    try std.testing.expect(!isOwn("app-rec\\x2dapp2-42.scope", "rec\\x2dapp"));
    try std.testing.expect(!isOwn("session-2.scope", "rec\\x2dapp"));
    try std.testing.expect(isOwn("app-com.example.notes.service", "com.example.notes"));
    try std.testing.expect(!isOwn("app-com.example.notes.beta-3.scope", "com.example.notes"));
}

test "entering is compiled" {
    _ = &enter;
}
