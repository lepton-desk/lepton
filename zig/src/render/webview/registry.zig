//! Which commands a page may call: the built-in ones, the application's own, and the
//! permission list that decides between them.
//!
//! An application registers commands in its `main.zig` as `AppCommand`s — a public
//! name and a function from argument bytes to result bytes. Their ids start at
//! [`first_app_id`], after the built-ins, in registration order; the page learns them by
//! name from `__lepton.appCommands`, never as numbers in its own source.
//!
//! Nothing runs unless it is listed. The list comes from `lepton.config.json`'s
//! `permissions` (the CLI hands it to the build as `-Dpermissions=a,b`), and it is checked
//! against the registered names at compile time: a misspelt permission is a build error,
//! not a command that silently never works. There is no wildcard — `*` is refused by the
//! CLI and again here — so granting a command is always naming it.
//!
//! Handlers get the application's state as a typed pointer: `checked(State, ...)` returns
//! a `Registered(State)`, and only `bind(&state)` turns it into the `Registry` the bridge
//! uses — so the pointer every handler receives is the `*State` the compiler checked,
//! never a cast the application wrote.

const std = @import("std");
const invoke = @import("invoke.zig");

/// Ids below this are the core's; an application's start here.
pub const first_app_id: u32 = 1000;

/// Why an application command did not produce a result.
pub const HandlerError = error{
    /// The command ran and refused: bad argument, failed operation.
    Failed,
    /// The result does not fit the space it was given.
    TooLarge,
    /// The command exists and is granted, but this use of it is not: a path outside the
    /// directories the application allowed. The page sees `denied`, as for an unlisted
    /// command.
    Denied,
};

/// An application command with its state: reads `argument`, writes its result into the
/// front of `out` and returns how many bytes it wrote.
pub fn Command(comptime State: type) type {
    return struct {
        /// `<group>.<name>`, lowercase: what the page passes to `invoke`.
        name: []const u8,
        run: *const fn (state: *State, argument: []const u8, out: []u8) HandlerError!usize,
    };
}

/// A handler with its state type erased, as the bridge stores it. Made only by
/// [`checked`], which pairs it with the `*State` it was written for.
pub const Handler = *const fn (context: ?*anyopaque, argument: []const u8, out: []u8) HandlerError!usize;

pub const AppCommand = struct {
    name: []const u8,
    run: Handler,
};

/// The commands of one application, checked, waiting for their state.
pub fn Registered(comptime State: type) type {
    return struct {
        /// Unbound: every application command answers `failed` until `bind`.
        unbound: Registry,
        /// One `"name": true;` line per command, for `declarations.zig` to put into the
        /// page's `src/lepton-commands.d.ts`.
        entries: []const u8,

        /// The registry the bridge uses, with `state` handed to every handler.
        pub fn bind(self: @This(), state: *State) Registry {
            var registry = self.unbound;
            registry.context = state;
            return registry;
        }
    };
}

/// What this core answers and what it is allowed to answer.
pub const Registry = struct {
    app: []const AppCommand = &.{},
    /// The application's state, handed to every handler; set by `Registered.bind`.
    context: ?*anyopaque = null,
    /// Command names a page may call. Empty: none.
    allowed: []const []const u8 = &.{},

    pub fn allows(self: *const Registry, name: []const u8) bool {
        for (self.allowed) |granted| {
            if (std.mem.eql(u8, granted, name)) return true;
        }
        return false;
    }

    /// The public name of `id`, built-in or application; `null` for an unknown id.
    pub fn nameOf(self: *const Registry, id: u32) ?[]const u8 {
        inline for (invoke.commands) |command| {
            if (id == @intFromEnum(command)) return command.publicName();
        }
        if (id < first_app_id) return null;
        const index = id - first_app_id;
        if (index >= self.app.len) return null;
        return self.app[index].name;
    }

    /// The application command with `id`, if `id` is one.
    pub fn appCommand(self: *const Registry, id: u32) ?AppCommand {
        if (id < first_app_id) return null;
        const index = id - first_app_id;
        if (index >= self.app.len) return null;
        return self.app[index];
    }
};

/// Splits `-Dpermissions`' comma list at compile time.
pub fn permissionList(comptime text: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        if (text.len == 0) return &.{};
        var names: []const []const u8 = &.{};
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| names = names ++ .{part};
        return names;
    }
}

/// A registry whose permissions name only commands that exist, checked at compile time.
pub fn checked(
    comptime State: type,
    comptime app: []const Command(State),
    comptime allowed: []const []const u8,
) Registered(State) {
    return checkedWith(State, app, &.{}, allowed);
}

/// A plugin's command: no application state, because a plugin is written before the
/// application that uses it. What it needs it reads from the system or keeps itself.
pub const PluginCommand = struct {
    name: []const u8,
    run: *const fn (argument: []const u8, out: []u8) HandlerError!usize,
};

/// Every plugin's `commands`, in the order the build lists the plugins. `plugins` is the
/// tuple `lepton_plugins.all` the project's build generates (`.{}` without plugins).
pub fn pluginCommands(comptime plugins: anytype) []const PluginCommand {
    comptime {
        var list: []const PluginCommand = &.{};
        for (plugins) |plugin| list = list ++ plugin.commands;
        return list;
    }
}

/// [`checked`] with plugin commands beside the application's. Plugin ids follow the
/// application's; names follow the same rules, and a name may be registered only once
/// across both.
pub fn checkedWith(
    comptime State: type,
    comptime app: []const Command(State),
    comptime plugins: []const PluginCommand,
    comptime allowed: []const []const u8,
) Registered(State) {
    comptime {
        // Every name against every earlier one, every permission against every name: with
        // a plugin's seven commands this passed Zig's default 1000 branches and the
        // application stopped compiling. Sized for hundreds of commands.
        @setEvalBranchQuota(1_000_000);
        var names: [app.len + plugins.len][]const u8 = undefined;
        var erased: [app.len + plugins.len]AppCommand = undefined;
        for (app, 0..) |command, index| {
            names[index] = command.name;
            erased[index] = .{ .name = command.name, .run = erase(State, command.run) };
        }
        for (plugins, app.len..) |command, index| {
            names[index] = command.name;
            erased[index] = .{ .name = command.name, .run = erasePlugin(command.run) };
        }
        for (names, 0..) |name, index| {
            if (!validName(name)) @compileError("command name \"" ++ name ++ "\" is not `<group>.<name>` in lowercase");
            if (isBuiltin(name)) @compileError("\"" ++ name ++ "\" is a built-in command; choose another name");
            for (names[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, name)) @compileError("command \"" ++ name ++ "\" is registered twice");
            }
        }
        for (allowed, 0..) |name, index| {
            if (std.mem.indexOfScalar(u8, name, '*') != null) @compileError("permission \"" ++ name ++ "\": wildcards are not allowed; name each command");
            const known = isBuiltin(name) or for (names) |registered| {
                if (std.mem.eql(u8, registered, name)) break true;
            } else false;
            if (!known) @compileError("permission \"" ++ name ++ "\" names no command this application has");
            for (allowed[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier, name)) @compileError("permission \"" ++ name ++ "\" is listed twice");
            }
        }
        const frozen = erased;
        var entries: []const u8 = "";
        for (names) |name| entries = entries ++ "    \"" ++ name ++ "\": true;\n";
        return .{
            .unbound = .{ .app = &frozen, .allowed = allowed },
            .entries = entries,
        };
    }
}

/// A plugin handler as the bridge stores it; the context is not its to use.
fn erasePlugin(
    comptime run: *const fn (argument: []const u8, out: []u8) HandlerError!usize,
) Handler {
    return &struct {
        fn call(_: ?*anyopaque, argument: []const u8, out: []u8) HandlerError!usize {
            return run(argument, out);
        }
    }.call;
}

/// Wraps a typed handler so the bridge can store it beside others of other states.
fn erase(
    comptime State: type,
    comptime run: *const fn (state: *State, argument: []const u8, out: []u8) HandlerError!usize,
) Handler {
    return &struct {
        fn call(context: ?*anyopaque, argument: []const u8, out: []u8) HandlerError!usize {
            // Only `bind` sets the context, and only to a `*State`.
            const state: *State = @ptrCast(@alignCast(context orelse return error.Failed));
            return run(state, argument, out);
        }
    }.call;
}

fn isBuiltin(name: []const u8) bool {
    inline for (invoke.commands) |command| {
        if (std.mem.eql(u8, command.publicName(), name)) return true;
    }
    return false;
}

/// `<group>.<name>[.<more>]`, each part `[a-z][a-z0-9_]*`. The CLI applies the same rule.
pub fn validName(name: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |part| {
        if (part.len == 0 or !std.ascii.isLower(part[0])) return false;
        for (part) |ch| {
            if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
        }
        parts += 1;
    }
    return parts >= 2;
}

/// Writes `{"notes.save":1000,...}` for the page.
pub fn writeAppTable(registry: *const Registry, out: []u8) error{NoSpaceLeft}![]const u8 {
    var used: usize = 0;
    used += (try std.fmt.bufPrint(out[used..], "{{", .{})).len;
    for (registry.app, 0..) |command, index| {
        const separator = if (index == 0) "" else ",";
        used += (try std.fmt.bufPrint(out[used..], "{s}\"{s}\":{d}", .{ separator, command.name, first_app_id + index })).len;
    }
    used += (try std.fmt.bufPrint(out[used..], "}}", .{})).len;
    return out[0..used];
}

const Counter = struct { calls: u32 = 0 };

fn upper(state: *Counter, argument: []const u8, out: []u8) HandlerError!usize {
    state.calls += 1;
    if (argument.len > out.len) return error.TooLarge;
    for (argument, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    return argument.len;
}

fn refuse(_: *Counter, _: []const u8, _: []u8) HandlerError!usize {
    return error.Failed;
}

test "names, ids and permissions resolve from one registry" {
    const app = [_]Command(Counter){ .{ .name = "text.upper", .run = &upper }, .{ .name = "text.refuse", .run = &refuse } };
    var counter: Counter = .{};
    const registry = (comptime checked(Counter, &app, permissionList("core.ping,text.upper"))).bind(&counter);
    try std.testing.expectEqualStrings("core.ping", registry.nameOf(1).?);
    try std.testing.expectEqualStrings("text.upper", registry.nameOf(first_app_id).?);
    try std.testing.expectEqualStrings("text.refuse", registry.nameOf(first_app_id + 1).?);
    try std.testing.expect(registry.nameOf(first_app_id + 2) == null);
    try std.testing.expect(registry.nameOf(999) == null);
    try std.testing.expect(registry.allows("text.upper"));
    try std.testing.expect(!registry.allows("text.refuse"));
    try std.testing.expect(!registry.allows("window.close"));

    var table: [128]u8 = undefined;
    try std.testing.expectEqualStrings("{\"text.upper\":1000,\"text.refuse\":1001}", try writeAppTable(&registry, &table));
}

test "command names follow <group>.<name> in lowercase" {
    try std.testing.expect(validName("notes.save"));
    try std.testing.expect(validName("a.b_2.c"));
    try std.testing.expect(!validName("notes"));
    try std.testing.expect(!validName("Notes.save"));
    try std.testing.expect(!validName("notes.*"));
    try std.testing.expect(!validName("notes..save"));
    try std.testing.expect(!validName("2d.draw"));
}

test "an empty permission list allows nothing" {
    const registered = comptime checked(Counter, &.{}, permissionList(""));
    try std.testing.expect(!registered.unbound.allows("core.ping"));
}

fn lower(argument: []const u8, out: []u8) HandlerError!usize {
    if (argument.len > out.len) return error.TooLarge;
    for (argument, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return argument.len;
}

test "plugin commands follow the application's, with the same rules" {
    const app = [_]Command(Counter){.{ .name = "text.upper", .run = &upper }};
    const Plugin = struct {
        pub const commands = [_]PluginCommand{.{ .name = "case.lower", .run = &lower }};
    };
    const plugins = comptime pluginCommands(.{Plugin});
    var counter: Counter = .{};
    const registry = (comptime checkedWith(Counter, &app, plugins, permissionList("case.lower"))).bind(&counter);
    try std.testing.expectEqualStrings("case.lower", registry.nameOf(first_app_id + 1).?);
    try std.testing.expect(registry.allows("case.lower"));
    try std.testing.expect(!registry.allows("text.upper"));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try registry.app[1].run(registry.context, "OK", &out));
    try std.testing.expectEqualStrings("ok", out[0..2]);
}

test "a registry of many commands and permissions compiles" {
    // Sixty-four plugin commands, every one granted: far past the size that first broke
    // the build (eight commands, seven permissions).
    const many = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var list: [64]PluginCommand = undefined;
        for (&list, 0..) |*command, index| command.* = .{ .name = std.fmt.comptimePrint("many.c{d}", .{index}), .run = &lower };
        break :blk list;
    };
    const granted = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var text: []const u8 = "";
        for (many, 0..) |command, index| text = text ++ (if (index == 0) "" else ",") ++ command.name;
        break :blk text;
    };
    const registered = comptime checkedWith(Counter, &.{}, &many, permissionList(granted));
    try std.testing.expect(registered.unbound.allows("many.c63"));
    try std.testing.expectEqualStrings("many.c63", registered.unbound.nameOf(first_app_id + 63).?);
}

test "a handler gets the state it was bound to, and an unbound one fails" {
    const app = [_]Command(Counter){.{ .name = "text.upper", .run = &upper }};
    const registered = comptime checked(Counter, &app, permissionList("text.upper"));
    var out: [16]u8 = undefined;
    try std.testing.expectError(error.Failed, registered.unbound.app[0].run(null, "x", &out));

    var counter: Counter = .{};
    const bound = registered.bind(&counter);
    try std.testing.expectEqual(@as(usize, 2), try bound.app[0].run(bound.context, "ok", &out));
    try std.testing.expectEqualStrings("OK", out[0..2]);
    try std.testing.expectEqual(@as(u32, 1), counter.calls);
}

test "every application command gets a declaration line" {
    const app = [_]Command(Counter){ .{ .name = "text.upper", .run = &upper }, .{ .name = "text.refuse", .run = &refuse } };
    const registered = comptime checked(Counter, &app, permissionList(""));
    try std.testing.expectEqualStrings("    \"text.upper\": true;\n    \"text.refuse\": true;\n", registered.entries);
}
