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

import CoreGraphics
import Foundation

/// The CoreGraphics fallback treemap renderer (spec §11 "Rendering"): used
/// when there is no Metal device, with the zoom animation disabled, and as the
/// deterministic reference for snapshot tests (spec §12).
///
/// It draws the same pixels as `TreemapRenderer`'s shader:
/// * **Fill** is the palette value, sRGB-encoded, written unconverted into an
///   8-bit sRGB image (each byte is the palette's hex value).
/// * **Border** is one *device* pixel wide, inside the rect, coloured the
///   fill's RGB times `TreemapRenderer.borderShade`, rounded as the GPU's unorm store does (see `quantised`).
/// * **Order** is array order (painter's order), under `clearColour`.
///
/// **Rasterisation rule.** Like the GPU, a device pixel belongs to a tile when
/// its centre lies inside the tile's rect (in points times `scale`), and is a
/// border pixel when its centre is less than one device pixel from an edge.
/// Rects are snapped to whole pixels by that rule and drawn with antialiasing
/// off, so output is byte-identical across machines. (The GPU rasterises
/// in `Float`; the two can only disagree for rect edges within rounding error
/// of a pixel centre.)
///
/// Tiles with a non-finite rect are skipped, and a size that rounds to zero
/// produces a 1×1 image of the clear colour; huge rects are clamped, so no
/// geometry can trap or emit NaN. What does trap (preconditions): a colour
/// index outside `colours`, and failure to allocate the bitmap (sizes are
/// capped at 32,768 px per side).
public struct CGTreemapRenderer {
    /// The colour under the tiles (sRGB-encoded, like the palette).
    public var clearColour: SIMD4<Float>

    public init(clearColour: SIMD4<Float> = Palette.surface(dark: false)) {
        self.clearColour = clearColour
    }

    /// Renders `tiles` into a `size` × `scale` image (8-bit BGRA, premultiplied
    /// first, little-endian, sRGB: the format `TreemapRenderer.renderOffscreen`
    /// returns). `colourOf` gives each tile's index into `colours`
    /// (`Palette.colours`).
    public func render(
        tiles: [Tile], colours: [SIMD4<Float>], colourOf: (Tile) -> UInt16, indices: [UInt16]? = nil, size: CGSize, scale: CGFloat
    ) -> CGImage {
        precondition(indices == nil || indices?.count == tiles.count, "one colour index per tile")
        let width = Self.pixels(size.width * scale)
        let height = Self.pixels(size.height * scale)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: info.rawValue)
        else { preconditionFailure("cannot allocate a \(width)×\(height) bitmap") }
        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)

        func set(_ c: SIMD4<Float>) {
            ctx.setFillColor(CGColor(
                colorSpace: space,
                components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), CGFloat(c.w)])!)
        }
        // CoreGraphics' origin is bottom-left; ours is top-left.
        func fill(_ x: Range<Int>, _ y: Range<Int>) {
            ctx.fill(CGRect(x: x.lowerBound, y: height - y.upperBound, width: x.count, height: y.count))
        }
        set(Self.quantised(clearColour, 1))
        fill(0..<width, 0..<height)

        let s = Double(scale)
        for (position, tile) in tiles.enumerated() {
            let r = tile.rect
            guard r.origin.x.isFinite, r.origin.y.isFinite, r.size.width.isFinite, r.size.height.isFinite,
                s.isFinite
            else { continue }
            let idx = Int(indices?[position] ?? colourOf(tile))
            precondition(idx < colours.count, "colour index \(idx) outside a palette of \(colours.count)")
            let (x0, x1) = (Double(r.minX) * s, Double(r.maxX) * s)
            let (y0, y1) = (Double(r.minY) * s, Double(r.maxY) * s)
            guard x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite else { continue }
            // Pixels whose centres are inside the rect, and those of them at
            // least one pixel from every edge.
            let outerX = Self.span(Self.firstPixel(x0 - 0.5), Self.firstPixel(x1 - 0.5), width)
            let outerY = Self.span(Self.firstPixel(y0 - 0.5), Self.firstPixel(y1 - 0.5), height)
            guard !outerX.isEmpty, !outerY.isEmpty else { continue }
            let innerX = Self.span(Self.firstPixel(x0 + 0.5), Self.lastPixel(x1 - 1.5) + 1, width)
            let innerY = Self.span(Self.firstPixel(y0 + 0.5), Self.lastPixel(y1 - 1.5) + 1, height)
            let c = colours[idx]
            set(Self.quantised(c, TreemapRenderer.borderShade))
            fill(outerX, outerY)
            if !innerX.isEmpty && !innerY.isEmpty {
                set(Self.quantised(c, 1))
                fill(innerX.clamped(to: outerX), innerY.clamped(to: outerY))
            }
        }
        guard let image = ctx.makeImage() else { preconditionFailure("cannot read back the bitmap") }
        return image
    }

    /// A length in device pixels as a whole count, at least 1.
    private static func pixels(_ v: CGFloat) -> Int {
        guard v.isFinite else { return 1 }
        return Int(min(max(v.rounded(), 1), 32_768))
    }

    /// The smallest whole pixel index at or after `v`, kept within `Int` range
    /// (callers clamp it to the bitmap).
    private static func firstPixel(_ v: Double) -> Int {
        Int(min(max(v.rounded(.up), -1e9), 1e9))
    }

    /// The largest whole pixel index at or before `v`, kept within `Int` range.
    private static func lastPixel(_ v: Double) -> Int {
        Int(min(max(v.rounded(.down), -1e9), 1e9))
    }

    /// `lo..<hi` clamped to `0..<limit` (empty if it misses).
    private static func span(_ lo: Int, _ hi: Int, _ limit: Int) -> Range<Int> {
        let a = min(max(lo, 0), limit)
        let b = min(max(hi, a), limit)
        return a..<b
    }

    /// `c`'s RGB times `shade`, rounded to the 8-bit value the GPU would
    /// store, as an exact k/255 colour so CoreGraphics adds no rounding of its
    /// own. Alpha is `c.w` (the palette is opaque).
    private static func quantised(_ c: SIMD4<Float>, _ shade: Float) -> SIMD4<Float> {
        // The shader's `Float` product, then the exact (not Float-rounded)
        // scale to 0...255, rounded ties-to-even: Metal's float-to-unorm8.
        func q(_ v: Float) -> Float {
            let stored = Double(v * shade) * 255
            return Float(min(max(stored.rounded(.toNearestOrEven), 0), 255)) / 255
        }
        return SIMD4(q(c.x), q(c.y), q(c.z), min(max(c.w, 0), 1))
    }
}
