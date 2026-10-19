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

/// Which tile is under a point (spec §8 "Hit testing"): a linear scan of the
/// emitted tile list with a last-hit cache.
///
/// **Deepest match.** The layout emits tiles breadth-first, every parent
/// before its children, and tiles that are not ancestor and descendant are
/// disjoint. So the tiles containing a point form one ancestor chain in
/// array order, and the deepest is the *last* one: the scan runs from the end
/// and stops at the first hit. That holds for aggregates and for
/// permission-denied placeholders too, which follow their sized siblings
/// inside the parent's rect; an empty cell of a placeholder strip is covered
/// by no child, so it hits the parent, which is what is drawn there.
///
/// **Containment** is `CGRect.contains`: min edges in, max edges out, so a
/// point on a shared edge belongs to exactly one sibling.
///
/// **Cache.** After a scan the hit tile is checked once for descendants (a
/// later tile whose centre lies inside it; a non-descendant is disjoint from
/// it, so its centre cannot). A *leaf* hit is cached: while the pointer stays
/// inside it, later queries return it without scanning. The cache is keyed
/// on the tile itself and the list's length, which cannot tell every new
/// list from the old one: call `invalidate()` whenever the tiles change
/// (`TreemapInteraction.setTiles` does).
public struct HitTester {
    private var cached: (index: Int, tile: Tile, count: Int)?
    /// Full scans run so far (for tests).
    public private(set) var scanCount = 0

    public init() {}

    public mutating func invalidate() { cached = nil }

    public mutating func tile(at p: CGPoint, in tiles: [Tile]) -> Int? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        if let c = cached, c.count == tiles.count, c.index < tiles.count, tiles[c.index] == c.tile,
            c.tile.rect.contains(p)
        {
            return c.index
        }
        scanCount += 1
        cached = nil
        let (hit, leaf) = tiles.withUnsafeBufferPointer { buf -> (Int?, Bool) in
            // `CGRect.contains` without its standardising, on raw fields: the
            // layout's rects have non-negative sizes.
            @inline(__always) func inside(_ r: CGRect, _ x: CGFloat, _ y: CGFloat) -> Bool {
                x >= r.origin.x && x < r.origin.x + r.size.width && y >= r.origin.y
                    && y < r.origin.y + r.size.height
            }
            var i = buf.count - 1
            while i >= 0 && !inside(buf[i].rect, p.x, p.y) { i -= 1 }
            guard i >= 0 else { return (nil, false) }
            let r = buf[i].rect
            var j = i + 1
            while j < buf.count {
                let c = buf[j].rect
                if inside(r, c.origin.x + c.size.width / 2, c.origin.y + c.size.height / 2) { return (i, false) }
                j += 1
            }
            return (i, true)
        }
        guard let i = hit else { return nil }
        if leaf { cached = (i, tiles[i], tiles.count) }
        return i
    }
}
