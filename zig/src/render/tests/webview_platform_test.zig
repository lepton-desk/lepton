//! Integration tests for the WPEWebKit platform layer, against the engine actually
//! installed on this machine.
//!
//! These exist because two of the rules this core depends on are enforced by
//! *assertions inside the engine*, not by anything in our control. A rule that lives
//! in a `g_assert` three libraries away is invisible to a compile check and to a code
//! read: the failure surfaces as a null pointer far from its cause. So both rules are
//! pinned here by running them.
//!
//! Nothing here is simulated. Every call crosses into the real libWPEWebKit, and every
//! assertion is about what the real library actually does on this build.
//!
//! The expected noise: WebKit answers some of these with `GLib-CRITICAL` lines on
//! stderr. That is the behaviour under test, not a problem with the test — the library
//! is refusing an argument, and refusing loudly is what makes the refusal legible.

const std = @import("std");
const abi = @import("../webview/wpe_abi.zig");
const wpe_view = @import("../webview/wpe_view.zig");
const caps = @import("../webview/caps.zig");

// These tests exercise the pre-2.54 ABI, and they call its symbols directly — which is
// the point, since what they pin down is that those symbols do not do what their names
// suggest. On a 2.54 build the symbols are not in the engine at all, so the tests are
// compiled out rather than rewritten: a version of "no backend can be injected" that
// ran against an API with no backend to inject would be asserting nothing.
const legacy_abi = !@import("build_options").wpe_platform_abi;

// The engine is a process-wide singleton: the loader takes the backend library once,
// and the display, once created, never goes away. Several entry points start it, so
// it has to be harmless to start more than once. This state stays at container level
// because a `comptime` block holds no mutable state, and these tests are sequential
// and share one engine.
var loader_started = false;

fn engineAvailable() bool {
    // On the 2.54 platform ABI there is no loader and no backend library: the platform
    // integration moved inside the engine, so nothing here has to be started before the
    // engine will answer.
    if (comptime @import("build_options").wpe_platform_abi) return true;
    if (loader_started) return true;
    loader_started = abi.wpe_loader_init("libWPEBackend-fdo-1.0.so");
    return loader_started;
}

test "the engine hands out a display, and a view built from it has a WPEView" {
        // This is the ordering the whole webview path rests on, exercised through the
        // production entry point rather than a reimplementation of it. `open` refuses
        // with `Error.NoDisplay` before it constructs anything if the display is
        // missing, and with `Error.NoView` if the view yields no WPEView — so passing
        // means the loader, the display and the view were all real, in that order.
        if (!engineAvailable()) return error.SkipZigTest;

        var view = try wpe_view.View.open();
        defer view.close();

        // A display is not optional: a view without one answers null here, and the
        // WPEView is built from the display. So this is the same condition the
        // ordering guards against, read from the other side.
        try std.testing.expect(abi.webkit_web_view_get_display(view.web_view) != null);
        try std.testing.expect(abi.webkit_web_view_get_wpe_view(view.web_view) != null);
}

test "no view backend can be injected, and null is the only working argument" {
    if (comptime legacy_abi) {
        // Why `webkit_web_view_new` is handed null is neither obvious nor documented
        // anywhere a reader would reach. It is two dead ends that close from both
        // sides:
        //
        //   `wpe_view_backend_create` returns null on a correctly installed fdo
        //   backend, so there is no backend object to wrap;
        //
        //   `webkit_web_view_backend_new` asserts on a null backend, so a backend that
        //   does exist is the only thing it will accept.
        //
        // Together they leave nothing to pass. Passing something anyway is not merely
        // unwise: the engine asserts `!backend || !isUsingWPEPlatformAPI()` and returns
        // null, which would reach the core as a missing view with no nearer cause.
        if (!engineAvailable()) return error.SkipZigTest;

        try std.testing.expect(abi.wpe_display_get_default() != null);

        const created = abi.wpe_view_backend_create();
        try std.testing.expect(created == null);

        // With no backend to wrap, the wrapper refuses the null it is handed rather
        // than producing something that could be passed on.
        try std.testing.expect(abi.webkit_web_view_backend_new(created, null, null) == null);

        // And the path the core takes is the one that yields a view.
        const view = abi.webkit_web_view_new(null);
        try std.testing.expect(view != null);
        try std.testing.expect(abi.webkit_web_view_get_wpe_view(view.?) != null);
        abi.g_object_unref(view);
    }
    }

test "the engine's answer is measured, and the route is derived from the measurement" {
    // Not "the route is engine_owns_display". That is this machine's answer, and a
    // framework that hardcoded it would report a bug on every machine where WebKit
    // behaves differently. What has to hold everywhere is that the route *follows* the
    // measurements — which is what makes the report worth reading.
    if (!engineAvailable()) return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const report = try caps.measure(allocator);

    try std.testing.expect(report.engine_present);
    // Both displays have a name, which means both were real objects rather than nulls.
    // A null display silently compares unequal to itself and would make the decisive
    // measurement answer "no" for the wrong reason.
    try std.testing.expect(report.default_display_type.len > 0);
    try std.testing.expect(report.owned_display_type.len > 0);

    const expected: caps.Route = if (report.owned_display_used)
        .display_substitutable
    else if (report.backend_accepted)
        .backend_injectable
    else
        .engine_owns_display;
    try std.testing.expectEqual(expected, report.route());
}

test "every route is reachable, so the derivation is not just this build's answer" {
    // The measurement above cannot cover all three branches: on a build where the engine
    // owns the display, both measurements are false and `route` answers
    // `engine_owns_display` whichever way it derives it. A test that passed here could
    // still be a table of constants.
    //
    // So the derivation is exercised over all four combinations of the two flags.
    // `Report` is a plain value with no handle in it, and `route` reads nothing but
    // those two booleans — which makes this a test of the function rather than of any
    // engine behaviour, and it is the only way to cover the branches this machine
    // cannot reach.
    const cases = [_]struct { owned: bool, backend: bool, want: caps.Route }{
        .{ .owned = true, .backend = true, .want = .display_substitutable },
        .{ .owned = true, .backend = false, .want = .display_substitutable },
        .{ .owned = false, .backend = true, .want = .backend_injectable },
        .{ .owned = false, .backend = false, .want = .engine_owns_display },
    };

    for (cases) |case| {
        const report: caps.Report = .{
            .engine_present = true,
            .default_display_type = "WPEDisplayWayland",
            .owned_display_type = "WPEDisplayHeadless",
            .owned_display_used = case.owned,
            .backend_accepted = case.backend,
        };
        try std.testing.expectEqual(case.want, report.route());
        try std.testing.expect(report.route().describe().len > 0);
    }
}
