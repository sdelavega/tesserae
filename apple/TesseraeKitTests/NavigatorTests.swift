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
import XCTest

@testable import TesseraeKit

/// Navigation (spec §8 "Zoom and navigation"), and the view-side interaction
/// that drives it.
@MainActor
final class NavigatorTests: XCTestCase {
    /// /r: big/ (deep/ (x.bin), a.bin), mid/ (b.bin), small/ (c.bin),
    /// locked/ (unreadable), top.mp4.
    static func tree() -> TestSnapshot {
        TestSnapshot(
            .dir(
                "/r",
                [
                    .dir("big", [.dir("deep", [.file("x.bin", 500)]), .file("a.bin", 400)]),
                    .dir("mid", [.file("b.bin", 300)]),
                    .dir("small", [.file("c.bin", 100)]),
                    .file("top.mp4", 50),
                    .denied("locked"),
                ]))
    }

    func test_descend_ascend_and_breadcrumb_round_trip() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        XCTAssertEqual(nav.root, t["/r"])
        XCTAssertEqual(nav.breadcrumb, [t["/r"]])

        var published: [UInt32] = []
        let sub = nav.$root.dropFirst().sink { published.append($0) }
        defer { sub.cancel() }

        nav.descend(into: t["big"])
        XCTAssertEqual(nav.breadcrumb, [t["/r"], t["big"]])
        nav.descend(into: t["deep"])
        XCTAssertEqual(nav.breadcrumb, [t["/r"], t["big"], t["deep"]])
        nav.ascend()
        XCTAssertEqual(nav.breadcrumb, [t["/r"], t["big"]])
        nav.ascend()
        XCTAssertEqual(nav.breadcrumb, [t["/r"]])
        nav.ascend()  // at the top: nothing
        XCTAssertEqual(nav.root, t["/r"])

        // A click may land several levels down: straight to the grandchild.
        nav.descend(into: t["deep"])
        XCTAssertEqual(nav.breadcrumb, [t["/r"], t["big"], t["deep"]])
        // Not beneath the current root: ignored.
        nav.descend(into: t["mid"])
        XCTAssertEqual(nav.root, t["deep"])
        XCTAssertEqual(published, [t["big"], t["deep"], t["big"], t["/r"], t["deep"]], "every move published once")
    }

    func test_descend_into_file_or_aggregate_is_a_no_op() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        XCTAssertTrue(nav.canDescend(into: t["mid"]), "precondition: a directory is descendable")
        for target in [t["top.mp4"], t["a.bin"], Tile.noNode, t["locked"], t["/r"], UInt32(10_000)] {
            XCTAssertFalse(nav.canDescend(into: target), "\(target)")
            nav.descend(into: target)
            XCTAssertEqual(nav.root, t["/r"], "descend(into: \(target)) moved")
        }

        // Through the view's interaction: clicks on a file and on an
        // aggregate do nothing, a click on a directory descends.
        let tiles = squarify(t.snapshot, root: nav.root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let interaction = TreemapInteraction()
        interaction.navigator = nav
        XCTAssertNil(interaction.setTiles(tiles))
        let fileTile = tiles.first { $0.node == t["top.mp4"] }!
        XCTAssertFalse(interaction.click(at: CGPoint(x: fileTile.rect.midX, y: fileTile.rect.midY)))
        var withAggregate = tiles
        withAggregate.append(
            Tile(rect: fileTile.rect, node: Tile.noNode, depth: fileTile.depth, flags: Tile.Flag.aggregated,
                 aggregateCount: 3, aggregateBytes: 9))
        _ = interaction.setTiles(withAggregate)
        XCTAssertFalse(interaction.click(at: CGPoint(x: fileTile.rect.midX, y: fileTile.rect.midY)))
        XCTAssertEqual(nav.root, t["/r"])
        let midTile = tiles.first { $0.node == t["b.bin"] }!  // inside mid/: the deepest tile is the file
        XCTAssertFalse(interaction.click(at: CGPoint(x: midTile.rect.midX, y: midTile.rect.midY)))
        let deepTile = tiles.first { $0.node == t["deep"] }!
        XCTAssertGreaterThanOrEqual(min(deepTile.rect.width, deepTile.rect.height), 24, "precondition: deep/ is subdivided")
        let xTile = tiles.first { $0.node == t["x.bin"] }!
        // Return over a file: nothing.
        interaction.hover(at: CGPoint(x: xTile.rect.midX, y: xTile.rect.midY))
        XCTAssertEqual(interaction.hovered, tiles.firstIndex(of: xTile), "precondition: hovering the file")
        interaction.key(.descend)
        XCTAssertEqual(nav.root, t["/r"], "Return over a file descended")
        // With x.bin gone, the middle of deep/ is deep/'s own tile.
        var bare = withAggregate
        bare.removeAll { $0.node == t["x.bin"] }
        _ = interaction.setTiles(bare)
        // Return over it descends ...
        interaction.hover(at: CGPoint(x: deepTile.rect.midX, y: deepTile.rect.midY))
        interaction.key(.descend)
        XCTAssertEqual(nav.root, t["deep"], "Return over a directory")
        XCTAssertEqual(interaction.setTiles(tiles), deepTile.rect, "the zoom starts from the hovered rect")
        XCTAssertNil(interaction.setTiles(bare), "and only once")
        // ... and so does a click.
        nav.ascend()
        nav.ascend()
        _ = interaction.setTiles(tiles)
        _ = interaction.setTiles(bare)
        XCTAssertTrue(interaction.click(at: CGPoint(x: deepTile.rect.midX, y: deepTile.rect.midY)))
        XCTAssertEqual(nav.root, t["deep"])
        XCTAssertEqual(interaction.setTiles(tiles), deepTile.rect, "the zoom starts from the clicked rect")
    }

    func test_sibling_navigation_clamps_at_the_ends() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        nav.sibling(1)
        XCTAssertEqual(nav.root, t["/r"], "the snapshot's root has no siblings")
        nav.descend(into: t["mid"])
        nav.sibling(-1)
        XCTAssertEqual(nav.root, t["big"])
        nav.sibling(-1)
        XCTAssertEqual(nav.root, t["big"], "clamped at the first")
        nav.sibling(1)
        nav.sibling(1)
        XCTAssertEqual(nav.root, t["small"])
        // Files and the unreadable folder are not stops.
        nav.sibling(1)
        XCTAssertEqual(nav.root, t["small"], "clamped at the last directory")
        nav.sibling(-5)
        XCTAssertEqual(nav.root, t["big"], "a long step clamps")
        nav.sibling(Int.max)
        XCTAssertEqual(nav.root, t["small"], "an overflowing step clamps")
        nav.sibling(Int.min)
        XCTAssertEqual(nav.root, t["big"])
        XCTAssertEqual(nav.breadcrumb, [t["/r"], t["big"]])

        // Keys, through the interaction.
        let interaction = TreemapInteraction()
        interaction.navigator = nav
        interaction.key(.nextSibling)
        XCTAssertEqual(nav.root, t["mid"])
        interaction.key(.previousSibling)
        XCTAssertEqual(nav.root, t["big"])
        interaction.key(.ascend)
        XCTAssertEqual(nav.root, t["/r"])
    }

    func test_keys_map_from_special_keys_not_key_codes() throws {
        func event(_ key: NSEvent.SpecialKey, _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let chars = String(Character(Unicode.Scalar(UInt32(key.rawValue))!))
            return try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                    keyCode: 0))
        }
        XCTAssertEqual(TreemapInteraction.Key(try event(.upArrow, .command)), .ascend)
        XCTAssertNil(TreemapInteraction.Key(try event(.upArrow)), "↑ alone is not ascend")
        XCTAssertEqual(TreemapInteraction.Key(try event(.carriageReturn)), .descend)
        XCTAssertEqual(TreemapInteraction.Key(try event(.enter)), .descend)
        XCTAssertEqual(TreemapInteraction.Key(try event(.leftArrow)), .previousSibling)
        XCTAssertEqual(TreemapInteraction.Key(try event(.rightArrow)), .nextSibling)
    }
}
