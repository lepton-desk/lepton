//! The draw command list's shaders in GLSL, shared by the GLES 3 backend (`gles3.zig`,
//! `#version 300 es`) and the OpenGL 3.3 one (`gpu/gl33.zig`, `#version 330 core`): one body,
//! the version line (and ES's precision) put in front by each.

pub const vertex_body =
    \\layout(location = 0) in vec4 a_rect;
    \\layout(location = 1) in vec4 a_fill;
    \\layout(location = 2) in vec4 a_border_colour;
    \\layout(location = 3) in vec4 a_params;
    \\uniform vec2 u_size;
    \\out vec2 v_local;
    \\out vec2 v_uv;
    \\flat out vec2 v_half;
    \\flat out vec4 v_fill;
    \\flat out vec4 v_border_colour;
    \\flat out vec4 v_params;
    \\void main() {
    \\    // A shadow reaches `blur` past its edge; every shape gets a pixel for its edge's
    \\    // antialiasing.
    \\    bool glyph = a_params.w > 1.5;
    \\    float pad = glyph ? 0.0 : a_params.z + 1.0;
    \\    vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
    \\    vec2 origin = a_rect.xy - pad;
    \\    vec2 extent = a_rect.zw + 2.0 * pad;
    \\    vec2 pixel = origin + corner * extent;
    \\    v_uv = mix(a_border_colour.xy, a_border_colour.zw, corner);
    \\    v_half = a_rect.zw * 0.5;
    \\    v_local = pixel - (a_rect.xy + v_half);
    \\    v_fill = a_fill;
    \\    v_border_colour = a_border_colour;
    \\    v_params = a_params;
    \\    gl_Position = vec4(pixel.x / u_size.x * 2.0 - 1.0, 1.0 - pixel.y / u_size.y * 2.0, 0.0, 1.0);
    \\}
;

pub const fragment_body =
    \\in vec2 v_local;
    \\in vec2 v_uv;
    \\flat in vec2 v_half;
    \\flat in vec4 v_fill;
    \\flat in vec4 v_border_colour;
    \\flat in vec4 v_params;
    \\uniform sampler2D u_atlas;
    \\out vec4 o_colour;
    \\float roundedBox(vec2 p, vec2 half_size, float radius) {
    \\    vec2 q = abs(p) - half_size + radius;
    \\    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
    \\}
    \\vec4 premultiplied(vec4 c) { return vec4(c.rgb * c.a, c.a); }
    \\void main() {
    \\    if (v_params.w > 1.5) {
    \\        o_colour = premultiplied(v_fill) * texture(u_atlas, v_uv).r;
    \\        return;
    \\    }
    \\    float radius = v_params.x;
    \\    float border = v_params.y;
    \\    float blur = v_params.z;
    \\    float d = roundedBox(v_local, v_half, radius);
    \\    if (v_params.w > 0.5) {
    \\        // Shadow: opaque `blur` inside the edge, gone `blur` outside it.
    \\        float a = 1.0 - smoothstep(-blur, blur, d);
    \\        o_colour = premultiplied(v_fill) * a;
    \\        return;
    \\    }
    \\    float coverage = clamp(0.5 - d, 0.0, 1.0);
    \\    vec4 colour = premultiplied(v_fill);
    \\    if (border > 0.0) {
    \\        float in_band = clamp(d + border + 0.5, 0.0, 1.0);
    \\        colour = mix(colour, premultiplied(v_border_colour), in_band);
    \\    }
    \\    o_colour = colour * coverage;
    \\}
;
