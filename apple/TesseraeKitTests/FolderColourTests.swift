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
import CoreFoundation
import XCTest
@testable import TesseraeKit

final class FolderColourTests: XCTestCase {
    private let light: [UInt32] = [
        0x256bc0, 0x0d59ac, 0x004893, 0x003976,
        0xeb6834, 0xff7d4b, 0xff9e7b, 0xfebca5,
        0x1baf7a, 0x3bc28c, 0x53d69e, 0x69eab1,
        0xeda100, 0xffb63e, 0xffd08f, 0xffe9cc,
        0xe87ba4, 0xfd8eb7, 0xffaeca, 0xffcddd,
        0x007a00, 0x036602, 0x025301, 0x014001,
        0x6250d6, 0x533cc1, 0x4427ad, 0x370a99,
        0xe34948, 0xf95d5a, 0xfe8079, 0xfea29a,
    ]
    private let dark: [UInt32] = [
        0x3987e5, 0x4c9afa, 0x6faefe, 0x92c2ff,
        0xd95926, 0xee6c3b, 0xfe8458, 0xffa484,
        0x199e70, 0x37b182, 0x4ec494, 0x64d8a6,
        0xc98500, 0xdd982a, 0xf1ab43, 0xffc16c,
        0xd55181, 0xea6493, 0xff78a5, 0xff9dba,
        0x007a00, 0x036602, 0x025301, 0x014001,
        0x9085e9, 0xa298fe, 0xb5b0fe, 0xc9c7fe,
        0xe66767, 0xfb7a79, 0xfe9a97, 0xfeb9b6,
    ]
    private func hex(_ c: SIMD4<Float>) -> UInt32 {
        UInt32((c.x * 255).rounded()) << 16 | UInt32((c.y * 255).rounded()) << 8 | UInt32((c.z * 255).rounded())
    }
    func test_folder_palette_values() {
        XCTAssertEqual(light.count + dark.count, 64)
        for (appearance, expected) in [(false, light), (true, dark)] {
            let palette = Palette.colours(.folder, dark: appearance)
            XCTAssertEqual(palette.count, 34)
            XCTAssertEqual(palette.map(hex), [appearance ? 0x3a3a37 : 0xd6d5cf, 0xfab219] + expected)
            XCTAssertTrue(palette.allSatisfy { $0.w == 1 })
        }
        let pairs = [(1,7), (2,4), (2,5), (2,6), (2,8), (3,5), (3,6), (3,8), (4,8), (5,8), (6,8)]
        XCTAssertEqual(FolderSlots.conflicts, Set(pairs.map { FolderSlots.Pair($0.0, $0.1) }))
    }
    func test_every_folder_fill_label_ink_at_least_4_5() {
        func luminance(_ h: UInt32) -> Double {
            let rgb = [Double((h >> 16) & 255), Double((h >> 8) & 255), Double(h & 255)].map { $0 / 255 }
            let v = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
        }
        func ratio(_ a: Double, _ b: Double) -> Double { (max(a,b) + 0.05) / (min(a,b) + 0.05) }
        var minimum = Double.infinity, minimumHex: UInt32 = 0
        for appearance in [false, true] {
            let fills = Palette.colours(.folder, dark: appearance).dropFirst(2)
            XCTAssertEqual(fills.count, 32)
            for c in fills {
                let h = hex(c), l = luminance(h)
                let best = max(ratio(l, luminance(0x0b0b0b)), ratio(l, luminance(0xf0efec)))
                XCTAssertGreaterThanOrEqual(best, 4.5)
                XCTAssertEqual(ratio(l, luminance({ let ink = LabelStyle.ink(over: c); return UInt32(ink.red) << 16 | UInt32(ink.green) << 8 | UInt32(ink.blue) }())), best, accuracy: 0.0001)
                if best < minimum { minimum = best; minimumHex = h }
            }
        }
        XCTAssertEqual(minimumHex, 0x256bc0)
        XCTAssertEqual((minimum * 100).rounded() / 100, 4.63)
    }
    private func clique(_ n: Int) -> [(node: UInt32, rect: CGRect, bytes: UInt64)] {
        // Facing edges are within 3pt for every pair, with >1pt vertical overlap.
        (0..<n).map { (UInt32($0), CGRect(x: 0, y: 0, width: 2, height: 10), UInt64(n - $0)) }
    }
    func test_assignment_largest_first_lowest_free_slot() {
        let children = clique(3)
        XCTAssertTrue(touches(children[0].rect, children[2].rect))
        XCTAssertEqual(FolderSlots.assign(rootChildren: children.reversed()), [0: 1, 1: 2, 2: 3])
        let ties = children.map { (node: $0.node, rect: $0.rect, bytes: UInt64(1)) }
        XCTAssertEqual(FolderSlots.assign(rootChildren: ties.reversed()), [0: 1, 1: 2, 2: 3])
    }
    func test_conflicting_slot_skipped_when_alternative_exists() {
        // 0 touches 1, 1 touches 2; 0 and 2 do not touch. 2 takes 1, the lowest safe slot.
        let rects = [CGRect(x: 0,y: 0,width: 10,height: 10), CGRect(x: 12,y: 0,width: 10,height: 10),
                     CGRect(x: 24,y: 0,width: 10,height: 10)]
        XCTAssertFalse(touches(rects[0], rects[2]))
        let children = rects.enumerated().map { (UInt32($0.offset), $0.element, UInt64(3 - $0.offset)) }
        XCTAssertEqual(FolderSlots.assign(rootChildren: children), [0: 1, 1: 2, 2: 1])
        XCTAssertEqual(FolderSlots.assign(rootChildren: clique(3))[2], 3)
        // The first four form a clique. The last sees only slots 1 and 4:
        // slot 2 is unused but conflicts with 4, so it must take slot 3.
        let heights = [30, 10, 10, 30, 10]
        let conflictRects: [(node: UInt32, rect: CGRect, bytes: UInt64)] = heights.enumerated().map { i, height in
            let rect = CGRect(x: 0, y: i == 4 ? 20 : 0, width: 2, height: height)
            return (UInt32(i), rect, UInt64(5 - i))
        }
        XCTAssertFalse(touches(conflictRects[1].rect, conflictRects[4].rect))
        XCTAssertEqual(FolderSlots.assign(rootChildren: conflictRects), [0: 1, 1: 2, 2: 3, 3: 4, 4: 3])
    }
    func test_eight_mutually_touching_children_terminate_deterministically() {
        for n in [8, 9] {
            let children = clique(n)
            for a in children { for b in children { XCTAssertTrue(touches(a.rect, b.rect)) } }
            let slots = FolderSlots.assign(rootChildren: children)
            XCTAssertEqual(slots, FolderSlots.assign(rootChildren: children.reversed()))
            XCTAssertEqual(Set((0..<8).compactMap { slots[UInt32($0)] }), Set(1...8))
            if n == 9 { XCTAssertEqual(slots[8], 1) }
        }
    }
    func test_assignment_is_independent_of_appearance() {
        let children = clique(8), slots = FolderSlots.assign(rootChildren: clique(8))
        XCTAssertEqual(slots.count, 8)
        for appearance in [false, true] {
            XCTAssertEqual(Palette.colours(.folder, dark: appearance).count, 34)
            XCTAssertEqual(FolderSlots.assign(rootChildren: children), slots)
        }
    }
    func test_touches_gap_overlap_and_corner_boundaries() {
        let a = CGRect(x: 0,y: 0,width: 10,height: 10)
        XCTAssertTrue(touches(a, CGRect(x: 13,y: 8,width: 10,height: 10)))
        XCTAssertFalse(touches(a, CGRect(x: 13.01,y: 0,width: 10,height: 10)))
        XCTAssertFalse(touches(a, CGRect(x: 12,y: 9,width: 10,height: 10)))
        XCTAssertFalse(touches(a, CGRect(x: 10,y: 10,width: 10,height: 10)))
        XCTAssertTrue(touches(a, CGRect(x: 8,y: 12,width: 10,height: 10)))
        XCTAssertTrue(touches(CGRect(x: 8,y: 12,width: 10,height: 10), a))
    }
    func test_generated_adjacency_matches_touches() {
        var seed: UInt64 = 0x7465737365726165
        func next(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(limit))
        }
        var touchingPairs = 0, separatedPairs = 0
        for _ in 0..<600 {
            let count = 2 + next(30)
            let children = (0..<count).map { i in
                (node: UInt32(i), rect: CGRect(x: Double(next(80)) / 2, y: Double(next(80)) / 2,
                    width: Double(1 + next(40)) / 2, height: Double(1 + next(40)) / 2), bytes: UInt64(next(20)))
            }
            let sorted = children.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.node < $1.node }
            let adjacency = FolderSlots.adjacency(sorted.map(\.rect))
            XCTAssertEqual(adjacency.count, count)
            for i in sorted.indices {
                let expectedNeighbours = Set((0..<i).filter { touches(sorted[i].rect, sorted[$0].rect) })
                XCTAssertEqual(Set(adjacency[i]), expectedNeighbours)
            }
            var expected: [UInt32: Int] = [:]
            for (i, child) in sorted.enumerated() {
                var used: Set<Int> = [], blocked: Set<Int> = []
                for other in sorted.prefix(i) {
                    if touches(child.rect, other.rect) {
                        touchingPairs += 1
                        let slot = expected[other.node]!
                        used.insert(slot)
                        for candidate in 1...8 where FolderSlots.conflicts.contains(.init(slot, candidate)) {
                            blocked.insert(candidate)
                        }
                    } else { separatedPairs += 1 }
                }
                expected[child.node] = (1...8).first { !used.contains($0) && !blocked.contains($0) }
                    ?? (1...8).first { !used.contains($0) } ?? 1
            }
            XCTAssertEqual(FolderSlots.assign(rootChildren: children.reversed()), expected)
        }
        XCTAssertGreaterThan(touchingPairs, 500)
        XCTAssertGreaterThan(separatedPairs, 500)
    }

    private func fixture() -> TestSnapshot {
        TestSnapshot(.dir("root", [.dir("folder", [.dir("nested", [.file("leaf", 100)])]), .file("loose", 50)]))
    }
    func test_loose_files_and_root_aggregate_are_neutral() {
        let t = fixture(), s = t.snapshot
        for node in [s.root, t["loose"], Tile.noNode] {
            let tile = Tile(rect: .zero, node: node, depth: 1, parent: s.root)
            XCTAssertEqual(colourIndex(for: tile, in: s, mode: .folder, slots: [t["folder"]: 2], rootChildOf: { _ in nil }), 0)
        }
        let denied = Tile(rect: .zero, node: Tile.noNode, depth: 1, flags: Tile.Flag.permDenied)
        XCTAssertEqual(colourIndex(for: denied, in: s, mode: .folder, slots: [:], rootChildOf: { _ in nil }), 1)
    }
    func test_depth_steps_cap_at_three() {
        let t = fixture()
        for depth in [1, 2, 3, 4, 5, 255] {
            let tile = Tile(rect: .zero, node: t["leaf"], depth: UInt8(depth))
            XCTAssertEqual(colourIndex(for: tile, in: t.snapshot, mode: .folder, slots: [t["folder"]: 8],
                rootChildOf: { _ in t["folder"] }), UInt16(30 + min(depth - 1, 3)))
        }
    }
    func test_aggregate_takes_folder_colour() {
        let t = fixture()
        let tile = Tile(rect: .zero, node: Tile.noNode, depth: 3, flags: Tile.Flag.aggregated, parent: t["nested"])
        XCTAssertEqual(colourIndex(for: tile, in: t.snapshot, mode: .folder, slots: [t["folder"]: 2],
            rootChildOf: { $0 == t["nested"] ? t["folder"] : nil }), 8)
        for mode in [ColourMode.age(now: Date()), .typeFocus([])] {
            XCTAssertEqual(colourIndex(for: tile, in: t.snapshot, mode: mode, slots: [t["folder"]: 2],
                rootChildOf: { _ in t["folder"] }), 0)
        }
    }
    func test_preparation_after_layout_navigation_resize_and_overlay() {
        let t = fixture(), s = t.snapshot
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tiles = squarify(s, root: s.root, in: bounds)
        let prepared = FolderColours(tiles: tiles, root: s.root, source: s)
        XCTAssertEqual(prepared.slots, [t["folder"]: 1])
        XCTAssertNil(prepared.rootChildren[t["loose"]])
        XCTAssertEqual(prepared.rootChildren[t["leaf"]], t["folder"])
        let moved = squarify(s, root: t["folder"], in: bounds)
        XCTAssertFalse(moved.isEmpty)
        let navigation = FolderColours(tiles: moved, root: t["folder"], source: s)
        XCTAssertEqual(navigation.slots, [t["nested"]: 1])
        XCTAssertEqual(navigation.rootChildren[t["leaf"]], t["nested"])
        let resized = squarify(s, root: s.root, in: CGRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertNotEqual(tiles, resized)
        XCTAssertEqual(FolderColours(tiles: resized, root: s.root, source: s).slots, prepared.slots)
        var overlay = SizeOverlay()
        overlay.remove(t["folder"], in: s)
        let source = OverlaySource(s, overlay)
        let reduced = squarify(source, root: s.root, in: bounds)
        XCTAssertFalse(reduced.isEmpty)
        XCTAssertTrue(FolderColours(tiles: reduced, root: s.root, source: source).slots.isEmpty)
    }

    func test_measure_assignment_for_50k_tiles_and_2000_root_children() {
        let tree = SyntheticTree(.dir((0..<2000).map { _ in .dir((0..<24).map { _ in .file(100) }) }))
        let tiles = squarify(tree, root: tree.rootIndex, in: CGRect(x: 0, y: 0, width: 30000, height: 30000))
        XCTAssertEqual(tiles.count, 50000)
        let children = tiles.filter { $0.parent == tree.rootIndex }.map { (node: $0.node, rect: $0.rect, bytes: tree.allocated($0.node)) }
        XCTAssertEqual(children.count, 2000)
        var samples: [Double] = []
        for _ in 0..<25 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = FolderSlots.assign(rootChildren: children)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            XCTAssertEqual(result.count, 2000)
        }
        let median = samples.sorted()[samples.count / 2]
        print("folder assignment: 50000 tiles, 2000 root children, median \(median) ms, max \(samples.max()!) ms")
        if ProcessInfo.processInfo.environment["TESSERAE_FOLDER_BENCHMARK"] == "1" {
            XCTAssertLessThan(samples.max()!, 2, "assignment budget is 2 ms with optimizations enabled")
        }
    }

}
