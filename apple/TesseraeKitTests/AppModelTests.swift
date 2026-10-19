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
import Combine
import TesseraeFFI
import XCTest
@testable import TesseraeKit

@MainActor
final class AppModelTests: XCTestCase {
    func test_banner_text_for_every_incomplete_code() throws {
        let cases: [(UInt32, String)] = [
            (UInt32(TESS_INCOMPLETE_NONE), ""),
            (UInt32(TESS_INCOMPLETE_CANCELLED), "cancelled"),
            (UInt32(TESS_INCOMPLETE_NODE_BUDGET), "node limit"),
            (UInt32(TESS_INCOMPLETE_OUT_OF_MEMORY), "memory"),
            (UInt32(TESS_INCOMPLETE_STALLED), "stalled"),
            (UInt32(TESS_INCOMPLETE_FD_EXHAUSTED), "file descriptors"),
            (UInt32(TESS_INCOMPLETE_MALFORMED_BATCH), "malformed"),
            (UInt32(TESS_INCOMPLETE_VOLUME_LOST), "volume"),
        ]
        XCTAssertEqual(cases.count, 8)
        for (code, word) in cases {
            var stats = TessScanStats()
            stats.incomplete = code
            let text = ScanBanner.text(for: stats, stalledAt: "/blocked/path")
            if code == 0 { XCTAssertNil(text); continue }
            let message = try XCTUnwrap(text)
            XCTAssertTrue(message.lowercased().contains(word), message)
            XCTAssertTrue(message.contains("Partial"), message)
            if code == UInt32(TESS_INCOMPLETE_STALLED) { XCTAssertTrue(message.contains("/blocked/path")) }
        }
        var unknown = TessScanStats()
        unknown.incomplete = 999
        XCTAssertNotNil(ScanBanner.text(for: unknown, stalledAt: nil))
    }

    func test_banner_mentions_unreadable_and_errors_when_complete() throws {
        var stats = TessScanStats()
        stats.errors = 17
        stats.unreadable_count = 23
        let text = try XCTUnwrap(ScanBanner.text(for: stats, stalledAt: nil))
        XCTAssertTrue(text.contains("17 errors"), text)
        XCTAssertTrue(text.contains("23 unreadable"), text)
        stats.errors = 0
        XCTAssertNotNil(ScanBanner.text(for: stats, stalledAt: nil))
        stats.errors = 17
        stats.unreadable_count = 0
        XCTAssertNotNil(ScanBanner.text(for: stats, stalledAt: nil))
    }

    func test_empty_scan_shows_empty_state() throws {
        let tree = TestSnapshot(.dir("/empty", []))
        let app = AppModel()
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 600, height: 400))
        XCTAssertTrue(session.tiles.isEmpty)
        XCTAssertTrue(session.isEmpty)
        let denied = TestSnapshot(.denied("/denied"))
        app.replaceSnapshot(denied.snapshot)
        let unreadable = try XCTUnwrap(app.session)
        unreadable.resize(to: CGSize(width: 600, height: 400))
        XCTAssertEqual(unreadable.tiles.count, 1)
        XCTAssertFalse(unreadable.isEmpty, "permission denial is not an empty folder")
    }

    func test_rescan_swaps_snapshot_atomically() async throws {
        let a = TestSnapshot(.dir("/A", [.dir("sub", [.file("a", 20), .file("b", 10)])]))
        let b = TestSnapshot(.dir("/B", [.file("only", 100)]))
        let app = AppModel()
        app.replaceSnapshot(a.snapshot)
        let old = try XCTUnwrap(app.session)
        old.resize(to: CGSize(width: 600, height: 400))
        old.navigator.descend(into: a["sub"])
        old.selection.nodes = [a["b"]]
        old.hover(tile: try XCTUnwrap(old.tiles.firstIndex { $0.node == a["b"] }))
        await old.waitForTable()
        XCTAssertNotNil(old.inspector)
        XCTAssertFalse(old.table.rows.isEmpty)
        XCTAssertFalse(old.selection.nodes.isEmpty)
        var sawNew = false
        let observation = app.$session.dropFirst().sink { session in
            guard let session else { return XCTFail("replacement must be a session") }
            sawNew = true
            XCTAssertTrue(session.snapshot === b.snapshot)
            XCTAssertEqual(session.navigator.root, b.snapshot.root)
            XCTAssertTrue(session.selection.nodes.isEmpty)
            XCTAssertNil(session.inspector)
            XCTAssertNil(session.table.content)
            XCTAssertTrue(session.tiles.isEmpty)
        }
        app.replaceSnapshot(b.snapshot)
        XCTAssertTrue(sawNew)
        withExtendedLifetime(observation) {}
        let current = try XCTUnwrap(app.session)
        current.resize(to: CGSize(width: 600, height: 400))
        await current.waitForTable()
        XCTAssertTrue(try XCTUnwrap(current.table.content).snapshot === b.snapshot)
        XCTAssertEqual(current.table.rows, [b["only"]])
        old.hover(tile: 9999)
        XCTAssertNil(current.inspector, "old callbacks cannot change the new session")
    }

    func test_navigation_relayouts_and_selection_reaches_tiles() throws {
        let tree = TestSnapshot(.dir("/R", [.dir("sub", [.file("one", 20), .file("two", 10)])]))
        let app = AppModel()
        app.replaceSnapshot(tree.snapshot)
        let s = try XCTUnwrap(app.session)
        s.resize(to: CGSize(width: 600, height: 400))
        XCTAssertEqual(s.tiles.first?.node, tree.snapshot.root)
        s.navigator.descend(into: tree["sub"])
        XCTAssertEqual(s.tiles.first?.node, tree["sub"])
        s.selection.nodes = [tree["two"]]
        let selected = s.tiles.filter { $0.flags & Tile.Flag.selected != 0 }
        XCTAssertEqual(selected.map(\.node), [tree["two"]])
        s.resize(to: .zero)
        XCTAssertTrue(s.tiles.isEmpty)
        s.resize(to: CGSize(width: 500, height: 300))
        XCTAssertEqual(s.tiles.first?.node, tree["sub"])
    }

    func test_focus_legend_has_voiceover_labels() {
        let app = AppModel()
        app.toggleFocus(.video)
        app.toggleFocus(.images)
        app.toggleFocus(.audio)
        app.toggleFocus(.archives)
        XCTAssertEqual(app.focusKinds, [.video, .images, .audio])
        let legend = app.focusLegend(dark: false)
        XCTAssertEqual(legend.count, 4, "three kinds plus the neutral category")
        XCTAssertEqual(legend.map(\.accessibilityLabel), ["Video files", "Image files", "Audio files", "Other files and folders"])
        XCTAssertEqual(legend.prefix(3).map(\.colour), Array(Palette.colours(.typeFocus(app.focusKinds), dark: false).dropFirst(2)))
        app.toggleFocus(.images)
        XCTAssertEqual(app.focusKinds, [.video, .audio])
    }

    func test_treemap_click_writes_shared_selection() throws {
        let tree = TestSnapshot(.dir("/R", [.file("one", 20)]))
        let selection = Selection()
        let interaction = TreemapInteraction()
        interaction.navigator = Navigator(snapshot: tree.snapshot)
        interaction.selection = selection
        _ = interaction.setTiles([Tile(rect: CGRect(x: 0, y: 0, width: 200, height: 100), node: tree["one"], depth: 1)])
        interaction.press(at: CGPoint(x: 30, y: 30))
        XCTAssertFalse(interaction.release(at: CGPoint(x: 30, y: 30)))
        XCTAssertEqual(selection.nodes, [tree["one"]])
    }
}
