//! libwpe-display-lepton.so — a WebKit display that belongs to this framework.
//!
//! **This is not a WebKit patch.** `wpe_display_get_default()` asks a GIO extension
//! point for a display and takes the first one that connects:
//!
//!     auto* extensionPoint = g_io_extension_point_lookup(WPE_DISPLAY_EXTENSION_POINT_NAME);
//!     for (auto* i = g_io_extension_point_get_extensions(extensionPoint); i; ...) {
//!         g_object_new(g_io_extension_get_type(extension), nullptr);
//!         if (wpe_display_connect(display, nullptr)) { s_defaultDisplay = display; return; }
//!     }
//!
//! and `wpeEnsureExtensionPointsLoaded()` fills that point by `dlopen`-ing every module
//! under `WPE_PLATFORMS_PATH`. So supplying a display means registering a GType against
//! the point named `WPE_DISPLAY_EXTENSION_POINT_NAME` — `"wpe-platform-display"`,
//! WPEDisplay.h:48 — and being selected by `WPE_PLATFORM=lepton`.
//!
//! The hook was never visible from the headers, which is why the search that led here
//! concluded that WebKit would have to be patched. It did not. What was measured instead
//! is recorded below, including the two ways a first attempt fails in ways that look
//! like progress.
//!
//! **What is implemented here.** A `WPEDisplay` subclass whose `connect` succeeds, so
//! that the engine draws into this framework. It is not yet a working platform: EGL, a
//! keymap, a clipboard and the buffer handshake are all still to come, and a display
//! without them will not paint a page. That is the next increment, not this one. This
//! increment establishes that the pixels are reachable at all — the whole plan rests on
//! that, and it cost a long search to find out.

const std = @import("std");
const counters_mod = @import("counters.zig");

const GType = c_ulong;
const Gpointer = ?*anyopaque;

const g_type_register_static = @extern(
    *const fn (GType, [*:0]const u8, *const GTypeInfo, c_int) callconv(.c) GType,
    .{ .name = "g_type_register_static" },
);

const g_io_extension_point_implement = @extern(
    *const fn ([*:0]const u8, GType, [*:0]const u8, c_int) callconv(.c) Gpointer,
    .{ .name = "g_io_extension_point_implement" },
);

/// `wpe_view_render_buffer`'s last parameter is `GError **`, so it is declared as a
/// pointer-to-optional rather than as an optional: a `GError **` is a pointer *to* a
/// pointer, and a Zig optional would have been the wrong shape by exactly one level.
/// `EGL_PLATFORM_SURFACELESS_MESA` — EGL/eglext.h:1093
const egl_platform_surfaceless: c_uint = 0x31DD;
/// `EGL_PLATFORM_GBM_MESA` — EGL/eglext.h:1088
const egl_platform_gbm: c_uint = 0x31D7;
/// `EGL_DEFAULT_DISPLAY`
const egl_default_display: Gpointer = null;

/// `EGLDisplay eglGetPlatformDisplay(EGLenum, void *, const EGLAttrib *)` — EGL/egl.h:331
const egl_get_platform_display = @extern(
    *const fn (c_uint, ?*anyopaque, ?*const anyopaque) callconv(.c) ?*anyopaque,
    .{ .name = "eglGetPlatformDisplay" },
);

/// `struct gbm_device *gbm_create_device(int fd)` — gbm.h:357
const gbm_create_device = @extern(
    *const fn (c_int) callconv(.c) ?*anyopaque,
    .{ .name = "gbm_create_device" },
);

/// `guint g_timeout_add(guint interval, GSourceFunc, gpointer)` — glib.h
///
/// The repaint tick. A platform owns the loop that redraws its views — the DRM backend
/// has one, the Wayland backend has one — and putting it here rather than in the core
/// keeps the core free of webview-specific timing.
const g_timeout_add = @extern(
    *const fn (c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_uint,
    .{ .name = "g_timeout_add" },
);

const g_idle_add = @extern(
    *const fn (*const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_uint,
    .{ .name = "g_idle_add" },
);

const g_source_remove = @extern(
    *const fn (c_uint) callconv(.c) c_int,
    .{ .name = "g_source_remove" },
);

const g_object_ref = @extern(
    *const fn (Gpointer) callconv(.c) Gpointer,
    .{ .name = "g_object_ref" },
);

/// The DRM render node, used only by the GBM fallback.
const drm_render_node = "/dev/dri/renderD128";

const wpe_view_render_buffer = @extern(
    *const fn (Gpointer, Gpointer, ?*const anyopaque, c_uint, *?*anyopaque) callconv(.c) c_int,
    .{ .name = "wpe_view_render_buffer" },
);

const wpe_buffer_import_to_pixels = @extern(
    *const fn (Gpointer, *?*anyopaque) callconv(.c) Gpointer,
    .{ .name = "wpe_buffer_import_to_pixels" },
);

const g_bytes_get_size = @extern(
    *const fn (Gpointer) callconv(.c) usize,
    .{ .name = "g_bytes_get_size" },
);

/// `g_bytes_get_data(GBytes *, gsize *)` — the out parameter is a length, not an error,
/// so it is declared as a `usize *` rather than as a pointer to an optional. Conflating
/// those two is an easy slip and this signature has no business looking like the other.
const g_bytes_get_data = @extern(
    *const fn (Gpointer, *usize) callconv(.c) ?*const anyopaque,
    .{ .name = "g_bytes_get_data" },
);

/// `GBytes *wpe_buffer_shm_get_data(WPEBufferSHM *)` — WPEBufferSHM.h
///
/// The direct read for a shared-memory buffer, bypassing the import path entirely. Declared
/// here because it is only valid for that buffer type, and which type this is has to be
/// established rather than assumed.
const wpe_buffer_shm_get_data = @extern(
    *const fn (?*anyopaque) callconv(.c) Gpointer,
    .{ .name = "wpe_buffer_shm_get_data" },
);

const wpe_buffer_shm_get_stride = @extern(
    *const fn (?*anyopaque) callconv(.c) c_uint,
    .{ .name = "wpe_buffer_shm_get_stride" },
);

const g_type_name_from_instance = @extern(
    *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    .{ .name = "g_type_name_from_instance" },
);

const wpe_buffer_get_width = @extern(
    *const fn (Gpointer) callconv(.c) c_int,
    .{ .name = "wpe_buffer_get_width" },
);

const wpe_buffer_get_height = @extern(
    *const fn (Gpointer) callconv(.c) c_int,
    .{ .name = "wpe_buffer_get_height" },
);

const wpe_view_get_type = @extern(
    *const fn () callconv(.c) GType,
    .{ .name = "wpe_view_get_type" },
);

/// `GObject *g_object_new(GType, const gchar *first_property_name, ...)`.
///
/// Declared with a fixed arity rather than as a variadic because Zig will not put a
/// `null` into a C varargs list. It is still the correct call: on the SysV ABI a
/// variadic callee reads its arguments by position out of the same registers a
/// fixed-arity call passes them in, and this callee reads three pointers — the first
/// property name, its value, and the null that ends the list. The shape is fixed here
/// because every call site in this module passes exactly that.
///
/// The property name is not in the public header. `WPEView.h` documents
/// `wpe_view_get_display` but no `display` construct property, because the property is
/// declared in a private header — which is also why a view built without it gets as far
/// as `wpe_input_method_context_new` and then faults on a null display.
const g_object_new = @extern(
    *const fn (GType, ?[*:0]const u8, ?*const anyopaque, ?*const anyopaque) callconv(.c) Gpointer,
    .{ .name = "g_object_new" },
);

/// The property a `WPEView` is constructed with, naming the display it lives on.
const view_display_property = "display";

const wpe_display_get_type = @extern(
    *const fn () callconv(.c) GType,
    .{ .name = "wpe_display_get_type" },
);

/// `struct _GTypeInfo` — gobject/gtype.h
const GTypeInfo = extern struct {
    class_size: u16,
    base_init: ?*const fn (Gpointer) callconv(.c) void,
    base_finalize: ?*const fn (Gpointer) callconv(.c) void,
    class_init: ?*const fn (Gpointer, Gpointer) callconv(.c) void,
    class_finalize: ?*const fn (Gpointer, Gpointer) callconv(.c) void,
    class_data: ?*const anyopaque,
    instance_size: u16,
    n_preallocs: u16,
    instance_init: ?*const fn (Gpointer, Gpointer) callconv(.c) void,
    value_table: ?*const anyopaque,
};

/// `struct _WPEDisplayClass` — WPEDisplay.h:56-83, following `GObjectClass`.
///
/// Every size and offset below is measured, not assumed, and the measurements are
/// asserted at compile time. `sizeof(GObjectClass)` is 136, so the vtable starts there
/// and `sizeof(WPEDisplayClass)` is 496 — thirteen vtable slots then 32 reserved
/// pointers. Counting the parent struct by hand gives 144, which is wrong by eight bytes;
/// writing a function pointer at 144 would land it in `connect`'s neighbour and corrupt
/// the parent's vtable silently. Asserting is what turns that from a mystery crash into
/// a build error.
const WPEDisplayClass = extern struct {
    parent_class: [136]u8 align(8),
    connect: ?*const fn (Gpointer, Gpointer) callconv(.c) c_int,
    create_view: ?*const fn (Gpointer) callconv(.c) Gpointer,
    get_egl_display: ?*const fn (Gpointer, *?*anyopaque) callconv(.c) Gpointer,
    get_keymap: ?*const fn (Gpointer) callconv(.c) Gpointer,
    get_clipboard: ?*const fn (Gpointer) callconv(.c) Gpointer,
    get_preferred_buffer_formats: ?*const fn (Gpointer) callconv(.c) Gpointer,
    get_n_screens: ?*const fn (Gpointer) callconv(.c) c_uint,
    get_screen: ?*const fn (Gpointer, c_uint) callconv(.c) Gpointer,
    get_drm_device: ?*const fn (Gpointer) callconv(.c) Gpointer,
    use_explicit_sync: ?*const fn (Gpointer) callconv(.c) c_int,
    create_input_method_context: ?*const fn (Gpointer, Gpointer) callconv(.c) Gpointer,
    create_toplevel: ?*const fn (Gpointer, c_uint) callconv(.c) Gpointer,
    create_gamepad_manager: ?*const fn (Gpointer) callconv(.c) Gpointer,
    padding: [32]Gpointer,
};

/// `sizeof(WPEDisplay)` — the instance struct; no fields of it are needed yet.
const instance_size: u16 = 32;

/// `struct _WPEViewClass` — WPEView.h:53-66, following `GObjectClass`.
///
/// Nine slots then 32 reserved pointers: 136 + 72 + 256 is 464, which is what C reports
/// for `sizeof(WPEViewClass)`. Asserted below for the same reason the display's table is.
/// Two of these were wrong when first written and are transcribed from WPEView.h:53-66
/// rather than from a summary of it:
///
/// - `buffers_changed` takes `(view, WPEBuffer **buffers, guint n_buffers)`, not a
///   `WPEBufferFormats *`. It is told about *buffers*, not about formats.
/// - `render_buffer` takes five arguments, the last being `GError **`. Dropping it "works"
///   on x86-64, where the spare register is simply ignored, which is precisely how a wrong
///   signature survives until it matters on another ABI.
///
/// - `set_cursor_from_bytes` takes six: bytes, width, height, stride, and two hotspot
///   coordinates.
const WPEViewClass = extern struct {
    parent_class: [136]u8 align(8),
    buffers_changed: ?*const fn (Gpointer, ?*const ?*anyopaque, c_uint) callconv(.c) void,
    render_buffer: ?*const fn (Gpointer, Gpointer, ?*const anyopaque, c_uint, *?*anyopaque) callconv(.c) c_int,
    lock_pointer: ?*const fn (Gpointer) callconv(.c) c_int,
    unlock_pointer: ?*const fn (Gpointer) callconv(.c) c_int,
    set_cursor_from_name: ?*const fn (Gpointer, ?[*:0]const u8) callconv(.c) void,
    set_cursor_from_bytes: ?*const fn (Gpointer, Gpointer, c_uint, c_uint, c_uint, c_uint, c_uint) callconv(.c) void,
    set_opaque_rectangles: ?*const fn (Gpointer, ?*const anyopaque, c_uint) callconv(.c) void,
    can_be_mapped: ?*const fn (Gpointer) callconv(.c) c_int,
    get_accessible: ?*const fn (Gpointer) callconv(.c) Gpointer,
    padding: [32]Gpointer,
};

/// `sizeof(WPEView)`.
const view_instance_size: u16 = 32;

comptime {
    if (@offsetOf(WPEViewClass, "buffers_changed") != 136) @compileError("WPEViewClass.buffers_changed is not at 136");
    if (@offsetOf(WPEViewClass, "render_buffer") != 144) @compileError("WPEViewClass.render_buffer is not at 144");
    if (@offsetOf(WPEViewClass, "can_be_mapped") != 192) @compileError("WPEViewClass.can_be_mapped is not at 192");
    if (@offsetOf(WPEViewClass, "get_accessible") != 200) @compileError("WPEViewClass.get_accessible is not at 200");
    if (@sizeOf(WPEViewClass) != 464) @compileError("WPEViewClass is not 464 bytes");
}

comptime {
    if (@offsetOf(WPEViewClass, "buffers_changed") != 136) @compileError("WPEViewClass.buffers_changed is not at 136");
    if (@offsetOf(WPEViewClass, "render_buffer") != 144) @compileError("WPEViewClass.render_buffer is not at 144");
    if (@offsetOf(WPEViewClass, "can_be_mapped") != 192) @compileError("WPEViewClass.can_be_mapped is not at 192");
    if (@offsetOf(WPEViewClass, "get_accessible") != 200) @compileError("WPEViewClass.get_accessible is not at 200");
    if (@sizeOf(WPEViewClass) != 464) @compileError("WPEViewClass is not 464 bytes");
    if (@offsetOf(WPEDisplayClass, "connect") != 136) @compileError("WPEDisplayClass.connect is not at 136");
    if (@offsetOf(WPEDisplayClass, "create_view") != 144) @compileError("WPEDisplayClass.create_view is not at 144");
    if (@offsetOf(WPEDisplayClass, "get_egl_display") != 152) @compileError("WPEDisplayClass.get_egl_display is not at 152");
    if (@offsetOf(WPEDisplayClass, "get_preferred_buffer_formats") != 176) @compileError("WPEDisplayClass.get_preferred_buffer_formats is not at 176");
    if (@offsetOf(WPEDisplayClass, "create_toplevel") != 224) @compileError("WPEDisplayClass.create_toplevel is not at 224");
    if (@sizeOf(WPEDisplayClass) != 496) @compileError("WPEDisplayClass is not 496 bytes");
}

/// `WPE_DISPLAY_EXTENSION_POINT_NAME` — WPEDisplay.h:48.
const extension_point_name = "wpe-platform-display";

/// What `WPE_PLATFORM=lepton` selects.
const extension_name = "lepton";

var display_type: GType = 0;

/// Reports itself connected, and that is the entire claim so far.
///
/// Returning true is what makes `wpe_display_get_default()` stop here. A subclass whose
/// `connect` failed would be skipped, and every check downstream would pass without
/// proving anything — which is why this returns true before EGL exists, and why the
/// checks that follow look at the display's *type* rather than at what it drew.
fn connect(display: Gpointer, error_out: Gpointer) callconv(.c) c_int {
    _ = display;
    _ = error_out;
    return 1;
}

var counters: counters_mod.Counters = .{
    .views_created = 0,
    .buffers_changed = 0,
    .render_buffer_calls = 0,
    .can_be_mapped_asked = 0,
    .buffers_allocated = 0,
    .frames_read_back = 0,
    .pixels_non_zero = 0,
    .egl_displays_created = 0,
    .egl_failures = 0,
    .ticks = 0,
    .render_requests = 0,
    .render_refusals = 0,
    .frames_with_pixels = 0,
    .views_without_a_loop = 0,
};

/// Repaint cadence in milliseconds.
///
/// The same cadence the window layer paints at. A faster tick would ask the engine for
/// frames it cannot produce and measure nothing but refusal.
const repaint_interval_ms: c_uint = 16;

/// How many views this module repaints.
const slot_count = 4;

/// Buffers kept per view. The engine offered two when this was measured; a larger offer
/// is truncated rather than indexed past, because a platform that trusts a count it has
/// not checked reads uninitialised memory the day the engine changes its mind.
const slot_buffers = 2;

/// Frames to render before the repaint loop stops.
///
/// Bounded because an unbounded loop outlives the measurement that justified it, and a
/// loop that never stops producing frames is a battery bug with a better story.
const frames_before_stopping = 3;

/// One view this platform repaints, and the buffers the engine offered for it.
///
/// A small fixed table rather than a single global because "one window per process" is a
/// property of this framework's window layer and not of its platform implementation, and a
/// platform that cannot survive a second window finds out in someone else's bug report.
const Slot = struct {
    view: ?*anyopaque = null,
    buffers: [slot_buffers]?*anyopaque = .{ null, null },
    n_buffers: u32 = 0,
    next: u32 = 0,
    timeout: c_uint = 0,
};

var slots: [slot_count]Slot = @splat(.{});

/// Reads a buffer back and records what was in it.
///
/// The size alone proves nothing — an unwritten allocation is exactly the right size — so
/// what is recorded is non-zero pixels and the first pixel's value. That is the difference
/// between "the page was drawn" and "the engine gave me memory".
fn sampleBuffer(buffer: ?*anyopaque) void {
    const target = buffer orelse return;
    const width = wpe_buffer_get_width(target);
    const height = wpe_buffer_get_height(target);

    // What kind of buffer is this? The answer decides how it can be read, and guessing
    // wrong here produces a correct-looking zero rather than an error: `import_to_pixels`
    // on a buffer whose pixels live on a GPU has nothing CPU-side to hand back.
    const kind = g_type_name_from_instance(target);
    const kind_name: []const u8 = if (kind) |k| std.mem.span(k) else "<not an object>";
    const is_shm = std.mem.eql(u8, kind_name, "WPEBufferSHM");

    if (counters.frames_with_pixels == 0 and counters.frames_read_back == 0) {
        std.debug.print("[lepton] buffer type {s} stride={d} shm={}\n", .{
            kind_name, wpe_buffer_shm_get_stride(target), is_shm,
        });
    }

    // Shared memory can be read straight through, with no import step that might be the
    // thing quietly returning nothing.
    if (is_shm) {
        const stride = wpe_buffer_shm_get_stride(target);
        const direct = wpe_buffer_shm_get_data(target);
        counters.frames_read_back += 1;
        const non_zero = countNonZero(direct, stride * @as(usize, @intCast(height)));
        counters.pixels_non_zero = non_zero;
        if (non_zero != 0 and counters.frames_with_pixels == 0) {
            counters.frames_with_pixels += 1;
            std.debug.print("[lepton] SHM {d}x{d} stride={d} non_zero={d} -- drawn\n", .{
                width, height, stride, non_zero,
            });
        }
        return;
    }

    var read_error: ?*anyopaque = null;
    const pixels = wpe_buffer_import_to_pixels(target, &read_error) orelse {
        counters.frames_read_back += 1;
        counters.pixels_non_zero = 0;
        std.debug.print("[lepton] {d}x{d} unreadable (err={*})\n", .{ width, height, read_error });
        return;
    };

    const size = g_bytes_get_size(pixels);
    var data_len: usize = 0;
    const data = g_bytes_get_data(pixels, &data_len);

    var non_zero: usize = 0;
    var first_word: u32 = 0;
    if (data) |raw| {
        const available: usize = if (data_len < size) data_len else size;
        const sampled: []const u8 = @as([*]const u8, @ptrCast(raw))[0..available];
        var offset: usize = 0;
        while (offset + 4 <= available) : (offset += 4) {
            if (std.mem.readInt(u32, sampled[offset..][0..4], .little) != 0) non_zero += 1;
        }
        if (available >= 4) first_word = std.mem.readInt(u32, sampled[0..4], .little);
    }

    counters.frames_read_back += 1;
    counters.pixels_non_zero = non_zero;
    if (non_zero != 0 and counters.frames_with_pixels == 0) {
        counters.frames_with_pixels += 1;
        std.debug.print("[lepton] {d}x{d} first=0x{x} non_zero={d} of {d} -- drawn, not empty\n", .{
            width, height, first_word, non_zero, size / 4,
        });
    }
}

/// Counts non-zero 32-bit pixels in `GBytes`-backed memory, reporting how many it looked at.
///
/// The count is of pixels, not bytes, so it can be compared against `width * height`
/// directly — "576000 of 576000" and "0 of 576000" mean different things and the byte
/// count alone would not distinguish them.
fn countNonZero(bytes: ?*anyopaque, limit: usize) usize {
    const raw = bytes orelse return 0;
    var length: usize = 0;
    if (g_bytes_get_data(raw, &length)) |data| {
        const available = if (length < limit) length else limit;
        const sampled: []const u8 = @as([*]const u8, @ptrCast(data))[0..available];
        var non_zero: usize = 0;
        var offset: usize = 0;
        while (offset + 4 <= available) : (offset += 4) {
            if (std.mem.readInt(u32, sampled[offset..][0..4], .little) != 0) non_zero += 1;
        }
        return non_zero;
    }
    return 0;
}

/// Asks the engine for one frame, then reads what landed.
///
/// Alternating buffers is deliberate: an engine that offers two is double-buffering, and
/// always asking for the same one would read a buffer the engine may consider in flight.
fn repaint(slot: *Slot) void {
    const view = slot.view orelse return;
    if (slot.n_buffers == 0) return;

    const index = slot.next % slot.n_buffers;
    slot.next +%= 1;
    const target = slot.buffers[index] orelse return;

    var error_out: ?*anyopaque = null;
    const accepted = wpe_view_render_buffer(view, target, null, 0, &error_out);
    counters.render_requests += 1;
    if (accepted == 0) {
        counters.render_refusals += 1;
        return;
    }
    sampleBuffer(target);
}

/// The repaint tick. Returning true removes the timeout, so this both drives and stops.
/// Starts the repaint loop from an idle handler rather than from `buffers_changed` itself.
///
/// Measured: a timeout added *during* a main-context dispatch fired exactly once and was
/// never re-armed, even though its callback returned "keep" — and adding a second,
/// unrelated source alongside it made the first one fire again. The repaint timer is
/// therefore installed from an idle callback, which runs when the context is not in the
/// middle of dispatching the very call that wanted the timer.
fn onStartRepaint(user_data: ?*anyopaque) callconv(.c) c_int {
    const slot: *Slot = @ptrCast(@alignCast(user_data.?));
    slot.timeout = g_timeout_add(repaint_interval_ms, onTick, slot);
    // One-shot: the timer it just installed is the loop.
    return 1;
}

fn onTick(user_data: ?*anyopaque) callconv(.c) c_int {
    const slot: *Slot = @ptrCast(@alignCast(user_data.?));
    counters.ticks += 1;
    repaint(slot);

    if (counters.frames_read_back < frames_before_stopping) return 0;

    slot.timeout = 0;
    slot.view = null;
    slot.n_buffers = 0;
    return 1;
}

/// The engine offers the buffers it can render into, and the view they belong to.
///
/// Nothing is drawn here, and that is the correction this increment exists to make. This
/// fires when the engine builds its buffer pool — measured, before the page has painted —
/// so a render request made in response asks for a frame of nothing and fills nothing.
/// The buffers are kept instead and drawn from the repaint tick, once the load has had
/// time to settle.
fn buffersChanged(view: ?*anyopaque, buffers: ?*const ?*anyopaque, n_buffers: c_uint) callconv(.c) void {
    counters.buffers_changed += 1;
    if (view == null or buffers == null or n_buffers == 0) return;

    for (&slots) |*slot| {
        if (slot.view != null) continue;

        slot.view = g_object_ref(view);
        const kept = if (n_buffers < slot_buffers) n_buffers else slot_buffers;
        slot.n_buffers = kept;
        var index: u32 = 0;
        while (index < kept) : (index += 1) {
            if (buffers.?.*) |buffer| slot.buffers[index] = g_object_ref(buffer);
        }

        _ = g_idle_add(onStartRepaint, slot);
        return;
    }

    // No free slot. Counted, so the limit is visible instead of a view that silently never
    // animates.
    counters.views_without_a_loop += 1;
}

/// The engine-side render handler.
///
/// Reached from this process only through a `wpe_view_render_buffer` call this framework
/// made itself, which is why it holds no logic: in a real deployment the view is remote and
/// this is where such a request arrives. Counting it is still worth keeping — a request the
/// engine never services shows up as repaint ticks that produce no frames.
fn renderBuffer(view: ?*anyopaque, buffer: ?*anyopaque, damage: ?*const anyopaque, count: c_uint, error_out: *?*anyopaque) callconv(.c) c_int {
    _ = view;
    _ = buffer;
    _ = damage;
    _ = count;
    _ = error_out;
    counters.render_buffer_calls += 1;
    return 1;
}

/// Hands the engine an EGL display.
///
/// WebKit calls `eglInitialize` on whatever this returns (`WPEDisplay.cpp` does it in
/// `wpe_display_get_egl_display` after the vfunc), so this must produce a display but must
/// not initialise it — initialising twice, or initialising here and having WebKit do it
/// again, leaves a context this framework cannot reason about.
///
/// Surfaceless is tried first because it needs no window and no device node, which is what
/// a framework that owns a window already does not want to be asked for twice. The GBM
/// fallback is for machines where surfaceless is absent but a render node exists. Both
/// were confirmed present by `eglinfo` before being relied on.
fn getEglDisplay(display: Gpointer, error_out: *?*anyopaque) callconv(.c) Gpointer {
    _ = display;
    _ = error_out;

    const surfaceless = egl_get_platform_display(egl_platform_surfaceless, egl_default_display, null);
    if (surfaceless != null) {
        counters.egl_displays_created += 1;
        return surfaceless;
    }

    const node = std.c.open(drm_render_node, .{ .ACCMODE = .RDONLY }, @as(c_int, 0));
    if (node >= 0) {
        defer _ = std.c.close(node);
        if (gbm_create_device(node)) |device| {
            const gbm_display = egl_get_platform_display(egl_platform_gbm, device, null);
            if (gbm_display != null) {
                counters.egl_displays_created += 1;
                return gbm_display;
            }
        }
    }

    counters.egl_failures += 1;
    return null;
}

/// Lepton's window can be mapped, so mapping is allowed through.
///
/// Returning false makes `wpe_view_map` a no-op, and every later measurement would be of
/// a view that never appeared.
fn canBeMapped(view: Gpointer) callconv(.c) c_int {
    _ = view;
    counters.can_be_mapped_asked += 1;
    return 1;
}

fn viewClassInit(class_ptr: Gpointer, class_data: Gpointer) callconv(.c) void {
    _ = class_data;
    const vtable: *WPEViewClass = @ptrCast(@alignCast(class_ptr.?));
    vtable.buffers_changed = buffersChanged;
    vtable.render_buffer = renderBuffer;
    vtable.can_be_mapped = canBeMapped;
}

fn registerView() GType {
    var info = GTypeInfo{
        .class_size = @sizeOf(WPEViewClass),
        .base_init = null,
        .base_finalize = null,
        .class_init = viewClassInit,
        .class_finalize = null,
        .class_data = null,
        .instance_size = view_instance_size,
        .n_preallocs = 0,
        .instance_init = null,
        .value_table = null,
    };
    return g_type_register_static(wpe_view_get_type(), "WPELeptonView", &info, 0);
}

/// Answers the engine's request for a view, by building one of this framework's own.
///
/// `wpe_view_new` looks like the obvious answer here and is not: it is the *public* entry
/// that asks the display to make a view, so calling it from `create_view` recurses until
/// the stack runs out. The base `WPEView` is derivable and not instantiable — measured, not
/// assumed, after the recursion made it obvious. Each platform supplies its own view, and
/// this is Lepton's.
fn createView(display: Gpointer) callconv(.c) Gpointer {
    // The display is not optional and not inferable: without it the view has none, and
    // the engine's next call — an input method context for the view — dereferences it.
    const view = g_object_new(lepton_view_type, view_display_property, display, null);
    if (view != null) counters.views_created += 1;
    return view;
}

fn classInit(class_ptr: Gpointer, class_data: Gpointer) callconv(.c) void {
    _ = class_data;
    const vtable: *WPEDisplayClass = @ptrCast(@alignCast(class_ptr.?));
    vtable.connect = connect;
    vtable.create_view = createView;
    vtable.get_egl_display = getEglDisplay;
}

var lepton_view_type: GType = 0;

fn registerDisplay() GType {
    var info = GTypeInfo{
        .class_size = @sizeOf(WPEDisplayClass),
        .base_init = null,
        .base_finalize = null,
        .class_init = classInit,
        .class_finalize = null,
        .class_data = null,
        .instance_size = instance_size,
        .n_preallocs = 0,
        .instance_init = null,
        .value_table = null,
    };
    return g_type_register_static(wpe_display_get_type(), "WPELeptonDisplay", &info, 0);
}

/// GIO's module entry point.
///
/// Both `g_io_module_load` and `g_io_module_unload` are mandatory, and a module missing
/// either is *skipped in silence*: GLib logs `undefined symbol: g_io_module_load` and
/// carries on, the engine falls through to `WPEDisplayWayland`, and the run looks
/// healthy while proving nothing. A first version of this file registered from a library
/// constructor instead of from here and failed exactly that way.
///
/// Registration belongs in this function rather than at load time for a second reason:
/// the extension point is created by `wpeEnsureExtensionPointsRegistered()`, and a
/// constructor runs during `dlopen` — before the point exists, so
/// `g_io_extension_point_implement` would have nothing to implement.
///
/// The module must also stay resident, which is the third way this went wrong. GIO frees
/// its module scope after scanning and closes what it opened; the registered type's
/// vtable then points into unmapped memory and the first virtual call faults at the
/// address of `connect` itself. `platform.zig` opens this library and keeps the handle,
/// which is why loading is not optional here.
fn g_io_module_load(module: Gpointer) callconv(.c) void {
    _ = module;
    display_type = registerDisplay();
    lepton_view_type = registerView();
    _ = g_io_extension_point_implement(extension_point_name, display_type, extension_name, 10);
}

/// Nothing to undo: a GType cannot be unregistered, and unregistering is not wanted —
/// the library stays resident, so the vtable stays valid.
fn g_io_module_unload(module: Gpointer) callconv(.c) void {
    _ = module;
}

comptime {
    @export(&g_io_module_load, .{ .name = "g_io_module_load" });
    @export(&g_io_module_unload, .{ .name = "g_io_module_unload" });
    @export(&counters, .{ .name = counters_mod.symbol_name });
}
