// The draw command list's vertex shader for Vulkan: `render/scene_glsl.zig`'s, with the
// frame's size in a push constant and Vulkan's clip space (y points down). Compiled to
// SPIR-V by `tools/vulkan-shaders.mjs` (glslang); the `.spv` beside it is what is embedded.
#version 450
layout(location = 0) in vec4 a_rect;
layout(location = 1) in vec4 a_fill;
layout(location = 2) in vec4 a_border_colour;
layout(location = 3) in vec4 a_params;
layout(push_constant) uniform Frame { vec2 size; } u_frame;
layout(location = 0) out vec2 v_local;
layout(location = 1) out vec2 v_uv;
layout(location = 2) flat out vec2 v_half;
layout(location = 3) flat out vec4 v_fill;
layout(location = 4) flat out vec4 v_border_colour;
layout(location = 5) flat out vec4 v_params;
void main() {
    // A shadow reaches `blur` past its edge; every shape gets a pixel for its edge's
    // antialiasing.
    bool glyph = a_params.w > 1.5;
    float pad = glyph ? 0.0 : a_params.z + 1.0;
    vec2 corner = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));
    vec2 origin = a_rect.xy - pad;
    vec2 extent = a_rect.zw + 2.0 * pad;
    vec2 pixel = origin + corner * extent;
    v_uv = mix(a_border_colour.xy, a_border_colour.zw, corner);
    v_half = a_rect.zw * 0.5;
    v_local = pixel - (a_rect.xy + v_half);
    v_fill = a_fill;
    v_border_colour = a_border_colour;
    v_params = a_params;
    gl_Position = vec4(pixel.x / u_frame.size.x * 2.0 - 1.0, pixel.y / u_frame.size.y * 2.0 - 1.0, 0.0, 1.0);
}
