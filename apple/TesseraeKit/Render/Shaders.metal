// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.


// The treemap's shaders (spec §8 "Metal"): one instanced draw of a unit quad,
// one instance per tile. TreemapRenderer.swift holds the Swift side of every
// struct and constant here; MetalRendererTests checks they agree.

#include <metal_stdlib>
using namespace metal;

// One tile. Must match `TileInstance` in TreemapRenderer.swift field for field:
// 20 bytes of payload, padded to a 32-byte stride by float4's alignment (the
// Swift struct's MemoryLayout stride is also 32).
struct TileInstance {
    float4 rect;      // x, y, w, h in points, origin top-left, y down
    ushort colorIdx;  // index into the palette buffer
    uchar depth;
    uchar flags;      // selected | staged | permDenied | aggregated
};
static_assert(sizeof(TileInstance) == 32, "TileInstance stride must match Swift");

// Must match `TreemapUniforms` in TreemapRenderer.swift.
struct Uniforms {
    float2 viewSize;  // points
    float scale;      // device pixels per point (the drawable's contentsScale)
    float alpha;      // multiplies each tile's alpha (1 for the zoom's opaque layers)
    float4 zoom;      // sx, sy, tx, ty: rect -> (xy * s + t, wh * s), the zoom's old-layout transform
};

// The border rule: the inner border is the fill's sRGB-encoded RGB scaled by
// this factor (alpha unchanged), one device pixel wide. Must match
// `TreemapRenderer.borderShade` / `borderWidthPixels`.
constant float kBorderShade = 0.7;
constant float kBorderWidthPixels = 1.0;

struct TileVertexOut {
    float4 position [[position]];
    float2 localPixels;              // offset from the rect's top-left, device pixels
    float2 sizePixels [[flat]];      // the rect's size, device pixels
    ushort colorIdx [[flat]];
    uchar flags [[flat]];
};

// Four vertices per instance as a triangle strip: (0,0) (1,0) (0,1) (1,1).
vertex TileVertexOut tile_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device TileInstance *tiles [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
    const TileInstance t = tiles[iid];
    // The transform is applied to the rect, so the border stays one device
    // pixel wide however far the old layout is zoomed.
    const float4 rect = float4(t.rect.xy * u.zoom.xy + u.zoom.zw, t.rect.zw * u.zoom.xy);
    const float2 corner = float2(float(vid & 1), float(vid >> 1));
    const float2 p = rect.xy + corner * rect.zw;
    TileVertexOut out;
    out.position = float4(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0, 0.0, 1.0);
    out.localPixels = corner * rect.zw * u.scale;
    out.sizePixels = rect.zw * u.scale;
    out.colorIdx = t.colorIdx;
    out.flags = t.flags;
    return out;
}

// Palette colours are sRGB-encoded and the target is a non-sRGB (unorm)
// format, so they are written through unconverted and the stored byte is the
// palette's hex value.
fragment float4 tile_fragment(TileVertexOut in [[stage_in]],
                              constant float4 *palette [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]]) {
    const float4 fill = palette[in.colorIdx];
    const float2 edge = min(in.localPixels, in.sizePixels - in.localPixels);
    const bool border = min(edge.x, edge.y) < kBorderWidthPixels;
    float3 rgb = border ? fill.rgb * kBorderShade : fill.rgb;
    // Bit 1 is Tile.Flag.staged. Coordinates and spacing are device pixels.
    if ((in.flags & 2) != 0) {
        const uint2 pixel = uint2(in.position.xy);
        const bool hatch = ((pixel.x + pixel.y) % 8) == 0;
        if (border || hatch) {
            const float ink = dot(fill.rgb, float3(0.2126, 0.7152, 0.0722)) > 0.5 ? 0.0 : 1.0;
            rgb = float3(ink);
        }
    }
    return float4(rgb, fill.a * u.alpha);
}

// The zoom's cross-fade (spec §8): the old and the new layout are each drawn
// opaque into a texture of the target's size, then this pass writes
// mix(old, new, alpha) per pixel. Fading whole layers, not tiles, keeps the
// fade uniform: a pixel where a child paints over its parent fades exactly
// like one covered by a single tile.
struct CompositeOut {
    float4 position [[position]];
};

// One triangle covering the target: (-1,-1) (3,-1) (-1,3).
vertex CompositeOut composite_vertex(uint vid [[vertex_id]]) {
    const float2 p = float2(float((vid << 1) & 2), float(vid & 2)) * 2.0 - 1.0;
    CompositeOut out;
    out.position = float4(p, 0.0, 1.0);
    return out;
}

fragment float4 composite_fragment(CompositeOut in [[stage_in]],
                                   texture2d<float, access::read> oldLayer [[texture(0)]],
                                   texture2d<float, access::read> newLayer [[texture(1)]],
                                   constant float &alpha [[buffer(0)]]) {
    const uint2 px = uint2(in.position.xy);
    return mix(oldLayer.read(px), newLayer.read(px), alpha);
}

// Test hook for MetalRendererTests: echoes how this file sees each instance
// (sizeof, then rect, colorIdx, depth, flags as 32-bit words) so the test can
// compare it with what Swift wrote. Never used for rendering.
kernel void tile_instance_probe(const device TileInstance *in [[buffer(0)]],
                                device uint *out [[buffer(1)]],
                                uint i [[thread_position_in_grid]]) {
    const TileInstance t = in[i];
    device uint *o = out + i * 8;
    o[0] = uint(sizeof(TileInstance));
    o[1] = as_type<uint>(t.rect.x);
    o[2] = as_type<uint>(t.rect.y);
    o[3] = as_type<uint>(t.rect.z);
    o[4] = as_type<uint>(t.rect.w);
    o[5] = uint(t.colorIdx);
    o[6] = uint(t.depth);
    o[7] = uint(t.flags);
}
