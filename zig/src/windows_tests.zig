//! Root of `zig build test` on a Windows host. The core's own root (`root.zig`) reaches the
//! Linux window and display layers, which do not build there, so this lists the files
//! that make up the Windows build — and the shared ones it uses — so their tests run on
//! the system they are for.
test {
    _ = @import("platform/windows/paths.zig");
    _ = @import("platform/windows/dialog.zig");
    _ = @import("platform/grants.zig");
    _ = @import("render/webview/webview2/request.zig");
    _ = @import("ipc/shm.zig");
    _ = @import("ipc/ring.zig");
    _ = @import("ipc/wire.zig");
    _ = @import("ipc/ownership.zig");
    _ = @import("render/webview/invoke.zig");
    _ = @import("render/webview/registry.zig");
    _ = @import("render/webview/events.zig");
}
