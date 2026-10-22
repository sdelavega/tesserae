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

/// The surface gap does not separate folders; point contacts do.
public func touches(_ a: CGRect, _ b: CGRect) -> Bool {
    let vertical = abs(a.maxX - b.minX) <= 3 || abs(b.maxX - a.minX) <= 3
    let horizontal = abs(a.maxY - b.minY) <= 3 || abs(b.maxY - a.minY) <= 3
    return (vertical && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 1)
        || (horizontal && min(a.maxX, b.maxX) - max(a.minX, b.minX) > 1)
}

/// Adjacency-aware greedy colouring, independent of appearance and paint order.
public enum FolderSlots {
    public struct Pair: Hashable, Sendable {
        public let low: Int
        public let high: Int
        public init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }
    public static let conflicts: Set<Pair> = Set([
        Pair(1, 7), Pair(2, 4), Pair(2, 5), Pair(2, 6), Pair(2, 8),
        Pair(3, 5), Pair(3, 6), Pair(3, 8), Pair(4, 8), Pair(5, 8), Pair(6, 8),
    ])
    private static let conflictMasks: [Int] = (1...8).map { slot in
        (1...8).reduce(0) { $0 | (conflicts.contains(Pair(slot, $1)) ? 1 << ($1 - 1) : 0) }
    }

    public static func assign(rootChildren: [(node: UInt32, rect: CGRect, bytes: UInt64)]) -> [UInt32: Int] {
        let children = rootChildren.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.node < $1.node }
        let count = children.count
        guard count > 0 else { return [:] }
        let neighbours = adjacency(children.map(\.rect))
        var assigned = [Int](repeating: 0, count: count)
        var result: [UInt32: Int] = [:]
        result.reserveCapacity(count)
        for i in children.indices {
            var used = 0, blocked = 0
            for j in neighbours[i] {
                let slot = assigned[j]
                used |= 1 << (slot - 1)
                blocked |= conflictMasks[slot - 1]
            }
            let safe = (~(used | blocked)) & 255
            let distinct = (~used) & 255
            let available = safe != 0 ? safe : distinct
            let slot = available == 0 ? 1 : available.trailingZeroBitCount + 1
            assigned[i] = slot
            result[children[i].node] = slot
        }
        return result
    }
    /// Earlier neighbours in the caller's order, using the edge-window fast path.
    static func adjacency(_ rects: [CGRect]) -> [[Int]] {
        let count = rects.count
        var neighbours = [[Int]](repeating: [], count: count)
        // Match opposing edges in sorted coordinate windows. This avoids an
        // all-pairs scan for the sparse adjacency graph of a treemap.
        for vertical in [true, false] {
            let starts = rects.indices.sorted {
                let a = vertical ? rects[$0].minX : rects[$0].minY
                let b = vertical ? rects[$1].minX : rects[$1].minY
                return a != b ? a < b : $0 < $1
            }
            let ends = rects.indices.sorted {
                let a = vertical ? rects[$0].maxX : rects[$0].maxY
                let b = vertical ? rects[$1].maxX : rects[$1].maxY
                return a != b ? a < b : $0 < $1
            }
            var lower = 0
            for i in ends {
                let edge = vertical ? rects[i].maxX : rects[i].maxY
                while lower < count {
                    let r = rects[starts[lower]]
                    if (vertical ? r.minX : r.minY) >= edge - 3 { break }
                    lower += 1
                }
                var k = lower
                while k < count {
                    let j = starts[k], r = rects[j]
                    if (vertical ? r.minX : r.minY) > edge + 3 { break }
                    if i != j {
                        let a = rects[i]
                        let overlap = vertical ? min(a.maxY, r.maxY) - max(a.minY, r.minY)
                            : min(a.maxX, r.maxX) - max(a.minX, r.minX)
                        if overlap > 1 { neighbours[max(i, j)].append(min(i, j)) }
                    }
                    k += 1
                }
            }
        }
        return neighbours
    }

}

/// Prepared once after layout, then shared by Metal, CoreGraphics and labels.
public struct FolderColours {
    public let slots: [UInt32: Int]
    public let rootChildren: [UInt32: UInt32]

    public init(tiles: [Tile], root: UInt32, source: some TreeSource) {
        var children: [(node: UInt32, rect: CGRect, bytes: UInt64)] = []
        var ancestry: [UInt32: UInt32] = [:]
        ancestry.reserveCapacity(tiles.count)
        // Layout is parent-before-child, including directories without labels.
        for tile in tiles where tile.node != Tile.noNode {
            if tile.parent == root, source.isDirectory(tile.node), !tile.isPermissionDenied {
                children.append((tile.node, tile.rect, source.allocated(tile.node)))
                ancestry[tile.node] = tile.node
            } else if let child = ancestry[tile.parent] {
                ancestry[tile.node] = child
            }
        }
        slots = FolderSlots.assign(rootChildren: children)
        rootChildren = ancestry
    }
}
