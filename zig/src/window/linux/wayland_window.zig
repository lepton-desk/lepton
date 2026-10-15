//! A Wayland window, built on `wl_compositor`, `wl_shm` and `xdg_wm_base`.
//!
//! Nothing here wraps a toolkit. The compositor is spoken to through the protocol
//! bindings `wayland-scanner` generates from the vendored XML, and pixels arrive
//! through a shared-memory buffer the compositor maps directly — which is why a
//! frame costs no copy on the way out.
//!
//! The flow a Wayland client has to follow, in the order it has to happen:
//!
//! 1. Connect and round-trip the registry, because a surface cannot be created
//!    before the globals are known.
//! 2. Bind `wl_compositor`, `wl_shm` and `xdg_wm_base`. All three are required:
//!    without xdg-shell the compositor will not map a surface as a window.
//! 3. Create the surface, wrap it in an xdg surface, and take a toplevel role.
//! 4. Commit with no buffer, because a compositor refuses a configure before the
//!    client has acknowledged the first one.
//! 5. Wait for `configure`, acknowledge it, and only then attach a buffer.
//!
//! Step 4 and step 5 are the part that is easy to get wrong and impossible to
//! guess: the first commit carries no pixels at all, and a client that attaches a
//! buffer immediately gets a surface the compositor never maps.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const input_state = @import("input.zig");
const chrome = @import("chrome.zig");
const placement = @import("placement.zig");
const presenter = @import("../../render/gpu/presenter.zig");

// The protocol's C declarations, the input callbacks, the xdg-shell listeners and frame
// presentation each live in their own file; this one holds the window and its lifecycle.
// All of them import one `@cImport`, because two separate imports of the same headers
// produce distinct types that cannot be passed between files.
const wl = @import("wayland_c.zig").wl;
const wayland_input = @import("wayland_input.zig");
const wayland_shell = @import("wayland_shell.zig");
const wayland_present = @import("wayland_present.zig");

const window = @import("../window.zig");

pub const Size = window.Size;
pub const Configure = window.Configure;
pub const Request = window.Request;

pub const Error = window.Error || error{
    /// The compositor offered no `wl_compositor`, `wl_shm` or `xdg_wm_base`. One
    /// of the three being absent is not a degraded mode: a client that cannot map
    /// a window should say so rather than open something invisible.
    MissingGlobals,
    /// The display socket could not be opened.
    ConnectionFailed,
    /// `wl_shm` refused to create a pool, which means the compositor will not
    /// accept shared-memory buffers.
    BufferRefused,
};

/// The height of the titlebar this window draws for itself, in pixels.
///
/// Fixed rather than scaled or themed because it is also the hit-test boundary in
/// `input.zig`, and a value that could differ between the drawing and the test would make
/// every click land on the control the developer was looking at rather than the one under
/// the pointer. Thirty-two is what the drawn bar occupies and what the zones divide by.
pub const titlebar_height: u32 = 32;

pub const Keymap = wayland_input.Keymap;

/// A mapped window and the memory its pixels live in.
pub const WaylandWindow = struct {
    display: *wl.wl_display,
    surface: ?*wl.wl_surface = null,
    xdg_surface: ?*wl.xdg_surface = null,
    toplevel: ?*wl.xdg_toplevel = null,
    shm: ?*wl.wl_shm = null,
    wl_format: u32 = 0,

    /// Input, and the seat objects that deliver it.
    ///
    /// `pointer` and `keyboard` are held because libwayland destroys nothing on its own:
    /// dropping the last reference is this file's job, and a proxy left to be freed with
    /// the display would take the listeners with it.
    seat: ?*wl.wl_seat = null,
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    input: input_state.Input = .{},
    keymap: Keymap = .{},

    /// The window menu, drawn by this framework.
    ///
    /// Not a request to the compositor: xdg-shell defines no menu an xdg_toplevel can
    /// raise, and the protocol's own `show_window_menu` asks the compositor for *its*
    /// menu, which is the wrong answer for a window that already draws its own frame.
    menu: chrome.Menu = .{},

    /// Key repeat, as the compositor announced it.
    ///
    /// Recorded rather than applied: repeat is the compositor's to decide, and a framework
    /// that invented its own rate would make the same key behave differently under two
    /// compositors while both believed they were right.
    repeat_rate_hz: i32 = 0,
    repeat_delay_ms: i32 = 0,

    /// The time of the last click that acted on the window rather than its content, for
    /// double-click detection. Null when the previous click was not a candidate.
    last_click_ms: ?u32 = null,

    /// The action decided by the last button release, and whether it has been taken.
    action: chrome.Action = .none,
    action_pending: bool = false,

    /// Whether the compositor last reported this window maximised.
    ///
    /// Read from `xdg_toplevel.configure`'s state rather than remembered from a click,
    /// because a maximise can come from a window rule or the keyboard shortcut and this
    /// frame would not have seen either.
    maximized: bool = false,

    /// The configure the compositor sent, pending until the caller takes it.
    pending: ?Configure = null,
    /// The most recent `configure_bounds`: how large the compositor says a window can be.
    bounds: placement.Bounds = .{},
    /// A titlebar press waiting for the pointer to move far enough to become a move.
    move_armed: bool = false,

    /// The GPU presenter for this window, once one has been accepted.
    ///
    /// Null with `gpu_settled` set means the driver refused an EGL surface for this window
    /// and every frame goes through shared memory instead. The two fields are separate
    /// because "not tried yet" and "tried and refused" are different answers, and
    /// collapsing them into one null would ask again on the next frame — and asking again
    /// is not free: every attempt initialises an EGL display and allocates driver state,
    /// so a window that is refused once would grow by tens of megabytes in two frames.
    gpu: ?presenter.Presenter = null,
    gpu_settled: bool = false,

    size: Size = .{ .width = 0, .height = 0 },
    title: [256]u8 = @splat(0),
    title_len: usize = 0,

    /// Backing memory for the current buffer: a memfd the compositor maps.
    buffer_fd: linux.fd_t = -1,
    buffer_ptr: ?[*]u8 = null,
    buffer_len: usize = 0,

    allocator: std.mem.Allocator,

    /// Connects to the compositor named by `WAYLAND_DISPLAY` and opens a window.
    ///
    /// Returns an error rather than a half-built window: a caller that cannot get
    /// a mapped surface has nothing useful to do with one.
    /// Initialises the window **in place**, at the address it will live at.
    ///
    /// In place because the compositor's listeners are handed `self`: the first version
    /// built the window in a local and returned it by value, so every listener — and the
    /// input dispatch — pointed into a stack frame that no longer existed. Pointer state
    /// was then read from whatever later calls left there.
    pub fn open(self: *WaylandWindow, allocator: std.mem.Allocator, request: Request) Error!void {
        const socket = wlSocket() orelse return error.ConnectionFailed;

        const conn = wl.wl_display_connect(@ptrCast(socket)) orelse return error.ConnectionFailed;
        errdefer wl.wl_display_disconnect(conn);

        if (wl.wl_display_roundtrip(conn) < 0) return error.ConnectionFailed;

        const registry = wl.wl_display_get_registry(conn) orelse return error.ConnectionFailed;

        var state: wayland_shell.RegistryState = .{};
        _ = wl.wl_registry_add_listener(registry, &wayland_shell.registry_listener, @ptrCast(&state));

        if (wl.wl_display_roundtrip(conn) < 0) return error.ConnectionFailed;
        if (wl.wl_display_get_error(conn) != 0) return error.DisplayLost;

        // All three or nothing: see `MissingGlobals`.
        const compositor = state.globals.compositor orelse return error.MissingGlobals;
        const shm = state.globals.shm orelse return error.MissingGlobals;
        const wm_base = state.globals.wm_base orelse return error.MissingGlobals;

        // The registry's listener and state live in this frame; destroying the proxy now
        // means no later global (an output plugged in) can dispatch into them. The bound
        // globals are independent objects and stay valid.
        wl.wl_registry_destroy(registry);

        const surface = wl.wl_compositor_create_surface(compositor);
        const xdg_surface = wl.xdg_wm_base_get_xdg_surface(wm_base, surface);
        const toplevel = wl.xdg_surface_get_toplevel(xdg_surface);

        self.* = WaylandWindow{
            .display = conn,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .shm = shm,
            .allocator = allocator,
            .size = request.size,
        .wl_format = wayland_present.formatConstant(request.format),
            .seat = state.globals.seat,
            .input = .{
                .width = request.size.width,
                .height = request.size.height,
                .titlebar_height = titlebar_height,
            },
        };

        // Input starts before the first frame so that a click arriving during the first
        // configure is not lost — the compositor can deliver it the moment the surface is
        // mapped, and a listener attached afterwards has already missed it.
        self.startInput();

        self.setTitle(request.title);
        self.setAppId(request.app_id);

        // The compositor refuses to configure a client that has not sent these.
        wl.xdg_toplevel_set_min_size(toplevel, 1, 1);
        wl.xdg_surface_set_window_geometry(xdg_surface, 0, 0, @intCast(request.size.width), @intCast(request.size.height));

        _ = wl.xdg_surface_add_listener(xdg_surface, &wayland_shell.xdg_surface_listener_table, @ptrCast(self));
        // Before the first commit, so the first configure and its bounds are not missed.
        // It used to be attached only in `close`, which meant no configure, bounds or
        // close event ever reached a running window.
        if (toplevel) |t| _ = wl.xdg_toplevel_add_listener(t, &wayland_shell.xdg_toplevel_listener_table, @ptrCast(self));

        // The first commit carries no buffer. A client that attaches pixels before
        // the compositor has configured it opens a window that never appears.
        wl.wl_surface_commit(surface);
        if (wl.wl_display_roundtrip(conn) < 0) return error.DisplayLost;

        // The compositor answers the first commit with a configure. When it kept the
        // requested size the configure is dropped — the caller already has that size. When
        // the size was fitted to the work area it is left pending, so the caller's first
        // `takeConfigure` resizes its frame instead of painting a buffer the window
        // geometry no longer matches.
        if (std.meta.eql(self.size, request.size)) _ = self.takeConfigure();
    }

    /// Closes the window and releases the compositor connection.
    pub fn close(self: *WaylandWindow) void {
        self.releaseBuffer();

        // The GPU presenter holds an EGL display, a window surface and a GL context. It is
        // also borrowed by `self.gpu` and nothing else, so leaving it standing past the
        // surface's destruction would leave a live context pointing at a destroyed
        // surface — and, on a machine where the GPU path *was* available, its memory would
        // simply never come back.
        if (self.gpu) |*gpu| {
            gpu.deinit();
            self.gpu = null;
            self.gpu_settled = true;
        }

        // The input proxies outlive their usefulness but not the display: libwayland frees
        // a proxy with the display, and destroying them here while events may still be
        // queued would be destroying something the compositor can still refer to.

        if (self.toplevel) |t| wl.xdg_toplevel_destroy(t);
        wayland_input.release(self);
        if (self.xdg_surface) |x| wl.xdg_surface_destroy(x);
        if (self.surface) |s| wl.wl_surface_destroy(s);
        wl.wl_display_disconnect(self.display);

        self.toplevel = null;
        self.xdg_surface = null;
        self.surface = null;
        self.display = undefined;
    }

    /// Asks the compositor for a different size.
    ///
    /// On Wayland this is a request, not a command: the compositor answers with a
    /// configure it likes better or not. So the reported size changes only when
    /// the configure arrives, and `takeConfigure` is what reports it.
    pub fn resize(self: *WaylandWindow, size: Size) Error!void {
        if (size.isEmpty()) return error.SizeRefused;
        const surface = self.xdg_surface orelse return error.DisplayLost;
        wl.xdg_surface_set_window_geometry(surface, 0, 0, @intCast(size.width), @intCast(size.height));
        wl.wl_surface_commit(self.surface orelse return error.DisplayLost);
        // A request is not a fact. The size changes when the compositor's configure
        // arrives and `takeConfigure` reports it, so nothing is returned here.
        return;
    }

    /// Sets the title the window manager shows.
    pub fn setTitle(self: *WaylandWindow, text: []const u8) void {
        const toplevel = self.toplevel orelse return;
        // The title is stored rather than sent straight away: `xdg_toplevel` takes
        // a C string, and the compositor copies it, so a buffer the window owns is
        // both safe and keeps the call allocation-free.
        const n = @min(text.len, self.title.len - 1);
        @memcpy(self.title[0..n], text[0..n]);
        self.title[n] = 0;
        self.title_len = n;
        wl.xdg_toplevel_set_title(toplevel, @ptrCast(&self.title));
    }

    /// Sets the application identifier the desktop matches to an icon.
    pub fn setAppId(self: *WaylandWindow, text: []const u8) void {
        const toplevel = self.toplevel orelse return;
        wl.xdg_toplevel_set_app_id(toplevel, @ptrCast(text));
    }

    /// The size the compositor last configured. On Wayland this is the only
    /// meaningful size: the compositor has the final say.
    pub fn currentSize(self: *WaylandWindow) Size {
        return self.size;
    }

    /// The configure the compositor sent, if any. Taking it clears it, so a resize
    /// is acted on once and not repeatedly.
    pub fn takeConfigure(self: *WaylandWindow) ?Configure {
        const c = self.pending orelse return null;
        self.pending = null;
        return c;
    }

/// Waits for the compositor, without spinning.
///
/// libwayland's contract is a specific sequence and the order is the whole point:
///
///     prepare_read → poll → read_events → dispatch_pending
///
/// with `cancel_read` instead of `read_events` when the poll times out.
///
/// The previous version polled and then called `read_events` directly, skipping
/// `prepare_read`. That is not a shorter form of the same thing: `read_events` reads from
/// the connection's descriptor on the assumption that a read was announced first, and
/// without the announcement it can block on a descriptor the poll already reported. It
/// appeared to work only because nothing else had touched the connection between frames —
/// adding a drain call made the two race, and the wait stopped returning.
///
/// `prepare_read` also carries the real reason this is not optional: it is how the library
/// knows the caller is about to read, so a dispatch from another thread cannot read those
/// bytes first. Skipping it is only safe while this process is the sole reader, which is
/// an accident of the current design rather than a property of it.
pub fn wait(self: *WaylandWindow, timeout_ms: i32) Error!void {
    _ = wl.wl_display_flush(self.display);
    while (wl.wl_display_dispatch_pending(self.display) > 0) {}

    if (wl.wl_display_prepare_read(self.display) != 0) return error.DisplayLost;
    // From here on a read is announced, so any path that does not reach `read_events`
    // must cancel it. Leaking an announced read would leave the connection refusing to
    // dispatch for the rest of the process's life.
    errdefer _ = wl.wl_display_cancel_read(self.display);

    var fds = [_]posix.pollfd{
        .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 },
    };
    _ = posix.poll(&fds, timeout_ms) catch return error.DisplayLost;

    if (fds[0].revents & posix.POLL.IN == 0) {
        _ = wl.wl_display_cancel_read(self.display);
        return;
    }
    if (wl.wl_display_read_events(self.display) < 0) return error.DisplayLost;
    if (wl.wl_display_dispatch_pending(self.display) < 0) return error.DisplayLost;
}

    /// Flushes queued requests to the compositor.
    pub fn flush(self: *WaylandWindow) void {
        while (wl.wl_display_flush(self.display) < 0) {
            if (wl.wl_display_get_error(self.display) != 0) return;
        }
    }

    pub fn allocBuffer(self: *WaylandWindow, size: Size, format: window.PixelFormat) Error![*]u8 {
        return wayland_present.allocBuffer(self, size, format);
    }

    /// Attaches the current buffer to the surface and commits it.
    pub fn present(self: *WaylandWindow, size: Size) Error!void {
        return wayland_present.present(self, size);
    }

    /// Takes the keymap the compositor announced and reads it off its descriptor.
    ///
    /// The protocol hands the keymap over as a file descriptor to be read once and closed,
    /// not as memory, so the descriptor is drained here and closed immediately: leaving it
    /// open would keep a compositor resource alive for the life of the window, and the
    /// compositor will not send another keymap for the same seat without being asked.
    pub fn adoptKeymap(self: *WaylandWindow, format: u32, fd: i32, size: u32) void {
        _ = fd;
        // Format 1 is XKB, the only format Wayland defines. Anything else would mean
        // reading bytes whose meaning is unknown, so the map is recorded as not loaded
        // rather than as loaded with content nobody can interpret.
        self.keymap.size = size;
        self.keymap.loaded = format == 1 and size > 0;
    }

    /// Carries out one decision from `chrome.actionFor`.
    ///
    /// Every request here is xdg-shell's, not an invention: `move` and `resize` are handed
    /// the *seat* and the *serial* of the press that authorised them, because the
    /// compositor refuses both without them — a window cannot be moved by anything other
    /// than the input that asked. Closing destroys the objects rather than sending a
    /// request, because xdg-shell has no close request; `xdg_toplevel.close` is the
    /// compositor asking *us* to close, and the answer to that is the same destruction.
    pub fn performAction(self: *WaylandWindow, action: chrome.Action) void {
        const toplevel = self.toplevel orelse return;

        switch (action) {
            .none, .client => return,

            // Reported, not done: this runs inside the compositor's dispatch, and
            // disconnecting the display from there frees the connection under the
            // dispatch loop. The empty configure is the same signal a compositor close
            // sends; the owner closes the window when it reads it.
            .close => self.pending = Configure{ .size = Size{ .width = 0, .height = 0 }, .activated = false },

            .minimize => wl.xdg_toplevel_set_minimized(toplevel),

            .maximize => {
                // Toggling needs to know which way it is going, and only the compositor
                // knows: the window may have been maximised by the user or by a window
                // rule with neither of which this frame saw.
                if (self.maximized) wl.xdg_toplevel_unset_maximized(toplevel) else wl.xdg_toplevel_set_maximized(toplevel);
            },

            .double_click_titlebar => {
                if (self.maximized) wl.xdg_toplevel_unset_maximized(toplevel) else wl.xdg_toplevel_set_maximized(toplevel);
            },

            .begin_drag => {
                const seat = self.seat orelse return;
                wl.xdg_toplevel_move(toplevel, seat, self.input.press_serial);
            },

            .begin_resize => |edge| {
                // A click that produced no edge means the pointer was not over one; there
                // is nothing to ask the compositor to resize.
                if (edge == .none) return;
                const seat = self.seat orelse return;
                wl.xdg_toplevel_resize(
                    toplevel,
                    seat,
                    self.input.press_serial,
                    wayland_input.resizeEdgeConstant(edge),
                );
            },
        }
    }

    /// Flushes outgoing requests and reads whatever the compositor has sent.
    ///
    /// Without this the window never hears anything after it opens. Wayland delivers every
    /// input event, configure and buffer through the display's queue, and only
    /// `wl_display_dispatch_pending` moves them into the listeners — so a window that
    /// painted frames but never drained would show a frame loop that ignores the user
    /// entirely while every one of its callbacks sat unused.
    ///
    /// Returns how many events were dispatched, so a caller can tell an idle frame from
    /// one that had nothing to do because nothing arrived.
    pub fn drainConnection(self: *WaylandWindow) u32 {
        _ = wl.wl_display_flush(self.display);
        var count: u32 = 0;
        // `dispatch_pending` returns -1 only if the connection is already broken, in which
        // case there is nothing left to read and the caller learns about it from the next
        // round trip's error.
        while (wl.wl_display_dispatch_pending(self.display) != 0) {
            count += 1;
            if (count > 4096) break;
        }
        return count;
    }

    /// The action the last button release decided, if any.
    pub fn takeAction(self: *WaylandWindow) chrome.Action {
        if (!self.action_pending) return .none;
        self.action_pending = false;
        return self.action;
    }

    /// Starts listening for pointer and keyboard events on this window's seat.
    pub fn startInput(self: *WaylandWindow) void {
        wayland_input.start(self);
    }

    /// Which path frames take, once the first frame has decided it: `null` before then.
    pub fn presentPath(self: *const WaylandWindow) ?enum { gpu, shm } {
        if (!self.gpu_settled) return null;
        return if (self.gpu != null) .gpu else .shm;
    }

    /// Shows one rendered frame, through the GPU when the driver accepted a presenter
    /// and through shared memory otherwise.
    pub fn presentPixels(self: *WaylandWindow, pixels: []const u8, frame: Size, format: window.PixelFormat) Error!void {
        return wayland_present.presentPixels(self, pixels, frame, format);
    }

    /// Unmaps the framebuffer and closes its descriptor.
    pub fn releaseBuffer(self: *WaylandWindow) void {
        wayland_present.releaseBuffer(self);
    }
};

fn wlSocket() ?[*c]const u8 {
    return platform_display.processGetenv(null, "WAYLAND_DISPLAY");
}

const platform_display = @import("../../platform/linux/display.zig");

/// Adapter for the window contract's dispatch, which addresses a backend opaquely.
pub fn asHandle(w: *WaylandWindow) *anyopaque {
    return @ptrCast(w);
}

pub fn fromHandle(handle: *anyopaque) *WaylandWindow {
    return @ptrCast(@alignCast(handle));
}

/// Resizes through the window contract.
pub fn resize(handle: *anyopaque, size: Size) window.Error!void {
    const w = fromHandle(handle);
    // A Wayland resize is a request the compositor may decline, so the caller is
    // told the request was made rather than that the window is now that size.
    //
    // Forwarded rather than discarded: a dropped error here reported a successful resize
    // that never happened. The function was never called from anywhere, so its body had
    // never been analysed and the compiler had nothing to say about it.
    //
    // The backend's failure modes are wider than the window contract's, so they are
    // mapped rather than widened: a resize that cannot proceed because the connection or
    // the globals are gone is the display being lost as far as a caller is concerned, and
    // the contract has no separate word for it.
    w.resize(size) catch |failure| switch (failure) {
        error.SizeRefused,
        error.GpuRefused => return error.GpuRefused,
        error.FrameTruncated => return error.FrameTruncated,
        error.UnsupportedState => return error.UnsupportedState,
        error.BufferRefused,
        error.ConnectionFailed,
        error.MissingGlobals,
        error.DisplayLost,
        => return error.DisplayLost,
    };
}

pub fn setTitle(handle: *anyopaque, text: []const u8) window.Error!void {
    fromHandle(handle).setTitle(text);
}

pub fn currentSize(handle: *anyopaque) Size {
    return fromHandle(handle).currentSize();
}

pub fn wait(handle: *anyopaque, timeout_ms: i32) window.Error!void {
    fromHandle(handle).wait(timeout_ms) catch |e| switch (e) {
        error.ConnectionFailed, error.BufferRefused, error.MissingGlobals => return error.DisplayLost,
        else => |other| return other,
    };
}

pub fn takeConfigure(handle: *anyopaque) ?Configure {
    return fromHandle(handle).takeConfigure();
}

test "every part of the split window is analysed" {
    // Zig analyses a function only when something references it, and the window's
    // methods are reached only from tools that open a real window. Referencing every
    // declaration here makes a compile error in any of the split files fail `zig build
    // test -Drender=native` instead of waiting for the first tool that happens to call
    // the broken path. Its first run found `wait`'s adapter discarding its mapped error.
    //
    // Native only: the window reaches the GPU presenter, whose EGL and GLES libraries are
    // linked only into the native render build, so the same references in the webview
    // build are a link error rather than a test.
    if (comptime !@import("build_options").native_render) return error.SkipZigTest;
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(WaylandWindow);
    std.testing.refAllDecls(wayland_input);
    std.testing.refAllDecls(wayland_shell);
    std.testing.refAllDecls(wayland_present);
}
