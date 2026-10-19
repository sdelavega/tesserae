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
///
/// * Hover hit-tests the tiles and reports the tile index (or nil) to
///   `onHover` when it changes; the caller turns it into an `InspectorInfo`
///   with `inspect(tileAt:in:snapshot:)`.
/// * A click on a directory descends into it; on a file, an aggregate or a
///   placeholder it does nothing. Return descends into the hovered tile, or
///   failing that the first tile flagged selected. ⌘↑ ascends; ← / → move
///   to the previous / next sibling.
/// * A descend records the clicked rect. The navigator's owner lays out the
///   new root and hands the view the new tiles; `setTiles` then returns that
///   rect once, which is what the view zooms from.
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

    var navigator: Navigator?
    var onHover: ((Int?) -> Void)?
    private(set) var tiles: [Tile] = []
    private(set) var hovered: Int?
    private var hitTester = HitTester()
    private var pendingZoom: CGRect?

    /// Installs the tiles to hit-test. If they differ from the last ones and
    /// a descend is pending, returns the rect it started from (once).
    func setTiles(_ new: [Tile]) -> CGRect? {
        let zoom = pendingZoom
        guard new != tiles else { return nil }
        pendingZoom = nil
        tiles = new
        hitTester.invalidate()
        // Reported after the view update that installed the tiles: the
        // report may change SwiftUI state, which an update must not do.
        if hovered != nil {
            hovered = nil
            Task { @MainActor [weak self] in
                // Unless the pointer has hovered something since.
                if let self, self.hovered == nil { self.onHover?(nil) }
            }
        }
        return zoom
    }

    /// The pointer is at `p` (view points, origin top-left), or left the view.
    func hover(at p: CGPoint?) {
        setHovered(p.flatMap { hitTester.tile(at: $0, in: tiles) })
    }

    /// A click at `p`. True if it descended.
    @discardableResult
    func click(at p: CGPoint) -> Bool {
        guard let i = hitTester.tile(at: p, in: tiles) else { return false }
        return descend(into: i)
    }

    /// True if the key was one of ours (handled, even if it changed nothing).
    @discardableResult
    func key(_ k: Key) -> Bool {
        guard let nav = navigator else { return false }
        switch k {
        case .ascend: nav.ascend()
        case .previousSibling: nav.sibling(-1)
        case .nextSibling: nav.sibling(1)
        case .descend:
            if let i = hovered ?? tiles.firstIndex(where: { $0.flags & Tile.Flag.selected != 0 }) {
                descend(into: i)
            }
        }
        return true
    }

    @discardableResult
    private func descend(into i: Int) -> Bool {
        guard let nav = navigator, nav.canDescend(into: tiles[i].node) else { return false }
        pendingZoom = tiles[i].rect
        nav.descend(into: tiles[i].node)
        return true
    }

    private func setHovered(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        onHover?(i)
    }
}
