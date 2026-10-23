//! Windows' own headers for the window layer: the same translation the WebView2 path
//! reads (`src/c/c_windows.h`), so a window made here is the `HWND` that path hosts in.

pub const c = @import("c_windows");

/// UTF-16 from a literal, NUL-terminated.
pub const W = @import("std").unicode.utf8ToUtf16LeStringLiteral;
