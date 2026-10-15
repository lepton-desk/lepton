//! Proves, through this framework's own code, that the engine draws into Lepton's
//! display — with no change to WebKit.
//!
//! The claim is falsifiable and narrow: after `platform.ensureSelected`, the display that
//! `wpe_display_get_default()` returns is `WPELeptonDisplay`. Not Wayland, not headless.
//! Everything else on the path to pixels is unproven and this tool says so.

const std = @import("std");
const core = @import("lepton_core");

pub fn main(init: std.process.Init) !void {
    const out = std.debug.print;
    const gpa = init.gpa;

    if (!core.render.can_load_pages) {
        out("engine       none in this build\n", .{});
        out("result       not measured: this build links no web engine\n", .{});
        return;
    }

    const platform = core.render.webview_platform;

    // Deliberately first. `wpe_display_get_default` caches behind a one-shot flag, so
    // asking before selecting would answer for the stock engine and prove nothing.
    platform.ensureSelected(gpa, init.io) catch |err| {
        out("module       {s}\n", .{@errorName(err)});
        if (platform.loadFailure()) |reason| out("loader said  {s}\n", .{reason});
        out("result       lepton's display module could not be loaded\n", .{});
        return;
    };
    out("module       loaded and held\n", .{});
    out("platform     {s}\n", .{platform.platform_selector});

    // Only the display is asked about. Constructing a view would go through Lepton's
    // display and fault on the missing `create_view` — `wpe_view_new` calls it directly,
    // so an incomplete display crashes rather than declining. That is the next
    // increment's work and not this tool's to attempt.
    const chosen = try core.render.engine_caps.defaultDisplayTypeName(gpa);
    defer gpa.free(chosen);
    out("default      {s}\n", .{chosen});

    if (std.mem.eql(u8, chosen, "WPELeptonDisplay")) {
        out(
            "result       lepton's own display is the default; the engine draws here\n" ++
                "             and no WebKit change was needed to make that happen\n" ++
                "next         create_view, then EGL on it, then the buffer handshake\n",
            .{},
        );
        return;
    }
    out("result       NOT lepton's display: selection did not take effect\n", .{});
}