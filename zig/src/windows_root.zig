//! The Windows half of the core as a module, until `root.zig` builds there (it reaches the
//! Linux display layers). Rooted in `src/` so every file the window layer names is inside
//! the module: Zig resolves a file's imports whether or not this system analyses them.

/// The window layer; on Windows its backend is `window/windows/native_window.zig`.
pub const window = @import("window/window.zig");
/// The draw command list, its glyph atlas, and the Direct3D 11 backend that draws them.
pub const scene = @import("render/scene.zig");
pub const atlas = @import("render/atlas.zig");
pub const d3d11 = @import("render/gpu/d3d11.zig");
