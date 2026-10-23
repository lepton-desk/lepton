// The draw command list's fragment shader for Vulkan: `render/scene_glsl.zig`'s, with the
// atlas at set 0, binding 0. Compiled to SPIR-V by `tools/vulkan-shaders.mjs` (glslang).
#version 450
layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_uv;
layout(location = 2) flat in vec2 v_half;
layout(location = 3) flat in vec4 v_fill;
layout(location = 4) flat in vec4 v_border_colour;
layout(location = 5) flat in vec4 v_params;
layout(set = 0, binding = 0) uniform sampler2D u_atlas;
layout(location = 0) out vec4 o_colour;
float roundedBox(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - half_size + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}
vec4 premultiplied(vec4 c) { return vec4(c.rgb * c.a, c.a); }
void main() {
    if (v_params.w > 1.5) {
        o_colour = premultiplied(v_fill) * texture(u_atlas, v_uv).r;
        return;
    }
    float radius = v_params.x;
    float border = v_params.y;
    float blur = v_params.z;
    float d = roundedBox(v_local, v_half, radius);
    if (v_params.w > 0.5) {
        // Shadow: opaque `blur` inside the edge, gone `blur` outside it.
        float a = 1.0 - smoothstep(-blur, blur, d);
        o_colour = premultiplied(v_fill) * a;
        return;
    }
    float coverage = clamp(0.5 - d, 0.0, 1.0);
    vec4 colour = premultiplied(v_fill);
    if (border > 0.0) {
        float in_band = clamp(d + border + 0.5, 0.0, 1.0);
        colour = mix(colour, premultiplied(v_border_colour), in_band);
    }
    o_colour = colour * coverage;
}
