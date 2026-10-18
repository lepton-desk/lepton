//! Root of `zig build gpu-test`: the tests that need a GL ES context, kept at `src/` so they
//! reach both the renderers (`render/`) and the window frame drawn with them (`window/`).
test {
    _ = @import("render/gpu/presenter.zig");
    _ = @import("render/gpu/gl_renderer.zig");
    _ = @import("window/linux/chrome_scene_test.zig");
}
