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
import XCTest
import TesseraeFFI
@testable import TesseraeKit

final class ReconciliationViewModelTests: XCTestCase {
    let locale = Locale(identifier: "en_US")
    func scan(_ reason: String? = nil, access: AccessState = .unknown) -> ScanFacts {
        ScanFacts(allocatedSum: 40, unreadableLocations: 3, incompleteReason: reason,
                  limited: false, datalessItems: nil, access: access)
    }
    func model(_ residual: Int64? = 30, caveats: [Caveat] = []) -> ReconciliationViewModel {
        let r = Reconciliation(capacity: 100, scanned: 40, free: 20, systemVolume: 10,
            snapshots: SnapshotFacts(count: 7, oldest: Date(timeIntervalSince1970: 0), aggregateBytes: nil),
            residual: residual, purgeableEstimate: 7, caveats: caveats)
        return ReconciliationViewModel(wholeVolume: true, reconciliation: r, scan: scan(), locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!)
    }
    func test_breakdown_caveats_omit_only_the_residual_explanation() {
        let partial = model(nil, caveats: [.partialScan("Scan cancelled"), .snapshotsUnavailable, .noFullDiskAccess])
        XCTAssertEqual(partial.rows[3].detail, "Scan cancelled", "precondition: residual explains suppression")
        XCTAssertEqual(partial.breakdownCaveats, ["Local snapshot information unavailable.", "Full Disk Access is missing."])
        XCTAssertEqual(partial.caveats, ["Scan cancelled", "Local snapshot information unavailable.", "Full Disk Access is missing."], "report keeps every caveat")
        let negative = model(-3, caveats: [.cloneDoubleCounting, .snapshotsUnavailable])
        XCTAssertTrue(negative.rows[3].negative)
        XCTAssertEqual(negative.breakdownCaveats, ["Local snapshot information unavailable."])
        XCTAssertEqual(model(caveats: [.cloneDoubleCounting]).breakdownCaveats, ["The scan is double-counting shared blocks."], "keep caveats that have no matching row detail")
    }

    func test_system_volume_uses_identity_through_another_path() {
        let identities = ["/": "system", "/System/Volumes/Data": "data", "/alias": "data", "/external": "other"]
        let read: (URL) -> NSObject? = { identities[$0.path].map { $0 as NSString } }
        XCTAssertTrue(ReconciliationViewModel.systemVolumeApplies(root: URL(fileURLWithPath: "/alias"), identity: read))
        XCTAssertFalse(ReconciliationViewModel.systemVolumeApplies(root: URL(fileURLWithPath: "/"), identity: read))
        XCTAssertFalse(ReconciliationViewModel.systemVolumeApplies(root: URL(fileURLWithPath: "/external"), identity: read))
        XCTAssertFalse(ReconciliationViewModel.systemVolumeApplies(root: URL(fileURLWithPath: "/missing"), identity: read))
    }

    func test_load_reconciles_data_system_and_unrelated_volume_summands() {
        let identities = ["/": "system", "/System/Volumes/Data": "data", "/alias": "data", "/external": "other"]
        let identity: (URL) -> NSObject? = { identities[$0.path].map { $0 as NSString } }
        let facts = VolumeFacts(capacity: 100, used: 80, free: 20, available: 20, purgeable: nil)
        for path in ["/alias", "/", "/external"] {
            var systemReads = 0
            let data = path == "/alias"
            let m = ReconciliationViewModel.load(root: URL(fileURLWithPath: path), scan: scan(access: .granted),
                wholeVolume: { _ in true },
                systemApplies: { ReconciliationViewModel.systemVolumeApplies(root: $0, identity: identity) },
                volumeFacts: { _ in facts }, systemUsed: { systemReads += 1; return 10 },
                snapshots: { _ in SnapshotFacts(count: 0, oldest: nil, aggregateBytes: nil) }, locale: locale)
            XCTAssertEqual(m.rows.count, 5, "precondition: volume breakdown exists")
            XCTAssertEqual(m.rows.map(\.value), ["100 bytes", "40 bytes", data ? "10 bytes" : "Not applicable", data ? "+30 bytes" : "+40 bytes", "20 bytes"], path)
            XCTAssertEqual(m.rows.map(\.fraction), [nil, 0.4, data ? 0.1 : 0, data ? 0.3 : 0.4, 0.2], path)
            XCTAssertEqual(systemReads, data ? 1 : 0, path)
        }
    }

    func test_unavailable_and_overflow_reasons_reach_diagnostics_from_model() {
        let tree = TestSnapshot(.dir("/Fixture", [.file("one", 40)]))
        let clean = scan(access: .granted)
        XCTAssertNil(clean.incompleteReason, "precondition: no partial-scan explanation")
        let overflow = reconcile(VolumeFacts(capacity: UInt64.max, used: 0, free: 0, available: 0, purgeable: nil),
            systemVolumeUsed: 0, SnapshotFacts(count: 0, oldest: nil, aggregateBytes: nil), clean)
        XCTAssertNil(overflow.residual, "precondition: signed result cannot fit")
        for (r, reason) in [(nil, "Volume information unavailable"), (Optional(overflow), "Too large to compute")] {
            let m = ReconciliationViewModel(wholeVolume: true, reconciliation: r, scan: clean, locale: locale)
            XCTAssertEqual(m.rows[3].value, "—")
            XCTAssertEqual(m.rows[3].detail, reason)
            XCTAssertTrue(m.caveats.contains(reason))
            let report = ScanReport(snapshot: tree.snapshot, caveats: m.caveats, access: .granted,
                scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test", locale: locale)
            XCTAssertTrue(report.text.contains("Reconciliation caveats\n" + reason), report.text)
        }
    }

    func test_non_residual_row_detail_cannot_hide_a_caveat() {
        let rows = [ReconciliationViewModel.Row(title: "System volume", value: "—",
            detail: "Full Disk Access is missing.", fraction: nil, negative: false)]
        XCTAssertFalse(rows.contains { $0.title == "Residual" }, "precondition: only another row matches")
        XCTAssertEqual(ReconciliationViewModel.breakdownCaveats(rows: rows, caveats: ["Full Disk Access is missing."]),
            ["Full Disk Access is missing."])
    }

    func test_cloud_only_caveat_formats_logical_bytes_and_policy_failure() {
        let scan = ScanFacts(allocatedSum: 40, unreadableLocations: 0, incompleteReason: nil,
            limited: false, datalessItems: 5, access: .granted,
            datalessLogicalBytes: 15729664, noMaterializeFailed: true)
        let r = Reconciliation(capacity: 100, scanned: 40, free: 20, systemVolume: 10,
            snapshots: SnapshotFacts(count: nil, oldest: nil, aggregateBytes: nil), residual: 30, purgeableEstimate: nil, caveats: [.datalessNotCounted(5)])
        XCTAssertEqual(scan.datalessItems, 5, "precondition: nonzero cloud count")
        let m = ReconciliationViewModel(wholeVolume: true, reconciliation: r, scan: scan, locale: locale)
        XCTAssertTrue(m.caveats.contains("5 cloud-only items (15.7 MB) — not stored on this Mac"))
        XCTAssertTrue(m.caveats.contains("Cloud-only download protection could not be enabled for this scan."))
    }

    func test_signed_rows_annotations_and_proportions() {
        let m = model(-3, caveats: [.cloneDoubleCounting])
        XCTAssertEqual(m.rows.map(\.title), ["Capacity", "Scanned", "System volume", "Residual", "Free"])
        XCTAssertEqual(m.rows.map(\.value), ["100 bytes", "40 bytes", "10 bytes", "−3 bytes", "20 bytes"])
        XCTAssertEqual(m.rows.map(\.fraction), [nil, 0.4, 0.1, 0.03, 0.2])
        XCTAssertTrue(m.rows[3].negative)
        XCTAssertEqual(m.rows[3].detail, "the scan is double-counting shared blocks")
        XCTAssertEqual(model().rows[3].value, "+30 bytes")
        XCTAssertEqual(model().rows[3].detail, "space the scan can't see")
        XCTAssertEqual(m.rows[2].detail, "read-only, not scanned by default")
        XCTAssertEqual(m.rows.first { $0.title == "Residual" }?.annotation, "7 local snapshots, oldest 1 Jan — size not reported by macOS")
        XCTAssertEqual(m.purgeable, "about 7 bytes purgeable (derived)")
        XCTAssertEqual(m.warning, "3 locations unreadable — grant Full Disk Access to include them")
        XCTAssertTrue(m.showGrantAccess)
    }
    func test_snapshot_annotation_belongs_to_residual() throws {
        let rows = model().rows
        XCTAssertEqual(rows.count, 5, "precondition: whole volume has rows")
        let residual = try XCTUnwrap(rows.first { $0.title == "Residual" })
        XCTAssertEqual(residual.annotation, "7 local snapshots, oldest 1 Jan — size not reported by macOS")
        XCTAssertTrue(rows.filter { $0.title != "Residual" }.allSatisfy { $0.annotation == nil })
    }

    func test_zero_residual_is_unsigned_and_neutral() throws {
        let residual = try XCTUnwrap(model(0).rows.first { $0.title == "Residual" })
        XCTAssertEqual(residual.fraction, 0, "precondition: known zero residual")
        XCTAssertEqual(residual.value, displaySize(0, locale: locale))
        XCTAssertEqual(residual.detail, "nothing unaccounted for")
        XCTAssertFalse(residual.negative)
    }

    @MainActor
    func test_rescan_cancels_detached_facts_loader() async {
        let tree = TestSnapshot(.dir("/old", [.file("one", 40)]))
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = expectation(description: "detached loader cancelled")
        let app = AppModel(coordinator: ScanCoordinator(), factsLoader: { _, scan in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            XCTAssertTrue(Task.isCancelled)
            cancelled.fulfill()
            return ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan)
        })
        defer { release.signal() }
        app.prepareSnapshot(tree.snapshot)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "precondition: detached work started")
        app.prepareSnapshot(nil)
        release.signal()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertNil(app.session)
    }

    func test_scope_and_unavailable_volume_figures() {
        let folder = ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan(), locale: locale)
        XCTAssertTrue(folder.rows.isEmpty)
        XCTAssertEqual(folder.scopeMessage, "Space breakdown is available when you scan a whole volume.")
        let volume = ReconciliationViewModel(wholeVolume: true, reconciliation: nil, scan: scan(), locale: locale)
        XCTAssertNil(volume.scopeMessage)
        XCTAssertEqual(volume.rows.map(\.value), ["—", "40 bytes", "—", "—", "—"])
        XCTAssertEqual(volume.rows[3].detail, "Volume information unavailable")
        XCTAssertNil(volume.purgeable)
        XCTAssertNil(volume.rows[3].fraction)
    }
    func test_suppression_reasons_and_caveat_order() {
        XCTAssertEqual(model(nil, caveats: [.partialScan("Scan cancelled")]).rows[3].detail, "Scan cancelled")
        XCTAssertEqual(model(nil).rows[3].detail, "Too large to compute")
        let cases: [(Caveat, String)] = [
            (.cloneDoubleCounting, "The scan is double-counting shared blocks."),
            (.noFullDiskAccess, "Full Disk Access is missing."),
            (.accessUnknown, "Full Disk Access is unknown."),
            (.limitedScan, "Limited scan."), (.partialScan("Scan cancelled"), "Scan cancelled"),
            (.containerDataUnavailable, "System volume information unavailable."),
            (.snapshotsUnavailable, "Local snapshot information unavailable."),
            (.datalessNotCounted(5), "5 cloud-only items (—) — not stored on this Mac")]
        XCTAssertEqual(model(caveats: cases.map(\.0)).caveats, cases.map(\.1))
    }
    func test_unknown_snapshots_system_and_granted_access() {
        let r = Reconciliation(capacity: 100, scanned: 40, free: 20, systemVolume: nil,
            snapshots: SnapshotFacts(count: nil, oldest: nil, aggregateBytes: nil),
            residual: 40, purgeableEstimate: nil, caveats: [])
        let m = ReconciliationViewModel(wholeVolume: true, reconciliation: r, scan: scan(access: .granted), locale: locale)
        XCTAssertEqual(m.rows[2].value, "—")
        XCTAssertEqual(m.rows.first { $0.title == "Residual" }?.annotation, "Local snapshots: —")
        XCTAssertNil(m.purgeable)
        XCTAssertFalse(m.showGrantAccess)
        XCTAssertEqual(m.warning, "3 locations unreadable")
    }
    func test_volume_root_detection_includes_data_but_excludes_repo() throws {
        let data = URL(fileURLWithPath: "/System/Volumes/Data")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try data.resourceValues(forKeys: [.volumeURLKey]).volume?.path, data.path)
        XCTAssertNotEqual(try repo.resourceValues(forKeys: [.volumeURLKey]).volume?.path, repo.path)
        XCTAssertTrue(ReconciliationViewModel.isWholeVolume(root: data))
        XCTAssertFalse(ReconciliationViewModel.isWholeVolume(root: repo))
    }

    @MainActor
    func test_facts_are_off_main_and_published_with_the_current_scan() async throws {
        var cloudStats = TessScanStats()
        cloudStats.dataless_files = 4
        cloudStats.dataless_directories = 1
        cloudStats.dataless_logical_bytes = 15729664
        cloudStats.no_materialize_failed = 1
        let a = TestSnapshot(.dir("/old", [.file("one", 40)]), stats: cloudStats)
        XCTAssertEqual(a.snapshot.datalessFiles, 4)
        XCTAssertEqual(a.snapshot.datalessDirectories, 1)
        let b = TestSnapshot(.dir("/new", [.file("two", 90)]))
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown }, factsLoader: { root, scan in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(scan.unreadableLocations, 0)
            XCTAssertNil(scan.incompleteReason)
            XCTAssertFalse(scan.limited)
            XCTAssertEqual(scan.datalessItems, root.path == "/old" ? 5 : 0)
            XCTAssertEqual(scan.datalessLogicalBytes, root.path == "/old" ? 15729664 : 0)
            XCTAssertEqual(scan.noMaterializeFailed, root.path == "/old")
            XCTAssertEqual(scan.access, .unknown)
            XCTAssertEqual(scan.allocatedSum, root.path == "/old" ? 40 : 90)
            return ReconciliationViewModel(wholeVolume: true, reconciliation: nil, scan: scan, locale: Locale(identifier: "en_US"))
        })
        app.prepareSnapshot(a.snapshot)
        XCTAssertNil(app.session, "facts have not arrived")
        await app.waitForFacts()
        XCTAssertTrue(app.session?.snapshot === a.snapshot, "precondition: cloud facts loaded before replacement")
        app.prepareSnapshot(b.snapshot)
        await app.waitForFacts()
        let current = try XCTUnwrap(app.session)
        XCTAssertTrue(current.snapshot === b.snapshot)
        XCTAssertEqual(current.reconciliation?.rows[1].value, "90 bytes")
        app.prepareSnapshot(nil)
        XCTAssertNil(app.session)
    }

    @MainActor
    func test_access_is_probed_at_launch_and_activation_off_main_and_used_in_scan_facts() async throws {
        let probe = AccessSequence()
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { probe.next() }, factsLoader: { root, scan in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(scan.access, root.path == "/first" ? .granted : .denied(evidence: "fixture EPERM"))
            return ReconciliationViewModel(wholeVolume: true, reconciliation: nil, scan: scan)
        })
        await app.waitForAccess()
        XCTAssertEqual(probe.calls, 1, "launch probes without requiring a scan")
        let a = TestSnapshot(.dir("/first", [.file("one", 40)]))
        app.prepareSnapshot(a.snapshot)
        await app.waitForFacts()
        XCTAssertFalse(try XCTUnwrap(app.session?.reconciliation).showGrantAccess)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await app.waitForAccess()
        XCTAssertEqual(probe.calls, 2, "activation rechecks access")
        let b = TestSnapshot(.dir("/second", [.file("two", 90)]))
        app.prepareSnapshot(b.snapshot)
        await app.waitForFacts()
        XCTAssertTrue(try XCTUnwrap(app.session?.reconciliation).showGrantAccess)
    }

    @MainActor
    func test_finished_state_waits_for_facts_and_session() async throws {
        let tree = TestSnapshot(.dir("/fixture", [.file("one", 40)]))
        let snapshot = tree.snapshot
        let coordinator = ScanCoordinator(factory: { _, _ in CompletedReconciliationScan(snapshot) })
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let app = AppModel(coordinator: coordinator, accessLoader: { .granted }, factsLoader: { _, scan in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan,
                                           locale: Locale(identifier: "en_US"))
        })
        defer { release.signal() }
        app.scan(URL(fileURLWithPath: "/fixture"))
        let deadline = Date().addingTimeInterval(3)
        while coordinator.state != .finished && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(coordinator.state, .finished, "precondition: scan completed")
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success, "precondition: facts loader is blocked")
        XCTAssertTrue(app.isScanning, "finished must imply a session is ready, including its facts")
        XCTAssertNil(app.session)
        release.signal()
        await app.waitForFacts()
        XCTAssertEqual(app.scanState, .finished)
        XCTAssertTrue(try XCTUnwrap(app.session).snapshot === snapshot)
    }

}


private final class CompletedReconciliationScan: ScanDriving, @unchecked Sendable {
    let snapshot: Snapshot
    init(_ snapshot: Snapshot) { self.snapshot = snapshot }
    func progress() -> TessProgress? { nil }
    func cancel() {}
    func status() -> Int32 { 1 }
    func finish() -> Snapshot? { snapshot }
}

private final class AccessSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func next() -> AccessState {
        XCTAssertFalse(Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == 1 ? .granted : .denied(evidence: "fixture EPERM")
    }
}
