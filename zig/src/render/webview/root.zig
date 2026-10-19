//! The webview render path.
//!
//! Selected at build time. `-Drender=webview` compiles this module in place of the
//! native one and links the engine; `-Drender=native` never references any of it, so
//! an engine cannot reach a native build however it was configured.
//!
//! Two engines behind one surface: WPE WebKit on Linux (`wpe_view.zig`), WebView2 on
//! Windows (`webview2/view.zig`). The template's `main.zig` drives both the same way.

const builtin = @import("builtin");

pub const wpe_view = @import("wpe_view.zig");
pub const webview2 = @import("webview2/view.zig");

const windows = builtin.os.tag == .windows;
const engine = if (windows) webview2 else wpe_view;

/// Whether this build contains a web engine.
pub fn is_available() bool {
    return if (windows) webview2.is_available() else wpe_view.is_available();
}

/// WPE is linked: the measurements and the display module below are WPE's own.
const wpe_linked = !windows and wpe_view.is_available();

/// The webview, or null when this build has no engine.
pub const View = if (is_available()) engine.View else void;

/// Measures which doors into the engine this build leaves open.
///
/// Gated rather than plain because every measurement in it is a call into the engine,
/// and a native build does not link the engine — an ungated reference asks the linker
/// for `wpe_display_get_default` and friends, which is the native path's whole point.
pub const caps = if (wpe_linked) @import("caps.zig") else void;

/// This framework's own `WPEDisplay`, as a loadable GIO extension module.
///
/// Loaded before the engine asks for a display, not after: `get_default` caches what it
/// finds, so pointing it at Lepton's display is a once-per-process act that has to come
/// first.
pub const platform = if (wpe_linked) @import("platform/root.zig") else void;

/// Runs one turn of the engine's event loop.
pub const pump = engine.pump;
pub const pumpBlocking = engine.pumpBlocking;
pub const wakeEvery = engine.wakeEvery;

/// Points the engine's web data at a directory of the caller's choosing.
///
/// Present on both ABIs: on the legacy one the engine has no such notion, so the call
/// compiles to nothing rather than failing at the call site — a template that asks for a
/// data directory must not fail to build on the engine that has no use for one.
pub const setDataDirectory = engine.setDataDirectory;
/// The application's own data and cache directories (`$APPDATA`, `$APPCACHE`).
pub const useApplicationDirectories = engine.useApplicationDirectories;

/// The backend implementation the loader actually brought up, if any.
///
/// Returns nothing rather than a name on a build with no engine, because there is no
/// loader to have brought anything up.
pub fn loadedBackend() ?[]const u8 {
    if (!is_available()) return null;
    return engine.loadedBackend();
}
