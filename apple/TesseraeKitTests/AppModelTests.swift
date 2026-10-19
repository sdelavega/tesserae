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
import Metal
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
        old.zoomRunning = false // the renderer completed navigation before this rescan
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

    func test_frame_capture_rejects_late_callbacks_and_keeps_duration_units() throws {
        let timer = FrameTimer(enabled: true)
        timer.startCapture()
        let stale = timer.begin("encode", at: 10)
        timer.startCapture()
        timer.end(stale, at: 100)
        XCTAssertTrue(timer.samples.isEmpty, "callbacks from an earlier capture cannot contaminate this one")
        let first = timer.begin("encode", at: 100)
        timer.end(first, at: 100.002)
        let second = timer.begin("encode", at: 101)
        timer.end(second, at: 101.020)
        let samples = timer.samples
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].seconds, 0.002, accuracy: 1e-10)
        XCTAssertEqual(samples[1].seconds, 0.020, accuracy: 1e-10)
        XCTAssertEqual(FrameTimer.percentile99(samples.map(\.seconds)), 0.020, accuracy: 1e-10)
    }

    func test_return_zoom_shrinks_the_old_root_into_its_parent_tile() throws {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let target = CGRect(x: 100, y: 50, width: 200, height: 300)
        let child = [Tile(rect: viewport, node: 7, depth: 0)]
        let parent = [Tile(rect: viewport, node: 0, depth: 0), Tile(rect: target, node: 7, depth: 1)]
        let from = try XCTUnwrap(TreemapView.navigationZoomRect(old: child, new: parent, viewport: viewport))
        let animation = ZoomAnimation(from: from, viewport: viewport)
        XCTAssertFalse(animation.isFinished)
        let result = viewport.applying(animation.transform(at: animation.duration))
        XCTAssertEqual(result.minX, target.minX, accuracy: 1e-8)
        XCTAssertEqual(result.minY, target.minY, accuracy: 1e-8)
        XCTAssertEqual(result.width, target.width, accuracy: 1e-8)
        XCTAssertEqual(result.height, target.height, accuracy: 1e-8)
        XCTAssertEqual(TreemapView.navigationZoomRect(old: parent, new: child, viewport: viewport), target)
        XCTAssertNil(TreemapView.navigationZoomRect(old: parent, new: parent, viewport: viewport))
    }

    func test_navigation_defers_labels_and_table_until_zoom_settles() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        let oldGeneration = session.layoutGeneration
        session.navigator.descend(into: t["sub"])
        session.setZoomRunning(false, generation: oldGeneration)
        XCTAssertEqual(session.tiles.first?.node, t["sub"])
        XCTAssertTrue(session.labels.isEmpty, "do not measure labels on the navigation critical path")
        await session.waitForTable()
        XCTAssertNil(session.table.content, "defer table traversal and publication during motion")
        session.zoomRunning = true
        XCTAssertTrue(session.labels.isEmpty)
        session.zoomRunning = false
        await session.waitForTable()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertEqual(Set(session.table.rows), [t["large"], t["small"]])
        session.navigator.ascend()
        XCTAssertTrue(session.labels.isEmpty)
        session.zoomRunning = false // a fallback or cancelled animation settles without starting
        await session.waitForTable()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        session.navigator.descend(into: t["empty"])
        await session.waitForTable()
        XCTAssertTrue(session.isEmpty)
        XCTAssertNotNil(session.table.content, "an empty folder has no renderer to send a completion callback")
        XCTAssertTrue(session.table.rows.isEmpty)
    }

    func test_renderer_inputs_only_rebuild_when_their_identity_or_values_change() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = try XCTUnwrap(TreemapRenderer(device: device))
        let a = TestSnapshot(.dir("/A", [.file("one.mp4", 20)]))
        let b = TestSnapshot(.dir("/B", [.file("one.txt", 20)]))
        let coordinator = TreemapView.Coordinator()
        var tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 100, height: 80), node: 1, depth: 0)]
        var palette = Palette.colours(.depth, dark: false)
        var calls = 0
        func install(_ snapshot: Snapshot?, _ mode: ColourMode?, dark: Bool = false) {
            coordinator.updateRenderer(renderer, tiles: tiles, palette: palette, dark: dark,
                snapshot: snapshot, mode: mode, colourOf: { _ in calls += 1; return 2 })
        }
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 1)
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 1, "hover or zoom-state updates do not rebuild identical input")
        tiles[0].flags |= Tile.Flag.selected
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 2, "selection invalidates the input")
        install(a.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 3, "a mode change invalidates even if its palette bytes match")
        install(b.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 4, "new snapshot names can map to different colours")
        palette[2] = SIMD4(1, 0, 0, 1)
        install(b.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 5)
        install(b.snapshot, .typeFocus([.video]), dark: true)
        XCTAssertEqual(calls, 6)
        install(nil, nil)
        install(nil, nil)
        XCTAssertEqual(calls, 8, "arbitrary closures without an identity remain dynamic")
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
