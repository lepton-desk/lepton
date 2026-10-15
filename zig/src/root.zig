//! Lepton core: the window, its render path, and the zero-copy channel between
//! them and the webview.
//!
//! The module is organised by concern, not by platform:
//!
//! * `ipc.shm` — POSIX shared memory, bound to the system C ABI.
//! * `ipc.ring` — a bounded MPMC ring living inside that mapping.
//! * `ipc.wire` — the fixed-layout frame every ring cell carries. No JSON, no
//!   text: a frame is a header plus a payload of a known shape.
//! * `ipc.channel` — the typed channel built from the two above, plus the
//!   window/server split that makes the webview a peer rather than a child.
//! * `platform.linux.display` — the X11/Wayland probe, read through XCB and the
//!   Wayland client library rather than a toolkit.
//!
//! `std` is re-exported so consumers can reach the exact version the core was
//! compiled against; a UI surface that links a different one would be a
//! different program wearing Lepton's name.

const std = @import("std");

pub const shm = @import("ipc/shm.zig");
pub const ring = @import("ipc/ring.zig");
pub const wire = @import("ipc/wire.zig");
pub const channel = @import("ipc/channel.zig");
pub const ownership = @import("ipc/ownership.zig");
pub const probe = @import("metrics/probe.zig");
pub const latency = @import("metrics/latency.zig");
pub const display = @import("platform/linux/display.zig");
/// The user's base directories (`$APPDATA`, `$DOCUMENT`, …), for plugins.
pub const paths = @import("platform/linux/paths.zig");
/// A plugin's settings from `lepton.config.json`'s `plugins`, read at compile time.
pub const pluginConfig = @import("plugin_config.zig");
pub const window = @import("window/window.zig");

/// The frame the render layer draws into, and the render paths that fill it.
///
/// Exported from the root so a project importing `lepton_core` gets the surface type
/// without knowing which render path it was built with — the whole point of the
/// split being that the frontend does not change between them.
pub const surface = @import("render/surface.zig");
pub const render = @import("render/root.zig");

/// Backends, exported so tooling can reach them without reaching through
/// `window`'s dispatch, which is opaque by design.
pub const waylandWindow = @import("window/linux/wayland_window.zig");

/// Pointer and keyboard state for the Wayland path.
///
/// Exported beside the window types so its tests are part of the core's run: the rules it
/// holds are the ones a window's behaviour rests on, and a rule that is only tested when
/// something happens to reach it is a rule that quietly stops being true.
pub const waylandInput = @import("window/linux/input.zig");

/// What a click means, and where the titlebar's controls sit.
///
/// Beside the input state and for the same reason: the mapping from a point to an action
/// is behaviour worth testing, and behaviour that lives behind a C callback cannot be
/// reached from a test.
pub const waylandChrome = @import("window/linux/chrome.zig");

/// The core's side of the conversation with the page.
///
/// Exported because its tests are part of the core's run: a bridge that is never asked
/// anything looks exactly like a working one until a page loads.
pub const webviewBridge = @import("render/webview/bridge.zig");
/// `invoke` frames and the layout the page reads them with: pure, no engine needed, so
/// `invoke-check` can answer the SDK's tests from the real handler.
pub const webviewInvoke = @import("render/webview/invoke.zig");
/// Application commands and the permission list (`registry.checked`).
pub const webviewRegistry = @import("render/webview/registry.zig");
/// The event log the page reads from (`/__lepton/events`).
pub const webviewEvents = @import("render/webview/events.zig");
/// `src/lepton-commands.d.ts` for an application's commands and events.
pub const webviewDeclarations = @import("render/webview/declarations.zig");
/// The system clipboard as text, for `@lepton-desk/plugin-clipboard`; `Failed` without WPE.
pub const webviewClipboard = @import("render/webview/clipboard.zig");
pub const webviewTransport = @import("render/webview/transport.zig");
pub const x11Window = @import("window/linux/x11_window.zig");

/// The `std` this core was built against.
pub const std_lib = std;

test {
    // Pulls in every declaration so a compile error anywhere in the core fails
    // the test build, then runs the suites that exercise real kernel state.
    std.testing.refAllDecls(@This());
    _ = @import("ipc/tests/ipc_integration.zig");
    _ = @import("platform/linux/display_test.zig");
    _ = @import("metrics/probe_test.zig");
    _ = @import("metrics/latency.zig");
    _ = @import("window/window.zig");
    _ = @import("window/linux/placement.zig");
    _ = @import("window/linux/gesture.zig");
    _ = @import("window/linux/wayland_shell.zig");
    _ = @import("render/webview/assets.zig");
    _ = @import("render/webview/bridge.zig");
    _ = @import("render/webview/transport.zig");
    _ = @import("render/webview/respond.zig");
    _ = @import("render/webview/invoke.zig");
    _ = @import("render/webview/registry.zig");
    _ = @import("render/webview/events.zig");
    _ = @import("render/webview/declarations.zig");
    _ = @import("window/linux/chrome_test.zig");
    // `comptime` is load-bearing and not a stylistic choice. Without it this reads as
    // a runtime branch whose body still gets compiled, and compiling it in a native
    // build asks the linker for `wpe_display_get_default`, `webkit_web_view_new` and
    // the rest — sixteen undefined symbols, none of which are linked in that
    // configuration. With it, the branch is resolved before the body is analysed.
    if (comptime @import("render/webview/root.zig").is_available()) {
        _ = @import("render/tests/webview_platform_test.zig");
    }
}
