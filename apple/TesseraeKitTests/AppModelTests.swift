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
    private let scanningPutBackMessage = "Put Back is unavailable while scanning — try again when the scan finishes, or use Finder"
    private let changedScanMessage = "Files changed since this scan — rescan to stage items"

    func test_other_model_scan_refuses_put_back_for_ordinary_and_dataless_children() async throws {
        for cloud in [false, true] {
            let (tree, a, probe, original, entry) = try await excludedChild(cloud: cloud)
            let missing = missingChildSnapshot(), driver = CrossingScan(snapshot: missing.snapshot)
            seedMissingSibling(missing, probe: probe)
            let b = await crossingApp(probe, driver: driver)
            XCTAssertTrue(a.session === original)
            XCTAssertEqual(original.overlay.deleted, [tree["child"]])
            probe.trashPaths.removeAll()
            b.scan(URL(fileURLWithPath: "/scan/root"))
            try await crossingWait { driver.hasStarted && b.isScanning }
            let mover = PutBackTests.RestoreProbe()
            let result = await a.putBack(entry, stat: probe, mover: mover, log: probe)
            XCTAssertEqual(result, .failed(scanningPutBackMessage))
            XCTAssertEqual(mover.calls, 0)
            XCTAssertEqual(original.overlay.deleted, [tree["child"]])
            driver.finishNow()
            try await crossingWait { b.scanState == .finished && b.session != nil }
            let session = try XCTUnwrap(b.session)
            XCTAssertEqual(session.snapshot.nodes.count, 3)
            XCTAssertFalse(session.changedSinceScan, "Refused restore left the child in Trash")
            session.selection.nodes = [missing["parent"]]; b.stageSelection(); await b.waitForStaging()
            XCTAssertEqual(session.jetsam.knownBytes, 20)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-refused-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ui = JetsamPresentation(log: JettisonLog(directory: directory), historyLoader: { [] })
            ui.prepare(session.jetsam.items, model: b)
            XCTAssertTrue(ui.showingConfirmation, "B can review because the restore was refused")
            XCTAssertEqual(ui.confirmation.items.first?.recordedSize, 20)
            XCTAssertTrue(probe.trashPaths.isEmpty)
            await ui.historyTask?.value
            withExtendedLifetime((tree, missing, a, b)) {}
        }
    }

    func test_other_model_open_review_is_invalidated_for_ordinary_and_dataless_children() async throws {
        for cloud in [false, true] {
            let (tree, a, probe, original, entry) = try await excludedChild(cloud: cloud)
            let missing = missingChildSnapshot(), driver = CrossingScan(snapshot: missing.snapshot)
            seedMissingSibling(missing, probe: probe)
            let b = await crossingApp(probe, driver: driver)
            b.scan(URL(fileURLWithPath: "/scan/root"))
            try await crossingWait { driver.hasStarted && b.isScanning }
            driver.finishNow()
            try await crossingWait { b.scanState == .finished && b.session != nil }
            let session = try XCTUnwrap(b.session)
            XCTAssertEqual(session.snapshot.nodes.count, 3)
            XCTAssertFalse(session.changedSinceScan)
            session.selection.nodes = [missing["parent"]]; b.stageSelection(); await b.waitForStaging()
            XCTAssertEqual(session.jetsam.knownBytes, 20)
            XCTAssertEqual(session.jetsam.items.first?.descendants.count, 1)
            XCTAssertEqual(session.jetsam.items.first?.warnings, [])
            let reviewed = session.jetsam.items
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fix4-review-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ui = JetsamPresentation(log: JettisonLog(directory: directory), historyLoader: { [] })
            ui.prepare(reviewed, model: b)
            XCTAssertTrue(ui.showingConfirmation)
            probe.trashPaths.removeAll()
            let mover = PutBackTests.RestoreProbe()
            let result = await a.putBack(entry, stat: probe, mover: mover, log: probe)
            XCTAssertEqual(result, .restored)
            XCTAssertEqual(mover.calls, 1)
            publishRestoredChild(tree, cloud: cloud, probe: probe)
            XCTAssertTrue(original.overlay.deleted.isEmpty)
            XCTAssertFalse(original.changedSinceScan, "The mapped session still contains the child")
            XCTAssertTrue(session.changedSinceScan)
            XCTAssertFalse(ui.showingConfirmation)
            await ui.execute(b, trasher: probe, stat: probe)
            XCTAssertNil(ui.result, "The model refuses even the frozen review")
            let context = try XCTUnwrap(session.guardContext)
            let stale = await session.execute(using: Executor(trasher: probe, stat: probe, log: probe, context: context),
                confirmedWarnings: [], reviewedItems: reviewed, stagingStat: probe)
            XCTAssertEqual(stale.outcomes.first?.1, .skipped(.changedSinceScan))
            try await assertChangedScanRefusesParent(b, session: session, tree: missing, probe: probe)
            await ui.historyTask?.value
            withExtendedLifetime((tree, missing, a, b)) {}
        }
    }

    func test_other_model_pending_scan_publishes_changed_after_in_flight_restore() async throws {
        for cloud in [false, true] {
            let (tree, a, probe, _, entry) = try await excludedChild(cloud: cloud)
            let missing = missingChildSnapshot(), driver = CrossingScan(snapshot: missing.snapshot)
            seedMissingSibling(missing, probe: probe)
            let b = await crossingApp(probe, driver: driver)
            probe.trashPaths.removeAll()
            let mover = HeldRestoreMover()
            let restore = Task { await a.putBack(entry, stat: probe, mover: mover, log: probe) }
            let started = await Task.detached { mover.waitUntilStarted() }.value
            XCTAssertTrue(started)
            b.scan(URL(fileURLWithPath: "/scan/root"))
            XCTAssertTrue(b.scanPending)
            XCTAssertFalse(driver.hasStarted, "All models share the restore permit")
            mover.release.signal()
            let result = await restore.value
            XCTAssertEqual(result, .restored)
            publishRestoredChild(tree, cloud: cloud, probe: probe)
            try await crossingWait { driver.hasStarted && b.isScanning }
            driver.finishNow()
            try await crossingWait { b.scanState == .finished && b.session != nil }
            let session = try XCTUnwrap(b.session)
            XCTAssertTrue(session.changedSinceScan)
            try await assertChangedScanRefusesParent(b, session: session, tree: missing, probe: probe)
            XCTAssertFalse(mover.timedOut)
            withExtendedLifetime((tree, missing, a, b)) {}
        }
    }

    func test_other_model_facts_publication_preserves_restore_invalidation() async throws {
        let (tree, a, probe, _, entry) = try await excludedChild(cloud: true)
        let missing = missingChildSnapshot(), facts = HeldCrossingFacts()
        seedMissingSibling(missing, probe: probe)
        let b = await crossingApp(probe, driver: CrossingScan(snapshot: missing.snapshot), factsLoader: { _, scan in facts.load(scan) })
        probe.trashPaths.removeAll()
        let mover = HeldRestoreMover()
        let restore = Task { await a.putBack(entry, stat: probe, mover: mover, log: probe) }
        let started = await Task.detached { mover.waitUntilStarted() }.value
        XCTAssertTrue(started)
        b.prepareSnapshot(missing.snapshot)
        let loading = await Task.detached { facts.waitUntilStarted() }.value
        XCTAssertTrue(loading)
        XCTAssertTrue(b.isScanning)
        XCTAssertNil(b.session)
        mover.release.signal()
        let result = await restore.value
        XCTAssertEqual(result, .restored)
        publishRestoredChild(tree, cloud: true, probe: probe)
        facts.release.signal()
        await b.waitForFacts()
        let session = try XCTUnwrap(b.session)
        XCTAssertTrue(session.changedSinceScan)
        try await assertChangedScanRefusesParent(b, session: session, tree: missing, probe: probe)
        XCTAssertFalse(mover.timedOut)
        XCTAssertFalse(facts.timedOut)
        withExtendedLifetime((tree, missing, a, b)) {}
    }

    func test_restoration_registry_preserves_raw_paths_and_component_boundaries() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        var root = TestSnapshot.Spec.dir("root", [.file("sibling", 20)])
        root.rawName = Array("/scan/".utf8) + [0xff]
        let tree = TestSnapshot(root, stats: stats, fileIDs: true)
        let probe = ExecutorTests.Probe()
        let app = await crossingApp(probe, driver: CrossingScan(snapshot: tree.snapshot))
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session), rawRoot = tree.snapshot.rawPath(tree.snapshot.root)
        XCTAssertNil(String(data: rawRoot, encoding: .utf8))
        XCTAssertFalse(session.changedSinceScan)
        // A byte prefix that is not an ancestor must not invalidate this root.
        JetsamCoordinator.shared.recordRestoration(rawRoot + Data("ish/child".utf8), fileID: 99)
        XCTAssertFalse(session.changedSinceScan)
        JetsamCoordinator.shared.recordRestoration(rawRoot + Data("/child".utf8), fileID: 99)
        XCTAssertTrue(session.changedSinceScan)
        XCTAssertTrue(app.stagingUnavailable)
        XCTAssertTrue(probe.trashPaths.isEmpty)
        withExtendedLifetime((tree, app)) {}
    }

    func test_restoration_registry_does_not_retain_models() async throws {
        let tree = missingChildSnapshot(), probe = ExecutorTests.Probe()
        weak var released: AppModel?
        do {
            let app = await crossingApp(probe, driver: CrossingScan(snapshot: tree.snapshot))
            app.replaceSnapshot(tree.snapshot)
            released = app
            XCTAssertNotNil(released)
        }
        await Task.yield()
        XCTAssertNil(released, "The process-wide registry must be weak")
        withExtendedLifetime(tree) {}
    }

    func test_historical_put_back_during_scan_cannot_cross_publication() async throws {
        for cloud in [false, true] {
            let (oldTree, _, p, _, entry) = try await excludedChild(cloud: cloud)
            let missing = missingChildSnapshot()
            seedMissingSibling(missing, probe: p)
            let driver = CrossingScan(snapshot: missing.snapshot)
            let app = await crossingApp(p, driver: driver)
            app.scan(URL(fileURLWithPath: "/scan/root"))
            try await crossingWait { driver.hasStarted && app.session == nil && app.isScanning }
            XCTAssertEqual(missing.snapshot.allocated(missing["parent"]), 20)
            XCTAssertEqual(missing.snapshot.nodes.count, 3)
            p.trashPaths.removeAll()
            let mover = HeldRestoreMover()
            let restore = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
            await Task.yield()
            try await crossingWait { mover.calls > 0 || app.restoresInFlight.isEmpty }
            // On the broken implementation the mover is held across publication.
            driver.finishNow()
            try await crossingWait { app.scanState == .finished && app.session != nil }
            let published = try XCTUnwrap(app.session)
            mover.release.signal()
            let result = await restore.value
            if case .failed(let message) = result {
                XCTAssertEqual(message, scanningPutBackMessage)
                XCTAssertEqual(mover.calls, 0)
            } else {
                XCTAssertEqual(result, .restored)
                publishRestoredChild(oldTree, cloud: cloud, probe: p)
                try await assertChangedScanRefusesParent(app, session: published, tree: missing, probe: p)
            }
            XCTAssertTrue(p.trashPaths.isEmpty)
            XCTAssertTrue(app.restoresInFlight.isEmpty)
            XCTAssertFalse(mover.timedOut)
            withExtendedLifetime((oldTree, missing)) {}
        }
    }

    func test_old_session_put_back_missing_from_replacement_refuses_staging() async throws {
        for cloud in [false, true] {
            let (oldTree, app, p, old, entry) = try await excludedChild(cloud: cloud)
            let missing = missingChildSnapshot()
            seedMissingSibling(missing, probe: p)
            p.trashPaths.removeAll()
            let mover = HeldRestoreMover()
            let restore = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
            let started = await Task.detached { mover.waitUntilStarted() }.value
            XCTAssertTrue(started)
            XCTAssertEqual(old.overlay.deleted, [oldTree["child"]])
            // Publication seam: a previously captured restore completes into a
            // session whose snapshot never contained C (ordinary or dataless).
            app.replaceSnapshot(missing.snapshot)
            let current = try XCTUnwrap(app.session)
            XCTAssertTrue(current !== old)
            let ctx = try XCTUnwrap(current.guardContext)
            current.jetsam.stage([missing["parent"]], in: missing.snapshot, context: ctx, stat: p)
            XCTAssertEqual(current.jetsam.knownBytes, 20)
            let reviewed = current.jetsam.items
            mover.release.signal()
            let restored = await restore.value
            XCTAssertEqual(restored, .restored)
            publishRestoredChild(oldTree, cloud: cloud, probe: p)
            try await assertChangedScanRefusesParent(app, session: current, tree: missing, probe: p)
            let stale = await current.execute(using: Executor(trasher: p, stat: p, log: p, context: ctx),
                confirmedWarnings: [], reviewedItems: reviewed, stagingStat: p)
            XCTAssertEqual(stale.outcomes.first?.1, .skipped(.changedSinceScan))
            XCTAssertTrue(p.trashPaths.isEmpty)
            withExtendedLifetime((oldTree, missing)) {}
        }
    }

    func test_queued_put_back_rechecks_session_and_generation_after_permit() async throws {
        for variant in 0..<4 {
            let scanTree = missingChildSnapshot(), driver = CrossingScan(snapshot: scanTree.snapshot)
            let coordinator = ScanCoordinator(progressInterval: 0.001, factory: { _, _ in driver.begin(); return driver })
            let (tree, app, p, original, entry) = try await excludedChild(cloud: false, coordinator: coordinator)
            await app.waitForAccess()
            XCTAssertTrue(app.onboarding.canScan)
            XCTAssertEqual(original.overlay.deleted, [tree["child"]])
            XCTAssertEqual(p.logs.last?.trashURL, entry.trashURL)
            p.trashPaths.removeAll()
            if variant == 0 { app.replaceSnapshot(nil) }
            let mover = PutBackTests.RestoreProbe()
            await JetsamCoordinator.shared.acquire()
            let restore = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
            try await crossingWait { !app.restoresInFlight.isEmpty }
            if variant >= 2 {
                app.scan(URL(fileURLWithPath: "/scan/root"))
                if variant == 3 { app.cancel() }
            } else if variant == 1 {
                app.prepareSnapshot(tree.snapshot)
                await app.waitForFacts()
            } else { app.replaceSnapshot(tree.snapshot) }
            JetsamCoordinator.shared.release()
            let result = await restore.value
            XCTAssertEqual(result, .failed(scanningPutBackMessage), "queued variant \(variant)")
            XCTAssertEqual(mover.calls, 0)
            if variant == 2 {
                try await crossingWait { driver.hasStarted }
                driver.finishNow()
                try await crossingWait { app.scanState == .finished }
            }
            XCTAssertTrue(app.restoresInFlight.isEmpty)
            XCTAssertTrue(p.trashPaths.isEmpty)
            XCTAssertEqual(original.overlay.deleted, [tree["child"]], "The eligible entry must remain in Trash")
            if variant == 3 { XCTAssertFalse(driver.hasStarted) }
            withExtendedLifetime((tree, scanTree)) {}
        }
    }

    func test_scan_waits_for_in_flight_restore() async throws {
        let (tree, _, p, _, _) = try await excludedChild(cloud: false)
        let driver = CrossingScan(snapshot: tree.snapshot)
        let app = await crossingApp(p, driver: driver)
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session), child = tree["child"]
        p.entries[tree.snapshot.rawPath(child)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1),
            fileID: tree.snapshot.fileID(child)!, isSymlink: false)
        session.selection.nodes = [child]; app.stageSelection(); await app.waitForStaging()
        _ = await app.executeJetsam(confirmedWarnings: [], trasher: p, stat: p, log: p)
        let entry = try XCTUnwrap(p.logs.last)
        p.entries[tree.snapshot.rawPath(child)] = .error(errno: ENOENT)
        let mover = HeldRestoreMover()
        let restore = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
        let started = await Task.detached { mover.waitUntilStarted() }.value
        XCTAssertTrue(started)
        app.scan(URL(fileURLWithPath: "/scan/root"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(driver.hasStarted, "Snapshot capture must wait for the restore permit")
        XCTAssertTrue(app.session === session)
        mover.release.signal()
        let restored = await restore.value
            XCTAssertEqual(restored, .restored)
        try await crossingWait { driver.hasStarted }
        driver.finishNow()
        try await crossingWait { app.scanState == .finished }
        XCTAssertTrue(session.overlay.deleted.isEmpty)
        withExtendedLifetime(tree) {}
    }

    func test_scan_waits_for_in_flight_execute() async throws {
        let (tree, _, p, _, _) = try await excludedChild(cloud: false)
        let driver = CrossingScan(snapshot: tree.snapshot)
        let app = await crossingApp(p, driver: driver)
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session)
        session.selection.nodes = [tree["sibling"]]; app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.jetsam.knownBytes, 20)
        let held = HeldExecutionTrasher()
        let execute = Task { await app.executeJetsam(confirmedWarnings: [], trasher: held, stat: p, log: p) }
        let started = await Task.detached { held.waitUntilStarted() }.value
        XCTAssertTrue(started)
        app.scan(URL(fileURLWithPath: "/scan/root"))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(driver.hasStarted, "Snapshot capture must wait for execute publication")
        XCTAssertTrue(app.session === session)
        held.release.signal()
        let result = await execute.value
        XCTAssertEqual(result?.outcomes.count, 1)
        XCTAssertEqual(session.overlay.deleted, [tree["sibling"]])
        try await crossingWait { driver.hasStarted }
        driver.finishNow()
        try await crossingWait { app.scanState == .finished }
        withExtendedLifetime(tree) {}
    }

    func test_put_back_availability_requires_session_volume_and_finished_facts() async throws {
        let (tree, _, p, _, entry) = try await excludedChild(cloud: false)
        let driver = CrossingScan(snapshot: tree.snapshot), facts = HeldCrossingFacts()
        let app = await crossingApp(p, driver: driver, factsLoader: { _, scan in facts.load(scan) })
        let mover = PutBackTests.RestoreProbe()
        XCTAssertFalse(app.canPutBack(entry))
        let noSession = await app.putBack(entry, stat: p, mover: mover, log: p)
        XCTAssertEqual(noSession, .failed(scanningPutBackMessage))
        var foreignStats = TessScanStats(); foreignStats.root_device = 8
        let foreign = TestSnapshot(.dir("/other/root", [.file("file", 10)]), stats: foreignStats, fileIDs: true)
        app.replaceSnapshot(foreign.snapshot)
        XCTAssertFalse(app.canPutBack(entry))
        let wrongVolume = await app.putBack(entry, stat: p, mover: mover, log: p)
        XCTAssertEqual(wrongVolume, .failed(scanningPutBackMessage))
        app.replaceSnapshot(tree.snapshot)
        XCTAssertTrue(app.canPutBack(entry))
        // Facts can still be loading while an earlier session exists and the
        // scan coordinator is idle. This must independently forbid Put Back.
        app.prepareSnapshot(tree.snapshot)
        let started = await Task.detached { facts.waitUntilStarted() }.value
        XCTAssertTrue(started)
        XCTAssertNotNil(app.session)
        XCTAssertTrue(app.isScanning)
        XCTAssertFalse(app.canPutBack(entry))
        let loading = await app.putBack(entry, stat: p, mover: mover, log: p)
        XCTAssertEqual(loading, .failed(scanningPutBackMessage))
        XCTAssertEqual(mover.calls, 0)
        facts.release.signal()
        await app.waitForFacts()
        XCTAssertFalse(facts.timedOut)
        XCTAssertTrue(app.canPutBack(entry))
        withExtendedLifetime((tree, foreign)) {}
    }

    func test_missing_restoration_invalidates_open_confirmation_until_rescan() async throws {
        let (oldTree, _, p, _, entry) = try await excludedChild(cloud: false)
        let missing = missingChildSnapshot()
        seedMissingSibling(missing, probe: p)
        let app = await crossingApp(p, driver: CrossingScan(snapshot: missing.snapshot))
        app.replaceSnapshot(missing.snapshot)
        let session = try XCTUnwrap(app.session)
        session.selection.nodes = [missing["parent"]]; app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.jetsam.knownBytes, 20)
        let reviewed = session.jetsam.items
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fix3-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ui = JetsamPresentation(log: JettisonLog(directory: directory), historyLoader: { [] })
        ui.prepare(reviewed, model: app)
        XCTAssertTrue(ui.showingConfirmation)
        // Exercise the publication seam independently of the busy UI, which
        // normally prevents opening a review while a mover is in flight.
        session.recordRestoration(entry)
        XCTAssertTrue(session.changedSinceScan)
        XCTAssertFalse(ui.showingConfirmation)
        let context = try XCTUnwrap(session.guardContext)
        p.trashPaths.removeAll()
        let stale = await session.execute(using: Executor(trasher: p, stat: p, log: p, context: context),
            confirmedWarnings: [], reviewedItems: reviewed, stagingStat: p)
        XCTAssertEqual(stale.outcomes.first?.1, .skipped(.changedSinceScan))
        XCTAssertTrue(p.trashPaths.isEmpty)
        app.replaceSnapshot(oldTree.snapshot)
        XCTAssertFalse(try XCTUnwrap(app.session).changedSinceScan)
        XCTAssertFalse(app.stagingUnavailable)
        await ui.historyTask?.value
        withExtendedLifetime((oldTree, missing)) {}
    }

    private func assertChangedScanRefusesParent(_ app: AppModel, session: AppSession,
                                                tree: TestSnapshot, probe: ExecutorTests.Probe) async throws {
        XCTAssertEqual(session.banner, changedScanMessage)
        XCTAssertTrue(app.stagingUnavailable)
        session.jetsam.clear()
        session.selection.nodes = [tree["parent"]]
        app.stageSelection(); await app.waitForStaging()
        XCTAssertTrue(session.jetsam.items.isEmpty, "An omitted restored child requires a new scan")
        let result = await app.executeJetsam(confirmedWarnings: [], trasher: probe, stat: probe, log: probe)
        XCTAssertNil(result)
        XCTAssertTrue(probe.trashPaths.isEmpty)
    }

    private func publishRestoredChild(_ tree: TestSnapshot, cloud: Bool, probe: ExecutorTests.Probe) {
        let node = tree["child"]
        XCTAssertEqual(tree.snapshot.isDataless(node), cloud)
        // The fake mover has returned success: publish its live-file effect
        // before attempting to stage the parent from the incomplete snapshot.
        probe.entries[tree.snapshot.rawPath(node)] = .ok(Observed(device: 7, flags: cloud ? UInt32(SF_DATALESS) : 0,
            isDirectory: false, linkCount: 1), fileID: tree.snapshot.fileID(node)!, isSymlink: false)
    }

    private func seedMissingSibling(_ tree: TestSnapshot, probe: ExecutorTests.Probe) {
        let node = tree["sibling"]
        probe.entries[tree.snapshot.rawPath(node)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1),
            fileID: tree.snapshot.fileID(node)!, isSymlink: false)
    }

    private func missingChildSnapshot() -> TestSnapshot {
        var stats = TessScanStats(); stats.root_device = 7
        return TestSnapshot(.dir("/scan/root", [.dir("parent", [.file("sibling", 20)])]), stats: stats, fileIDs: true)
    }

    private func crossingApp(_ probe: ExecutorTests.Probe, driver: CrossingScan,
                             factsLoader: @escaping @Sendable (URL, ScanFacts) -> ReconciliationViewModel = { _, facts in
                                 ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: facts, locale: Locale(identifier: "en_US"))
                             }) async -> AppModel {
        let app = AppModel(coordinator: ScanCoordinator(progressInterval: 0.001, factory: { _, _ in
            driver.begin(); return driver
        }), accessLoader: { .granted }, stagingStat: probe, contextLoader: { snapshot in
            GuardContext(scanRoot: snapshot.rawPath(snapshot.root), volumeRoot: Data("/".utf8), scanRootDevice: 7,
                appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        }, factsLoader: factsLoader)
        await app.waitForAccess()
        XCTAssertTrue(app.onboarding.canScan)
        return app
    }

    private func crossingWait(_ ready: () -> Bool) async throws {
        for _ in 0..<600 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for crossing precondition")
    }

    private final class HeldCrossingFacts: @unchecked Sendable {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        private(set) var timedOut = false
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func load(_ scan: ScanFacts) -> ReconciliationViewModel {
            started.signal()
            timedOut = release.wait(timeout: .now() + 5) == .timedOut
            return ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan, locale: Locale(identifier: "en_US"))
        }
    }

    private final class CrossingScan: ScanDriving, @unchecked Sendable {
        private let lock = NSLock()
        private var begun = false, finished = false
        let snapshot: Snapshot
        init(snapshot: Snapshot) { self.snapshot = snapshot }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return begun }
        func begin() { lock.lock(); begun = true; lock.unlock() }
        func finishNow() { lock.lock(); finished = true; lock.unlock() }
        func status() -> Int32 { lock.lock(); defer { lock.unlock() }; return finished ? 1 : 0 }
        func progress() -> TessProgress? { TessProgress() }
        func cancel() { finishNow() }
        func finish() -> Snapshot? { snapshot }
    }

    private final class HeldExecutionTrasher: Trasher, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func trash(_ url: URL) throws -> URL {
            started.signal()
            _ = release.wait(timeout: .now() + 3)
            return URL(fileURLWithPath: "/fake-trash/" + url.lastPathComponent)
        }
    }

    func test_million_descendant_preparation_keeps_heartbeat_below_100ms() async throws {
        let fixture = await Task.detached { MillionFixture() }.value
        let s = fixture.snapshot
        XCTAssertEqual(s.nodes.count, 1_000_001)
        let ctx = GuardContext(scanRoot: s.rawPath(0), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let app = AppModel(coordinator: ScanCoordinator(), stagingStat: MillionStat(), contextLoader: { _ in ctx })
        app.replaceSnapshot(s)
        let session = try XCTUnwrap(app.session)
        session.selection.nodes = [0]
        var ticks = 0, maximum = 0.0, last = Date()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let now = Date()
                maximum = max(maximum, now.timeIntervalSince(last)); last = now; ticks += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await Task.yield()
        let start = Date()
        app.stageSelection()
        for _ in 0..<10_000 {
            if !session.jetsam.items.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(20))
        heartbeat.cancel(); await heartbeat.value
        XCTAssertGreaterThan(ticks, 3)
        XCTAssertEqual(session.jetsam.items.first?.descendants.count, 1_000_000)
        XCTAssertEqual(session.jetsam.knownBytes, 1_000_000)
        XCTAssertLessThanOrEqual(maximum, 0.100, "Main actor heartbeat stalled during preparation")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("FIX2 million: preparation=\(Date().timeIntervalSince(start))s heartbeatMax=\(maximum)s peakRSS=\(usage.ru_maxrss) bytes")
        withExtendedLifetime(fixture) {}
    }

    func test_cancelled_and_replaced_preparations_never_publish() async throws {
        for replace in [false, true] {
            var stats = TessScanStats(); stats.root_device = 7
            let t = TestSnapshot(.dir("/scan/root", [.file("leaf", 10)]), stats: stats, fileIDs: true)
            let s = t.snapshot, stat = HeldStagingStat()
            let ctx = GuardContext(scanRoot: s.rawPath(0), volumeRoot: Data("/".utf8), scanRootDevice: 7,
                appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
            let app = AppModel(coordinator: ScanCoordinator(), stagingStat: stat, contextLoader: { _ in ctx })
            app.replaceSnapshot(s)
            let old = try XCTUnwrap(app.session)
            old.selection.nodes = [0]
            app.stageSelection()
            let started = await Task.detached { stat.waitUntilStarted() }.value
            XCTAssertTrue(started); XCTAssertTrue(app.isPreparingJetsam)
            XCTAssertTrue(old.jetsam.items.isEmpty)
            if replace { app.replaceSnapshot(s) } else { app.cancelStaging() }
            stat.release.signal()
            await app.waitForStaging()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(app.isPreparingJetsam)
            XCTAssertTrue(old.jetsam.items.isEmpty, "Stale preparation was published")
            XCTAssertTrue(app.session?.jetsam.items.isEmpty == true)
            XCTAssertFalse(stat.timedOut)
        }
    }

    private final class HeldStagingStat: FileStat, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var first = true
        private(set) var timedOut = false
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func lstat(_ path: Data) -> StatResult {
            lock.lock(); let hold = first; first = false; lock.unlock()
            if hold { started.signal(); timedOut = release.wait(timeout: .now() + 3) == .timedOut }
            return .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: 1, isSymlink: false)
        }
    }

    private struct MillionStat: FileStat {
        func lstat(_ path: Data) -> StatResult {
            .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: 1, isSymlink: false)
        }
    }

    private final class MillionFixture: @unchecked Sendable {
        let nodes: UnsafeMutablePointer<TessNode>
        let names: UnsafeMutablePointer<UInt8>
        let snapshot: Snapshot
        init() {
            let count = 1_000_001, root = Array("/scan/root".utf8)
            nodes = .allocate(capacity: count)
            names = .allocate(capacity: root.count + 1)
            names.initialize(from: root + [102], count: root.count + 1)
            var file = TessNode(); file.parent = 0; file.allocated = 1; file.logical = 1
            file.name_off = UInt32(root.count); file.name_len = 1
            nodes.initialize(repeating: file, count: count)
            nodes[0].parent = UInt32.max; nodes[0].flags = UInt16(TESS_FLAG_DIR)
            nodes[0].allocated = 1_000_000; nodes[0].logical = 1_000_000
            nodes[0].name_off = 0; nodes[0].name_len = UInt16(root.count)
            nodes[0].child_start = 1; nodes[0].child_count = 1_000_000
            var stats = TessScanStats(); stats.root_device = 7
            snapshot = Snapshot(testingNodes: UnsafeBufferPointer(start: nodes, count: count),
                names: UnsafeRawBufferPointer(start: names, count: root.count + 1), root: 0, stats: stats,
                fileIDs: (0..<count).map { UInt64($0 + 1) })
        }
        deinit { nodes.deallocate(); names.deallocate() }
    }

    func test_restored_ordinary_child_reprepares_ancestor_and_stale_review_never_moves() async throws {
        try await assertRestoredChild(cloud: false)
    }

    func test_restored_dataless_child_requires_fresh_review() async throws {
        try await assertRestoredChild(cloud: true)
    }

    private func assertRestoredChild(cloud: Bool) async throws {
        let (t, app, p, session, entry) = try await excludedChild(cloud: cloud)
        let parent = t["parent"], child = t["child"], s = t.snapshot
        session.selection.nodes = [parent]; app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.jetsam.knownBytes, 20)
        XCTAssertEqual(session.jetsam.items.first?.descendants.count, 1)
        XCTAssertTrue(session.jetsam.items.first?.warnings.isEmpty == true)
        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fix2-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let ui = JetsamPresentation(log: JettisonLog(directory: logDirectory))
        ui.prepare(session.jetsam.items, model: app)
        XCTAssertTrue(ui.showingConfirmation)
        let reviewedRevision = session.overlay.revision
        XCTAssertEqual(ui.confirmation.overlayRevision, reviewedRevision)
        let historical = LogEntry(ts: entry.ts, action: entry.action, path: entry.path, pathB64: entry.pathB64,
            inode: entry.inode, device: entry.device, volumeUUID: entry.volumeUUID, isDirectory: entry.isDirectory,
            bytes: entry.bytes, trashURL: "file:///fake-trash/earlier-scan-child", result: entry.result)
        p.entries[Data("/fake-trash/earlier-scan-child".utf8)] = p.entries[Data("/fake-trash/child".utf8)]
        let historicalMover = PutBackTests.RestoreProbe()
        let historicalResult = await app.putBack(historical, stat: p, mover: historicalMover, log: p)
        guard case .failed(let message) = historicalResult else {
            return XCTFail("Unmapped historical restore must not change reviewed membership")
        }
        XCTAssertTrue(message.contains("Finder"))
        XCTAssertEqual(historicalMover.calls, 0)
        let restored = await app.putBack(entry, stat: p, mover: PutBackTests.RestoreProbe(), log: p)
        XCTAssertEqual(restored, .restored)
        XCTAssertFalse(ui.showingConfirmation, "Overlay changes invalidate the open review")
        XCTAssertGreaterThan(session.overlay.revision, reviewedRevision)
        XCTAssertEqual(session.jetsam.items.first?.overlayRevision, session.overlay.revision)
        XCTAssertEqual(session.jetsam.items.first?.sessionID, session.id)
        p.entries[s.rawPath(child)] = .ok(Observed(device: 7, flags: cloud ? UInt32(SF_DATALESS) : 0,
            isDirectory: false, linkCount: 1), fileID: s.fileID(child)!, isSymlink: false)
        let expected: UInt64 = cloud ? 20 : 100
        XCTAssertEqual(session.source.allocated(parent), expected)
        XCTAssertEqual(session.jetsam.knownBytes, expected)
        XCTAssertEqual(session.jetsam.items.first?.descendants.count, 2)
        XCTAssertEqual(session.jetsam.items.first?.warnings.contains(.containsCloudOnly), cloud)
        XCTAssertEqual(session.jetsam.items.first?.hasUnknownContent, cloud)
        p.trashPaths.removeAll()
        await ui.execute(app, trasher: p, stat: p)
        XCTAssertTrue(p.trashPaths.isEmpty, "Stale review must never reach Trash")
        let stale = try XCTUnwrap(ui.result?.outcomes.first?.1)
        XCTAssertTrue(outcomeText(stale).contains("changed since review"))
        XCTAssertEqual(session.source.allocated(parent), expected)
        // A fresh cloud warning starts unchecked and requires its own review.
        ui.prepare(session.jetsam.items, model: app)
        XCTAssertEqual(ui.confirmation.movingCount, cloud ? 0 : 1)
        if cloud {
            XCTAssertEqual(ui.confirmation.warningItems.map(\.id), [parent])
            await ui.execute(app, trasher: p, stat: p)
            XCTAssertTrue(p.trashPaths.isEmpty)
            guard case .notConfirmed = ui.result?.outcomes.first?.1 else { return XCTFail("Fresh warning needs consent") }
            ui.prepare(session.jetsam.items, model: app)
            ui.confirmation.setConfirmed(parent, true)
        }
        await ui.execute(app, trasher: p, stat: p)
        guard case .trashed = ui.result?.outcomes.first?.1 else { return XCTFail("Fresh reviewed ancestor must move") }
        XCTAssertEqual(p.trashPaths.count, 1)
        XCTAssertEqual(ui.result?.reclaimableBytes, expected)
        XCTAssertEqual(ui.result?.auditEntries.first?.bytes, expected)
        XCTAssertEqual(ui.result?.unknownSizeTrashed, cloud ? 1 : 0)
        XCTAssertTrue(session.overlay.deleted.contains(parent))
        XCTAssertEqual(session.source.allocated(s.root), 0)
        await ui.historyTask?.value
        withExtendedLifetime(t) {}
    }

    func test_restore_in_flight_serializes_staging_and_confirmation() async throws {
        let (t, app, p, session, entry) = try await excludedChild(cloud: true)
        session.selection.nodes = [t["parent"]]; app.stageSelection(); await app.waitForStaging()
        let oldItems = session.jetsam.items
        XCTAssertEqual(oldItems.first?.descendants.count, 1)
        XCTAssertTrue(oldItems.first?.warnings.isEmpty == true)
        p.trashPaths.removeAll()
        let mover = HeldRestoreMover()
        let work = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
        let started = await Task.detached { mover.waitUntilStarted() }.value
        XCTAssertTrue(started)
        defer { mover.release.signal() }
        XCTAssertTrue(app.restoresInFlight.contains(entry.trashURL!))
        app.stageSelection()
        let ctx = try XCTUnwrap(session.guardContext)
        let execution = Task {
            await session.execute(using: Executor(trasher: p, stat: p, log: p, context: ctx),
                confirmedWarnings: [], reviewedItems: oldItems, stagingStat: p)
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(app.isPreparingJetsam)
        XCTAssertEqual(session.jetsam.items, oldItems, "Preparation cannot publish during restore")
        XCTAssertTrue(p.trashPaths.isEmpty, "Execution must wait for the held restore")
        let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fix2-held-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: logDirectory) }
        let ui = JetsamPresentation(log: JettisonLog(directory: logDirectory))
        ui.prepare(session.jetsam.items, model: app)
        XCTAssertFalse(ui.showingConfirmation, "Cannot review an unfinished preparation")
        await ui.execute(app, trasher: p, stat: p)
        XCTAssertTrue(p.trashPaths.isEmpty)
        let s = t.snapshot, child = t["child"]
        p.entries[s.rawPath(child)] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 1),
            fileID: s.fileID(child)!, isSymlink: false)
        mover.release.signal()
        let restored = await work.value
        XCTAssertEqual(restored, .restored)
        await app.waitForStaging()
        let attempted = await execution.value
        XCTAssertEqual(attempted.outcomes.first?.1, .skipped(.changedSinceReview))
        XCTAssertTrue(p.trashPaths.isEmpty)
        XCTAssertFalse(app.isPreparingJetsam)
        XCTAssertEqual(session.jetsam.items.first?.descendants.count, 2)
        XCTAssertTrue(session.jetsam.items.first?.warnings.contains(.containsCloudOnly) == true)
        XCTAssertEqual(session.jetsam.knownBytes, session.source.allocated(t["parent"]))
        ui.prepare(session.jetsam.items, model: app)
        XCTAssertEqual(ui.confirmation.warningItems.map(\.id), [t["parent"]])
        XCTAssertTrue(ui.confirmation.confirmedWarnings.isEmpty)
        await ui.execute(app, trasher: p, stat: p)
        XCTAssertTrue(p.trashPaths.isEmpty)
        await ui.historyTask?.value
        withExtendedLifetime(t) {}
    }

    private func excludedChild(cloud: Bool, coordinator: ScanCoordinator? = nil) async throws -> (TestSnapshot, AppModel, ExecutorTests.Probe, AppSession, LogEntry) {
        var stats = TessScanStats(); stats.root_device = 7
        var child = TestSnapshot.Spec.file("child", cloud ? 0 : 80); child.dataless = cloud
        let t = TestSnapshot(.dir("/scan/root", [.dir("parent", [child, .file("sibling", 20)])]), stats: stats, fileIDs: true)
        let s = t.snapshot, p = ExecutorTests.Probe()
        for n in 0..<UInt32(s.nodes.count) {
            p.entries[s.rawPath(n)] = .ok(Observed(device: 7, flags: s.isDataless(n) ? UInt32(SF_DATALESS) : 0,
                isDirectory: s.isDirectory(n), linkCount: 1), fileID: s.fileID(n)!, isSymlink: false)
        }
        let ctx = GuardContext(scanRoot: s.rawPath(s.root), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let app = AppModel(coordinator: coordinator ?? ScanCoordinator(), accessLoader: { .granted },
            stagingStat: p, contextLoader: { _ in ctx }, factsLoader: { _, facts in
                ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: facts, locale: Locale(identifier: "en_US"))
            })
        app.replaceSnapshot(s)
        let session = try XCTUnwrap(app.session), node = t["child"]
        session.selection.nodes = [node]; app.stageSelection(); await app.waitForStaging()
        let first = await app.executeJetsam(confirmedWarnings: [node], trasher: p, stat: p, log: p)
        guard case .trashed = first?.outcomes.first?.1 else { throw NSError(domain: "fixture", code: 1) }
        XCTAssertEqual(session.overlay.deleted, [node])
        session.jetsam.clear()
        let entry = try XCTUnwrap(p.logs.last)
        p.entries[Data("/fake-trash/child".utf8)] = .ok(Observed(device: 7, flags: cloud ? UInt32(SF_DATALESS) : 0,
            isDirectory: false, linkCount: 1), fileID: entry.inode, isSymlink: false)
        p.entries[s.rawPath(node)] = .error(errno: ENOENT)
        return (t, app, p, session, entry)
    }

    func test_two_batches_review_summary_log_and_overlay_use_remaining_subtree() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        let t = TestSnapshot(.dir("/scan/root", [.dir("parent", [.file("large", 80), .file("small", 20)])]), stats: stats, fileIDs: true)
        let s = t.snapshot, p = ExecutorTests.Probe()
        for n in 0..<UInt32(s.nodes.count) {
            p.entries[s.rawPath(n)] = .ok(Observed(device: 7, flags: 0, isDirectory: s.isDirectory(n), linkCount: 1),
                fileID: s.fileID(n)!, isSymlink: false)
        }
        let ctx = GuardContext(scanRoot: s.rawPath(s.root), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let app = AppModel(coordinator: ScanCoordinator(), stagingStat: p, contextLoader: { _ in ctx })
        app.replaceSnapshot(s)
        let session = try XCTUnwrap(app.session)
        session.selection.nodes = [t["large"]]; app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.jetsam.knownBytes, 80)
        let first = await app.executeJetsam(confirmedWarnings: [], trasher: p, stat: p, log: p)
        XCTAssertEqual(first?.reclaimableBytes, 80)
        session.jetsam.clear()
        XCTAssertEqual(session.source.allocated(t["parent"]), 20)
        session.selection.nodes = [t["parent"]]; app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.jetsam.knownBytes, 20)
        XCTAssertEqual(TrashConfirmation(items: session.jetsam.items).total(locale: Locale(identifier: "en_US")), "Up to " + displaySize(20, locale: Locale(identifier: "en_US")) + " staged")
        let second = await app.executeJetsam(confirmedWarnings: [], trasher: p, stat: p, log: p)
        XCTAssertEqual(second?.reclaimableBytes, 20)
        XCTAssertTrue(trashSummaryText(try XCTUnwrap(second), locale: Locale(identifier: "en_US")).hasPrefix("Up to " + displaySize(20, locale: Locale(identifier: "en_US"))))
        XCTAssertEqual(p.logs.map(\.bytes), [80, 20])
        XCTAssertEqual(session.source.allocated(s.root), 0)
        let e = try XCTUnwrap(p.logs.last)
        p.entries[Data("/fake-trash/parent".utf8)] = .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1),
            fileID: e.inode, isSymlink: false)
        p.entries[s.rawPath(t["parent"])] = .error(errno: ENOENT)
        let mover = PutBackTests.RestoreProbe()
        let restored = await app.putBack(e, stat: p, mover: mover, log: p)
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(session.source.allocated(s.root), 20)
        XCTAssertEqual(session.overlay.deleted, [t["large"]])
    }

    func test_blocking_put_back_keeps_main_actor_responsive() async throws {
        let (tree, app, p, _, entry) = try await excludedChild(cloud: false)
        let heartbeat = expectation(description: "main actor runs while mover is blocked")
        let mover = BlockingRestoreMover(heartbeat: heartbeat)
        let work = Task { await app.putBack(entry, stat: p, mover: mover, log: p) }
        await fulfillment(of: [heartbeat], timeout: 3)
        let result = await work.value
        XCTAssertEqual(result, .restored)
        XCTAssertFalse(mover.timedOut, "main actor must run before the mover completes")
        withExtendedLifetime(tree) {}
    }

    func test_restore_keeps_captured_session_and_refuses_duplicate_while_blocked() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        let t = TestSnapshot(.dir("/scan/root", [.file("file", 100)]), stats: stats, fileIDs: true)
        let s = t.snapshot, p = ExecutorTests.Probe()
        for n in 0..<UInt32(s.nodes.count) {
            p.entries[s.rawPath(n)] = .ok(Observed(device: 7, flags: 0, isDirectory: s.isDirectory(n), linkCount: 1), fileID: s.fileID(n)!, isSymlink: false)
        }
        let ctx = GuardContext(scanRoot: s.rawPath(s.root), volumeRoot: Data("/".utf8), scanRootDevice: 7,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let app = AppModel(coordinator: ScanCoordinator(), stagingStat: p, contextLoader: { _ in ctx })
        app.replaceSnapshot(s)
        let old = try XCTUnwrap(app.session)
        old.selection.nodes = [t["file"]]; app.stageSelection(); await app.waitForStaging()
        _ = await app.executeJetsam(confirmedWarnings: [], trasher: p, stat: p, log: p)
        XCTAssertEqual(old.overlay.deleted, [t["file"]])
        let e = try XCTUnwrap(p.logs.last), mover = HeldRestoreMover()
        p.entries[Data("/fake-trash/file".utf8)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1), fileID: e.inode, isSymlink: false)
        p.entries[s.rawPath(t["file"])] = .error(errno: ENOENT)
        let work = Task { await app.putBack(e, stat: p, mover: mover, log: p) }
        let started = await Task.detached { mover.waitUntilStarted() }.value
        XCTAssertTrue(started)
        XCTAssertTrue(app.restoresInFlight.contains(e.trashURL!))
        let duplicate = await app.putBack(e, stat: p, mover: mover, log: p)
        XCTAssertEqual(duplicate, .failed("Put Back is already in progress."))
        app.replaceSnapshot(s)
        let replacement = try XCTUnwrap(app.session)
        XCTAssertTrue(old !== replacement)
        mover.release.signal()
        let result = await work.value
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(mover.calls, 1)
        XCTAssertTrue(old.overlay.deleted.isEmpty)
        XCTAssertTrue(replacement.overlay.deleted.isEmpty)
        XCTAssertTrue(app.restoresInFlight.isEmpty)
    }

    private final class HeldRestoreMover: Mover, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var callCount = 0, didTimeOut = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return didTimeOut }
        func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }
        func move(_ from: URL, to: URL) throws {
            lock.lock(); callCount += 1; lock.unlock()
            started.signal()
            let timeout = release.wait(timeout: .now() + 5) == .timedOut
            lock.lock(); didTimeOut = timeout; lock.unlock()
        }
    }

    private final class BlockingRestoreMover: Mover, @unchecked Sendable {
        let heartbeat: XCTestExpectation
        var timedOut = false
        init(heartbeat: XCTestExpectation) { self.heartbeat = heartbeat }
        func move(_ from: URL, to: URL) throws {
            let release = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { self.heartbeat.fulfill(); release.signal() }
            timedOut = release.wait(timeout: .now() + 1) == .timedOut
        }
    }

    func test_end_to_end_on_disk_image() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let ok = try f.file("ok.bin")
        try Data(repeating: 0x41, count: 1_048_576).write(to: ok)
        let warn = try f.file("linked.bin")
        let alias = warn.appendingPathExtension("alias")
        try FileManager.default.linkItem(at: warn, to: alias)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("tree/nested/.Spotlight-V100"), withIntermediateDirectories: true)
        let denied = try f.file(".Spotlight-V100/denied.bin")
        let unknown = f.root.appendingPathComponent("tree/unknown")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("unreadable child".utf8).write(to: unknown.appendingPathComponent("child"))
        XCTAssertEqual(chmod(unknown.path, 0), 0)
        defer { _ = chmod(unknown.path, 0o700) }
        let suite = "Tesserae.EndToEnd." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(coordinator: ScanCoordinator(progressInterval: 0.001), accessLoader: { .granted },
            onboardingStore: OnboardingStore(defaults: defaults))
        await model.waitForAccess()
        XCTAssertTrue(model.onboarding.canScan)
        model.scan(f.root)
        for _ in 0..<3000 {
            if model.scanState == .finished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.scanState, .finished)
        let session = try XCTUnwrap(model.session)
        let snapshot = session.snapshot
        XCTAssertEqual(snapshot.rawPath(snapshot.root), Data(f.root.path.utf8))
        XCTAssertNotNil(session.guardContext)
        let urls = [ok, warn, denied, unknown]
        let nodes = try urls.map { url in
            try XCTUnwrap((0..<UInt32(snapshot.nodes.count)).first { snapshot.rawPath($0) == Data(url.path.utf8) })
        }
        XCTAssertTrue(snapshot.isPermissionDenied(nodes[3]), "real unreadable directory supplies unknown size")
        // Restore access after the scan; its recorded size remains unknown.
        XCTAssertEqual(chmod(unknown.path, 0o700), 0)
        session.selection.nodes = Set(nodes)
        model.stageSelection(); await model.waitForStaging()
        let staged = Dictionary(uniqueKeysWithValues: session.jetsam.items.map { ($0.id, $0) })
        XCTAssertEqual(staged.count, 4)
        XCTAssertEqual(staged[nodes[0]]?.verdict, .ok)
        XCTAssertEqual(staged[nodes[1]]?.verdict, .warn(.otherHardLinks))
        XCTAssertEqual(staged[nodes[2]]?.verdict, .denied(.systemManaged))
        XCTAssertNil(staged[nodes[3]]?.recordedSize)
        XCTAssertEqual(session.jetsam.unknownSizeCount, 1)
        let originalID = try XCTUnwrap(snapshot.fileID(nodes[0]))
        let before = session.source.allocated(snapshot.root)
        let log = JettisonLog(directory: f.root.appendingPathComponent("audit"))
        let ui = JetsamPresentation(log: log)
        ui.prepare(session.jetsam.items)
        ui.confirmation.setConfirmed(nodes[1], true)
        await ui.execute(model, trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()))
        await ui.historyTask?.value
        let result = try XCTUnwrap(ui.result)
        XCTAssertEqual(result.outcomes.count, 4)
        let outcomes = Dictionary(uniqueKeysWithValues: result.outcomes.map { ($0.0.id, $0.1) })
        XCTAssertEqual(outcomes[nodes[2]], .skipped(.systemManaged))
        for node in [nodes[0], nodes[1], nodes[3]] {
            guard case .trashed(let trash)? = outcomes[node] else { return XCTFail("Expected trash for \(node)") }
            XCTAssertTrue(trash.pathComponents.starts(with: f.root.pathComponents))
            if node == nodes[3] { XCTAssertEqual(chmod(trash.path, 0o700), 0) }
        }
        XCTAssertEqual(session.overlay.deleted, Set([nodes[0], nodes[1], nodes[3]]))
        XCTAssertEqual(session.source.allocated(snapshot.root), before - nodes.filter { $0 != nodes[2] }.reduce(0) { $0 + snapshot.allocated($1) })
        XCTAssertEqual(result.reclaimableBytes, snapshot.allocated(nodes[0]), "hard link and unknown excluded")
        XCTAssertEqual(result.unknownSizeTrashed, 1)
        XCTAssertTrue(trashSummaryText(result, locale: Locale(identifier: "en_US")).contains("plus 1 item of unknown size"))
        XCTAssertEqual(log.entries().count, 4)
        XCTAssertEqual(ui.history.count, 3)
        let entry = try XCTUnwrap(ui.history.first { $0.inode == originalID })
        await ui.restore(entry, model: model, mover: ContainedMover(fixtureRoot: f.root, inner: ProductionMover()))
        await ui.historyTask?.value
        XCTAssertEqual(ui.messages[entry.trashURL!], "Put back in its original location.")
        guard case .ok(_, let restoredID, false) = ProductionFileStat().lstat(Data(ok.path.utf8)) else { return XCTFail("Not restored") }
        XCTAssertEqual(restoredID, originalID)
        XCTAssertEqual(try Data(contentsOf: ok).count, 1_048_576)
        XCTAssertFalse(session.overlay.deleted.contains(nodes[0]))
        XCTAssertEqual(ui.history.count, 2)
        XCTAssertEqual(log.entries().last?.action, "putBack")
    }

    func test_age_reference_follows_each_snapshot_scan_start() throws {
        let app = AppModel()
        app.colourChoice = 1
        for seconds: Int64 in [1_700_000_000, 1_800_000_000] {
            var stats = TessScanStats(); stats.started_at = seconds
            let tree = TestSnapshot(.dir("/fixture", [.file("f", 100)]), stats: stats)
            XCTAssertNotEqual(seconds, 0, "precondition: known scan start")
            app.replaceSnapshot(tree.snapshot)
            XCTAssertEqual(app.colourMode, .age(now: Date(timeIntervalSince1970: Double(seconds))))
        }
    }

    func test_hover_updates_only_inspector_and_overlay_lists_follow_tiles() throws {
        let t = TestSnapshot(.dir("/R", [.file("movie.MP4", 100), .denied("private")]))
        let session = AppSession(snapshot: t.snapshot)
        session.resize(to: CGSize(width: 800, height: 600))
        XCTAssertFalse(session.tiles.isEmpty)
        XCTAssertEqual(session.deniedTiles.map(\.tile.node), [t["private"]])
        session.selection.nodes = [t["movie.MP4"]]
        XCTAssertEqual(session.selectedTiles.map(\.tile.node), [t["movie.MP4"]])
        var sessionChanges = 0, inspectorChanges = 0
        let a = session.objectWillChange.sink { sessionChanges += 1 }
        let b = session.inspectorModel.objectWillChange.sink { inspectorChanges += 1 }
        let index = try XCTUnwrap(session.tiles.firstIndex { $0.node == t["movie.MP4"] })
        session.hover(tile: index)
        XCTAssertEqual(session.inspectorModel.info?.node, t["movie.MP4"])
        XCTAssertEqual(inspectorChanges, 1)
        XCTAssertEqual(sessionChanges, 0, "hover must not invalidate SessionView")
        session.hover(tile: nil)
        XCTAssertNil(session.inspectorModel.info)
        session.resize(to: .zero)
        XCTAssertTrue(session.selectedTiles.isEmpty)
        XCTAssertTrue(session.deniedTiles.isEmpty)
        withExtendedLifetime((a, b)) {}
    }

    func test_snapshot_caches_one_kind_byte_per_node() throws {
        let t = kindsFixture()
        let snapshot = t.snapshot
        XCTAssertEqual(snapshot.fileKinds.count, snapshot.nodes.count)
        XCTAssertEqual(MemoryLayout.size(ofValue: snapshot.fileKinds[0]), 1)
        XCTAssertNil(snapshot.fileKind(t["/R.mp4"]), "directories are neutral")
        XCTAssertEqual(snapshot.fileKind(t["movie.MP4"]), .video)
        XCTAssertEqual(snapshot.fileKind(t["photo.png"]), .images)
        XCTAssertNil(snapshot.fileKind(t[".mp4"]))
        XCTAssertNil(snapshot.fileKind(t["unknown.bin"]))
        for _ in 0..<3 {
            XCTAssertEqual(colourIndex(t["movie.MP4"], depth: 0, in: snapshot, mode: .typeFocus([.images, .video])), 3)
        }
    }

    private func kindsFixture() -> TestSnapshot {
        TestSnapshot(.dir("/R.mp4", [.file("movie.MP4", 100), .file("photo.png", 80), .file(".mp4", 60), .file("unknown.bin", 40)]))
    }

    func test_frame_pass_summary_preserves_maximum_p99_and_late_pass_identity() throws {
        let timer = FrameTimer(enabled: true)
        timer.startCapture()
        timer.setPass("age")
        let old = timer.begin("inputs", at: 1)
        timer.setPass("type-focus")
        timer.end(old, at: 1.02)
        let next = timer.begin("inputs", at: 2)
        timer.end(next, at: 2.01)
        timer.setPass("hover")
        for i in 1...100 {
            let token = timer.begin("hover", at: 10)
            timer.end(token, at: 10 + Double(i) / 1000)
        }
        let summaries = timer.passSummaries
        XCTAssertEqual(timer.samples.count, 102)
        XCTAssertEqual(summaries["hover"]?["hover"]?.count, 100)
        XCTAssertEqual(try XCTUnwrap(summaries["hover"]?["hover"]?.maxSeconds), 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summaries["hover"]?["hover"]?.p99Seconds), 0.099, accuracy: 1e-9)
        XCTAssertEqual(summaries["age"]?["inputs"]?.count, 1)
        XCTAssertEqual(try XCTUnwrap(summaries["age"]?["inputs"]?.maxSeconds), 0.02, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summaries["type-focus"]?["inputs"]?.p99Seconds), 0.01, accuracy: 1e-9)
    }

    func test_limited_mode_reaches_engine_and_scan_facts_end_to_end() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("tess-limited-\(UUID())")
        defer { try? fm.removeItem(at: home) }
        let relative = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
        for path in relative {
            let directory = home.appendingPathComponent(path)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 8192).write(to: directory.appendingPathComponent("secret"))
        }
        try Data(repeating: 0x42, count: 7).write(to: home.appendingPathComponent("visible"))
        let expected = relative.map { home.appendingPathComponent($0).path }
        for mode in [ScanMode.full, .limited] {
            let suite = "Tesserae.LimitedTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let c = ScanCoordinator(progressInterval: 0.001, factory: { root, options in
                let paths = (0..<Int(options.skip_count)).map { String(cString: options.skip![$0]!) }
                XCTAssertEqual(paths, mode == .limited ? expected : [])
                return ScanHandle(root: root, options: options)
            })
            let app = AppModel(coordinator: c, accessLoader: { mode == .full ? .granted : .unknown },
                onboardingStore: OnboardingStore(defaults: defaults), homeDirectory: home,
                factsLoader: { _, scan in
                    XCTAssertEqual(scan.limited, mode == .limited, "facts describe the scan mode at launch")
                    return ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan,
                        locale: Locale(identifier: "en_US"))
                })
            await app.waitForAccess()
            if mode == .limited { app.sendOnboarding(.useLimited) }
            XCTAssertEqual(app.scanMode, mode, "precondition")
            app.scan(home)
            // A later permission change must not relabel a Limited scan as Full.
            if mode == .limited { app.sendOnboarding(.activated(.granted)) }
            for _ in 0..<2000 {
                if app.scanState == .finished { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(app.scanState, .finished)
            let snap = try XCTUnwrap(app.session?.snapshot)
            XCTAssertEqual(snap.stats.files, mode == .limited ? 1 : 5)
            XCTAssertEqual(snap.skippedByRequest.map { String(decoding: $0.path, as: UTF8.self) }.sorted(),
                mode == .limited ? expected.sorted() : [])
            XCTAssertTrue(snap.skippedByRequest.allSatisfy { $0.reason == "limited scan" })
            if mode == .limited {
                let nodes = snap.nodes.indices.filter { snap.isSkippedByRequest(UInt32($0)) }
                XCTAssertEqual(nodes.count, 4)
                for node in nodes {
                    XCTAssertTrue(snap.children(UInt32(node)).isEmpty)
                    XCTAssertTrue(snap.isPermissionDenied(UInt32(node)), "uses unknown-size rendering")
                }
            }
        }
    }

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

    /// Final review I2: the stalled path is made of names, so it is shown as
    /// they are (one line, bidi and format characters neutralised).
    func test_banner_neutralises_a_crafted_stalled_path() throws {
        var stats = TessScanStats()
        stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
        let text = try XCTUnwrap(ScanBanner.text(for: stats, stalledAt: "/a\u{202E}b\nc"))
        XCTAssertTrue(text.contains("stalled at /a\u{FFFD}b c"), text)
        XCTAssertFalse(text.contains("\u{202E}"), text)
        XCTAssertFalse(text.contains { $0.isNewline }, text)
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
        // Not empty, but nothing allocated: dataless (evicted) files or hardlink duplicates counted once elsewhere.
        let zero = TestSnapshot(.dir("/zero", [.file("dataless", 0, logical: 4096), .file("duplicate", 0, logical: 100)]))
        XCTAssertEqual(zero.snapshot.children(zero.snapshot.root).count, 2, "precondition: the folder has entries")
        app.replaceSnapshot(zero.snapshot)
        let unallocated = try XCTUnwrap(app.session)
        unallocated.resize(to: CGSize(width: 600, height: 400))
        XCTAssertTrue(unallocated.tiles.isEmpty)
        XCTAssertTrue(unallocated.isEmpty, "entries with no allocated bytes have nothing to draw")
    }

    func test_rescan_swaps_snapshot_atomically() async throws {
        var a: TestSnapshot? = TestSnapshot(.dir("/A", [.dir("sub", [.file("a", 20), .file("b", 10)])]))
        let b = TestSnapshot(.dir("/B", [.file("only", 100)]))
        let app = AppModel()
        app.replaceSnapshot(try XCTUnwrap(a).snapshot)
        weak let oldSnapshot = a?.snapshot
        var old: AppSession? = try XCTUnwrap(app.session)
        let sub = try XCTUnwrap(a)["sub"], fileB = try XCTUnwrap(a)["b"]
        try XCTUnwrap(old).resize(to: CGSize(width: 600, height: 400))
        try XCTUnwrap(old).navigator.descend(into: sub)
        try XCTUnwrap(old).selection.nodes = [fileB]
        let bTile = try XCTUnwrap(old?.tiles.firstIndex { $0.node == fileB })
        try XCTUnwrap(old).hover(tile: bTile)
        // The renderer completed navigation before this rescan.
        try XCTUnwrap(old).setZoomRunning(false, generation: try XCTUnwrap(old).layoutGeneration)
        await old?.waitForTable()
        await old?.waitForLabels()
        XCTAssertNotNil(old?.inspector)
        XCTAssertFalse(try XCTUnwrap(old).table.rows.isEmpty)
        XCTAssertFalse(try XCTUnwrap(old).selection.nodes.isEmpty)
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
        XCTAssertNil(current.inspector, "precondition: nothing has hovered the new session")
        old?.hover(tile: bTile)
        XCTAssertNotNil(old?.inspector, "precondition: the old session still answers its own hover")
        XCTAssertNil(current.inspector, "old callbacks cannot change the new session")
        XCTAssertNotNil(oldSnapshot, "precondition: the old session still owns its snapshot")
        old = nil
        a = nil
        XCTAssertNil(oldSnapshot, "the replaced session releases the old snapshot")
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

    func test_frame_gate_configuration_comes_from_the_environment_in_every_build() throws {
        let tmp = URL(fileURLWithPath: "/private/tmp/gate-test", isDirectory: true)
        let off = try FrameGateConfiguration(environment: [:], temporaryDirectory: tmp)
        XCTAssertFalse(off.timingEnabled)
        XCTAssertNil(off.autorunRoot)
        XCTAssertEqual(off.output.path, "/private/tmp/gate-test/tesserae-frame-gate.json")
        XCTAssertFalse(try FrameGateConfiguration(environment: ["TESSERAE_FRAME_TIMING": "yes"], temporaryDirectory: tmp).timingEnabled)
        let on = try FrameGateConfiguration(
            environment: [
                "TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": "/System/Volumes/Data",
                "TESSERAE_FRAME_GATE_OUT": "/Fixture/gate.json",
            ], temporaryDirectory: tmp)
        XCTAssertTrue(on.timingEnabled)
        XCTAssertEqual(on.autorunRoot?.path, "/System/Volumes/Data")
        XCTAssertEqual(on.output.path, "/Fixture/gate.json")
        XCTAssertNil(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": ""], temporaryDirectory: tmp).autorunRoot)
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": "relative/root"], temporaryDirectory: tmp))
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_GATE_AUTORUN": "/System/Volumes/Data"], temporaryDirectory: tmp),
            "autorun measures nothing without timing")
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_OUT": "gate.json"], temporaryDirectory: tmp))
        // Debug builds no longer record unless asked to: the same variable decides in every configuration.
        XCTAssertEqual(FrameTimer.shared.isEnabled, ProcessInfo.processInfo.environment["TESSERAE_FRAME_TIMING"] == "1")
        XCTAssertFalse(FrameTimer(enabled: false).isEnabled)
    }

    func test_frame_gate_timeout_from_the_environment() throws {
        let tmp = URL(fileURLWithPath: "/private/tmp/gate-test", isDirectory: true)
        XCTAssertEqual(try FrameGateConfiguration(environment: [:], temporaryDirectory: tmp).timeout, .seconds(900))
        XCTAssertEqual(
            try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": "120"], temporaryDirectory: tmp).timeout,
            .seconds(120))
        XCTAssertEqual(
            try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": "2.5"], temporaryDirectory: tmp).timeout,
            .milliseconds(2500))
        for bad in ["0", "-5", "soon", "nan", "inf"] {
            XCTAssertThrowsError(
                try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": bad], temporaryDirectory: tmp), bad)
        }
    }

    func test_frame_gate_deadline_bounds_every_wait() async throws {
        let clock = ContinuousClock()
        // A condition that never holds: the wait gives up at the deadline, not later.
        let short = FrameGateDeadline(after: .milliseconds(150))
        XCTAssertFalse(short.isExpired(), "precondition")
        let start = clock.now
        let ended = expectation(description: "the wait ended")
        var met: Bool?
        // In a task, so a wait that ignored its deadline fails here instead of hanging the suite.
        let waiting = Task { @MainActor in
            met = await short.wait(every: .milliseconds(20)) { false }
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 2)
        waiting.cancel()
        let waited = clock.now - start
        XCTAssertEqual(met, false)
        XCTAssertTrue(short.isExpired())
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(140))
        XCTAssertLessThan(waited, .seconds(2), "the wait ends at the deadline")
        // Once expired, later waits fail at once: one deadline covers every stage.
        let again = clock.now
        let late = await short.wait { false }
        XCTAssertFalse(late)
        XCTAssertLessThan(clock.now - again, .milliseconds(100))
        // A condition that holds returns true, including one that becomes true later.
        let long = FrameGateDeadline(after: .seconds(10))
        let alreadyMet = await long.wait { true }
        XCTAssertTrue(alreadyMet)
        var polls = 0
        let laterMet = await long.wait(every: .milliseconds(5)) { polls += 1; return polls >= 3 }
        XCTAssertTrue(laterMet)
        XCTAssertEqual(polls, 3)
        // An expired deadline fails even a condition that holds: one deadline ends every stage.
        let expired = FrameGateDeadline(after: .zero)
        XCTAssertTrue(expired.isExpired())
        let metLate = await expired.wait { true }
        XCTAssertFalse(metLate)
    }

    func test_phase_gate_cancel_stops_the_run_without_writing_a_capture() async throws {
        let t = TestSnapshot(.dir("/gate", (1...5).map { .dir("d\($0)", [.file("f\($0)", UInt64(10 * $0))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.setZoomRunning(true, generation: session.layoutGeneration)  // each transition would take 3 s
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(100))
        let done = expectation(description: "gate stopped")
        var outcome: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/gate", minimumNodes: 0, output: output, completion: {
            outcome = $0
            done.fulfill()
        })
        XCTAssertTrue(runner.isRunning, "precondition")
        try await Task.sleep(for: .milliseconds(50))
        runner.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(outcome, .failed("The frame gate was cancelled."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancelled run writes nothing")
    }

    func test_phase_gate_runs_the_protocol_on_the_requested_root_and_writes_the_capture() async throws {
        let dirs = ["d1", "d2", "d3", "d4", "d5", "d6"]
        let t = TestSnapshot(.dir("/gate", dirs.enumerated().map { i, d in .dir(d, [.file("\(d).bin", UInt64(100 - i))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(1))

        var refused: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/elsewhere", minimumNodes: 0, output: output, completion: { refused = $0 })
        guard case .failed(let reason)? = refused else { return XCTFail("a different root must be refused") }
        XCTAssertTrue(reason.contains("/elsewhere"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let done = expectation(description: "gate finished")
        var outcome: PhaseGateRunner.Outcome?
        var modes: [ColourMode] = []
        runner.run(session: session, requiredRoot: "/gate/", minimumNodes: 0, output: output, setMode: { modes.append($0) }, completion: {
            outcome = $0
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(outcome, .saved(output))
        XCTAssertEqual(session.navigator.root, t.snapshot.root)
        struct Capture: Decodable {
            let root: String, build: String, nodes: Int, directories: [String], settleTimeouts: Int
            let samples: [FrameTimer.Sample]
            let passes: [String]
            let summaries: [String: [String: FrameTimer.Summary]]
        }
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: output))
        XCTAssertEqual(capture.passes, ["depth", "age", "type-focus", "hover"])
        XCTAssertEqual(modes, [.depth, .age(now: Date(timeIntervalSince1970: Double(t.snapshot.stats.started_at))), .typeFocus([.video, .images, .audio])])
        XCTAssertEqual(Set(capture.summaries.keys), Set(capture.passes))
        XCTAssertEqual(capture.summaries["hover"]?["hover"]?.count, 240)
        XCTAssertEqual(capture.root, "/gate")
        XCTAssertEqual(capture.directories, ["d1", "d2", "d3", "d4", "d5"], "the five largest readable root directories")
        XCTAssertEqual(capture.nodes, t.snapshot.nodes.count)
        XCTAssertEqual(capture.settleTimeouts, 0, "no treemap view, so every transition settles at once")
        #if DEBUG
        XCTAssertEqual(capture.build, "Debug")
        #else
        XCTAssertEqual(capture.build, "Release")
        #endif
    }

    func test_phase_gate_rejects_a_run_whose_zooms_never_finish() async throws {
        let t = TestSnapshot(.dir("/gate", (1...5).map { .dir("d\($0)", [.file("f\($0)", UInt64(10 * $0))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        // A view that never draws never ends its zoom.
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.zoomRunning, "precondition")
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(1))
        let done = expectation(description: "gate finished")
        var outcome: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/gate", minimumNodes: 0, output: output, completion: {
            outcome = $0
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 30)
        guard case .failed(let reason)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(reason.contains("not a valid run"), reason)
        struct Capture: Decodable { let settleTimeouts: Int }
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: output))
        XCTAssertEqual(capture.settleTimeouts, 90, "the evidence is kept, and says why it is invalid")
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
        // A resize between the layouts cancels the zoom, as `cancelPendingZoom` does for a descend:
        // the old rects belong to the pre-resize viewport.
        let resized = CGRect(x: 0, y: 0, width: 700, height: 500)
        let resizedParent = [Tile(rect: resized, node: 0, depth: 0), Tile(rect: target, node: 7, depth: 1)]
        let resizedChild = [Tile(rect: resized, node: 7, depth: 0)]
        XCTAssertNotNil(TreemapView.navigationZoomRect(old: child, new: parent, viewport: viewport), "precondition")
        XCTAssertNil(TreemapView.navigationZoomRect(old: child, new: resizedParent, viewport: resized))
        XCTAssertNil(TreemapView.navigationZoomRect(old: parent, new: resizedChild, viewport: resized))
    }

    func test_navigation_defers_labels_and_table_until_zoom_settles() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        let oldGeneration = session.layoutGeneration
        session.navigator.descend(into: t["sub"])
        session.setZoomRunning(false, generation: oldGeneration)
        XCTAssertEqual(session.tiles.first?.node, t["sub"])
        XCTAssertTrue(session.labels.isEmpty, "do not measure labels on the navigation critical path")
        await session.waitForTable()
        XCTAssertNil(session.table.content, "defer table traversal and publication during motion")
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.labels.isEmpty)
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertEqual(Set(session.table.rows), [t["large"], t["small"]])
        session.navigator.ascend()
        XCTAssertTrue(session.labels.isEmpty)
        // A fallback or cancelled animation settles without starting.
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        session.navigator.descend(into: t["empty"])
        await session.waitForTable()
        XCTAssertTrue(session.isEmpty)
        XCTAssertNotNil(session.table.content, "an empty folder has no renderer to send a completion callback")
        XCTAssertTrue(session.table.rows.isEmpty)
    }

    func test_leaving_an_empty_folder_settles_labels_and_table() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty, "precondition")
        session.navigator.descend(into: t["empty"])
        XCTAssertTrue(session.isEmpty, "precondition: the view shows the empty state, with no treemap")
        await session.waitForTable()
        XCTAssertNotNil(session.table.content, "precondition: the empty folder settled")
        session.navigator.ascend()
        // The rebuilt treemap reports nothing: makeNSView installed these tiles,
        // so its first update sees no change and no zoom.
        XCTAssertFalse(session.isEmpty)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.zoomRunning)
        XCTAssertFalse(session.labels.isEmpty, "labels must not stay pending after leaving an empty folder")
        XCTAssertNotNil(session.table.content, "the table must not stay pending after leaving an empty folder")
        XCTAssertFalse(session.table.rows.isEmpty)
    }

    func test_tearing_the_treemap_down_mid_zoom_clears_zoom_running() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.zoomRunning, "precondition: a zoom is running")
        let running = session.layoutGeneration
        session.navigator.descend(into: t["empty"])
        XCTAssertTrue(session.isEmpty, "precondition: the treemap view is removed")
        // The removed view's final report carries the old generation and is dropped.
        session.setZoomRunning(false, generation: running)
        XCTAssertFalse(session.zoomRunning, "no renderer remains to end the zoom")
        await session.waitForTable()
        XCTAssertNotNil(session.table.content)
        XCTAssertTrue(session.labels.isEmpty)
    }

    func test_breadcrumb_jump_relayouts_once() throws {
        let t = TestSnapshot(.dir("/R", [.dir("a", [.dir("b", [.dir("c", [.file("f", 10)])])])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.navigator.descend(into: t["c"])
        XCTAssertEqual(session.navigator.breadcrumb.count, 4, "precondition: three levels below the root")
        var published = 0
        let observation = session.$tiles.dropFirst().sink { _ in published += 1 }
        let before = session.layoutGeneration
        session.go(to: t.snapshot.root)
        XCTAssertEqual(session.navigator.root, t.snapshot.root)
        XCTAssertEqual(session.layoutGeneration, before &+ 1, "one squarify for a deep jump")
        XCTAssertEqual(published, 1, "one tiles publication for a deep jump")
        session.go(to: t["b"])
        XCTAssertEqual(session.navigator.root, t.snapshot.root, "only ancestors on the breadcrumb are targets")
        session.go(to: t.snapshot.root)
        XCTAssertEqual(session.layoutGeneration, before &+ 1, "jumping to the current root does nothing")
        withExtendedLifetime(observation) {}
    }

    func test_labels_are_placed_off_the_main_actor_under_the_generation_guard() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .file("top", 60)]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        let probe = MeasureProbe()
        session.labelMeasure = { text in probe.measure(text) }
        session.resize(to: CGSize(width: 800, height: 600))
        // Placement is blocked inside its first measurement; the main actor is not.
        XCTAssertTrue(probe.waitUntilBlocked(), "precondition: placement started")
        XCTAssertTrue(session.labels.isEmpty, "precondition: nothing placed yet")
        session.navigator.descend(into: t["sub"])
        probe.release()
        await session.waitForLabels()
        XCTAssertTrue(session.labels.isEmpty, "a placement for an earlier layout is never applied")
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForLabels()
        let texts = session.labels.map(\.text)
        XCTAssertFalse(texts.isEmpty)
        XCTAssertTrue(texts.contains { $0.hasPrefix("large") }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("top") }, "only the current layout's labels: \(texts)")
        XCTAssertGreaterThan(probe.calls, 0)
        XCTAssertEqual(probe.mainThreadCalls, 0, "label text is measured off the main thread")
    }

    func test_labels_ready_only_once_the_current_layouts_labels_are_applied() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .file("top", 60)]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        let probe = MeasureProbe()
        session.labelMeasure = { text in probe.measure(text) }
        XCTAssertFalse(session.labelsReady, "nothing placed yet")
        session.resize(to: CGSize(width: 800, height: 600))
        XCTAssertTrue(probe.waitUntilBlocked(), "precondition: placement started")
        XCTAssertFalse(session.labelsReady, "not ready while placement runs")
        probe.release()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty, "precondition")
        XCTAssertTrue(session.labelsReady)
        // A resize hides the stale labels at once, before the new ones are placed.
        session.resize(to: CGSize(width: 700, height: 500))
        XCTAssertFalse(session.labelsReady, "stale labels are hidden at the start of a resize relayout")
        await session.waitForLabels()
        XCTAssertTrue(session.labelsReady)
        // A navigation: not ready through the zoom and until the settle's placement is applied.
        session.navigator.descend(into: t["sub"])
        XCTAssertFalse(session.labelsReady)
        session.setZoomRunning(true, generation: session.layoutGeneration)
        session.setZoomRunning(false, generation: session.layoutGeneration)
        XCTAssertFalse(session.labelsReady, "the zoom ending is not the labels arriving")
        await session.waitForLabels()
        XCTAssertTrue(session.labelsReady)
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

/// A label measure that records which thread calls it and blocks its first
/// call until released (or a timeout, so a main-thread caller cannot hang the suite).
private final class MeasureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var first = true
    private var _calls = 0, _main = 0

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var mainThreadCalls: Int { lock.lock(); defer { lock.unlock() }; return _main }

    func measure(_ text: String) -> CGSize {
        lock.lock()
        _calls += 1
        if Thread.isMainThread { _main += 1 }
        let wait = first
        first = false
        lock.unlock()
        if wait {
            blocked.signal()
            _ = gate.wait(timeout: .now() + 2)
        }
        return CGSize(width: 6 * CGFloat(text.count), height: 12)
    }

    func waitUntilBlocked() -> Bool { blocked.wait(timeout: .now() + 2) == .success }
    func release() { gate.signal() }
}
