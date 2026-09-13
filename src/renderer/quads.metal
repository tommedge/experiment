#include <metal_stdlib>
using namespace metal;
struct Quad { float2 origin; float2 size; float4 color; };
struct Vertex { float4 position [[position]]; float4 color; };
vertex Vertex quad_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
                          const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[] = {float2(0,0), float2(1,0), float2(0,1), float2(1,1)};
    Quad q = quads[instance_id];
    float2 p = (q.origin + corners[vertex_id] * q.size) / viewport;
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), q.color};
}
fragment float4 quad_fragment(Vertex in [[stage_in]]) { return in.color; }
