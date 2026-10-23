// The draw command list (`render/scene.zig`) on Direct3D 11: the GLES 3 shaders
// (`render/gles3.zig`) in HLSL, shader model 4.0 so feature level 10_0 runs them. Every
// shape is one instance of a four-vertex strip; the vertex shader places the quad (grown
// by a shadow's blur), the pixel shader turns the signed distance to the rounded rectangle
// into coverage, border and shadow. Output is premultiplied (blend ONE, INV_SRC_ALPHA).
//
// Compiled to DXBC by `tools/d3d11-shaders.mjs` (fxc); the .dxbc files beside this one are
// its output, checked against this source by CI. Edit here, then run the tool.

cbuffer Frame : register(b0) {
    float2 u_size;
    float2 u_unused;
};

Texture2D<float> u_atlas : register(t0);
SamplerState u_sampler : register(s0);

struct Shape {
    float4 rect : RECT;
    float4 fill : FILL;
    float4 border_colour : BORDER;
    float4 params : PARAMS;
    uint vertex : SV_VertexID;
};

struct Pixel {
    float4 position : SV_Position;
    float2 local : LOCAL;
    float2 uv : UV;
    nointerpolation float2 half_size : HALF;
    nointerpolation float4 fill : FILL;
    nointerpolation float4 border_colour : BORDER;
    nointerpolation float4 params : PARAMS;
};

Pixel vs_main(Shape shape) {
    Pixel output;
    // A shadow reaches `blur` past its edge; every shape gets a pixel for its edge's
    // antialiasing.
    bool glyph = shape.params.w > 1.5;
    float pad = glyph ? 0.0 : shape.params.z + 1.0;
    float2 corner = float2(float(shape.vertex & 1), float(shape.vertex >> 1));
    float2 origin = shape.rect.xy - pad;
    float2 extent = shape.rect.zw + 2.0 * pad;
    float2 pixel = origin + corner * extent;
    output.uv = lerp(shape.border_colour.xy, shape.border_colour.zw, corner);
    output.half_size = shape.rect.zw * 0.5;
    output.local = pixel - (shape.rect.xy + output.half_size);
    output.fill = shape.fill;
    output.border_colour = shape.border_colour;
    output.params = shape.params;
    output.position = float4(pixel.x / u_size.x * 2.0 - 1.0, 1.0 - pixel.y / u_size.y * 2.0, 0.0, 1.0);
    return output;
}

float roundedBox(float2 p, float2 half_size, float radius) {
    float2 q = abs(p) - half_size + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float4 premultiplied(float4 c) { return float4(c.rgb * c.a, c.a); }

float4 ps_main(Pixel input) : SV_Target {
    if (input.params.w > 1.5) {
        return premultiplied(input.fill) * u_atlas.Sample(u_sampler, input.uv);
    }
    float radius = input.params.x;
    float border = input.params.y;
    float blur = input.params.z;
    float d = roundedBox(input.local, input.half_size, radius);
    if (input.params.w > 0.5) {
        // Shadow: opaque `blur` inside the edge, gone `blur` outside it.
        float a = 1.0 - smoothstep(-blur, blur, d);
        return premultiplied(input.fill) * a;
    }
    float coverage = saturate(0.5 - d);
    float4 colour = premultiplied(input.fill);
    if (border > 0.0) {
        float in_band = saturate(d + border + 0.5);
        colour = lerp(colour, premultiplied(input.border_colour), in_band);
    }
    return colour * coverage;
}
