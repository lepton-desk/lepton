//! The render paths: what fills a frame.
//!
//! ## One surface, two renderers, one chosen at build time
//!
//! A renderer draws into a [`Surface`] and knows nothing about window systems,
//! shared memory or protocols. That is the whole design: the native path costs what
//! the frame costs and the webview path costs what an engine costs, and neither knows
//! what the other is.
//!
//! Which one is compiled in is read from the core's build options, not from a runtime
//! flag. A binary that carried both would carry the engine in the native build too —
//! which is the single thing the native path exists to avoid, and the reason this
//! selection happens in the build graph rather than in a `switch`.

const build_options = @import("build_options");

const surface = @import("surface.zig");
const text = @import("text.zig");
const webview = @import("webview/root.zig");

pub const Surface = surface.Surface;
pub const Colour = surface.Colour;
pub const Rect = surface.Rect;

/// The render path this build contains.
///
/// A compile-time value rather than a variable, so that the branch a renderer takes is
/// resolved before anything is compiled and the webview's sources are never even
/// referenced in a native build.
pub const is_native: bool = build_options.native_render;

/// Type rasterisation, available only when this build found Cairo and Pango.
///
/// Null rather than a stub when they are absent: a caller that asked for text on a
/// machine without a text stack should be told the machine cannot, not handed a
/// function that draws nothing and reports success.
pub const Text = if (build_options.have_cairo)
    text.Text
else
    void;

/// Whether this build can draw type.
pub const can_draw_text: bool = build_options.have_cairo;

/// The webview, or null when this build has no engine.
pub const WebView = if (webview.is_available()) webview.View else void;

/// Whether this build can load a page.
pub const can_load_pages: bool = webview.is_available();

/// The WPE backend implementation the loader actually brought up, if any.
pub const loaded_webview_backend = webview.loadedBackend;

/// Points the engine's web data at a directory of the caller's choosing.
///
/// Exposed here because the setter lives beside the other engine declarations rather than
/// on `View`: it is read when the *context* is created, which happens before there is a
/// view to ask.
pub const set_webview_data_directory = webview.setDataDirectory;
/// Each application's web storage in its own `$APPDATA`; call before opening the view.
pub const use_application_directories = webview.useApplicationDirectories;

/// What the installed engine allows, measured. `void` in a native build.
pub const engine_caps = webview.caps;

/// This framework's own display and the loader that points the engine at it.
///
/// Exported whole rather than member by member because the two halves only make sense
/// together: the module has to be resident before the engine is asked for a display.
pub const webview_platform = webview.platform;


/// Runs one turn of the web engine's event loop.
pub const pump_webview = webview.pump;
pub const pump_webview_blocking = webview.pumpBlocking;
pub const wake_webview_every = webview.wakeEvery;

/// Why a render path is not usable on this machine.
pub const Error = error{
    /// The build has no text stack, and the panel was asked to draw type.
    NoTextStack,
};

test {
    _ = @import("surface_test.zig");
    if (can_draw_text) _ = @import("text_test.zig");
}
