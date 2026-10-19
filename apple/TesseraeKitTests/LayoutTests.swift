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

    /// A tile and the tiles laid out inside it (its children and its aggregate).
    struct Group {
        var parent: Tile
        var parentIndex: Int
        var children: [(tile: Tile, index: Int)]
    }

    /// Groups tiles by parent: a node tile by the tree's parent link, an
    /// aggregate by which tile one level up contains its centre (tiles of
    /// one depth are disjoint, so that tile is unique).
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
                parentIndex = tiles.indices.first {
                    tiles[$0].depth + 1 == tile.depth && !tiles[$0].isAggregate && tiles[$0].rect.contains(c)
                }
                XCTAssertNotNil(parentIndex, "aggregate with no parent tile", file: file, line: line)
            } else if tile.node == t.rootIndex {
                parentIndex = nil
            } else {
                parentIndex = byNode[t.parents[Int(tile.node)]]
                XCTAssertNotNil(parentIndex, "tile without its parent's tile", file: file, line: line)
            }
            guard let pi = parentIndex else { continue }
            XCTAssertLessThan(pi, i, "child painted before its parent", file: file, line: line)
            XCTAssertEqual(tiles[pi].depth + 1, tile.depth, "depth is not parent's + 1", file: file, line: line)
            groups[pi, default: Group(parent: tiles[pi], parentIndex: pi, children: [])].children.append((tile, i))
        }
        return groups.values.sorted { $0.parentIndex < $1.parentIndex }
    }

    static func area(_ r: CGRect) -> Double { Double(r.width) * Double(r.height) }

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
                XCTAssertEqual(sum, pa, accuracy: 1e-6 * pa, "children do not cover parent \(g.parent.node)")
                let slack = 1e-9 * max(g.parent.rect.width, g.parent.rect.height)
                let outer = g.parent.rect.insetBy(dx: -slack, dy: -slack)
                for c in g.children {
                    XCTAssertTrue(outer.contains(c.tile.rect), "\(c.tile.rect) outside parent \(g.parent.rect)")
                    if c.tile.isAggregate { aggregates += 1 }
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
                let pa = Self.area(g.parent.rect)
                let pb = Double(t.allocated(g.parent.node))
                for c in g.children {
                    let bytes = c.tile.isAggregate ? c.tile.aggregateBytes : t.allocated(c.tile.node)
                    let want = Double(bytes) / pb
                    let got = Self.area(c.tile.rect) / pa
                    XCTAssertLessThanOrEqual(abs(got - want), 1e-3 * want, "tile \(c.tile.node): \(got) vs \(want)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 50_000, "precondition: many tiles checked")
    }

    /// A window-shaped rect, as the treemap is laid out in.
    static func window(_ seed: UInt64) -> CGRect {
        var rng = SplitMix64(seed: seed ^ 0xA5)
        return CGRect(x: 0, y: 0, width: 600 + rng.unit() * 1900, height: 400 + rng.unit() * 1000)
    }

    static func ratio(_ r: CGRect) -> Double {
        Double(max(r.width, r.height) / min(r.width, r.height))
    }

    /// Worst ratio of emitted tiles ≤ 20 for non-aggregate tiles larger than
    /// subdivideMin (min side ≥ 24), in a window-shaped root.
    ///
    /// No rectangular layout can bound aspect ratios for arbitrary sizes:
    /// with sizes 97.7% and 2.3% in a square, the small one is at best a
    /// 2.3%-wide strip (ratio ~44) whatever the algorithm. So the bound is
    /// asserted outright on trees whose siblings differ by at most 10x, and
    /// on heavy-tailed trees for every tile not forced thin: a tile is forced
    /// when its larger siblings together take at least 90% of the parent (it
    /// lives in the leftover strip) or its parent tile is itself over the
    /// bound (a dominant child inherits its parent's shape).
    func test_aspect_ratios_are_bounded() {
        var balancedChecked = 0
        var heavyChecked = 0
        var forced = 0
        var worstUnforced = 0.0
        for seed in Self.seeds {
            let before = testRun!.failureCount
            let b = Self.window(seed)

            let bt = SyntheticTree.balanced(seed: seed)
            for tile in squarify(bt, root: bt.rootIndex, in: b, p).dropFirst() where !tile.isAggregate {
                guard min(tile.rect.width, tile.rect.height) >= p.subdivideMin else { continue }
                XCTAssertLessThanOrEqual(Self.ratio(tile.rect), 20, "balanced: tile \(tile.node) \(tile.rect)")
                balancedChecked += 1
            }

            let t = SyntheticTree.random(seed: seed)
            let tiles = squarify(t, root: t.rootIndex, in: b, p)
            var tileOf: [UInt32: Tile] = [:]
            for tile in tiles where !tile.isAggregate { tileOf[tile.node] = tile }
            for tile in tiles.dropFirst() where !tile.isAggregate {
                guard min(tile.rect.width, tile.rect.height) >= p.subdivideMin else { continue }
                heavyChecked += 1
                let r = Self.ratio(tile.rect)
                let parent = t.parents[Int(tile.node)]
                let larger = t.children(parent).lowerBound..<tile.node
                let largerShare = Double(larger.reduce(UInt64(0)) { $0 + t.allocated($1) }) / Double(t.allocated(parent))
                if largerShare >= 0.9 || Self.ratio(tileOf[parent]!.rect) > 20 {
                    if r > 20 { forced += 1 }
                    continue
                }
                worstUnforced = max(worstUnforced, r)
                XCTAssertLessThanOrEqual(r, 20, "heavy-tailed: tile \(tile.node) \(tile.rect)")
            }
            if testRun!.failureCount > before {
                print("aspect: failing seed \(seed)")
                XCTFail("aspect: failing seed \(seed) (bounds \(b))")
                return
            }
        }
        print("aspect: \(balancedChecked) balanced tiles, \(heavyChecked) heavy-tailed tiles, \(forced) forced over 20, worst unforced \(worstUnforced)")
        XCTAssertGreaterThan(balancedChecked, 20_000, "precondition: many balanced tiles checked")
        XCTAssertGreaterThan(heavyChecked, 10_000, "precondition: many heavy-tailed tiles checked")
        XCTAssertGreaterThan(forced, 0, "precondition: the forced case occurs, so the exemption is not vacuous")
    }

    func test_tail_aggregate_is_a_contiguous_suffix() {
        var aggregates = 0
        var multiAggregates = 0
        forEachSeed("suffix") { _, t, _, tiles in
            for g in Self.groups(tiles, t) {
                let range = t.children(g.parent.node)
                let positive = range.filter { t.allocated($0) > 0 }
                let aggs = g.children.filter(\.tile.isAggregate)
                XCTAssertLessThanOrEqual(aggs.count, 1, "more than one aggregate in a sibling set")
                let emitted = g.children.filter { !$0.tile.isAggregate }.map(\.tile.node)
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
                for c in g.children where !c.tile.isAggregate {
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
                XCTAssertEqual(sum, pa, accuracy: 1e-6 * pa, "seed \(seed): budget broke coverage")
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
        ] {
            XCTAssertEqual(squarify(sized, root: sized.rootIndex, in: bad), [], "\(bad)")
        }
        XCTAssertEqual(squarify(sized, root: sized.rootIndex, in: b, LayoutParameters(budget: 0)), [])
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
        bench(snap, root: largest, label: "largest directory (\(snap.path(largest)))")
    }
}
