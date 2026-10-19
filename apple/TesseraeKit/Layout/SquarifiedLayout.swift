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
///   (or subtree) emits nothing.
/// * The first positive child whose share of the parent's area is below
///   `cullArea` starts the tail; it and every positive child after it
///   collapse into one aggregate tile (`Tile.noNode`, `Flag.aggregated`) of
///   their combined area, placed last. Because children are sorted, the tail
///   is a suffix and the cut is a binary search, not a scan.
/// * No more than `budget` tiles are emitted. Directories are subdivided
///   breadth-first, so the budget cuts the deepest levels first; a sibling
///   set that does not fit the remaining budget is cut shorter, its excess
///   joining the aggregate, and a parent is never left half covered.
///
/// Output is paint order: every parent precedes its children.
public func squarify(
    _ src: some TreeSource, root: UInt32, in bounds: CGRect, _ p: LayoutParameters = .init()
) -> [Tile] {
    guard p.budget > 0,
        bounds.origin.x.isFinite, bounds.origin.y.isFinite,
        bounds.size.width.isFinite, bounds.size.height.isFinite,
        bounds.size.width > 0, bounds.size.height > 0,
        src.allocated(root) > 0
    else { return [] }

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
    return tiles
}

/// Reused buffers for one sibling set.
struct SquarifyScratch {
    var areas: [Double] = []
    var rects: [CGRect] = []
    var suffix: [Double] = []
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
    guard !range.isEmpty, total > 0 else { return }

    // Positive-size children are a prefix; zero-size ones are left out.
    let positiveEnd = firstBelow(range) { src.allocated($0) == 0 }
    guard positiveEnd > range.lowerBound else { return }

    // The cull: the first child whose share of the area is below cullArea.
    let area = Double(rect.width) * Double(rect.height)
    let scale = area / Double(total)
    let cull = Double(p.cullArea)
    var keepEnd = firstBelow(range.lowerBound..<positiveEnd) { Double(src.allocated($0)) * scale < cull }
    let needed = Int(keepEnd - range.lowerBound) + (keepEnd < positiveEnd ? 1 : 0)
    if needed > remaining {
        // Cut the prefix shorter so it plus the aggregate fit the budget;
        // a set that would be a lone aggregate is not worth subdividing.
        guard remaining >= 2 else { return }
        keepEnd = range.lowerBound + UInt32(remaining - 1)
    }

    var keptBytes: UInt64 = 0
    scratch.areas.removeAll(keepingCapacity: true)
    for c in range.lowerBound..<keepEnd {
        let s = src.allocated(c)
        keptBytes += s
        scratch.areas.append(Double(s))
    }
    // The tail's bytes from the rollup: a directory's size is the sum over
    // its children, so this is exact without touching the tail.
    let tailBytes = total > keptBytes ? total - keptBytes : 0
    let tailCount = positiveEnd - keepEnd
    let hasTail = tailCount > 0 && tailBytes > 0
    if hasTail { scratch.areas.append(Double(tailBytes)) }

    let sum = Double(keptBytes) + (hasTail ? Double(tailBytes) : 0)
    for i in scratch.areas.indices { scratch.areas[i] *= area / sum }
    squarifyRow(scratch.areas, in: rect, into: &scratch.rects, suffix: &scratch.suffix)

    let keptCount = Int(keepEnd - range.lowerBound)
    let childDepth = depth == UInt8.max ? depth : depth + 1
    for (i, r) in scratch.rects.enumerated() {
        if i == keptCount {
            tiles.append(
                Tile(
                    rect: r, node: Tile.noNode, depth: childDepth, flags: Tile.Flag.aggregated,
                    aggregateCount: tailCount, aggregateBytes: tailBytes))
            continue
        }
        let c = range.lowerBound + UInt32(i)
        tiles.append(Tile(rect: r, node: c, depth: childDepth))
        if src.isDirectory(c) && min(r.width, r.height) >= p.subdivideMin {
            queue.append((c, r, childDepth))
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
