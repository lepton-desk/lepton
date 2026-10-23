//! The Windows half of the core as a module, until `root.zig` builds there (it reaches the
//! Linux display layers). Rooted in `src/` so every file the window layer names is inside
//! the module: Zig resolves a file's imports whether or not this system analyses them.

/// The window layer; on Windows its backend is `window/windows/native_window.zig`.
pub const window = @import("window/window.zig");
