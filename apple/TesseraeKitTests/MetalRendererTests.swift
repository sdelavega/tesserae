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

/// The instanced Metal renderer (spec §8 "Metal"), checked on pixels read back
/// from `renderOffscreen`. Every test needs a GPU; without one it is skipped by
/// name, never passed silently.
final class MetalRendererTests: XCTestCase {
    private func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        return d
    }

    /// An 8-bit BGRA pixel.
    private struct Pixel: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int, a: Int
        var description: String { String(format: "#%02x%02x%02x/%02x", r, g, b, a) }
    }

    /// The raw bytes of `image`, which `renderOffscreen` returns as 8-bit
    /// BGRA (premultiplied first, 32-bit little-endian) in sRGB. Read straight
    /// from the data provider: drawing into a context could colour-match.
    private struct Bitmap {
        let width: Int, height: Int, bytesPerRow: Int
        let bytes: [UInt8]
        init(_ image: CGImage) throws {
            XCTAssertEqual(image.bitsPerComponent, 8)
            XCTAssertEqual(image.bitsPerPixel, 32)
            XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
            XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            width = image.width
            height = image.height
            bytesPerRow = image.bytesPerRow
            bytes = [UInt8](data)
        }
        subscript(x: Int, y: Int) -> Pixel {
            precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)×\(height)")
            let o = y * bytesPerRow + x * 4
            return Pixel(r: Int(bytes[o + 2]), g: Int(bytes[o + 1]), b: Int(bytes[o]), a: Int(bytes[o + 3]))
        }
    }

    /// The 8-bit encoding of a palette colour (sRGB-encoded, hex / 255).
    private static func pixel(_ c: SIMD4<Float>) -> Pixel {
        func q(_ v: Float) -> Int { Int((v * 255).rounded()) }
        return Pixel(r: q(c.x), g: q(c.y), b: q(c.z), a: q(c.w))
    }

    /// Palette and clear colours are k/255 floats, which the GPU's
    /// float-to-unorm8 conversion maps back to exactly k: compared exactly.
    private func assertExact(
        _ got: Pixel, _ want: Pixel, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got, want, what, file: file, line: line)
    }

    /// Within one 8-bit step per channel, for border pixels only: fill × 0.7
    /// falls between 8-bit steps, and Metal does not require its
    /// float-to-unorm8 conversion to round to nearest, so a value near a
    /// half-step may land on either neighbour.
    private func assertClose(
        _ got: Pixel, _ want: Pixel, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let ok = abs(got.r - want.r) <= 1 && abs(got.g - want.g) <= 1 && abs(got.b - want.b) <= 1
            && abs(got.a - want.a) <= 1
        XCTAssertTrue(ok, "\(what): got \(got), want \(want)", file: file, line: line)
    }

    private static func render(
        _ r: TreemapRenderer, _ tiles: [Tile], palette: [SIMD4<Float>], size: CGSize, scale: CGFloat
    ) throws -> Bitmap {
        r.update(tiles: tiles, colourOf: { UInt16(Palette.firstColourIndex + Int($0.depth)) }, palette: palette)
        let image = r.renderOffscreen(size: size, scale: scale)
        XCTAssertEqual(image.width, Int(size.width * scale))
        XCTAssertEqual(image.height, Int(size.height * scale))
        return try Bitmap(image)
    }

    // MARK: Tests

    func test_tile_centre_pixel_is_its_palette_colour() throws {
        let r = try XCTUnwrap(TreemapRenderer(device: try device()))
        let palette = Palette.colours(.folder, dark: false)
        // Breadth-first, as the layout emits them: two parents, then a child
        // of the first, which must paint over it (painter's order).
        let tiles = [
            Tile(rect: CGRect(x: 0, y: 0, width: 60, height: 80), node: 1, depth: 0),
            Tile(rect: CGRect(x: 60, y: 0, width: 40, height: 80), node: 2, depth: 1),
            Tile(rect: CGRect(x: 10, y: 20, width: 40, height: 30), node: 3, depth: 2),
        ]
        let colours = tiles.map { palette[Palette.firstColourIndex + Int($0.depth)] }
        XCTAssertEqual(Set(colours.map { Self.pixel($0).description }).count, 3, "precondition: distinct colours")
        for scale in [1.0, 2.0] as [CGFloat] {
            let bmp = try Self.render(r, tiles, palette: palette, size: CGSize(width: 100, height: 80), scale: scale)
            // Centres, plus a point of the first parent outside its child.
            let probes: [(CGPoint, Int)] = [
                (CGPoint(x: 30, y: 70), 0), (CGPoint(x: 80, y: 40), 1), (CGPoint(x: 30, y: 35), 2),
            ]
            for (p, i) in probes {
                let got = bmp[Int(p.x * scale), Int(p.y * scale)]
                assertExact(got, Self.pixel(colours[i]), "tile \(i) at \(p) scale \(scale)")
            }
        }
    }

    func test_inner_border_is_one_pixel_and_darker_than_fill() throws {
        let r = try XCTUnwrap(TreemapRenderer(device: try device()))
        let palette = Palette.colours(.folder, dark: false)
        let tile = Tile(rect: CGRect(x: 10, y: 10, width: 40, height: 40), node: 1, depth: 2)
        let fill = palette[Palette.firstColourIndex + 2]
        let border = SIMD4(fill.x * TreemapRenderer.borderShade, fill.y * TreemapRenderer.borderShade,
                           fill.z * TreemapRenderer.borderShade, fill.w)
        let (fillPx, borderPx, clearPx) = (Self.pixel(fill), Self.pixel(border), Self.pixel(r.clearColour))
        XCTAssertTrue(borderPx.r <= fillPx.r && borderPx.g <= fillPx.g && borderPx.b <= fillPx.b
            && borderPx.r + borderPx.g + borderPx.b < fillPx.r + fillPx.g + fillPx.b - 30,
            "precondition: the border rule darkens \(fillPx) to \(borderPx)")
        XCTAssertNotEqual(clearPx, fillPx, "precondition: background differs from fill")
        XCTAssertNotEqual(clearPx, borderPx, "precondition: background differs from border")

        // One device pixel at every scale, so 2 px wide at scale 2, 3 at 3
        // would mean a point-sized border.
        for scale in [1, 2, 3] {
            let bmp = try Self.render(r, [tile], palette: palette, size: CGSize(width: 60, height: 60),
                                      scale: CGFloat(scale))
            let lo = 10 * scale, hi = 50 * scale - 1, mid = 30 * scale
            // Across the middle row and down the middle column: each edge
            // pixel, its inward neighbour, and its outward neighbour.
            struct Edge { let name: String; let x: Int; let y: Int; let dx: Int; let dy: Int }
            let edges = [
                Edge(name: "left", x: lo, y: mid, dx: 1, dy: 0), Edge(name: "right", x: hi, y: mid, dx: -1, dy: 0),
                Edge(name: "top", x: mid, y: lo, dx: 0, dy: 1), Edge(name: "bottom", x: mid, y: hi, dx: 0, dy: -1),
            ]
            for e in edges {
                assertClose(bmp[e.x, e.y], borderPx, "\(e.name) edge pixel at scale \(scale)")
                assertExact(bmp[e.x + e.dx, e.y + e.dy], fillPx, "pixel inside the \(e.name) edge at scale \(scale)")
                assertExact(bmp[e.x - e.dx, e.y - e.dy], clearPx, "pixel outside the \(e.name) edge at scale \(scale)")
            }
            assertExact(bmp[mid, mid], fillPx, "centre at scale \(scale)")
        }
    }

    func test_instance_struct_layout_matches_the_shader() throws {
        let d = try device()
        // Spec §8: 20 bytes of payload; float4's 16-byte alignment pads the
        // array stride to 32 on both sides.
        XCTAssertEqual(MemoryLayout<TileInstance>.size, 20)
        XCTAssertEqual(MemoryLayout<TileInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<TileInstance>.offset(of: \TileInstance.rect), 0)
        XCTAssertEqual(MemoryLayout<TileInstance>.offset(of: \TileInstance.colorIdx), 16)
        XCTAssertEqual(MemoryLayout<TileInstance>.offset(of: \TileInstance.depth), 18)
        XCTAssertEqual(MemoryLayout<TileInstance>.offset(of: \TileInstance.flags), 19)

        // The shader's own view: a probe kernel in Shaders.metal reads each
        // instance written from Swift and echoes its fields and sizeof.
        let lib = try TreemapRenderer.makeLibrary(device: d)
        let fn = try XCTUnwrap(lib.makeFunction(name: "tile_instance_probe"))
        let pso = try d.makeComputePipelineState(function: fn)
        let input: [TileInstance] = (0..<4).map { (i: Int) -> TileInstance in
            let f = Float(i)
            let rect = SIMD4<Float>(f + 0.25, 100 + f, 1000.5 + f, -7 - f)
            return TileInstance(rect: rect, colorIdx: UInt16(0xA1B2 + i), depth: UInt8(0x30 + i), flags: UInt8(0xC0 + i))
        }
        let stride = MemoryLayout<TileInstance>.stride
        let inBuf = try XCTUnwrap(d.makeBuffer(bytes: input, length: stride * input.count, options: .storageModeShared))
        let words = 8
        let outBuf = try XCTUnwrap(d.makeBuffer(length: 4 * words * input.count, options: .storageModeShared))
        let q = try XCTUnwrap(d.makeCommandQueue())
        let cb = try XCTUnwrap(q.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: input.count, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
        let out = outBuf.contents().bindMemory(to: UInt32.self, capacity: words * input.count)
        for (i, t) in input.enumerated() {
            let o = i * words
            XCTAssertEqual(Int(out[o]), stride, "sizeof(TileInstance) in the shader")
            for c in 0..<4 {
                XCTAssertEqual(Float(bitPattern: out[o + 1 + c]), t.rect[c], "instance \(i) rect[\(c)]")
            }
            XCTAssertEqual(out[o + 5], UInt32(t.colorIdx), "instance \(i) colorIdx")
            XCTAssertEqual(out[o + 6], UInt32(t.depth), "instance \(i) depth")
            XCTAssertEqual(out[o + 7], UInt32(t.flags), "instance \(i) flags")
        }
    }

    func test_budget_halves_when_buffer_allocation_fails() throws {
        let d = try device()
        XCTAssertEqual(TreemapRenderer.defaultInstanceBudget, 50_000, "precondition: spec §8 budget")
        let stride = MemoryLayout<TileInstance>.stride
        var requests: [Int] = []
        var failures = 0
        let r = try XCTUnwrap(TreemapRenderer(device: d, allocator: { dev, length in
            requests.append(length)
            if failures == 0 {
                failures += 1
                return nil
            }
            return dev.makeBuffer(length: length, options: .storageModeShared)
        }), "the renderer gives up instead of retrying with a smaller budget")
        XCTAssertEqual(failures, 1, "precondition: the allocator failed once")
        XCTAssertEqual(r.instanceBudget, 25_000)
        XCTAssertEqual(requests.first, 50_000 * stride)
        XCTAssertEqual(Array(requests.dropFirst()), Array(repeating: 25_000 * stride, count: 3),
                       "after the failure, three instance buffers at half the budget")

        // And it still draws, capped at its budget.
        let palette = Palette.colours(.folder, dark: false)
        let tile = Tile(rect: CGRect(x: 0, y: 0, width: 20, height: 20), node: 1, depth: 1)
        let bmp = try Self.render(r, [tile], palette: palette, size: CGSize(width: 20, height: 20), scale: 1)
        assertExact(bmp[10, 10], Self.pixel(palette[Palette.firstColourIndex + 1]), "centre after the retry")
        XCTAssertEqual(r.droppedTileCount, 0, "precondition: one tile fits the budget")

        // The clamp is reported, not silent: one tile past the halved budget.
        let many = Array(repeating: tile, count: r.instanceBudget + 1)
        r.update(tiles: many, colourOf: { _ in UInt16(Palette.firstColourIndex) }, palette: palette)
        XCTAssertEqual(r.droppedTileCount, many.count - r.instanceBudget)
        XCTAssertEqual(r.droppedTileCount, 1)
        // And recomputed on every update.
        r.update(tiles: [tile], colourOf: { _ in UInt16(Palette.firstColourIndex) }, palette: palette)
        XCTAssertEqual(r.droppedTileCount, 0)
    }

    func test_init_fails_when_every_allocation_fails() throws {
        let d = try device()
        var requests: [Int] = []
        let r = TreemapRenderer(device: d, allocator: { _, length in
            requests.append(length)
            return nil
        })
        XCTAssertNil(r, "no instance buffers at any budget: no renderer")
        // Precondition: it really tried every halving down to one tile.
        let stride = MemoryLayout<TileInstance>.stride
        XCTAssertEqual(requests.first, TreemapRenderer.defaultInstanceBudget * stride)
        XCTAssertEqual(requests.last, 1 * stride)
        XCTAssertEqual(requests.count, 16, "50000, 25000, … 3, 1: sixteen halvings tried")
    }

    func test_tiles_past_the_budget_are_not_drawn() throws {
        let d = try device()
        let stride = MemoryLayout<TileInstance>.stride
        // Fail every buffer larger than three tiles: the budget halves
        // 50000 → … → 6 → 3.
        let r = try XCTUnwrap(TreemapRenderer(device: d, allocator: { dev, length in
            length > 3 * stride ? nil : dev.makeBuffer(length: length, options: .storageModeShared)
        }))
        XCTAssertEqual(r.instanceBudget, 3, "precondition: a three-tile budget")
        let palette = Palette.colours(.folder, dark: false)
        // Five disjoint tiles in a row, all one colour.
        let tiles = (0..<5).map { i in
            Tile(rect: CGRect(x: CGFloat(i) * 20, y: 0, width: 20, height: 20), node: UInt32(i), depth: 0)
        }
        let bmp = try Self.render(r, tiles, palette: palette, size: CGSize(width: 100, height: 20), scale: 1)
        XCTAssertEqual(r.droppedTileCount, 2)
        let fill = Self.pixel(palette[Palette.firstColourIndex])
        let clear = Self.pixel(r.clearColour)
        XCTAssertNotEqual(fill, clear, "precondition: tiles are visible against the background")
        for i in 0..<5 {
            let want = i < 3 ? fill : clear
            assertExact(bmp[i * 20 + 10, 10], want, "tile \(i) \(i < 3 ? "within" : "past") the budget")
        }
    }
}
