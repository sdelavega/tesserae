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
import TesseraeFFI
import XCTest

@testable import TesseraeKit

@MainActor
final class ReclaimTests: XCTestCase {
    private struct FakeStat: FileStat {
        var entries: [Data: StatResult]
        func lstat(_ path: Data) -> StatResult {
            entries[path] ?? .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1),
                                 fileID: 1, isSymlink: false)
        }
    }

    private func fixture() -> TestSnapshot {
        var stats = TessScanStats(); stats.root_device = 7
        var cloud = TestSnapshot.Spec.file("cloud", 17); cloud.dataless = true
        var skipped = TestSnapshot.Spec.dir("skipped", []); skipped.skippedByRequest = true
        return TestSnapshot(.dir("/scan/root", [
            .dir("parent", [.dir("nested", [.file("leaf", 100)]), .file("sibling", 40)]),
            .file("parent-prefix", 60), cloud, skipped, .denied("denied"),
            .rawFile([0xff], key: "raw", 9)
        ]), stats: stats, fileIDs: true)
    }

    private func context(_ s: Snapshot) -> GuardContext {
        GuardContext(scanRoot: s.rawPath(s.root), volumeRoot: Data("/".utf8), scanRootDevice: s.rootDevice,
                     appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
    }

    private func fake(_ s: Snapshot) -> FakeStat {
        FakeStat(entries: Dictionary(uniqueKeysWithValues: (0..<UInt32(s.nodes.count)).map { i in
            (s.rawPath(i), .ok(Observed(device: s.rootDevice, flags: 0, isDirectory: s.isDirectory(i), linkCount: 1),
                              fileID: s.fileID(i)!, isSymlink: false))
        }))
    }

    func test_directory_preserves_mixed_unknown_cloud_and_hardlink_descendants() {
        var stats = TessScanStats(); stats.root_device = 7
        var cloud = TestSnapshot.Spec.file("cloudChild", 0); cloud.dataless = true
        var linked = TestSnapshot.Spec.file("linkedChild", 0); linked.hardlinkDuplicate = true
        var skipped = TestSnapshot.Spec.dir("skipChild", []); skipped.skippedByRequest = true
        let t = TestSnapshot(.dir("/scan/root", [.dir("mixed", [.file("known", 20), .denied("unreadable"), cloud, linked, skipped])]),
            stats: stats, fileIDs: true)
        let s = t.snapshot, j = Reclaim()
        XCTAssertEqual(s.allocated(t["mixed"]), 20)
        j.stage([t["mixed"]], in: s, context: context(s), stat: fake(s))
        XCTAssertEqual(j.knownBytes, 20)
        XCTAssertEqual(j.unknownSizeCount, 1)
        XCTAssertEqual(Set(j.items[0].warnings.map { String(describing: $0) }),
            Set(["containsUnknownSize", "containsCloudOnly", "containsHardLinks"]))
        XCTAssertNotEqual(j.items[0].verdict, .ok)
        XCTAssertTrue(TrashConfirmation(items: j.items).total(locale: Locale(identifier: "en_US")).contains("unknown size"))
    }

    func test_recursive_execution_audits_known_part_unknown_content_and_excludes_external_links() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        var cloud = TestSnapshot.Spec.file("cloudChild", 0); cloud.dataless = true
        var duplicate = TestSnapshot.Spec.file("duplicate", 0); duplicate.hardlinkDuplicate = true
        let t = TestSnapshot(.dir("/scan/root", [.dir("mixed", [.file("known", 20), .denied("unreadable"), cloud, duplicate])]),
            stats: stats, fileIDs: true)
        let s = t.snapshot, j = Reclaim(), p = ExecutorTests.Probe()
        p.entries = fake(s).entries
        p.entries[s.rawPath(t["cloudChild"])] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 1),
            fileID: s.fileID(t["cloudChild"])!, isSymlink: false)
        p.entries[s.rawPath(t["known"])] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 2),
            fileID: s.fileID(t["known"])!, isSymlink: false)
        j.stage([t["mixed"]], in: s, context: context(s), stat: p)
        XCTAssertEqual(j.knownBytes, 20); XCTAssertEqual(j.unknownSizeCount, 1)
        let r = await Executor(trasher: p, stat: p, log: p, context: context(s)).run(j.items, confirmedWarnings: [t["mixed"]])
        guard case .trashed = r.outcomes.first?.1 else { return XCTFail("Reviewed recursive item must move") }
        XCTAssertEqual(r.reclaimableBytes, 0, "the only allocated child has an external hard link")
        XCTAssertEqual(r.unknownSizeTrashed, 1)
        XCTAssertEqual(p.logs.first?.bytes, 20)
        XCTAssertEqual(p.logs.first?.hasUnknownContent, true)
        XCTAssertTrue(trashSummaryText(r, locale: Locale(identifier: "en_US")).contains("unknown size"))
    }

    func test_new_live_descendant_hard_link_requires_review_and_reviewed_control_moves() async throws {
        let t = fixture(), s = t.snapshot, j = Reclaim(), p = ExecutorTests.Probe()
        p.entries = fake(s).entries
        let parent = t["parent"], leaf = t["leaf"]
        XCTAssertEqual(s.nodes[Int(leaf)].flags & UInt16(TESS_FLAG_HARDLINK_DUP), 0)
        guard case .ok(let before, _, _) = p.lstat(s.rawPath(leaf)) else { return XCTFail("Missing child") }
        XCTAssertEqual(before.linkCount, 1)
        j.stage([parent], in: s, context: context(s), stat: p)
        let item = try XCTUnwrap(j.items.first)
        XCTAssertEqual(item.verdict, .ok); XCTAssertTrue(item.warnings.isEmpty)
        p.entries[s.rawPath(leaf)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 2),
            fileID: s.fileID(leaf)!, isSymlink: false)
        let executor = Executor(trasher: p, stat: p, log: p, context: context(s))
        let refused = await executor.run([item], confirmedWarnings: [], reviewedWarnings: [parent: []])
        XCTAssertEqual(refused.outcomes.first?.1, .notConfirmed(.containsHardLinks))
        XCTAssertTrue(p.trashPaths.isEmpty)
        let reviewed = await executor.run([item], confirmedWarnings: [parent],
            reviewedWarnings: [parent: [.containsHardLinks]])
        guard case .trashed = reviewed.outcomes.first?.1 else { return XCTFail("Reviewed link must move") }
        XCTAssertEqual(p.trashPaths.count, 1)
        XCTAssertEqual(reviewed.reclaimableBytes, 40, "Shared leaf bytes remain excluded after consent")
    }

    func test_new_cloud_only_descendant_requires_another_review() async {
        let t = fixture(), s = t.snapshot, j = Reclaim(), p = ExecutorTests.Probe()
        p.entries = fake(s).entries
        j.stage([t["parent"]], in: s, context: context(s), stat: p)
        XCTAssertTrue(j.items[0].warnings.isEmpty)
        p.entries[s.rawPath(t["leaf"])] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 1),
            fileID: s.fileID(t["leaf"])!, isSymlink: false)
        let r = await Executor(trasher: p, stat: p, log: p, context: context(s)).run(j.items, confirmedWarnings: [t["parent"]])
        XCTAssertEqual(r.outcomes.first?.1, .notConfirmed(.containsCloudOnly))
        XCTAssertTrue(p.trashPaths.isEmpty)
    }

    func test_fresh_dataless_observation_is_unknown_and_ancestor_keeps_dropped_warnings() {
        let t = fixture(), s = t.snapshot, j = Reclaim()
        var stat = fake(s)
        let leaf = t["leaf"]
        XCTAssertFalse(s.isDataless(leaf))
        stat.entries[s.rawPath(leaf)] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 2),
            fileID: s.fileID(leaf)!, isSymlink: false)
        j.stage([leaf], in: s, context: context(s), stat: stat)
        XCTAssertEqual(j.unknownSizeCount, 1)
        XCTAssertNil(j.items[0].recordedSize)
        j.stage([t["parent"]], in: s, context: context(s), stat: stat)
        XCTAssertEqual(j.items.count, 1)
        XCTAssertTrue(j.items[0].warnings.contains(.cloudOnly))
        XCTAssertTrue(j.items[0].warnings.contains(.otherHardLinks))
        XCTAssertEqual(j.unknownSizeCount, 1)
    }

    func test_staging_retains_every_warning_in_priority_order() {
        var stats = TessScanStats(); stats.root_device = 7
        let t = TestSnapshot(.dir("/Users/tester/Library/Containers/app", [.file("linked", 10)]), stats: stats, fileIDs: true)
        let n = t["linked"], snap = t.snapshot
        var stat = fake(snap)
        stat.entries[snap.rawPath(n)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 2),
            fileID: snap.fileID(n)!, isSymlink: false)
        let j = Reclaim()
        j.stage([n], in: snap, context: context(snap), stat: stat)
        XCTAssertEqual(j.items.count, 1)
        XCTAssertEqual(j.items[0].verdict, .warn(.appContainer))
        XCTAssertEqual(j.items[0].warnings, [.appContainer, .otherHardLinks])
        XCTAssertEqual(allVerdicts(snap.rawPath(n), Observed(device: 7, flags: UInt32(SF_DATALESS),
            isDirectory: false, linkCount: 2), context(snap)),
            [.warn(.appContainer), .warn(.cloudOnly), .warn(.otherHardLinks)])
    }

    func test_staging_unavailable_tracks_session_without_context() async throws {
        let t = fixture()
        let app = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in nil })
        XCTAssertFalse(app.stagingUnavailable)
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        XCTAssertTrue(app.stagingUnavailable)
        session.selection.nodes = [t["leaf"]]
        app.stageSelection(); await app.waitForStaging()
        XCTAssertTrue(session.reclaim.items.isEmpty)
        app.replaceSnapshot(nil)
        XCTAssertFalse(app.stagingUnavailable)
    }

    func test_staging_ten_thousand_nodes_is_fast_and_complete() {
        var stats = TessScanStats(); stats.root_device = 7
        let t = TestSnapshot(.dir("/scan/root", (0..<10_000).map { .file("f\($0)", 1) }),
                             stats: stats, fileIDs: true)
        let snap = t.snapshot, j = Reclaim(), stat = fake(t.snapshot)
        let nodes = (0..<10_000).map { t["f\($0)"] }
        XCTAssertEqual(Set(nodes).count, 10_000)
        let start = Date()
        j.stage(nodes, in: snap, context: context(snap), stat: stat)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(j.items.map(\.nodeIndex), nodes)
        XCTAssertEqual(j.knownBytes, 10_000)
        XCTAssertTrue(j.items.allSatisfy { $0.verdict == .ok })
        XCTAssertLessThan(elapsed, 2)
        print("10,000-node staging: \(elapsed) s")
    }

    func test_directory_dedup_totals_raw_bytes_and_unstage() {
        let t = fixture(), j = Reclaim()
        let snap = t.snapshot
        XCTAssertEqual(snap.allocated(t["parent"]), 140)
        XCTAssertNotNil(snap.fileID(t["leaf"]))
        j.stage([t["leaf"], t["sibling"], t["leaf"]], in: snap, context: context(snap), stat: fake(snap))
        XCTAssertEqual(j.items.count, 2); XCTAssertEqual(j.knownBytes, 140)
        j.stage([t["parent"]], in: snap, context: context(snap), stat: fake(snap))
        XCTAssertEqual(j.items.map(\.nodeIndex), [t["parent"]])
        j.stage([t["nested"], t["parent-prefix"], t["raw"]], in: snap, context: context(snap), stat: fake(snap))
        XCTAssertEqual(j.items.count, 3); XCTAssertEqual(j.knownBytes, 209)
        XCTAssertEqual(j.items.last?.path, Data("/scan/root/".utf8) + Data([0xff]))
        XCTAssertEqual(j.items.first?.recorded, Recorded(fileID: snap.fileID(t["parent"])!, device: 7, isDirectory: true))
        XCTAssertEqual(j.items.first?.recordedSize, 140)
        j.unstage([t["parent"]]); XCTAssertEqual(j.stagedNodes, [t["parent-prefix"], t["raw"]])
        j.clear(); XCTAssertTrue(j.items.isEmpty); XCTAssertEqual(j.knownBytes, 0)
    }

    func test_ancestry_property_500_seeds() {
        let t = fixture(), snap = t.snapshot
        let count = UInt32(snap.nodes.count)
        XCTAssertGreaterThan(count, 8)
        for seed in 0..<500 {
            var state = UInt64(seed)
            func next() -> UInt32 {
                state &+= 0x9e3779b97f4a7c15
                var z = state
                z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
                z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
                return UInt32(truncatingIfNeeded: z ^ (z >> 31)) % count
            }
            let j = Reclaim()
            var expected: Set<UInt32> = []
            func ancestor(_ a: UInt32, _ b: UInt32) -> Bool {
                var p = b
                while p != Tile.noNode {
                    if p == a { return true }; p = snap.nodes[Int(p)].parent
                }
                return false
            }
            for _ in 0..<40 {
                let n = next()
                if !expected.contains(where: { ancestor($0, n) }) {
                    expected = expected.filter { !ancestor(n, $0) }; expected.insert(n)
                }
                j.stage([n], in: snap, context: context(snap), stat: fake(snap))
                XCTAssertEqual(j.stagedNodes, expected, "seed \(seed)")
                for a in j.stagedNodes {
                    for b in j.stagedNodes where a != b { XCTAssertFalse(ancestor(a, b)) }
                }
            }
        }
    }

    func test_unknown_sizes_denials_and_missing_identity() {
        let t = fixture(), j = Reclaim(), snap = t.snapshot
        for name in ["cloud", "skipped", "denied"] {
            XCTAssertNotNil(snap.fileID(t[name]))
            j.stage([t[name]], in: snap, context: context(snap), stat: fake(snap))
        }
        XCTAssertEqual(j.items.count, 3)
        XCTAssertTrue(j.items.allSatisfy { $0.recordedSize == nil })
        XCTAssertEqual(j.unknownSizeCount, 3); XCTAssertEqual(j.knownBytes, 0)
        let noID = TestSnapshot(.dir("/scan/root", [.file("noID", 50)]))
        XCTAssertNil(noID.snapshot.fileID(noID["noID"]))
        let missing = Reclaim()
        missing.stage([noID["noID"]], in: noID.snapshot, context: context(noID.snapshot), stat: FakeStat(entries: [:]))
        XCTAssertEqual(missing.items.first?.verdict, .denied(.noRecordedIdentity))
        XCTAssertEqual(missing.knownBytes, 0); XCTAssertEqual(missing.unknownSizeCount, 0)
        missing.unstage([noID["noID"]]); XCTAssertTrue(missing.items.isEmpty)
        j.stage([Tile.noNode, UInt32(snap.nodes.count)], in: snap, context: context(snap), stat: fake(snap))
        XCTAssertEqual(j.items.count, 3)
        let emptyPath = TestSnapshot(.dir("", []), fileIDs: true)
        let empty = Reclaim()
        XCTAssertTrue(emptyPath.snapshot.rawPath(0).isEmpty)
        empty.stage([0], in: emptyPath.snapshot, context: context(emptyPath.snapshot), stat: FakeStat(entries: [:]))
        XCTAssertTrue(empty.items.isEmpty)
        var stat = fake(snap)
        stat.entries[snap.rawPath(t["cloud"])] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 1),
            fileID: snap.fileID(t["cloud"])!, isSymlink: false)
        let cloud = Reclaim()
        cloud.stage([t["cloud"]], in: snap, context: context(snap), stat: stat)
        XCTAssertEqual(cloud.items.first?.verdict, .warn(.cloudOnly))
        XCTAssertEqual(cloud.knownBytes, 0); XCTAssertEqual(cloud.unknownSizeCount, 1)
        stat.entries[snap.rawPath(t["cloud"])] = .error(errno: EACCES)
        let denied = Reclaim()
        denied.stage([t["cloud"]], in: snap, context: context(snap), stat: stat)
        XCTAssertEqual(denied.items.count, 1); XCTAssertNil(denied.items[0].recordedSize)
        XCTAssertEqual(denied.unknownSizeCount, 0)
    }

    func test_identity_precedes_guards_and_denied_items_stay_visible() {
        let t = fixture(), snap = t.snapshot, n = t["leaf"]
        let path = snap.rawPath(n), id = snap.fileID(n)!
        let rows: [(StatResult, Reason)] = [
            (.error(errno: ENOENT), .changedSinceScan), (.error(errno: EACCES), .changedSinceScan),
            (.ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1), fileID: id + 1, isSymlink: false), .changedSinceScan),
            (.ok(Observed(device: 8, flags: 0, isDirectory: false, linkCount: 1), fileID: id, isSymlink: false), .changedSinceScan),
            (.ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: id, isSymlink: false), .changedSinceScan),
            (.ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1), fileID: id, isSymlink: true), .symlinkInPath),
            (.ok(Observed(device: 7, flags: UInt32(UF_IMMUTABLE), isDirectory: false, linkCount: 1), fileID: id, isSymlink: false), .immutable)
        ]
        XCTAssertEqual(rows.count, 7)
        for (result, reason) in rows {
            var stat = fake(snap); stat.entries[path] = result
            let j = Reclaim(); j.stage([n], in: snap, context: context(snap), stat: stat)
            XCTAssertEqual(j.items.count, 1); XCTAssertEqual(j.items[0].verdict, .denied(reason))
            XCTAssertEqual(j.knownBytes, 0); XCTAssertEqual(j.unknownSizeCount, 0)
        }
        var stat = fake(snap)
        stat.entries[snap.rawPath(t["parent"])] = .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: 1, isSymlink: true)
        let j = Reclaim(); j.stage([n], in: snap, context: context(snap), stat: stat)
        XCTAssertEqual(j.items.first?.verdict, .denied(.symlinkInPath))
        let deniedContext = GuardContext(scanRoot: context(snap).scanRoot, volumeRoot: Data("/scan".utf8), scanRootDevice: 7,
            appBundle: context(snap).appBundle, home: context(snap).home)
        let root = Reclaim(); root.stage([snap.root], in: snap, context: deniedContext, stat: fake(snap))
        XCTAssertEqual(root.items.first?.verdict, .denied(.volumeRootOrTopLevel))
    }

    func test_app_stages_selection_flags_descendants_and_rescan_clears() async throws {
        let t = fixture()
        let ctx = context(t.snapshot)
        let app = AppModel(coordinator: ScanCoordinator(), stagingStat: fake(t.snapshot), contextLoader: { _ in ctx })
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.selection.nodes = [t["parent"]]
        app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.reclaim.stagedNodes, [t["parent"]])
        XCTAssertEqual(session.reclaim.items.first?.verdict, .ok)
        session.navigator.ascend(to: t["parent"])
        session.resize(to: CGSize(width: 900, height: 600))
        let descendants = session.tiles.filter { $0.node == t["leaf"] || $0.node == t["sibling"] }
        XCTAssertFalse(descendants.isEmpty)
        XCTAssertTrue(descendants.allSatisfy { $0.flags & Tile.Flag.staged != 0 })
        session.reclaim.unstage([t["parent"]])
        XCTAssertTrue(session.tiles.allSatisfy { $0.flags & Tile.Flag.staged == 0 })
        app.stageSelection(); await app.waitForStaging(); XCTAssertFalse(session.reclaim.items.isEmpty)
        await session.waitForLabels()
        await session.waitForTable()
        app.prepareSnapshot(nil)
        XCTAssertNil(app.session); XCTAssertTrue(session.reclaim.items.isEmpty)
        app.replaceSnapshot(t.snapshot)
        XCTAssertTrue(try XCTUnwrap(app.session).reclaim.items.isEmpty)
    }
}
