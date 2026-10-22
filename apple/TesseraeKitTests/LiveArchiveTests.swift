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

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import TesseraeKit

final class LiveArchiveTests: XCTestCase, @unchecked Sendable {
    func fixture(fs: String = "APFS") throws -> (DiskImageFixture, URL) {
        guard ProcessInfo.processInfo.environment["TESSERAE_LIVE_ARCHIVE"] == "1" else {
            throw XCTSkip("Opt in with TESSERAE_LIVE_ARCHIVE=1; tests use their own disposable images")
        }
        let f = DiskImageFixture()
        do { try f.setUp(size: "2g", fs: fs) }
        catch { if fs == "ExFAT" { throw XCTSkip("exFAT image creation unavailable on this host: \(error)") }; throw error }
        do {
            let root = f.root.appendingPathComponent("archive/nested")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("archive test".utf8).write(to: root.appendingPathComponent(".tesserae-live-test"))
            try validate(root, mount: f.root); return (f, root)
        } catch { try f.tearDown(); throw error }
    }
    func validate(_ root: URL, mount: URL, uuid: String? = nil) throws {
        try Self.validateRoot(root, mount: mount, uuid: uuid)
    }
    static func validateRoot(_ root: URL, mount: URL, uuid: String? = nil) throws {
        let path = root.path
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw archiveError(EPERM) }
        // O_NOFOLLOW_ANY refuses symlinks in every component, including the root.
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        let mount = mount.standardizedFileURL
        guard root.pathComponents.starts(with: mount.pathComponents), root.pathComponents.count >= mount.pathComponents.count + 2,
              try volumeRoot(of: Data(path.utf8)) == Data(mount.path.utf8) else { throw archiveError(EPERM) }
        var s = Darwin.stat()
        guard fstatat(fd, ".tesserae-live-test", &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_mode & S_IFMT == S_IFREG else { throw archiveError(EPERM) }
        if let uuid {
            guard !uuid.isEmpty, ProductionFileStat().volumeUUID(Data(path.utf8)) == uuid else { throw archiveError(EPERM) }
        }
    }
    func test_coordinator_preflight_refuses_containment_breaches_without_writes() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let safe = f.root.appendingPathComponent("safe/nested")
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let uuid = try XCTUnwrap(ProductionFileStat().volumeUUID(Data(safe.path.utf8)))
        XCTAssertThrowsError(try validate(safe, mount: f.root, uuid: uuid), "missing marker")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: safe.path).isEmpty, "never create a missing marker")
        let marker = safe.appendingPathComponent(".tesserae-live-test")
        try Data().write(to: marker)
        XCTAssertNoThrow(try validate(safe, mount: f.root, uuid: uuid))
        XCTAssertThrowsError(try validate(safe, mount: f.root, uuid: "wrong-uuid"))
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: safe.deletingLastPathComponent())
        XCTAssertThrowsError(try validate(alias.appendingPathComponent("nested"), mount: f.root, uuid: uuid), "symlink ancestor")
        let leaf = f.root.appendingPathComponent("safe/leaf")
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: safe)
        XCTAssertThrowsError(try validate(leaf, mount: f.root, uuid: uuid), "symlink root")
        for root in [f.root!, safe.deletingLastPathComponent()] {
            try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
            XCTAssertThrowsError(try validate(root, mount: f.root, uuid: uuid), "shallow root")
        }
        let badMarker = f.root.appendingPathComponent("bad/nested")
        try FileManager.default.createDirectory(at: badMarker, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: badMarker.appendingPathComponent(".tesserae-live-test"), withDestinationURL: marker)
        XCTAssertThrowsError(try validate(badMarker, mount: f.root, uuid: uuid), "symlink marker")
        let directoryMarker = f.root.appendingPathComponent("directory/nested")
        try FileManager.default.createDirectory(at: directoryMarker.appendingPathComponent(".tesserae-live-test"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try validate(directoryMarker, mount: f.root, uuid: uuid), "directory marker")
        XCTAssertThrowsError(try validate(marker, mount: f.root, uuid: uuid), "file root")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: safe.path), [".tesserae-live-test"])
    }
    func test_coordinator_root_mode_round_trip_json_and_preserves_run() async throws {
        let f = DiskImageFixture(); try f.setUp(size: "2g"); defer { XCTAssertNoThrow(try f.tearDown()) }
        let root = f.root.appendingPathComponent("coordinator/nested")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
        let uuid = try XCTUnwrap(ProductionFileStat().volumeUUID(Data(root.path.utf8))), output = root.appendingPathComponent("results.json")
        let report = try await coordinatorRoot(environment: ["TESSERAE_LIVE_ARCHIVE_ROOT": root.path,
            "TESSERAE_LIVE_ARCHIVE_UUID": uuid, "TESSERAE_LIVE_ARCHIVE_OUT": output.path])
        XCTAssertNil(report.failure)
        XCTAssertEqual(report.filesystem, "apfs"); XCTAssertEqual(report.volumeUUID, uuid)
        XCTAssertEqual(Set(report.formats.map(\.format)), Set(ArchiveFormat.allCases.map(\.rawValue)))
        XCTAssertTrue(report.formats.allSatisfy { $0.bytes > 0 && $0.putBack && $0.sha256.count == 64 })
        XCTAssertEqual(try JSONDecoder().decode(Report.self, from: Data(contentsOf: output)), report)
        let run = root.appendingPathComponent(report.run)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.path), "run is never cleaned up")
        for format in ArchiveFormat.allCases {
            XCTAssertTrue(FileManager.default.fileExists(atPath: run.appendingPathComponent(format.rawValue + "/tree").path))
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do { _ = try await coordinatorRun(root: root, uuid: "wrong", output: root.appendingPathComponent("bad.json")); XCTFail("UUID must refuse") } catch {}
        do { _ = try await coordinatorRun(root: root, uuid: uuid, output: output); XCTFail("Existing output must refuse") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before, "failed preflight writes nothing")
    }
    func test_coordinator_failure_writes_json_and_keeps_a_fresh_run() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let root = f.root.appendingPathComponent("failure/nested")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
        let uuid = try XCTUnwrap(ProductionFileStat().volumeUUID(Data(root.path.utf8)))
        var runs: [String] = []
        for index in 0..<2 {
            let output = root.appendingPathComponent("failure-\(index).json")
            do {
                _ = try await coordinatorRun(root: root, uuid: uuid, output: output) { directory in
                    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
                    throw archiveError(EIO)
                }
                XCTFail("Runtime errors must fail the run")
            } catch {}
            let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: output))
            XCTAssertNotNil(report.failure); XCTAssertTrue(report.formats.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(report.run).path))
            runs.append(report.run)
        }
        XCTAssertEqual(Set(runs).count, 2, "each attempt uses a fresh retained subdirectory")
    }
    func test_coordinator_archive_failure_records_check_and_raw_path() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let root = f.root.appendingPathComponent("diagnostics/nested")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
        let uuid = try XCTUnwrap(ProductionFileStat().volumeUUID(Data(root.path.utf8)))
        let output = root.appendingPathComponent("failure.json")
        do {
            _ = try await coordinatorRun(root: root, uuid: uuid, output: output) { directory in
                let fifo = directory.appendingPathComponent("tiny\nname")
                XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
                _ = try ArchiveTree.scan(Data(fifo.path.utf8), hashFiles: true)
                XCTFail("FIFO must fail before any attempt to read it"); return []
            }
            XCTFail("Unsupported original must fail")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error.code, 7); XCTAssertEqual(error.path, Data("tiny\nname".utf8))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        let detail = try XCTUnwrap(json["archiveFailure"] as? [String: Any])
        XCTAssertEqual(detail["code"] as? Int, 7)
        XCTAssertEqual(detail["reason"] as? String, "unsupportedType")
        XCTAssertEqual(detail["pathBase64"] as? String, Data("tiny\nname".utf8).base64EncodedString())
        XCTAssertEqual(detail["pathLength"] as? Int, 9)
        XCTAssertTrue((json["failure"] as? String)?.contains("unsupportedType") == true)
        let missingOutput = root.appendingPathComponent("missing.json")
        do {
            _ = try await coordinatorRun(root: root, uuid: uuid, output: missingOutput) { directory in
                _ = try ArchiveTree.scan(Data(directory.appendingPathComponent("missing\nfile").path.utf8), hashFiles: true)
                XCTFail("Missing original must fail"); return []
            }
            XCTFail("Missing original must fail the run")
        } catch let error as ArchiveFailure {
            XCTAssertEqual(error.reason, .entryStat); XCTAssertEqual(error.systemError, ENOENT)
            let decoded = try JSONDecoder().decode(Report.self, from: Data(contentsOf: missingOutput))
            XCTAssertEqual(decoded.archiveFailure?.reason, "entryStat")
            XCTAssertEqual(decoded.archiveFailure?.systemError, ENOENT)
            XCTAssertEqual(decoded.archiveFailure?.pathBase64, error.path.base64EncodedString())
            XCTAssertEqual(decoded.archiveFailure?.pathLength, error.path.count)
        }
    }
    func test_exfat_item_never_offers_compress() {
        let item = ReclaimItem(nodeIndex: 1, path: Data("/fixture/test/item".utf8),
            recorded: Recorded(fileID: 1, device: 1, isDirectory: false), recordedSize: 100, verdict: .ok)
        let actions = availableActions(for: item, volume: VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat"), verdict: .ok)
        guard case .unavailable(let reason) = actions[.compress] else { return XCTFail("exFAT cannot offer Compress") }
        XCTAssertFalse(reason.isEmpty)
        for format in ArchiveFormat.allCases { XCTAssertEqual(actions[.archive(format)], .available) }
    }
    func staged(_ url: URL, _ format: ArchiveFormat, warnings: [Reason] = []) throws -> ReclaimItem {
        let path = Data(url.path.utf8)
        guard case .ok(let info, let id, false) = ProductionFileStat().lstat(path) else { throw archiveError() }
        let facts = try ProductionArchiveFileSystem().inspect(path)
        return ReclaimItem(nodeIndex: 1, path: path, recorded: Recorded(fileID: id, device: info.device, isDirectory: info.isDirectory),
            recordedSize: facts.facts.eligibleBytes, verdict: warnings.first.map(Verdict.warn) ?? .ok, warnings: warnings, action: .archive(format))
    }
    func context(_ root: URL, mount: URL) throws -> GuardContext {
        try validate(root, mount: mount)
        guard case .ok(let s, _, _) = ProductionFileStat().lstat(Data(root.path.utf8)) else { throw archiveError() }
        return GuardContext(scanRoot: Data(root.path.utf8), volumeRoot: Data(mount.path.utf8), scanRootDevice: s.device,
            appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/home/test".utf8))
    }
    func corpus(_ tree: URL, macMetadata: Bool) throws {
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data().write(to: tree.appendingPathComponent("empty"))
        try Data([1, 2, 3]).write(to: tree.appendingPathComponent("nested/tiny\nname"))
        let big = tree.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big), block = Data(repeating: 65, count: 1024 * 1024)
        for _ in 0..<65 { try handle.write(contentsOf: block) }; try handle.close()
        let sparse = tree.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data([9])))
        let sparseHandle = try FileHandle(forWritingTo: sparse); try sparseHandle.truncate(atOffset: 2 * 1024 * 1024); try sparseHandle.close()
        try Data("sub-block".utf8).write(to: tree.appendingPathComponent("nested/extra"))
        if macMetadata {
            XCTAssertEqual(symlink("nested/tiny\nname", tree.appendingPathComponent("link").path), 0)
            XCTAssertEqual(clonefile(big.path, tree.appendingPathComponent("clone").path, 0), 0)
            XCTAssertEqual(link(big.path, tree.appendingPathComponent("hardlink").path), 0)
            let fork = tree.appendingPathComponent("resource"); try Data("forked".utf8).write(to: fork)
            XCTAssertEqual(setxattr(fork.path, "com.apple.ResourceFork", "fork", 4, 0, 0), 0)
        }
    }
    func contents(_ tree: URL, verificationFlags: UInt32? = nil) throws -> [Data: ArchiveContent] {
        let raw = Data(tree.path.utf8)
        return try ArchiveTree.scan(raw, hashFiles: true, flags: verificationFlags ?? archiveVerificationFlags(raw)).entries
    }
    func test_apfs_emulated_sidecars_preserve_unusual_raw_names() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let tree = root.appendingPathComponent("tree"), nested = tree.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let names = ["ordinary", "tiny\nname", "tab\tname", "replacement-\u{fffd}", "-leading", String(repeating: "l", count: 240)]
        for name in names { try Data([1, 2, 3]).write(to: nested.appendingPathComponent(name)) }
        let raw = Data(tree.path.utf8)
        XCTAssertEqual(try archiveVerificationFlags(raw), 0, "real APFS, forced flag only via internal seams")
        // Write all formats before emulating exFAT's on-disk metadata files.
        var archives: [(ArchiveFormat, URL)] = []
        for format in ArchiveFormat.allCases {
            let out = root.appendingPathComponent(UUID().uuidString + "." + format.fileExtension)
            let fd = open(out.path, O_CREAT | O_EXCL | O_RDWR, 0o644)
            XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { throw archiveError(errno) }
            let status = await ProductionArchiveRunner().run(item: raw, format: format, to: fd); close(fd)
            XCTAssertEqual(status, 0); archives.append((format, out))
        }
        for name in names {
            let sidecar = nested.appendingPathComponent("._" + name)
            var metadata = Data(repeating: 0, count: 4096)
            metadata.replaceSubrange(0..<8, with: [0, 5, 22, 7, 0, 2, 0, 0])
            try metadata.write(to: sidecar)
            XCTAssertEqual(chflags(sidecar.path, UInt32(UF_HIDDEN)), 0)
            var s = Darwin.stat(); XCTAssertEqual(lstat(sidecar.path, &s), 0)
            XCTAssertEqual(s.st_size, 4096); XCTAssertEqual(s.st_mode & S_IFMT, S_IFREG)
            XCTAssertNotEqual(s.st_flags & UInt32(UF_HIDDEN), 0)
        }
        let native = try ArchiveTree.scan(raw, hashFiles: true)
        XCTAssertEqual(native.files.count, names.count * 2)
        let baseline = try contents(tree, verificationFlags: 1)
        XCTAssertEqual(baseline.count, names.count + 2, "live baseline must exclude paired sidecars too")
        let flagged = try ArchiveTree.scan(raw, hashFiles: true, flags: 1)
        XCTAssertEqual(flagged.files.count, names.count); XCTAssertEqual(flagged.stamps.count, names.count * 2 + 2)
        XCTAssertFalse(flagged.facts.containsRealAppleDouble)
        let inspection = try ProductionArchiveFileSystem(verificationFlags: { _ in 1 }).inspect(raw)
        XCTAssertEqual(inspection.files.count, names.count)
        for (format, out) in archives {
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            let verdict = ProductionArchiveVerifier(verificationFlags: { _ in 1 }).verify(fd: fd, path: Data(out.path.utf8), format: format, item: raw)
            XCTAssertEqual(verdict, ArchiveVerdict(files: UInt64(names.count), dirs: 2, bytes: UInt64(names.count * 3)), "\(format)")
            let withSidecars = root.appendingPathComponent(UUID().uuidString + "." + format.fileExtension)
            let written = open(withSidecars.path, O_CREAT | O_EXCL | O_RDWR, 0o644)
            XCTAssertGreaterThanOrEqual(written, 0); guard written >= 0 else { throw archiveError(errno) }; defer { close(written) }
            let status = await ProductionArchiveRunner().run(item: raw, format: format, to: written)
            XCTAssertEqual(status, 0)
            let actual = ProductionArchiveVerifier(verificationFlags: { _ in 1 }).verify(fd: written,
                path: Data(withSidecars.path.utf8), format: format, item: raw)
            XCTAssertEqual(actual, verdict, "writer with sidecars present: \(format)")
        }
    }
    func test_all_five_formats_apfs_archive_verify_trash_extract_put_back() async throws { try await roundTrip(fs: "APFS") }
    func test_all_five_formats_exfat_when_available() async throws { try await roundTrip(fs: "ExFAT") }
    func roundTrip(fs: String) async throws {
        let (f, root) = try fixture(fs: fs); defer { XCTAssertNoThrow(try f.tearDown()) }
        _ = try await roundTrip(root: root, mount: f.root, fs: fs)
    }
    struct FormatResult: Codable, Equatable {
        let format, outcome, archive, sha256: String
        let bytes: UInt64
        let trashURL: String?
        let putBack: Bool
    }
    struct Report: Codable, Equatable {
        let run, filesystem, volumeUUID: String
        let formats: [FormatResult]
        var failure: String? = nil
        var archiveFailure: FailureDetail? = nil
    }
    struct FailureDetail: Codable, Equatable {
        let code: Int32
        let reason: String
        let systemError: Int32?
        let pathBase64: String
        let pathLength: Int
        init(_ failure: ArchiveFailure) {
            code = failure.code; reason = failure.reason.rawValue; systemError = failure.systemError
            pathBase64 = failure.path.base64EncodedString(); pathLength = failure.path.count
        }
    }
    func test_coordinator_root_all_formats() async throws {
        _ = try await coordinatorRoot(environment: ProcessInfo.processInfo.environment)
    }
    func coordinatorRoot(environment env: [String: String]) async throws -> Report {
        guard let path = env["TESSERAE_LIVE_ARCHIVE_ROOT"] else { throw XCTSkip("Coordinator root is unset") }
        let uuid = try XCTUnwrap(env["TESSERAE_LIVE_ARCHIVE_UUID"], "Set TESSERAE_LIVE_ARCHIVE_UUID")
        let output = try XCTUnwrap(env["TESSERAE_LIVE_ARCHIVE_OUT"], "Set TESSERAE_LIVE_ARCHIVE_OUT")
        guard path.hasPrefix("/"), !path.utf8.contains(0), output.hasPrefix("/"), !output.utf8.contains(0) else { throw archiveError(EPERM) }
        return try await coordinatorRun(root: URL(fileURLWithPath: path), uuid: uuid, output: URL(fileURLWithPath: output))
    }
    func coordinatorRun(root: URL, uuid: String, output: URL, perform: ((URL) async throws -> [FormatResult])? = nil) async throws -> Report {
        // Every precondition, including the output destination, is checked before the first write.
        let mount = URL(fileURLWithPath: String(decoding: try volumeRoot(of: Data(root.path.utf8)), as: UTF8.self))
        try validate(root, mount: mount, uuid: uuid)
        guard !uuid.isEmpty else { throw archiveError(EPERM) }
        let outputParent = open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard outputParent >= 0 else { throw archiveError(errno) }; close(outputParent)
        var info = Darwin.stat()
        guard lstat(output.path, &info) != 0, errno == ENOENT else { throw archiveError(EPERM) }
        var fs = statfs()
        guard statfs(root.path, &fs) == 0 else { throw archiveError(errno) }
        let filesystem = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let run = "run-" + UUID().uuidString.lowercased(), directory = root.appendingPathComponent(run)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var formats: [FormatResult] = [], failure: (any Error)?
        do {
            formats = if let perform { try await perform(directory) } else { try await roundTrip(root: root, mount: mount, fs: filesystem, directory: directory, uuid: uuid) }
        } catch { failure = error }
        let report = Report(run: run, filesystem: filesystem, volumeUUID: uuid, formats: formats, failure: failure?.localizedDescription,
            archiveFailure: (failure as? ArchiveFailure).map(FailureDetail.init))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .withoutOverwriting)
        if let failure { throw failure }
        return report
    }
    func roundTrip(root: URL, mount: URL, fs: String, directory: URL? = nil, uuid: String? = nil) async throws -> [FormatResult] {
        var reports: [FormatResult] = []
        let isAPFS = fs.lowercased() == "apfs"
        for format in ArchiveFormat.allCases {
            try validate(root, mount: mount, uuid: uuid)
            let work = (directory ?? root).appendingPathComponent(format.rawValue); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            let tree = work.appendingPathComponent("tree"); try corpus(tree, macMetadata: isAPFS)
            let before = try contents(tree); XCTAssertGreaterThan(before.count, 6)
            let warnings: [Reason] = isAPFS ? [.containsHardLinks] : []
            let item = try staged(tree, format, warnings: warnings)
            if fs.lowercased() == "exfat" {
                let actions = availableActions(for: item, volume: VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat"), verdict: item.verdict)
                guard case .unavailable = actions[.compress] else { throw archiveError(EPERM) }
                XCTAssertFalse(actions.contains { $0.key == .compress && $0.value == .available }, "Compress must not be offered on exFAT")
            }
            let log = ReclaimLog(directory: work.appendingPathComponent("audit")), ctx = try context(root, mount: mount)
            let trasher = LiveArchiveTrasher(root: root, run: directory ?? root, mount: mount, uuid: uuid)
            let executor = Executor(trasher: trasher, stat: ProductionFileStat(), log: log, context: ctx)
            let result = await executor.run([item], confirmedWarnings: [item.id], reviewedWarnings: [item.id: Set(warnings)])
            guard case .archived(let run) = try XCTUnwrap(result.outcomes.first).1,
                  case .archivedAndTrashed(let archive, let bytes, let trash) = run.outcome else {
                XCTFail("Archive failed for \(format): \(result.outcomes.map { outcomeText($0.1) }); \(String(describing: result.auditEntries.first?.archive))")
                throw archiveError(EIO)
            }
            XCTAssertGreaterThan(bytes, 0); XCTAssertEqual(bytes, UInt64(try Data(contentsOf: archive).count))
            XCTAssertFalse(FileManager.default.fileExists(atPath: tree.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
            XCTAssertTrue(pathIsWithin(Data(trash.path.utf8), root: Data(mount.path.utf8)))
            XCTAssertEqual(try volumeRoot(of: Data(trash.path.utf8)), Data(mount.path.utf8))
            XCTAssertEqual(try contents(trash).count, before.count)
            let restored = work.appendingPathComponent("restored"); try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
            if format == .appleArchiveFast || format == .appleArchiveSmallest {
                let list = await SpawnRunner().runCapturing("/usr/bin/aa", ["list", "-i", archive.path].map { Data($0.utf8) })
                XCTAssertEqual(list.0, .exited(0)); assertListing(list.stdout, entries: before)
                let extracted = await SpawnRunner().run("/usr/bin/aa", ["extract", "-i", archive.path, "-d", restored.path].map { Data($0.utf8) })
                XCTAssertEqual(extracted, .exited(0))
            } else {
                var readable = archive
                if format == .tarZst {
                    readable = work.appendingPathComponent("decoded.tar")
                    let decoder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("target/debug/examples/archive_decode")
                    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: decoder.path), "Build the test decoder with just app-test")
                    let fd = open(readable.path, O_CREAT | O_EXCL | O_WRONLY, 0o644); guard fd >= 0 else { throw archiveError(errno) }
                    let decoded = await SpawnRunner().run(decoder.path, [Data(archive.path.utf8)], stdoutFD: fd); close(fd)
                    XCTAssertEqual(decoded, .exited(0))
                }
                let list = await SpawnRunner().runCapturing("/usr/bin/tar", ["-tf", readable.path].map { Data($0.utf8) })
                XCTAssertEqual(list.0, .exited(0)); assertListing(list.stdout, entries: before)
                let extracted = await SpawnRunner().run("/usr/bin/tar", ["-xf", readable.path, "-C", restored.path].map { Data($0.utf8) })
                XCTAssertEqual(extracted, .exited(0))
            }
            XCTAssertEqual(try contents(restored.appendingPathComponent("tree")), before)
            let entry = try XCTUnwrap(log.restorableEntries().first)
            XCTAssertEqual(entry.action, "archive"); XCTAssertEqual(entry.archive?.sha256, SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined())
            if isAPFS {
                let put = putBack(entry, stat: ProductionFileStat(), mover: ContainedMover(fixtureRoot: directory ?? root, inner: ProductionMover(), allowedTrashURL: trash, failOnEscape: true), log: log)
                XCTAssertEqual(put, .restored); XCTAssertEqual(try contents(tree), before); XCTAssertTrue(log.restorableEntries().isEmpty)
            }
            reports.append(FormatResult(format: format.rawValue, outcome: "archivedAndTrashed", archive: archive.path,
                sha256: try XCTUnwrap(entry.archive?.sha256), bytes: bytes, trashURL: trash.absoluteString, putBack: isAPFS))
        }
        XCTAssertEqual(reports.count, ArchiveFormat.allCases.count)
        return reports
    }
    func assertListing(_ listing: Data, entries: [Data: ArchiveContent]) {
        let text = String(decoding: listing, as: UTF8.self)
        XCTAssertGreaterThan(entries.count, 6)
        for raw in entries.keys {
            let path = String(decoding: raw, as: UTF8.self)
            XCTAssertTrue(text.contains(path) || text.contains(path.replacingOccurrences(of: "\n", with: "\\n")), "Listing omitted \(path)")
        }
    }
    func test_review_focus_1_real_changes_keep_originals_and_trash_stale_archive() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        for afterVerification in [false, true] {
            let url = root.appendingPathComponent(afterVerification ? "swap" : "modify")
            try Data("original".utf8).write(to: url)
            let item = try staged(url, .zip), log = ReclaimLog(directory: root.appendingPathComponent(UUID().uuidString))
            let ctx = try context(root, mount: f.root), trasher = ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher())
            let archiver = Archiver(runner: ChangingArchiveRunner(target: url, change: !afterVerification),
                verifier: ChangingArchiveVerifier(target: url, change: afterVerification), trasher: trasher, log: log, context: ctx)
            let executor = Executor(trasher: trasher, stat: ProductionFileStat(), log: log, context: ctx, archiver: archiver)
            let result = await executor.run([item], confirmedWarnings: [])
            guard case .archived(let run) = try XCTUnwrap(result.outcomes.first).1,
                  case .failed(_, let discarded) = run.outcome else { return XCTFail("Stale archive must fail") }
            XCTAssertEqual(run.auditEntry?.archive?.exitStatus, 0)
            XCTAssertEqual(run.auditEntry?.archive?.verificationCode, afterVerification ? 0 : 4)
            XCTAssertNotNil(discarded); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".zip"))
            XCTAssertEqual(try Data(contentsOf: url), Data("modified".utf8))
            XCTAssertEqual(result.reclaimableBytes, 0)
        }
    }
}
private struct ChangingArchiveRunner: ArchiveRunner {
    let target: URL, change: Bool
    func run(item: Data, format: ArchiveFormat, to fd: Int32) async -> Int32 {
        let status = await ProductionArchiveRunner().run(item: item, format: format, to: fd)
        if change { try? Data("modified".utf8).write(to: target) }
        return status
    }
}
private struct ChangingArchiveVerifier: ArchiveVerifier {
    let target: URL, change: Bool
    func verify(fd: Int32, path: Data, format: ArchiveFormat, item: Data) -> ArchiveVerdict {
        let verdict = ProductionArchiveVerifier().verify(fd: fd, path: path, format: format, item: item)
        if change { try? Data("modified".utf8).write(to: target, options: .atomic) }
        return verdict
    }
}

private struct LiveArchiveTrasher: Trasher {
    let root, run, mount: URL
    let uuid: String?
    func trash(_ url: URL) throws -> URL {
        try LiveArchiveTests.validateRoot(root, mount: mount, uuid: uuid)
        guard pathIsWithin(Data(url.path.utf8), root: Data(run.path.utf8)), url != run,
              verifyIdentity(Data(url.path.utf8), try identity(url), stat: ProductionFileStat()) == .same else {
            XCTFail("Trash escaped the run directory"); throw archiveError(EPERM)
        }
        let trash = try ProductionTrasher().trash(url)
        guard try volumeRoot(of: Data(trash.path.utf8)) == Data(mount.path.utf8),
              uuid == nil || ProductionFileStat().volumeUUID(Data(trash.path.utf8)) == uuid else {
            XCTFail("Returned Trash escaped the approved volume"); throw archiveError(EPERM)
        }
        return trash
    }
    private func identity(_ url: URL) throws -> Recorded {
        guard case .ok(let info, let id, false) = ProductionFileStat().lstat(Data(url.path.utf8)) else { throw archiveError(EPERM) }
        return Recorded(fileID: id, device: info.device, isDirectory: info.isDirectory)
    }
}
