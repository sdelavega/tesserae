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
