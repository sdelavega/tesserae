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
import Metal
import MetalKit

/// One tile as the GPU sees it (spec §8 "Metal"). Matched field for field by
/// `TileInstance` in Shaders.metal: 20 bytes of payload (`MemoryLayout.size`),
/// padded by `SIMD4<Float>`'s 16-byte alignment to a 32-byte stride, which is
/// also the shader's `sizeof`.
public struct TileInstance {
    public var rect: SIMD4<Float>  // x, y, w, h in points, origin top-left, y down
    public var colorIdx: UInt16  // index into the palette buffer
    public var depth: UInt8
    public var flags: UInt8  // `Tile.Flag` bits

    public init(rect: SIMD4<Float>, colorIdx: UInt16, depth: UInt8, flags: UInt8) {
        self.rect = rect
        self.colorIdx = colorIdx
        self.depth = depth
        self.flags = flags
    }
}

/// `Uniforms` in Shaders.metal.
struct TreemapUniforms {
    var viewSize: SIMD2<Float>  // points
    var scale: Float  // device pixels per point
    var alpha: Float
}

/// Draws a list of tiles with one instanced draw call (spec §8 "Metal").
///
/// **Colour space.** Palette colours are sRGB-encoded (`Palette.colours`), and
/// every target is `.bgra8Unorm`, a non-sRGB format: the shader writes the
/// palette values unconverted, so each stored byte is the palette's hex value,
/// and the view's `colorspace` (sRGB) tells the compositor how to read them.
/// Blending for the cross-fade `alpha` therefore happens on encoded values,
/// which is fine for a fade.
///
/// **Order.** Tiles are drawn in array order (painter's order). The layout
/// emits them breadth-first, so every parent precedes its children and
/// children paint over it; nothing assumes a subtree is contiguous.
///
/// **Border.** Each tile has an inner border one *device* pixel wide (from the
/// fragment's distance, in device pixels, to the nearest rect edge), coloured
/// the fill's encoded RGB times `borderShade`.
///
/// **Buffering.** Three instance buffers (`storageModeShared`) used round-robin,
/// guarded by `DispatchSemaphore(value: 3)`: a frame waits until the GPU has
/// finished with the buffer it is about to overwrite. If a buffer cannot be
/// allocated the instance budget is halved and all three are allocated again
/// (spec §11); tiles beyond the budget are not drawn (since the list is
/// breadth-first those are the deepest) and are counted in
/// `droppedTileCount`.
public final class TreemapRenderer {
    /// Spec §8's hard instance budget.
    public static let defaultInstanceBudget = 50_000
    /// The border colour is the fill's sRGB-encoded RGB times this (the
    /// shader's `kBorderShade`).
    public static let borderShade: Float = 0.7
    /// The border's width in device pixels (the shader's `kBorderWidthPixels`).
    public static let borderWidthPixels = 1
    static let inFlightFrames = 3
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let buffers: [MTLBuffer]
    private let inFlight = DispatchSemaphore(value: TreemapRenderer.inFlightFrames)
    private var frame = 0

    /// How many tiles a frame draws at most: the spec's budget, halved for
    /// every failed allocation.
    public let instanceBudget: Int
    /// How many tiles the last `update` dropped because they were past
    /// `instanceBudget`: shown to the user, since the spec forbids silent
    /// under-reporting (§11).
    public private(set) var droppedTileCount = 0
    /// The colour under the tiles (sRGB-encoded, like the palette).
    public var clearColour: SIMD4<Float> = Palette.surface(dark: false)

    private var instances: [TileInstance] = []
    private var palette: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1)]

    /// The compiled Shaders.metal, from TesseraeKit's own bundle.
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeDefaultLibrary(bundle: Bundle(for: TreemapRenderer.self))
    }

    /// `nil` if the shaders or the pipeline cannot be built, or no instance
    /// buffers can be allocated at any budget.
    public convenience init?(device: MTLDevice) {
        self.init(device: device) { dev, length in dev.makeBuffer(length: length, options: .storageModeShared) }
    }

    /// As above, allocating instance buffers with `allocator` (a test seam).
    init?(device: MTLDevice, allocator: (MTLDevice, Int) -> MTLBuffer?) {
        guard let queue = device.makeCommandQueue(),
            let library = try? Self.makeLibrary(device: device),
            let vertex = library.makeFunction(name: "tile_vertex"),
            let fragment = library.makeFunction(name: "tile_fragment")
        else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Treemap tiles"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        let colour = desc.colorAttachments[0]!
        colour.pixelFormat = Self.pixelFormat
        colour.isBlendingEnabled = true
        colour.rgbBlendOperation = .add
        colour.alphaBlendOperation = .add
        colour.sourceRGBBlendFactor = .sourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        let stride = MemoryLayout<TileInstance>.stride
        var budget = Self.defaultInstanceBudget
        var buffers: [MTLBuffer] = []
        while budget > 0 {
            buffers = []
            for _ in 0..<Self.inFlightFrames {
                guard let b = allocator(device, budget * stride) else { break }
                b.label = "Treemap instances"
                buffers.append(b)
            }
            if buffers.count == Self.inFlightFrames { break }
            budget /= 2
        }
        guard budget > 0 else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.buffers = buffers
        self.instanceBudget = budget
    }

    /// Replaces the tiles to draw. `colourOf` gives each tile's index into
    /// `palette` (`Palette.colours`); tiles past `instanceBudget` are dropped.
    public func update(tiles: [Tile], colourOf: (Tile) -> UInt16, palette: [SIMD4<Float>]) {
        precondition(!palette.isEmpty, "empty palette")
        let n = min(tiles.count, instanceBudget)
        droppedTileCount = tiles.count - n
        instances = tiles.prefix(n).map { t in
            let idx = colourOf(t)
            precondition(Int(idx) < palette.count, "colour index \(idx) outside a palette of \(palette.count)")
            return TileInstance(
                rect: SIMD4(Float(t.rect.minX), Float(t.rect.minY), Float(t.rect.width), Float(t.rect.height)),
                colorIdx: idx, depth: t.depth, flags: t.flags)
        }
        self.palette = palette
    }

    /// Draws the current tiles into `view`'s next drawable, at `alpha` over
    /// the clear colour. The view's drawable must be `.bgra8Unorm`.
    @MainActor
    public func draw(in view: MTKView, alpha: Float = 1) {
        let bounds = view.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        precondition(view.colorPixelFormat == Self.pixelFormat, "MTKView must use \(Self.pixelFormat)")
        let scale = view.drawableSize.width / bounds.width
        inFlight.wait()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let cb = queue.makeCommandBuffer()
        else {
            inFlight.signal()
            return
        }
        encode(cb, pass: pass, size: bounds, scale: scale, alpha: alpha)
        cb.present(drawable)
        cb.commit()
    }

    /// Renders the current tiles into a `size` × `scale` image (8-bit BGRA,
    /// premultiplied first, sRGB) and waits for it. For tests.
    public func renderOffscreen(size: CGSize, scale: CGFloat) -> CGImage {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        precondition(width > 0 && height > 0, "empty render size \(size) at scale \(scale)")
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: td) else {
            preconditionFailure("cannot allocate a \(width)×\(height) render target")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else {
            inFlight.signal()
            preconditionFailure("cannot make a command buffer")
        }
        encode(cb, pass: pass, size: size, scale: scale, alpha: 1)
        guard let blit = cb.makeBlitCommandEncoder() else { preconditionFailure("cannot make a blit encoder") }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        precondition(cb.status == .completed, "offscreen render failed: \(String(describing: cb.error))")

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)
        else { preconditionFailure("cannot wrap the render in a CGImage") }
        return image
    }

    /// Encodes one frame into `cb` (the caller has waited on `inFlight`; the
    /// command buffer's completion signals it) and advances the round-robin.
    private func encode(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, scale: CGFloat, alpha: Float) {
        let semaphore = inFlight
        cb.addCompletedHandler { _ in semaphore.signal() }
        let buffer = buffers[frame]
        frame = (frame + 1) % buffers.count

        let colour = pass.colorAttachments[0]!
        colour.loadAction = .clear
        colour.storeAction = .store
        colour.clearColor = MTLClearColor(
            red: Double(clearColour.x), green: Double(clearColour.y), blue: Double(clearColour.z),
            alpha: Double(clearColour.w))
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { enc.endEncoding() }
        let count = instances.count
        guard count > 0 else { return }
        instances.withUnsafeBytes { src in
            buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        var uniforms = TreemapUniforms(
            viewSize: SIMD2(Float(size.width), Float(size.height)), scale: Float(scale), alpha: alpha)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
        palette.withUnsafeBytes { p in
            enc.setFragmentBytes(p.baseAddress!, length: p.count, index: 0)
        }
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }
}
