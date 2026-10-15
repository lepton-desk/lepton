//! Opens the real WPE engine, loads a real page, and reports what the engine says.
//!
//! The webview path's counterpart to `native_check.zig`, and it answers the only
//! question this path can currently answer honestly: does the engine start, take a
//! page, and report a settled state on this machine?
//!
//! It deliberately does **not** report a frame. Two different reasons, and conflating them
//! would be the worst outcome:
//!
//! - With the **stock** engine, WPE gives an embedder no render target at all —
//!   `struct wpe_view_backend_interface` is four members deep and none of them is one — so
//!   there is no buffer to compare against a surface and nothing to put on screen.
//! - With **Lepton's own display** there *is* a render target, and the engine hands over
//!   its buffer formats (`buffers_changed`). This framework has not yet allocated a buffer
//!   from them, so `frames_read_back` is zero, and until it is not this tool would be
//!   reporting a measurement it never took.
//!
//! A check that printed "page rendered" in either case would be lying about work not done.
//!
//! Set `LEPTON_PLATFORM=lepton` and the check runs the same journey on **Lepton's own
//! display** instead, which is the measurement that matters now that the display can be
//! supplied: the engine takes the page on a display this framework owns. It still claims
//! no frame — this framework has not yet implemented the buffer handshake that would make
//! one — but it does say which display the page landed on, so "it worked" and "it worked
//! where it matters" stop being the same claim.
//!
//! Every line below is the engine's own answer, not a proxy for it: `isMapped` and
//! `isLoading` are the same predicates the engine's own bindings expose, and the URI
//! is what it settled on after redirects.

const std = @import("std");

const core = @import("lepton_core");

const Size = core.window.Size;

/// The page the engine is asked for. A `data:` URL, so the check needs no network and
/// no server: it is testing the engine, and a page on disk would only add a second
/// thing that can be wrong.
/// The page, which asks the core for something and shows what came back.
///
/// The fetch is the point of the check: a bridge that nothing asks from reports zero
/// requests and looks identical to a bridge that works. So the page requests, and the
/// report says how many arrived.
/// Iterates GLib's default main context once.
///
/// Sleeping is not enough, and the difference is the whole check. WebKit delivers every
/// answer it has — a scheme request, a finished load, a render — through callbacks on this
/// context. A check that only sleeps sends its requests into the engine and then waits for
/// replies that are never dispatched, so it verifies that a window opened and reports
/// nothing about whether the engine did anything at all.
const iterate_main_context = @extern(
    *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    .{ .name = "g_main_context_iteration" },
);

/// Asking WebKit where it keeps web data crashes the process.
///
/// Recorded here rather than worked around. `webkit_website_data_manager_get_base_data_directory`
/// is exported and takes no arguments, which reads like a harmless query; calling it
/// before a data manager exists faults inside libc. There is no public way in these
/// headers to create or attach one — only `get_base_cache_directory`, `get_favicon_manager`
/// and the `fetch`/`clear` family — so the directory is not observable at this point.
///
/// The consequence is recorded rather than solved here: a packaged build cannot be *told*
/// where its local storage lives, only where the engine chose. If that turns out to be
/// ephemeral, the fix is not this API but the storage path itself.

/// One turn: let the engine answer, then pace the loop.
///
/// Non-blocking on purpose. A blocking iteration would wait for an event that may never
/// come, and a check that can hang cannot report anything.
fn engineTurn() void {
    _ = iterate_main_context(null, 0);
}

/// Clears the probe key and nothing else.
///
/// Loaded first so the two measured loads start from a known state. Without it the
/// check would report `kept` on load 1 whether persistence works or not, because a value
/// left by an earlier run of the check would be read back as proof of exactly the thing
/// being measured.
const clearing_page: [:0]const u8 =
    "<title>lepton</title><script>"
    ++ "var done='no';"
    ++ "try{localStorage.removeItem('lepton-probe');"
    ++ "done=(localStorage.getItem('lepton-probe')===null)?'cleared':'still-there';}catch(e){done='threw';}"
    ++ "fetch('lepton://check/reset/'+done);"
    ++ "</script>";

const page: [:0]const u8 = "<title>lepton</title>"
    ++ "<body style='background:#14181c;color:#cdd3d8;font:16px monospace'>"
    ++ "lepton webview check"
    ++ "<script>"
    ++ "var before='absent',after='absent';"
    ++ "try{"
    ++ "var seen=localStorage.getItem('lepton-probe');"
    ++ "if(seen!==null){before=seen;}"
    ++ "localStorage.setItem('lepton-probe','kept');"
    ++ "after=(localStorage.getItem('lepton-probe')==='kept')?'kept':'lost';"
    ++ "}catch(e){before='threw';after='threw';}"
    ++ "fetch('lepton://check/storage/'+before+'-'+after).then(r=>r.text())"
    ++ ".then(t=>{document.title='answered'})"
    ++ ".catch(()=>{document.title='refused'})"
    ++ "</script></body>";

/// How long to wait for the engine to settle, in turns of `turn_ms`.
///
/// Bounded because an engine that never settles is a real failure and an unbounded
/// wait would turn it into a hung build. One and a half seconds is long enough for a
/// `data:` URL on a cold engine process and short enough that a failure is reported
/// rather than waited out.
const settle_turns = 90;
const turn_ms = 16;

/// Turns to keep pumping after the load has settled.
///
/// Frames are produced by the platform's repaint loop, which only runs while this loop
/// runs. Thirty turns is about half a second — several frames at the repaint cadence, and
/// short enough that a platform that never draws is reported rather than waited out.
const drain_turns = 30;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    _ = &debug_allocator;

    // Split at compile time, not at run time. In a native build `core.render.WebView`
    // is `void`, so naming `open` on it does not compile — and a check that cannot be
    // built in the configuration someone built it in reports nothing at all. The two
    // arms therefore differ in kind, not just in outcome: one runs an engine, the other
    // states plainly that this build has none.
    if (comptime core.render.can_load_pages) {
        return run();
    }

    std.debug.print("engine       none in this build\n", .{});
    std.debug.print("selection    {s}\n", .{if (core.render.is_native) "native" else "webview"});
    std.debug.print("result       this build renders natively, so there is no engine to check\n", .{});
    std.debug.print("note         build with -Drender=webview to exercise the webview path\n", .{});
    return error.NoWebviewEngine;
}

/// Runs the engine and reports what it says about itself.
fn run() !void {
    std.debug.print("engine       wpe\n", .{});

    // Asked before anything touches the engine: `get_default` caches what it finds, and
    // pointing it at Lepton's display afterwards would change nothing while appearing to
    // work. Failure is reported rather than ignored, because a check that silently ran on
    // the stock engine while claiming otherwise is worse than one that fails.
    const platform = core.render.webview_platform;
    if (platform.requested()) {
        platform.ensureSelected(std.heap.page_allocator, std.Io.Threaded.global_single_threaded.io()) catch |err| {
            std.debug.print("display      lepton requested, {t}\n", .{err});
            if (platform.loadFailure()) |reason| std.debug.print("loader said  {s}\n", .{reason});
            return err;
        };
        const chosen = try core.render.engine_caps.defaultDisplayTypeName(std.heap.page_allocator);
        defer std.heap.page_allocator.free(chosen);
        std.debug.print("display      {s}\n", .{chosen});
    }

    const requested: Size = .{ .width = 900, .height = 640 };

    var view = core.render.WebView.open() catch |failure| {
        std.debug.print("result       the engine refused to open: {t}\n", .{failure});
        return failure;
    };
    defer view.close();

    view.resized(requested.width, requested.height);

    // The core answers on this scheme, and the page is what asks. The body is set before
    // the load because the request arrives while the page is still running, and a bridge
    // that had nothing to give would refuse rather than answer — which is the difference
    // this check is meant to catch.
    view.startBridge();

    // The body is composed into the channel's own mapping rather than into a string, so
    // what the page receives is bytes that were written through shared memory. The
    // header is read back out of the same region to find where the payload starts, which
    // is the same arithmetic a peer on the other end would do.
    // A channel has two ends. Sending on this one and reading the *same* channel would
    // read the inbound ring, which is empty — the sent frame is on the outbound ring and
    // only a second attachment onto the same region can see it. That is why the round trip
    // tool needs a peer, and why this check now opens one rather than indexing the mapping.
    var outbound = try core.channel.Channel.create(std.heap.page_allocator, "/lepton-webview-check", .{});
    defer outbound.deinit(std.heap.page_allocator);
    var inbound = try core.channel.Channel.attach(std.heap.page_allocator, "/lepton-webview-check");
    defer inbound.deinit(std.heap.page_allocator);

    const payload = "lepton-check";
    const sequence = try outbound.sendBytes(.sample, payload, .{});

    var composed: []const u8 = "";
    if (try inbound.receive()) |frame| {
        composed = frame.payload;
    }
    view.bridge.setBody(composed, "text/plain");
    std.debug.print("channel      sequence {d}, received {d} byte(s)\n", .{ sequence, composed.len });
    std.debug.print("channel      body={s}\n", .{composed});
    // The two measured loads, and only those two, are labelled. The reset that runs before
    // them has its own turn above and its own line below, so no label can name the wrong
    // load.

    // Loaded twice on purpose. The page reports what it *read* before writing, so the
    // first load says `absent-kept` and the second says `kept-kept`. That single
    // difference is the whole persistence question answered, in the check itself, rather
    // than by comparing two runs against each other.
    // The document's origin, overridable so two origins can be measured with one tool:
    // `LEPTON_CHECK_BASE=lepton://localhost/` asks whether the registered secure scheme
    // keeps storage the way `http://lepton.localhost/` does.
    const base: [:0]const u8 = if (core.display.processGetenv(null, "LEPTON_CHECK_BASE")) |raw| std.mem.span(raw) else "http://lepton.localhost/";
    std.debug.print("base         {s}\n", .{base});
    view.loadHtml(page, base);
    view.map();

    if (core.render.loaded_webview_backend()) |implementation| {
        std.debug.print("backend      {s}\n", .{implementation});
    } else {
        std.debug.print("backend      unknown\n", .{});
    }

    std.debug.print("requested    {d}x{d}\n", .{ requested.width, requested.height });

    // The engine runs in another process and reports back through its own connection,
    // so there is nothing to drive here but time. Sleeping on the process-wide event
    // loop rather than spinning keeps a check that is only waiting from looking like
    // a check that is working.
    const io = std.Io.Threaded.global_single_threaded.io();

    var settled: ?bool = null;
    var turn: usize = 0;
    while (turn < settle_turns) : (turn += 1) {
        // The engine's loop first, so any state it has already queued is visible to
        // the predicates below on this same turn rather than one turn late.
        const dispatched = core.render.pump_webview();

        engineTurn();
        try std.Io.Clock.Duration.sleep(
            .{ .raw = .fromMilliseconds(turn_ms), .clock = .awake },
            io,
        );

        if (!dispatched) continue;
        if (!view.isMapped()) continue;

        // A load that is in flight is not a settled state, and reporting one as the
        // other would make a slow engine look like a working one.
        if (view.isLoading()) {
            settled = false;
            continue;
        }

        settled = true;
        break;
    }

    const mapped = view.isMapped();
    if (!mapped) {
        std.debug.print("mapped       no, after {d} turns\n", .{turn});
        std.debug.print("result       the view never reached the mapped state\n", .{});
        return error.NotMapped;
    }
    std.debug.print("mapped       yes, after {d} turns\n", .{turn});

    if (settled) |was_settled| {
        if (was_settled) {
            std.debug.print("loading      settled\n", .{});
        } else {
            std.debug.print("loading      still in flight after {d} turns\n", .{turn});
        }
    } else {
        std.debug.print("loading      never observed as mapped\n", .{});
    }

    // After the settle loop, not inside it: the settle loop's job is to answer "did the
    // engine take the page", and answering that should not also decide when rendering
    // gets a chance to happen. Stopping the instant the page settled measured "no frames"
    // for a reason that had nothing to do with frames.
    if (settled orelse false) {
        var drain: usize = 0;
        while (drain < drain_turns) : (drain += 1) {
            _ = core.render.pump_webview();
            try std.Io.Clock.Duration.sleep(
                .{ .raw = .fromMilliseconds(turn_ms), .clock = .awake },
                io,
            );
        }
    }


    if (view.uri()) |landed| {
        std.debug.print("uri          {s}\n", .{landed});
    } else {
        std.debug.print("uri          none reported\n", .{});
    }

    // What the platform module did, when there is one. Printed for the same journey the
    // lines above report, and not instead of them: the engine's own answers and the
    // platform's own counts are separate evidence, and a check that showed only the
    // first could pass on a display that did nothing at all.
    if (core.render.webview_platform.counters()) |counts| {
        std.debug.print("platform     views {d}, buffers_changed {d}, render_buffer {d}, mapped-asked {d}\n", .{
            counts.views_created,
            counts.buffers_changed,
            counts.render_buffer_calls,
            counts.can_be_mapped_asked,
        });
        std.debug.print("             buffers_allocated {d}, frames_read_back {d}, pixels_non_zero {d}\n", .{
            counts.buffers_allocated,
            counts.frames_read_back,
            counts.pixels_non_zero,
        });
        std.debug.print("             render_requests {d}, refusals {d}, frames_with_pixels {d}\n", .{
            counts.render_requests,
            counts.render_refusals,
            counts.frames_with_pixels,
        });
        std.debug.print("             egl_displays {d}, views_without_a_loop {d}\n", .{
            counts.egl_displays_created,
            counts.views_without_a_loop,
        });
    }

    // A second load, then one more round of the loop, so the reload's report replaces the
    // first one's. The persistence question is answered by the difference between them.
    view.loadHtml(clearing_page, base);
    var clearing_turn: usize = 0;
    while (clearing_turn < settle_turns) : (clearing_turn += 1) {
        engineTurn();
        try std.Io.Clock.Duration.sleep(
            .{ .raw = .fromMilliseconds(turn_ms), .clock = .awake },
            io,
        );

    }
    const reset_path = core.webviewBridge.lastPath() orelse "no answer";
    std.debug.print("reset        {s}\n", .{reset_path});
    view.loadHtml(page, base);
    var second_turn: usize = 0;
    while (second_turn < settle_turns) : (second_turn += 1) {
        engineTurn();
        try std.Io.Clock.Duration.sleep(
            .{ .raw = .fromMilliseconds(turn_ms), .clock = .awake },
            io,
        );
    }
    std.debug.print("load 1       {s}\n", .{core.webviewBridge.lastPath() orelse "no answer"});
    view.loadHtml(page, base);
    var third_turn: usize = 0;
    while (third_turn < settle_turns) : (third_turn += 1) {
        engineTurn();
        try std.Io.Clock.Duration.sleep(
            .{ .raw = .fromMilliseconds(turn_ms), .clock = .awake },
            io,
        );
    }
    std.debug.print("load 2       {s}\n", .{core.webviewBridge.lastPath() orelse "no answer"});
    std.debug.print("bridge       {d} request(s), {d} refused, {d} bytes served\n", .{
        view.bridge.counters.requests,
        view.bridge.counters.refused,
        view.bridge.counters.bytes_served,
    });
    std.debug.print("result       engine opened, took a page, and mapped\n", .{});
    if (core.render.webview_platform.counters()) |_| {
        std.debug.print("note         lepton's display is in use, but no buffer has been\n", .{});
        std.debug.print("             allocated from the formats the engine offered, so no\n", .{});
        std.debug.print("             frame is read back or verified by this check\n", .{});
    } else {
        std.debug.print("note         WPE exposes no render target to an embedder, so no\n", .{});
        std.debug.print("             frame is presented or verified by this check\n", .{});
    }

    if (settled != true) return error.LoadDidNotSettle;
}
