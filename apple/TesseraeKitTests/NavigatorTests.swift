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
import Metal
import MetalKit
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
        XCTAssertFalse(Self.click(interaction, CGPoint(x: fileTile.rect.midX, y: fileTile.rect.midY)))
        var withAggregate = tiles
        withAggregate.append(
            Tile(rect: fileTile.rect, node: Tile.noNode, depth: fileTile.depth, flags: Tile.Flag.aggregated,
                 aggregateCount: 3, aggregateBytes: 9))
        _ = interaction.setTiles(withAggregate)
        XCTAssertFalse(Self.click(interaction, CGPoint(x: fileTile.rect.midX, y: fileTile.rect.midY)))
        XCTAssertEqual(nav.root, t["/r"])
        let midTile = tiles.first { $0.node == t["b.bin"] }!  // inside mid/: the deepest tile is the file
        XCTAssertFalse(Self.click(interaction, CGPoint(x: midTile.rect.midX, y: midTile.rect.midY)))
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
        let deepLayout = squarify(t.snapshot, root: t["deep"], in: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(interaction.setTiles(deepLayout), deepTile.rect, "the zoom starts from the hovered rect")
        XCTAssertNil(interaction.setTiles(bare), "and only once")
        // ... and so does a click.
        nav.ascend()
        nav.ascend()
        _ = interaction.setTiles(tiles)
        _ = interaction.setTiles(bare)
        XCTAssertTrue(Self.click(interaction, CGPoint(x: deepTile.rect.midX, y: deepTile.rect.midY)))
        XCTAssertEqual(nav.root, t["deep"])
        XCTAssertEqual(interaction.setTiles(deepLayout), deepTile.rect, "the zoom starts from the clicked rect")
    }

    /// A press and a release at `p`.
    static func click(_ i: TreemapInteraction, _ p: CGPoint) -> Bool {
        i.press(at: p)
        return i.release(at: p)
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

    // MARK: Fix round 1

    static let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    static func centre(_ t: Tile) -> CGPoint { CGPoint(x: t.rect.midX, y: t.rect.midY) }

    /// A recorded descend rect is used only for the layout of the node it
    /// descended into, and is dropped by every other move and by a resize.
    func test_pending_zoom_is_dropped_by_other_moves_and_by_a_resize() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        let rootTiles = squarify(t.snapshot, root: nav.root, in: Self.bounds)
        let midTile = rootTiles.first { $0.node == t["mid"] }!
        var bare = rootTiles
        bare.removeAll { $0.node == t["b.bin"] }  // so mid/'s centre is mid/'s own tile
        let midLayout = squarify(t.snapshot, root: t["mid"], in: Self.bounds)

        func descendIntoMid(_ i: TreemapInteraction) {
            _ = i.setTiles(rootTiles)
            _ = i.setTiles(bare)
            XCTAssertTrue(Self.click(i, Self.centre(midTile)), "precondition: descended")
            XCTAssertNotNil(i.pendingZoom, "precondition: a zoom is pending")
        }

        // A resize before the owner lays out the new root: the coordinator's
        // size callback drops the rect, so the relayout does not zoom.
        let coordinator = TreemapView.Coordinator()
        coordinator.interaction.navigator = nav
        descendIntoMid(coordinator.interaction)
        let view = MTKView(frame: Self.bounds, device: nil)
        coordinator.mtkView(view, drawableSizeWillChange: CGSize(width: 800, height: 600))
        XCTAssertNil(coordinator.interaction.setTiles(midLayout), "zoomed from the rect of before the resize")

        // Tiles that are not the target's layout (here: the old root laid out
        // again at a new size) never zoom, and drop the rect.
        nav.ascend()
        let i = TreemapInteraction()
        i.navigator = nav
        descendIntoMid(i)
        let resized = squarify(t.snapshot, root: t["/r"], in: CGRect(x: 0, y: 0, width: 500, height: 280))
        XCTAssertNil(i.setTiles(resized), "zoomed a layout of another root")
        XCTAssertNil(i.setTiles(midLayout), "the stale rect survived a tiles change")

        // Ascend, sibling moves and a replaced navigator drop it too.
        for move in ["ascend", "previous", "next", "navigator"] {
            nav.ascend()
            descendIntoMid(i)
            switch move {
            case "ascend": i.key(.ascend)
            case "previous": i.key(.previousSibling)
            case "next": i.key(.nextSibling)
            default: i.navigator = Navigator(snapshot: t.snapshot)
            }
            XCTAssertNil(i.pendingZoom, "\(move) kept the pending zoom")
            i.navigator = nav
        }
        // Re-assigning the same navigator keeps it.
        nav.ascend()
        descendIntoMid(i)
        i.navigator = nav
        XCTAssertEqual(i.setTiles(midLayout), midTile.rect)
    }

    /// The views are not flipped (their layers draw as before); event
    /// locations, bottom-left origin, are turned into top-left tile points.
    func test_events_are_flipped_into_tile_coordinates_without_flipping_the_views() throws {
        let size = CGRect(x: 0, y: 0, width: 200, height: 100)
        let tiles = [
            Tile(rect: CGRect(x: 0, y: 0, width: 200, height: 30), node: 1, depth: 0),  // the top strip
            Tile(rect: CGRect(x: 0, y: 30, width: 200, height: 70), node: 2, depth: 0),
        ]
        XCTAssertEqual(TreemapInteraction.tilePoint(CGPoint(x: 7, y: 90), viewHeight: 100), CGPoint(x: 7, y: 10))
        let views: [NSView] = [
            TreemapView.FallbackView(frame: size),
            TreemapView.InteractiveMTKView(frame: size, device: MTLCreateSystemDefaultDevice()),
        ]
        for view in views {
            XCTAssertFalse(view.isFlipped, "\(type(of: view)) is flipped")
            let interaction = TreemapInteraction()
            _ = interaction.setTiles(tiles)
            (view as? TreemapView.FallbackView)?.interaction = interaction
            (view as? TreemapView.InteractiveMTKView)?.interaction = interaction
            let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = view
            func move(_ y: CGFloat) throws {
                let e = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .mouseMoved, location: CGPoint(x: 20, y: y), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
                view.mouseMoved(with: e)
            }
            try move(90)  // near the top of an unflipped view
            XCTAssertEqual(interaction.hovered, 0, "\(type(of: view)): y = 90 is the top tile")
            try move(10)
            XCTAssertEqual(interaction.hovered, 1, "\(type(of: view)): y = 10 is the bottom tile")
            window.contentView = nil
        }
    }

    func test_click_needs_press_and_release_on_one_tile() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        var tiles = squarify(t.snapshot, root: nav.root, in: Self.bounds)
        tiles.removeAll { [t["b.bin"], t["c.bin"]].contains($0.node) }
        let mid = tiles.first { $0.node == t["mid"] }!
        let small = tiles.first { $0.node == t["small"] }!
        let i = TreemapInteraction()
        i.navigator = nav
        _ = i.setTiles(tiles)
        i.press(at: Self.centre(mid))
        XCTAssertFalse(i.release(at: Self.centre(small)), "a drag from mid/ to small/ descended")
        XCTAssertEqual(nav.root, t["/r"])
        XCTAssertFalse(i.release(at: Self.centre(small)), "a release with no press descended")
        i.press(at: Self.centre(small))
        XCTAssertTrue(i.release(at: Self.centre(small)))
        XCTAssertEqual(nav.root, t["small"])
    }

    func test_return_takes_the_first_descendable_and_works_after_new_tiles() {
        let t = Self.tree()
        let nav = Navigator(snapshot: t.snapshot)
        var tiles = squarify(t.snapshot, root: nav.root, in: Self.bounds)
        tiles.removeAll { $0.node == t["c.bin"] }
        let file = tiles.first { $0.node == t["top.mp4"] }!
        let si = tiles.firstIndex { $0.node == t["small"] }!
        tiles[si].flags |= Tile.Flag.selected
        let i = TreemapInteraction()
        var reports: [Int?] = []
        i.onHover = { reports.append($0) }
        i.navigator = nav
        _ = i.setTiles(tiles)
        // A file hovered, a directory selected: Return takes the directory.
        i.hover(at: Self.centre(file))
        XCTAssertEqual(i.hovered, tiles.firstIndex(of: file), "precondition: hovering the file")
        i.key(.descend)
        XCTAssertEqual(nav.root, t["small"], "Return gave up on the hovered file")

        // New tiles under a pointer that has not moved: hovered is the tile
        // now under it, so Return works at once.
        nav.ascend()
        var moved = squarify(t.snapshot, root: nav.root, in: Self.bounds)
        moved.removeAll { $0.node == t["c.bin"] }
        let smallNow = moved.first { $0.node == t["small"] }!
        i.hover(at: Self.centre(smallNow))
        // A different list (nothing selected now) with small/ in the same place.
        let swapped = moved + [Tile(rect: .zero, node: Tile.noNode, depth: 9, flags: Tile.Flag.aggregated)]
        XCTAssertFalse(swapped.contains { $0.flags & Tile.Flag.selected != 0 }, "precondition: only hover can help")
        _ = i.setTiles(swapped)
        XCTAssertEqual(i.hovered, swapped.firstIndex { $0.node == t["small"] }, "not re-hit after new tiles")
        i.key(.descend)
        XCTAssertEqual(nav.root, t["small"])
        XCTAssertTrue(reports.contains(tiles.firstIndex(of: file)), "precondition: hover was reported")
    }
}
