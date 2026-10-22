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

final class ArchiverTests: XCTestCase, @unchecked Sendable {
    final class Probe: ArchiveFileSystem, ExclusiveCreator, ArchiveRunner, ArchiveVerifier, Trasher, AuditSink, @unchecked Sendable {
        var events: [String] = [], logs: [LogEntry] = []
        var status: Int32 = 0, verdict = ArchiveVerdict(files: 1, bytes: 100)
        var free: UInt64? = UInt64.max
        var changed = false, tamperArchive = false, failTrash = false, afterVerify = false
        var unsafeParent = false, makeParentUnsafeOnInspect = false
        var originalCalls = 0
        var syncError: Int32?
        func syncParent(_ path: Data, recorded: Recorded) throws {
            events.append("syncParent")
            if let syncError { throw archiveError(syncError) }
        }
        var directory = false, facts = ArchiveItemFacts(eligibleBytes: 100)
        var recorded: Recorded { Recorded(fileID: 5, device: 1, isDirectory: directory) }
        func lstat(_ path: Data) -> StatResult {
            .ok(Observed(device: 1, flags: 0, isDirectory: path != Data("/scan/root/a".utf8) || directory, linkCount: 1, permissions: unsafeParent && path == Data("/scan/root".utf8) ? 0o777 : 0o755),
                fileID: path == Data("/scan/root/a".utf8) ? 5 : 2, isSymlink: false)
        }
        func volumeUUID(_ path: Data) -> String? { "fixture" }
        func inspect(_ path: Data) throws -> ArchiveInspection {
            events.append("inspect")
            if makeParentUnsafeOnInspect { unsafeParent = true }
            return ArchiveInspection(facts: facts, files: [(path, 100)],
                stamps: [path: ArchiveStamp(recorded: recorded, size: changed ? 101 : 100)])
        }
        func freeSpace(_ path: Data) -> UInt64? { free }
        func readArchive(_ path: Data, matching fd: Int32) throws -> Int32 { open("/dev/null", O_RDONLY) }
        func archiveStamp(_ fd: Int32) throws -> ArchiveStamp {
            ArchiveStamp(recorded: recorded, size: tamperArchive && events.contains("verify") ? 21 : 20)
        }
        func usage(_ fd: Int32) throws -> (allocated: UInt64, logical: UInt64) { (32, 20) }
        func digest(_ fd: Int32) throws -> String { String(repeating: "a", count: 64) }
        func create(parent: Data, parentRecorded: Recorded, baseName: Data, ext: String) throws -> (fd: Int32, name: Data) {
            events.append("create"); return (open("/dev/null", O_WRONLY), baseName + Data(("." + ext).utf8))
        }
        func run(item: Data, format: ArchiveFormat, to fd: Int32) async -> Int32 { events.append("write"); return status }
        func verify(fd: Int32, path: Data, format: ArchiveFormat, item: Data) -> ArchiveVerdict {
            events.append("verify"); if afterVerify { changed = true }; return verdict
        }
        func trash(_ url: URL) throws -> URL {
            events.append("discard")
            if failTrash { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            return URL(fileURLWithPath: "/fake-trash/partial")
        }
        func append(_ entry: LogEntry) -> Bool { logs.append(entry); return true }
        func original() async -> Outcome {
            events.append("original"); originalCalls += 1
            if failTrash { return .failed(errno: ENOTSUP, message: "no Trash") }
            return .trashed(trashURL: URL(fileURLWithPath: "/fake-trash/a"))
        }
    }
    func item(_ p: Probe) -> ReclaimItem {
        ReclaimItem(nodeIndex: 1, path: Data("/scan/root/a".utf8), recorded: p.recorded,
            recordedSize: 100, verdict: .ok, action: .archive(.zip))
    }
    func engine(_ p: Probe) -> Archiver {
        Archiver(creator: p, runner: p, verifier: p, files: p, trasher: p, log: p,
            context: GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8), scanRootDevice: 1, appBundle: URL(fileURLWithPath: "/app"), home: Data("/home".utf8)))
    }
    func test_archive_refuses_unsafe_ancestry_at_start_and_after_inspection() async throws {
        for becomesUnsafeLater in [false, true] {
            let probe = Probe()
            probe.unsafeParent = !becomesUnsafeLater
            probe.makeParentUnsafeOnInspect = becomesUnsafeLater
            let worker = engine(probe)
            let result = await worker.archive(item(probe), format: .zip, trashOriginal: probe.original)
            guard case .failed(let reason, _) = result else { return XCTFail("unsafe archive accepted") }
            XCTAssertEqual(reason, "Another user can change files in this folder, so Tesserae can't safely compress or archive here.")
            XCTAssertFalse(probe.events.contains("create"))
            XCTAssertFalse(probe.events.contains("write"))
            XCTAssertEqual(probe.originalCalls, 0)
            XCTAssertEqual(probe.events.contains("inspect"), becomesUnsafeLater, "precondition: intended boundary reached")
        }
    }

    func test_archive_inspection_records_raw_symlink_target() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let file = try f.file("file"), raw = Data(file.deletingLastPathComponent().appendingPathComponent("link").path.utf8)
        let target = Data([102, 255, 10])
        XCTAssertEqual(archiveCString(target) { target in archiveCString(raw) { symlink(target, $0) } }, 0)
        let tree = try ProductionArchiveFileSystem().inspect(Data(file.deletingLastPathComponent().path.utf8))
        let stamp = try XCTUnwrap(tree.stamps[raw])
        XCTAssertEqual(stamp.mode & S_IFMT, UInt16(S_IFLNK))
        XCTAssertEqual(stamp.linkTarget, target)
        var retargeted = stamp; retargeted.linkTarget = Data([102, 254, 10])
        XCTAssertNotEqual(stamp, retargeted, "archive validation compares the target as well as identity and timestamps")
    }

    @MainActor
    func test_snapshot_archive_symlink_and_late_changes() async throws {
        for change in 0..<4 {
            let f = DiskImageFixture(); try f.setUp(size: "2g")
            defer { XCTAssertNoThrow(try f.tearDown()) }
            let file = try f.file("file"), folder = file.deletingLastPathComponent()
            let linkURL = folder.appendingPathComponent("link")
            XCTAssertEqual(symlink("file", linkURL.path), 0)
            let (snapshot, ctx) = try await archiveSnapshot(f, root: folder.deletingLastPathComponent())
            let node = try XCTUnwrap((0..<UInt32(snapshot.nodes.count)).first { snapshot.rawPath($0) == Data(folder.path.utf8) })
            let staged = Reclaim.prepare([node], in: snapshot, context: ctx, stat: ProductionFileStat(), overlay: SizeOverlay(), existing: [])
            XCTAssertEqual(staged.count, 1); XCTAssertEqual(staged[0].descendants.count, 2)
            XCTAssertFalse(itemWarnings(staged[0]).contains(.containsUnknownSize))
            let vm = ReclaimViewModel(defaults: nil)
            vm.prepare(staged, context: ctx)
            try await waitForArchiveReview(vm)
            vm.setAction(.archive(.appleArchiveFast), for: node)
            try await waitForArchiveReview(vm)
            let review = TrashConfirmation(items: vm.items)
            XCTAssertEqual(review.movingCount, 1); XCTAssertTrue(review.warningRows.isEmpty)
            let verifier = ChangingVerifier(folder: folder, change: change)
            let trasher = ArchiveTrashProbe(root: f.root)
            let log = ReclaimLog(directory: f.root.appendingPathComponent("audit"))
            let archive = Archiver(verifier: verifier, trasher: trasher, log: log, context: ctx)
            let result = await Executor(trasher: trasher, stat: ProductionFileStat(), log: log, context: ctx, archiver: archive)
                .run(review.items, confirmedWarnings: review.confirmedWarnings,
                     reviewedVerdicts: Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, $0.verdict) }),
                     reviewedWarnings: Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, Set(itemWarnings($0))) }))
            XCTAssertEqual(verifier.calls, 1, "real archive verification must run")
            guard case .archived(let run) = result.outcomes.first?.1 else { return XCTFail("Archive must dispatch") }
            if change == 0 {
                guard case .archivedAndTrashed = run.outcome else { return XCTFail("Unchanged staged symlink must archive: \(run.outcome)") }
                XCTAssertTrue(trasher.paths.contains(Data(folder.path.utf8)))
            } else {
                guard case .failed(_, let discarded) = run.outcome else { return XCTFail("Late content change must refuse") }
                XCTAssertNotNil(discarded)
                XCTAssertFalse(trasher.paths.contains(Data(folder.path.utf8)))
                XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
            }
        }
    }

    @MainActor
    func test_archive_preparation_exposes_external_hardlink_unchecked() async throws {
        let f = DiskImageFixture(); try f.setUp(size: "2g"); defer { XCTAssertNoThrow(try f.tearDown()) }
        let file = try f.file("file"), folder = file.deletingLastPathComponent()
        XCTAssertEqual(link(file.path, f.root.appendingPathComponent("outside-scan").path), 0)
        let (snapshot, ctx) = try await archiveSnapshot(f, root: folder.deletingLastPathComponent())
        let node = try XCTUnwrap((0..<UInt32(snapshot.nodes.count)).first { snapshot.rawPath($0) == Data(folder.path.utf8) })
        let staged = Reclaim.prepare([node], in: snapshot, context: ctx, stat: ProductionFileStat(), overlay: SizeOverlay(), existing: [])
        XCTAssertEqual(staged[0].descendants.count, 1)
        XCTAssertFalse(itemWarnings(staged[0]).contains(.containsHardLinks), "second name is outside scan")
        let inspection = try ProductionArchiveFileSystem().inspect(Data(folder.path.utf8))
        XCTAssertTrue(inspection.stamps.values.contains { $0.links > 1 && $0.mode & S_IFMT == S_IFREG })
        let vm = ReclaimViewModel(defaults: nil)
        vm.prepare(staged, context: ctx); try await waitForArchiveReview(vm)
        vm.setAction(.archive(.appleArchiveFast), for: node); try await waitForArchiveReview(vm)
        var review = TrashConfirmation(items: vm.items)
        XCTAssertEqual(review.warningRows.count, 1)
        XCTAssertTrue(itemWarnings(review.items[0]).contains(.containsHardLinks))
        XCTAssertEqual(review.movingCount, 0); XCTAssertTrue(review.confirmedWarnings.isEmpty)
        review.setConfirmed(node, true); XCTAssertEqual(review.movingCount, 1)
        let log = ReclaimLog(directory: f.root.appendingPathComponent("audit"))
        let result = await Executor(trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()),
            stat: ProductionFileStat(), log: log, context: ctx).run(review.items, confirmedWarnings: review.confirmedWarnings,
                reviewedWarnings: [node: Set(itemWarnings(review.items[0]))])
        guard case .archived(let run) = result.outcomes.first?.1, case .archivedAndTrashed = run.outcome else {
            return XCTFail("Acknowledged external hard link must archive: \(result.outcomes)")
        }
        XCTAssertEqual(result.reclaimableBytes, 0, "other hard-link name retains allocation")
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent("outside-scan")), Data("fixture".utf8))
    }

    @MainActor
    private func archiveSnapshot(_ f: DiskImageFixture, root: URL) async throws -> (Snapshot, GuardContext) {
        let scanner = ScanCoordinator(); scanner.start(root: root)
        for _ in 0..<3000 {
            if scanner.state == .finished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(scanner.state, .finished)
        let snapshot = try XCTUnwrap(scanner.snapshot)
        return (snapshot, GuardContext(scanRoot: Data(root.path.utf8), volumeRoot: Data(f.root.path.utf8),
            scanRootDevice: snapshot.rootDevice, appBundle: URL(fileURLWithPath: "/app"), home: Data("/home".utf8)))
    }
    @MainActor
    private func waitForArchiveReview(_ vm: ReclaimViewModel) async throws {
        for _ in 0..<3000 {
            if !vm.preparing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(vm.preparing)
    }

    private final class ArchiveTrashProbe: Trasher, @unchecked Sendable {
        let root: URL
        var paths: [Data] = []
        init(root: URL) { self.root = root }
        func trash(_ url: URL) throws -> URL {
            paths.append(Data(url.path.utf8))
            return try ContainedTrasher(fixtureRoot: root, inner: ProductionTrasher()).trash(url)
        }
    }
    private final class ChangingVerifier: ArchiveVerifier, @unchecked Sendable {
        let folder: URL, change: Int
        var calls = 0
        init(folder: URL, change: Int) { self.folder = folder; self.change = change }
        func verify(fd: Int32, path: Data, format: ArchiveFormat, item: Data) -> ArchiveVerdict {
            calls += 1
            let result = ProductionArchiveVerifier().verify(fd: fd, path: path, format: format, item: item)
            XCTAssertEqual(result.code, 0)
            do {
                let linkURL = folder.appendingPathComponent("link"), file = folder.appendingPathComponent("file")
                if change == 1 {
                    try FileManager.default.moveItem(at: linkURL, to: folder.appendingPathComponent("old-link"))
                    XCTAssertEqual(symlink("elsewhere", linkURL.path), 0)
                } else if change == 2 {
                    try FileManager.default.moveItem(at: linkURL, to: folder.appendingPathComponent("old-link"))
                    XCTAssertEqual(symlink("file", linkURL.path), 0)
                } else if change == 3 {
                    try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent("old-file"))
                    XCTAssertEqual(symlink("old-file", file.path), 0)
                }
            } catch { XCTFail("Mutation must succeed: \(error)") }
            return result
        }
    }

    func test_sidecar_item_refuses_before_creating_archive_or_trashing() async {
        for format in ArchiveFormat.allCases {
            let p = Probe(); p.facts.isSidecar = true
            let result = await engine(p).archive(item(p), format: format, estimatedBytes: 100, trashOriginal: { await p.original() })
            guard case .failed(let reason, let discarded) = result else { return XCTFail("Sidecar must be refused") }
            XCTAssertEqual(reason, "This item is a macOS metadata sidecar. Archive its sibling instead.")
            XCTAssertNil(discarded); XCTAssertEqual(p.originalCalls, 0)
            XCTAssertTrue(p.events.contains("inspect")); XCTAssertFalse(p.events.contains("create"))
            XCTAssertFalse(p.events.contains("write")); XCTAssertFalse(p.events.contains("verify"))
        }
    }
    func test_tar_failure_trashes_partial_and_keeps_originals() async {
        let p = Probe(); p.status = 3
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(_, let discarded) = result else { return XCTFail("Expected failure") }
        XCTAssertNotNil(discarded); XCTAssertEqual(p.originalCalls, 0)
        XCTAssertEqual(p.events.filter { $0 != "inspect" }, ["create", "write", "discard"])
    }
    func test_verify_failure_trashes_archive_and_keeps_originals() async {
        let p = Probe(); p.verdict = ArchiveVerdict(code: 4, firstBadPath: Data("a".utf8))
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(_, let discarded) = result else { return XCTFail("Expected verification failure") }
        XCTAssertNotNil(discarded); XCTAssertEqual(p.originalCalls, 0); XCTAssertTrue(p.events.contains("verify"))
        XCTAssertEqual(p.logs.last?.archive?.archiveBytes, 20)
    }
    func test_change_between_archive_and_trash_is_refused() async {
        let p = Probe(); p.afterVerify = true
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(_, let discarded) = result else { return XCTFail("Late change must refuse") }
        XCTAssertNotNil(discarded); XCTAssertEqual(p.originalCalls, 0)
    }
    func test_identity_refusal_after_verification_discards_archive() async {
        let p = Probe()
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { .identityChanged(.inodeChanged) })
        guard case .failed(_, let discarded) = result else { return XCTFail("Identity change must refuse") }
        XCTAssertNotNil(discarded); XCTAssertTrue(p.events.contains("verify"))
    }
    func test_archive_changed_after_verification_keeps_originals() async {
        let p = Probe(); p.tamperArchive = true
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(_, let discarded) = result else { return XCTFail("Changed archive must fail") }
        XCTAssertNotNil(discarded); XCTAssertEqual(p.originalCalls, 0); XCTAssertTrue(p.events.contains("verify"))
    }
    func test_no_trash_keeps_archive_and_originals_with_message() async {
        let p = Probe(); p.failTrash = true
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .archivedOriginalsKept(_, let reason) = result else { return XCTFail("Keep both") }
        XCTAssertEqual(outcomeText(.archived(ArchiveRun(outcome: result))), reason, "the no-Trash result appears exactly once")
        XCTAssertEqual(reason, "Archive kept. This disk has no Trash, so the originals remain in place."); XCTAssertEqual(p.originalCalls, 1); XCTAssertFalse(p.events.contains("discard"))
    }
    func test_other_trash_errors_keep_both_and_report_the_actual_error() async {
        for code in [EPERM, EIO] {
            let p = Probe()
            let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100,
                trashOriginal: { p.events.append("original"); return .failed(errno: code, message: "fixture failure") })
            guard case .archivedOriginalsKept(_, let reason) = result else { return XCTFail("Keep both") }
            XCTAssertTrue(p.events.contains("verify")); XCTAssertTrue(p.events.contains("original"))
            XCTAssertTrue(reason.contains("couldn't be moved to the Trash: fixture failure"))
            XCTAssertFalse(reason.contains("no Trash")); XCTAssertFalse(p.events.contains("discard"))
        }
    }
    func test_unknown_free_space_refuses_without_claiming_zero_bytes() async {
        let p = Probe(); p.free = nil
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(let reason, let discarded) = result else { return XCTFail("Unknown space must refuse") }
        XCTAssertEqual(reason, "Tesserae couldn't read this disk's free space.")
        XCTAssertNil(discarded); XCTAssertFalse(p.events.contains("create")); XCTAssertEqual(p.originalCalls, 0)
    }
    func test_parent_sync_precedes_originals_and_failure_is_logged_but_not_fatal() async throws {
        for failure in [false, true] {
            let p = Probe(); p.syncError = failure ? EIO : nil
            let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
            guard case .archivedAndTrashed = result else { return XCTFail("Parent sync is best effort") }
            let sync = try XCTUnwrap(p.events.firstIndex(of: "syncParent"))
            XCTAssertLessThan(try XCTUnwrap(p.events.firstIndex(of: "write")), sync)
            XCTAssertLessThan(sync, try XCTUnwrap(p.events.firstIndex(of: "original")))
            let entry = try XCTUnwrap(p.logs.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
            let audit = try XCTUnwrap(json["archive"] as? [String: Any])
            XCTAssertEqual(audit["parentSyncError"] as? Int, failure ? Int(EIO) : nil)
        }
    }
    func test_parent_directory_descriptor_is_synced_and_identity_checked() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let parent = try f.file("probe").deletingLastPathComponent(), r = try XCTUnwrap(recorded(parent))
        final class Calls: @unchecked Sendable { var count = 0; var fd: Int32 = -1 }
        let calls = Calls()
        let files = ProductionArchiveFileSystem(syncDirectory: { fd in
            calls.count += 1; calls.fd = fd
            var info = Darwin.stat(); XCTAssertEqual(fstat(fd, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR); XCTAssertEqual(info.st_ino, r.fileID)
            errno = EIO; return -1
        })
        XCTAssertThrowsError(try files.syncParent(Data(parent.path.utf8), recorded: r)) { XCTAssertEqual(($0 as NSError).code, Int(EIO)) }
        XCTAssertEqual(calls.count, 1); XCTAssertGreaterThanOrEqual(calls.fd, 0)
        var closed = Darwin.stat(); XCTAssertEqual(fstat(calls.fd, &closed), -1); XCTAssertEqual(errno, EBADF)
        XCTAssertThrowsError(try files.syncParent(Data(parent.path.utf8), recorded: Recorded(fileID: r.fileID + 1, device: r.device, isDirectory: true)))
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        XCTAssertThrowsError(try files.syncParent(Data(alias.path.utf8), recorded: r))
        XCTAssertEqual(calls.count, 1, "refused paths must not be synced")
    }
    func test_failed_archive_audit_offers_discard_for_put_back() async throws {
        let f = DiskImageFixture(); try f.setUp(size: "2g"); defer { XCTAssertNoThrow(try f.tearDown()) }
        let content = try f.file("original"), original = content.deletingLastPathComponent(), path = Data(original.path.utf8)
        let r = try XCTUnwrap(recorded(original))
        let staged = ReclaimItem(nodeIndex: 1, path: path, recorded: r, recordedSize: 7, verdict: .ok, action: .archive(.zip))
        let log = ReclaimLog(directory: f.root.appendingPathComponent("audit"))
        let ctx = GuardContext(scanRoot: Data(original.deletingLastPathComponent().path.utf8), volumeRoot: Data(f.root.path.utf8),
            scanRootDevice: r.device, appBundle: URL(fileURLWithPath: "/app"), home: Data("/home".utf8))
        let p = Probe(); p.status = 3
        let result = await Archiver(runner: p, trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()), log: log, context: ctx)
            .archive(staged, format: .zip, trashOriginal: { XCTFail("Original must stay"); return .identityChanged(.inodeChanged) })
        guard case .failed(_, let discarded) = result else { return XCTFail("Writer must fail") }
        let trash = try XCTUnwrap(discarded), entry = try XCTUnwrap(log.entries().first)
        XCTAssertTrue(p.events.contains("write")); XCTAssertEqual(entry.archive?.exitStatus, 3)
        XCTAssertEqual(entry.result, "failed"); XCTAssertEqual(entry.trashURL, trash.absoluteString)
        XCTAssertEqual(entry.path, original.path + ".zip"); XCTAssertEqual(entry.isDirectory, false)
        let identity = try XCTUnwrap(recorded(trash)); XCTAssertEqual(entry.inode, identity.fileID)
        XCTAssertEqual(log.restorableEntries(), [entry])
        XCTAssertEqual(putBack(entry, stat: ProductionFileStat(), mover: ContainedMover(fixtureRoot: f.root, inner: ProductionMover()), log: log), .restored)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path + ".zip"))
        XCTAssertEqual(try Data(contentsOf: content), Data("fixture".utf8)); XCTAssertTrue(log.restorableEntries().isEmpty)
    }
    func test_free_space_precondition() async {
        for free in [UInt64(0), Archiver.requiredSpace(estimatedBytes: 100) - 1] {
            let p = Probe(); p.free = free
            let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
            guard case .failed(let reason, _) = result else { return XCTFail("Insufficient space") }
            let locale = Locale(identifier: "en_US")
            XCTAssertEqual(reason, "Archive needs " + displaySize(Archiver.requiredSpace(estimatedBytes: 100), locale: locale)
                + " free; " + displaySize(free, locale: locale) + " are available.")
            XCTAssertFalse(p.events.contains("create")); XCTAssertEqual(p.originalCalls, 0)
        }
        XCTAssertEqual(Archiver.requiredSpace(estimatedBytes: 100), 512 * 1024 * 1024 + 125)
        XCTAssertEqual(Archiver.requiredSpace(estimatedBytes: UInt64.max), UInt64.max)
    }
    func test_archive_bytes_added_to_ancestor_deltas() async {
        let p = Probe(), f = TestSnapshot(.dir("root", [.dir("dir", [.file("a", 100)]), .file("other", 50)]))
        var staged = item(p)
        staged = ReclaimItem(nodeIndex: f["a"], path: staged.path, recorded: staged.recorded, recordedSize: 100, verdict: .ok)
        let result = await engine(p).perform(staged, format: .zip, estimatedBytes: 100, trashOriginal: { _ in await p.original() })
        guard case .archivedAndTrashed = result.outcome else { return XCTFail("Successful archive") }
        var overlay = SizeOverlay(); result.apply(item: staged, to: &overlay, snapshot: f.snapshot)
        XCTAssertEqual(overlay.deltas[f["dir"]], -68); XCTAssertEqual(overlay.deltas[f.snapshot.root], -68)
        XCTAssertEqual(overlay.logicalDeltas[f.snapshot.root], -80); XCTAssertTrue(overlay.deleted.contains(f["a"]))
        overlay.restore(f["a"], in: f.snapshot); XCTAssertEqual(overlay.deltas[f.snapshot.root], 32)
    }
    func test_audit_records_format_digest_and_counts() async throws {
        let p = Probe()
        _ = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        let entry = try XCTUnwrap(p.logs.last), archive = try XCTUnwrap(entry.archive)
        XCTAssertEqual(p.logs.count, 1); XCTAssertEqual(entry.action, "archive"); XCTAssertEqual(entry.result, "ok")
        XCTAssertEqual(archive.format, "zip"); XCTAssertEqual(archive.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(archive.files, 1); XCTAssertEqual(archive.verifiedBytes, 100); XCTAssertEqual(archive.archiveBytes, 20)
        XCTAssertEqual(entry.trashURL, "file:///fake-trash/a"); XCTAssertEqual(archive.flags, ["-c", "-k", "--sequesterRsrc"])
        let roundTrip = try JSONDecoder().decode(LogEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(roundTrip, entry)
    }
    func test_real_appledouble_policy_and_aar_arguments() async {
        let facts = ArchiveItemFacts(containsRealAppleDouble: true)
        for f in [ArchiveFormat.zip, .tarXZ, .tarZst] {
            guard case .unavailable(let reason) = formatSupports(f, itemFacts: facts) else { return XCTFail("Must deny") }
            XCTAssertTrue(reason.contains("macOS metadata files"))
        }
        for f in [ArchiveFormat.appleArchiveFast, .appleArchiveSmallest] {
            XCTAssertEqual(formatSupports(f, itemFacts: facts), .available)
            XCTAssertNil(tarArguments(f, parent: Data([47]), name: Data("x".utf8)))
        }
        let p = Probe(); p.directory = true; p.facts.containsRealAppleDouble = true
        let result = await engine(p).archive(item(p), format: .zip, estimatedBytes: 100, trashOriginal: { await p.original() })
        guard case .failed(let reason, _) = result else { return XCTFail("Refuse before creation") }
        XCTAssertTrue(reason.contains("macOS metadata files")); XCTAssertFalse(p.events.contains("create")); XCTAssertEqual(p.originalCalls, 0)
    }
    func test_existing_name_is_never_overwritten() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let parent = f.root.appendingPathComponent("parent"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let raw = Data(parent.path.utf8), recorded = try XCTUnwrap(recorded(parent))
        let creator = ProductionExclusiveCreator()
        try Data("existing".utf8).write(to: parent.appendingPathComponent("a.zip"))
        let made = try creator.create(parent: raw, parentRecorded: recorded, baseName: Data("a".utf8), ext: "zip"); close(made.fd)
        XCTAssertEqual(made.name, Data("a 2.zip".utf8)); XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("a.zip")), Data("existing".utf8))
        for n in 3...99 { try Data().write(to: parent.appendingPathComponent("a \(n).zip")) }
        XCTAssertThrowsError(try creator.create(parent: raw, parentRecorded: recorded, baseName: Data("a".utf8), ext: "zip"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("a 100.zip").path))
    }
    func test_parent_identity_checked_before_create() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let parent = f.root.appendingPathComponent("parent"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let r = try XCTUnwrap(recorded(parent))
        XCTAssertThrowsError(try ProductionExclusiveCreator().create(parent: Data(parent.path.utf8),
            parentRecorded: Recorded(fileID: r.fileID + 1, device: r.device, isDirectory: true), baseName: Data("a".utf8), ext: "zip"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
    private func recorded(_ url: URL) -> Recorded? {
        guard case .ok(let s, let id, false) = ProductionFileStat().lstat(Data(url.path.utf8)) else { return nil }
        return Recorded(fileID: id, device: s.device, isDirectory: s.isDirectory)
    }
}
