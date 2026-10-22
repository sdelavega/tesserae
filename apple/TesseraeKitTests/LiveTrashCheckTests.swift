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

@MainActor
final class LiveTrashCheckTests: XCTestCase {
    func test_live_trash_and_put_back() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TESSERAE_LIVE_TRASH_ROOT"] else {
            throw XCTSkip("Coordinator opt-in: TESSERAE_LIVE_TRASH_ROOT is unset")
        }
        let root = try LiveTrashHarness.validate(path)
        let output = try XCTUnwrap(env["TESSERAE_LIVE_TRASH_OUT"], "Set TESSERAE_LIVE_TRASH_OUT")
        guard output.hasPrefix("/") else { return XCTFail("Output must be absolute") }
        _ = try await LiveTrashHarness.run(root: root, output: URL(fileURLWithPath: output))
    }
}

@MainActor
final class LiveTrashSafetyTests: XCTestCase {
    func test_preflight_refuses_unsafe_roots_before_writing() throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let file = try f.file("file")
        let shallow = f.root.appendingPathComponent("shallow")
        let safe = f.root.appendingPathComponent("safe/nested")
        for url in [shallow, safe] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        for path in ["relative/root", f.root.appendingPathComponent("missing").path, file.path, safe.path] {
            XCTAssertThrowsError(try LiveTrashHarness.validate(path), path)
        }
        for url in [f.root!, shallow] {
            try Data().write(to: url.appendingPathComponent(".tesserae-live-test"))
            XCTAssertThrowsError(try LiveTrashHarness.validate(url.path), "volume root and first child refused")
        }
        let symlinkRoot = f.root.appendingPathComponent("symlink/nested")
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent(".tesserae-live-test"), withDestinationURL: file)
        XCTAssertThrowsError(try LiveTrashHarness.validate(symlinkRoot.path), "marker must be a regular file, not a symlink")
        try Data().write(to: safe.appendingPathComponent(".tesserae-live-test"))
        XCTAssertEqual(try LiveTrashHarness.validate(safe.path).path, safe.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: safe.path), [".tesserae-live-test"], "validation writes nothing")
    }

    func test_harness_records_success_and_expected_trash_failure_on_disk_image() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let root = f.root.appendingPathComponent("live/nested")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
        for failure in [false, true] {
            let output = root.appendingPathComponent(failure ? "failure.json" : "success.json")
            let report = try await LiveTrashHarness.run(root: try LiveTrashHarness.validate(root.path), output: output,
                trasher: failure ? UnavailableTrash() : ProductionTrasher())
            XCTAssertEqual(report.items.count, 2)
            XCTAssertEqual(report.filesystem, "apfs")
            XCTAssertTrue(report.items.allSatisfy { $0.returned && !$0.lost })
            XCTAssertTrue(report.items.allSatisfy { failure ? $0.errno == EOPNOTSUPP : $0.outcome == "Moved to Trash." })
            XCTAssertEqual(try JSONDecoder().decode(LiveTrashHarness.Report.self, from: Data(contentsOf: output)), report)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(report.run).path), "no cleanup")
        }
    }

    private struct UnavailableTrash: Trasher {
        func trash(_ url: URL) throws -> URL { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EOPNOTSUPP)) }
    }
}

@MainActor
private enum LiveTrashHarness {
    struct Item: Codable, Equatable {
        let path: String
        let fileID: UInt64
        let outcome: String
        let errno: Int32?
        let trashURL: String?
        let putBack: String?
        let returned: Bool
        let inTrash: Bool
        let lost: Bool
    }
    struct Report: Codable, Equatable {
        let run: String
        let filesystem: String
        let items: [Item]
    }

    // Read-only preflight. Resolve the mount and marker before creating anything.
    static func validate(_ path: String) throws -> URL {
        func refuse() -> NSError { NSError(domain: "LiveTrashPreflight", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Root must be an absolute directory with a regular .tesserae-live-test marker, at least two components below its mount point"]) }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw refuse() }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var info = Darwin.stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw refuse() }
        let mount = URL(fileURLWithPath: String(decoding: try volumeRoot(of: Data(root.path.utf8)), as: UTF8.self))
            .resolvingSymlinksInPath().standardizedFileURL
        guard root.pathComponents.starts(with: mount.pathComponents),
              root.pathComponents.count >= mount.pathComponents.count + 2 else { throw refuse() }
        let marker = root.appendingPathComponent(".tesserae-live-test")
        guard lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw refuse() }
        return root
    }

    static func run(root: URL, output: URL, trasher: any Trasher = ProductionTrasher()) async throws -> Report {
        let root = try validate(root.path)
        var fs = statfs()
        guard statfs(root.path, &fs) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let filesystem = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let run = "run-" + UUID().uuidString.lowercased()
        let directory = root.appendingPathComponent(run)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("a"), withIntermediateDirectories: false)
        let files = [directory.appendingPathComponent("a/b.bin"), directory.appendingPathComponent("c.txt")]
        try Data(repeating: 0x41, count: 1_048_576).write(to: files[0], options: .withoutOverwriting)
        try Data("Tesserae live trash check\n".utf8).write(to: files[1], options: .withoutOverwriting)
        let suite = "Tesserae.LiveTrash." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(coordinator: ScanCoordinator(progressInterval: 0.005), accessLoader: { .granted },
            onboardingStore: OnboardingStore(defaults: defaults))
        await model.waitForAccess()
        model.scan(directory)
        for _ in 0..<6000 {
            if model.scanState == .finished { break }
            if case .failed = model.scanState { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.scanState == .finished, let session = model.session else {
            model.cancel()
            throw NSError(domain: "LiveTrashScan", code: 1)
        }
        let snapshot = session.snapshot
        let context = try XCTUnwrap(session.guardContext)
        XCTAssertEqual(context.volumeRoot, try volumeRoot(of: Data(root.path.utf8)))
        let nodes = try files.map { file in
            try XCTUnwrap((0..<UInt32(snapshot.nodes.count)).first { snapshot.rawPath($0) == Data(file.path.utf8) })
        }
        session.selection.nodes = Set(nodes)
        model.stageSelection(); await model.waitForStaging()
        XCTAssertEqual(session.reclaim.items.count, 2)
        let log = ReclaimLog(directory: directory.appendingPathComponent("audit"))
        let execution = await model.executeReclaim(confirmedWarnings: [],
            trasher: ContainedTrasher(fixtureRoot: root, inner: trasher), log: log)
        let result = try XCTUnwrap(execution)
        var items: [Item] = []
        let stat = ProductionFileStat()
        func present(_ url: URL, id: UInt64) -> Bool {
            if case .ok(_, let observedID, false) = stat.lstat(Data(url.path.utf8)) { return observedID == id }
            return false
        }
        for (item, outcome) in result.outcomes {
            let original = URL(fileURLWithPath: String(decoding: item.path, as: UTF8.self))
            var trash: URL?
            var restored: String?
            var code: Int32?
            if case .failed(let error, _) = outcome { code = error }
            if case .trashed(let url) = outcome {
                trash = url
                let entry = try XCTUnwrap(result.auditEntries.first { $0.trashURL == url.absoluteString && $0.result == "ok" })
                restored = putBackText(await model.putBack(entry,
                    mover: ContainedMover(fixtureRoot: root, inner: ProductionMover(), allowedTrashURL: url, failOnEscape: true), log: log))
            }
            let returned = present(original, id: item.recorded.fileID)
            let inTrash = trash.map { present($0, id: item.recorded.fileID) } ?? false
            items.append(Item(path: original.path, fileID: item.recorded.fileID, outcome: outcomeText(outcome), errno: code,
                trashURL: trash?.absoluteString, putBack: restored, returned: returned, inTrash: inTrash, lost: !returned && !inTrash))
        }
        let report = Report(run: run, filesystem: filesystem, items: items)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .withoutOverwriting)
        XCTAssertEqual(items.count, 2, "every staged item has a recorded outcome")
        XCTAssertFalse(items.contains { $0.lost }, "An item is neither at its original path nor its returned Trash location")
        return report
    }
}
