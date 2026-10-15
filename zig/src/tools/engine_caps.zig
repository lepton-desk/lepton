//! Reports what the installed web engine allows, measured against the real library.
//!
//! This exists because the answer is a property of the WebKit build, not of this
//! framework. WPE hands over rendered pixels only to whoever owns the `WPEDisplay` the
//! engine draws into, and whether an integrator can supply that display is not something
//! the WPE headers promise — it varies by version, and on some builds the only way in is
//! refused by an assertion inside WebKit. A framework that assumed either answer would be
//! wrong on somebody else's machine.
//!
//! So it is measured. Every line below comes from libWPEWebKit on this machine, and
//! "engine pixels unreachable" here is a finding, not an excuse.

const std = @import("std");
const caps = @import("lepton_core").render.engine_caps;

pub fn main() !void {
    // `std.debug.print` writes to stderr unbuffered, which is what the other check
    // tools do. Reaching for a buffered writer here would be a different convention for
    // no gain: this prints eleven lines, once.
    const out = std.debug.print;

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    _ = &debug_allocator;
    const gpa = debug_allocator.allocator();
    const report = try caps.measure(gpa);
    defer gpa.free(report.default_display_type);
    defer gpa.free(report.owned_display_type);


    out("engine present   {}\n", .{report.engine_present});
    if (!report.engine_present) {
        out("default display  <no engine loaded>\n", .{});
        out("result           nothing to measure: the backend library did not load\n", .{});
        return;
    }

    out("default display  {s}\n", .{report.default_display_type});
    out("owned display    {s}\n", .{report.owned_display_type});
    out("engine used it   {}\n", .{report.owned_display_used});
    out("backend accepted {}\n", .{report.backend_accepted});

    const route = report.route();
    out("route            {s}\n", .{@tagName(route)});
    out("                 {s}\n", .{route.describe()});

    // Stated plainly, because a capability report that does not say what it implies is
    // a table of numbers.
    if (route == .engine_owns_display) {
        out(
            "result           engine pixels are not reachable on this build; the page\n" ++
                "                 loads and maps, but its buffer goes to a display this\n" ++
                "                 framework did not choose and cannot read\n",
            .{},
        );
    } else {
        out(
            "result           engine pixels are reachable; this build accepts a {s}\n" ++
                "                 from the embedder\n",
            .{@tagName(route)},
        );
    }
}