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

import Darwin
import Foundation
import XCTest
@testable import TesseraeKit

final class SizeOverlayTests: XCTestCase {
    func test_inspector_logical_totals_remove_and_restore_descendants() {
        let f = TestSnapshot(.dir("root", [.dir("dir", [.file("a", 80, logical: 800), .file("b", 20, logical: 200)])]))
        let s = f.snapshot
        var o = SizeOverlay()
        let tile = Tile(rect: CGRect(x: 0, y: 0, width: 100, height: 100), node: f["dir"], depth: 1, parent: s.root)
        let aggregate = Tile(rect: tile.rect, node: Tile.noNode, depth: 1, flags: Tile.Flag.aggregated,
            aggregateCount: 1, aggregateBytes: 20, parent: s.root)
        XCTAssertEqual(inspect(tileAt: 0, in: [tile], snapshot: s).logical, 1000)
        o.remove(f["a"], in: s)
        XCTAssertEqual(inspect(tileAt: 0, in: [tile], snapshot: s, overlay: o).logical, 200)
        XCTAssertEqual(inspect(tileAt: 0, in: [aggregate], snapshot: s, overlay: o).logical, 200)
        o.restore(f["a"], in: s)
        XCTAssertEqual(inspect(tileAt: 0, in: [tile], snapshot: s, overlay: o).logical, 1000)
        XCTAssertEqual(inspect(tileAt: 0, in: [aggregate], snapshot: s, overlay: o).logical, 1000)
    }

    func test_random_leaf_arithmetic_and_restore_are_exact() {
        for seed in 1...40 {
            var serial = 0
            var rng = UInt64(seed)
            func tree(_ depth: Int) -> TestSnapshot.Spec {
                serial += 1
                let name = "n\(serial)"
                rng = rng &* 6364136223846793005 &+ 1
                if depth == 0 { return .file(name, rng % 10000 + 1) }
                let count = Int(rng % 5) + 1
                return .dir(name, (0..<count).map { _ in tree(depth - 1) })
            }
            let fixture = TestSnapshot(tree(3))
            let s = fixture.snapshot
            let originalSizes = s.nodes.map(\.allocated)
            let leaves = s.nodes.indices.map(UInt32.init).filter { !s.isDirectory($0) && s.allocated($0) > 0 }
            XCTAssertFalse(leaves.isEmpty)
            for leaf in leaves.prefix(12) {
                var overlay = SizeOverlay()
                overlay.remove(leaf, in: s)
                XCTAssertEqual(s.nodes.map(\.allocated), originalSizes)
                var ancestors: Set<UInt32> = []
                var p = s.nodes[Int(leaf)].parent
                while p != UInt32.max { ancestors.insert(p); p = s.nodes[Int(p)].parent }
                XCTAssertFalse(ancestors.isEmpty)
                XCTAssertEqual(overlay.deleted, [leaf])
                for i in s.nodes.indices.map(UInt32.init) {
                    XCTAssertEqual(overlay.deltas[i], ancestors.contains(i) ? -Int64(s.allocated(leaf)) : nil)
                    XCTAssertEqual(OverlaySource(s, overlay).allocated(i), s.allocated(i) - (ancestors.contains(i) ? s.allocated(leaf) : 0))
                }
                overlay.restore(leaf, in: s)
                XCTAssertTrue(overlay.deleted.isEmpty)
                XCTAssertTrue(overlay.deltas.isEmpty)
                XCTAssertTrue(OverlaySource(s, overlay).children(s.root).isRange)
            }
        }
    }

    func test_nested_deletions_are_idempotent_and_restore_in_either_order() {
        let f = TestSnapshot(.dir("root", [.dir("dir", [.file("a", 80), .file("b", 20)]), .file("other", 30)]))
        let s = f.snapshot
        for parentFirst in [true, false] {
            var o = SizeOverlay()
            o.remove(f["a"], in: s)
            o.remove(f["a"], in: s)
            XCTAssertEqual(o.deltas[s.root], -80)
            o.remove(f["dir"], in: s)
            XCTAssertEqual(o.deltas[s.root], -100)
            o.remove(f["b"], in: s)
            XCTAssertFalse(o.deleted.contains(f["b"]))
            XCTAssertEqual(OverlaySource(s, o).allocated(s.root), 30)
            let order = parentFirst ? [f["dir"], f["a"]] : [f["a"], f["dir"]]
            for node in order { o.restore(node, in: s) }
            o.restore(f["a"], in: s)
            XCTAssertTrue(o.deltas.isEmpty)
            XCTAssertTrue(o.deleted.isEmpty)
            XCTAssertEqual(OverlaySource(s, o).allocated(s.root), 130)
        }
    }

    func test_children_reorder_stably_and_untouched_parents_keep_ranges() {
        let f = TestSnapshot(.dir("root", [.dir("large", [.file("remove", 90), .file("left", 10)]),
            .dir("tie1", [.file("x", 40)]), .dir("tie2", [.file("y", 40)]), .denied("denied")]))
        let s = f.snapshot
        var o = SizeOverlay()
        XCTAssertTrue(s.children(s.root).isRange)
        o.remove(f["remove"], in: s)
        let src = OverlaySource(s, o)
        XCTAssertFalse(src.children(s.root).isRange)
        XCTAssertEqual(Array(src.children(s.root)), [f["tie1"], f["tie2"], f["large"], f["denied"]])
        XCTAssertEqual(Array(src.children(f["large"])), [f["left"]])
        XCTAssertTrue(src.children(f["tie1"]).isRange)
        XCTAssertEqual(src.isDirectory(f["large"]), s.isDirectory(f["large"]))
        XCTAssertTrue(src.isPermissionDenied(f["denied"]))
        XCTAssertEqual(Array(s.children(s.root)), [f["large"], f["tie1"], f["tie2"], f["denied"]])
        o.restore(f["remove"], in: s)
        XCTAssertTrue(OverlaySource(s, o).children(s.root).isRange)
        o.remove(f["denied"], in: s)
        XCTAssertTrue(o.deltas.isEmpty, "precondition: only a zero-byte node is removed")
        XCTAssertFalse(OverlaySource(s, o).children(s.root).contains(f["denied"]))
        o.restore(f["denied"], in: s)
        XCTAssertTrue(OverlaySource(s, o).children(s.root).isRange)
    }

    @MainActor
    func test_overlay_consumers_use_reordered_children_and_adjusted_sizes() throws {
        let f = TestSnapshot(.dir("root", [.dir("large", [.file("deleted", 90), .file("left", 10)]),
            .dir("other", [.file("keep", 40)])]))
        let s = f.snapshot
        var o = SizeOverlay()
        o.remove(f["deleted"], in: s)
        let source = OverlaySource(s, o)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tiles = squarify(source, root: s.root, in: bounds)
        XCTAssertEqual(tiles.filter { $0.parent == s.root }.map(\.node), [f["other"], f["large"]])
        XCTAssertFalse(tiles.contains { $0.node == f["deleted"] })
        let terminal = Tile(rect: bounds, node: f["large"], depth: 1, parent: s.root)
        let labels = placeLabels([terminal], in: s, measure: { _ in CGSize(width: 1, height: 1) },
            locale: Locale(identifier: "en_US"), overlay: o)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].text, "large  " + displaySize(10, locale: Locale(identifier: "en_US")))
        XCTAssertEqual(inspect(tileAt: 0, in: [terminal], snapshot: s, overlay: o).allocated, 10)
        let aggregate = Tile(rect: bounds, node: Tile.noNode, depth: 1, flags: Tile.Flag.aggregated,
            aggregateCount: 1, aggregateBytes: 10, parent: s.root)
        XCTAssertEqual(inspect(tileAt: 0, in: [aggregate], snapshot: s, overlay: o).logical, 10)
        var hit = HitTester()
        let point = try XCTUnwrap(tiles.first { $0.node == f["left"] }).rect
        let index = try XCTUnwrap(hit.tile(at: CGPoint(x: point.midX, y: point.midY), in: tiles))
        XCTAssertEqual(tiles[index].node, f["left"])
        XCTAssertEqual(Set(FileTableModel(snapshot: s, scope: s.root, overlay: o).defaultRows()), [f["left"], f["keep"]])
        let nav = Navigator(snapshot: s)
        nav.updateOverlay(o)
        nav.descend(into: f["other"])
        nav.sibling(1)
        XCTAssertEqual(nav.root, f["large"])
        o.remove(f["large"], in: s)
        nav.updateOverlay(o)
        XCTAssertEqual(nav.root, s.root)
        XCTAssertFalse(nav.canDescend(into: f["large"]))
        XCTAssertEqual(FileTableModel(snapshot: s, scope: s.root, overlay: o).defaultRows(), [f["keep"]])
        XCTAssertTrue(FileTableModel(snapshot: s, scope: f["large"], overlay: o).defaultRows().isEmpty)
    }

    func test_child_list_uses_int_positions_for_both_storage_cases() {
        for list in [ChildList(7..<10), ChildList([7, 9, 8])] {
            XCTAssertEqual(list.startIndex, 0)
            XCTAssertEqual(list.endIndex, 3)
            XCTAssertEqual(list[0], 7)
            XCTAssertEqual(list[list.index(before: list.endIndex)], 8 + (list.isRange ? 1 : 0))
            XCTAssertEqual(list.distance(from: list.startIndex, to: list.endIndex), 3)
            XCTAssertEqual(Array(list.dropFirst().prefix(1)), [list[1]])
        }
        XCTAssertTrue(ChildList(7..<10).isRange)
        XCTAssertFalse(ChildList([7, 9, 8]).isRange)
    }

    func test_empty_overlay_layout_matches_snapshot_over_random_trees() {
        for seed in 1...40 {
            var next = 0
            func tree(_ depth: Int) -> TestSnapshot.Spec {
                next += 1
                let name = "n\(next)"
                if depth == 0 { return .file(name, UInt64((next * seed) % 1000)) }
                return .dir(name, (0..<5).map { _ in tree(depth - 1) })
            }
            let f = TestSnapshot(tree(3))
            let s = f.snapshot
            let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
            let plain = squarify(s, root: s.root, in: bounds)
            XCTAssertGreaterThan(plain.count, 1)
            XCTAssertEqual(squarify(OverlaySource(s, SizeOverlay()), root: s.root, in: bounds), plain)
        }
    }

    func test_rescan_thresholds_are_strict() {
        let f = TestSnapshot(.dir("root", (0..<10_001).map { .file("f\($0)", 0) }))
        var o = SizeOverlay()
        for child in f.snapshot.children(0).prefix(10_000) { o.remove(child, in: f.snapshot) }
        XCTAssertEqual(o.deleted.count, 10_000)
        XCTAssertFalse(o.needsRescan(rootAllocated: 100))
        o.remove(f["f10000"], in: f.snapshot)
        XCTAssertEqual(o.deleted.count, 10_001)
        XCTAssertTrue(o.needsRescan(rootAllocated: 100))
        let sizes = TestSnapshot(.dir("root", [.file("ten", 10), .file("one", 1), .file("rest", 89)]))
        o = SizeOverlay()
        o.remove(sizes["ten"], in: sizes.snapshot)
        XCTAssertFalse(o.needsRescan(rootAllocated: 100))
        o.remove(sizes["one"], in: sizes.snapshot)
        XCTAssertTrue(o.needsRescan(rootAllocated: 100))
    }
    @MainActor
    func test_session_execution_put_back_and_rescan_refresh_together() async throws {
        let f = TestSnapshot(.dir("/fixture", [.dir("dir", [.file("a", 80), .file("b", 20)]), .file("other", 30)]), fileIDs: true)
        let s = f.snapshot
        let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in overlayContext() })
        app.replaceSnapshot(s)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        XCTAssertTrue(session.table.rows.contains(f["a"]))
        let item = JetsamItem(nodeIndex: f["a"], path: s.rawPath(f["a"]),
            recorded: Recorded(fileID: try XCTUnwrap(s.fileID(f["a"])), device: 0, isDirectory: false), recordedSize: 80, verdict: .ok)
        session.jetsam.stage([f["a"]], in: s, context: overlayContext(), stat: OverlayStat(inode: item.recorded.fileID))
        XCTAssertEqual(session.jetsam.items.count, 1)
        let executor = Executor(trasher: OverlayTrasher(), stat: OverlayStat(inode: item.recorded.fileID), log: OverlayLog(), context: overlayContext())
        let execution = await app.executeJetsam(confirmedWarnings: [], trasher: OverlayTrasher(),
            stat: OverlayStat(inode: item.recorded.fileID), log: OverlayLog())
        let result = try XCTUnwrap(execution)
        guard case .trashed = result.outcomes.first?.1 else { return XCTFail("precondition: trash succeeded: \(result.outcomes)") }
        XCTAssertEqual(session.overlay.deleted, [f["a"]])
        XCTAssertEqual(session.source.allocated(s.root), 50)
        XCTAssertTrue(session.needsRescan)
        XCTAssertEqual(session.banner, "Sizes include 1 trashed item; rescan for exact figures")
        XCTAssertFalse(session.tiles.contains { $0.node == f["a"] })
        await session.waitForTable()
        XCTAssertFalse(session.table.rows.contains(f["a"]))
        XCTAssertEqual(Set(session.table.rows), [f["b"], f["other"]])
        let e = LogEntry(ts: Date(), action: "trash", path: String(decoding: item.path, as: UTF8.self), pathB64: nil,
            inode: item.recorded.fileID, device: 0, volumeUUID: "overlay-volume", isDirectory: false, bytes: 80, trashURL: "file:///fixture/.Trashes/a", result: "ok")
        let missing = await app.putBack(e, stat: PutBackTests.MissingStat(code: ENOENT), mover: OverlayMover(), log: OverlayLog())
        XCTAssertEqual(missing, .trashItemGone)
        XCTAssertEqual(session.overlay.deleted, [f["a"]])
        let restored = await app.putBack(e, stat: OverlayRestoreStat(inode: item.recorded.fileID), mover: OverlayMover(), log: OverlayLog())
        XCTAssertEqual(restored, .restored)
        XCTAssertTrue(session.overlay.deleted.isEmpty)
        XCTAssertEqual(session.source.allocated(s.root), 130)
        XCTAssertFalse(session.needsRescan)
        XCTAssertNil(session.banner)
        XCTAssertTrue(session.tiles.contains { $0.node == f["a"] })
        await session.waitForTable()
        XCTAssertTrue(session.table.rows.contains(f["a"]))
        // A successful execution consumes the staged entry; Put Back does not
        // grant another review. Explicitly stage the restored fixture for retry.
        session.jetsam.stage([f["a"]], in: s, context: overlayContext(),
            stat: OverlayStat(inode: item.recorded.fileID), overlay: session.overlay)
        XCTAssertEqual(session.jetsam.items.first?.overlayRevision, session.overlay.revision)
        let failed = Executor(trasher: OverlayTrasher(), stat: PutBackTests.MissingStat(code: ENOENT),
            log: OverlayLog(), context: overlayContext())
        let failure = await session.execute(using: failed, confirmedWarnings: [])
        guard case .identityChanged = failure.outcomes.first?.1 else { return XCTFail("precondition: execution failed") }
        XCTAssertTrue(session.overlay.deleted.isEmpty)
        _ = await session.execute(using: executor, confirmedWarnings: [])
        XCTAssertFalse(session.overlay.deleted.isEmpty)
        app.replaceSnapshot(s)
        XCTAssertTrue(try XCTUnwrap(app.session).overlay.deleted.isEmpty)
        XCTAssertTrue(app.session !== session)
    }
}

private func overlayContext() -> GuardContext {
    GuardContext(scanRoot: Data("/fixture".utf8), volumeRoot: Data("/".utf8), scanRootDevice: 0,
        appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
}

private struct OverlayStat: FileStat {
    let inode: UInt64
    func lstat(_ path: Data) -> StatResult {
        .ok(Observed(device: 0, flags: 0, isDirectory: path != Data("/fixture/dir/a".utf8), linkCount: 1), fileID: inode, isSymlink: false)
    }
}

private struct OverlayRestoreStat: FileStat {
    func volumeUUID(_ path: Data) -> String? { "overlay-volume" }
    let inode: UInt64
    func lstat(_ path: Data) -> StatResult {
        if path == Data("/fixture/dir/a".utf8) { return .error(errno: ENOENT) }
        return .ok(Observed(device: 0, flags: 0, isDirectory: path == Data("/fixture/dir".utf8), linkCount: 1), fileID: inode, isSymlink: false)
    }
}

private struct OverlayTrasher: Trasher {
    func trash(_ url: URL) throws -> URL { URL(fileURLWithPath: "/fixture/.Trashes/a") }
}

private struct OverlayMover: Mover {
    func move(_ from: URL, to: URL) throws {}
}

private struct OverlayLog: AuditSink {
    func append(_ entry: LogEntry) -> Bool { true }
}
