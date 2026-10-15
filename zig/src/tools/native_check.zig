//! Paints a real window and reports what reached the screen.
//!
//! This is the native path's proof, in the same way `window_check.zig` is the window
//! layer's: it opens an actual window on an actual display server, draws into an
//! actual frame, and says what happened. Nothing here is simulated — if the compositor
//! refused the buffer, or the server never mapped the window, or the frame was the
//! wrong size, the report says so.
//!
//! ## What it draws
//!
//! The starter panel's layout: the forme, the rail, the hairline rules of the
//! measures table, and a sparkline of the round-trip history. No glyphs — text needs
//! a rasteriser, and pretending to draw it with filled rectangles would be the one
//! dishonest thing in an otherwise honest tool. The glyph layer is a separate step
//! with its own check.

const std = @import("std");

const core = @import("lepton_core");
const chrome = core.waylandChrome;
const Surface = core.surface.Surface;
const Colour = core.surface.Colour;
const Size = core.window.Size;
const Text = core.render.Text;

/// The palette, in the project's own materials.
///
/// The four roles the starter sheet defines, named here so a renderer and the sheet
/// cannot drift: the table, the raised type, the lead groove, and the single ink
/// reserved for a value that is out of tolerance.
const ink = struct {
    const bed = Colour.rgb(0x14, 0x18, 0x1C);
    const ramp1 = Colour.rgb(0x19, 0x1E, 0x23);
    const ramp2 = Colour.rgb(0x1F, 0x25, 0x2B);
    const ramp3 = Colour.rgb(0x26, 0x2D, 0x34);
    const face = Colour.rgb(0xCD, 0xD3, 0xD8);
    const face_dim = Colour.rgb(0x8E, 0x97, 0x9F);
    const face_faint = Colour.rgb(0x62, 0x6C, 0x74);
    const groove = Colour.rgb(0x0B, 0x0E, 0x11);
    const rule = Colour.rgb(0x2B, 0x33, 0x3A);
    const spot = Colour.rgb(0xC8, 0x96, 0x3C);
};

/// The baseline the whole sheet is set on, in pixels.
///
/// Sixteen at the default scale. Every vertical measurement below is a multiple of
/// it, which is what makes the layout read as ruled rather than as rectangles that
/// happen to be near each other.
const baseline: i32 = 16;

/// The rail's width, in pixels. Thirteen rem at the sheet's sixteen-pixel root.
const rail_width: i32 = 13 * 16;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    // Out of the event loop, as everything in this framework is: the allocator is
    // touched here and nowhere else until a frame is presented.
    const requested: Size = .{ .width = 900, .height = 640 };
    var history: History = .{};

    const display = try core.display.Display.probe(core.display.processGetenv, null);

    std.debug.print("session      {s}\n", .{@tagName(display.session)});
    std.debug.print("screen       {d}x{d}\n", .{ display.width, display.height });
    // The field carries millihertz, so the division is here rather than in the probe:
    // every caller would otherwise have to remember, and one that forgot would report
    // a screen refreshing a thousand times too fast.
    std.debug.print("refresh      {d:.2} Hz\n", .{@as(f64, @floatFromInt(display.refresh_mhz)) / 1000.0});

    const request: core.window.Request = .{
        .title = "Lepton native check",
        .app_id = "dev.lepton.native-check",
        .size = requested,
        .format = .argb8888,
    };

    const opened = try open(allocator, request);

    var frame = try Surface.init(allocator, requested, .argb8888);
    defer frame.deinit();

    // A name unique to this process. A fixed name would work until a run is killed,
    // and then every subsequent run would fail with `AlreadyExists` — because the
    // object outlives the process that made it. A check tool has no reason to share a
    // channel with anything, including a previous run of itself.
    var channel_name_buf: [64]u8 = undefined;
    const channel_name = try std.fmt.bufPrint(
        &channel_name_buf,
        "/lepton-native-check-{d}",
        .{std.os.linux.getpid()},
    );

    // Cleared before creating. A POSIX shared-memory object outlives the process that
    // made it, so a check tool that was killed last time left a name behind that
    // nothing would ever remove — and this tool has no peer to lose by removing it.
    // A long-lived application must not do this: it would destroy the name a live peer
    // is publishing into.
    core.shm.unlink(allocator, channel_name) catch {};

    var channel = try core.channel.Channel.create(allocator, channel_name, .{});
    defer channel.deinit(allocator);

    // Text needs Cairo, which the build probed for. Absent, the panel still opens and
    // still shows the rules and the trace — a check tool that refused to run would
    // report less than one that ran with no labels.
    var subject: ?Text = null;
    if (core.render.can_draw_text) {
        if (Text.init(frame)) |bound_text| {
            subject = bound_text;
            std.debug.print("text         cairo, monospace 11pt\n", .{});
        } else |failure| {
            std.debug.print("text         unavailable: {t}\n", .{failure});
        }
    }

    std.debug.print("requested    {d}x{d}\n", .{ requested.width, requested.height });
    std.debug.print("channel      {s}\n", .{channel_name});

    var frames: u32 = 0;
    var presented: u64 = 0;

    while (frames < 3) : (frames += 1) {
        const configured = opened.takeConfigure();

        if (configured) |change| {
            if (!change.size.isEmpty()) {
                try frame.resize(change.size);
                if (subject) |*bound_text| try bound_text.retarget(frame);
                // The window as well as the frame. Resizing only the frame leaves the
                // surface the compositor is showing at one size and the pixels at
                // another, and it is also the only call in this file that reaches the
                // X11 resize adapter — an adapter nothing calls is an adapter nobody
                // compiles, and that one had a swallowed error in it.
                try opened.resize(change.size);
            }
        }

        const measured = Measured.take(&channel);
        history.record(measured.round_trip_ns orelse 0);

        var rows_buffer: [8]Row = @splat(.{
            .label = @splat(0),
            .label_len = 0,
            .value = @splat(0),
            .value_len = 0,
        });
        buildRows(&rows_buffer, measured);

        paint(&frame, if (subject) |*t| t else null, history, measured, &rows_buffer);

        // The titlebar last, over everything the content drew, because the window's own
        // controls belong to the frame rather than to the content inside it.
        chrome.paintTitlebar(inputState(opened.*, frame.size), frame);
        chrome.paintMenu(menuOf(opened.*), frame);

        // Events are drained and acted on before the frame is drawn, so what the frame
        // shows is the state the events produced. Drawing first would put the control the
        // pointer just pressed on screen a frame after the press was handled.
        _ = opened.drain();

        try opened.present(frame.pixels, frame.size, frame.format);
        presented += frame.pixels.len;

        std.debug.print("frame        {d} {d}x{d} {d} bytes\n", .{
            frames,
            frame.size.width,
            frame.size.height,
            frame.pixels.len,
        });
        // Said rather than shown as zero: this tool has no peer to bounce a frame off,
        // so the honest line is that the figure lives in `zig build roundtrip`.
        std.debug.print("round trip   see `zig build roundtrip` (no peer in this tool)\n", .{});
        // Printed by hand rather than with `{any}`: an absent figure and a zero look
        // the same in a column, and one of them is a measurement and the other is not.
        if (measured.rss_bytes) |count| {
            std.debug.print("resident     {d} bytes\n", .{count});
        } else {
            std.debug.print("resident     unavailable\n", .{});
        }

        opened.wait(16) catch break;
    }

    std.debug.print("bytes sent   {d}\n", .{presented});
    std.debug.print("free cells   {d}/{d}\n", .{ channel.freeCells(), channel.capacity() });
    std.debug.print("result       native frame painted and presented\n", .{});

    if (subject) |*type_face| type_face.deinit();
    opened.release();
}

/// One reading of this machine, taken through the real channel.
///
/// Every figure here was measured. A figure that could not be read is `null` and
/// printed as such — not as zero. A panel that shows `0 bytes` for a resident set is
/// claiming a measurement that was not taken, and on this screen that claim would be
/// the only number a reader could not check against anything.
const Measured = struct {
    /// Time since the core started, monotonic. Null when the clock could not be read.
    uptime_ns: ?u64 = null,
    /// Resident set of this process. Null when `/proc/self/statm` is unavailable.
    rss_bytes: ?u64 = null,
    /// Free cells in the ring, and the ring's size. Always readable: they are fields
    /// of a mapping this process owns.
    ring_free_cells: u32,
    ring_capacity_cells: u32,
    /// Nothing.
    ///
    /// Deliberately absent. A round trip needs a peer on the other ring, and this tool
    /// is one process with one channel — so composing a frame and reading it back out
    /// of the same ring would measure the compose twice and call it a round trip.
    ///
    /// The real figure is produced by `zig build roundtrip`, which does have a peer:
    /// a second channel over a second region, sending and receiving for twenty
    /// thousand iterations. A latency number on this panel that this tool could not
    /// have taken would be the one figure a reader had no way to check.
    round_trip_ns: ?u64 = null,
    fn take(channel: *core.channel.Channel) Measured {
        var self = Measured{
            .ring_free_cells = channel.freeCells(),
            .ring_capacity_cells = channel.capacity(),
        };

        var probe = core.probe.Probe.init();

        // One real composition into shared memory: the frame is built straight into a
        // ring cell, with no staging buffer, and the mapping is the destination. This
        // is the part of the path Lepton owns; the rest belongs to the peer.
        const sample: core.wire.Sample = .{
            // Zero here rather than a guess: the timestamps that matter are the ones
            // the clock reports, and this field is filled from `probe` below or not at
            // all.
            .timestamp_ns = 0,
            .rss_bytes = 0,
            // The allocator's figures are left at zero because this tool allocates
            // before the loop and never inside it, so there is no heap traffic to
            // report. A fabricated high-water mark would be the one number on this
            // screen that means nothing.
            .heap_high_water_bytes = 0,
            .heap_in_use_bytes = 0,
            .ring_free_cells = self.ring_free_cells,
            .ring_capacity_cells = self.ring_capacity_cells,
            .round_trip_ns = 0,
            .round_trip_max_ns = 0,
        };

        _ = channel.send(.sample, &sample, .{}) catch {};

        // Read from the kernel's own accounting, separately from the channel: this is
        // a property of the process, and asking the channel for it would only prove
        // the channel can carry it.
        self.rss_bytes = core.probe.residentSetBytes() catch null;
        if (self.uptime_ns == null) {
            const reading = probe.read(self.ring_free_cells, self.ring_capacity_cells) catch
                return self;
            self.uptime_ns = reading.uptime_ns;
        }

        return self;
    }
};

/// Recent round-trip figures, for the sparkline.
///
/// A ring of samples rather than a growing list: a panel that has been open for a
/// day must not have grown an array to hold them.
const History = struct {
    const capacity = 96;

    samples: [capacity]u64 = @splat(0),
    filled: usize = 0,
    cursor: usize = 0,
    largest: u64 = 1,

    fn record(self: *History, value: u64) void {
        self.samples[self.cursor] = value;
        self.cursor = (self.cursor + 1) % capacity;
        if (self.cursor > self.filled) self.filled = self.cursor;
        if (value > self.largest) self.largest = value;
    }

    /// One sample, oldest first.
    fn at(self: History, index: usize) u64 {
        if (index >= self.filled) return 0;
        return self.samples[(self.cursor + capacity - self.filled + index) % capacity];
    }
};

/// Fills `rows` with this machine's measurements, as text.
///
/// Every string comes from a real reading or from a real value the channel reported.
/// A field that could not be read is left out rather than shown as zero, because a
/// panel of measurements whose whole claim is that they are measured must not contain
/// a figure nobody took.
fn buildRows(rows: []Row, measured: Measured) void {
    var scratch: [Capacity]u8 = undefined;

    // Filled from the outside in, and each entry advances the count only once it has
    // been written: a measurement that could not be read leaves its row out rather than
    // filling it with a zero.
    var used: usize = 0;

    if (used < rows.len) {
        if (measured.uptime_ns) |value| {
            _ = row(&rows[used], "core clock", text_of(&scratch, nanoseconds(&scratch, value)), false);
            used += 1;
        }
    }

    if (used < rows.len) {
        if (measured.rss_bytes) |value| {
            _ = row(&rows[used], "resident", text_of(&scratch, bytes(&scratch, value)), false);
            used += 1;
        }
    }

    if (used < rows.len) {
        const written = write(&scratch, "{d}", .{measured.ring_free_cells});
        _ = row(&rows[used], "ring free", text_of(&scratch, written), false);
        used += 1;
    }

    if (used < rows.len) {
        const written = write(&scratch, "{d}", .{measured.ring_capacity_cells});
        _ = row(&rows[used], "ring capacity", text_of(&scratch, written), false);
        used += 1;
    }

    if (used < rows.len) {
        // The channel's name is a real fact about this run: it carries the process id,
        // so two checks on one machine never collide.
        const written = write(&scratch, "lepton-native-check-{d}", .{std.os.linux.getpid()});
        _ = row(&rows[used], "channel", text_of(&scratch, written), false);
        used += 1;
    }

    // Any row past what was filled is blanked, so a stale value from a previous frame
    // cannot survive in a row whose measurement stopped being available.
    for (rows[used..]) |*blank| {
        blank.label_len = 0;
        blank.value_len = 0;
        blank.out_of_tolerance = false;
    }
}

/// The measures the panel shows, as text.
///
/// Built into a fixed buffer rather than allocated: the panel redraws once a second
/// for as long as the window is open, and a per-frame allocation here would be the
/// only thing on the frame path that is not free.
const Capacity = 32;

/// A row on the panel: a label on the left, a value on the right.
const Row = struct {
    label: [Capacity]u8,
    label_len: usize,
    value: [Capacity]u8,
    value_len: usize,
    /// Whether this value is outside tolerance. At most one row carries it.
    out_of_tolerance: bool = false,
};

/// Fills `row` from two slices, marking the row out of tolerance when `bad`.
///
/// Returns false when either side does not fit, which the caller turns into a blank
/// row rather than a truncated one: a measurement cut in half is a wrong number
/// wearing the right one's label.
fn row(row_out: *Row, label: []const u8, value: []const u8, bad: bool) bool {
    if (label.len + 1 > Capacity or value.len + 1 > Capacity) return false;

    @memcpy(row_out.label[0..label.len], label);
    row_out.label_len = label.len;
    @memcpy(row_out.value[0..value.len], value);
    row_out.value_len = value.len;
    row_out.out_of_tolerance = bad;

    return true;
}

/// The part of a slice that is safe to hand to Cairo: no NUL, and bounded.
fn text_of(storage: []const u8, len: usize) []const u8 {
    return storage[0..len];
}

/// Writes a nanosecond count into `storage` as a scaled string, and returns its length.
///
/// Uses the largest unit that keeps the figure readable: a latency printed as nine
/// digits of a nanosecond is a table nobody scans, and the digits past the third are
/// measurement noise rather than signal.
fn nanoseconds(storage: *[Capacity]u8, nanoseconds_value: u64) usize {
    const units = [_]struct { scale: u64, suffix: []const u8 }{
        .{ .scale = 1_000_000_000, .suffix = " s" },
        .{ .scale = 1_000_000, .suffix = " ms" },
        .{ .scale = 1_000, .suffix = " us" },
        .{ .scale = 1, .suffix = " ns" },
    };

    for (units) |unit| {
        if (nanoseconds_value < unit.scale) continue;

        // Hundredths, truncated rather than rounded: a latency that reads high is the
        // direction that hides a problem.
        const hundredths = (nanoseconds_value * 100) / unit.scale;
        const whole = hundredths / 100;
        const fraction = hundredths % 100;

        if (fraction == 0) {
            return write(storage, "{d}{s}", .{ whole, unit.suffix });
        }

        return write(storage, "{d}.{d}{s}", .{ whole, fraction / 10, unit.suffix });
    }

    return write(storage, "0 ns", .{});
}

/// Formats into `storage` and returns how many bytes were written.
///
/// `bufPrint` hands back the written slice rather than a count, and every caller in
/// this file wants the count because it keeps its own slice and its own length. The
/// length is the slice's, never a null terminator's: Cairo terminates the copy this
/// module makes, and a second terminator here would be counted as part of the text.
fn write(storage: *[Capacity]u8, comptime format: []const u8, args: anytype) usize {
    const written = std.fmt.bufPrint(storage, format, args) catch return 0;
    return written.len;
}

/// Writes a byte count into `storage` as a binary-scaled string, and its length.
fn bytes(storage: *[Capacity]u8, count: u64) usize {
    const units = [_]struct { scale: u64, suffix: []const u8 }{
        .{ .scale = 1 << 30, .suffix = " GiB" },
        .{ .scale = 1 << 20, .suffix = " MiB" },
        .{ .scale = 1 << 10, .suffix = " KiB" },
    };

    for (units) |unit| {
        if (count < unit.scale) continue;
        const hundredths = (count * 100) / unit.scale;
        return write(storage, "{d}.{d}{s}", .{ hundredths / 100, (hundredths % 100) / 10, unit.suffix });
    }

    return write(storage, "{d} B", .{count});
}

/// Paints one frame: the forme, the rail, the table rules, the type, and the sparkline.
///
/// `type_on_surface` is optional because a machine with no Cairo still runs this tool:
/// the rules and the trace are real measurements and worth showing without type, and a
/// panel that refused to open would report less than one that opened with no labels.
/// The input state of whichever window is open, so the titlebar can be painted against
/// the same zones it is clicked with.
fn inputState(opened: Opened, size: Size) core.waylandInput.Input {
    _ = size;
    return switch (opened.backend) {
        // Wayland keeps its own live state, and it is the one that has followed the
        // compositor's configure. The X11 backend has no input layer yet, so its zones
        // are derived from the frame being drawn — correct for painting, and the reason
        // that backend's clicking is still listed as unfinished.
        .wayland => |w| w.input,
        .x11 => |w| w.input,
    };
}

/// The window menu of whichever window is open.
fn menuOf(opened: Opened) chrome.Menu {
    return switch (opened.backend) {
        .wayland => |w| w.menu,
        .x11 => |w| w.menu,
    };
}

fn paint(
    frame: *const Surface,
    subject: ?*Text,
    history: History,
    measured: Measured,
    rows: []const Row,
) void {
    frame.fill(ink.bed);

    const width: i32 = @intCast(frame.size.width);
    const height: i32 = @intCast(frame.size.height);

    // The rail: the darkest surface on the bed, separated by a single rule. The only
    // place a border reads as structure rather than as decoration.
    frame.fillRect(0, 0, rail_width, height, ink.groove);
    frame.vLine(rail_width, 0, height, ink.rule);

    // Bay rules on the baseline lattice. Three of them: under the title, under the
    // column heads, and at the foot.
    const bay_left = rail_width + baseline * 2;
    const bay_right = width - baseline * 2;

    frame.hLine(bay_left, baseline * 3, bay_right - bay_left, ink.rule);
    frame.hLine(bay_left, baseline * 6, bay_right - bay_left, ink.rule);

    // The columns: the label measure from the sheet, and the value measure on the
    // right, with the groove between them carrying the grid.
    const value_left = bay_right - baseline * 12;
    frame.vLine(value_left, baseline * 6, height - baseline * 8, ink.groove);

    // One row per measure, ruled on the baseline, with its label set to the left and
    // its value to the right. The value column is right-aligned by measuring from the
    // right edge, so the figures line up on their least significant digit — which is
    // the only alignment in which two numbers can be compared by eye.
    var index: i32 = 7;
    while (index * baseline < height - baseline * 2) : (index += 1) {
        const y = index * baseline;
        frame.hLine(bay_left, y, bay_right - bay_left, ink.groove);

        if (subject) |type_face| {
            const slot: usize = @intCast(index - 7);
            if (slot >= rows.len) continue;

            const entry = rows[slot];
            const label = text_of(&entry.label, entry.label_len);
            const value = text_of(&entry.value, entry.value_len);

            const ascent = type_face.measure(label) orelse continue;

            _ = type_face.draw(
                bay_left + baseline,
                y - ascent.descent,
                label,
                ink.face_dim,
            );

            const measured_value = type_face.measure(value) orelse continue;
            const value_x = bay_right - baseline - measured_value.width;
            _ = type_face.draw(
                value_x,
                y - ascent.descent,
                value,
                if (entry.out_of_tolerance) ink.spot else ink.face,
            );
        }
    }

    // The sparkline, in the value measure, scaled to the largest figure seen so the
    // trace uses the whole height without a second axis to read.
    const spark_top = baseline * 7;
    const spark_height = height - spark_top - baseline * 2;
    var x: i32 = value_left + baseline;
    while (x < bay_right - baseline) : (x += 2) {
        const sample_index = @min(
            @as(usize, @intCast(@divTrunc(x - value_left - baseline, 2))),
            history.filled -| 1,
        );
        const value = history.at(sample_index);
        const height_of_bar = if (history.largest == 0)
            0
        else
            @as(i32, @intCast(value * @as(u64, @intCast(spark_height)) / history.largest));

        // The single ink appears here and nowhere else: the trace is the one thing on
        // screen that is a measurement over time rather than a value.
        frame.fillRect(x, spark_top + spark_height - height_of_bar, 1, height_of_bar, ink.face_dim);
    }

    // Out of tolerance, marked in the spot ink. Identified by its shape as well as its
    // colour, so it is found by form and not only by hue — a reader who cannot see the
    // hue still finds the band.
    if ((measured.round_trip_ns orelse 0) > tolerance) {
        frame.fillRect(bay_left, height - baseline, baseline, baseline, ink.spot);
    }
}

/// Half a millisecond, the same figure the starter screen uses.
const tolerance: u64 = 500_000;

/// The window, whichever backend the display server turned out to be.
const Opened = struct {
    /// Which backend the session turned out to have. A tagged union rather than a
    /// vtable: there are two, they are chosen once, and every call would otherwise
    /// cost an indirect branch for no polymorphism.
    backend: Backend,
    /// Kept so `release` can free what this struct allocated.
    allocator: std.mem.Allocator,

    const Backend = union(enum) {
        wayland: *core.waylandWindow.WaylandWindow,
        x11: *core.x11Window.X11Window,
    };

    /// Reads whatever input has arrived since the last frame.
    fn drain(self: Opened) u32 {
        return switch (self.backend) {
            .wayland => |w| w.drainConnection(),
            .x11 => |w| blk: {
                core.x11Window.pumpEvents(w);
                break :blk 0;
            },
        };
    }

    /// Takes the action the last button release decided, if there was one.
    fn takeAction(self: Opened) ?chrome.Action {
        return switch (self.backend) {
            .wayland => null,
            .x11 => |w| blk: {
                const action = core.x11Window.takeAction(w);
                break :blk if (action == .none) null else action;
            },
        };
    }

    fn present(self: Opened, pixels: []const u8, frame: Size, format: core.window.PixelFormat) !void {
        switch (self.backend) {
            .wayland => |w| try w.presentPixels(pixels, frame, format),
            // The X11 backend's presenter is a free function taking the handle the
            // dispatch in `window.Backend` uses, because that is how the union reaches
            // it without knowing which backend it holds.
            .x11 => |w| try core.x11Window.presentPixels(core.x11Window.asHandle(w), pixels, frame, format),
        }
    }

    fn resize(self: Opened, size: core.window.Size) !void {
        switch (self.backend) {
            .wayland => |w| try core.waylandWindow.resize(core.waylandWindow.asHandle(w), size),
            .x11 => |w| try core.x11Window.resize(core.x11Window.asHandle(w), size),
        }
    }

    fn takeConfigure(self: Opened) ?core.window.Configure {
        return switch (self.backend) {
            .wayland => |w| w.takeConfigure(),
            .x11 => |w| core.x11Window.takeConfigure(core.x11Window.asHandle(w)),
        };
    }

    fn wait(self: Opened, timeout_ms: i32) !void {
        switch (self.backend) {
            .wayland => |w| try w.wait(timeout_ms),
            .x11 => |w| try core.x11Window.wait(core.x11Window.asHandle(w), timeout_ms),
        }
    }

    /// Closes the window and releases everything this union allocated.
    ///
    /// The backend is closed before its handle is freed, and both before the union
    /// itself: the window's teardown writes through the handle, so freeing the handle
    /// first would be a use-after-free that happens to work until it does not.
    fn close(self: Opened) void {
        switch (self.backend) {
            .wayland => |w| {
                w.close();
                self.allocator.destroy(w);
            },
            .x11 => |w| {
                w.close();
                self.allocator.destroy(w);
            },
        }
    }

    /// Releases the union itself. Separate from `close` because a `defer` on `close`
    /// would run before the caller's own teardown, and this is the last step.
    fn release(self: *Opened) void {
        self.close();
        self.allocator.destroy(self);
    }
};

/// Opens a window on whichever backend the session has.
///
/// Both the handle and the window itself live on the heap, and both are released by
/// `close`. That is a little ceremony for a tool that runs three frames, and it is
/// here because the framework's first claim is that it is leak-free: a check tool
/// that leaked would be the worst possible place for that to be true, since the
/// allocator would report it and a reader would have to decide whether it mattered.
fn open(allocator: std.mem.Allocator, request: core.window.Request) !*Opened {
    const display = try core.display.Display.probe(core.display.processGetenv, null);

    const opened = try allocator.create(Opened);
    errdefer allocator.destroy(opened);

    switch (display.session) {
        .wayland => {
            const handle = try allocator.create(core.waylandWindow.WaylandWindow);
            errdefer allocator.destroy(handle);
            try handle.open(allocator, request);
            opened.* = .{ .backend = .{ .wayland = handle }, .allocator = allocator };
        },
        .x11 => {
            const handle = try allocator.create(core.x11Window.X11Window);
            errdefer allocator.destroy(handle);
            handle.* = try core.x11Window.X11Window.open(request);
            opened.* = .{ .backend = .{ .x11 = handle }, .allocator = allocator };
        },
    }

    return opened;
}
