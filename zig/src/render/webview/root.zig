//! The webview render path.
//!
//! Selected at build time. `-Drender=webview` compiles this module in place of the
//! native one and links the engine; `-Drender=native` never references any of it, so
//! an engine cannot reach a native build however it was configured.

pub const wpe_view = @import("wpe_view.zig");

/// The webview, or null when this build has no engine.
pub const View = if (wpe_view.is_available()) wpe_view.View else void;

pub const is_available = wpe_view.is_available;

/// Measures which doors into the engine this build leaves open.
///
/// Gated rather than plain because every measurement in it is a call into the engine,
/// and a native build does not link the engine — an ungated reference asks the linker
/// for `wpe_display_get_default` and friends, which is the native path's whole point.
pub const caps = if (wpe_view.is_available()) @import("caps.zig") else void;

/// This framework's own `WPEDisplay`, as a loadable GIO extension module.
///
/// Loaded before the engine asks for a display, not after: `get_default` caches what it
/// finds, so pointing it at Lepton's display is a once-per-process act that has to come
/// first.
pub const platform = if (wpe_view.is_available()) @import("platform/root.zig") else void;

/// Runs one turn of the engine's event loop.
pub const pump = wpe_view.pump;
pub const pumpBlocking = wpe_view.pumpBlocking;
pub const wakeEvery = wpe_view.wakeEvery;

/// Points the engine's web data at a directory of the caller's choosing.
///
/// Present on both ABIs: on the legacy one the engine has no such notion, so the call
/// compiles to nothing rather than failing at the call site — a template that asks for a
/// data directory must not fail to build on the engine that has no use for one.
pub const setDataDirectory = wpe_view.setDataDirectory;

/// The backend implementation the loader actually brought up, if any.
///
/// Returns nothing rather than a name on a build with no engine, because there is no
/// loader to have brought anything up.
pub fn loadedBackend() ?[]const u8 {
    if (!wpe_view.is_available()) return null;
    return wpe_view.loadedBackend();
}
