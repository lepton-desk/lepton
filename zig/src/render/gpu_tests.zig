//! Root of `zig build gpu-test`'s presenter tests, one directory up from `gpu/` so the
//! presenter can reach the draw command list's renderer (`gles3.zig`) beside it.
test {
    _ = @import("gpu/presenter.zig");
    _ = @import("gpu/gl_renderer.zig");
}
