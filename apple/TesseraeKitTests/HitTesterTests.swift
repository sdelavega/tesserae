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
import XCTest

@testable import TesseraeKit

/// Hit testing (spec §8 "Hit testing").
final class HitTesterTests: XCTestCase {
    /// A root holding a subdivided directory, three unreadable folders (a
    /// placeholder strip), a file, and a tail of tiny files (an aggregate).
    static func tree() -> SyntheticTree {
        SyntheticTree(
            .dir(
                [
                    .dir([.file(300_000), .file(200_000), .dir([.file(50_000), .file(30_000)])]),
                    .denied, .denied, .denied,
                    .file(250_000),
                ] + Array(repeating: .file(1), count: 200)))
    }

    /// The deepest tile containing `p`, by depth, without relying on order.
    static func deepest(_ p: CGPoint, _ tiles: [Tile]) -> Int? {
        let hits = tiles.indices.filter { tiles[$0].rect.contains(p) }
        guard let best = hits.max(by: { tiles[$0].depth < tiles[$1].depth }) else { return nil }
        XCTAssertEqual(hits.filter { tiles[$0].depth == tiles[best].depth }.count, 1, "two tiles of one depth at \(p)")
        return best
    }

    func test_hit_test_returns_the_deepest_tile_and_uses_the_cache() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tiles = squarify(Self.tree(), root: 0, in: bounds)
        let placeholders = tiles.indices.filter { tiles[$0].isPermissionDenied }
        let aggregate = tiles.indices.first { tiles[$0].isAggregate && !tiles[$0].isPermissionDenied }
        XCTAssertEqual(placeholders.count, 3, "precondition: a placeholder strip")
        XCTAssertNotNil(aggregate, "precondition: an aggregate")
        XCTAssertGreaterThanOrEqual(tiles.map(\.depth).max()!, 2, "precondition: nesting")

        // Every point of a grid hits the deepest tile under it.
        var h = HitTester()
        var differsFromFirstMatch = 0
        for gx in 0..<200 {
            for gy in 0..<150 {
                let p = CGPoint(x: Double(gx) * 2 + 0.25, y: Double(gy) * 2 + 0.25)
                let got = h.tile(at: p, in: tiles)
                XCTAssertEqual(got, Self.deepest(p, tiles), "at \(p)")
                if got != tiles.indices.first(where: { tiles[$0].rect.contains(p) }) { differsFromFirstMatch += 1 }
            }
        }
        XCTAssertGreaterThan(differsFromFirstMatch, 10_000, "precondition: most points are under nested tiles")

        // The strip: a placeholder, and an empty cell below the squares,
        // where the parent shows through.
        let first = tiles[placeholders[0]].rect
        let strip = placeholders.map { tiles[$0].rect }.reduce(first) { $0.union($1) }
        XCTAssertEqual(h.tile(at: CGPoint(x: first.midX, y: first.midY), in: tiles), placeholders[0])
        let empty = CGPoint(x: strip.midX, y: strip.maxY + 50)
        XCTAssertLessThan(empty.y, bounds.maxY, "precondition: the strip leaves empty cells")
        XCTAssertEqual(h.tile(at: empty, in: tiles), 0, "an empty strip cell is the parent's")
        let agg = tiles[aggregate!].rect
        XCTAssertEqual(h.tile(at: CGPoint(x: agg.midX, y: agg.midY), in: tiles), aggregate)
        XCTAssertNil(h.tile(at: CGPoint(x: -1, y: 5), in: tiles))
        XCTAssertNil(h.tile(at: CGPoint(x: CGFloat.nan, y: 5), in: tiles))

        // The cache: a second point in the same leaf does not scan.
        let leafIndex = tiles.indices.last!
        let leaf = tiles[leafIndex].rect
        h.invalidate()
        let before = h.scanCount
        XCTAssertEqual(h.tile(at: CGPoint(x: leaf.minX + 1, y: leaf.minY + 1), in: tiles), leafIndex)
        XCTAssertEqual(h.scanCount, before + 1)
        XCTAssertEqual(h.tile(at: CGPoint(x: leaf.midX, y: leaf.midY), in: tiles), leafIndex)
        XCTAssertEqual(h.scanCount, before + 1, "a hit in the cached leaf scanned")
        // A changed list is not answered from the cache.
        var moved = tiles
        moved[leafIndex].rect = moved[leafIndex].rect.offsetBy(dx: 1000, dy: 0)
        _ = h.tile(at: CGPoint(x: leaf.midX, y: leaf.midY), in: tiles)
        XCTAssertNotEqual(h.tile(at: CGPoint(x: leaf.midX, y: leaf.midY), in: moved), leafIndex)
    }

    /// A parent cached by a careless cache would answer for its child.
    func test_cache_never_answers_for_a_parent() {
        let tiles = [
            Tile(rect: CGRect(x: 0, y: 0, width: 100, height: 100), node: 0, depth: 0),
            Tile(rect: CGRect(x: 50, y: 50, width: 50, height: 50), node: 1, depth: 1),
        ]
        var h = HitTester()
        XCTAssertEqual(h.tile(at: CGPoint(x: 10, y: 10), in: tiles), 0)
        XCTAssertEqual(h.tile(at: CGPoint(x: 75, y: 75), in: tiles), 1)
        XCTAssertEqual(h.tile(at: CGPoint(x: 80, y: 80), in: tiles), 1)
        XCTAssertEqual(h.scanCount, 2, "the leaf was not cached")
        XCTAssertEqual(h.tile(at: CGPoint(x: 10, y: 10), in: tiles), 0)
    }

    /// 50,000 tiles, the instance budget: a root and a grid of leaves.
    static func fiftyThousand() -> [Tile] {
        var tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 1000, height: 1000), node: 0, depth: 0)]
        let w = 1000.0 / 250, hgt = 1000.0 / 200
        outer: for gy in 0..<200 {
            for gx in 0..<250 {
                if tiles.count == 50_000 { break outer }
                tiles.append(
                    Tile(rect: CGRect(x: Double(gx) * w, y: Double(gy) * hgt, width: w, height: hgt),
                         node: UInt32(tiles.count), depth: 1))
            }
        }
        return tiles
    }

    /// Reported in docs/benchmarks.md, not asserted (spec §12). Each query
    /// misses the cache (`invalidate`) and lands near the top left, so the
    /// backward scan runs through almost the whole list: the worst case.
    func test_hit_test_of_50k_tiles_measured() {
        let tiles = Self.fiftyThousand()
        XCTAssertEqual(tiles.count, 50_000, "precondition: the instance budget")
        var rng = SplitMix64(seed: 42)
        let points = (0..<100).map { _ in CGPoint(x: rng.unit() * 40, y: rng.unit() * 20) }
        var h = HitTester()
        for p in points {
            XCTAssertEqual(h.tile(at: p, in: tiles), Self.deepest(p, tiles), "precondition: correct before timing")
        }
        // XCTest reports the average per block of 100 queries.
        var sink = 0
        measure {
            for p in points {
                h.invalidate()
                sink &+= h.tile(at: p, in: tiles) ?? 0
            }
        }
        XCTAssertGreaterThan(sink, 0)
    }
}
