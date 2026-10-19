//! Windows and WebView2, translated once for every file in this directory.
//!
//! `WebView2.h` is Microsoft's, vendored with its licence in `zig/webview2/`. Its COM
//! interfaces come through `@cImport` as structs with an `lpVtbl`, so every vtable this
//! backend fills or calls is typed by the header rather than transcribed by hand — the
//! lesson the Wayland listeners taught (`CLAUDE.md`: a hand-written table shifted every
//! argument by one).

pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("shlwapi.h");
    @cInclude("shellapi.h");
    @cInclude("psapi.h");
    @cInclude("dwmapi.h");
    @cInclude("WebView2.h");
});

const std = @import("std");

/// IUnknown for a handler that lives as long as its owner: no counting, no freeing.
/// WebView2 calls `AddRef`/`Release` on handlers it is given; a handler embedded in a
/// struct that outlives the controller has nothing to free.
pub fn Unknown(comptime Interface: type, comptime iid: *const c.IID) type {
    return struct {
        pub fn queryInterface(self: [*c]Interface, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.winapi) c.HRESULT {
            const asked: *const c.IID = riid;
            const wanted = std.mem.asBytes(asked);
            if (std.mem.eql(u8, wanted, std.mem.asBytes(iid)) or
                std.mem.eql(u8, wanted, std.mem.asBytes(&c.IID_IUnknown)))
            {
                out.* = @ptrCast(self);
                return c.S_OK;
            }
            out.* = null;
            return c.E_NOINTERFACE;
        }
        pub fn addRef(_: [*c]Interface) callconv(.winapi) c.ULONG {
            return 1;
        }
        pub fn release(_: [*c]Interface) callconv(.winapi) c.ULONG {
            return 1;
        }
    };
}

/// A handler object WebView2 can call: the interface first (its `lpVtbl`), so a pointer to
/// the handler is a pointer to the interface, and `@fieldParentPtr` finds the owner.
pub fn Handler(comptime Interface: type, comptime Vtbl: type, comptime iid: *const c.IID, comptime invoke: anytype) type {
    const unknown = Unknown(Interface, iid);
    return struct {
        pub const vtbl: Vtbl = .{
            .QueryInterface = unknown.queryInterface,
            .AddRef = unknown.addRef,
            .Release = unknown.release,
            .Invoke = invoke,
        };
        pub fn make() Interface {
            return .{ .lpVtbl = @constCast(&vtbl) };
        }
    };
}

/// UTF-16 from a literal, NUL-terminated.
pub const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// A `CoTaskMemAlloc`ed wide string as UTF-8 into `out`, freed. "" when it does not fit.
pub fn takeString(wide: c.LPWSTR, out: []u8) []const u8 {
    if (wide == null) return "";
    defer c.CoTaskMemFree(wide);
    const units = std.mem.sliceTo(wide, 0);
    // Three bytes per unit is the most UTF-8 a UTF-16 unit becomes (a surrogate pair is
    // four bytes for two units); the conversion does not check the room itself.
    if (units.len * 3 > out.len) return "";
    const len = std.unicode.utf16LeToUtf8(out, units) catch return "";
    return out[0..len];
}

/// Whether an HRESULT is a success code.
pub fn ok(hr: c.HRESULT) bool {
    return hr >= 0;
}
