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
import XCTest
@testable import TesseraeKit

final class ReclaimActionTests: XCTestCase, @unchecked Sendable {
    private let volume = VolumeCapabilities(isLocal: true, isWritable: true, fsType: "apfs")
    private func item(_ path: String = "/Users/x/item", directory: Bool = false, facts: ArchiveItemFacts = ArchiveItemFacts(),
                      unknown: Bool = false, warnings: [Reason] = []) -> ReclaimItem {
        ReclaimItem(nodeIndex: 1, path: Data(path.utf8), recorded: Recorded(fileID: 3, device: 4, isDirectory: directory),
                    recordedSize: 512, verdict: .ok, warnings: warnings, hasUnknownContent: unknown, archiveFacts: facts)
    }
    @MainActor
    func test_review_refuses_archive_after_parent_becomes_shared() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/review-ancestry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { _ = chmod(directory.path, 0o755); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: url)
        let raw = Data(url.path.utf8)
        guard case .ok(let observation, let id, false) = ProductionFileStat().lstat(raw) else { return XCTFail("precondition: real file") }
        let staged = ReclaimItem(nodeIndex: 1, path: raw,
            recorded: Recorded(fileID: id, device: observation.device, isDirectory: false), recordedSize: 7, verdict: .ok)
        let context = GuardContext(scanRoot: Data(directory.path.utf8), volumeRoot: try volumeRoot(of: raw),
            scanRootDevice: observation.device, appBundle: URL(fileURLWithPath: "/fixture/Tesserae.app"), home: Data(NSHomeDirectory().utf8))
        let review = ReclaimViewModel(defaults: nil)
        func prepare() async throws -> ReclaimItem {
            review.prepare([staged], context: context)
            for _ in 0..<500 where review.preparing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(review.preparing, "precondition: preparation completed")
            return try XCTUnwrap(review.items.first)
        }
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        let ordinary = try await prepare()
        XCTAssertEqual(review.availability(.archive(.zip), for: ordinary), .available, "precondition: ordinary folder eligible")
        XCTAssertEqual(chmod(directory.path, 0o777), 0)
        let shared = try await prepare()
        XCTAssertEqual(review.availability(.archive(.zip), for: shared), .unavailable(
            "Another user can change files in this folder, so Tesserae can't safely compress or archive here."))
        XCTAssertEqual(review.availability(.trash, for: shared), .available)
    }

    final class AncestryStat: FileStat, @unchecked Sendable {
        var values: [Data: StatResult] = [:]
        var calls: [Data] = []
        func lstat(_ path: Data) -> StatResult { calls.append(path); return values[path] ?? .error(errno: ENOENT) }
        func seed(_ path: String, owner: UInt32, permissions: UInt16 = 0o755, directory: Bool = true, symlink: Bool = false) {
            values[Data(path.utf8)] = .ok(Observed(device: 7, flags: 0, isDirectory: directory, linkCount: 1,
                owner: owner, permissions: permissions), fileID: 1, isSymlink: symlink)
        }
    }

    func test_mutation_ancestry_checks_every_directory_and_stops_at_volume_root() {
        let probe = AncestryStat(), user = geteuid()
        let path = Data("/disk/home/folder/item".utf8), root = Data("/disk".utf8)
        func reset() {
            probe.seed("/disk", owner: 0)
            probe.seed("/disk/home", owner: user)
            probe.seed("/disk/home/folder", owner: user)
            probe.seed("/disk/home/folder/item", owner: user, directory: false)
            probe.calls = []
        }
        reset()
        XCTAssertTrue(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe))
        XCTAssertEqual(probe.calls, ["/disk/home/folder/item", "/disk/home/folder", "/disk/home", "/disk"].map { Data($0.utf8) })
        for (directory, owner, permissions): (String, UInt32, UInt16) in [
            ("/disk/home/folder", user, 0o777), ("/disk/home", user, 0o775),
            ("/disk/home", user + 1, 0o755), ("/disk", user, 0o777)] {
            reset(); probe.seed(directory, owner: owner, permissions: permissions)
            XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe), directory)
        }
        reset(); probe.seed("/disk/home", owner: user, symlink: true)
        XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe))
        reset(); probe.values[Data("/disk/home".utf8)] = .error(errno: EACCES)
        XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe))
    }

    func test_firmlinked_home_checks_the_physical_data_volume_root() {
        let probe = AncestryStat(), user = geteuid()
        probe.seed("/Users", owner: 0)
        probe.seed("/Users/tester", owner: user)
        probe.seed("/Users/tester/item", owner: user, directory: false)
        let root = "/System/Volumes/Data", path = Data("/Users/tester/item".utf8)
        probe.seed(root, owner: 0, permissions: 0o775)
        XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: Data(root.utf8), user: user, stat: probe))
        probe.seed(root, owner: 0, permissions: 0o755)
        XCTAssertTrue(mutationAncestryIsSafe(path, volumeRoot: Data(root.utf8), user: user, stat: probe))
        XCTAssertTrue(probe.calls.contains(Data(root.utf8)), "physical volume root was inspected")
        XCTAssertFalse(probe.calls.contains(Data("/".utf8)), "system root does not substitute for the data volume root")
    }

    func test_sticky_directory_protects_only_trusted_owners_entries() {
        let probe = AncestryStat(), user = geteuid()
        let path = Data("/disk/tmp/item".utf8), root = Data("/disk".utf8)
        probe.seed("/disk", owner: 0)
        probe.seed("/disk/tmp", owner: 0, permissions: 0o1777)
        probe.seed("/disk/tmp/item", owner: user, directory: false)
        XCTAssertTrue(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe), "precondition: tmp-style sticky protection")
        probe.seed("/disk/tmp/item", owner: user + 1, directory: false)
        XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe))
        probe.seed("/disk/tmp/item", owner: user, directory: false)
        probe.seed("/disk/tmp", owner: user + 1, permissions: 0o1777)
        XCTAssertFalse(mutationAncestryIsSafe(path, volumeRoot: root, user: user, stat: probe), "directory owner can remove any entry")
    }

    func test_unsafe_ancestry_disables_compress_and_every_archive_but_keeps_trash() {
        var facts = ArchiveItemFacts()
        XCTAssertEqual(availableActions(for: item(facts: facts), volume: volume, verdict: .ok)[.compress], .available, "precondition")
        facts.mutationAncestrySafe = false
        let actions = availableActions(for: item(facts: facts), volume: volume, verdict: .ok)
        XCTAssertEqual(actions[.trash], .available)
        let reason = "Another user can change files in this folder, so Tesserae can't safely compress or archive here."
        for action in [ReclaimAction.compress] + ArchiveFormat.allCases.map({ .archive($0) }) {
            XCTAssertEqual(actions[action], .unavailable(reason))
        }
        XCTAssertEqual(formatSupports(.zip, itemFacts: facts), .unavailable(reason))
    }

    func test_production_ancestry_uses_fresh_lstat_permissions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ancestry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { _ = chmod(root.path, 0o755); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("item")
        try Data("fixture".utf8).write(to: file)
        for (mode, expected): (mode_t, Bool) in [(0o755, true), (0o777, false), (0o1777, true), (0o775, false), (0o755, true)] {
            XCTAssertEqual(chmod(root.path, mode), 0, "precondition")
            let path = Data(file.path.utf8), volume = Data(root.path.utf8)
            XCTAssertEqual(mutationAncestryIsSafe(path, volumeRoot: volume), expected, "mode \(mode)")
        }
    }

    func test_action_default_and_all_formats() {
        XCTAssertEqual(item().action, .trash)
        let actions = availableActions(for: item(), volume: volume, verdict: .ok)
        XCTAssertEqual(actions.count, 7)
        XCTAssertTrue(actions.values.allSatisfy { $0 == .available })
        var changed = item()
        changed.action = .compress
        XCTAssertNotEqual(changed, item())
    }
    func test_compress_unavailable_on_exfat_and_smb_with_reason() {
        XCTAssertTrue(volume.canCompress)
        for v in [VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat"),
                  VolumeCapabilities(isLocal: false, isWritable: true, fsType: "apfs"),
                  VolumeCapabilities(isLocal: false, isWritable: true, fsType: "smbfs")] {
            XCTAssertFalse(v.canCompress)
            let actions = availableActions(for: item(), volume: v, verdict: .ok)
            guard case .unavailable(let reason) = actions[.compress] else { return XCTFail("Expected disabled action") }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertEqual(actions[.archive(.zip)], .available)
        }
        let readOnly = VolumeCapabilities(isLocal: true, isWritable: false, fsType: "apfs")
        XCTAssertFalse(readOnly.canCompress)
        XCTAssertFalse(readOnly.canArchive)
        XCTAssertNotEqual(availableActions(for: item(), volume: readOnly, verdict: .ok)[.archive(.zip)], .available)
    }
    func test_archive_denied_for_cloud_only_unknown_content_other_volume_and_archive_items() {
        XCTAssertEqual(availableActions(for: item(), volume: volume, verdict: .ok)[.archive(.zip)], .available)
        XCTAssertEqual(availableActions(for: item("/folder.zip", directory: true), volume: volume, verdict: .ok)[.archive(.zip)], .available)
        let items = [item(facts: ArchiveItemFacts(containsCloudOnly: true)), item(unknown: true),
                     item(facts: ArchiveItemFacts(containsOtherVolume: true)), item(facts: ArchiveItemFacts(parentWritable: false)),
                     item(warnings: [.containsCloudOnly]), item(warnings: [.containsUnknownSize])]
            + ["zip", "tar.xz", "tar.zst", "aar"].map { item("/a.\($0.uppercased())") }
        for i in items {
            for f in ArchiveFormat.allCases {
                guard case .unavailable(let text) = availableActions(for: i, volume: volume, verdict: .ok)[.archive(f)] else {
                    XCTFail("Expected archive denial for \(i.path)"); continue
                }
                XCTAssertFalse(text.isEmpty)
            }
        }
        XCTAssertEqual(formatSupports(.zip, itemFacts: ArchiveItemFacts()), .available)
    }
    func test_denied_item_offers_nothing() {
        XCTAssertFalse(availableActions(for: item(), volume: volume, verdict: .ok).isEmpty)
        XCTAssertTrue(availableActions(for: item(), volume: volume, verdict: .denied(.immutable)).isEmpty)
        var denied = item()
        denied.verdict = .denied(.restricted)
        XCTAssertTrue(availableActions(for: denied, volume: volume, verdict: .ok).isEmpty)
    }
    func test_default_format_by_volume() {
        XCTAssertEqual(ArchiveFormat.allCases.count, 5)
        for fs in ["apfs", "hfs"] { XCTAssertEqual(defaultFormat(volumeFSType: fs), .appleArchiveFast) }
        for fs in ["exfat", "msdos", "ntfs", "smbfs"] { XCTAssertEqual(defaultFormat(volumeFSType: fs), .zip) }
        XCTAssertEqual(ArchiveFormat.appleArchiveFast.fileExtension, "aar")
        XCTAssertEqual(ArchiveFormat.appleArchiveSmallest.fileExtension, "aar")
    }
    func test_advanced_membership_by_volume() {
        for fs in ["apfs", "hfs", "exfat", "msdos", "ntfs", "smbfs"] {
            for f in ArchiveFormat.allCases {
                XCTAssertEqual(isAdvanced(f, volumeFSType: fs), f == .tarZst || f == .appleArchiveSmallest || (f == .appleArchiveFast && fs != "apfs" && fs != "hfs"))
            }
        }
    }
    func test_item_warning_boundaries_and_denial_precedence() {
        let boundary = ArchiveItemFacts(largestFileSize: 4 * 1024 * 1024 * 1024, eligibleBytes: 100_000_000_000)
        XCTAssertTrue(actionWarnings(for: item(), action: .compress, facts: boundary).isEmpty)
        let facts = ArchiveItemFacts(containsGitWorkingTree: true, largestFileSize: boundary.largestFileSize + 1,
                                     eligibleBytes: boundary.eligibleBytes + 1)
        XCTAssertEqual(actionWarnings(for: item("/a.app"), action: .compress, facts: facts),
                       [.appBundleCompress, .gitWorkingTree, .largeFile, .largeCompressRun])
        XCTAssertTrue(actionWarnings(for: item("/a.app"), action: .trash, facts: facts).isEmpty)
        for reason in [Reason.appBundleCompress, .gitWorkingTree, .largeFile, .largeCompressRun, .containsOtherVolume, .isArchive] {
            XCTAssertFalse(reasonText(reason).isEmpty)
        }
        XCTAssertEqual(orderedVerdicts([.warn(.appContainer), .denied(.isArchive), .warn(.appBundleCompress)]),
                       [.denied(.isArchive), .warn(.appContainer), .warn(.appBundleCompress)])
    }
    func test_open_files_probe_reports_partial_inspection() async {
        let probe = CountingOpenFilesProbe()
        let prepared = await prepareOpenFiles(using: probe)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(prepared.keys, [FileKey(dev: 2, ino: 7)])
        XCTAssertFalse(prepared.inspectedAll)
        XCTAssertNil(openFilesInspectionWarning(inspectedAll: true))
        XCTAssertFalse((openFilesInspectionWarning(inspectedAll: false) ?? "").isEmpty)
        let key = FileKey(dev: 2, ino: 7)
        let complete = LibprocOpenFilesProbe.sweep(processes: [1, 2]) { _ in ([key], true) }
        XCTAssertEqual(complete.keys, [key]); XCTAssertTrue(complete.inspectedAll)
        var calls = 0
        let partial = LibprocOpenFilesProbe.sweep(processes: [1, 2]) { pid in
            calls += 1
            return pid == 1 ? ([key], true) : ([], false)
        }
        XCTAssertEqual(calls, 2); XCTAssertEqual(partial.keys, [key]); XCTAssertFalse(partial.inspectedAll)
        XCTAssertFalse(LibprocOpenFilesProbe.sweep(processes: nil) { _ in XCTFail("No PIDs"); return ([], true) }.inspectedAll)
    }
    func test_live_open_files_probe_finds_writer() async throws {
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let url = fixture.root.appendingPathComponent("writer")
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        let key = FileKey(dev: info.st_dev, ino: info.st_ino)
        let result = await prepareOpenFiles(using: LibprocOpenFilesProbe())
        XCTAssertTrue(result.keys.contains(key))
    }
}

private final class CountingOpenFilesProbe: OpenFilesProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func openForWriting() -> (keys: Set<FileKey>, inspectedAll: Bool) {
        XCTAssertFalse(Thread.isMainThread)
        lock.withLock { count += 1 }
        return ([FileKey(dev: 2, ino: 7)], false)
    }
}
