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
/// demand (not on a display-link loop) whenever SwiftUI updates the inputs,
/// and frame by frame only while a zoom animates.
///
/// **Interaction** (spec §8, `TreemapInteraction`): hover reports the tile
/// under the pointer to `onHover`; with a `navigator`, a click on a directory
/// tile, or Return over one, descends into it, ⌘↑ ascends and ← / → move
/// between siblings. The caller lays out `navigator.root` and passes the new
/// `tiles`; when they arrive after a descend, the view zooms: the old tiles,
/// transformed so the clicked rect grows to fill the view, cross-fade to the
/// new ones over ~250 ms (`ZoomAnimation`, `TreemapRenderer.drawZoom`), with
/// no layout during the animation. Returning to an ancestor (⌘↑, the
/// breadcrumb) animates too, inferred from the two layouts
/// (`navigationZoomRect`): the old root shrinks into its tile in the parent
/// layout. A resize cancels a recorded descend (`cancelPendingZoom`) and, since
/// the two layouts then fill different viewports, the inferred zoom as well.
/// Sibling moves and other tile changes redraw at once.
///
/// Without a Metal device, or if the renderer cannot be built, it shows the
/// CoreGraphics renderer's image instead (spec §11 "Rendering"), with no zoom
/// animation (ruling P2): there every navigation redraws at once.
public struct TreemapView: NSViewRepresentable {
    public var tiles: [Tile]
    public var palette: [SIMD4<Float>]
    public var colourOf: (Tile) -> UInt16
    public var dark: Bool
    /// Supplying both promises colourOf depends only on this snapshot, mode
    /// and tile. Without them an arbitrary closure is evaluated every update.
    public var snapshot: Snapshot?
    public var mode: ColourMode?
    public var selection: Selection?
    public var onZoomChanged: ((Bool) -> Void)?
    public var onDroppedTiles: ((Int) -> Void)?
    public var navigator: Navigator?
    public var onStage: (() -> Void)?
    public var onHover: ((Int?) -> Void)?

    public init(
        tiles: [Tile], palette: [SIMD4<Float>], dark: Bool, navigator: Navigator? = nil,
        snapshot: Snapshot? = nil, mode: ColourMode? = nil,
        selection: Selection? = nil, onZoomChanged: ((Bool) -> Void)? = nil,
        onDroppedTiles: ((Int) -> Void)? = nil,
        onHover: ((Int?) -> Void)? = nil, onStage: (() -> Void)? = nil, colourOf: @escaping (Tile) -> UInt16
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.selection = selection
        self.onZoomChanged = onZoomChanged
        self.onDroppedTiles = onDroppedTiles
        self.tiles = tiles
        self.palette = palette
        self.dark = dark
        self.navigator = navigator
        self.onStage = onStage
        self.onHover = onHover
        self.colourOf = colourOf
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        context.coordinator.contextMenu.stage = onStage
        let interaction = context.coordinator.interaction
        interaction.selection = selection
        interaction.navigator = navigator
        interaction.onHover = onHover
        _ = interaction.setTiles(tiles)
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = TreemapRenderer(device: device) else {
            let fallback = FallbackView(frame: .zero)
            fallback.interaction = interaction
            fallback.jetsamMenu = context.coordinator.contextMenu
            fallback.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: dark, snapshot: snapshot, mode: mode)
            return fallback
        }
        let view = InteractiveMTKView(frame: .zero, device: device)
        view.interaction = interaction
        view.jetsamMenu = context.coordinator.contextMenu
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
        let coordinator = context.coordinator
        coordinator.contextMenu.stage = onStage
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onDroppedTiles = onDroppedTiles
        coordinator.interaction.selection = selection
        let sameNavigator = coordinator.interaction.navigator === navigator
        let previousTiles = coordinator.interaction.tiles
        coordinator.interaction.navigator = navigator
        coordinator.interaction.onHover = onHover
        let pending = coordinator.interaction.setTiles(tiles)
        let inferred = sameNavigator ? Self.navigationZoomRect(old: previousTiles, new: tiles, viewport: nsView.bounds) : nil
        let zoomFrom = pending ?? inferred
        guard let renderer = coordinator.renderer, let view = nsView as? MTKView else {
            // No animation without Metal: the new layout at once.
            (nsView as? FallbackView)?.set(tiles: tiles, palette: palette, colourOf: colourOf, dark: dark, snapshot: snapshot, mode: mode)
            if previousTiles != tiles { coordinator.reportZoom(false, force: true) }
            return
        }
        if let zoomFrom {
            // The old layout is what the renderer holds now; keep it before
            // the update replaces it.
            coordinator.startZoom(from: zoomFrom, in: view, beforeUpdate: renderer.beginZoom())
        }
        let updated = coordinator.updateRenderer(
            renderer, tiles: tiles, palette: palette, dark: dark,
            snapshot: snapshot, mode: mode, colourOf: colourOf)
        coordinator.reportDropped(renderer.droppedTileCount)
        if zoomFrom == nil && !coordinator.player.isRunning && previousTiles != tiles {
            coordinator.reportZoom(false, force: true)
        }
        if updated || zoomFrom != nil { nsView.needsDisplay = true }
    }

    /// A virtual old-layout window that makes the existing zoom transform
    /// shrink the old root into its tile in the returned-to parent layout
    /// (or, if the new root is a tile of the old layout, that tile's rect).
    /// Nil unless both layouts fill the same bounds: after a resize the old
    /// rects describe a viewport that no longer exists, the case
    /// `cancelPendingZoom` covers for a recorded descend.
    static func navigationZoomRect(old: [Tile], new: [Tile], viewport: CGRect) -> CGRect? {
        guard let oldFirst = old.first, let newFirst = new.first, oldFirst.rect == newFirst.rect else { return nil }
        let oldRoot = oldFirst.node, newRoot = newFirst.node
        guard oldRoot != newRoot, oldRoot != Tile.noNode, newRoot != Tile.noNode,
            viewport.width > 0, viewport.height > 0 else { return nil }
        if let target = old.first(where: { $0.node == newRoot }) { return target.rect }
        guard let target = new.first(where: { $0.node == oldRoot }),
            target.rect.width > 0, target.rect.height > 0 else { return nil }
        let sx = target.rect.width / viewport.width
        let sy = target.rect.height / viewport.height
        return CGRect(
            x: viewport.minX + (viewport.minX - target.rect.minX) / sx,
            y: viewport.minY + (viewport.minY - target.rect.minY) / sy,
            width: viewport.width / sx, height: viewport.height / sy)
    }

    /// An event's location in the tiles' coordinates (top-left origin).
    /// The views are not flipped (so their layers draw as before); the y
    /// axis is turned over here instead.
    @MainActor
    static func tilePoint(_ event: NSEvent, in view: NSView) -> CGPoint {
        TreemapInteraction.tilePoint(view.convert(event.locationInWindow, from: nil), viewHeight: view.bounds.height)
    }

    /// Mouse tracking for the views that forward pointer and key events to
    /// a `TreemapInteraction`.
    @MainActor
    static func installTracking(on view: NSView) {
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: view, userInfo: nil))
    }

    final class InteractiveMTKView: MTKView {
        weak var interaction: TreemapInteraction?
        var jetsamMenu: JetsamContextMenu?
        override func menu(for event: NSEvent) -> NSMenu? {
            guard interaction?.selectForContext(at: TreemapView.tilePoint(event, in: self)) == true else { return nil }
            return jetsamMenu?.make()
        }

        override init(frame: CGRect, device: MTLDevice?) {
            super.init(frame: frame, device: device)
            TreemapView.installTracking(on: self)
        }

        required init(coder: NSCoder) { fatalError("InteractiveMTKView is not decoded from a nib") }

        override var acceptsFirstResponder: Bool { true }
        override func mouseMoved(with event: NSEvent) { interaction?.hover(at: TreemapView.tilePoint(event, in: self)) }
        override func mouseExited(with event: NSEvent) { interaction?.hover(at: nil) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            interaction?.press(at: TreemapView.tilePoint(event, in: self))
        }
        override func mouseUp(with event: NSEvent) { interaction?.release(at: TreemapView.tilePoint(event, in: self)) }
        override func keyDown(with event: NSEvent) {
            guard let k = TreemapInteraction.Key(event), interaction?.key(k) == true else {
                return super.keyDown(with: event)
            }
        }
    }

    /// The no-Metal view: draws the tiles with `CGTreemapRenderer` into its
    /// layer. It re-renders only when what it would draw changes (tiles, the
    /// colour index of each tile, palette, light/dark, size, backing scale),
    /// on `set`, `layout` and `viewDidChangeBackingProperties`.
    final class FallbackView: NSView {
        /// Everything a render depends on.
        private struct Key: Equatable {
            var tiles: [Tile]
            var indices: [UInt16]
            var palette: [SIMD4<Float>]
            var dark: Bool
            var size: CGSize
            var scale: CGFloat
        }

        private var tiles: [Tile] = []
        private var palette: [SIMD4<Float>] = [SIMD4(0, 0, 0, 1)]
        private var indices: [UInt16] = []
        private var inputSnapshot: Snapshot?
        private var inputMode: ColourMode?
        private var dark = false
        private var lastKey: Key?
        weak var interaction: TreemapInteraction?
        var jetsamMenu: JetsamContextMenu?
        override func menu(for event: NSEvent) -> NSMenu? {
            guard interaction?.selectForContext(at: TreemapView.tilePoint(event, in: self)) == true else { return nil }
            return jetsamMenu?.make()
        }
        /// How many times the image has been rendered (for tests).
        private(set) var renderCount = 0
        /// Overrides the window's backing scale (for tests).
        var scaleOverride: CGFloat? {
            didSet { redraw() }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            TreemapView.installTracking(on: self)
        }

        required init?(coder: NSCoder) { fatalError("FallbackView is not decoded from a nib") }

        override var acceptsFirstResponder: Bool { true }
        override func mouseMoved(with event: NSEvent) { interaction?.hover(at: TreemapView.tilePoint(event, in: self)) }
        override func mouseExited(with event: NSEvent) { interaction?.hover(at: nil) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            interaction?.press(at: TreemapView.tilePoint(event, in: self))
        }
        override func mouseUp(with event: NSEvent) { interaction?.release(at: TreemapView.tilePoint(event, in: self)) }
        override func keyDown(with event: NSEvent) {
            guard let k = TreemapInteraction.Key(event), interaction?.key(k) == true else {
                return super.keyDown(with: event)
            }
        }

        func set(tiles: [Tile], palette: [SIMD4<Float>], colourOf: @escaping (Tile) -> UInt16, dark: Bool,
                 snapshot: Snapshot? = nil, mode: ColourMode? = nil) {
            if snapshot == nil || mode == nil || inputSnapshot !== snapshot || inputMode != mode
                || self.tiles != tiles || self.palette != palette || self.dark != dark {
                indices = tiles.map(colourOf)
            }
            inputSnapshot = snapshot
            inputMode = mode
            self.tiles = tiles
            self.palette = palette
            self.dark = dark
            redraw()
        }

        override func layout() {
            super.layout()
            redraw()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            redraw()
        }

        private func redraw() {
            guard let layer, bounds.width > 0, bounds.height > 0 else { return }
            let scale = scaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let key = Key(
                tiles: tiles, indices: indices, palette: palette, dark: dark,
                size: bounds.size, scale: scale)
            guard key != lastKey else { return }
            lastKey = key
            renderCount += 1
            let image = CGTreemapRenderer(clearColour: Palette.surface(dark: dark)).render(
                tiles: tiles, colours: palette, colourOf: { _ in 0 }, indices: indices, size: bounds.size, scale: scale)
            layer.contentsScale = scale
            layer.contentsGravity = .topLeft
            layer.contents = image
        }
    }

    /// The `MTKView`'s delegate; owns the renderer, the interaction and the
    /// running zoom.
    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: TreemapRenderer?
        let interaction = TreemapInteraction()
        let contextMenu = JetsamContextMenu()
        private(set) var player = ZoomPlayer()
        var onZoomChanged: ((Bool) -> Void)?
        var onDroppedTiles: ((Int) -> Void)?
        private var lastDropped: Int?
        private var reportedZoom = false

        private struct InputKey: Equatable {
            var tiles: [Tile]
            var palette: [SIMD4<Float>]
            var dark: Bool
            var mode: ColourMode
        }
        private var inputKey: InputKey?
        // Retaining the owner prevents ObjectIdentifier reuse and also keeps
        // the previous colour source alive until it is replaced.
        private var inputSnapshot: Snapshot?

        @discardableResult
        func updateRenderer(
            _ renderer: TreemapRenderer, tiles: [Tile], palette: [SIMD4<Float>], dark: Bool,
            snapshot: Snapshot?, mode: ColourMode?, colourOf: (Tile) -> UInt16
        ) -> Bool {
            let next = mode.map { InputKey(tiles: tiles, palette: palette, dark: dark, mode: $0) }
            if let snapshot, let next, inputSnapshot === snapshot, inputKey == next { return false }
            let timing = FrameTimer.shared.begin("inputs", tiles: tiles.count)
            defer { FrameTimer.shared.end(timing) }
            renderer.clearColour = Palette.surface(dark: dark)
            renderer.update(tiles: tiles, colourOf: colourOf, palette: palette)
            inputSnapshot = snapshot
            inputKey = next
            return true
        }

        func reportDropped(_ count: Int) {
            guard count != lastDropped else { return }
            lastDropped = count
            let report = onDroppedTiles
            Task { @MainActor in report?(count) }
        }

        func reportZoom(_ running: Bool, force: Bool = false) {
            guard force || running != reportedZoom else { return }
            reportedZoom = running
            let report = onZoomChanged
            Task { @MainActor in report?(running) }
        }

        /// Starts the zoom from `rect` (old-layout points) if the renderer
        /// kept the old layout (`began`); either way any running zoom stops.
        func startZoom(from rect: CGRect, in view: MTKView, beforeUpdate began: Bool) {
            guard began,
                player.start(
                    from: rect, viewport: CGRect(origin: .zero, size: view.bounds.size),
                    now: CACurrentMediaTime())
            else { return stopZoom(view) }
            // Frame by frame until it finishes.
            reportZoom(true)
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        }

        private func stopZoom(_ view: MTKView) {
            reportZoom(false, force: true)
            player.cancel()
            renderer?.endZoom()
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.needsDisplay = true
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // A descend not yet laid out must not zoom the resized layout.
            interaction.cancelPendingZoom()
            player.resize(to: CGRect(origin: .zero, size: view.bounds.size))
            if !player.isRunning, renderer?.isZooming == true { stopZoom(view) }
            view.needsDisplay = true
        }

        public func draw(in view: MTKView) {
            guard let renderer else { return }
            if renderer.isZooming {
                if let f = player.frame(now: CACurrentMediaTime()) {
                    FrameTimer.shared.frameStarted()
                    return renderer.drawZoom(in: view, oldTransform: f.transform, alpha: f.alpha)
                }
                stopZoom(view)
            }
            renderer.draw(in: view)
        }
    }
}
