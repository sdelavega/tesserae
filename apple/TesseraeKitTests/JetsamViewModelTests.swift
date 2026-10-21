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
final class JetsamViewModelTests: XCTestCase {
    func test_count_copy_agrees_for_zero_one_and_two() {
        let locale = Locale(identifier: "en_US")
        for count in 0...2 {
            let noun = count == 1 ? "item" : "items"
            let items = (0..<count).map { item(UInt32($0), .ok, nil) }
            XCTAssertEqual(JetsamCopy.staged(count), "\(count) staged \(noun)")
            XCTAssertEqual(JetsamCopy.moving(count), "\(count) \(noun) will move")
            XCTAssertEqual(JetsamCopy.processed(count, count), "\(count) of \(count) \(noun) processed")
            XCTAssertEqual(JetsamCopy.rescan(count), "Sizes include \(count) trashed \(noun); rescan for exact figures")
            XCTAssertEqual(TrashConfirmation(items: items).total(locale: locale),
                "Zero kB staged" + (count == 0 ? "" : " · \(count) \(noun) of unknown size"))
            XCTAssertEqual(trashSummaryText(ExecutionResult(outcomes: [], reclaimableBytes: 0, unknownSizeTrashed: count), locale: locale),
                "Zero kB moved to Trash — empty Trash to reclaim it" + (count == 0 ? "" : " (plus \(count) \(noun) of unknown size)"))
        }
    }

    func test_history_load_is_off_main_and_stale_completion_is_ignored() async throws {
        let probe = HistoryProbe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-unused-" + UUID().uuidString)
        let ui = JetsamPresentation(log: JettisonLog(directory: directory), historyLoader: { probe.load() })
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
        let sheet = try String(contentsOf: apple.appendingPathComponent("Tesserae/ConfirmTrashSheet.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("Button(\"Cancel\", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)"))
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
        let commands = JetsamContextMenu()
        let disabled = commands.make()
        XCTAssertEqual(disabled.items.count, 1)
        XCTAssertFalse(disabled.items[0].isEnabled)
        var calls = 0
        commands.stage = { calls += 1 }
        let menu = commands.make()
        XCTAssertEqual(menu.items[0].title, "Add to Jetsam")
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jetsam-ui-" + UUID().uuidString)
        try Data("blocked log directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = JettisonLog(directory: directory)
        let ui = JetsamPresentation(log: log)
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
        XCTAssertEqual(session.jetsam.items.count, 2)
        XCTAssertTrue(p.trashPaths.isEmpty, "staging never trashes")
        ui.prepare(session.jetsam.items)
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
        XCTAssertEqual(session.jetsam.items.map(\.id), [tree["b"]])
        XCTAssertEqual(ui.result?.outcomes.last?.1, .notConfirmed(.cloudOnly))
        await ui.historyTask?.value
        XCTAssertTrue(ui.logFailed)
        XCTAssertTrue(ui.history.isEmpty)
        XCTAssertEqual(ui.resultEntries.count, 1, "Put Back remains available after a log failure")
        XCTAssertEqual(session.banner, JetsamCopy.rescan(1))
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

    private final class RecordingMover: Mover, @unchecked Sendable {
        var calls = 0
        func move(_ from: URL, to: URL) throws { calls += 1 }
    }

    private func item(_ id: UInt32, _ verdict: Verdict, _ size: UInt64?) -> JetsamItem {
        JetsamItem(nodeIndex: id, path: Data("/Fixture/item-\(id)".utf8),
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
