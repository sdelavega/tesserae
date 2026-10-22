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
import TesseraeFFI
import XCTest

@testable import TesseraeKit

/// Squarified layout with level-of-detail (spec §8), property-tested over
/// seeded random trees (spec §12 "Layout — property tests").
final class LayoutTests: XCTestCase {
    static let seeds: [UInt64] = Array(1...500)
    let p = LayoutParameters()

    // MARK: Helpers

    /// A random bounds rect: mostly window-like, some thin strips, some tiny.
    static func bounds(_ seed: UInt64) -> CGRect {
        var rng = SplitMix64(seed: seed ^ 0xB0B0_B0B0)
        let x = rng.unit() * 100
        let y = rng.unit() * 100
        let kind = rng.unit()
        if kind < 0.6 {
            return CGRect(x: x, y: y, width: 300 + rng.unit() * 2200, height: 200 + rng.unit() * 1400)
        } else if kind < 0.8 {
            return CGRect(x: x, y: y, width: 400 + rng.unit() * 2000, height: 1 + rng.unit() * 60)
        } else {
            return CGRect(x: x, y: y, width: 1 + rng.unit() * 120, height: 1 + rng.unit() * 120)
        }
    }

    /// The depth of a child of a tile at depth `d`: one more, saturating at
    /// 255 as the layout's does. Never `d + 1` on the `UInt8` (final review C1).
    static func childDepth(_ d: UInt8) -> UInt8 { d == .max ? d : d + 1 }

    /// A tile and the tiles laid out inside it (its children and its aggregate).
    struct Group {
        var parent: Tile
        var parentIndex: Int
        var children: [(tile: Tile, index: Int)]
    }

    /// Groups tiles by parent: a node tile by the tree's parent link, an
    /// aggregate by its `Tile.parent` (whose tile must contain its centre).
    static func groups(_ tiles: [Tile], _ t: SyntheticTree, file: StaticString = #filePath, line: UInt = #line) -> [Group] {
        var byNode: [UInt32: Int] = [:]
        for (i, tile) in tiles.enumerated() where !tile.isAggregate {
            XCTAssertNil(byNode[tile.node], "node emitted twice", file: file, line: line)
            byNode[tile.node] = i
        }
        var groups: [Int: Group] = [:]
        for (i, tile) in tiles.enumerated() {
            let parentIndex: Int?
            if tile.isAggregate {
                let c = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
                parentIndex = byNode[tile.parent]
                XCTAssertNotNil(parentIndex, "aggregate with no parent tile", file: file, line: line)
                if let pi = parentIndex {
                    XCTAssertTrue(tiles[pi].rect.contains(c), "aggregate outside its parent", file: file, line: line)
                }
            } else if tile.node == t.rootIndex {
                parentIndex = nil
            } else {
                parentIndex = byNode[t.parents[Int(tile.node)]]
                XCTAssertNotNil(parentIndex, "tile without its parent's tile", file: file, line: line)
            }
            guard let pi = parentIndex else { continue }
            XCTAssertLessThan(pi, i, "child painted before its parent", file: file, line: line)
            XCTAssertEqual(Self.childDepth(tiles[pi].depth), tile.depth, "depth is not parent's + 1", file: file, line: line)
            groups[pi, default: Group(parent: tiles[pi], parentIndex: pi, children: [])].children.append((tile, i))
        }
        return groups.values.sorted { $0.parentIndex < $1.parentIndex }
    }

    func contentRect(_ tile: Tile) -> CGRect {
        var rect = tile.rect
        if let header = tile.headerRect { rect.origin.y += header.height; rect.size.height -= header.height }
        return rect
    }

    static func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }

    /// The area of the strip that holds `tiles` placeholder squares in a
    /// parent `r` (ruling T6-3): whole lines of floor(shorter side / side)
    /// squares across the shorter side. Zero for no placeholders.
    func stripArea(in r: CGRect, tiles: Int) -> Double {
        guard tiles > 0 else { return 0 }
        let side = Double(p.cullArea).squareRoot()
        let length = Double(min(r.width, r.height))
        let perLine = (length / side + 1e-9).rounded(.down)
        return length * ((Double(tiles) / perLine).rounded(.up) * side)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0 ? Double(w) * Double(h) : 0
    }

    /// Run `body` for every seed; on the first failing seed, report it and stop.
    func forEachSeed(_ name: String, _ body: (UInt64, SyntheticTree, CGRect, [Tile]) -> Void) {
        for seed in Self.seeds {
            let t = SyntheticTree.random(seed: seed)
            let b = Self.bounds(seed)
            let tiles = squarify(t, root: t.rootIndex, in: b, p)
            let before = testRun?.failureCount ?? 0
            body(seed, t, b, tiles)
            if (testRun?.failureCount ?? 0) > before {
                print("\(name): failing seed \(seed)")
                XCTFail("\(name): failing seed \(seed) (bounds \(b), \(tiles.count) tiles)")
                return
            }
        }
    }

    // MARK: Properties

    func test_rects_are_disjoint_among_siblings() {
        var multiChildGroups = 0
        forEachSeed("disjoint") { _, t, _, tiles in
            for g in Self.groups(tiles, t) {
                if g.children.count >= 2 { multiChildGroups += 1 }
                let eps = 1e-9 * Self.area(g.parent.rect)
                // Sweep by minX so large groups stay cheap.
                let kids = g.children.map(\.tile.rect).sorted { $0.minX < $1.minX }
                for i in kids.indices {
                    var j = i + 1
                    while j < kids.count && kids[j].minX < kids[i].maxX {
                        XCTAssertLessThanOrEqual(Self.overlap(kids[i], kids[j]), eps, "\(kids[i]) overlaps \(kids[j])")
                        j += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(multiChildGroups, 1000, "precondition: sibling sets with several tiles")
    }

    func test_rects_plus_aggregate_cover_the_parent_within_epsilon() {
        var aggregates = 0
        var terminalDirs = 0
        var subdivided = 0
        forEachSeed("cover") { _, t, _, tiles in
            let groups = Self.groups(tiles, t)
            let parents = Set(groups.map(\.parentIndex))
            for g in groups {
                let pa = Self.area(g.parent.rect)
                let sum = g.children.reduce(0.0) { $0 + Self.area($1.tile.rect) }
                // Sized children, their aggregate and any permission-denied
                // placeholders together cover a sized parent.
                // The strip holding the placeholders is a whole band; the
                // cells its squares leave empty are the one uncovered part
                // of a parent, so the tiles plus those cells cover it.
                if t.allocated(g.parent.node) > 0 {
                    let ph = g.children.filter(\.tile.isPermissionDenied)
                    let empty = stripArea(in: contentRect(g.parent), tiles: ph.count) - ph.reduce(0.0) { $0 + Self.area($1.tile.rect) }
                    XCTAssertGreaterThanOrEqual(empty, -1e-6 * pa)
                    XCTAssertEqual(sum + empty + Self.area(g.parent.headerRect ?? .zero), pa, accuracy: 1e-6 * pa, "children do not cover parent \(g.parent.node)")
                }
                let slack = 1e-9 * max(g.parent.rect.width, g.parent.rect.height)
                let outer = contentRect(g.parent).insetBy(dx: -slack, dy: -slack)
                for c in g.children {
                    XCTAssertTrue(outer.contains(c.tile.rect), "\(c.tile.rect) outside parent \(g.parent.rect)")
                    if c.tile.isAggregate && !c.tile.isPermissionDenied { aggregates += 1 }
                }
            }
            // Level of detail: a directory is subdivided iff its tile is at
            // least subdivideMin on its smaller side (the budget never binds
            // on these trees).
            XCTAssertLessThan(tiles.count, p.budget)
            for (i, tile) in tiles.enumerated() where !tile.isAggregate && t.isDirectory(tile.node) {
                let big = min(tile.rect.width, tile.rect.height) >= p.subdivideMin
                let hasKids = t.allocated(tile.node) > 0 && !t.children(tile.node).isEmpty
                XCTAssertEqual(parents.contains(i), big && hasKids, "subdivision of \(tile.node) at \(tile.rect)")
                if !big && hasKids { terminalDirs += 1 }
                if parents.contains(i) { subdivided += 1 }
            }
        }
        XCTAssertGreaterThan(aggregates, 500, "precondition: aggregates exercised")
        XCTAssertGreaterThan(terminalDirs, 500, "precondition: terminal directory tiles exercised")
        XCTAssertGreaterThan(subdivided, 1000, "precondition: subdivided directories exercised")
    }

    func test_area_is_proportional_to_size_within_tolerance() {
        var checked = 0
        forEachSeed("area") { _, t, _, tiles in
            for g in Self.groups(tiles, t) {
                // Permission-denied placeholders have a fixed area, not a
                // size; the sized children share the rect their strip leaves.
                let placeholders = g.children.filter(\.tile.isPermissionDenied)
                let pa = Self.area(contentRect(g.parent)) - stripArea(in: contentRect(g.parent), tiles: placeholders.count)
                let pb = Double(t.allocated(g.parent.node))
                for c in g.children where !c.tile.isPermissionDenied {
                    let bytes = c.tile.isAggregate ? c.tile.aggregateBytes : t.allocated(c.tile.node)
                    let want = Double(bytes) / pb
                    let got = Self.area(c.tile.rect) / pa
                    XCTAssertLessThanOrEqual(abs(got - want), 1e-3 * want, "tile \(c.tile.node): \(got) vs \(want)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 50_000, "precondition: many tiles checked")

        // The row step alone, on extreme spreads (sizes over 50 bits, so a
        // tile can be 1e-15 of its parent): every rect keeps its proportion.
        var rects: [CGRect] = []
        var suffix: [Double] = []
        var tiny = 0
        for seed in Self.seeds {
            var rng = SplitMix64(seed: seed ^ 0xA4EA)
            let n = 2 + Int(rng.next() % 100)
            var areas = (0..<n).map { _ in exp(rng.unit() * 50 * M_LN2) }.sorted(by: >)
            let r = Self.window(seed)
            let scale = Double(r.width) * Double(r.height) / areas.reduce(0, +)
            areas = areas.map { $0 * scale }
            squarifyRow(areas, in: r, into: &rects, suffix: &suffix)
            for (a, rect) in zip(areas, rects) {
                if a < 1e-9 { tiny += 1 }
                XCTAssertLessThanOrEqual(abs(Self.area(rect) - a), 1e-3 * a, "seed \(seed): \(rect) for area \(a)")
            }
            if testRun!.failureCount > 0 {
                print("area: failing seed \(seed) (row step)")
                return
            }
        }
        XCTAssertGreaterThan(tiny, 200, "precondition: tiles under 1e-9 pt² exercised")
        // A dominant item and one 1e-14 its size, away from the origin: the
        // small one's extent is far below the coordinates' rounding, so it
        // must come from its own area, not from "end minus cursor".
        for r in [CGRect(x: 51, y: 4.5, width: 409, height: 1163), CGRect(x: 4.5, y: 51, width: 1163, height: 409)] {
            let whole = Self.area(r)
            let areas = [whole * (1 - 1e-14), whole * 1e-14]
            squarifyRow(areas, in: r, into: &rects, suffix: &suffix)
            for (a, rect) in zip(areas, rects) {
                XCTAssertLessThanOrEqual(abs(Self.area(rect) - a), 1e-3 * a, "\(r): \(rect) for area \(a)")
            }
        }
    }

    /// A window-shaped rect, as the treemap is laid out in.
    static func window(_ seed: UInt64) -> CGRect {
        var rng = SplitMix64(seed: seed ^ 0xA5)
        return CGRect(x: 0, y: 0, width: 600 + rng.unit() * 1900, height: 400 + rng.unit() * 1000)
    }

    static func ratio(_ r: CGRect) -> Double {
        Double(max(r.width, r.height) / min(r.width, r.height))
    }

    /// BHvW's worst aspect ratio of a row of `areas` laid along a side `s`.
    static func worst(_ areas: ArraySlice<Double>, _ s: Double) -> Double {
        let sum = areas.reduce(0, +)
        return max(s * s * areas.max()! / (sum * sum), sum * sum / (s * s * areas.min()!))
    }

    /// The exact oracle for the squarified row-building step: reconstruct the
    /// rows of `rects` (the output of `squarifyRow` on `areas` in `rect`) and
    /// check each against the greedy rule. Returns the rows checked and how
    /// many of those had a next item, so (b) was decided.
    ///
    /// (c) the row is laid along the current shorter side of the free rect
    ///     (a column when w ≥ h), starting at its corner;
    /// (a) the row's worst ratio is no worse than its first item's alone;
    /// (b) adding the next item would make the row worse (strictly).
    static func checkGreedyRows(
        _ areas: [Double], _ rect: CGRect, _ rects: [CGRect], file: StaticString = #filePath, line: UInt = #line
    ) -> (rows: Int, decided: Int) {
        XCTAssertEqual(rects.count, areas.count, file: file, line: line)
        guard rects.count == areas.count else { return (0, 0) }
        var fx = Double(rect.minX), fy = Double(rect.minY)
        var fw = Double(rect.width), fh = Double(rect.height)
        let tol = 1e-10 * max(fw, fh)
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tol }
        let n = areas.count
        var i = 0
        var rows = 0
        var decided = 0
        while i < n {
            // The items of one row: a column shares minX and width and
            // stacks down from fy; a row shares minY and height and runs
            // right from fx. Valid if it spans the free side exactly.
            func row(column: Bool) -> Int? {
                let first = rects[i]
                var len = 0.0
                var j = i
                let side = column ? fh : fw
                while j < n {
                    let q = rects[j]
                    let fits = column
                        ? near(Double(q.minX), fx) && near(Double(q.width), Double(first.width)) && near(Double(q.minY), fy + len)
                        : near(Double(q.minY), fy) && near(Double(q.height), Double(first.height)) && near(Double(q.minX), fx + len)
                    guard fits else { return nil }
                    len += Double(column ? q.height : q.width)
                    j += 1
                    if len >= side - tol { return near(len, side) ? j : nil }
                }
                return nil
            }
            let preferColumn = fw >= fh
            var column = preferColumn
            var end = row(column: column)
            if end == nil && near(fw, fh) {
                column.toggle()
                end = row(column: column)
            }
            guard let j = end else {
                XCTFail("(c) item \(i) does not start a row along the shorter side of (\(fx), \(fy), \(fw), \(fh))", file: file, line: line)
                return (rows, decided)
            }
            let s = min(fw, fh)
            let w = worst(areas[i..<j], s)
            XCTAssertLessThanOrEqual(w, worst(areas[i..<i + 1], s) * (1 + 1e-9), "(a) row \(i)..<\(j) worse than its first item alone", file: file, line: line)
            if j < n {
                XCTAssertGreaterThan(worst(areas[i...j], s), w, "(b) row \(i)..<\(j) stopped although item \(j) would not worsen it", file: file, line: line)
                decided += 1
            }
            let thick = Double(column ? rects[i].width : rects[i].height)
            if column { fx += thick; fw -= thick } else { fy += thick; fh -= thick }
            rows += 1
            i = j
        }
        return (rows, decided)
    }

    /// Worst ratio ≤ 20 for non-aggregate tiles larger than subdivideMin, by
    /// area (≥ subdivideMin², so slivers count), in a window-shaped root.
    ///
    /// No rectangular layout bounds aspect ratios for arbitrary sizes (97.7%
    /// and 2.3% in a square force a strip of ratio ~44), so (ruling T6-1):
    /// * the bound of 20 is asserted strictly on trees whose siblings differ
    ///   by at most 10x;
    /// * on heavy-tailed inputs the row-building step is checked exactly
    ///   against the BHvW greedy rule (`checkGreedyRows`), with no exemptions;
    /// * the heavy-tailed trees' worst ratio is reported, not gated.
    func test_aspect_ratios_are_bounded() {
        let minArea = Double(p.subdivideMin * p.subdivideMin)
        var balancedChecked = 0
        var balancedSlivers = 0
        var rows = 0
        var decided = 0
        var heavyWorst = 0.0
        var scratch: (rects: [CGRect], suffix: [Double]) = ([], [])
        for seed in Self.seeds {
            let before = testRun!.failureCount
            let b = Self.window(seed)

            let bt = SyntheticTree.balanced(seed: seed)
            for tile in squarify(bt, root: bt.rootIndex, in: b, p).dropFirst() where !tile.isAggregate {
                guard Self.area(tile.rect) >= minArea else { continue }
                if min(tile.rect.width, tile.rect.height) < p.subdivideMin { balancedSlivers += 1 }
                XCTAssertLessThanOrEqual(Self.ratio(tile.rect), 20, "balanced: tile \(tile.node) \(tile.rect)")
                balancedChecked += 1
            }

            // Heavy-tailed area lists (16 bits log-uniform, sorted as the
            // layout receives them, sometimes with an aggregate and
            // placeholders appended) in window, strip or tiny rects.
            var rng = SplitMix64(seed: seed ^ 0x0AC1E)
            let n = 1 + Int(rng.next() % 200)
            var areas = (0..<n).map { _ in exp(rng.unit() * 16 * M_LN2) }.sorted(by: >)
            if rng.unit() < 0.3 { areas.append(areas.reduce(0, +) * rng.unit() * 0.2 + 1) }
            if rng.unit() < 0.2 { areas += Array(repeating: areas.last! * (0.5 + rng.unit()), count: 1 + Int(rng.next() % 16)) }
            let r = Self.bounds(seed)
            let scale = Double(r.width) * Double(r.height) / areas.reduce(0, +)
            areas = areas.map { $0 * scale }
            squarifyRow(areas, in: r, into: &scratch.rects, suffix: &scratch.suffix)
            let checked = Self.checkGreedyRows(areas, r, scratch.rects)
            rows += checked.rows
            decided += checked.decided

            let t = SyntheticTree.random(seed: seed)
            for tile in squarify(t, root: t.rootIndex, in: b, p).dropFirst() where !tile.isAggregate {
                guard Self.area(tile.rect) >= minArea else { continue }
                heavyWorst = max(heavyWorst, Self.ratio(tile.rect))
            }
            if testRun!.failureCount > before {
                print("aspect: failing seed \(seed)")
                XCTFail("aspect: failing seed \(seed)")
                return
            }
        }
        // Ties: the greedy rule joins an item that leaves the worst ratio
        // unchanged. Two halves of a square tie at 2 (k = 1 → 2); six sixths
        // of a 6x6 square tie at 1.5 (k = 2 → 3). Exact in binary.
        for (areas, r) in [
            ([8192.0, 8192.0], CGRect(x: 0, y: 0, width: 128, height: 128)),
            (Array(repeating: 6.0, count: 6), CGRect(x: 0, y: 0, width: 6, height: 6)),
        ] {
            squarifyRow(areas, in: r, into: &scratch.rects, suffix: &scratch.suffix)
            let checked = Self.checkGreedyRows(areas, r, scratch.rects)
            // 2 halves: one row of both. 6 sixths: [3 joined on the tie], then 1, 1, 1.
            XCTAssertEqual(checked.rows, areas.count == 2 ? 1 : 4, "tie fixture \(areas.count): rows")
        }
        print("aspect: \(balancedChecked) balanced tiles (\(balancedSlivers) thinner than \(p.subdivideMin)), \(rows) greedy rows (\(decided) decided); heavy-tailed worst ratio \(heavyWorst) (reported, not gated)")
        XCTAssertGreaterThan(balancedChecked, 20_000, "precondition: many balanced tiles checked")
        XCTAssertGreaterThan(rows, 5_000, "precondition: many greedy rows checked")
        XCTAssertGreaterThan(decided, 4_000, "precondition: many rows where the join rule was decided")
    }

    func test_tail_aggregate_is_a_contiguous_suffix() {
        var aggregates = 0
        var multiAggregates = 0
        forEachSeed("suffix") { _, t, _, tiles in
            for g in Self.groups(tiles, t) {
                let range = t.children(g.parent.node)
                let positive = range.filter { t.allocated($0) > 0 }
                let sized = g.children.filter { !$0.tile.isPermissionDenied }
                let aggs = sized.filter(\.tile.isAggregate)
                XCTAssertLessThanOrEqual(aggs.count, 1, "more than one aggregate in a sibling set")
                let emitted = sized.filter { !$0.tile.isAggregate }.map(\.tile.node)
                // The individually emitted children are exactly a prefix.
                XCTAssertEqual(emitted.sorted(), Array(positive.prefix(emitted.count)), "emitted set is not a prefix")
                if let agg = aggs.first?.tile {
                    aggregates += 1
                    let tail = positive.dropFirst(emitted.count)
                    if tail.count > 1 { multiAggregates += 1 }
                    XCTAssertEqual(agg.node, UInt32(TESS_NODE_NONE))
                    XCTAssertEqual(Int(agg.aggregateCount), tail.count)
                    XCTAssertEqual(agg.aggregateBytes, tail.reduce(0) { $0 + t.allocated($1) })
                    // Everything collapsed is no bigger than anything kept.
                    if let smallestKept = emitted.last, let largestTail = tail.first {
                        XCTAssertLessThanOrEqual(t.allocated(largestTail), t.allocated(smallestKept))
                    }
                } else {
                    XCTAssertEqual(emitted.count, positive.count, "children missing without an aggregate")
                }
                for c in sized where !c.tile.isAggregate {
                    XCTAssertEqual(c.tile.aggregateCount, 0)
                    XCTAssertEqual(c.tile.aggregateBytes, 0)
                    XCTAssertEqual(c.tile.flags & Tile.Flag.aggregated, 0)
                    XCTAssertGreaterThanOrEqual(Self.area(c.tile.rect), Double(p.cullArea) * (1 - 1e-9), "culled tile emitted")
                }
            }
        }
        XCTAssertGreaterThan(aggregates, 500, "precondition: aggregates exercised")
        XCTAssertGreaterThan(multiAggregates, 200, "precondition: multi-item aggregates exercised")
    }

    func test_budget_is_respected() {
        var bound = 0
        for seed in Self.seeds {
            let t = SyntheticTree.random(seed: seed)
            let b = CGRect(x: 0, y: 0, width: 1440, height: 900)
            var rng = SplitMix64(seed: seed ^ 0xBADD_CAFE)
            let budget = Int(rng.next() % 200)
            let unbounded = squarify(t, root: t.rootIndex, in: b, LayoutParameters(budget: .max)).count
            let tiles = squarify(t, root: t.rootIndex, in: b, LayoutParameters(budget: budget))
            if unbounded > budget { bound += 1 }
            XCTAssertLessThanOrEqual(tiles.count, budget, "seed \(seed)")
            // Under a binding budget the layout stays well formed: every
            // subdivided parent is still exactly covered.
            for g in Self.groups(tiles, t) {
                let pa = Self.area(g.parent.rect)
                let sum = g.children.reduce(0.0) { $0 + Self.area($1.tile.rect) }
                let held = g.children.filter(\.tile.isPermissionDenied)
                let empty = stripArea(in: contentRect(g.parent), tiles: held.count) - held.reduce(0.0) { $0 + Self.area($1.tile.rect) }
                XCTAssertEqual(sum + empty + Self.area(g.parent.headerRect ?? .zero), pa, accuracy: 1e-6 * pa, "seed \(seed): budget broke coverage")
            }
            if testRun!.failureCount > 0 {
                print("budget: failing seed \(seed)")
                return
            }
        }
        XCTAssertGreaterThan(bound, 250, "precondition: the budget binds")
    }

    func test_zero_size_root_yields_no_tiles_and_no_nan() {
        let b = CGRect(x: 0, y: 0, width: 800, height: 600)
        let empties: [SyntheticTree] = [
            SyntheticTree(.file(0)),
            SyntheticTree(.dir([])),
            SyntheticTree(.dir([.file(0), .file(0), .dir([.file(0)])])),
        ]
        for t in empties {
            XCTAssertEqual(t.allocated(t.rootIndex), 0, "precondition: zero-size root")
            XCTAssertEqual(squarify(t, root: t.rootIndex, in: b), [])
        }
        // A zero-size subtree inside a sized tree emits nothing either.
        let t = SyntheticTree(.dir([.file(1000), .dir([.file(0), .file(0)]), .file(0)]))
        let tiles = squarify(t, root: t.rootIndex, in: b)
        XCTAssertEqual(tiles.map(\.node), [0, 1], "only the root and its sized child")
        XCTAssertEqual(tiles.last?.rect, b)
        // Degenerate bounds yield nothing, never a NaN rect.
        let sized = SyntheticTree.random(seed: 7)
        for bad in [
            CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: -5),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: 1e200, height: 1e200),  // area overflows to +inf
            CGRect(x: 0, y: 0, width: 1e-200, height: 1e-200),  // area underflows to 0
        ] {
            XCTAssertEqual(squarify(sized, root: sized.rootIndex, in: bad), [], "\(bad)")
        }
        XCTAssertEqual(squarify(sized, root: sized.rootIndex, in: b, LayoutParameters(budget: 0)), [])
    }

    /// Ruling T6-3: a placeholder must be visible. It is a square of side
    /// sqrt(cullArea), laid in a strip beside the squarified sized children,
    /// never a sliver inside their rows.
    func test_placeholders_are_visible_squares() {
        let side = Double(p.cullArea).squareRoot()
        let eps = 1e-9 * side
        var checked = 0
        func check(_ tile: Tile, _ what: String) {
            let w = Double(tile.rect.width)
            let h = Double(tile.rect.height)
            XCTAssertGreaterThanOrEqual(min(w, h), side - eps, "\(what): placeholder \(tile.rect) is too thin")
            XCTAssertLessThanOrEqual(max(w, h) / min(w, h), 1 + 1e-9, "\(what): placeholder \(tile.rect) is not square")
            checked += 1
        }
        // Sized children of very different sizes beside 1, 3, 16 and 17
        // unreadable folders, in landscape, portrait and the smallest
        // subdividable rects.
        for b in [
            CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 10, y: 20, width: 500, height: 900),
            CGRect(x: 0, y: 0, width: 24, height: 24), CGRect(x: 0, y: 0, width: 24, height: 40),
        ] {
            for d in [1, 3, 16, 17] {
                let t = SyntheticTree(
                    .dir([.file(1_000_000), .file(500_000), .dir([.file(300), .file(200)])] + Array(repeating: .denied, count: d)))
                for tile in squarify(t, root: 0, in: b, p) where tile.isPermissionDenied { check(tile, "\(d) in \(b)") }
            }
        }
        // The same, over every random tree.
        forEachSeed("visible") { seed, t, b, tiles in
            for tile in tiles where tile.isPermissionDenied && tile.depth > 0 { check(tile, "seed \(seed)") }
        }
        XCTAssertGreaterThan(checked, 300, "precondition: placeholders checked")
    }

    /// Ruling T6-2: a permission-denied directory (0 bytes) gets a fixed
    /// placeholder tile of area cullArea, laid after its sized siblings and
    /// flagged permDenied; more than 16 collapse into one placeholder flagged
    /// permDenied + aggregated, counting them.
    func test_permission_denied_directories_get_placeholder_tiles() {
        let b = CGRect(x: 0, y: 0, width: 800, height: 600)
        let cull = Double(p.cullArea)
        for d in [1, 16, 17] {
            let t = SyntheticTree(
                .dir([.file(1_000_000), .file(500_000), .dir([.file(300), .file(200)])] + Array(repeating: .denied, count: d)))
            let deniedKids = t.children(0).filter { t.isPermissionDenied($0) }
            XCTAssertEqual(deniedKids.count, d, "precondition")
            let tiles = squarify(t, root: 0, in: b, p)
            let placeholders = tiles.enumerated().filter { $0.element.isPermissionDenied }
            if d <= 16 {
                XCTAssertEqual(placeholders.map(\.element.node).sorted(), deniedKids, "\(d): one tile per denied folder")
                for (_, tile) in placeholders {
                    XCTAssertEqual(tile.flags, Tile.Flag.permDenied, "\(d)")
                    XCTAssertEqual(tile.aggregateCount, 0)
                }
            } else {
                XCTAssertEqual(placeholders.count, 1, "\(d): collapsed")
                guard let tile = placeholders.first?.element else { continue }
                XCTAssertEqual(tile.flags, Tile.Flag.permDenied | Tile.Flag.aggregated)
                XCTAssertEqual(tile.node, Tile.noNode)
                XCTAssertEqual(tile.aggregateCount, UInt32(d))
                XCTAssertEqual(tile.aggregateBytes, 0)
            }
            for (i, tile) in placeholders {
                XCTAssertEqual(Self.area(tile.rect), cull, accuracy: 1e-9 * cull, "\(d): placeholder area")
                XCTAssertEqual(tile.depth, 1)
                // Painted after every sized sibling.
                for (j, other) in tiles.enumerated() where other.depth == 1 && !other.isPermissionDenied {
                    XCTAssertLessThan(j, i, "\(d): placeholder before a sized sibling")
                }
            }
            // Coverage, disjointness and proportion of the sized children.
            let kids = tiles.filter { $0.depth == 1 }
            let strip = stripArea(in: b, tiles: placeholders.count)
            XCTAssertEqual(
                kids.reduce(0.0) { $0 + Self.area($1.rect) } + strip - Double(placeholders.count) * cull, Self.area(b),
                accuracy: 1e-6 * Self.area(b), "\(d): tiles plus the strip's empty cells cover the parent")
            for x in kids.indices { for y in kids.indices where x < y {
                XCTAssertLessThanOrEqual(Self.overlap(kids[x].rect, kids[y].rect), 1e-9 * Self.area(b))
            } }
            let avail = Self.area(b) - strip
            for tile in kids where !tile.isPermissionDenied {
                let want = Double(t.allocated(tile.node)) / Double(t.allocated(0))
                XCTAssertEqual(Self.area(tile.rect) / avail, want, accuracy: 1e-9, "\(d): sized share")
            }
        }

        // A parent whose only child is unreadable (so the parent is 0 bytes).
        let only = SyntheticTree(.dir([.denied]))
        let onlyTiles = squarify(only, root: 0, in: b, p)
        XCTAssertEqual(onlyTiles.map(\.node), [0, 1])
        XCTAssertEqual(onlyTiles.last?.flags, Tile.Flag.permDenied)
        if let last = onlyTiles.last {
            XCTAssertEqual(Self.area(last.rect), cull, accuracy: 1e-9 * cull)
            XCTAssertTrue(b.contains(last.rect))
        }
        // An unreadable root is one placeholder filling the bounds.
        XCTAssertEqual(squarify(SyntheticTree(.denied), root: 0, in: b, p), [Tile(rect: b, node: 0, depth: 0, flags: Tile.Flag.permDenied)])

        // The budget still binds with placeholders in play.
        let crowd = SyntheticTree(.dir((1...200).map { .file(UInt64($0) * 1000) } + Array(repeating: .denied, count: 10)))
        for budget in 0...40 {
            let tiles = squarify(crowd, root: 0, in: b, LayoutParameters(budget: budget))
            XCTAssertLessThanOrEqual(tiles.count, budget, "budget \(budget)")
            let kids = tiles.filter { $0.depth == 1 }
            if !kids.isEmpty {
                let held = kids.filter(\.isPermissionDenied)
                let empty = stripArea(in: b, tiles: held.count) - Double(held.count) * cull
                XCTAssertEqual(kids.reduce(0.0) { $0 + Self.area($1.rect) } + empty, Self.area(b), accuracy: 1e-6 * Self.area(b), "budget \(budget)")
                XCTAssertFalse(kids.filter(\.isPermissionDenied).isEmpty, "budget \(budget): placeholders kept")
            }
        }

        // Random trees: every subdivided parent shows its denied children.
        var few = 0
        var many = 0
        forEachSeed("denied") { _, t, _, tiles in
            for g in Self.groups(tiles, t) {
                let denied = t.children(g.parent.node).filter { t.isPermissionDenied($0) }
                let shown = g.children.filter(\.tile.isPermissionDenied).map(\.tile)
                if denied.isEmpty {
                    XCTAssertTrue(shown.isEmpty)
                } else if denied.count <= 16 {
                    few += 1
                    XCTAssertEqual(shown.map(\.node).sorted(), denied)
                } else {
                    many += 1
                    XCTAssertEqual(shown.count, 1)
                    XCTAssertEqual(shown.first?.aggregateCount, UInt32(denied.count))
                }
                for tile in shown { XCTAssertEqual(Self.area(tile.rect), cull, accuracy: 1e-9 * cull) }
            }
        }
        XCTAssertGreaterThan(few, 100, "precondition: parents with 1-16 denied children")
        XCTAssertGreaterThan(many, 5, "precondition: parents with more than 16 denied children")
    }

    func test_huge_flat_directory_is_bounded_and_aggregate_is_exact() {
        var rng = SplitMix64(seed: 42)
        let n = 500_000
        let kids = (0..<n).map { _ in SyntheticTree.Spec.file(SyntheticTree.fileSize(&rng)) }
        let t = SyntheticTree(.dir(kids))
        let positive = t.children(t.rootIndex).filter { t.allocated($0) > 0 }
        XCTAssertGreaterThan(positive.count, 400_000, "precondition: mostly sized files")
        // A window, then a canvas big enough that the budget, not the cull, binds.
        for b in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 30_000, height: 30_000)] {
            let tiles = squarify(t, root: t.rootIndex, in: b, p)
            XCTAssertLessThanOrEqual(tiles.count, p.budget, "\(b)")
            let aggs = tiles.filter(\.isAggregate)
            XCTAssertEqual(aggs.count, 1, "\(b)")
            guard let agg = aggs.first else { continue }
            let kept = tiles.count - 2  // minus the root and the aggregate
            XCTAssertEqual(Int(agg.aggregateCount), positive.count - kept, "\(b)")
            let tailBytes = positive[kept...].reduce(UInt64(0)) { $0 + t.allocated($1) }
            XCTAssertEqual(agg.aggregateBytes, tailBytes, "\(b)")
            XCTAssertEqual(Self.area(agg.rect) / Self.area(b), Double(tailBytes) / Double(t.allocated(0)), accuracy: 1e-9)
            // Every individually kept file clears the cull threshold.
            for tile in tiles.dropFirst() where !tile.isAggregate {
                XCTAssertGreaterThanOrEqual(Self.area(tile.rect), Double(p.cullArea) * (1 - 1e-9), "\(b): culled tile emitted")
            }
            print("flat \(n) in \(b.size): \(tiles.count) tiles, aggregate of \(agg.aggregateCount)")
        }
        XCTAssertEqual(squarify(t, root: t.rootIndex, in: CGRect(x: 0, y: 0, width: 30_000, height: 30_000), p).count, p.budget,
                       "precondition: the budget binds on the big canvas")
    }

    func test_no_rect_is_nan_or_negative() {
        var tiny = 0
        forEachSeed("finite") { _, _, b, tiles in
            if b.width < 24 || b.height < 24 { tiny += 1 }
            for tile in tiles {
                let r = tile.rect
                XCTAssertTrue(r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite, "\(r)")
                XCTAssertGreaterThan(r.size.width, 0, "\(r)")
                XCTAssertGreaterThan(r.size.height, 0, "\(r)")
            }
            XCTAssertFalse(tiles.isEmpty, "a sized tree yields tiles")
        }
        XCTAssertGreaterThan(tiny, 20, "precondition: tiny bounds exercised")
    }

    // MARK: Measurement (spec §12 "Performance": reported, never asserted)

    /// A real snapshot to time the layout on, scanned once per run from
    /// `TESSERAE_BENCH_ROOT` (e.g. `/System/Volumes/Data`); pass it to
    /// xcodebuild as `TEST_RUNNER_TESSERAE_BENCH_ROOT`. Unset, the
    /// measurements skip, so CI never scans the runner's disk.
    nonisolated(unsafe) private static var benchSnapshot: Snapshot?

    private func benchSnapshotOrSkip() throws -> Snapshot {
        if let s = Self.benchSnapshot { return s }
        guard let root = ProcessInfo.processInfo.environment["TESSERAE_BENCH_ROOT"] else {
            throw XCTSkip("set TEST_RUNNER_TESSERAE_BENCH_ROOT to measure on a real snapshot")
        }
        let start = Date()
        guard let scan = tess_scan_begin(root, nil) else { throw XCTSkip("tess_scan_begin failed") }
        while tess_scan_status(scan) == Int32(TESS_STATUS_RUNNING) { usleep(10_000) }
        guard let handle = tess_scan_finish(scan) else { throw XCTSkip("tess_scan_finish failed") }
        let snap = Snapshot(handle: handle)
        print("BENCH scanned \(root): \(snap.nodes.count) nodes in \(Date().timeIntervalSince(start)) s")
        Self.benchSnapshot = snap
        return snap
    }

    private func bench(_ snap: Snapshot, root: UInt32, label: String) {
        let b = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let tiles = squarify(snap, root: root, in: b)
        let aggs = tiles.filter(\.isAggregate)
        print(
            "BENCH \(label): node \(root), \(snap.children(root).count) children, \(tiles.count) tiles, "
                + "\(aggs.count) aggregates, max depth \(tiles.map(\.depth).max() ?? 0)")
        var times: [Double] = []
        for _ in 0..<50 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = squarify(snap, root: root, in: b)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        times.sort()
        print("BENCH \(label): min \(times[0]) ms, median \(times[25]) ms, max \(times[49]) ms over 50 runs")
        measure { _ = squarify(snap, root: root, in: b) }
    }

    func test_measure_squarify_on_the_snapshot_root() throws {
        let snap = try benchSnapshotOrSkip()
        bench(snap, root: snap.root, label: "root")
    }

    func test_measure_squarify_on_the_largest_directory() throws {
        let snap = try benchSnapshotOrSkip()
        // The directory with the most children: the flat-directory worst case.
        var largest = snap.root
        var most: UInt32 = 0
        for (i, n) in snap.nodes.enumerated() where n.child_count > most {
            most = n.child_count
            largest = UInt32(i)
        }
        bench(snap, root: largest, label: "largest directory (\(snap.displayPath(largest)))")
    }

    /// How long the main actor is blocked when a zoom settles and labels are
    /// due, over the phase gate's protocol (the five largest readable root
    /// directories, in and out, three times) at the gate's viewport. With
    /// `TEST_RUNNER_TESSERAE_FRAME_TIMING=1` it also reports the existing
    /// `labels` interval (placement, now off the main actor) and
    /// `labels-apply` (publishing the result on it).
    @MainActor
    func test_measure_label_settle_cost_on_the_main_actor() async throws {
        let snap = try benchSnapshotOrSkip()
        let app = AppModel()
        app.replaceSnapshot(snap)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 1679, height: 493.5))
        await session.waitForLabels()
        let targets = snap.children(snap.root).filter {
            snap.isDirectory($0) && !snap.isPermissionDenied($0) && snap.allocated($0) > 0
        }.prefix(5)
        FrameTimer.shared.startCapture()
        var settle: [Double] = []
        for _ in 1...3 {
            for node in targets {
                for move in [{ session.navigator.descend(into: node) }, { session.go(to: snap.root) }] {
                    move()
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    session.setZoomRunning(false, generation: session.layoutGeneration)
                    settle.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    await session.waitForLabels()
                    await session.waitForTable()
                }
            }
        }
        FrameTimer.shared.stopCapture()
        settle.sort()
        print("BENCH label settle on the main actor: \(settle.count) settles, median \(settle[settle.count / 2]) ms, "
            + "p99 \(FrameTimer.percentile99(settle)) ms, max \(settle.last ?? 0) ms")
        for kind in ["labels", "labels-apply"] {
            let ms = FrameTimer.shared.samples.filter { $0.kind == kind }.map { $0.seconds * 1000 }.sorted()
            guard !ms.isEmpty else { print("BENCH \(kind): no samples (TESSERAE_FRAME_TIMING unset)"); continue }
            print("BENCH \(kind): \(ms.count) samples, median \(ms[ms.count / 2]) ms, max \(ms.last ?? 0) ms")
        }
    }

    /// Every tile's `parent` is the directory whose subtree it was laid out
    /// in; the root tile's is `Tile.noNode`, even for a subtree root.
    func test_tile_parent_is_the_node_it_was_laid_out_in() {
        let tiny = (0..<60).map { _ in SyntheticTree.Spec.file(1) }
        let denied = (0..<20).map { _ in SyntheticTree.Spec.denied }
        let trees = [
            SyntheticTree(.dir([.file(1_000_000), .dir([.file(500_000), .dir(tiny + [.file(300_000)])]) , .dir(tiny + denied + [.file(900_000)])])),
            SyntheticTree.random(seed: 7), SyntheticTree.balanced(seed: 3),
        ]
        let b = CGRect(x: 0, y: 0, width: 800, height: 600)
        for (n, t) in trees.enumerated() {
            for root in [UInt32(0), 1] where Int(root) < t.count && t.isDirectory(root) {
                let tiles = squarify(t, root: root, in: b)
                XCTAssertFalse(tiles.isEmpty)
                XCTAssertEqual(tiles[0].parent, Tile.noNode, "tree \(n) root \(root): the root tile")
                var sawAggregate = false, sawPlaceholder = false
                for (i, tile) in tiles.enumerated() where i > 0 {
                    XCTAssertNotEqual(tile.parent, Tile.noNode, "tree \(n) tile \(i)")
                    if tile.node != Tile.noNode {
                        XCTAssertEqual(tile.parent, t.parents[Int(tile.node)], "tree \(n) tile \(i)")
                        sawPlaceholder = sawPlaceholder || tile.isPermissionDenied
                    } else {
                        sawAggregate = true
                        sawPlaceholder = sawPlaceholder || tile.isPermissionDenied
                    }
                    // Whatever the tile, its parent's tile holds it, one level up.
                    guard let up = tiles[..<i].last(where: { $0.node == tile.parent }) else {
                        XCTFail("tree \(n) tile \(i): parent \(tile.parent) has no earlier tile"); continue
                    }
                    XCTAssertEqual(Self.childDepth(up.depth), tile.depth)
                    XCTAssertTrue(up.rect.insetBy(dx: -1e-6, dy: -1e-6).contains(tile.rect), "tree \(n) tile \(i)")
                }
                if n == 0 && root == 0 {
                    XCTAssertTrue(sawAggregate && sawPlaceholder, "precondition: aggregates and placeholders occur")
                }
            }
        }
    }
}
