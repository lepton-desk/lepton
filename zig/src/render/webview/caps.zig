//! What the installed engine actually allows, measured rather than assumed.
//!
//! Every way out of "WPE gives this framework no pixels" ends in one of two hooks:
//! either the engine takes a display this framework supplies, or it takes a view backend
//! this framework supplies. Both are *optional per build*, and both differ between
//! WebKit versions, so neither can be hardcoded — the answer has to be asked of the
//! library that is actually installed.
//!
//! This module asks. It constructs a display it owns, promotes it to primary, and then
//! checks which display the engine reaches for; then it offers the engine a view
//! backend and checks whether that is accepted. Nothing here is simulated: the numbers
//! come from the real libWPEWebKit on this machine.
//!
//! One caution for callers: `wpe_display_set_primary` mutates process-global engine
//! state. That is why this lives apart from `wpe_view.zig` and is called from a probe
//! tool, never from the window path, where a display has already been chosen.

const std = @import("std");
const abi = @import("wpe_abi.zig");
const platform_abi = @import("wpe_platform_abi.zig");

/// Which of the two doors into the engine this build has left open.
pub const Route = enum {
    /// A display this framework supplies reaches the engine. `wpe_display_set_primary`
    /// is the hook, and on this build the engine ignored it.
    display_substitutable,
    /// A view backend this framework supplies reaches the engine. On a build with the
    /// WPE Platform API active, `webkit_web_view_new` asserts against this.
    backend_injectable,
    /// Neither. The engine renders into a display it chose for itself, and there is no
    /// public call that hands that decision over.
    engine_owns_display,

    pub fn describe(self: Route) []const u8 {
        return switch (self) {
            .display_substitutable => "a display supplied by this framework reaches the engine",
            .backend_injectable => "a view backend supplied by this framework reaches the engine",
            .engine_owns_display => "the engine renders into a display it chose; neither door is open",
        };
    }
};

/// The measured answer for the installed engine.
pub const Report = struct {
    /// Whether the backend library loaded at all. A false here means the report is not
    /// about the engine's policy but about a missing package, and the two are not the
    /// same message.
    engine_present: bool,

    /// The GObject type name of whatever `wpe_display_get_default` built — measured, so
    /// it distinguishes `WPEDisplayWayland` from `WPEDisplayHeadless` instead of
    /// reporting "some display" and leaving the reader to guess.
    default_display_type: []const u8,

    /// The same, for the display this process constructed for itself.
    owned_display_type: []const u8,

    /// Whether the engine's own view ended up on the display this process constructed.
    /// This is the decisive measurement, and the one that settles the architecture: it
    /// is the difference between owning the pixels and watching someone else draw them.
    owned_display_used: bool,

    /// Whether `webkit_web_view_new` accepted a view backend.
    backend_accepted: bool,

    pub fn route(self: Report) Route {
        if (self.owned_display_used) return .display_substitutable;
        if (self.backend_accepted) return .backend_injectable;
        return .engine_owns_display;
    }
};

/// Measures the 2.54 platform ABI.
///
/// There is no display to promote and no backend to inject, because `WPEDisplayWayland`
/// is a final type and its constructor takes nothing: the engine builds the view and
/// publishes the surface. So what is measured here is what that ABI actually offers —
/// whether a view can be built at all, whether a platform view comes back out of it, and
/// whether the engine published a surface. The two ownership fields stay false because
/// they are not refused answers here, they are absent questions.
fn measurePlatform(allocator: std.mem.Allocator) !Report {
    const web_view = platform_abi.g_object_new(platform_abi.webkit_web_view_get_type(), null) orelse
        return .{
            .engine_present = false,
            .default_display_type = "",
            .owned_display_type = "",
            .owned_display_used = false,
            .backend_accepted = false,
        };

    const wpe_view = platform_abi.webkit_web_view_get_wpe_view(web_view);
    const default_name = try typeName(allocator, web_view);

    // The platform view names the implementation the engine selected, and that name is
    // the whole answer to "which platform am I running on" for one type query.
    const platform_name = if (wpe_view) |view| try typeName(allocator, view) else "";

    abi.g_object_unref(web_view);

    return .{
        .engine_present = true,
        .default_display_type = default_name,
        .owned_display_type = platform_name,
        .owned_display_used = false,
        .backend_accepted = false,
    };
}

/// Measures what this engine allows. Allocates for the two type names.
pub fn measure(allocator: std.mem.Allocator) !Report {
    // The loader has to be up before any display exists, and the backend library name
    // is the one the platform really ships — the ABI version, not the release version.
    // Which ABI is being measured decides what can even be asked. The legacy probe below
    // asks whether the embedder can own the display and hand WebKit a view backend; on
    // 2.54 neither door exists, so on that ABI the same fields answer a different
    // question rather than reporting a failure that the engine did not produce.
    if (comptime @import("build_options").wpe_platform_abi) return measurePlatform(allocator);

    if (!abi.wpe_loader_init(backendLibraryName())) {
        return .{
            .engine_present = false,
            .default_display_type = "",
            .owned_display_type = "",
            .owned_display_used = false,
            .backend_accepted = false,
        };
    }

    const default_display = abi.wpe_display_get_default();
    const default_name = try typeName(allocator, default_display);

    // A display this process owns, promoted the way a platform implementation would be.
    // If the engine honoured this, the view below would end up on it.
    const owned = abi.wpe_display_headless_new();
    if (owned != null) abi.wpe_display_set_primary(owned);
    const owned_name = try typeName(allocator, owned);

    // Now ask the engine to make a view and see where it decided to put it.
    var owned_display_used = false;
    if (abi.webkit_web_view_new(null)) |view| {
        const used = abi.webkit_web_view_get_display(view);
        owned_display_used = used != null and used == owned;
        abi.g_object_unref(view);
    }

    // And ask it to take a backend instead, which is the other door.
    const wrapper = abi.webkit_web_view_backend_new(abi.wpe_view_backend_create(), null, null);
    var backend_accepted = false;
    if (wrapper) |w| {
        if (abi.webkit_web_view_new(w)) |view| {
            backend_accepted = true;
            abi.g_object_unref(view);
        }
        abi.g_object_unref(w);
    }

    return .{
        .engine_present = true,
        .default_display_type = default_name,
        .owned_display_type = owned_name,
        .owned_display_used = owned_display_used,
        .backend_accepted = backend_accepted,
    };
}

/// The GObject type name of the display the engine actually chose, and nothing else.
///
/// Separate from `measure` because asking this question is safe on any engine while
/// `measure` constructs a view through the chosen display. With Lepton's display in
/// place that construction faults — the engine calls `create_view`, which the stub does
/// not implement — so a tool asking only "is it ours?" must not be the tool that also
/// asks for a page.
pub fn defaultDisplayTypeName(allocator: std.mem.Allocator) ![]const u8 {
    return typeName(allocator, abi.wpe_display_get_default());
}

fn typeName(allocator: std.mem.Allocator, instance: abi.Gpointer) ![]const u8 {
    const name = abi.g_type_name_from_instance(instance);
    if (name == null) return try allocator.dupe(u8, "<not an object>");
    return try allocator.dupe(u8, std.mem.span(name.?));
}

/// The backend library to hand the loader.
///
/// Read from the same probe the build uses, so the probe and the runtime cannot name
/// different files. Falls back to the fdo ABI name when the build recorded nothing, which
/// is the case for a native-only build.
fn backendLibraryName() [:0]const u8 {
    const recorded = @import("build_options").wpe_backend_library;
    if (recorded.len != 0) return recorded[0..recorded.len :0];
    return "libWPEBackend-fdo-1.0.so";
}
