//! Screen geometry from XCB, reached through `libxcb` itself.
//!
//! Xlib allocates, hides connections and hands values back behind accessors.
//! XCB does not: it is the protocol library, so a query here is a request and a
//! reply, and the screen dimensions arrive as integers. That is why the X11 path
//! is XCB rather than Xlib — not preference, but the absence of an allocator on
//! a path that runs at startup.

const std = @import("std");

const xcb = @import("c_xcb_probe");

/// The RandR extension key, declared here rather than taken from the header.
///
/// `xcb_randr_id` is an `extern` global whose type, `xcb_extension_t`, is opaque:
/// it is a key into libxcb's own extension cache, and nothing about it is
/// readable. `@cImport` cannot translate a value of an opaque type, so the symbol
/// is declared directly. Only its address is ever used, which makes the layout
/// irrelevant — but the linkage is not, and `extern` gives the linker the
/// reference to libxcb.
const ExtensionKey = extern struct {
    unreadable: [0]u8,
};

extern var xcb_randr_id: ExtensionKey;

pub const Error = error{
    ConnectionFailed,
    HandshakeFailed,
    NoScreens,
};

/// The root window's screen geometry, as the server reports it.
pub const Screen = struct {
    width: u32,
    height: u32,
    /// Refresh in millihertz, from the RandR output's active mode. Zero when the
    /// extension is absent, which is normal on a headless X server.
    refresh_mhz: u32,
};

/// Connects to `display` and reads the root screen's geometry.
///
/// Returns an error rather than a fallback size: a window opened at an invented
/// geometry is a bug the developer must debug, while an error here is a fact
/// they can act on.
pub fn probe(display: [*:0]const u8) Error!Screen {
    const maybe_conn = xcb.xcb_connect(@ptrCast(display), null);
    const conn: *xcb.xcb_connection_t = maybe_conn orelse return error.ConnectionFailed;
    defer xcb.xcb_disconnect(conn);

    if (xcb.xcb_connection_has_error(conn) != 0) return error.ConnectionFailed;

    const setup = xcb.xcb_get_setup(conn) orelse return error.HandshakeFailed;
    // The iterator carries a cursor (`data`), a count (`rem`) and an index, rather
    // than a slice: XCB hands back a pointer into its own reply, which stays valid
    // for as long as the setup reply does.
    const roots = xcb.xcb_setup_roots_iterator(setup);
    if (roots.rem == 0) return error.NoScreens;

    // The first screen is the one a single-monitor session uses. Multi-screen
    // setups are described through RandR, read just below.
    const screen = roots.data[0];

    var result = Screen{
        .width = @intCast(screen.width_in_pixels),
        .height = @intCast(screen.height_in_pixels),
        .refresh_mhz = 0,
    };

    result.refresh_mhz = readRefresh(conn, screen.root);
    return result;
}

/// Reads the active mode's refresh rate through RandR.
///
/// Every failure path returns zero, which `Display` documents as "not reported".
/// A missing rate is normal and must not be invented; a wrong one is worse than
/// no rate at all, because frame budgeting would be built on it.
/// Mirrors of the two RandR reply headers, whose counts are needed to walk their
/// inline arrays. Only the count fields are read; the inline data itself is
/// reached through the library's own accessors.
fn readRefresh(conn: *xcb.xcb_connection_t, root: xcb.xcb_window_t) u32 {
    // `xcb_get_extension_data` returns a borrowed reply owned by libxcb's cache,
    // so it is read and never freed. A null pointer means the extension is absent.
    const ext = xcb.xcb_get_extension_data(conn, @ptrCast(&xcb_randr_id));
    if (ext == null) return 0;

    // The reply struct comes through `@cImport` as opaque, so its first bytes are
    // read through a mirror of the protocol's own layout. `present` is what
    // answers the only question being asked here: does this server have RandR at
    // all. Reading nothing else from it means the mirror cannot drift into
    // asserting something about a field it has no business reading.
    const ExtensionReply = extern struct {
        response_type: u8,
        pad: u8,
        sequence: u16,
        length: u32,
        present: u8,
        major_opcode: u8,
        first_event: u8,
        first_error: u8,
    };
    const reply: *const ExtensionReply = @ptrCast(@alignCast(ext));
    if (reply.present == 0) return 0;

    // `get_screen_info` is the cheaper answer: it carries the rate the screen is
    // running at directly, so there is no second request to thread. It is not
    // per-output — a multi-head server can run its outputs at different rates —
    // but for a window on one screen it is the number that matters, and it is the
    // honest number rather than a rate guessed from a mode list the server does
    // not have to populate.
    const cookie = xcb.xcb_randr_get_screen_info(conn, root);
    const info = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse return 0;
    defer std.c.free(info);

    // The reply arrives as an opaque pointer, so one field is read through a
    // mirror of the protocol's own layout. `rate` is the screen's current refresh
    // in hertz; nothing else in the mirror is consulted, so it cannot drift into
    // asserting something about a field it has no business reading.
    const ScreenInfo = extern struct {
        response_type: u8,
        rotations: u8,
        sequence: u16,
        length: u32,
        root: u32,
        timestamp: u32,
        config_timestamp: u32,
        n_sizes: u16,
        size_id: u16,
        rotation: u16,
        rate: u16,
        n_info: u16,
        pad: [2]u8,
    };
    const screen: *const ScreenInfo = @ptrCast(@alignCast(info));

    if (screen.rate == 0) return 0;
    return @as(u32, @intCast(@as(u64, screen.rate) * 1000));
}

test {
    _ = xcb;
    _ = readRefresh;
}
