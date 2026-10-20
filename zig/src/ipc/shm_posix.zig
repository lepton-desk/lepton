//! POSIX shared-memory regions, bound straight to the system C ABI.
//!
//! Nothing here wraps a library. `shm_open`, `fstat`, `ftruncate`, `close` and
//! `shm_unlink` are the platform's own symbols reached through `@cImport`; the
//! mapping itself goes through `std.posix.mmap`. A region is created once by the
//! process that owns the window and attached by everyone else.
//!
//! Two properties matter to the rest of Lepton:
//!
//! * Every byte handed out lives in one mapping made at startup. Nothing in this
//!   file allocates on the event loop.
//! * A region is a real kernel object with a real name, so a second process can
//!   prove it is talking to the same ring rather than trusting a pid.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
});

/// Alignment of every mapping this module hands out.
pub const page_align = std.heap.page_size_min;

/// Stands in for a freed name so a closed region never reads as a live one.
///
/// A `deinit`ed region keeps this rather than a dangling pointer: a caller that
/// reads `name` after cleanup sees an empty name instead of freed memory.
const empty_name: [:0]const u8 = "";

pub const Error = error{
    PermissionDenied,
    AlreadyExists,
    NotFound,
    InvalidArgument,
    InvalidName,
    NameTooLong,
    IsDirectory,
    FdQuotaExhausted,
    NoSpaceLeft,
    OutOfMemory,
    WouldBlock,
    UnsupportedMapping,
} || posix.UnexpectedError;

pub const Region = struct {
    /// Owned, NUL-terminated copy of the kernel object name.
    name: [:0]const u8,
    /// The whole mapping. Owned by this struct.
    bytes: []align(page_align) u8,
    fd: posix.fd_t,
    /// True when this process called `shm_open` with `O_CREAT`, which makes it
    /// the one responsible for `shm_unlink`.
    owner: bool,

    /// Unmaps and closes. Leaves the kernel object in place when `owner`.
    pub fn close(self: *Region) void {
        posix.munmap(self.bytes);
        self.bytes = &.{};
        _ = c.close(self.fd);
        self.fd = -1;
    }

    /// Removes the kernel object. A name that is already gone is not an error:
    /// two processes racing to clean up is the normal case, not a failure.
    pub fn unlink(self: *Region) void {
        _ = c.shm_unlink(self.name.ptr);
    }

    /// Closes and, when this process created it, unlinks. Use with `defer`.
    pub fn deinit(self: *Region, allocator: Allocator) void {
        const was_owner = self.owner;
        self.close();
        if (was_owner) {
            self.unlink();
        }
        // Only a name this process duplicated is freed; a sentinel is static.
        if (self.name.ptr != empty_name.ptr) allocator.free(@constCast(self.name));
        self.name = empty_name;
    }
};

/// Creates a region of exactly `len` bytes and maps it read-write.
///
/// The name is created with mode 0600: the window and its webview belong to
/// whoever launched them, and nothing else on the machine may read the ring.
///
/// Fails with `error.AlreadyExists` when the name is taken, so two windows can
/// never silently share a ring they did not negotiate.
pub fn create(allocator: Allocator, name: []const u8, len: usize) Error!Region {
    const z = try validateName(allocator, name);
    errdefer allocator.free(z);

    const rc = c.shm_open(z.ptr, c.O_RDWR | c.O_CREAT | c.O_EXCL, 0o600);
    if (rc < 0) return mapErrno();

    const fd: posix.fd_t = rc;
    errdefer _ = c.close(fd);

    if (len == 0) return error.InvalidArgument;
    if (c.ftruncate(fd, @intCast(len)) != 0) return mapErrno();

    const bytes = mapRegion(len, fd) catch |e| return e;
    return .{ .name = z, .bytes = bytes, .fd = fd, .owner = true };
}

/// Removes a region's name, leaving the mapping itself alone.
///
/// Exists because a POSIX shared-memory object outlives the process that made it: a
/// process that is killed leaves its name behind, and the next process to ask for it
/// gets `AlreadyExists` forever.
///
/// Whether that should be cleared is the caller's decision, and the two callers want
/// different answers. A one-shot tool wants the name gone before it starts. A
/// long-lived application must not — clearing it would destroy the name a live peer is
/// still publishing into — and should instead discover that the previous owner is gone
/// through the channel's handshake, which is what `Channel.isEstablished` is for.
pub fn unlink(allocator: Allocator, name: []const u8) Error!void {
    const z = try validateName(allocator, name);
    defer allocator.free(z);

    if (c.shm_unlink(z.ptr) != 0) {
        // Nothing there is the outcome the caller asked for, so it is not a failure.
        if (mapErrno() == error.AlreadyExists) return;
        return mapErrno();
    }
}

/// Attaches to a region another process created, sized by its own `fstat`.
pub fn attach(allocator: Allocator, name: []const u8) Error!Region {
    const z = try validateName(allocator, name);
    errdefer allocator.free(z);

    const rc = c.shm_open(z.ptr, c.O_RDWR, 0);
    if (rc < 0) return mapErrno();

    const fd: posix.fd_t = rc;
    errdefer _ = c.close(fd);

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return mapErrno();

    const size: i64 = st.st_size;
    if (size <= 0) return error.InvalidArgument;

    const bytes = mapRegion(@intCast(size), fd) catch |e| return e;
    return .{ .name = z, .bytes = bytes, .fd = fd, .owner = false };
}

/// Maps a shared, read-write view of `len` bytes backed by `fd`.
///
/// A shared mapping over a descriptor Lepton itself just opened and sized cannot
/// fail for reasons the caller could act on, so every branch below is an explicit
/// decision rather than a catch-all.
fn mapRegion(len: usize, fd: posix.fd_t) Error![]align(page_align) u8 {
    return posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch |e| switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        error.LockedMemoryLimitExceeded => Error.WouldBlock,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => Error.FdQuotaExhausted,
        error.MemoryMappingNotSupported => Error.UnsupportedMapping,
        error.AccessDenied, error.PermissionDenied => Error.PermissionDenied,
        // A shared file mapping at an address of our choosing cannot collide; the
        // kernel reports it only when the descriptor already has a mapping of a
        // different kind, which this descriptor never does.
        error.MappingAlreadyExists => error.InvalidArgument,
        else => |other| other,
    };
}

fn validateName(allocator: Allocator, name: []const u8) Error![:0]u8 {
    // POSIX shared memory takes exactly one leading slash and no other path
    // separator. Rejecting here beats discovering it as an EINVAL from the kernel.
    if (name.len == 0 or name[0] != '/') return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name[1..], '/') != null) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '\x00') != null) return error.InvalidName;
    // The user's id is part of the name the kernel sees. `/dev/shm` is shared by every
    // user, and a name another user made first cannot be removed or opened by this one
    // (sticky directory, mode 0600): without it, anyone could keep an app from starting
    // by creating its channel's name.
    return try std.fmt.allocPrintSentinel(allocator, "{s}.u{d}", .{ name, c.getuid() }, 0);
}

/// Maps the calling process's `errno` onto Lepton's error set.
///
/// `errno` is read directly from the C library's thread-local slot. Note that
/// `std.posix.errno` is *not* the right tool here: it decodes a raw syscall
/// return value in which a failure is encoded as `-errno`, whereas the value in
/// `errno` is already the positive error number.
fn mapErrno() Error {
    const value = c.__errno_location().*;
    // A value outside the platform's range means the C library reported a
    // failure without describing it. Reporting that as a specific cause would
    // blame the caller for the library's silence.
    if (value <= 0) return error.Unexpected;
    return switch (@as(posix.E, @enumFromInt(@as(usize, @intCast(value))))) {
        // `errno` is already non-zero here, so this arm is unreachable; it is
        // present because the switch must be total.
        .SUCCESS => error.Unexpected,
        .ACCES, .PERM => error.PermissionDenied,
        .EXIST => error.AlreadyExists,
        .NOENT => error.NotFound,
        .INVAL => error.InvalidArgument,
        .NAMETOOLONG => error.NameTooLong,
        .ISDIR => error.IsDirectory,
        .MFILE, .NFILE => error.FdQuotaExhausted,
        .NOSPC => error.NoSpaceLeft,
        .NOMEM => error.OutOfMemory,
        .AGAIN => error.WouldBlock,
        else => |e| posix.unexpectedErrno(e),
    };
}
