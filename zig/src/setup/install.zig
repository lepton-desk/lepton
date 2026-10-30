//! Installing and uninstalling, for the window and for `/S` alike.
//!
//! Install: the zip is unpacked into `<folder>.setup-new` beside the install folder, each
//! file's CRC checked; this program without its zip goes in as `uninstall.exe`, and
//! `.lepton-setup-files` lists every file written. Only then is the old folder renamed away
//! and the new one renamed into place, so a failure or a cancel leaves the installed
//! version as it was. The registry and the Start menu shortcut follow, as the MSI writes
//! them (`crates/cli/src/commands/installer_tables.rs`): the same AppUserModelID, schemes and
//! notification name, so either package installs the same application.
//!
//! Uninstall removes the files the list names and the folders left empty by that, the
//! registry values and the shortcut. The application's data (`%LOCALAPPDATA%\<identifier>`,
//! `%APPDATA%\<identifier>`) stays unless the user asks for it to go.

const std = @import("std");
const payload = @import("payload.zig");
const win = @import("win.zig");
const c = win.c;
const W = win.W;

pub const Error = win.Error || payload.Error || error{ Cancelled, OutOfMemory, Newer, Foreign };

/// What is in the install folder before this setup runs.
pub const State = enum { fresh, upgrade, same, newer, foreign };

pub const files_list = ".lepton-setup-files";
const uninstaller = "uninstall.exe";
const uninstall_root = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";

/// Everything the install needs, read before the window opens.
pub const Plan = struct {
    bytes: []const u8,
    archive: payload.Archive,
    manifest: payload.Manifest,
    dir: win.Path,
    state: State,
    /// The installed version, when there is one.
    installed: [64]u8 = undefined,
    installed_len: usize = 0,
    /// The bytes the files hold, for the progress bar and `EstimatedSize`.
    total: u64,

    pub fn installedVersion(self: *const Plan) []const u8 {
        return self.installed[0..self.installed_len];
    }
};

var manifest_text: [16 * 1024]u8 = undefined;
var installed_text: [16 * 1024]u8 = undefined;

/// Reads the zip after this program and what the install folder holds. `error.NoArchive`
/// means this is `uninstall.exe`.
pub fn plan(bytes: []const u8) Error!Plan {
    const archive = try payload.Archive.open(bytes);
    const entry = (try archive.find(payload.manifest_name)) orelse return error.NoManifest;
    if (entry.size > manifest_text.len) return error.BadManifest;
    try entry.unpack(manifest_text[0..entry.size]);
    const manifest = try payload.Manifest.parse(manifest_text[0..entry.size]);

    var total: u64 = 0;
    var entries = archive.iterator();
    while (try entries.next()) |each| total += each.size;

    var out: Plan = .{
        .bytes = bytes,
        .archive = archive,
        .manifest = manifest,
        .dir = try (try win.knownFolder(&win.folder_user_programs)).join(manifest.product),
        .state = .fresh,
        .total = total,
    };
    if (!win.exists(&out.dir)) return out;
    const installed = readInstalled(&out.dir) orelse {
        out.state = .foreign;
        return out;
    };
    if (!std.mem.eql(u8, installed.identifier, manifest.identifier)) {
        out.state = .foreign;
        return out;
    }
    const len = @min(installed.version.len, out.installed.len);
    @memcpy(out.installed[0..len], installed.version[0..len]);
    out.installed_len = len;
    const old = payload.Version.parse(installed.version) orelse {
        out.state = .foreign;
        return out;
    };
    const new = payload.Version.parse(manifest.version).?;
    out.state = switch (new.order(old)) {
        .gt => .upgrade,
        .eq => .same,
        .lt => .newer,
    };
    return out;
}

/// The `.lepton-setup` an earlier install left in `dir`.
pub fn readInstalled(dir: *const win.Path) ?payload.Manifest {
    const path = dir.join(payload.manifest_name) catch return null;
    const text = win.readFile(&path, &installed_text) catch return null;
    return payload.Manifest.parse(text) catch null;
}

/// Reports how far the work is; `cancelled` is read between files.
pub const Progress = struct {
    context: ?*anyopaque = null,
    step: ?*const fn (?*anyopaque, done: u64, total: u64) void = null,
    cancelled: ?*const std.atomic.Value(bool) = null,

    fn report(progress: Progress, done: u64, total: u64) void {
        if (progress.step) |step| step(progress.context, done, total);
    }

    fn stop(progress: Progress) bool {
        return if (progress.cancelled) |flag| flag.load(.acquire) else false;
    }
};

pub fn install(job: *const Plan, progress: Progress) Error!void {
    switch (job.state) {
        .fresh, .upgrade, .same => {},
        .newer => return error.Newer,
        .foreign => return error.Foreign,
    }
    const staging = try job.dir.withSuffix(W(".setup-new"));
    try win.deleteTree(&staging);
    try win.createDirs(&staging);
    errdefer win.deleteTree(&staging) catch {};

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.heap.page_allocator);
    var done: u64 = 0;
    var entries = job.archive.iterator();
    while (try entries.next()) |entry| {
        if (progress.stop()) return error.Cancelled;
        const target = try staging.join(entry.name);
        if (entry.directory) {
            try win.createDirs(&target);
            continue;
        }
        const bytes = try std.heap.page_allocator.alloc(u8, entry.size);
        defer std.heap.page_allocator.free(bytes);
        try entry.unpack(bytes);
        win.writeFile(&target, bytes) catch |err| switch (err) {
            // A file inside a folder the zip did not list first.
            error.Windows => {
                try win.createDirs(&target.parent());
                try win.writeFile(&target, bytes);
            },
            else => return err,
        };
        try list.appendSlice(std.heap.page_allocator, entry.name);
        try list.append(std.heap.page_allocator, '\n');
        done += entry.size;
        progress.report(done, job.total);
    }
    // This program without its zip: what `uninstall.exe` needs is the program alone.
    try win.writeFile(&(try staging.join(uninstaller)), job.bytes[0..job.archive.base]);
    try list.appendSlice(std.heap.page_allocator, uninstaller ++ "\n" ++ files_list ++ "\n");
    try win.writeFile(&(try staging.join(files_list)), list.items);
    if (progress.stop()) return error.Cancelled;

    if (win.exists(&job.dir)) {
        const old = try job.dir.withSuffix(W(".setup-old"));
        try win.deleteTree(&old);
        // A running program keeps its folder from being renamed: nothing is changed yet.
        try win.rename(&job.dir, &old);
        win.rename(&staging, &job.dir) catch |err| {
            win.rename(&old, &job.dir) catch {};
            return err;
        };
        win.deleteTree(&old) catch {};
    } else {
        try win.createDirs(&job.dir.parent());
        try win.rename(&staging, &job.dir);
    }
    try register(job);
}

/// The registry values and the shortcut, from the installed folder.
fn register(job: *const Plan) Error!void {
    // The UTF-16 literals below are made at compile time, past the default quota.
    @setEvalBranchQuota(20_000);
    const m = job.manifest;
    var buffers: [6][2048]u16 = undefined;
    const product = try win.wide(&buffers[0], m.product);
    const identifier = try win.wide(&buffers[1], m.identifier);
    const program_path = try job.dir.join(m.program);
    const program = program_path.plain();
    const dir = job.dir.plain();

    var key_name: [512]u16 = undefined;
    const uninstall_key = try win.concat(&key_name, &.{ W(uninstall_root), identifier });
    {
        const key = try win.Key.create(uninstall_key);
        defer key.close();
        try key.setText(W("DisplayName"), product);
        try key.setText(W("DisplayVersion"), try win.wide(&buffers[2], m.version));
        if (m.publisher.len > 0) try key.setText(W("Publisher"), try win.wide(&buffers[3], m.publisher));
        try key.setText(W("DisplayIcon"), try win.concat(&buffers[4], &.{ program, W(",0") }));
        try key.setText(W("InstallLocation"), dir);
        const remover = try job.dir.join(uninstaller);
        try key.setText(W("UninstallString"), try win.concat(&buffers[5], &.{ W("\""), remover.plain(), W("\"") }));
        try key.setText(W("QuietUninstallString"), try win.concat(&buffers[5], &.{ W("\""), remover.plain(), W("\" /S") }));
        try key.setNumber(W("NoModify"), 1);
        try key.setNumber(W("NoRepair"), 1);
        try key.setNumber(W("EstimatedSize"), @intCast(@min(job.total / 1024, std.math.maxInt(u32))));
        // What tells this setup's entry from the MSI's (whose key is its ProductCode).
        try key.setNumber(W("LeptonSetup"), 1);
    }

    // `deepLinks`: each scheme opens the program with the link, as the MSI registers it.
    var schemes = m.schemes();
    while (schemes.next()) |scheme| {
        const name = try win.wide(&buffers[2], scheme);
        {
            const key = try win.Key.create(try win.concat(&key_name, &.{ W("Software\\Classes\\"), name }));
            defer key.close();
            try key.setText(null, try win.concat(&buffers[3], &.{ W("URL:"), product }));
            try key.setText(W("URL Protocol"), W(""));
        }
        const key = try win.Key.create(try win.concat(&key_name, &.{ W("Software\\Classes\\"), name, W("\\shell\\open\\command") }));
        defer key.close();
        try key.setText(null, try win.concat(&buffers[3], &.{ W("\""), program, W("\" \"%1\"") }));
    }

    // The name and icon Windows shows on the program's notifications.
    const icon_path: ?win.Path = if (m.icon.len > 0) try job.dir.join(m.icon) else null;
    {
        const key = try win.Key.create(try win.concat(&key_name, &.{ W("Software\\Classes\\AppUserModelId\\"), identifier }));
        defer key.close();
        try key.setText(W("DisplayName"), product);
        if (icon_path) |*icon| try key.setText(W("IconUri"), icon.plain());
    }

    _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    const link = try shortcutPath(m.product);
    try win.writeShortcut(.{
        .file = &link,
        .target = program,
        .directory = dir,
        .description = product,
        .icon = if (icon_path) |*icon| icon.plain() else null,
        .app_id = identifier,
    });
}

fn shortcutPath(product: []const u8) Error!win.Path {
    var name: [512]u8 = undefined;
    const file = std.fmt.bufPrint(&name, "{s}.lnk", .{product}) catch return error.TooLong;
    return (try win.knownFolder(&win.folder_programs)).join(file);
}

/// Removes what `install` wrote into `dir` for `manifest`, and the application's data too
/// when `remove_data` is set.
pub fn uninstall(dir: *const win.Path, manifest: payload.Manifest, remove_data: bool, progress: Progress) Error!void {
    @setEvalBranchQuota(20_000);
    const program = try dir.join(manifest.program);
    // A running program cannot be renamed: checked before anything is removed. One that is
    // already gone does not stop the rest from going.
    const aside = try program.withSuffix(W(".setup-check"));
    if (win.rename(&program, &aside)) |_| {
        try win.rename(&aside, &program);
    } else |err| if (err == error.InUse) return err;

    const list_path = try dir.join(files_list);
    const list = try std.heap.page_allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.heap.page_allocator.free(list);
    const text = try win.readFile(&list_path, list);

    var count: u64 = 0;
    var total: u64 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| total += @intFromBool(line.len > 0);
    lines.reset();
    while (lines.next()) |raw| {
        const name = std.mem.trimEnd(u8, raw, "\r");
        if (name.len == 0 or std.mem.eql(u8, name, uninstaller) or std.mem.eql(u8, name, files_list)) continue;
        // The list is this program's own, but it is a file on disk: nothing outside `dir`.
        if (std.mem.find(u8, name, "..") != null or name[0] == '/' or std.mem.findScalar(u8, name, ':') != null) continue;
        const path = try dir.join(name);
        try win.deleteFile(&path);
        var up = path.parent();
        while (up.len > dir.len) : (up = up.parent()) win.removeEmptyDir(&up);
        count += 1;
        progress.report(count, total);
    }

    var buffers: [3][2048]u16 = undefined;
    var key_name: [512]u16 = undefined;
    const identifier = try win.wide(&buffers[0], manifest.identifier);
    win.deleteKey(try win.concat(&key_name, &.{ W(uninstall_root), identifier }));
    win.deleteKey(try win.concat(&key_name, &.{ W("Software\\Classes\\AppUserModelId\\"), identifier }));
    var schemes = manifest.schemes();
    while (schemes.next()) |scheme| {
        const name = try win.wide(&buffers[1], scheme);
        // A scheme another program took over since is left to it.
        const command_key = try win.concat(&key_name, &.{ W("Software\\Classes\\"), name, W("\\shell\\open\\command") });
        const ours = if (win.Key.open(command_key)) |key| blk: {
            defer key.close();
            const command = key.text(null, &buffers[2]) orelse break :blk false;
            break :blk std.mem.find(u16, command, program.plain()) != null;
        } else false;
        if (ours) win.deleteKey(try win.concat(&key_name, &.{ W("Software\\Classes\\"), name }));
    }
    const link = try shortcutPath(manifest.product);
    try win.deleteFile(&link);

    if (remove_data) {
        try win.deleteTree(&(try (try win.knownFolder(&win.folder_local_app_data)).join(manifest.identifier)));
        try win.deleteTree(&(try (try win.knownFolder(&win.folder_roaming_app_data)).join(manifest.identifier)));
    }

    // This program cannot delete itself while it runs, but it can be moved: to the temporary
    // folder, where Windows is asked to delete it at the next restart (which needs rights a
    // per-user uninstall does not have; then it stays there, as NSIS's uninstaller does).
    const own = try win.ownPath();
    const remover = try dir.join(uninstaller);
    if (std.mem.eql(u16, own.plain(), remover.plain())) {
        var temp_units: [win.Path.max]u16 = undefined;
        const temp_len = c.GetTempPathW(temp_units.len, &temp_units);
        if (temp_len > 0 and temp_len < temp_units.len) {
            var temp = try win.Path.of(temp_units[0..temp_len]);
            var name: [64]u8 = undefined;
            try temp.add(try win.wide(&buffers[1], std.fmt.bufPrint(&name, "lepton-uninstall-{d}.exe", .{c.GetCurrentProcessId()}) catch unreachable));
            if (c.MoveFileExW(own.long(), temp.long(), 0) != 0) {
                _ = c.MoveFileExW(temp.long(), null, c.MOVEFILE_DELAY_UNTIL_REBOOT);
            }
        }
    } else try win.deleteFile(&remover);
    try win.deleteFile(&list_path);
    win.removeEmptyDir(dir);
    // `%LOCALAPPDATA%\Programs` too, when nothing else is in it, as the MSI does.
    win.removeEmptyDir(&dir.parent());
}
