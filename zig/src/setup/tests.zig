//! setup.exe's platform-free half, tested on any host (`zig build setup-test`).
test {
    _ = @import("payload.zig");
    _ = @import("text.zig");
}
