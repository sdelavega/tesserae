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
import Metal
import MetalKit
import SwiftUI

/// Hosts the treemap: an `MTKView` drawn by `TreemapRenderer`, redrawn on
/// demand (not on a display-link loop) whenever SwiftUI updates the inputs.
///
/// Without a Metal device, or if the renderer cannot be built, it shows the
/// CoreGraphics renderer's image instead (spec §11 "Rendering"), with no zoom
/// animation.
public struct TreemapView: NSViewRepresentable {
    public var tiles: [Tile]
    public var palette: [SIMD4<Float>]
    public var colourOf: (Tile) -> UInt16
    public var dark: Bool

    public init(tiles: [Tile], palette: [SIMD4<Float>], dark: Bool, colourOf: @escaping (Tile) -> UInt16) {
        self.tiles = tiles
        self.palette = palette
        self.dark = dark
        self.colourOf = colourOf
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = TreemapRenderer(device: device) else {
            let fallback = FallbackView(frame: .zero)
            fallback.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: dark)
            return fallback
        }
        let view = MTKView(frame: .zero, device: device)
        // The palette's sRGB-encoded values are written unconverted into a
        // non-sRGB drawable; the colorspace says how to read them.
        view.colorPixelFormat = TreemapRenderer.pixelFormat
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true
        context.coordinator.renderer = renderer
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let renderer = context.coordinator.renderer else {
            (nsView as? FallbackView)?.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: dark)
            return
        }
        renderer.clearColour = Palette.surface(dark: dark)
        renderer.update(tiles: tiles, colourOf: colourOf, palette: palette)
        nsView.needsDisplay = true
    }

    /// The no-Metal view: draws the tiles with `CGTreemapRenderer` into its
    /// layer whenever its inputs or size change.
    final class FallbackView: NSView {
        private var tiles: [Tile] = []
        private var palette: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1)]
        private var colourOf: (Tile) -> UInt16 = { _ in 0 }
        private var dark = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("FallbackView is not decoded from a nib") }

        func set(tiles: [Tile], palette: [SIMD4<Float>], colourOf: @escaping (Tile) -> UInt16, dark: Bool) {
            self.tiles = tiles
            self.palette = palette
            self.colourOf = colourOf
            self.dark = dark
            redraw()
        }

        override func layout() {
            super.layout()
            redraw()
        }

        private func redraw() {
            guard let layer, bounds.width > 0, bounds.height > 0 else { return }
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let image = CGTreemapRenderer(clearColour: Palette.surface(dark: dark)).render(
                tiles: tiles, colours: palette, colourOf: colourOf, size: bounds.size, scale: scale)
            layer.contentsScale = scale
            layer.contentsGravity = .topLeft
            layer.contents = image
        }
    }

    /// The `MTKView`'s delegate; owns the renderer.
    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: TreemapRenderer?

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        public func draw(in view: MTKView) {
            renderer?.draw(in: view)
        }
    }
}
