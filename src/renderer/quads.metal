#include <metal_stdlib>
using namespace metal;
struct Quad { float2 origin; float2 size; float4 color; float2 uv_origin; float2 uv_size; uint mode; uint p0; uint p1; uint p2; };
struct Vertex { float4 position [[position]]; float4 color; float2 uv; uint mode [[flat]]; };
vertex Vertex quad_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
                          const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[] = {float2(0,0), float2(1,0), float2(0,1), float2(1,1)};
    Quad q = quads[instance_id];
    float2 p = (q.origin + corners[vertex_id] * q.size) / viewport;
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), q.color, q.uv_origin + corners[vertex_id] * q.uv_size, q.mode};
}
fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler filtering [[sampler(0)]]) {
    if (in.mode == 0) return in.color;
    float4 sample = atlas.sample(filtering, in.uv);
    if (in.mode == 1) return float4(in.color.rgb, in.color.a * sample.r);
    // CoreGraphics color glyphs contain premultiplied sRGB. Interpolate in that
    // representation, unpremultiply, then decode for the linear blend pipeline.
    float3 rgb = sample.a > 0 ? sample.rgb / sample.a : float3(0);
    rgb = select(pow((rgb + 0.055) / 1.055, float3(2.4)), rgb / 12.92, rgb <= 0.04045);
    return float4(rgb, sample.a * in.color.a);
}
