//! Named shared-memory regions on Windows: a section backed by the paging file.
//!
//! `CreateFileMappingW(INVALID_HANDLE_VALUE, …)` is the Windows counterpart of
//! `shm_open` + `ftruncate`, and `MapViewOfFile` of `mmap`. Every call is a kernel32
//! export that Windows 7 already has, so this file is not what keeps the core off the
//! older systems (`docs/plans/windows.md`).
//!
//! ## Names
//!
//! Callers pass the POSIX form, `/lepton-ledger`. It becomes `Local\lepton-ledger`: the
//! session's own namespace, so two users signed in at once never meet each other's rings
//! — the role mode 0600 plays on Linux. The object's default security descriptor grants
//! its creator, SYSTEM and administrators, nobody else.
//!
//! ## Lifetime
//!
//! A section lives exactly as long as a handle to it does. There is nothing to unlink,
//! and a killed owner leaves nothing behind for the next launch to trip over: the case
//! `ownership.zig` exists for on Linux cannot arise here.
//!
//! ## Size
//!
//! The kernel keeps a section's size in whole pages — measured: a 12 345-byte section
//! reads back as 16 384 from `NtQuerySection` — and the channel splits its region in half
//! by length. So the creator makes the section one page-rounded `len + 8` and writes
//! `len` into its last eight bytes; `attach` reads it back from there.

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

/// Alignment of every mapping this module hands out. A view starts on an allocation
/// granularity boundary (64 KiB), which is stricter than a page.
pub const page_align = std.heap.page_size_min;

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
    Unexpected,
};

extern "kernel32" fn CreateFileMappingW(
    file: ?windows.HANDLE,
    attributes: ?*anyopaque,
    protect: windows.DWORD,
    size_high: windows.DWORD,
    size_low: windows.DWORD,
    name: [*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn OpenFileMappingW(access: windows.DWORD, inherit: windows.BOOL, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn MapViewOfFile(
    section: windows.HANDLE,
    access: windows.DWORD,
    offset_high: windows.DWORD,
    offset_low: windows.DWORD,
    bytes: usize,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;
extern "ntdll" fn NtQuerySection(
    section: windows.HANDLE,
    class: c_int,
    information: *anyopaque,
    length: usize,
    returned: ?*usize,
) callconv(.winapi) i32;

const page_readwrite: windows.DWORD = 0x04;
const file_map_all_access: windows.DWORD = 0x000F001F;
const invalid_handle: windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));

const error_already_exists: windows.DWORD = 183;
const error_file_not_found: windows.DWORD = 2;
const error_access_denied: windows.DWORD = 5;
const error_invalid_parameter: windows.DWORD = 87;
const error_invalid_name: windows.DWORD = 123;
const error_not_enough_memory: windows.DWORD = 8;
const error_outofmemory: windows.DWORD = 14;
const error_commitment_limit: windows.DWORD = 1455;
const error_too_many_open_files: windows.DWORD = 4;

/// `SECTION_BASIC_INFORMATION` (`SectionBasicInformation`, class 0).
const SectionBasic = extern struct {
    base: ?*anyopaque,
    attributes: u32,
    size: i64,
};

/// The page size the kernel rounds a section to (x86-64 and ARM64 Windows alike).
const section_page = 4096;
/// The exact length's slot at the end of the section.
const trailer = @sizeOf(u64);

/// The longest name a section takes, `Local\` included, before the terminator.
const max_name = 260;

pub const Region = struct {
    /// Owned, NUL-terminated copy of the name as the caller gave it (POSIX form).
    name: [:0]const u8,
    /// The whole mapping. Owned by this struct.
    bytes: []align(page_align) u8,
    section: ?windows.HANDLE,
    /// True when this process created the section.
    owner: bool,

    /// Unmaps and closes the handle. The section ends with the last handle anywhere.
    pub fn close(self: *Region) void {
        if (self.bytes.len != 0) _ = UnmapViewOfFile(self.bytes.ptr);
        self.bytes = &.{};
        if (self.section) |handle| _ = CloseHandle(handle);
        self.section = null;
    }

    /// Nothing to remove: a section has no name apart from its handles.
    pub fn unlink(_: *Region) void {}

    /// Closes and frees the name. Use with `defer`.
    pub fn deinit(self: *Region, allocator: Allocator) void {
        self.close();
        if (self.name.ptr != empty_name.ptr) allocator.free(@constCast(self.name));
        self.name = empty_name;
    }
};

/// Creates a section of exactly `len` bytes and maps it read-write.
///
/// Fails with `error.AlreadyExists` when the name is taken — `CreateFileMappingW` then
/// returns the existing section, which is closed here rather than silently shared.
pub fn create(allocator: Allocator, name: []const u8, len: usize) Error!Region {
    if (len == 0) return error.InvalidArgument;
    var wide: [max_name:0]u16 = undefined;
    try sectionName(name, &wide);
    const z = try allocator.dupeSentinel(u8, name, 0);
    errdefer allocator.free(z);

    const total = std.mem.alignForward(usize, len + trailer, section_page);
    const size: u64 = total;
    const handle = CreateFileMappingW(
        invalid_handle,
        null,
        page_readwrite,
        @truncate(size >> 32),
        @truncate(size),
        &wide,
    ) orelse return mapError(GetLastError());
    if (GetLastError() == error_already_exists) {
        _ = CloseHandle(handle);
        return error.AlreadyExists;
    }
    errdefer _ = CloseHandle(handle);

    const whole = try mapView(handle, total);
    std.mem.writeInt(u64, whole[total - trailer ..][0..trailer], len, .little);
    return .{ .name = z, .bytes = whole[0..len], .section = handle, .owner = true };
}

/// Attaches to a section another process created, sized by the kernel's own record.
pub fn attach(allocator: Allocator, name: []const u8) Error!Region {
    var wide: [max_name:0]u16 = undefined;
    try sectionName(name, &wide);
    const z = try allocator.dupeSentinel(u8, name, 0);
    errdefer allocator.free(z);

    const handle = OpenFileMappingW(file_map_all_access, .FALSE, &wide) orelse return mapError(GetLastError());
    errdefer _ = CloseHandle(handle);

    var basic: SectionBasic = undefined;
    if (NtQuerySection(handle, 0, &basic, @sizeOf(SectionBasic), null) < 0) return error.Unexpected;
    if (basic.size < trailer) return error.InvalidArgument;
    const total: usize = @intCast(basic.size);

    const whole = try mapView(handle, total);
    const len = std.mem.readInt(u64, whole[total - trailer ..][0..trailer], .little);
    if (len == 0 or len > total - trailer) {
        _ = UnmapViewOfFile(whole.ptr);
        return error.InvalidArgument;
    }
    return .{ .name = z, .bytes = whole[0..@intCast(len)], .section = handle, .owner = false };
}

/// Nothing to remove on Windows; validates the name so a malformed one is still refused.
pub fn unlink(allocator: Allocator, name: []const u8) Error!void {
    _ = allocator;
    var wide: [max_name:0]u16 = undefined;
    try sectionName(name, &wide);
}

fn mapView(handle: windows.HANDLE, len: usize) Error![]align(page_align) u8 {
    const base = MapViewOfFile(handle, file_map_all_access, 0, 0, len) orelse return mapError(GetLastError());
    const aligned: [*]align(page_align) u8 = @ptrCast(@alignCast(base));
    return aligned[0..len];
}

/// `/name` → `Local\name`, UTF-16, NUL-terminated.
fn sectionName(name: []const u8, out: *[max_name:0]u16) Error!void {
    if (name.len == 0 or name[0] != '/') return error.InvalidName;
    const rest = name[1..];
    if (rest.len == 0) return error.InvalidName;
    if (std.mem.indexOfAny(u8, rest, "/\\\x00") != null) return error.InvalidName;
    const prefix = "Local\\";
    if (prefix.len + rest.len > max_name) return error.NameTooLong;
    var at: usize = 0;
    for (prefix) |byte| {
        out[at] = byte;
        at += 1;
    }
    const written = std.unicode.utf8ToUtf16Le(out[at..max_name], rest) catch return error.InvalidName;
    out[at + written] = 0;
}

fn mapError(code: windows.DWORD) Error {
    return switch (code) {
        error_already_exists => error.AlreadyExists,
        error_file_not_found => error.NotFound,
        error_access_denied => error.PermissionDenied,
        error_invalid_parameter => error.InvalidArgument,
        error_invalid_name => error.InvalidName,
        error_not_enough_memory, error_outofmemory => error.OutOfMemory,
        error_commitment_limit => error.NoSpaceLeft,
        error_too_many_open_files => error.FdQuotaExhausted,
        else => error.Unexpected,
    };
}

test "a section is shared by name, sized exactly, and gone with its last handle" {
    const allocator = std.testing.allocator;
    var buffered: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffered, "/lepton-shm-test-{d}", .{windows.GetCurrentProcessId()});

    // An odd size: a view is page-rounded, the section is not, and the channel splits
    // its region in half by this length.
    var made = try create(allocator, name, 12_345);
    try std.testing.expectError(error.AlreadyExists, create(allocator, name, 12_345));

    var seen = try attach(allocator, name);
    try std.testing.expectEqual(@as(usize, 12_345), seen.bytes.len);
    made.bytes[100] = 0x5a;
    try std.testing.expectEqual(@as(u8, 0x5a), seen.bytes[100]);
    seen.deinit(allocator);

    made.deinit(allocator);
    try std.testing.expectError(error.NotFound, attach(allocator, name));
}

test "names keep the POSIX form" {
    var wide: [max_name:0]u16 = undefined;
    try sectionName("/lepton-ledger", &wide);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Local\\lepton-ledger"), std.mem.sliceTo(&wide, 0));
    try std.testing.expectError(error.InvalidName, sectionName("lepton", &wide));
    try std.testing.expectError(error.InvalidName, sectionName("/a/b", &wide));
    try std.testing.expectError(error.InvalidName, sectionName("/a\\b", &wide));
    try std.testing.expectError(error.InvalidName, sectionName("/", &wide));
}
