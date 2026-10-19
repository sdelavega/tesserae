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
/// Without a Metal device, or if the renderer cannot be built, it shows a
/// plain surface-coloured placeholder; Task 9 replaces that with the
/// CoreGraphics renderer (spec §11 "Rendering").
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
            return Self.placeholder(dark: dark)
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
            nsView.layer?.backgroundColor = Self.cgColour(Palette.surface(dark: dark))
            return
        }
        renderer.clearColour = Palette.surface(dark: dark)
        renderer.update(tiles: tiles, colourOf: colourOf, palette: palette)
        nsView.needsDisplay = true
    }

    private static func cgColour(_ c: SIMD4<Float>) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), CGFloat(c.w)])!
    }

    private static func placeholder(dark: Bool) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = cgColour(Palette.surface(dark: dark))
        return view
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
