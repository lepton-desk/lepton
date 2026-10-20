//! One running copy per application and user. A second start hands its arguments (a deep
//! link, a file to open) to the first and ends; the first emits them to its page as the
//! `app.opened` event (`events.zig`), and the page reads its own start's with `app.args`.
//!
//! Linux: an abstract unix socket, `\0lepton-<identifier>.u<uid>`. Abstract, so a copy that
//! crashed leaves nothing behind to clear (the kernel drops the name with the socket). The
//! namespace is shared by every user, so both sides check the other's uid (`SO_PEERCRED`):
//! a name another user took first is not this user's app, and this copy then runs on its
//! own rather than handing a link to a stranger or refusing to start.
//!
//! Windows: a named pipe, `\\.\pipe\lepton-<identifier>`, made with
//! `FILE_FLAG_FIRST_PIPE_INSTANCE` (the first copy owns it) and
//! `PIPE_REJECT_REMOTE_CLIENTS`; the default security lets only this user and the system
//! open it.
//!
//! A message is the arguments after the program's own, each ended by a NUL, at most
//! `max_message` bytes.

const std = @import("std");
const builtin = @import("builtin");

pub const max_message = 4096;

/// What `claim` found.
pub const Claim = union(enum) {
    /// This is the first copy: `take` answers the later ones.
    primary: Instance,
    /// Another copy runs and has the arguments: end now.
    forwarded,
    /// Neither: no way to tell (an error, another user holding the name). Run alone.
    alone,
};

var launch_buffer: [max_message]u8 = undefined;
var launch_len: usize = 0;

/// This start's own arguments, as `claim` packed them: what `app.args` answers.
pub fn launchArgs() []const u8 {
    return launch_buffer[0..launch_len];
}

/// The last few handed-over messages, by number: an event's data is too short for a long
/// deep link (`events.max_data`), so `app.opened` carries the number and the page reads
/// the arguments with `app.args`.
const kept = 8;
var opened_buffer: [kept][max_message]u8 = undefined;
var opened_len: [kept]usize = @splat(0);
var opened_next: u32 = 1;

/// Keeps a handed-over message and returns its number (from 1).
pub fn remember(message: []const u8) u32 {
    const number = opened_next;
    opened_next +%= 1;
    if (opened_next == 0) opened_next = 1;
    const slot = number % kept;
    const len = @min(message.len, max_message);
    @memcpy(opened_buffer[slot][0..len], message[0..len]);
    opened_len[slot] = len;
    opened_numbers[slot] = number;
    return number;
}
var opened_numbers: [kept]u32 = @splat(0);

/// A kept message by number; null once it has been overwritten.
pub fn opened(number: u32) ?[]const u8 {
    const slot = number % kept;
    if (number == 0 or opened_numbers[slot] != number) return null;
    return opened_buffer[slot][0..opened_len[slot]];
}

/// Packs `args` (without the program) NUL-ended into `out`; what does not fit is dropped
/// whole, never cut inside an argument.
pub fn pack(args: []const []const u8, out: []u8) usize {
    var len: usize = 0;
    for (args) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) continue;
        if (len + arg.len + 1 > out.len) break;
        @memcpy(out[len..][0..arg.len], arg);
        out[len + arg.len] = 0;
        len += arg.len + 1;
    }
    return len;
}

/// Becomes the application's one copy, or hands `args` to the copy that already is.
/// `identifier` is `lepton.config.json`'s, already checked to be `[A-Za-z0-9._-]`.
pub fn claim(identifier: []const u8, args: []const []const u8) Claim {
    launch_len = pack(args, &launch_buffer);
    if (identifier.len == 0 or identifier.len > 160) return .alone;
    return platform.claim(identifier, launch_buffer[0..launch_len]);
}

pub const Instance = platform.Held;

const platform = if (builtin.os.tag == .windows) windows_impl else linux_impl;

const linux_impl = struct {
    const linux = std.os.linux;

    pub const Held = struct {
        fd: i32,

        /// One waiting copy's arguments into `out`, or null when none is waiting. Never
        /// blocks: called from the loop every turn.
        pub fn take(self: *Held, out: []u8) ?[]u8 {
            while (true) {
                const accepted = linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC);
                if (linux.errno(accepted) != .SUCCESS) return null;
                const peer: i32 = @intCast(accepted);
                defer _ = linux.close(peer);
                if (!sameUser(peer)) continue;
                // The sender wrote everything before this accept could see it, and closed;
                // a short wait covers a slow writer without stalling the loop for long.
                const wait: linux.timeval = .{ .sec = 0, .usec = 200_000 };
                _ = linux.setsockopt(peer, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&wait), @sizeOf(linux.timeval));
                var len: usize = 0;
                while (len < out.len) {
                    const got = linux.read(peer, out[len..].ptr, out.len - len);
                    if (linux.errno(got) != .SUCCESS or got == 0) break;
                    len += got;
                }
                return out[0..len];
            }
        }

        pub fn deinit(self: *Held) void {
            _ = linux.close(self.fd);
        }
    };

    fn address(identifier: []const u8, out: *linux.sockaddr.un) linux.socklen_t {
        out.* = .{ .family = linux.AF.UNIX, .path = @splat(0) };
        // path[0] stays 0: the abstract namespace.
        const name = std.fmt.bufPrint(out.path[1..], "lepton-{s}.u{d}", .{ identifier, linux.getuid() }) catch return 0;
        return @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + name.len);
    }

    /// `struct ucred` (socket(7)).
    const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

    fn sameUser(fd: i32) bool {
        var cred: Ucred = undefined;
        var len: linux.socklen_t = @sizeOf(Ucred);
        if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len)) != .SUCCESS) return false;
        return cred.uid == linux.getuid();
    }

    fn socket(flags: u32) ?i32 {
        const made = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | flags, 0);
        if (linux.errno(made) != .SUCCESS) return null;
        return @intCast(made);
    }

    fn claim(identifier: []const u8, message: []const u8) Claim {
        var where: linux.sockaddr.un = undefined;
        const where_len = address(identifier, &where);
        if (where_len == 0) return .alone;

        const listener = socket(linux.SOCK.NONBLOCK) orelse return .alone;
        if (linux.errno(linux.bind(listener, @ptrCast(&where), where_len)) == .SUCCESS) {
            if (linux.errno(linux.listen(listener, 8)) != .SUCCESS) {
                _ = linux.close(listener);
                return .alone;
            }
            return .{ .primary = .{ .fd = listener } };
        }
        _ = linux.close(listener);

        // Taken: hand the arguments to whoever holds it, if that is this user.
        const sender = socket(0) orelse return .alone;
        defer _ = linux.close(sender);
        if (linux.errno(linux.connect(sender, @ptrCast(&where), where_len)) != .SUCCESS) return .alone;
        if (!sameUser(sender)) return .alone;
        var sent: usize = 0;
        while (sent < message.len) {
            const wrote = linux.write(sender, message[sent..].ptr, message.len - sent);
            if (linux.errno(wrote) != .SUCCESS) return .alone;
            sent += wrote;
        }
        return .forwarded;
    }
};

const windows_impl = struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;

    extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max: u32, out_size: u32, in_size: u32, timeout: u32, security: ?*anyopaque) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const PIPE_ACCESS_INBOUND: u32 = 0x1;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
    const PIPE_TYPE_MESSAGE: u32 = 0x4;
    const PIPE_READMODE_MESSAGE: u32 = 0x2;
    const PIPE_NOWAIT: u32 = 0x1;
    const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x8;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const ERROR_NO_DATA: u32 = 232;

    pub const Held = struct {
        pipe: HANDLE,

        /// One waiting copy's arguments, or null. The pipe is non-blocking (`PIPE_NOWAIT`):
        /// `ConnectNamedPipe` reports a client already there as `ERROR_PIPE_CONNECTED`.
        pub fn take(self: *Held, out: []u8) ?[]u8 {
            if (ConnectNamedPipe(self.pipe, null) == 0) {
                const code = GetLastError();
                if (code != ERROR_PIPE_CONNECTED and code != ERROR_NO_DATA) return null;
            }
            defer _ = DisconnectNamedPipe(self.pipe);
            var got: u32 = 0;
            if (ReadFile(self.pipe, out.ptr, @intCast(out.len), &got, null) == 0) return null;
            return out[0..got];
        }

        pub fn deinit(self: *Held) void {
            _ = CloseHandle(self.pipe);
        }
    };

    fn claim(identifier: []const u8, message: []const u8) Claim {
        var name_buffer: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "\\\\.\\pipe\\lepton-{s}", .{identifier}) catch return .alone;
        var wide: [256:0]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide, name) catch return .alone;
        wide[wide_len] = 0;

        const pipe = CreateNamedPipeW(&wide, PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0, max_message, 0, null);
        if (pipe != w.INVALID_HANDLE_VALUE) return .{ .primary = .{ .pipe = pipe } };

        const client = CreateFileW(&wide, GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
        if (client == w.INVALID_HANDLE_VALUE) return .alone;
        defer _ = CloseHandle(client);
        var written: u32 = 0;
        if (WriteFile(client, message.ptr, @intCast(message.len), &written, null) == 0) return .alone;
        return .forwarded;
    }
};

test "arguments are packed NUL-ended and never cut" {
    var out: [12]u8 = undefined;
    const len = pack(&.{ "myapp://a", "bb", "toolong" }, &out);
    try std.testing.expectEqualStrings("myapp://a\x00", out[0..len]);
    try std.testing.expectEqual(@as(usize, 0), pack(&.{"a\x00b"}, &out));
}

test "a second claim hands its arguments to the first" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var first = switch (claim("dev.lepton.single-instance-test", &.{"one"})) {
        .primary => |instance| instance,
        else => return error.TestUnexpectedResult,
    };
    defer first.deinit();
    try std.testing.expectEqualStrings("one\x00", launchArgs());
    try std.testing.expect(claim("dev.lepton.single-instance-test", &.{ "myapp://open/7", "x" }) == .forwarded);
    var out: [max_message]u8 = undefined;
    try std.testing.expectEqualStrings("myapp://open/7\x00x\x00", first.take(&out).?);
    try std.testing.expect(first.take(&out) == null);
}

test "a handed-over message is kept by number until eight more arrive" {
    const first = remember("one\x00");
    try std.testing.expectEqualStrings("one\x00", opened(first).?);
    for (0..kept) |_| _ = remember("later\x00");
    try std.testing.expect(opened(first) == null);
    try std.testing.expect(opened(0) == null);
}
