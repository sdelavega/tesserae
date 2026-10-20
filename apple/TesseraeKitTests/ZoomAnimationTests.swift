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
import Metal
import XCTest

@testable import TesseraeKit

/// The descend animation (spec §8 "Zoom and navigation"): its curves, and the
/// renderer's layer cross-fade.
final class ZoomAnimationTests: XCTestCase {
    private static func close(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-9) -> Bool {
        abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps && abs(a.width - b.width) <= eps
            && abs(a.height - b.height) <= eps
    }

    func test_zoom_transform_maps_the_clicked_rect_onto_the_viewport_at_the_end() {
        for viewport in [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 15, y: 40, width: 640, height: 200)] {
            let from = CGRect(x: 230, y: 120, width: 50, height: 37)
            let z = ZoomAnimation(from: from, viewport: viewport)
            XCTAssertFalse(z.isFinished, "precondition: an animatable zoom")
            XCTAssertEqual(z.transform(at: 0), .identity, "the old layout as it was at the start")
            let end = from.applying(z.transform(at: 0.25))
            XCTAssertTrue(Self.close(end, viewport), "clicked rect \(end) does not fill \(viewport)")
            XCTAssertTrue(Self.close(from.applying(z.transform(at: 5)), viewport), "held after the end")
            // In between, the clicked rect grows steadily towards the viewport.
            var last = from
            for i in 1..<25 {
                let r = from.applying(z.transform(at: Double(i) / 100))
                XCTAssertGreaterThan(r.width, last.width)
                XCTAssertGreaterThan(r.height, last.height)
                XCTAssertLessThan(r.width, viewport.width)
                last = r
            }
        }
    }

    func test_zoom_is_ease_out_and_finishes_at_250ms() {
        var z = ZoomAnimation(from: CGRect(x: 10, y: 10, width: 20, height: 20), viewport: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(z.duration, 0.25, "spec: ~250 ms by default")
        XCTAssertEqual(z.alpha(at: 0), 0)
        XCTAssertEqual(z.alpha(at: 0.25), 1)
        // Cubic ease-out: half the time is 1 - 0.5³ of the way.
        XCTAssertEqual(z.alpha(at: 0.125), 0.875, accuracy: 1e-6)
        var last: Float = 0
        for i in 1..<250 {
            let t = Double(i) / 1000
            let a = z.alpha(at: t)
            XCTAssertGreaterThan(a, last, "not increasing at \(t)")
            XCTAssertGreaterThan(Double(a), t / 0.25, "not ease-out (ahead of linear) at \(t)")
            // Decelerating: each millisecond moves less than the one before.
            if i > 1 {
                XCTAssertLessThan(a - last, last - z.alpha(at: Double(i - 2) / 1000) + 1e-6, "accelerating at \(t)")
            }
            last = a
        }
        // The transform follows the same curve: the clicked rect's width.
        let w0 = z.from.width, w1 = z.viewport.width
        let wMid = z.from.applying(z.transform(at: 0.125)).width
        let visibleMid = w0 * w1 / wMid  // the window's width at t: lerp(w1, w0, p)
        XCTAssertEqual((w1 - visibleMid) / (w1 - w0), 0.875, accuracy: 1e-9)

        z.advance(to: 0.2499)
        XCTAssertFalse(z.isFinished, "finished early")
        z.advance(to: 0.25)
        XCTAssertTrue(z.isFinished, "not finished at 250 ms")
        z.advance(to: 0.1)
        XCTAssertTrue(z.isFinished, "time ran backwards")
        var c = ZoomAnimation(from: z.from, viewport: z.viewport)
        c.cancel()
        XCTAssertTrue(c.isFinished)
        XCTAssertEqual(c.alpha(at: 0), 1, "a cancelled zoom shows the new layout")
        XCTAssertEqual(c.transform(at: 0), .identity)
    }

    // MARK: Degenerate sizes (ruling P3)

    @MainActor
    func test_resize_to_zero_mid_animation_emits_no_nan() throws {
        func finite(_ m: CGAffineTransform) -> Bool {
            [m.a, m.b, m.c, m.d, m.tx, m.ty].allSatisfy { $0.isFinite && Float($0).isFinite }
        }
        let tree = SyntheticTree(.dir([.dir([.file(500), .file(300)]), .file(200), .dir([.file(90), .file(10)])]))
        let big = CGRect(x: 0, y: 0, width: 400, height: 300)
        let oldTiles = squarify(tree, root: tree.rootIndex, in: big)
        let clicked = oldTiles[1].rect
        XCTAssertGreaterThan(oldTiles.count, 3, "precondition: a layout to zoom from")

        let device = MTLCreateSystemDefaultDevice()
        let renderer = device.flatMap { TreemapRenderer(device: $0) }
        let palette = Palette.colours(.depth, dark: false)
        let colourOf: (Tile) -> UInt16 = { UInt16(Palette.firstColourIndex + Int($0.depth) % 5) }
        var animatedFrames = 0

        for side in [0.0, 0.5, 1.0] as [CGFloat] {
            let small = CGRect(x: 0, y: 0, width: side, height: side)
            // The view resizes while a zoom runs: the player cancels cleanly.
            var player = ZoomPlayer()
            XCTAssertTrue(player.start(from: clicked, viewport: big, now: 100))
            let f = try XCTUnwrap(player.frame(now: 100.1), "precondition: running mid-way")
            XCTAssertTrue(finite(f.transform) && f.alpha.isFinite)
            player.resize(to: small)
            XCTAssertFalse(player.isRunning, "a resize to \(side) did not cancel")
            XCTAssertNil(player.frame(now: 100.15))
            // A zoom started at the degenerate size, or onto/from one.
            for (from, viewport) in [(clicked, small), (small, big), (CGRect(x: 1, y: 1, width: 1e-300, height: 1e-300), big)] {
                var z = ZoomAnimation(from: from, viewport: viewport)
                // Nothing to animate onto or from a 0×0 rect, or from one a
                // Float zoom cannot reach: finished at once, nothing started.
                let degenerate = side == 0 || from.width < 1e-100
                XCTAssertEqual(z.isFinished, degenerate, "\(from) → \(viewport) finished at the start")
                var started = ZoomPlayer()
                XCTAssertEqual(started.start(from: from, viewport: viewport, now: 0), !degenerate)
                for i in 0...30 {
                    let t = Double(i) / 100
                    XCTAssertTrue(finite(z.transform(at: t)), "\(from) → \(viewport) at \(t)")
                    XCTAssertTrue(z.alpha(at: t).isFinite)
                }
                XCTAssertTrue(finite(z.transform(at: .nan)) && z.alpha(at: .infinity).isFinite)
                z.advance(to: 0.3)
                XCTAssertTrue(z.isFinished, "did not complete")
                var p = ZoomPlayer()
                _ = p.start(from: from, viewport: viewport, now: 0)
                if let fr = p.frame(now: 0.1) {
                    XCTAssertTrue(finite(fr.transform) && fr.alpha.isFinite)
                }
            }

            // On the GPU: the old layout zoomed at mid-animation over a view
            // that is now 0×0, 0.5×0.5 or 1×1, with tiles laid out for it.
            guard let renderer else { continue }
            renderer.update(tiles: oldTiles, colourOf: colourOf, palette: palette)
            XCTAssertTrue(renderer.beginZoom())
            let newTiles = squarify(tree, root: 1, in: small)
            renderer.update(tiles: newTiles, colourOf: colourOf, palette: palette)
            let z = ZoomAnimation(from: clicked, viewport: big)
            for m in [z.transform(at: 0.1), CGAffineTransform(a: .infinity, b: 0, c: 0, d: .nan, tx: 1e300, ty: 0)] {
                let image = renderer.renderZoomOffscreen(size: small.size, scale: 2, oldTransform: m, alpha: .nan)
                XCTAssertGreaterThanOrEqual(image.width, 1)
                for u in renderer.lastEncodedUniforms {
                    let all = [u.viewSize.x, u.viewSize.y, u.scale, u.alpha, u.zoom.x, u.zoom.y, u.zoom.z, u.zoom.w]
                    XCTAssertTrue(all.allSatisfy(\.isFinite), "non-finite uniform \(u) at \(side)")
                    XCTAssertTrue(u.viewSize.x > 0 && u.viewSize.y > 0, "a zero view size reached the shader")
                }
                // A 0×0 view draws nothing; the others draw the old layer at least.
                XCTAssertEqual(renderer.lastEncodedUniforms.isEmpty, side == 0, "at \(side)")
                for r in renderer.instanceRects {
                    XCTAssertTrue(r.x.isFinite && r.y.isFinite && r.z.isFinite && r.w.isFinite, "instance rect \(r)")
                }
                animatedFrames += 1
            }
            renderer.endZoom()
            XCTAssertFalse(renderer.isZooming)
        }
        if renderer != nil { XCTAssertEqual(animatedFrames, 6) }
    }

    func test_static_zoom_destination_is_cached_and_invalidated_without_changing_pixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = try XCTUnwrap(TreemapRenderer(device: device))
        let size = CGSize(width: 100, height: 80)
        let old = [Tile(rect: CGRect(origin: .zero, size: size), node: 0, depth: 3)]
        var next = [Tile(rect: CGRect(x: 0, y: 0, width: 60, height: 50), node: 1, depth: 0)]
        var palette = Palette.colours(.depth, dark: false)
        let index: (Tile) -> UInt16 = { UInt16(2 + $0.depth) }
        renderer.update(tiles: old, colourOf: index, palette: palette)
        XCTAssertTrue(renderer.beginZoom())
        renderer.update(tiles: next, colourOf: index, palette: palette)
        let animation = ZoomAnimation(from: CGRect(x: 10, y: 10, width: 40, height: 30), viewport: CGRect(origin: .zero, size: size))
        func check(_ size: CGSize, _ scale: CGFloat, _ alpha: Float, _ time: Double) throws {
            let reference = try XCTUnwrap(TreemapRenderer(device: device))
            reference.clearColour = renderer.clearColour
            reference.update(tiles: old, colourOf: index, palette: palette)
            XCTAssertTrue(reference.beginZoom())
            reference.update(tiles: next, colourOf: index, palette: palette)
            let transform = animation.transform(at: time)
            let expected = reference.renderZoomOffscreen(size: size, scale: scale, oldTransform: transform, alpha: alpha)
            let actual = renderer.renderZoomOffscreen(size: size, scale: scale, oldTransform: transform, alpha: alpha)
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)
            let actualBytes = try XCTUnwrap(actual.dataProvider?.data) as Data
            let expectedBytes = try XCTUnwrap(expected.dataProvider?.data) as Data
            XCTAssertEqual(actualBytes, expectedBytes, "cached and fresh renders must be byte-identical")
        }
        try check(size, 1, 0.25, 0.02)
        XCTAssertEqual(renderer.destinationRenderCount, 1)
        try check(size, 1, 0.5, 0.1)
        try check(size, 1, 1, 0.2)
        XCTAssertEqual(renderer.destinationRenderCount, 1, "only the old geometry moves between frames")
        palette[2] = SIMD4(1, 0, 0, 1)
        renderer.update(tiles: next, colourOf: index, palette: palette)
        try check(size, 1, 1, 0.2)
        XCTAssertEqual(renderer.destinationRenderCount, 2, "palette invalidates cached pixels")
        renderer.clearColour = SIMD4(0, 1, 0, 1)
        try check(size, 1, 1, 0.2)
        XCTAssertEqual(renderer.destinationRenderCount, 3, "background invalidates uncovered pixels")
        next[0].rect.origin.x = 30
        renderer.update(tiles: next, colourOf: index, palette: palette)
        try check(size, 1, 1, 0.2)
        XCTAssertEqual(renderer.destinationRenderCount, 4)
        try check(size, 2, 0.5, 0.1)
        XCTAssertEqual(renderer.destinationRenderCount, 5, "backing pixel size invalidates")
        try check(CGSize(width: 200, height: 160), 1, 0.5, 0.1)
        XCTAssertEqual(renderer.destinationRenderCount, 6, "point size/scale invalidate even with identical texture dimensions")
        renderer.endZoom()
        renderer.update(tiles: old, colourOf: index, palette: palette)
        XCTAssertTrue(renderer.beginZoom())
        renderer.update(tiles: next, colourOf: index, palette: palette)
        try check(size, 1, 0.5, 0.1)
        XCTAssertEqual(renderer.destinationRenderCount, 7, "a new transition invalidates")
    }

    // MARK: The cross-fade

    private struct Px: Equatable { var r, g, b: Int }

    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> Px {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let o = y * image.bytesPerRow + x * 4  // BGRA, little-endian premultiplied-first
        return Px(r: Int(data[o + 2]), g: Int(data[o + 1]), b: Int(data[o]))
    }

    private static func q(_ c: SIMD4<Float>) -> Px {
        func b(_ v: Float) -> Int { Int((v * 255).rounded()) }
        return Px(r: b(c.x), g: b(c.y), b: b(c.z))
    }

    /// The fade is of whole layers: where a child paints over its parent in
    /// the new layout, the pixel is exactly mix(old, new, alpha), as where a
    /// single tile covers it; per-tile alpha would blend the parent in too.
    func test_zoom_cross_fade_is_uniform_where_tiles_overlap() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = try XCTUnwrap(TreemapRenderer(device: device))
        let palette = Palette.colours(.depth, dark: false)
        let colourOf: (Tile) -> UInt16 = { UInt16(Palette.firstColourIndex + Int($0.depth)) }
        func colour(_ depth: UInt8) -> Px { Self.q(palette[Palette.firstColourIndex + Int(depth)]) }
        let size = CGSize(width: 100, height: 80)
        let viewport = CGRect(origin: .zero, size: size)

        // Old: a root (depth 3) and the clicked directory (depth 4) at its top left.
        let clicked = CGRect(x: 0, y: 0, width: 50, height: 40)
        let old = [
            Tile(rect: viewport, node: 0, depth: 3),
            Tile(rect: clicked, node: 1, depth: 4),
        ]
        // New: a parent with a child over its bottom right quarter.
        let new = [
            Tile(rect: viewport, node: 1, depth: 0),
            Tile(rect: CGRect(x: 50, y: 40, width: 50, height: 40), node: 2, depth: 1),
        ]
        r.update(tiles: old, colourOf: colourOf, palette: palette)
        XCTAssertTrue(r.beginZoom())
        r.update(tiles: new, colourOf: colourOf, palette: palette)

        let z = ZoomAnimation(from: clicked, viewport: viewport)
        let t = 0.04
        let m = z.transform(at: t)
        XCTAssertNotEqual(m, .identity, "precondition: the old layout is transformed")
        // Probes away from every border: in the child (over the parent), and
        // in the parent alone; each is in the old root or old clicked tile.
        // (55, 45) is in the old clicked tile only because the old layout is
        // transformed (untransformed, it would be the old root).
        let probes = [(80, 70), (70, 15), (20, 65), (10, 10), (55, 45)]
        XCTAssertTrue(clicked.contains(CGPoint(x: 55.5, y: 45.5).applying(m.inverted())))
        XCTAssertFalse(clicked.contains(CGPoint(x: 55.5, y: 45.5)), "precondition: a probe that sees the transform")
        var overlapProbes = 0
        for alpha in [0.0, 0.25, 0.5, 0.8, 1.0] as [Float] {
            let image = r.renderZoomOffscreen(size: size, scale: 1, oldTransform: m, alpha: alpha)
            for (x, y) in probes {
                let centre = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let oldPoint = centre.applying(m.inverted())
                let oldTile = old.last { $0.rect.contains(oldPoint) }!
                let newTile = new.last { $0.rect.contains(centre) }!
                let o = colour(oldTile.depth), n = colour(newTile.depth)
                let a = Double(alpha)
                func mix(_ u: Int, _ v: Int) -> Double { Double(u) + (Double(v) - Double(u)) * a }
                let got = try Self.pixel(image, x, y)
                let want = (mix(o.r, n.r), mix(o.g, n.g), mix(o.b, n.b))
                let ok = abs(Double(got.r) - want.0) <= 1 && abs(Double(got.g) - want.1) <= 1
                    && abs(Double(got.b) - want.2) <= 1
                XCTAssertTrue(ok, "alpha \(alpha) at (\(x), \(y)): got \(got), want mix(\(o), \(n)) = \(want)")
                if newTile.depth == 1 && alpha > 0 && alpha < 1 {
                    // Precondition: per-tile alpha would be visibly different here.
                    let p = colour(0)
                    func perTile(_ u: Int, _ par: Int, _ v: Int) -> Double { Double(v) * a + (1 - a) * (Double(par) * a + (1 - a) * Double(u)) }
                    let wrong = [perTile(o.r, p.r, n.r) - want.0, perTile(o.g, p.g, n.g) - want.1, perTile(o.b, p.b, n.b) - want.2]
                    XCTAssertGreaterThan(wrong.map(abs).max()!, 3, "precondition: the probe tells layer from per-tile fades")
                    overlapProbes += 1
                }
            }
        }
        XCTAssertEqual(overlapProbes, 6, "precondition: overlap probes at each partial alpha")
        r.endZoom()
    }
}
