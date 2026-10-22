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

/// What `TreemapView` does with the pointer and the keyboard (spec §8), apart
/// from drawing: hover, click and keys in, navigation and hover reports out.
/// Points are in the tiles' coordinates (points, origin top-left); the views
/// convert with `tilePoint(_:viewHeight:)`.
///
/// * Hover hit-tests the tiles and reports the tile index (or nil) to
///   `onHover` when it changes; the caller turns it into an `InspectorInfo`
///   with `inspect(tileAt:in:snapshot:)`. When new tiles arrive, the last
///   pointer position is hit-tested again, so Return works without moving
///   the mouse.
/// * A click (`press` then `release` on the same tile) selects the node and
///   descends one level into the current root's readable child containing it.
///   A file directly under the current root only selects.
///   Aggregates/placeholders and release over a different tile do nothing. Return descends
///   into the first descendable of the hovered tile and the first tile
///   flagged selected. ⌘↑ ascends; ← / → move to the previous / next sibling.
/// * A descend records the clicked rect. The navigator's owner lays out the
///   new root and hands the view the new tiles; `setTiles` then returns that
///   rect once, which is what the view zooms from, but only if the tiles are
///   rooted at the node descended into. Any other tiles change, and any other move (ascend, a
///   sibling, a different navigator, a resize via `cancelPendingZoom`) drops
///   the rect, so a later tiles change never zooms from a stale one.
@MainActor
final class TreemapInteraction {
    enum Key {
        case ascend, descend, previousSibling, nextSibling

        /// The key an event stands for, from its special key (no key codes).
        init?(_ event: NSEvent) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.specialKey {
            case .upArrow? where mods.contains(.command): self = .ascend
            case .carriageReturn?, .enter?: self = .descend
            case .leftArrow? where !mods.contains(.command): self = .previousSibling
            case .rightArrow? where !mods.contains(.command): self = .nextSibling
            default: return nil
            }
        }
    }

    /// A point in an unflipped view's coordinates (origin bottom-left, as
    /// AppKit reports events) in the tiles' coordinates (origin top-left).
    /// The views stay unflipped so that nothing about their layers' geometry
    /// changes; the flip happens only here.
    static func tilePoint(_ p: CGPoint, viewHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: viewHeight - p.y)
    }

    var navigator: Navigator? {
        didSet { if oldValue !== navigator { pendingZoom = nil } }
    }
    var selection: Selection?
    var onHover: ((Int?) -> Void)?
    var onPointer: ((Int?, CGPoint?) -> Void)?
    var onDismissCallout: ((HoverCallout.Event) -> Void)?
    private(set) var tiles: [Tile] = []
    private(set) var hovered: Int?
    /// What `onHover` was last told.
    private var reported: Int?
    private var pointer: CGPoint?
    private var pressed: Int?
    private var hitTester = HitTester()
    /// The rect a descend started from, and the node it descended into.
    private(set) var pendingZoom: (rect: CGRect, target: UInt32)?

    /// Installs the tiles to hit-test. If they differ from the last ones, a
    /// descend is pending, and they are the layout of the node it descended
    /// into (their first tile is the layout root), returns the rect it
    /// started from; the pending descend is dropped either way.
    func setTiles(_ new: [Tile]) -> CGRect? {
        guard new != tiles else { return nil }
        let zoom = pendingZoom.flatMap { new.first?.node == $0.target ? $0.rect : nil }
        pendingZoom = nil
        pressed = nil
        tiles = new
        hitTester.invalidate()
        hovered = pointer.flatMap { hitTester.tile(at: $0, in: tiles) }
        // Reported after the view update that installed the tiles: the
        // report may change SwiftUI state, which an update must not do.
        Task { @MainActor [weak self] in self?.report() }
        return zoom
    }

    /// Drops a recorded descend rect (the view resized, so it is stale).
    func cancelPendingZoom() { pendingZoom = nil }

    /// The pointer is at `p`, or left the view.
    func hover(at p: CGPoint?) {
        pointer = p
        hovered = p.flatMap { hitTester.tile(at: $0, in: tiles) }
        onPointer?(hovered, p)
        report()
    }

    /// The button went down at `p`.
    func selectForContext(at point: CGPoint) -> Bool {
        onDismissCallout?(.click)
        guard let index = hitTester.tile(at: point, in: tiles) else { return false }
        let node = tiles[index].node
        guard node != Tile.noNode else { return false }
        if selection?.nodes.contains(node) != true { selection?.nodes = [node] }
        return true
    }

    func press(at p: CGPoint) {
        onDismissCallout?(.click)
        pressed = hitTester.tile(at: p, in: tiles)
    }

    /// The button came up at `p`: a click if it is over the tile it went
    /// down on. True if it descended.
    @discardableResult
    func release(at p: CGPoint) -> Bool {
        defer { pressed = nil }
        guard let i = hitTester.tile(at: p, in: tiles), i == pressed else { return false }
        let node = tiles[i].node
        if node != Tile.noNode { selection?.nodes = [node] }
        return descendOneLevel(containing: node)
    }

    /// True if the key was one of ours (handled, even if it changed nothing).
    @discardableResult
    func key(_ k: Key) -> Bool {
        guard let nav = navigator else { return false }
        switch k {
        case .ascend:
            pendingZoom = nil
            nav.ascend()
        case .previousSibling:
            pendingZoom = nil
            nav.sibling(-1)
        case .nextSibling:
            pendingZoom = nil
            nav.sibling(1)
        case .descend:
            let selected = tiles.firstIndex { $0.flags & Tile.Flag.selected != 0 }
            if let i = [hovered, selected].compactMap({ $0 }).first(where: { nav.canDescend(into: tiles[$0].node) }) {
                descend(into: i)
            }
        }
        return true
    }

    @discardableResult
    private func descendOneLevel(containing node: UInt32) -> Bool {
        guard let nav = navigator, node != Tile.noNode, node != nav.root,
              Int(node) < nav.snapshot.nodes.count else { return false }
        var child = node
        while nav.snapshot.nodes[Int(child)].parent != nav.root {
            child = nav.snapshot.nodes[Int(child)].parent
            guard child != Tile.noNode, Int(child) < nav.snapshot.nodes.count else { return false }
        }
        guard nav.canDescend(into: child) else { return false }
        pendingZoom = tiles.first { $0.node == child }.map { (rect: $0.rect, target: child) }
        nav.descend(into: child)
        return true
    }

    @discardableResult
    private func descend(into i: Int) -> Bool {
        guard let nav = navigator, nav.canDescend(into: tiles[i].node) else { return false }
        pendingZoom = (tiles[i].rect, tiles[i].node)
        nav.descend(into: tiles[i].node)
        return true
    }

    private func report() {
        guard hovered != reported else { return }
        reported = hovered
        onHover?(hovered)
    }
}
