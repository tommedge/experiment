#include <metal_stdlib>
using namespace metal;
// Clockwise radii: TL, TR, BR, BL. Border widths: left, top, right, bottom.
struct Quad {
    float2 origin; float2 size; float4 color; float2 uv_origin; float2 uv_size;
    uint mode; float scale; uint p0; uint p1;
    float2 shape_origin; float2 shape_size; float4 border_color; float4 border_widths; float4 corner_radii;
};
struct Vertex {
    float4 position [[position]]; float4 color; float2 uv; uint mode [[flat]];
    float2 shape_point; float2 shape_size [[flat]]; float4 border_color [[flat]];
    float4 border_widths [[flat]]; float4 corner_radii [[flat]];
};
vertex Vertex quad_vertex(uint vertex_id [[vertex_id]], uint instance_id [[instance_id]],
                          const device Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[] = {float2(0,0), float2(1,0), float2(0,1), float2(1,1)};
    Quad q = quads[instance_id];
    float2 point = q.origin + corners[vertex_id] * q.size;
    float2 p = point / viewport;
    return {float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), q.color, q.uv_origin + corners[vertex_id] * q.uv_size, q.mode,
        (point - q.shape_origin) * q.scale, q.shape_size, q.border_color, q.border_widths, q.corner_radii};
}

// GPUI-style signed distances: outer is negative inside the rounded box;
// inner is negative in the border and positive in the content region.
float4 rounded_box(Vertex in) {
    float2 center_to_point = in.shape_point - in.shape_size * 0.5;
    float radius = center_to_point.x < 0
        ? (center_to_point.y < 0 ? in.corner_radii.x : in.corner_radii.w)
        : (center_to_point.y < 0 ? in.corner_radii.y : in.corner_radii.z);
    float2 border = float2(center_to_point.x < 0 ? in.border_widths.x : in.border_widths.z,
                          center_to_point.y < 0 ? in.border_widths.y : in.border_widths.w);
    float2 corner_to_point = abs(center_to_point) - in.shape_size * 0.5;
    float2 circle_point = corner_to_point + radius;
    float outer = length(max(circle_point, 0.0)) + min(max(circle_point.x, circle_point.y), 0.0) - radius;
    float outer_coverage = saturate(0.5 - outer);
    float border_coverage = 0;
    if (border.x > 0 || border.y > 0) {
        // Suppress antialiasing along absent sides instead of inventing hairlines.
        float2 reduced = float2(border.x == 0 ? -0.5 : border.x, border.y == 0 ? -0.5 : border.y);
        float2 straight_inner = corner_to_point + reduced;
        float inner;
        if (circle_point.x <= 0 || circle_point.y <= 0) {
            inner = -max(straight_inner.x, straight_inner.y);
        } else if (straight_inner.x > 0 || straight_inner.y > 0) {
            inner = -1;
        } else if (reduced.x == reduced.y) {
            inner = -(outer + reduced.x);
        } else {
            // Unequal widths produce a quarter ellipse. The normalized-circle
            // distance uses the average radius to approximate pixel distance.
            // Fast paths above handle collapsed interiors; epsilon protects the join.
            float2 radii = max(float2(1e-5), radius - reduced);
            inner = (length(circle_point / radii) - 1) * -0.5 * (radii.x + radii.y);
        }
        border_coverage = saturate(0.5 - inner);
    }
    // Compose and return premultiplied RGBA. Keeping coverage in RGB as well as
    // alpha avoids dividing by tiny/zero alpha along transparent rounded edges.
    float border_alpha = in.border_color.a * border_coverage;
    float alpha = border_alpha + in.color.a * (1 - border_alpha);
    float3 premultiplied = in.border_color.rgb * border_alpha + in.color.rgb * in.color.a * (1 - border_alpha);
    return float4(premultiplied * outer_coverage, alpha * outer_coverage);
}
fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> atlas [[texture(0)]], sampler filtering [[sampler(0)]]) {
    if (in.mode == 0) return float4(in.color.rgb * in.color.a, in.color.a);
    if (in.mode == 3) return rounded_box(in);
    float4 sample = atlas.sample(filtering, in.uv);
    if (in.mode == 1) {
        float alpha = in.color.a * sample.r;
        return float4(in.color.rgb * alpha, alpha);
    }
    // CoreGraphics color glyphs contain premultiplied sRGB. Interpolate in that
    // representation, unpremultiply, then decode for the linear blend pipeline.
    float3 rgb = sample.a > 0 ? sample.rgb / sample.a : float3(0);
    rgb = select(pow((rgb + 0.055) / 1.055, float3(2.4)), rgb / 12.92, rgb <= 0.04045);
    float alpha = sample.a * in.color.a;
    return float4(rgb * alpha, alpha);
}
