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

/// Level-of-detail constants (spec §8).
public struct LayoutParameters: Sendable {
    /// A directory tile whose smaller side is below this is terminal.
    public var subdivideMin: CGFloat = 24
    /// A child whose area would fall below this starts the aggregated tail.
    public var cullArea: CGFloat = 16
    /// At most this many tiles are emitted.
    public var budget = 50_000

    public init(subdivideMin: CGFloat = 24, cullArea: CGFloat = 16, budget: Int = 50_000) {
        self.subdivideMin = subdivideMin
        self.cullArea = cullArea
        self.budget = budget
    }
}

/// Lay out the subtree under `root` in `bounds` (spec §8).
///
/// Bruls–Huizing–van Wijk squarified layout over children that arrive sorted
/// by size descending, so nothing is sorted here, with level of detail:
///
/// * Every emitted tile is a node's whole share of its parent's rect; a
///   directory that is subdivided keeps its own tile (painted first, so the
///   renderer can draw its nesting border) and its children tile that rect
///   exactly, without padding.
/// * A directory tile whose smaller side is below `subdivideMin` is terminal.
/// * Zero-size children get no area, so they are left out of the layout
///   entirely: no tile, and not counted in an aggregate. A zero-size root
///   (or subtree) emits nothing, except for permission-denied directories.
/// * The first positive child whose share of the parent's area is below
///   `cullArea` starts the tail; it and every positive child after it
///   collapse into one aggregate tile (`Tile.noNode`, `Flag.aggregated`) of
///   their combined area, placed after the kept children. Because children
///   are sorted, the tail is a suffix and the cut is a binary search, not a
///   scan. The aggregate is emitted even when it is below `cullArea`, so the
///   parent stays covered.
/// * Permission-denied directories (0 bytes, unreadable) are not sizes but
///   must stay visible (spec §8 "Status colours"; ruling T6-2). Each gets a
///   placeholder tile of area `cullArea`, flagged `permDenied`, laid after
///   its sized siblings; more than `maxDeniedTiles` collapse into one
///   placeholder flagged `permDenied | aggregated` that counts them. The
///   sized children share the parent's area minus the placeholders'. An
///   unreadable root is one placeholder filling `bounds`. Finding them scans
///   the zero-size suffix of each laid-out sibling set.
/// * No more than `budget` tiles are emitted. Directories are subdivided
///   breadth-first, so the budget cuts the deepest levels first; a sibling
///   set that does not fit the remaining budget is cut shorter (placeholders
///   first collapse to one), its excess joining the aggregate, and a parent
///   is never left half covered.
///
/// Output is paint order: every parent precedes its children.
public func squarify(
    _ src: some TreeSource, root: UInt32, in bounds: CGRect, _ p: LayoutParameters = .init()
) -> [Tile] {
    precondition(p.subdivideMin > 0, "LayoutParameters.subdivideMin must be positive")
    precondition(p.cullArea > 0, "LayoutParameters.cullArea must be positive")
    precondition(p.budget >= 0, "LayoutParameters.budget must not be negative")
    let boundsArea = Double(bounds.size.width) * Double(bounds.size.height)
    guard p.budget > 0,
        bounds.origin.x.isFinite, bounds.origin.y.isFinite,
        bounds.size.width.isFinite, bounds.size.height.isFinite,
        bounds.size.width > 0, bounds.size.height > 0,
        boundsArea.isFinite, boundsArea > 0
    else { return [] }

    let rootBytes = src.allocated(root)
    if rootBytes == 0 && src.isPermissionDenied(root) {
        return [Tile(rect: bounds, node: root, depth: 0, flags: Tile.Flag.permDenied)]
    }
    guard rootBytes > 0 || src.isDirectory(root) else { return [] }

    var tiles: [Tile] = []
    tiles.reserveCapacity(min(p.budget, 4096))
    tiles.append(Tile(rect: bounds, node: root, depth: 0))

    // Directories waiting to be subdivided, in breadth-first order.
    var queue: [(node: UInt32, rect: CGRect, depth: UInt8)] = []
    if src.isDirectory(root) && min(bounds.width, bounds.height) >= p.subdivideMin {
        queue.append((root, bounds, 0))
    }
    var head = 0
    var row = SquarifyScratch()
    while head < queue.count {
        let (node, rect, depth) = queue[head]
        head += 1
        let remaining = p.budget - tiles.count
        if remaining <= 0 { break }
        layoutChildren(
            src, of: node, in: rect, depth: depth, remaining: remaining, p,
            scratch: &row, tiles: &tiles, queue: &queue)
    }
    // A zero-size root shows only its unreadable children, if any.
    if rootBytes == 0 && tiles.count == 1 { return [] }
    return tiles
}

/// More permission-denied siblings than this share one placeholder tile.
let maxDeniedTiles = 16

/// Reused buffers for one sibling set.
struct SquarifyScratch {
    var areas: [Double] = []
    var rects: [CGRect] = []
    var suffix: [Double] = []
    var denied: [UInt32] = []
}

/// The first index in `range` for which `isBelow` holds, given that it holds
/// for a suffix of `range` (children are sorted descending).
@inline(__always)
private func firstBelow(_ range: Range<UInt32>, _ isBelow: (UInt32) -> Bool) -> UInt32 {
    var lo = range.lowerBound
    var hi = range.upperBound
    while lo < hi {
        let mid = lo + (hi - lo) / 2
        if isBelow(mid) { hi = mid } else { lo = mid + 1 }
    }
    return lo
}

/// Emit the children of `node`, which occupies `rect`, and queue the
/// directories among them that are big enough to subdivide.
private func layoutChildren(
    _ src: some TreeSource, of node: UInt32, in rect: CGRect, depth: UInt8, remaining: Int,
    _ p: LayoutParameters, scratch: inout SquarifyScratch, tiles: inout [Tile],
    queue: inout [(node: UInt32, rect: CGRect, depth: UInt8)]
) {
    let range = src.children(node)
    let total = src.allocated(node)
    guard !range.isEmpty else { return }
    let area = Double(rect.width) * Double(rect.height)
    guard area.isFinite, area > 0 else { return }
    let cull = Double(p.cullArea)

    // Positive-size children are a prefix; zero-size ones are left out,
    // except that unreadable directories among them get placeholders.
    let positiveEnd = total > 0 ? firstBelow(range) { src.allocated($0) == 0 } : range.lowerBound
    let positiveCount = Int(positiveEnd - range.lowerBound)
    scratch.denied.removeAll(keepingCapacity: true)
    for c in positiveEnd..<range.upperBound where src.isPermissionDenied(c) {
        scratch.denied.append(c)
    }
    let deniedCount = scratch.denied.count
    guard positiveCount > 0 || deniedCount > 0 else { return }

    // Placeholder tiles: one per unreadable folder, or one for them all.
    var deniedTiles = deniedCount <= maxDeniedTiles ? deniedCount : 1
    // Placeholders never take more than half the parent (only reachable
    // with parameters far from the defaults: a subdivided rect is at least
    // subdivideMin², and 16 placeholders of cullArea fit in half of 24²).
    if Double(deniedTiles) * cull > area / 2 { deniedTiles = cull > area / 2 ? 0 : min(deniedTiles, 1) }

    // The cull, over the area the placeholders leave.
    var keepEnd = positiveEnd
    if positiveCount > 0 {
        let scale = (area - Double(deniedTiles) * cull) / Double(total)
        keepEnd = firstBelow(range.lowerBound..<positiveEnd) { Double(src.allocated($0)) * scale < cull }
    }
    var needed = Int(keepEnd - range.lowerBound) + (keepEnd < positiveEnd ? 1 : 0) + deniedTiles
    if needed > remaining {
        // Collapse the placeholders, then cut the prefix shorter so it plus
        // the aggregate fit; a set that would keep no sized child is not
        // worth subdividing.
        deniedTiles = min(deniedTiles, 1)
        needed = Int(keepEnd - range.lowerBound) + (keepEnd < positiveEnd ? 1 : 0) + deniedTiles
        if needed > remaining {
            if positiveCount == 0 { return }
            guard remaining >= 2 + deniedTiles else { return }
            keepEnd = range.lowerBound + UInt32(remaining - 1 - deniedTiles)
        }
    }
    let deniedArea = Double(deniedTiles) * cull
    let sizedArea = area - deniedArea

    var keptBytes: UInt64 = 0
    scratch.areas.removeAll(keepingCapacity: true)
    for c in range.lowerBound..<keepEnd {
        let s = src.allocated(c)
        keptBytes += s
        scratch.areas.append(Double(s))
    }
    // The tail's bytes from the rollup: a directory's size is the sum over
    // its children, so this is exact without touching the tail.
    assert(total >= keptBytes, "directory smaller than its kept children: rollup broken")
    let tailBytes = total > keptBytes ? total - keptBytes : 0
    let tailCount = positiveEnd - keepEnd
    let hasTail = tailCount > 0 && tailBytes > 0
    if hasTail { scratch.areas.append(Double(tailBytes)) }

    let sum = Double(keptBytes) + (hasTail ? Double(tailBytes) : 0)
    if sum > 0 {
        for i in scratch.areas.indices { scratch.areas[i] *= sizedArea / sum }
    }
    for _ in 0..<deniedTiles { scratch.areas.append(cull) }
    // With no sized children, empty space fills the rest (never emitted).
    if sum == 0 { scratch.areas.append(sizedArea) }
    squarifyRow(scratch.areas, in: rect, into: &scratch.rects, suffix: &scratch.suffix)

    let keptCount = Int(keepEnd - range.lowerBound)
    let aggregateIndex = hasTail ? keptCount : -1
    let deniedStart = keptCount + (hasTail ? 1 : 0)
    let childDepth = depth == UInt8.max ? depth : depth + 1
    for (i, r) in scratch.rects.enumerated() {
        if i < keptCount {
            let c = range.lowerBound + UInt32(i)
            tiles.append(Tile(rect: r, node: c, depth: childDepth))
            if src.isDirectory(c) && min(r.width, r.height) >= p.subdivideMin {
                queue.append((c, r, childDepth))
            }
        } else if i == aggregateIndex {
            tiles.append(
                Tile(
                    rect: r, node: Tile.noNode, depth: childDepth, flags: Tile.Flag.aggregated,
                    aggregateCount: tailCount, aggregateBytes: tailBytes))
        } else if i < deniedStart + deniedTiles {
            if deniedTiles == deniedCount {
                tiles.append(
                    Tile(rect: r, node: scratch.denied[i - deniedStart], depth: childDepth, flags: Tile.Flag.permDenied))
            } else {
                tiles.append(
                    Tile(
                        rect: r, node: Tile.noNode, depth: childDepth,
                        flags: Tile.Flag.permDenied | Tile.Flag.aggregated,
                        aggregateCount: UInt32(deniedCount), aggregateBytes: 0))
            }
        }
    }
}

/// The worst aspect ratio of a row of total area `sum` whose largest and
/// smallest items are `maxA` and `minA`, laid along a side of length `side`.
@inline(__always)
private func worst(_ sum: Double, _ minA: Double, _ maxA: Double, _ side: Double) -> Double {
    let s2 = sum * sum
    let w2 = side * side
    return max(w2 * maxA / s2, s2 / (w2 * minA))
}

/// Squarify `areas` (positive, summing to the area of `rect`) into `rect`.
/// Each item's rect is computed from its own area (thickness × area ÷
/// thickness), never as "whatever remains", so even a tile a billionth of
/// its parent keeps its proportion; the rects then meet and cover `rect` to
/// within rounding. The free part of the rect is resized from the area
/// still to place (a suffix sum, free of cancellation), not by subtraction,
/// so it never shrinks to zero while items remain.
func squarifyRow(_ areas: [Double], in rect: CGRect, into out: inout [CGRect], suffix: inout [Double]) {
    out.removeAll(keepingCapacity: true)
    suffix.removeAll(keepingCapacity: true)
    suffix.append(contentsOf: repeatElement(0, count: areas.count + 1))
    for k in areas.indices.reversed() { suffix[k] = suffix[k + 1] + areas[k] }
    var x = Double(rect.minX)
    var y = Double(rect.minY)
    var w = Double(rect.width)
    var h = Double(rect.height)
    var i = 0
    let n = areas.count
    while i < n {
        let side = min(w, h)
        var sum = areas[i]
        var minA = areas[i]
        var maxA = areas[i]
        var current = worst(sum, minA, maxA, side)
        var j = i + 1
        while j < n {
            let a = areas[j]
            let nextSum = sum + a
            let nextMin = min(minA, a)
            let nextMax = max(maxA, a)
            let next = worst(nextSum, nextMin, nextMax, side)
            if next > current { break }
            sum = nextSum
            minA = nextMin
            maxA = nextMax
            current = next
            j += 1
        }
        if w >= h {
            // A column on the left, items stacked top to bottom.
            let thick = sum / h
            var cy = y
            for k in i..<j {
                let len = areas[k] / thick
                out.append(CGRect(x: x, y: cy, width: thick, height: len))
                cy += len
            }
            x += thick
            w = suffix[j] / h
        } else {
            // A row along the top, items left to right.
            let thick = sum / w
            var cx = x
            for k in i..<j {
                let len = areas[k] / thick
                out.append(CGRect(x: cx, y: y, width: len, height: thick))
                cx += len
            }
            y += thick
            h = suffix[j] / w
        }
        i = j
    }
}
