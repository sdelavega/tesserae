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

import AppKit
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

@testable import TesseraeKit

/// Deterministic reference images of the CoreGraphics fallback (spec §12:
/// "snapshot-test the treemap through the CoreGraphics fallback"), and a
/// cross-check against the Metal renderer.
///
/// References are PNGs in `SnapshotTests/` beside this file, located through
/// `#filePath` (they are not bundle resources, so the test bundle needs no
/// copy phase). Record or re-record with `TESSERAE_RECORD_SNAPSHOTS=1`.
/// Comparison is exact on the decoded 8-bit sRGB RGBA bytes; on a mismatch the
/// actual image and a diff image are written to a temp directory and their
/// paths printed.
final class RenderSnapshotTests: XCTestCase {
    // MARK: Pixel access

    /// Canonical bytes of `image`: 8-bit sRGB RGBA, row-major, top row first.
    /// Both renderers' output and the decoded PNGs go through this, so any
    /// storage format compares equal if the pixels do.
    private struct Raster: Equatable {
        var width: Int, height: Int
        var bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.setBlendMode(.copy)
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            precondition(ok, "cannot read pixels back")
        }

        func rgba(_ x: Int, _ y: Int) -> [Int] {
            let o = (y * width + x) * 4
            return (0..<4).map { Int(bytes[o + $0]) }
        }
    }

    // MARK: Reference store

    private static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SnapshotTests")
    }

    private static var recording: Bool { ProcessInfo.processInfo.environment["TESSERAE_RECORD_SNAPSHOTS"] == "1" }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func readPNG(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil), "cannot decode \(url.path)")
    }

    private func assertMatchesReference(
        _ image: CGImage, named name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = Self.directory.appendingPathComponent("\(name).png")
        let actual = Raster(image)
        if Self.recording {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try writePNG(image, to: url)
            XCTAssertEqual(Raster(try readPNG(url)), actual, "\(name): PNG round trip is lossless", file: file, line: line)
            print("recorded \(url.path)")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("no reference \(url.path); record with TESSERAE_RECORD_SNAPSHOTS=1", file: file, line: line)
            return
        }
        let want = Raster(try readPNG(url))
        guard actual == want else {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tesserae-snapshots")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let actualURL = tmp.appendingPathComponent("\(name).actual.png")
            let diffURL = tmp.appendingPathComponent("\(name).diff.png")
            try writePNG(image, to: actualURL)
            var differing = 0
            var diff = want
            if want.width == actual.width && want.height == actual.height {
                for p in 0..<(want.width * want.height) {
                    let same = (0..<4).allSatisfy { want.bytes[p * 4 + $0] == actual.bytes[p * 4 + $0] }
                    if !same { differing += 1 }
                    // Matching pixels dimmed to grey, differing ones magenta.
                    let g = UInt8((Int(want.bytes[p * 4]) + Int(want.bytes[p * 4 + 1]) + Int(want.bytes[p * 4 + 2])) / 6 + 128)
                    (diff.bytes[p * 4], diff.bytes[p * 4 + 1], diff.bytes[p * 4 + 2], diff.bytes[p * 4 + 3]) =
                        same ? (g, g, g, 255) : (255, 0, 255, 255)
                }
                try writePNG(Self.cgImage(diff), to: diffURL)
            }
            XCTFail(
                "\(name): \(differing) pixels differ (\(actual.width)×\(actual.height) vs reference "
                    + "\(want.width)×\(want.height)). actual: \(actualURL.path) diff: \(diffURL.path) reference: \(url.path)",
                file: file, line: line)
            return
        }
    }

    private static func cgImage(_ r: Raster) -> CGImage {
        let provider = CGDataProvider(data: Data(r.bytes) as CFData)!
        return CGImage(
            width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: Fixtures

    /// A fixed tree: nested directories to depth 4, a permission-denied
    /// folder, and a crowd of tiny files that the layout collapses into an
    /// aggregate.
    private static func fixedTree() -> SyntheticTree {
        typealias S = SyntheticTree.Spec
        let tiny = (0..<60).map { _ in S.file(1) }
        return SyntheticTree(.dir([
            .dir([
                .dir([.dir([.file(9_000), .file(4_000), .file(2_000)]), .file(6_000), .file(3_000)]),
                .file(12_000), .file(5_000),
            ]),
            .dir([.file(20_000), .file(11_000), .dir([.file(7_000), .file(5_000)])]),
            .denied,
            .file(30_000),
            .dir(tiny + [.file(8_000), .file(9_500)]),
        ]))
    }

    private static let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)

    private static func tiles(of tree: SyntheticTree) -> [Tile] {
        squarify(tree, root: tree.rootIndex, in: bounds)
    }

    /// Depth mode's colours for layout tiles (what `colourIndex(for:in:mode:)`
    /// gives on a snapshot): the ramp cycles every five levels.
    private static func depthIndex(_ t: Tile) -> UInt16 {
        t.isPermissionDenied ? UInt16(Palette.statusIndex) : UInt16(Palette.firstColourIndex + Int(t.depth) % 5)
    }

    /// Type-focus-like colours: denied is status, aggregates neutral, and files
    /// cycle through neutral and the three focus slots by node number.
    private static func focusIndex(_ t: Tile) -> UInt16 {
        if t.isPermissionDenied { return UInt16(Palette.statusIndex) }
        if t.isAggregate { return UInt16(Palette.neutralIndex) }
        let slot = Int(t.node) % 4
        return slot == 3 ? UInt16(Palette.neutralIndex) : UInt16(Palette.firstColourIndex + slot)
    }

    private func render(
        _ tiles: [Tile], _ colours: [SIMD4<Float>], _ colourOf: (Tile) -> UInt16, dark: Bool,
        size: CGSize = bounds.size, scale: CGFloat = 1
    ) -> CGImage {
        CGTreemapRenderer(clearColour: Palette.surface(dark: dark)).render(
            tiles: tiles, colours: colours, colourOf: colourOf, size: size, scale: scale)
    }

    // MARK: References

    func test_fixed_tree_depth_mode_light_matches_reference() throws {
        let tiles = Self.tiles(of: Self.fixedTree())
        XCTAssertGreaterThanOrEqual(Set(tiles.map(\.depth)).count, 4, "precondition: several depths")
        XCTAssertGreaterThan(tiles.count, 12, "precondition: many tiles")
        let image = render(tiles, Palette.colours(.depth, dark: false), Self.depthIndex, dark: false)
        XCTAssertEqual(image.width, 240)
        try assertMatchesReference(image, named: "fixed-tree-depth-light")
    }

    func test_fixed_tree_depth_mode_dark_matches_reference() throws {
        let tiles = Self.tiles(of: Self.fixedTree())
        XCTAssertGreaterThanOrEqual(Set(tiles.map(\.depth)).count, 4, "precondition: several depths")
        // At scale 2, so the 1-device-pixel border is a half-point border.
        let image = render(
            tiles, Palette.colours(.depth, dark: true), Self.depthIndex, dark: true, scale: 2)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 320)
        try assertMatchesReference(image, named: "fixed-tree-depth-dark-2x")
    }

    func test_type_focus_and_permission_denied_tiles_match_reference() throws {
        // The layout's permission-denied placeholder is a 4×4 point square
        // (visible, but only a few pixels of fill at this size), so a
        // hand-made one, 30×20 points, is added to make the status colour
        // prominent in the reference.
        let tiles = Self.tiles(of: Self.fixedTree()) + [
            Tile(rect: CGRect(x: 100, y: 60, width: 30, height: 20), node: 7, depth: 2, flags: Tile.Flag.permDenied)
        ]
        XCTAssertGreaterThanOrEqual(tiles.filter { $0.isPermissionDenied }.count, 2, "precondition: denied tiles")
        XCTAssertTrue(tiles.contains { $0.isAggregate && !$0.isPermissionDenied }, "precondition: an aggregate tile")
        let indices = Set(tiles.map(Self.focusIndex))
        XCTAssertEqual(indices, [0, 1, 2, 3, 4], "precondition: neutral, status and all three focus slots appear")
        let image = render(tiles, Palette.colours(.typeFocus([]), dark: false), Self.focusIndex, dark: false)
        let raster = Raster(image)
        var statusPixels = 0
        for p in 0..<(raster.width * raster.height) where Array(raster.bytes[p * 4..<p * 4 + 3]) == [0xfa, 0xb2, 0x19] {
            statusPixels += 1
        }
        XCTAssertGreaterThan(statusPixels, 20, "precondition: the permission-denied tile is visible in the image")
        try assertMatchesReference(image, named: "type-focus-permission-denied-light")
    }

    // MARK: Pixel rules

    func test_fill_border_and_painter_order_pixels() throws {
        let colours = Palette.colours(.depth, dark: false)
        let tiles = [
            Tile(rect: CGRect(x: 0, y: 0, width: 20, height: 20), node: 0, depth: 0),
            Tile(rect: CGRect(x: 5, y: 6, width: 10, height: 8), node: 1, depth: 3),
        ]
        let image = render(tiles, colours, Self.depthIndex, dark: false, size: CGSize(width: 24, height: 24))
        let r = Raster(image)
        func q(_ c: SIMD4<Float>, _ s: Float) -> [Int] {
            [Int((c.x * s * 255).rounded()), Int((c.y * s * 255).rounded()), Int((c.z * s * 255).rounded()), 255]
        }
        let outer = colours[2], inner = colours[5]
        XCTAssertNotEqual(q(outer, 1), q(inner, 1), "precondition: distinct fills")
        XCTAssertEqual(r.rgba(10, 3), q(outer, 1), "parent fill")
        XCTAssertEqual(r.rgba(0, 10), q(outer, 0.7), "parent left border pixel")
        XCTAssertEqual(r.rgba(1, 10), q(outer, 1), "one pixel in is fill")
        XCTAssertEqual(r.rgba(19, 19), q(outer, 0.7), "parent corner border")
        XCTAssertEqual(r.rgba(20, 10), q(Palette.surface(dark: false), 1), "outside the parent is clear")
        XCTAssertEqual(r.rgba(10, 10), q(inner, 1), "child painted over parent")
        XCTAssertEqual(r.rgba(5, 10), q(inner, 0.7), "child border (1 px, not 2)")
        XCTAssertEqual(r.rgba(6, 10), q(inner, 1), "child fill next to border")
        XCTAssertEqual(r.rgba(14, 13), q(inner, 0.7), "child bottom-right border")
        XCTAssertEqual(r.rgba(10, 6), q(inner, 0.7), "child top border (y is down)")
        XCTAssertEqual(r.rgba(10, 7), q(inner, 1), "child fill below top border")
    }

    // MARK: Tiny and zero sizes

    func test_tiny_and_zero_sizes_emit_no_nan() throws {
        let tree = Self.fixedTree()
        let palette = Palette.colours(.depth, dark: false)
        var checkedRects = 0
        let metal = MTLCreateSystemDefaultDevice().flatMap { TreemapRenderer(device: $0) }
        for side: CGFloat in [0, 0.5, 1] {
            let b = CGRect(x: 0, y: 0, width: side, height: side)
            let tiles = squarify(tree, root: tree.rootIndex, in: b)
            for t in tiles {
                for v in [t.rect.minX, t.rect.minY, t.rect.width, t.rect.height] {
                    XCTAssertTrue(v.isFinite, "side \(side): non-finite layout rect \(t.rect)")
                    checkedRects += 1
                }
            }
            if side == 0 { XCTAssertTrue(tiles.isEmpty, "a 0×0 layout is empty") }
            // The layout's own tiles, plus rects that would make a careless
            // renderer trap or write NaN: non-finite and enormous ones.
            let nasty = [
                Tile(rect: CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4), node: 1, depth: 1),
                Tile(rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.nan), node: 2, depth: 1),
                Tile(rect: CGRect(x: -1e300, y: -1e300, width: 2e300, height: 2e300), node: 3, depth: 2),
                Tile(rect: CGRect(x: 0, y: 0, width: 0, height: 0), node: 4, depth: 0),
            ]
            for scale: CGFloat in [1, 2] {
                let image = render(tiles + nasty, palette, Self.depthIndex, dark: false, size: b.size, scale: scale)
                XCTAssertGreaterThanOrEqual(image.width, 1)
                XCTAssertGreaterThanOrEqual(image.height, 1)
                XCTAssertLessThanOrEqual(image.width, Int(side * scale) + 1, "side \(side)")
                let r = Raster(image)
                XCTAssertTrue(r.bytes.contains { $0 != 0 }, "side \(side) scale \(scale): the image is drawn")
                // The huge tile covers everything; the NaN ones must not have
                // painted over it.
                let want = palette[Palette.firstColourIndex + 2]
                XCTAssertEqual(
                    r.rgba(0, 0), [Int((want.x * 255).rounded()), Int((want.y * 255).rounded()),
                                   Int((want.z * 255).rounded()), 255], "side \(side): the huge tile's fill")
            }
            if let metal = metal {
                metal.update(tiles: tiles + nasty, colourOf: Self.depthIndex, palette: palette)
                let image = metal.renderOffscreen(size: b.size, scale: 1)
                XCTAssertGreaterThanOrEqual(image.width, 1, "Metal side \(side)")
                XCTAssertGreaterThanOrEqual(image.height, 1, "Metal side \(side)")
            }
        }
        XCTAssertGreaterThan(checkedRects, 0, "precondition: the 1×1 layout produced tiles to check")
        if metal == nil { throw XCTSkip("no Metal device: the CoreGraphics half ran, the Metal half did not") }
    }

    // MARK: Metal cross-check

    /// The fallback must not drift from the real renderer: same tiles, same
    /// bytes, for every shipped palette entry. One 20×20 tile per palette
    /// index (integral rects, so rasterisation is unambiguous); the status
    /// colour comes from a real `permDenied` tile. Border bytes are
    /// fill × 0.7, which lands on exact .5 for several shipped channels
    /// (0x19, 0xaf, 0xcd, 0x55, ...), so this also pins the tie-rounding mode.
    func test_metal_and_coregraphics_agree_on_every_palette() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let metal = try XCTUnwrap(TreemapRenderer(device: device))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let modes: [(String, ColourMode)] = [
            ("depth", .depth), ("age", .age(now: now)), ("typeFocus", .typeFocus([]))
        ]
        var mismatches: [String] = []
        var checkedColours = 0
        for (modeName, mode) in modes {
            for dark in [false, true] {
                for staged in [false, true] {
                    let palette = Palette.colours(mode, dark: dark)
                    var tiles: [Tile] = []
                    for i in 0..<palette.count {
                        let rect = CGRect(x: (i % 6) * 20, y: (i / 6) * 20, width: 20, height: 20)
                        let flags = i == Palette.statusIndex ? Tile.Flag.permDenied : 0
                        tiles.append(Tile(rect: rect, node: UInt32(i), depth: 0, flags: flags | (staged ? Tile.Flag.staged : 0)))
                    }
                    XCTAssertTrue(tiles.contains { $0.isPermissionDenied }, "precondition: a permDenied tile")
                    let colourOf: (Tile) -> UInt16 = {
                        $0.isPermissionDenied ? UInt16(Palette.statusIndex) : UInt16($0.node)
                    }
                    let size = CGSize(width: 120, height: CGFloat((palette.count + 5) / 6 * 20))
                    for scale: CGFloat in [1, 2] {
                        metal.clearColour = Palette.surface(dark: dark)
                        metal.update(tiles: tiles, colourOf: colourOf, palette: palette)
                        let m = Raster(metal.renderOffscreen(size: size, scale: scale))
                        let c = Raster(render(tiles, palette, colourOf, dark: dark, size: size, scale: scale))
                        XCTAssertEqual(m.width, c.width)
                        XCTAssertEqual(m.height, c.height)
                        var bad = Set<String>()
                        for t in tiles {
                            // Probe every pixel of the tile, which covers fill and border.
                            let x0 = Int(t.rect.minX * scale), y0 = Int(t.rect.minY * scale)
                            for y in y0..<(y0 + Int(20 * scale)) {
                                for x in x0..<(x0 + Int(20 * scale)) where m.rgba(x, y) != c.rgba(x, y) {
                                    bad.insert("\(modeName)\(dark ? "-dark" : "") index \(t.node): "
                                        + "Metal \(m.rgba(x, y)) CG \(c.rgba(x, y))")
                                }
                            }
                        }
                        mismatches += bad.sorted().map { "\($0) @\(scale)x" }
                        checkedColours += tiles.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedColours, 120, "precondition: all palettes were compared")
        XCTAssertEqual(mismatches, [], "Metal and CoreGraphics bytes differ")
    }

    @MainActor
    func test_fallback_identity_skips_colour_mapping_on_hover_and_scale_updates() {
        let view = TreemapView.FallbackView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let t = TestSnapshot(.dir("/R", [.file("clip.mp4", 10)]))
        let tiles = [Tile(rect: view.bounds, node: t["clip.mp4"], depth: 0)]
        let palette = Palette.colours(.typeFocus([.video]), dark: false)
        var calls = 0
        let colour: (Tile) -> UInt16 = { _ in calls += 1; return 2 }
        view.set(tiles: tiles, palette: palette, colourOf: colour, dark: false, snapshot: t.snapshot, mode: .typeFocus([.video]))
        let initial = calls
        XCTAssertGreaterThan(initial, 0, "precondition: first input mapped")
        view.set(tiles: tiles, palette: palette, colourOf: colour, dark: false, snapshot: t.snapshot, mode: .typeFocus([.video]))
        view.layout()
        view.scaleOverride = 2
        XCTAssertEqual(calls, initial, "no name lookup or palette mapping on identical input or backing scale")
        view.set(tiles: tiles, palette: palette, colourOf: colour, dark: false, snapshot: t.snapshot, mode: .age(now: Date(timeIntervalSince1970: 100)))
        XCTAssertGreaterThan(calls, initial, "mode changes invalidate colours")
    }

    func test_staged_tiles_have_hatch_and_one_device_pixel_outline() throws {
        let tile = Tile(rect: CGRect(x: 0, y: 0, width: 20, height: 20), node: 0, depth: 0, flags: Tile.Flag.staged)
        XCTAssertNotEqual(tile.flags & Tile.Flag.staged, 0)
        for dark in [false, true] {
            for scale: CGFloat in [1, 2] {
                let palette = Palette.colours(.depth, dark: dark)
                let image = render([tile], palette, Self.depthIndex, dark: dark, size: tile.rect.size, scale: scale)
                let raster = Raster(image)
                let ink = palette[2].x * 0.2126 + palette[2].y * 0.7152 + palette[2].z * 0.0722 > 0.5 ? 0 : 255
                XCTAssertEqual(raster.rgba(0, 10), [ink, ink, ink, 255], "outline")
                XCTAssertEqual(raster.rgba(3, 5), [ink, ink, ink, 255], "diagonal hatch")
                XCTAssertNotEqual(raster.rgba(1, 10), [ink, ink, ink, 255], "outline stays one device pixel")
                try assertMatchesReference(image, named: "jetsam-staged-" + (dark ? "dark" : "light") + "-\(Int(scale))x")
            }
        }
    }

    // MARK: Fallback view caching

    @MainActor
    func test_fallback_view_rerenders_on_scale_change_but_not_on_unchanged_update() throws {
        let view = TreemapView.FallbackView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 120, height: 80), node: 0, depth: 0)]
        let palette = Palette.colours(.depth, dark: false)
        let colourOf: (Tile) -> UInt16 = { _ in 2 }
        view.scaleOverride = 1
        let base = view.renderCount  // the empty view's own render
        view.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: false)
        XCTAssertEqual(view.renderCount, base + 1, "first set renders")
        let first = try XCTUnwrap(view.layer?.contents as! CGImage?)
        XCTAssertEqual(first.width, 120)

        view.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: false)
        view.layout()
        XCTAssertEqual(view.renderCount, base + 1, "an unchanged update does not re-render")

        view.scaleOverride = 2
        XCTAssertEqual(view.renderCount, base + 2, "a scale change re-renders")
        let second = try XCTUnwrap(view.layer?.contents as! CGImage?)
        XCTAssertEqual(second.width, 240)

        view.set(tiles: tiles, palette: palette, colourOf: { _ in 3 }, dark: false)
        XCTAssertEqual(view.renderCount, base + 3, "different colour indices re-render")
        view.set(tiles: tiles, palette: palette, colourOf: { _ in 3 }, dark: true)
        XCTAssertEqual(view.renderCount, base + 4, "light/dark re-renders")
    }
}
