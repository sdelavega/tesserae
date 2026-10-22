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

import XCTest
@testable import TesseraeKit

final class LayoutHeaderTests: XCTestCase {
    private func fixture() -> TestSnapshot {
        TestSnapshot(.dir("/R", [.dir("folder", [.file("a", 60), .file("b", 40)])]))
    }
    private func layout(_ t: TestSnapshot, _ w: CGFloat = 96, _ h: CGFloat = 48, _ p: LayoutParameters = .init()) -> [Tile] {
        squarify(t.snapshot, root: 0, in: CGRect(x: 0, y: 0, width: w, height: h), p)
    }
    func test_header_reserved_only_when_96x48() throws {
        let t = fixture()
        XCTAssertNil(try XCTUnwrap(layout(t, 95, 200).first { $0.node == t["folder"] }).headerRect)
        XCTAssertNil(try XCTUnwrap(layout(t, 96, 47).first { $0.node == t["folder"] }).headerRect)
        XCTAssertEqual(try XCTUnwrap(layout(t).first { $0.node == t["folder"] }).headerRect?.height, 16)
    }
    func test_children_laid_out_below_header() throws {
        let t = fixture(), tiles = layout(t)
        let folder = try XCTUnwrap(tiles.first { $0.node == t["folder"] })
        let kids = tiles.filter { $0.parent == folder.node }
        XCTAssertEqual(kids.count, 2)
        for child in kids { XCTAssertGreaterThanOrEqual(child.rect.minY, folder.rect.minY + 16) }
        XCTAssertEqual(kids.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }, 96 * 32, accuracy: 0.001)
    }
    func test_folder_tile_area_still_proportional_among_siblings() throws {
        let t = TestSnapshot(.dir("/R", [.dir("big", [.file("a", 60)]), .dir("small", [.file("b", 40)])]))
        let on = layout(t, 400, 300), off = layout(t, 400, 300, .init(showHeaders: false))
        let a = try XCTUnwrap(on.first { $0.node == t["big"] })
        let b = try XCTUnwrap(on.first { $0.node == t["small"] })
        XCTAssertNotNil(a.headerRect); XCTAssertNotNil(b.headerRect)
        XCTAssertEqual(a.rect.width * a.rect.height / (b.rect.width * b.rect.height), 1.5, accuracy: 0.001)
        XCTAssertEqual(on.filter { $0.parent == 0 }.map(\.rect), off.filter { $0.parent == 0 }.map(\.rect))
    }
    func test_headers_off_reserves_nothing() throws {
        let t = fixture(), tiles = layout(t, 96, 48, .init(showHeaders: false))
        XCTAssertTrue(tiles.allSatisfy { $0.headerRect == nil })
        let kids = tiles.filter { $0.parent == t["folder"] }
        XCTAssertEqual(kids.count, 2)
        XCTAssertEqual(kids.reduce(CGFloat(0)) { $0 + $1.rect.width * $1.rect.height }, 96 * 48, accuracy: 0.001)
        let expected = [CGRect(x: 0, y: 0, width: 57.6, height: 48), CGRect(x: 57.6, y: 0, width: 38.4, height: 48)]
        for (actual, want) in zip(kids.map(\.rect), expected) {
            XCTAssertEqual(actual.minX, want.minX, accuracy: 1e-10)
            XCTAssertEqual(actual.minY, want.minY, accuracy: 1e-10)
            XCTAssertEqual(actual.width, want.width, accuracy: 1e-10)
            XCTAssertEqual(actual.height, want.height, accuracy: 1e-10)
        }
    }
    func test_header_hit_resolves_to_folder() throws {
        let t = fixture(), tiles = layout(t)
        var hit = HitTester()
        let i = try XCTUnwrap(hit.tile(at: CGPoint(x: 20, y: 8), in: tiles))
        XCTAssertEqual(tiles[i].node, t["folder"])
    }
    func test_folder_with_strip_gets_no_label() throws {
        let t = fixture(), tiles = layout(t, 300, 200)
        XCTAssertNotNil(try XCTUnwrap(tiles.first { $0.node == t["folder"] }).headerRect)
        let labels = placeLabels(tiles, in: t.snapshot, measure: { _ in CGSize(width: 20, height: 12) })
        XCTAssertFalse(labels.isEmpty)
        XCTAssertFalse(labels.contains { $0.tile.node == t["folder"] })
        let headers = placeHeaderLabels(tiles, in: t.snapshot, measure: { _ in CGSize(width: 20, height: 12) })
        XCTAssertEqual(headers.map { $0.tile.node }, [t["folder"]])
        XCTAssertEqual(headers.first?.rect.minY, 2)
    }
}
