//! Serving the bundled frontend from `lepton://localhost/`.
//!
//! A packaged application cannot load its frontend from `file://`: WebKit gives file
//! documents an opaque origin, Vite emits `<script type="module" crossorigin>`, and the
//! module is refused — measured as a blank window with the bundle on disk. Serving the
//! same files through the core's own scheme gives the document a real origin
//! (`lepton://localhost`), on which storage was measured to persist across loads
//! (`webview-check`, `LEPTON_CHECK_BASE=lepton://localhost/`: `absent-kept`, `kept-kept`).
//!
//! This module decides which file a request names and what it is; the bridge answers.
//! Paths are confined to the root: a request is percent-decoded first and then refused
//! if any segment is `..`, `.`, empty, or hidden, so no encoding of a traversal survives.

const std = @import("std");

/// The host the frontend is served on. Any other host on the scheme is the IPC channel.
/// On Windows the frontend and the channel share `lepton.localhost` (`webview2/view.zig`).
pub const host = if (@import("builtin").os.tag == .windows) "lepton.localhost" else "localhost";

/// The longest path this module will build. Paths past it are refused, not truncated.
pub const max_path = 4096;

/// Why a request was not turned into a file path.
pub const Refusal = error{ NotConfined, TooLong, BadEncoding };

/// Joins `root` and the request path into `out` and returns it, NUL-terminated.
///
/// `/` and any path ending in `/` name `index.html` in that directory, which is what a
/// static server does and what a single-page app's entry expects.
pub fn resolve(root: []const u8, request_path: []const u8, out: []u8) Refusal![:0]const u8 {
    var decoded_buffer: [max_path]u8 = undefined;
    const decoded = try percentDecode(request_path, &decoded_buffer);

    var writer: Writer = .{ .out = out };
    try writer.put(root);

    var segments = std.mem.splitScalar(u8, decoded, '/');
    var wrote_any = false;
    var last_was_empty = true;
    while (segments.next()) |segment| {
        if (segment.len == 0) {
            last_was_empty = true;
            continue;
        }
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".") or segment[0] == '.') {
            return error.NotConfined;
        }
        if (std.mem.indexOfScalar(u8, segment, 0) != null or std.mem.indexOfScalar(u8, segment, '\\') != null) {
            return error.NotConfined;
        }
        try writer.put("/");
        try writer.put(segment);
        if (windows and !windowsSafe(segment)) return error.NotConfined;
        wrote_any = true;
        last_was_empty = false;
    }
    if (!wrote_any or last_was_empty) try writer.put("/index.html");
    return writer.finish();
}

const windows = @import("builtin").os.tag == .windows;

/// Whether a path segment names an ordinary file on Windows: no `:` (a drive, or an
/// alternate data stream — `index.html:secret`), and not a device (`CON`, `NUL`,
/// `COM1`…, with or without an extension), which `CreateFileW` opens instead of a file.
fn windowsSafe(segment: []const u8) bool {
    if (std.mem.indexOfScalar(u8, segment, ':') != null) return false;
    const stem_end = std.mem.indexOfScalar(u8, segment, '.') orelse segment.len;
    const stem = std.mem.trimEnd(u8, segment[0..stem_end], " ");
    const devices = [_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" };
    for (devices) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return false;
    }
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "com") or std.ascii.startsWithIgnoreCase(stem, "lpt")) and
        std.ascii.isDigit(stem[3])) return false;
    return true;
}

/// The content type for a file, by extension. Unknown types are served as bytes rather
/// than guessed at: a script served as `text/plain` is refused by the engine anyway.
pub fn mimeFor(path: []const u8) [:0]const u8 {
    const extension = std.fs.path.extension(path);
    const table = [_]struct { []const u8, [:0]const u8 }{
        .{ ".html", "text/html" },
        .{ ".js", "text/javascript" },
        .{ ".mjs", "text/javascript" },
        .{ ".css", "text/css" },
        .{ ".json", "application/json" },
        .{ ".map", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".webp", "image/webp" },
        .{ ".gif", "image/gif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff2", "font/woff2" },
        .{ ".woff", "font/woff" },
        .{ ".wasm", "application/wasm" },
        .{ ".txt", "text/plain" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

/// A whole file in a `malloc` buffer, so the engine can free it with libc's `free` when
/// its stream is done — the buffer outlives this call by design.
pub const Loaded = struct {
    bytes: [*]u8,
    len: usize,
};

/// Reads the file at `path` in full. `null` when it cannot be opened or read.
pub fn load(path: [:0]const u8) ?Loaded {
    if (windows) return loadWindows(path);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var capacity: usize = 16 * 1024;
    var buffer: [*]u8 = @ptrCast(std.c.malloc(capacity) orelse return null);
    var len: usize = 0;
    while (true) {
        if (len == capacity) {
            capacity *= 2;
            const grown = std.c.realloc(buffer, capacity) orelse {
                std.c.free(buffer);
                return null;
            };
            buffer = @ptrCast(grown);
        }
        const got = std.c.read(fd, buffer + len, capacity - len);
        if (got < 0) {
            std.c.free(buffer);
            return null;
        }
        if (got == 0) break;
        len += @intCast(got);
    }
    return .{ .bytes = buffer, .len = len };
}

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadFile(file: *anyopaque, buffer: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetFileType(file: *anyopaque) callconv(.winapi) u32;

/// `load` on Windows: the UTF-8 path as UTF-16 (forward slashes are accepted), opened
/// for reading and shared, and refused unless it is a disk file.
fn loadWindows(path: [:0]const u8) ?Loaded {
    var wide: [max_path:0]u16 = undefined;
    const units = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], path) catch return null;
    wide[units] = 0;
    const generic_read: u32 = 0x80000000;
    const share_read_write: u32 = 0x1 | 0x2;
    const open_existing: u32 = 3;
    const invalid: usize = std.math.maxInt(usize);
    const handle = CreateFileW(&wide, generic_read, share_read_write, null, open_existing, 0x80, null) orelse return null;
    if (@intFromPtr(handle) == invalid) return null;
    defer _ = CloseHandle(handle);
    const file_type_disk: u32 = 1;
    if (GetFileType(handle) != file_type_disk) return null;

    var capacity: usize = 16 * 1024;
    var buffer: [*]u8 = @ptrCast(std.c.malloc(capacity) orelse return null);
    var len: usize = 0;
    while (true) {
        if (len == capacity) {
            capacity *= 2;
            const grown = std.c.realloc(buffer, capacity) orelse {
                std.c.free(buffer);
                return null;
            };
            buffer = @ptrCast(grown);
        }
        var got: u32 = 0;
        const asked: u32 = @intCast(@min(capacity - len, std.math.maxInt(u32)));
        if (ReadFile(handle, buffer + len, asked, &got, null) == 0) {
            std.c.free(buffer);
            return null;
        }
        if (got == 0) break;
        len += got;
    }
    return .{ .bytes = buffer, .len = len };
}

const Writer = struct {
    out: []u8,
    len: usize = 0,

    fn put(self: *Writer, text: []const u8) Refusal!void {
        if (self.len + text.len + 1 > self.out.len) return error.TooLong;
        @memcpy(self.out[self.len..][0..text.len], text);
        self.len += text.len;
    }

    fn finish(self: *Writer) [:0]const u8 {
        self.out[self.len] = 0;
        return self.out[0..self.len :0];
    }
};

fn percentDecode(text: []const u8, out: []u8) Refusal![]const u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (len += 1) {
        if (len == out.len) return error.TooLong;
        if (text[i] == '?' or text[i] == '#') break;
        if (text[i] == '%') {
            if (i + 2 >= text.len) return error.BadEncoding;
            const value = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.BadEncoding;
            out[len] = value;
            i += 3;
        } else {
            out[len] = text[i];
            i += 1;
        }
    }
    return out[0..len];
}

test "the root and a trailing slash name the index" {
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings("/srv/dist/index.html", try resolve("/srv/dist", "/", &buffer));
    try std.testing.expectEqualStrings("/srv/dist/index.html", try resolve("/srv/dist", "", &buffer));
    try std.testing.expectEqualStrings("/srv/dist/docs/index.html", try resolve("/srv/dist", "/docs/", &buffer));
}

test "an asset path is joined under the root, query and fragment dropped" {
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/srv/dist/assets/index-dqQyW6uo.js",
        try resolve("/srv/dist", "/assets/index-dqQyW6uo.js?v=1#x", &buffer),
    );
}

test "no spelling of a traversal escapes the root" {
    var buffer: [max_path]u8 = undefined;
    const attempts = [_][]const u8{
        "/../etc/passwd",
        "/assets/../../etc/passwd",
        "/%2e%2e/etc/passwd",
        "/%2E%2E%2Fetc%2Fpasswd",
        "/./index.html",
        "/.env",
        "/a%00b",
        "/a%5c..%5cb",
    };
    for (attempts) |attempt| {
        if (resolve("/srv/dist", attempt, &buffer)) |escaped| {
            std.debug.print("{s} resolved to {s}\n", .{ attempt, escaped });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a broken escape is refused rather than passed through" {
    var buffer: [max_path]u8 = undefined;
    try std.testing.expectError(error.BadEncoding, resolve("/srv", "/a%zz", &buffer));
    try std.testing.expectError(error.BadEncoding, resolve("/srv", "/a%2", &buffer));
}

test "a path longer than the buffer is refused, not truncated" {
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.TooLong, resolve("/srv/dist", "/assets/a-long-name.js", &small));
}

test "the types a Vite bundle needs are named" {
    try std.testing.expectEqualStrings("text/javascript", mimeFor("/x/index-abc.js"));
    try std.testing.expectEqualStrings("text/css", mimeFor("a.CSS"));
    try std.testing.expectEqualStrings("font/woff2", mimeFor("f.woff2"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("blob.bin"));
}

test "a real file is read whole, and a missing one is not" {
    if (windows) return loadsOnWindows();
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buffer, "/tmp/lepton-assets-{d}.bin", .{std.c.getpid()}, 0);
    const fd = std.c.open(name.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    // Larger than the first buffer, so the growth path runs.
    var payload: [40 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 7);
    try std.testing.expectEqual(@as(isize, payload.len), std.c.write(fd, &payload, payload.len));
    _ = std.c.close(fd);
    defer _ = std.c.unlink(name.ptr);

    const loaded = load(name) orelse return error.TestUnexpectedResult;
    defer std.c.free(loaded.bytes);
    try std.testing.expectEqualSlices(u8, &payload, loaded.bytes[0..loaded.len]);

    try std.testing.expect(load("/tmp/lepton-assets-does-not-exist") == null);
}

/// The same, through `CreateFileW`: a file in a test directory, its path in forward
/// slashes as `resolve` builds it, and a device name refused even if asked directly.
fn loadsOnWindows() !void {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var payload: [40 * 1024]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 7);
    try dir.dir.writeFile(io, .{ .sub_path = "bundle.bin", .data = &payload });
    var root_buffer: [max_path]u8 = undefined;
    const root_len = try dir.dir.realPath(io, &root_buffer);
    var path_buffer: [max_path]u8 = undefined;
    const path = try resolve(root_buffer[0..root_len], "/bundle.bin", &path_buffer);

    const loaded = load(path) orelse return error.TestUnexpectedResult;
    defer std.c.free(loaded.bytes);
    try std.testing.expectEqualSlices(u8, &payload, loaded.bytes[0..loaded.len]);
    try std.testing.expect(load(try resolve(root_buffer[0..root_len], "/absent.bin", &path_buffer)) == null);
    try std.testing.expectError(error.NotConfined, resolve(root_buffer[0..root_len], "/nul.txt", &path_buffer));
    try std.testing.expectError(error.NotConfined, resolve(root_buffer[0..root_len], "/index.html:stream", &path_buffer));
    try std.testing.expectError(error.NotConfined, resolve(root_buffer[0..root_len], "/COM1", &path_buffer));
}
