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

@MainActor
final class ReclaimViewModelTests: XCTestCase {
    func test_staging_is_ready_without_filesystem_inspection() async throws {
        let probe = BlockingArchiveFiles()
        defer { probe.release.signal() }
        let path = Data(URL(fileURLWithPath: #filePath).path.utf8)
        let staged = ReclaimItem(nodeIndex: 1, path: path,
            recorded: Recorded(fileID: 1, device: 1, isDirectory: false), recordedSize: 512, verdict: .ok)
        let vm = ReclaimViewModel(defaults: nil, archiveFiles: probe)
        vm.prepare([staged], context: nil)
        XCTAssertEqual(vm.items.count, 1, "precondition: staging published an item")
        XCTAssertEqual(vm.items[0].action, .compress, "precondition: the Compress default is selected")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1,
            "Compress must be immediately confirmable, even if archive inspection would block forever")
        vm.setAction(.trash, for: 1)
        XCTAssertEqual(vm.items[0].action, .trash)
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.calls, 0, "Trash and Compress never invoke Archive inspection")
        vm.replace([], volumes: [:])
    }

    func test_user_choice_survives_restaging() {
        let staged = item(1, .ok, 512)
        let vm = ReclaimViewModel(items: [staged], volumes: [1: appleVolume], defaults: nil)
        XCTAssertEqual(vm.items[0].action, .compress, "precondition: the new default is Compress")
        vm.setAction(.trash, for: 1)
        XCTAssertEqual(vm.items[0].action, .trash, "precondition: an explicit choice was made")
        vm.replace([staged, item(2, .ok, 256)], volumes: [1: appleVolume, 2: appleVolume])
        XCTAssertEqual(vm.items.map(\.action), [.trash, .compress])
        var replacement = staged
        replacement = ReclaimItem(nodeIndex: staged.id, path: Data("/different/item".utf8),
            recorded: staged.recorded, recordedSize: 512, verdict: .ok)
        vm.replace([replacement], volumes: [1: appleVolume])
        XCTAssertEqual(vm.items[0].action, .compress, "a reused node ID cannot inherit another item's choice")
        let other = ReclaimViewModel(items: [staged], volumes: [1: VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat")], defaults: nil)
        XCTAssertEqual(other.items[0].action, .trash, "precondition: unsupported volume defaults to Trash")
        other.setAction(.trash, for: 1)
        other.replace([staged], volumes: [1: appleVolume])
        XCTAssertEqual(other.items[0].action, .trash, "explicitly choosing the current default is still a user choice")
        vm.replace([], volumes: [:])
    }

    func test_archive_item_blocks_only_itself_until_inspected() async throws {
        let probe = BlockingArchiveFiles()
        defer { probe.release.signal() }
        let vm = reviewWithProbe(probe)
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 2, "precondition: both start ready")
        vm.setAction(.archive(.zip), for: 1)
        XCTAssertTrue(vm.checking.contains(1))
        XCTAssertEqual(vm.estimateText(for: vm.items[0]), "Checking…")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1)
        XCTAssertEqual(TrashConfirmation(items: vm.items).checkingItems.map(\.id), [1])
        XCTAssertEqual(vm.items[1].actionAvailability, .available)
        await assertStarted(probe.started)
        let ui = ReclaimPresentation(historyLoader: { [] })
        ui.prepare(vm.items, viewModel: vm)
        XCTAssertTrue(ui.showingConfirmation, "precondition: other items can open confirmation")
        XCTAssertEqual(ui.confirmation.movingCount, 1)
        probe.release.signal()
        await vm.waitForInspection(1)
        XCTAssertTrue(ui.showingConfirmation, "an Archive completion cannot interrupt confirmation for other items")
        XCTAssertEqual(ui.confirmation.movingCount, 1, "the frozen pending Archive item stays excluded from this batch")
        XCTAssertFalse(vm.checking.contains(1))
        XCTAssertEqual(vm.items[0].actionAvailability, .available)
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 2)
        XCTAssertEqual(probe.calls, 1, "the inspection is reused for the archive estimate")
        vm.replace([], volumes: [:])
    }

    func test_stale_inspection_result_is_dropped() async throws {
        let probe = BlockingArchiveFiles()
        probe.facts = ArchiveItemFacts(containsUnknownContent: true, containsRealAppleDouble: true)
        defer { probe.release.signal(); probe.laterRelease.signal() }
        let vm = reviewWithProbe(probe)
        vm.setAction(.archive(.zip), for: 1)
        await assertStarted(probe.started)
        let old = vm.inspectionTask(for: 1)
        vm.setAction(.trash, for: 1)
        XCTAssertFalse(vm.checking.contains(1))
        XCTAssertEqual(vm.items[0].action, .trash, "precondition: choice changed while inspection is blocked")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 2)
        // A new Archive choice for the same ID must not accept the previous generation's result.
        vm.setAction(.archive(.zip), for: 1)
        await assertStarted(probe.started)
        let current = vm.inspectionTask(for: 1)
        probe.release.signal()
        await old?.value
        XCTAssertTrue(vm.checking.contains(1), "the superseded inspection cannot unlock the newer Archive choice")
        XCTAssertFalse(vm.items[0].archiveFacts.containsUnknownContent)
        vm.setAction(.trash, for: 1)
        probe.laterRelease.signal()
        await current?.value
        XCTAssertEqual(vm.items[0].action, .trash)
        XCTAssertFalse(vm.items[0].archiveFacts.containsUnknownContent)
        XCTAssertEqual(vm.availability(.archive(.zip), for: vm.items[0]), .available)
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 2)
        vm.setAction(.archive(.zip), for: 1)
        await assertStarted(probe.started)
        let restaged = vm.inspectionTask(for: 1)
        vm.replace([], volumes: [:])
        probe.release.signal()
        await restaged?.value
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.checking.isEmpty)
    }

    func test_estimate_fills_in_without_blocking() async throws {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let vm = ReclaimViewModel(items: [item(1, .ok, 1_000_000_000)], volumes: [1: appleVolume],
            defaults: nil, compressionEstimate: { _ in started.signal(); release.wait(); return 500_000_000 })
        XCTAssertEqual(vm.items[0].action, .compress)
        XCTAssertTrue(vm.estimating.contains(1))
        XCTAssertEqual(vm.estimateText(for: vm.items[0]), "Estimating…")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1)
        await assertStarted(started)
        let frozen = vm.items
        release.signal()
        await vm.waitForEstimate()
        XCTAssertFalse(vm.estimating.contains(1))
        XCTAssertEqual(vm.items, frozen, "an estimate cannot invalidate an open confirmation")
        XCTAssertEqual(vm.estimateText(for: vm.items[0], locale: Locale(identifier: "en_US")),
            "Saves about 500 MB (estimated)")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1)
    }

    func test_compress_review_does_not_claim_unperformed_process_inspection() {
        let vm = ReclaimViewModel(items: [item(1, .ok, 512)], volumes: [1: appleVolume],
            defaults: nil, compressionEstimate: { _ in 0 })
        XCTAssertEqual(vm.items[0].action, .compress, "precondition: reviewing Compress")
        let ui = ReclaimPresentation(historyLoader: { [] })
        ui.prepare(vm.items, viewModel: vm)
        XCTAssertTrue(ui.showingConfirmation)
        XCTAssertFalse((ui.confirmation.notes[1] ?? []).isEmpty, "precondition: confirmation notes were built")
        XCTAssertFalse((ui.confirmation.notes[1] ?? []).contains(
            "Processes belonging to other users could not all be inspected."))
        vm.replace([], volumes: [:])
    }

    func test_trash_starts_no_estimate_and_compress_estimate_is_cancelled_when_choice_changes() async {
        let probe = CountingEstimator()
        let staged = ReclaimItem(nodeIndex: 1, path: Data("/Fixture/image.png".utf8),
            recorded: Recorded(fileID: 2, device: 1, isDirectory: false), recordedSize: 512, verdict: .ok)
        let vm = ReclaimViewModel(items: [staged], volumes: [1: appleVolume], defaults: nil,
            compressionEstimate: { _ in probe.estimate() })
        XCTAssertEqual(vm.items[0].action, .trash, "precondition: won't-shrink file defaults to Trash")
        vm.setAction(.trash, for: 1)
        await vm.waitForEstimate()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertTrue(vm.estimating.isEmpty)
        XCTAssertNil(vm.inspectionTask(for: 1))
        XCTAssertEqual(vm.availability(.compress, for: vm.items[0]), .available)
        vm.setAction(.compress, for: 1)
        XCTAssertEqual(vm.items[0].action, .compress)
        await assertStarted(probe.started)
        XCTAssertEqual(probe.calls, 1)
        let pending = vm.inspectionTask(for: 1)
        XCTAssertNotNil(pending, "precondition: estimate is running")
        vm.setAction(.trash, for: 1)
        XCTAssertEqual(vm.items[0].action, .trash)
        XCTAssertTrue(vm.estimating.isEmpty)
        XCTAssertNil(vm.inspectionTask(for: 1))
        await pending?.value
        await vm.waitForEstimate()
        XCTAssertEqual(probe.cancelled, 1, "switching away cancels the running estimator")
        XCTAssertEqual(probe.calls, 1, "explicit Trash must not start another estimate")
        vm.replace([], volumes: [:])
    }

    func test_archive_inspection_cancels_background_walk() throws {
        let path = Data(URL(fileURLWithPath: #filePath).path.utf8)
        let ordinary = try ProductionArchiveFileSystem().inspect(path)
        XCTAssertFalse(ordinary.files.isEmpty, "precondition: the real file can be inspected")
        let cancelled = ProductionArchiveFileSystem(isCancelled: { true })
        XCTAssertThrowsError(try cancelled.inspect(path)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_volume_capabilities_are_cached_per_device() {
        let probe = VolumeProbe()
        let vm = ReclaimViewModel(defaults: nil, volumeLoader: { probe.load($0) })
        vm.prepare([item(1, .ok, 512), item(2, .ok, 512)], context: nil)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(probe.calls, 1, "one statfs for two items on the same volume")
        vm.prepare(vm.items, context: nil)
        XCTAssertEqual(probe.calls, 1, "restaging reuses the volume cache")
        XCTAssertEqual(vm.items.map(\.actionAvailability), [.available, .available])
        vm.replace([], volumes: [:])
        let failed = VolumeProbe(result: VolumeCapabilities(isLocal: false, isWritable: false, fsType: ""))
        let retry = ReclaimViewModel(defaults: nil, volumeLoader: { failed.load($0) })
        retry.prepare([item(1, .ok, 512), item(2, .ok, 512)], context: nil)
        XCTAssertEqual(failed.calls, 1, "a failed statfs is shared within one staging request")
        XCTAssertEqual(TrashConfirmation(items: retry.items).movingCount, 0, "a failed observation fails closed")
        retry.prepare(retry.items, context: nil)
        XCTAssertEqual(failed.calls, 2, "failed capabilities can be retried on restaging")
    }

    private nonisolated static func blockingStartWait(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + 3)
    }
    private func assertStarted(_ semaphore: DispatchSemaphore, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await Task.detached { Self.blockingStartWait(semaphore) }.value
        XCTAssertEqual(result, .success, "precondition: background work actually started", file: file, line: line)
    }

    private func reviewWithProbe(_ probe: BlockingArchiveFiles) -> ReclaimViewModel {
        let path = Data(URL(fileURLWithPath: #filePath).path.utf8)
        let staged = (1...2).map { id in ReclaimItem(nodeIndex: UInt32(id), path: path,
            recorded: Recorded(fileID: UInt64(id), device: 1, isDirectory: false), recordedSize: 512, verdict: .ok) }
        return ReclaimViewModel(items: staged, volumes: [1: appleVolume, 2: appleVolume], defaults: nil,
            archiveFiles: probe, archiveSafety: { _, _ in true }, compressionEstimate: { _ in 0 })
    }


    func test_reclaim_paths_use_neutral_distinct_display_and_keep_raw_bytes() throws {
        let raw = [Data("/fixture/evil\u{202e}gpj.exe".utf8), Data("/fixture/tiny\nname".utf8),
                   Data("/fixture/bad-".utf8) + Data([255]), Data("/fixture/bad-".utf8) + Data([254])]
        let items = raw.enumerated().map { index, path in
            ReclaimItem(nodeIndex: UInt32(index), path: path, recorded: Recorded(fileID: UInt64(index + 1), device: 1, isDirectory: false),
                recordedSize: 1, verdict: .warn(.appContainer))
        }
        let confirmation = TrashConfirmation(items: items)
        let displays = confirmation.warningRows.map(\.path)
        XCTAssertEqual(displays[0], "/fixture/evil\u{fffd}gpj.exe")
        XCTAssertEqual(displays[1], "/fixture/tiny name")
        XCTAssertNotEqual(displays[2], displays[3])
        XCTAssertTrue(displays[2].contains("\u{fffd}")); XCTAssertTrue(displays[3].contains("\u{fffd}"))
        XCTAssertEqual(confirmation.items.map(\.path), raw)
        for (index, path) in raw.enumerated() {
            let entry = LogEntry(ts: Date(), action: "compress", path: String(data: path, encoding: .utf8),
                pathB64: String(data: path, encoding: .utf8) == nil ? path.base64EncodedString() : nil,
                inode: 1, bytes: 1, trashURL: nil, result: "ok")
            XCTAssertEqual(entry.displayPath, displays[index])
        }
    }

    func test_reclaim_path_and_cancellation_controls_are_wired_at_every_surface() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: apple.appendingPathComponent("Tesserae/ReclaimView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: apple.appendingPathComponent("Tesserae/ConfirmReclaimSheet.swift"), encoding: .utf8)
        let summary = try String(contentsOf: apple.appendingPathComponent("Tesserae/ReclaimSummaryView.swift"), encoding: .utf8)
        let content = try String(contentsOf: apple.appendingPathComponent("Tesserae/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("Text(item.displayPath)"))
        XCTAssertEqual(view.components(separatedBy: "Text(DisplayPath.text(row.path))").count - 1, 2)
        XCTAssertEqual(view.components(separatedBy: "Text(entry.displayPath)").count - 1, 2)
        XCTAssertEqual(sheet.components(separatedBy: "Text(item.displayPath)").count - 1, 3)
        XCTAssertTrue(sheet.contains("Text(item.path)"), "WarningRow.path is already neutralised")
        XCTAssertTrue(summary.contains("Text(pair.0.displayPath)"))
        for source in [view, sheet, summary] { XCTAssertFalse(source.contains("String(decoding:")) }
        XCTAssertTrue(sheet.contains("defaultValue: \"Stop after this batch\""))
        XCTAssertTrue(sheet.contains("action: cancel).disabled(cancellationRequested)"))
        XCTAssertEqual(content.components(separatedBy: "cancel: reclaimUI.cancelExecution").count - 1, 2)
        XCTAssertTrue(content.contains("move: { reclaimUI.startExecution(model) }"))
        XCTAssertTrue(content.contains("execute: { reclaimUI.startDecompression(run: review.run, model: model) }"))
        XCTAssertTrue(content.contains("if !$0 { reclaimUI.dismissDecompression() }"))
        XCTAssertTrue(content.contains("cancel: reclaimUI.dismissDecompression"))
    }

    func test_unavailable_action_disabled_with_reason() {
        let i = item(1, .ok, 100)
        let ro = VolumeCapabilities(isLocal: true, isWritable: false, fsType: "apfs")
        let actions = availableActions(for: i, volume: ro, verdict: .ok)
        XCTAssertEqual(actions[.trash], .unavailable("This disk is read-only."))
        let vm = ReclaimViewModel(items: [i], volumes: [1: ro], defaults: nil)
        XCTAssertEqual(vm.availability(.trash, for: i), .unavailable("This disk is read-only."))
        vm.setAction(.compress, for: 1)
        XCTAssertEqual(vm.items[0].action, .trash, "unavailable choices cannot be selected")
        XCTAssertEqual(vm.items[0].actionAvailability, .unavailable("This disk is read-only."))
        let confirmation = TrashConfirmation(items: vm.items)
        XCTAssertEqual(confirmation.deniedItems.map(\.id), [1])
        XCTAssertEqual(confirmation.movingCount, 0)
    }

    func test_action_change_invalidates_open_review() {
        let vm = ReclaimViewModel(items: [item(1, .ok, 100)], volumes: [1: appleVolume], defaults: nil)
        let ui = ReclaimPresentation(log: ReclaimLog(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("unused-task12-log")))
        ui.prepare(vm.items, viewModel: vm)
        XCTAssertTrue(ui.showingConfirmation)
        vm.setAction(.trash, for: 1)
        XCTAssertFalse(ui.showingConfirmation)
        ui.prepare(vm.items, viewModel: vm)
        vm.setAction(.archive(.zip), for: 1)
        XCTAssertFalse(ui.showingConfirmation)
        ui.prepare(vm.items, viewModel: vm)
        vm.setAction(.archive(.tarXZ), for: 1)
        XCTAssertFalse(ui.showingConfirmation)
        XCTAssertEqual(ui.confirmation.items[0].action, .archive(.zip), "review stays frozen")
    }

    func test_confirmation_groups_by_action_and_lists_all_warnings_and_skips() async {
        var a = item(1, .ok, 100); a.action = .compress
        a.archiveFacts = ArchiveItemFacts(containsGitWorkingTree: true, largestFileSize: 5_000_000_000)
        let b = ReclaimItem(nodeIndex: 2, path: Data(URL(fileURLWithPath: #filePath).path.utf8),
            recorded: Recorded(fileID: 3, device: 1, isDirectory: false), recordedSize: 200,
            verdict: .warn(.appContainer), action: .archive(.zip))
        let probe = BlockingArchiveFiles()
        probe.release.signal()
        let vm = ReclaimViewModel(items: [a, b, item(3, .denied(.restricted), nil)],
            volumes: [1: appleVolume, 2: appleVolume, 3: appleVolume], defaults: nil,
            archiveFiles: probe, archiveSafety: { _, _ in true }, compressionEstimate: { _ in 0 })
        await vm.waitForInspection(2)
        XCTAssertFalse(vm.items[1].isCheckingArchive, "precondition: the Archive item was inspected")
        XCTAssertEqual(probe.calls, 1)
        let c = TrashConfirmation(items: vm.items)
        XCTAssertEqual(c.groupedForConfirmation.map { $0.0 }, [.compress, .archive(.zip)])
        XCTAssertEqual(c.groupedForConfirmation.flatMap { $0.1 }.count, 2)
        XCTAssertEqual(c.warningRows.count, 2)
        XCTAssertEqual(c.warningRows[0].texts, [reasonText(.gitWorkingTree), reasonText(.largeFile)])
        XCTAssertEqual(c.deniedItems.map(\.id), [3])
        XCTAssertEqual(c.movingCount, 0)
    }

    func test_estimate_texts() async {
        let probe = BlockingArchiveFiles()
        defer { probe.release.signal() }
        let path = Data(URL(fileURLWithPath: #filePath).path.utf8)
        let staged = ReclaimItem(nodeIndex: 1, path: path, recorded: Recorded(fileID: 1, device: 1, isDirectory: false),
            recordedSize: 1_000_000_000, verdict: .ok)
        let vm = ReclaimViewModel(items: [staged], volumes: [1: appleVolume], defaults: nil,
            archiveFiles: probe, archiveSafety: { _, _ in true }, compressionEstimate: { _ in 0 })
        let locale = Locale(identifier: "en_US")
        vm.setAction(.trash, for: 1)
        XCTAssertEqual(vm.estimateText(for: vm.items[0], locale: locale), "1 GB")
        vm.setAction(.compress, for: 1)
        XCTAssertTrue(vm.estimating.contains(1), "estimate runs without blocking review")
        XCTAssertEqual(TrashConfirmation(items: vm.items).movingCount, 1)
        vm.setEstimate(500_000_000, for: 1)
        XCTAssertEqual(vm.estimateText(for: vm.items[0], locale: locale), "Saves about 500 MB (estimated)")
        vm.setAction(.archive(.zip), for: 1)
        probe.release.signal()
        await vm.waitForInspection(1)
        vm.setEstimate(400_000_000, for: 1)
        XCTAssertEqual(vm.estimateText(for: vm.items[0], locale: locale), "Saves about 400 MB once you empty the Trash (estimated)")
        XCTAssertTrue(vm.checking.isEmpty)
    }

    func test_archive_format_choice_persists() throws {
        let suite = "task12-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = ReclaimViewModel(items: [item(1, .ok, 100)], volumes: [1: appleVolume], defaults: defaults)
        XCTAssertEqual(vm.formats(for: vm.items[0], advanced: false), [.appleArchiveFast, .zip, .tarXZ])
        vm.setAction(.archive(.tarZst), for: 1)
        let next = ReclaimViewModel(items: [item(1, .ok, 100)], volumes: [1: appleVolume], defaults: defaults)
        XCTAssertEqual(next.selectedFormat(for: next.items[0]), .tarZst)
        XCTAssertEqual(next.formats(for: next.items[0], advanced: true), [.tarZst, .appleArchiveSmallest])
        let otherVolume = VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat")
        let foreign = ReclaimViewModel(items: [item(1, .ok, 100)], volumes: [1: otherVolume], defaults: defaults)
        XCTAssertEqual(foreign.selectedFormat(for: foreign.items[0]), .zip)
        XCTAssertEqual(foreign.formats(for: foreign.items[0], advanced: false), [.zip, .tarXZ])
        XCTAssertEqual(foreign.formats(for: foreign.items[0], advanced: true), [.tarZst, .appleArchiveFast, .appleArchiveSmallest])
        var restricted = item(2, .ok, 100)
        restricted.archiveFacts.containsRealAppleDouble = true
        let other = ReclaimViewModel(items: [restricted], volumes: [2: appleVolume], defaults: nil)
        XCTAssertEqual(other.availability(.archive(.zip), for: restricted),
            .unavailable("Contains macOS metadata files this format can't store."))
    }

    func test_results_text_per_outcome() {
        var c = CompressOutcome(runID: UUID())
        c.compressed = 2; c.bytesBefore = 100; c.bytesAfter = 120
        XCTAssertTrue(outcomeText(.compressed(c)).contains("saved -20 bytes"))
        c.refusal = "Changed"
        XCTAssertTrue(outcomeText(.compressed(c)).contains("Compressed 2 files"))
        XCTAssertTrue(outcomeText(.compressed(c)).contains("Changed"))
        c.compressed = 0
        XCTAssertTrue(outcomeText(.compressed(c)).contains("Changed"))
        c.refusal = nil; c.cancelled = true
        XCTAssertTrue(outcomeText(.compressed(c)).contains("Cancelled"))
        c.cancelled = false; c.failed = [Data("/fixture".utf8)]
        XCTAssertTrue(outcomeText(.compressed(c)).contains("1"))
        let url = URL(fileURLWithPath: "/fixture/a.zip")
        let cases: [(ArchiveOutcome, String)] = [
            (.archivedAndTrashed(archive: url, bytes: 10, trashURL: url), "Originals moved to Trash"),
            (.archivedOriginalsKept(archive: url, reason: "No Trash"), "No Trash"),
            (.failed("Failed verification", archiveTrashed: nil), "Failed verification")]
        XCTAssertEqual(cases.count, 3)
        for (outcome, text) in cases {
            XCTAssertTrue(outcomeText(.archived(ArchiveRun(outcome: outcome))).contains(text))
        }
    }

    func test_decompress_requires_confirmation_with_file_count() async throws {
        let rows = [CompressManifest.Row(path: Data("/fixture/a".utf8), device: 1, fileID: 2),
                    CompressManifest.Row(path: Data("/fixture/b".utf8), device: 1, fileID: 3)]
        var c = DecompressConfirmation(run: UUID(), rows: rows,
            warnings: [rows[0].path: [.appContainer, .otherHardLinks]])
        XCTAssertEqual(c.fileCount, 2)
        XCTAssertTrue(c.title.contains("2"))
        XCTAssertEqual(c.warningRows.count, 1)
        XCTAssertTrue(c.confirmedPaths.isEmpty)
        XCTAssertEqual(c.allowedPaths, [rows[1].path])
        c.setConfirmed(rows[0].path, true)
        XCTAssertEqual(c.allowedPaths, Set(rows.map(\.path)))

        let world = CompressorTests.World()
        let path = Data("/Users/tester/Library/Containers/com.example/file".utf8)
        world.seed(path)
        let original = try XCTUnwrap(world.files[path])
        world.files[path] = CompressionFile(facts: FileFacts(flags: UInt32(UF_COMPRESSED),
            size: 131072, blocks: 8, key: FileKey(dev: 7, ino: original.recorded.fileID)),
            recorded: original.recorded, allocated: 4096)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/task-12/" + UUID().uuidString)
        let manifests = CompressManifest(directory: directory), run = UUID()
        try manifests.create(run)
        try manifests.append([CompressManifest.Row(path: path, device: 7, fileID: original.recorded.fileID)], run: run)
        let context = GuardContext(scanRoot: Data("/Users/tester".utf8), volumeRoot: Data("/".utf8),
            scanRootDevice: 7, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let engine = Compressor(helper: URL(fileURLWithPath: "/fixture/Contents/Helpers/applesauce"),
            runner: world, files: world, openFiles: world, log: world, manifests: manifests, context: context)
        let loadedReview = await engine.reviewDecompression(run: run)
        var review = try XCTUnwrap(loadedReview)
        XCTAssertEqual(review.fileCount, 1)
        XCTAssertEqual(review.warnings[path], [.appContainer], "current warnings must be reviewed")
        XCTAssertTrue(review.title.contains("1 file?"))
        let refused = await engine.decompress(run: run, reviewed: review)
        XCTAssertEqual(refused.decompressed, 0)
        XCTAssertTrue(world.calls.isEmpty, "an unchecked warning cannot invoke the helper")
        review.setConfirmed(path, true)
        let stale = DecompressConfirmation(run: run,
            rows: [CompressManifest.Row(path: path, device: 7, fileID: 999)], warnings: [:])
        let changed = await engine.decompress(run: run, reviewed: stale)
        XCTAssertNotNil(changed.refusal, "a changed manifest invalidates the frozen review")
        XCTAssertTrue(world.calls.isEmpty)
        let restored = await engine.decompress(run: run, reviewed: review)
        XCTAssertEqual(restored.decompressed, 1)
        XCTAssertEqual(world.calls.count, 1)
        let invocation = try XCTUnwrap(world.calls.first)
        XCTAssertEqual(Array(invocation.prefix(2)), Compressor.decompressFlags)
    }

    func test_review_fix_results_format_bytes_and_signature() {
        var c = CompressOutcome(runID: UUID())
        c.compressed = 2; c.bytesBefore = 50_000_000; c.bytesAfter = 10_000_000
        XCTAssertEqual(c.summary(locale: Locale(identifier: "en_US")), "Compressed 2 files — saved 40 MB")
        c.bytesBefore = 10_000_000; c.bytesAfter = 50_000_000
        XCTAssertEqual(c.summary(locale: Locale(identifier: "en_US")), "Compressed 2 files — saved -40 MB")
        c.isDecompression = true
        XCTAssertEqual(c.summary(locale: Locale(identifier: "en_US")), "Decompressed 2 files — allocation changed by 40 MB")
        c.signatureStatus = 0
        XCTAssertTrue(c.displayResult.contains("App signature check passed."))
        c.signatureStatus = 3
        XCTAssertTrue(c.displayResult.contains("App signature check failed (exit code 3)."))
    }

    func test_review_fix_noop_stage_preserves_ready_pane() {
        var stats = TessScanStats(); stats.root_device = 7
        let tree = TestSnapshot(.dir("/scan/root", [.dir("Projects", [.file("leaf", 100)])]), stats: stats, fileIDs: true)
        let reclaim = Reclaim(), probe = ExecutorTests.Probe(), snapshot = tree.snapshot
        for node in 0..<UInt32(snapshot.nodes.count) {
            probe.entries[snapshot.rawPath(node)] = .ok(Observed(device: 7, flags: 0,
                isDirectory: snapshot.isDirectory(node), linkCount: 1), fileID: snapshot.fileID(node)!, isSymlink: false)
        }
        let context = GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8),
            scanRootDevice: 7, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        reclaim.stage([tree["Projects"]], in: snapshot, context: context, stat: probe)
        XCTAssertEqual(reclaim.items.map(\.id), [tree["Projects"]])
        reclaim.viewModel.replace(reclaim.items, volumes: [tree["Projects"]: appleVolume])
        let frozen = reclaim.viewModel.items
        XCTAssertEqual(frozen[0].actionAvailability, .available)
        XCTAssertFalse(reclaim.viewModel.needsPreparation)
        for node in [tree["Projects"], tree["leaf"]] {
            reclaim.stage([node], in: snapshot, context: context, stat: probe)
            XCTAssertEqual(reclaim.viewModel.items, frozen)
            XCTAssertFalse(reclaim.viewModel.needsPreparation)
            XCTAssertTrue(reclaim.viewModel.checking.isEmpty)
            XCTAssertEqual(reclaim.viewModel.items[0].actionAvailability, .available)
        }
    }

    func test_review_fix_denied_format_shows_reason() {
        var staged = item(1, .ok, 100); staged.action = .archive(.zip)
        staged.archiveFacts.containsRealAppleDouble = true
        let vm = ReclaimViewModel(items: [staged], volumes: [1: appleVolume], defaults: nil)
        XCTAssertNotEqual(vm.items[0].actionAvailability, .available)
        XCTAssertEqual(vm.estimateText(for: vm.items[0]), "Contains macOS metadata files this format can't store.")
        XCTAssertTrue(TrashConfirmation(items: vm.items).groupedForConfirmation.isEmpty)
    }

    func test_review_fix_plural_copy_uses_resolved_language() {
        for (identifier, count) in [("ru_RU", 21), ("fr_FR", 0), ("en_US", 1), ("en_US", 2)] {
            let locale = Locale(identifier: identifier), noun = count == 1 ? "file" : "files"
            XCTAssertEqual(ReclaimCopy.proceeding(count, locale: locale), "\(count) \(count == 1 ? "item" : "items") will proceed")
            var result = CompressOutcome(runID: UUID())
            result.compressed = count
            result.failed = (0..<count).map { Data("/fixture/\($0)".utf8) }
            XCTAssertEqual(result.summary(locale: locale), "Compressed \(count) \(noun) — saved " + displaySize(0, locale: locale))
            result.isDecompression = true
            XCTAssertEqual(result.summary(locale: locale), "Decompressed \(count) \(noun) — allocation changed by " + displaySize(0, locale: locale))
            XCTAssertEqual(ReclaimCopy.failedFiles(count, locale: locale), "\(count) \(noun) failed.")
            if count > 0 { XCTAssertTrue(result.displayResult(locale: locale).contains("\(count) \(noun) failed.")) }
            let rows = (0..<count).map { CompressManifest.Row(path: Data("/fixture/\($0)".utf8), device: 1, fileID: UInt64($0 + 1)) }
            let review = DecompressConfirmation(run: UUID(), rows: rows, warnings: [:])
            XCTAssertEqual(review.fileCount, count)
            XCTAssertEqual(review.title(locale: locale), "Decompress \(count) \(noun)?")
        }
    }

    func test_review_fix_summary_and_trash_destinations() {
        let locale = Locale(identifier: "en_US"), staged = item(1, .ok, 1_000_000_000)
        var a = CompressOutcome(runID: UUID()), b = CompressOutcome(runID: UUID())
        a.compressed = 2; a.bytesBefore = 100_000_000; a.bytesAfter = 50_000_000
        b.compressed = 1; b.bytesBefore = 10_000_000; b.bytesAfter = 20_000_000
        let compressed = ExecutionResult(outcomes: [(staged, .compressed(a)), (staged, .compressed(b))], reclaimableBytes: 0, unknownSizeTrashed: 0)
        XCTAssertFalse(compressed.hasTrashedItems)
        XCTAssertEqual(compressed.summary(locale: locale), "Compressed 3 files — saved 40 MB")
        let url = URL(fileURLWithPath: "/Fixture/Trash/a.aar")
        let archived = Outcome.archived(ArchiveRun(outcome: .archivedAndTrashed(archive: url, bytes: 10, trashURL: url)))
        let result = ExecutionResult(outcomes: [(staged, archived)], reclaimableBytes: 400_000_000, unknownSizeTrashed: 0)
        XCTAssertTrue(result.hasTrashedItems)
        XCTAssertEqual(result.summary(locale: locale), "Saves about 400 MB once you empty the Trash")
        XCTAssertEqual(archived.trashDestination, url)
        let failed = Outcome.archived(ArchiveRun(outcome: .failed("Verification failed.", archiveTrashed: url)))
        XCTAssertEqual(failed.trashDestination, url)
        XCTAssertTrue(outcomeText(failed).contains("Use Put Back to restore it."))
        XCTAssertFalse(outcomeText(failed).contains("Finder"))
        XCTAssertTrue(ExecutionResult(outcomes: [(staged, failed)], reclaimableBytes: 0, unknownSizeTrashed: 0).hasTrashedItems)
        XCTAssertNil(Outcome.archived(ArchiveRun(outcome: .failed("Failed", archiveTrashed: nil))).trashDestination)
        XCTAssertFalse(outcomeText(.archived(ArchiveRun(outcome: .failed("Failed", archiveTrashed: nil)))).contains("Use Put Back"))
    }

    func test_review_fix_history_path_labels_and_native_controls() throws {
        let entry = LogEntry(ts: Date(), action: "compress", path: nil, pathB64: "L2b/", inode: 1, bytes: 0, trashURL: nil, result: "ok")
        XCTAssertEqual(entry.displayPath, "/f\u{fffd} ⟨L2b/⟩")
        let utf8 = LogEntry(ts: Date(), action: "compress", path: "/fixture/file", pathB64: nil, inode: 1, bytes: 0, trashURL: nil, result: "ok")
        XCTAssertEqual(utf8.displayPath, "/fixture/file")
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: apple.appendingPathComponent("Tesserae/ReclaimView.swift"), encoding: .utf8)
        XCTAssertEqual(view.components(separatedBy: "Text(entry.displayPath)").count - 1, 2, "both history lists use the catalogued path label")
        XCTAssertTrue(view.contains("Picker(item.action.title"))
        XCTAssertTrue(view.contains(".pickerStyle(.radioGroup)"))
        XCTAssertTrue(view.contains("@State var advancedExpanded = false"))
        XCTAssertFalse(view.contains("✓"))
        let content = try String(contentsOf: apple.appendingPathComponent("Tesserae/ContentView.swift"), encoding: .utf8)
        let welcome = try XCTUnwrap(content.range(of: "                    welcome"))
        let end = try XCTUnwrap(content.range(of: ".onChange(of: model.session?.id)", range: welcome.upperBound..<content.endIndex))
        XCTAssertFalse(content[welcome.lowerBound..<end.lowerBound].contains("RecentlyCompressedView"))
        XCTAssertEqual(content.components(separatedBy: "RecentlyCompressedView").count - 1, 1, "compression history remains in the session pane")
        let summary = try String(contentsOf: apple.appendingPathComponent("Tesserae/ReclaimSummaryView.swift"), encoding: .utf8)
        XCTAssertTrue(summary.contains("if result.hasTrashedItems"))
        XCTAssertTrue(summary.contains("pair.1.trashDestination"), "discarded archives get Put Back alongside trashed originals")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: apple.appendingPathComponent("Tesserae/Localizable.xcstrings"))) as? [String: Any]
        let strings = try XCTUnwrap(catalog?["strings"] as? [String: [String: Any]])
        for (key, expected) in [("confirmReclaimSheet.execute", "ConfirmReclaimSheet: Apply actions."),
                                ("reclaimSummaryView.results", "ReclaimSummaryView: Reclaim results."),
                                ("reclaimView.ready.to.review", "ReclaimView: Ready to review.")] {
            XCTAssertEqual(strings[key]?["comment"] as? String, expected)
        }
    }

    func test_discarded_archive_put_back_runs_through_current_session() async throws {
        var stats = TessScanStats(); stats.root_device = 1
        let tree = TestSnapshot(.dir("/scan/root", [.file("b", 200), .file("c", 200), .file("d", 200), .file("a", 100)]), stats: stats, fileIDs: true)
        let probe = ArchiverTests.Probe(); probe.status = 3
        let context = GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8),
            scanRootDevice: 1, appBundle: URL(fileURLWithPath: "/app"), home: Data("/home".utf8))
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .granted }, stagingStat: probe, contextLoader: { _ in context })
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session), node = tree["a"]
        XCTAssertEqual(tree.snapshot.fileID(node), probe.recorded.fileID)
        let item = ReclaimItem(nodeIndex: node, path: tree.snapshot.rawPath(node), recorded: probe.recorded,
            recordedSize: 100, verdict: .ok, sessionID: session.id, action: .archive(.zip))
        session.reclaim.publish([item])
        let archiver = Archiver(creator: probe, runner: probe, verifier: probe, files: probe, trasher: probe, log: probe, context: context)
        let executor = Executor(trasher: probe, stat: probe, log: probe, context: context, archiver: archiver)
        let result = await session.execute(using: executor, confirmedWarnings: [], stagingStat: probe)
        guard case .archived(let run) = result.outcomes.first?.1,
              case .failed(_, let discarded?) = run.outcome else { return XCTFail("The writer must fail after creating an archive") }
        let entry = try XCTUnwrap(result.auditEntries.first)
        XCTAssertEqual(entry.trashURL, discarded.absoluteString)
        XCTAssertEqual(entry.path, "/scan/root/a.zip")
        XCTAssertEqual(probe.events.filter { $0 == "write" }.count, 1)
        XCTAssertFalse(session.overlay.isDeleted(node, in: tree.snapshot))
        XCTAssertFalse(session.changedSinceScan)
        XCTAssertTrue(app.canPutBack(entry))
        let mover = RecordingMover(), stat = DiscardRestoreStat(entry: entry, base: probe)
        let restored = await app.putBack(entry, stat: stat, mover: mover, log: probe)
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(mover.calls, 1)
        XCTAssertFalse(session.overlay.isDeleted(node, in: tree.snapshot), "restoring a new archive must not restore/remove its original node")
        XCTAssertEqual(session.source.allocated(node), 100)
        XCTAssertTrue(session.changedSinceScan, "a new archive absent from the snapshot requires a rescan")
        let duplicate = await session.putBack(entry, stat: stat, mover: mover, log: probe)
        XCTAssertNotEqual(duplicate, .restored)
        XCTAssertEqual(mover.calls, 1)
    }

    private var appleVolume: VolumeCapabilities {
        VolumeCapabilities(isLocal: true, isWritable: true, fsType: "apfs")
    }

    func test_noop_unstage_preserves_prepared_actions() {
        let reclaim = Reclaim()
        let staged = item(1, .ok, 100)
        reclaim.publish([staged])
        var reviewed = staged; reviewed.action = .compress
        reclaim.viewModel.replace([reviewed], volumes: [1: appleVolume])
        let frozen = reclaim.viewModel.items
        XCTAssertEqual(frozen.count, 1)
        XCTAssertTrue(reclaim.viewModel.checking.isEmpty)
        reclaim.unstage([])
        XCTAssertEqual(reclaim.viewModel.items, frozen, "a refused batch unstages no nodes and must preserve its review")
        XCTAssertTrue(reclaim.viewModel.checking.isEmpty, "no changed items means no new preparation event")
        reclaim.unstage([999])
        XCTAssertEqual(reclaim.viewModel.items, frozen)
        XCTAssertEqual(reclaim.items.count, 1)
    }

    func test_empty_staging_copy_keeps_byte_summary_for_staged_zero_bytes() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(TrashConfirmation(items: []).total(locale: locale), "Nothing staged")
        let zero = item(1, .ok, 0)
        let confirmation = TrashConfirmation(items: [zero])
        XCTAssertEqual(confirmation.items.count, 1)
        XCTAssertEqual(confirmation.items[0].recordedSize, 0)
        XCTAssertEqual(confirmation.total(locale: locale), "Zero kB staged")
    }

    func test_count_copy_agrees_for_zero_one_and_two() {
        let locale = Locale(identifier: "en_US")
        for count in 0...2 {
            let noun = count == 1 ? "item" : "items"
            let items = (0..<count).map { item(UInt32($0), .ok, nil) }
            XCTAssertEqual(ReclaimCopy.staged(count), "\(count) staged \(noun)")
            XCTAssertEqual(ReclaimCopy.moving(count), "\(count) \(noun) will move")
            XCTAssertEqual(ReclaimCopy.processed(count, count), "\(count) of \(count) \(noun) processed")
            XCTAssertEqual(ReclaimCopy.rescan(count), "Sizes include \(count) trashed \(noun); rescan for exact figures")
            XCTAssertEqual(TrashConfirmation(items: items).total(locale: locale),
                (count == 0 ? "Nothing staged" : "Zero kB staged · \(count) \(noun) of unknown size"))
            XCTAssertEqual(trashSummaryText(ExecutionResult(outcomes: [], reclaimableBytes: 0, unknownSizeTrashed: count), locale: locale),
                "Zero kB moved to Trash — empty Trash to reclaim it" + (count == 0 ? "" : " (plus \(count) \(noun) of unknown size)"))
        }
    }

    func test_history_load_is_off_main_and_stale_completion_is_ignored() async throws {
        let probe = HistoryProbe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-unused-" + UUID().uuidString)
        let ui = ReclaimPresentation(log: ReclaimLog(directory: directory), historyLoader: { probe.load() })
        XCTAssertTrue(probe.started.wait(timeout: .now() + 3) == .success, "launch starts a load")
        let old = ui.historyTask
        await ui.refresh().value
        XCTAssertEqual(ui.history.map(\.inode), [2])
        probe.release.signal()
        await old?.value
        XCTAssertEqual(ui.history.map(\.inode), [2], "older completion must not replace the latest history")
        XCTAssertEqual(probe.mainCalls, 0)
        XCTAssertEqual(probe.calls, 2)
    }

    func test_every_reason_has_one_plain_sentence() {
        let cases: [(Reason, String)] = [
            (.nonCanonicalPath, "This path cannot be identified safely."),
            (.osIntegrity, "This item is part of macOS."),
            (.systemState, "macOS uses this item to keep the system running."),
            (.appTemporaryFiles, "Running apps use these temporary files."),
            (.systemManaged, "macOS manages this item."),
            (.timeMachineBackup, "Time Machine manages this backup."),
            (.userAccountCore, "This item is essential to your user account."),
            (.volumeRootOrTopLevel, "This item is the volume root or a top-level folder."),
            (.otherVolume, "This item is on a different volume from the scan."),
            (.selfOrAncestorOfApp, "This item contains the running Tesserae app."),
            (.alreadyInTrash, "Already in the Trash — empty it from Finder."),
            (.restricted, "macOS System Integrity Protection protects this item."),
            (.immutable, "This item is locked against changes."),
            (.symlinkInPath, "This path contains a symbolic link and cannot be trashed safely."),
            (.appContainer, "Removing an app's container resets that app, including documents of sandboxed apps."),
            (.cloudOnly, "Cloud-only: trashing removes it from iCloud on all your devices and frees no space on this Mac."),
            (.otherHardLinks, "Other hard links point to this file; its space is freed only when every link is gone."),
            (.changedSinceScan, "This item changed since the scan; rescan before staging it."),
            (.noRecordedIdentity, "The scan could not record this item's identity."),
            (.containsUnknownSize, "This folder contains unreadable or skipped content; its size is only the known part."),
            (.containsCloudOnly, "This folder contains cloud-only items. Trashing removes them from iCloud on all your devices."),
            (.containsHardLinks, "This folder contains hard links; space is freed only when every link is gone.")]
        XCTAssertEqual(cases.count, 22)
        for (reason, expected) in cases { XCTAssertEqual(reasonText(reason), expected) }
    }

    func test_totals_confirmation_and_summary() {
        let items = [item(0, .ok, 1_000_000_000), item(1, .warn(.cloudOnly), nil),
                     item(2, .warn(.appContainer), 2_000_000_000), item(3, .denied(.restricted), nil)]
        var confirmation = TrashConfirmation(items: items)
        XCTAssertEqual(confirmation.items.count, 4)
        XCTAssertTrue(confirmation.confirmedWarnings.isEmpty)
        XCTAssertEqual(confirmation.warningItems.map(\.id), [1, 2])
        XCTAssertEqual(confirmation.deniedItems.map(\.id), [3])
        XCTAssertEqual(confirmation.total(locale: Locale(identifier: "en_US")), "3 GB staged · 1 item of unknown size")
        confirmation.setConfirmed(1, true)
        confirmation.setConfirmed(3, true)
        XCTAssertEqual(confirmation.confirmedWarnings, [1])
        XCTAssertEqual(confirmation.movingCount, 2)
        confirmation.setConfirmed(1, false)
        XCTAssertTrue(confirmation.confirmedWarnings.isEmpty)
        let result = ExecutionResult(outcomes: [], reclaimableBytes: 1_000_000_000, unknownSizeTrashed: 2)
        XCTAssertEqual(trashSummaryText(result, locale: Locale(identifier: "en_US")),
                       "1 GB moved to Trash — empty Trash to reclaim it (plus 2 items of unknown size)")
        XCTAssertEqual(trashSummaryText(ExecutionResult(outcomes: [], reclaimableBytes: 0, unknownSizeTrashed: 0),
                                       locale: Locale(identifier: "en_US")), "Zero kB moved to Trash — empty Trash to reclaim it")
    }

    func test_every_outcome_and_identity_and_put_back_wording() {
        let cases: [(Outcome, String)] = [
            (.trashed(trashURL: URL(fileURLWithPath: "/Fixture/Trash/a")), "Moved to Trash."),
            (.skipped(.immutable), "Skipped: This item is locked against changes."),
            (.notConfirmed(.appContainer), "Not confirmed: " + reasonText(.appContainer)),
            (.failed(errno: 5, message: "Disk unavailable"), "Failed: Disk unavailable (errno 5).")]
        XCTAssertEqual(cases.count, 4)
        for (outcome, text) in cases { XCTAssertEqual(outcomeText(outcome), text) }
        let identities: [(IdentityResult, String)] = [(.same, "Identity could not be verified."),
            (.gone, "This item no longer exists."), (.inodeChanged, "A different item now occupies this path."),
            (.deviceChanged, "This item's volume changed."), (.nowSymlink, "This item is now a symbolic link."),
            (.typeChanged, "This item's file type changed."),
            (.symlinkInPath(Data("/Fixture/link".utf8)), "This path now contains a symbolic link."),
            (.unreadable(errno: 13), "This item's identity could not be read (errno 13).")]
        XCTAssertEqual(identities.count, 8)
        for (identity, text) in identities { XCTAssertEqual(outcomeText(.identityChanged(identity)), "Skipped: " + text) }
        let restores: [(PutBackResult, String)] = [(.restored, "Put back in its original location."),
            (.trashItemGone, "This item is no longer in the Trash."), (.trashItemChanged, "The item in the Trash has changed."),
            (.originalOccupied, "The original location is occupied; nothing was overwritten."),
            (.parentMissing, "The original parent folder is missing."), (.failed("Offline"), "Put Back failed: Offline")]
        XCTAssertEqual(restores.count, 6)
        for (result, text) in restores { XCTAssertEqual(putBackText(result), text) }
    }

    func test_open_trash_only_opens_exact_home_trash_and_sources_never_empty_it() throws {
        var received: [URL] = []
        openTrash { received.append($0); return true }
        XCTAssertEqual(received, [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")])
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: apple.appendingPathComponent("Tesserae/ConfirmReclaimSheet.swift"), encoding: .utf8)
        XCTAssertNotNil(sheet.range(of: #"Button\(String\(\s*localized: "confirmTrashSheet.cancel",\s*defaultValue: "Cancel""#,
                                    options: .regularExpression))
        XCTAssertTrue(sheet.contains("role: .cancel, action: cancel).keyboardShortcut(.defaultAction)"))
        XCTAssertEqual(sheet.components(separatedBy: ".defaultAction").count - 1, 1)
        XCTAssertTrue(sheet.contains(".interactiveDismissDisabled()"))
        var count = 0
        for folder in ["Tesserae", "TesseraeKit"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: apple.appendingPathComponent(folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                for forbidden in ["NSAppleScript", "emptyTrash", "empty trash", "kAEEmptyTrash"] {
                    XCTAssertFalse(source.contains(forbidden), url.lastPathComponent + ": " + forbidden)
                }
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 40)
    }

    func test_native_context_menu_stages_only_and_selects_clicked_tile_without_navigation() throws {
        let commands = ReclaimContextMenu()
        let disabled = commands.make()
        XCTAssertEqual(disabled.items.count, 1)
        XCTAssertFalse(disabled.items[0].isEnabled)
        var calls = 0
        commands.stage = { calls += 1 }
        let menu = commands.make()
        XCTAssertEqual(menu.items[0].title, "Add to Reclaim Space")
        XCTAssertEqual(menu.items[0].keyEquivalent, "\u{8}")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, .command)
        XCTAssertTrue(menu.items[0].isEnabled)
        _ = NSApplication.shared
        menu.performActionForItem(at: 0)
        XCTAssertEqual(calls, 1)
        let interaction = TreemapInteraction()
        let selection = Selection(nodes: [1, 2])
        interaction.selection = selection
        _ = interaction.setTiles([
            Tile(rect: CGRect(x: 0, y: 0, width: 20, height: 20), node: 1, depth: 0),
            Tile(rect: CGRect(x: 20, y: 0, width: 20, height: 20), node: 3, depth: 0)])
        XCTAssertTrue(interaction.selectForContext(at: CGPoint(x: 10, y: 10)))
        XCTAssertEqual(selection.nodes, [1, 2], "right-click within a multi-selection keeps it")
        XCTAssertTrue(interaction.selectForContext(at: CGPoint(x: 30, y: 10)))
        XCTAssertEqual(selection.nodes, [3])
        XCTAssertFalse(interaction.selectForContext(at: CGPoint(x: 100, y: 100)))
        XCTAssertNil(interaction.pendingZoom)
    }

    func test_presentation_executes_updates_progress_and_overlay_and_restores_with_failed_log() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reclaim-ui-" + UUID().uuidString)
        try Data("blocked log directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = ReclaimLog(directory: directory)
        let ui = ReclaimPresentation(log: log)
        var stats = TessScanStats(); stats.root_device = 7
        let tree = TestSnapshot(.dir("/scan/root", [.file("a", 100), .file("b", 50)]), stats: stats, fileIDs: true)
        let p = ExecutorTests.Probe()
        for n in 0..<UInt32(tree.snapshot.nodes.count) {
            p.entries[tree.snapshot.rawPath(n)] = .ok(Observed(device: 7, flags: 0,
                isDirectory: tree.snapshot.isDirectory(n), linkCount: 1), fileID: tree.snapshot.fileID(n)!, isSymlink: false)
        }
        let context = GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8),
            scanRootDevice: 7, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .granted }, stagingStat: p, contextLoader: { _ in context })
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session)
        session.selection.nodes = [tree["a"], tree["b"]]
        let warningPath = tree.snapshot.rawPath(tree["b"])
        p.entries[warningPath] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS), isDirectory: false, linkCount: 1),
            fileID: tree.snapshot.fileID(tree["b"])!, isSymlink: false)
        app.stageSelection(); await app.waitForStaging()
        XCTAssertEqual(session.reclaim.items.count, 2)
        XCTAssertTrue(p.trashPaths.isEmpty, "staging never trashes")
        ui.prepare(session.reclaim.items)
        XCTAssertTrue(ui.showingConfirmation)
        XCTAssertEqual(ui.confirmation.warningItems.map(\.id), [tree["b"]])
        p.entries[warningPath] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1),
            fileID: tree.snapshot.fileID(tree["b"])!, isSymlink: false)
        await ui.execute(app, trasher: p, stat: p)
        XCTAssertEqual(ui.done, 2)
        XCTAssertFalse(ui.running)
        XCTAssertFalse(ui.showingConfirmation)
        XCTAssertEqual(ui.result?.outcomes.count, 2)
        XCTAssertEqual(session.overlay.deleted.count, 1)
        XCTAssertEqual(session.reclaim.items.map(\.id), [tree["b"]])
        XCTAssertEqual(ui.result?.outcomes.last?.1, .notConfirmed(.cloudOnly))
        await ui.historyTask?.value
        XCTAssertTrue(ui.logFailed)
        XCTAssertTrue(ui.history.isEmpty)
        XCTAssertEqual(ui.resultEntries.count, 1, "Put Back remains available after a log failure")
        XCTAssertEqual(session.banner, ReclaimCopy.rescan(1))
        let entry = try XCTUnwrap(ui.resultEntries.first)
        let trash = try XCTUnwrap(URL(string: try XCTUnwrap(entry.trashURL)))
        p.entries[Data(trash.path.utf8)] = .ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1),
            fileID: entry.inode, isSymlink: false)
        p.entries[Data(try XCTUnwrap(entry.path).utf8)] = .error(errno: ENOENT)
        let mover = RecordingMover()
        await ui.restore(entry, model: app, stat: p, mover: mover)
        XCTAssertEqual(mover.calls, 1)
        XCTAssertEqual(session.overlay.deleted.count, 0)
        XCTAssertEqual(ui.resultEntries.count, 0)
        XCTAssertEqual(ui.messages[entry.trashURL!], "Put back in its original location.")
    }

    private struct DiscardRestoreStat: FileStat {
        let entry: LogEntry
        let base: ArchiverTests.Probe
        func volumeUUID(_ path: Data) -> String? { base.volumeUUID(path) }
        func lstat(_ path: Data) -> StatResult {
            if path == Data((entry.path ?? "").utf8) { return .error(errno: ENOENT) }
            if path == Data(URL(string: entry.trashURL!)!.path.utf8) {
                return .ok(Observed(device: entry.device!, flags: 0, isDirectory: entry.isDirectory!, linkCount: 1),
                    fileID: entry.inode, isSymlink: false)
            }
            return base.lstat(path)
        }
    }

    private final class RecordingMover: Mover, @unchecked Sendable {
        var calls = 0
        func move(_ from: URL, to: URL) throws { calls += 1 }
    }

    private func item(_ id: UInt32, _ verdict: Verdict, _ size: UInt64?) -> ReclaimItem {
        ReclaimItem(nodeIndex: id, path: Data("/Fixture/item-\(id)".utf8),
            recorded: Recorded(fileID: UInt64(id) + 1, device: 1, isDirectory: false), recordedSize: size, verdict: verdict)
    }
}

private final class HistoryProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var mainCalls = 0
    func load() -> [LogEntry] {
        lock.lock()
        calls += 1
        let number = calls
        if Thread.isMainThread { mainCalls += 1 }
        lock.unlock()
        if number == 1 {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        return [LogEntry(ts: Date(), action: "trash", path: "/fixture/entry", pathB64: nil,
            inode: UInt64(number), bytes: 1, trashURL: "file:///fixture/Trash/entry", result: "ok")]
    }
}

private final class BlockingArchiveFiles: ArchiveFileSystem, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let laterRelease = DispatchSemaphore(value: 0)
    var facts = ArchiveItemFacts()
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func inspect(_ path: Data) throws -> ArchiveInspection {
        let call = lock.withLock { count += 1; return count }
        started.signal()
        if call == 2 { laterRelease.wait() } else { release.wait() }
        return ArchiveInspection(facts: facts, files: [], stamps: [:])
    }
    func lstat(_ path: Data) -> StatResult { .error(errno: ENOENT) }
    func volumeUUID(_ path: Data) -> String? { nil }
    func freeSpace(_ path: Data) -> UInt64? { nil }
    func readArchive(_ path: Data, matching fd: Int32) throws -> Int32 { throw archiveError(EIO) }
    func archiveStamp(_ fd: Int32) throws -> ArchiveStamp { throw archiveError(EIO) }
    func usage(_ fd: Int32) throws -> (allocated: UInt64, logical: UInt64) { throw archiveError(EIO) }
    func digest(_ fd: Int32) throws -> String { throw archiveError(EIO) }
    func syncParent(_ path: Data, recorded: Recorded) throws { throw archiveError(EIO) }
}

private final class VolumeProbe: @unchecked Sendable {
    let result: VolumeCapabilities
    init(result: VolumeCapabilities = VolumeCapabilities(isLocal: true, isWritable: true, fsType: "apfs")) { self.result = result }
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func load(_ path: Data) -> VolumeCapabilities {
        lock.withLock { count += 1 }
        return result
    }
}

private final class CountingEstimator: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0, cancellations = 0
    var calls: Int { lock.withLock { count } }
    var cancelled: Int { lock.withLock { cancellations } }
    func estimate() -> UInt64 {
        lock.withLock { count += 1 }
        started.signal()
        let deadline = Date().addingTimeInterval(3)
        while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        if Task.isCancelled { lock.withLock { cancellations += 1 } }
        return 256
    }
}
