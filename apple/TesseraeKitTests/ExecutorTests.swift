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

final class ExecutorTests: XCTestCase, @unchecked Sendable {
    final class Probe: FileStat, Trasher, AuditSink, @unchecked Sendable {
        var events: [String] = []
        var entries: [Data: StatResult] = [:]
        var logs: [LogEntry] = []
        var trashPaths: [Data] = []
        var secondObservation: StatResult?
        var observedPath: Data?
        var observedCount = 0
        var failPath: Data?
        var logSucceeds = true
        var hook: (@Sendable () throws -> Void)?
        func volumeUUID(_ path: Data) -> String? { "volume-A" }
        func lstat(_ path: Data) -> StatResult {
            events.append("stat:" + String(decoding: path, as: UTF8.self))
            if path == observedPath {
                observedCount += 1
                if observedCount == 2, let secondObservation { return secondObservation }
            }
            return entries[path] ?? .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1),
                                        fileID: 1, isSymlink: false)
        }
        func trash(_ url: URL) throws -> URL {
            let path = url.withUnsafeFileSystemRepresentation { Data(bytes: $0!, count: strlen($0!)) }
            trashPaths.append(path)
            events.append("trash:" + String(decoding: path, as: UTF8.self))
            if path == failPath { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            try hook?()
            return URL(fileURLWithPath: "/fake-trash/" + url.lastPathComponent)
        }
        func append(_ e: LogEntry) -> Bool {
            logs.append(e); events.append("log:" + e.result); return logSucceeds
        }
    }

    private let context = GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8),
        scanRootDevice: 7, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"),
        home: Data("/Users/tester".utf8))

    private func item(_ n: UInt32, path: Data? = nil, size: UInt64? = 10, warnings: [Reason] = []) -> JetsamItem {
        JetsamItem(nodeIndex: n, path: path ?? Data("/scan/root/f\(n)".utf8),
                   recorded: Recorded(fileID: UInt64(n + 10), device: 7, isDirectory: false),
                   recordedSize: size, verdict: warnings.first.map { .warn($0) } ?? .ok, warnings: warnings)
    }

    private func seed(_ items: [JetsamItem], _ p: Probe, flags: UInt32 = 0, links: UInt16 = 1) {
        for i in items {
            p.entries[i.path] = .ok(Observed(device: 7, flags: flags, isDirectory: false, linkCount: links),
                                    fileID: i.recorded.fileID, isSymlink: false)
        }
    }

    func test_new_warning_replacement_and_hidden_addition_require_new_consent() async {
        for container in [false, true] {
            let p = Probe()
            let old = item(0, path: Data((container ? "/Users/tester/Library/Containers/app/file" : "/scan/root/file").utf8))
            let staged = JetsamItem(nodeIndex: old.id, path: old.path, recorded: old.recorded, recordedSize: 10,
                verdict: .warn(container ? .appContainer : .otherHardLinks),
                warnings: container ? [.appContainer, .otherHardLinks] : [.otherHardLinks])
            seed([staged], p, flags: UInt32(SF_DATALESS), links: container ? 2 : 1)
            XCTAssertFalse(staged.warnings.contains(.cloudOnly))
            let r = await Executor(trasher: p, stat: p, log: p, context: context).run([staged],
                confirmedWarnings: [staged.id], reviewedVerdicts: [staged.id: staged.verdict])
            XCTAssertEqual(r.outcomes.first?.1, .notConfirmed(.cloudOnly))
            XCTAssertTrue(p.trashPaths.isEmpty)
        }
    }

    func test_reviewed_choices_still_exclude_unchecked_warnings_and_denials_when_guards_clear() async {
        let p = Probe(), items = [item(0), item(1), item(2), item(3)]
        seed(items, p) // All four current observations are now ok.
        let reviewed: [UInt32: Verdict] = [0: .ok, 1: .warn(.cloudOnly), 2: .denied(.immutable)]
        let result = await Executor(trasher: p, stat: p, log: p, context: context).run(items,
            confirmedWarnings: [], reviewedVerdicts: reviewed)
        XCTAssertEqual(result.outcomes.count, 4)
        XCTAssertEqual(p.trashPaths, [items[0].path])
        XCTAssertEqual(result.outcomes[1].1, .notConfirmed(.cloudOnly))
        XCTAssertEqual(result.outcomes[2].1, .skipped(.immutable))
        guard case .failed(_, let message) = result.outcomes[3].1 else { return XCTFail("Unreviewed item must not move") }
        XCTAssertEqual(message, "This item was not included in the confirmation.")
        XCTAssertEqual(p.logs.count, 4)
    }

    func test_progress_reports_every_audited_outcome_in_order() async {
        let p = Probe(), items = [item(0), item(1), item(2)]
        seed(items, p)
        p.failPath = items[1].path
        XCTAssertEqual(items.count, 3)
        let result = await Executor(trasher: p, stat: p, log: p, context: context).run(items, confirmedWarnings: [],
            progress: { done, total in p.events.append("progress:\(done)/\(total):logs=\(p.logs.count)") })
        XCTAssertEqual(result.outcomes.count, 3)
        XCTAssertEqual(p.events.filter { $0.hasPrefix("progress:") },
            ["progress:1/3:logs=1", "progress:2/3:logs=2", "progress:3/3:logs=3"])
    }

    func test_order_failure_continuation_and_best_effort_audit() async {
        let p = Probe(), items = [item(2), item(0), item(1)]
        seed(items, p); p.failPath = items[1].path; p.logSucceeds = false
        let result = await Executor(trasher: p, stat: p, log: p, context: context).run(items, confirmedWarnings: [])
        XCTAssertEqual(result.outcomes.map { $0.0 }, items)
        XCTAssertEqual(result.outcomes.map { $0.1 }, [
            .trashed(trashURL: URL(fileURLWithPath: "/fake-trash/f2")),
            .failed(errno: EIO, message: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)).localizedDescription),
            .trashed(trashURL: URL(fileURLWithPath: "/fake-trash/f1"))])
        XCTAssertEqual(result.reclaimableBytes, 20)
        XCTAssertEqual(result.unknownSizeTrashed, 0)
        XCTAssertEqual(p.logs.map(\.result), ["ok", "failed:5", "ok"])
        XCTAssertEqual(p.events.filter { !$0.hasPrefix("stat:") }, [
            "trash:/scan/root/f2", "log:ok", "trash:/scan/root/f0", "log:failed:5",
            "trash:/scan/root/f1", "log:ok"])
        for i in items {
            let path = String(decoding: i.path, as: UTF8.self)
            let first = p.events.firstIndex(of: "stat:" + path)!
            let trash = p.events.firstIndex(of: "trash:" + path)!
            XCTAssertLessThan(first, trash)
            XCTAssertEqual(p.events[first..<trash].filter { $0 == "stat:" + path }.count, 2)
        }
    }

    func test_identity_then_current_guards_and_confirmation() async {
        let p = Probe()
        let items = [item(0), item(1), item(2), item(3, path: Data("/System/new-file".utf8))]
        seed(items, p)
        p.entries[items[0].path] = .error(errno: ENOENT)
        p.entries[items[1].path] = .ok(Observed(device: 7, flags: UInt32(UF_IMMUTABLE),
            isDirectory: false, linkCount: 1), fileID: items[1].recorded.fileID, isSymlink: false)
        p.entries[items[2].path] = .ok(Observed(device: 7, flags: UInt32(SF_DATALESS),
            isDirectory: false, linkCount: 1), fileID: items[2].recorded.fileID, isSymlink: false)
        let r = await Executor(trasher: p, stat: p, log: p, context: context).run(items, confirmedWarnings: [])
        XCTAssertEqual(r.outcomes.map { $0.1 }, [.identityChanged(.gone), .skipped(.immutable),
                                                .notConfirmed(.cloudOnly), .skipped(.osIntegrity)])
        XCTAssertFalse(p.events.contains { $0.hasPrefix("trash:") })
        XCTAssertEqual(p.logs.map(\.result), ["identityChanged:gone", "skipped:immutable",
                                               "notConfirmed:cloudOnly", "skipped:osIntegrity"])
        XCTAssertEqual(r.reclaimableBytes, 0)
    }

    func test_second_stat_failure_and_new_denial_refuse_trash() async {
        let i = item(0)
        let rows: [(StatResult, Outcome)] = [
            (.error(errno: EACCES), .failed(errno: EACCES,
                message: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)).localizedDescription)),
            (.ok(Observed(device: 7, flags: UInt32(UF_IMMUTABLE), isDirectory: false, linkCount: 1),
                 fileID: i.recorded.fileID, isSymlink: false), .skipped(.immutable)),
            (.ok(Observed(device: 7, flags: 0, isDirectory: false, linkCount: 1),
                 fileID: i.recorded.fileID + 1, isSymlink: false), .identityChanged(.inodeChanged))
        ]
        XCTAssertEqual(rows.count, 3)
        for (second, expected) in rows {
            let p = Probe()
            seed([i], p); p.observedPath = i.path; p.secondObservation = second
            let r = await Executor(trasher: p, stat: p, log: p, context: context).run([i], confirmedWarnings: [])
            XCTAssertEqual(p.observedCount, 2)
            XCTAssertEqual(r.outcomes.map { $0.1 }, [expected])
            XCTAssertTrue(p.trashPaths.isEmpty)
            XCTAssertEqual(p.logs.count, 1)
        }
    }

    func test_confirmed_warnings_and_unknown_sizes_count_correctly() async {
        let p = Probe(), items = [item(0, warnings: [.cloudOnly]), item(1, warnings: [.otherHardLinks]), item(2, size: nil), item(3)]
        seed(items, p)
        seed([items[0]], p, flags: UInt32(SF_DATALESS))
        seed([items[1]], p, links: 2)
        let r = await Executor(trasher: p, stat: p, log: p, context: context)
            .run(items, confirmedWarnings: [0, 1])
        XCTAssertEqual(r.outcomes.count, 4)
        XCTAssertTrue(r.outcomes.allSatisfy { if case .trashed = $0.1 { return true }; return false })
        XCTAssertEqual(r.reclaimableBytes, 10)
        XCTAssertEqual(r.unknownSizeTrashed, 2)
        XCTAssertEqual(p.logs.count, 4)
    }

    func test_container_warning_does_not_hide_observed_reclaim_exclusions() async {
        for (flags, links) in [(UInt32(0), UInt16(2)), (UInt32(SF_DATALESS), UInt16(1))] {
            let p = Probe(), i = item(0, path: Data("/Users/tester/Library/Containers/app/file".utf8),
                warnings: [.appContainer, flags == 0 ? .otherHardLinks : .cloudOnly])
            seed([i], p, flags: flags, links: links)
            XCTAssertEqual(combinedVerdict(i.path, Observed(device: 7, flags: flags,
                isDirectory: false, linkCount: links), context), .warn(.appContainer))
            let r = await Executor(trasher: p, stat: p, log: p, context: context).run([i], confirmedWarnings: [0])
            XCTAssertEqual(p.trashPaths, [i.path])
            XCTAssertEqual(r.reclaimableBytes, 0)
        }
    }

    func test_audit_preserves_raw_paths_and_round_trips() async throws {
        let p = Probe(), raw = Data("/scan/root/".utf8) + Data([0xff])
        let items = [item(0), item(1, path: raw)]
        seed(items, p)
        let r = await Executor(trasher: p, stat: p, log: p, context: context).run(items, confirmedWarnings: [])
        XCTAssertEqual(r.outcomes.count, 2)
        XCTAssertEqual(p.logs.count, 2)
        XCTAssertEqual(p.trashPaths, [items[0].path])
        XCTAssertEqual(r.outcomes[1].1, .failed(errno: EILSEQ, message: "File URL changed the raw path bytes"))
        XCTAssertEqual(p.logs[0].path, "/scan/root/f0"); XCTAssertNil(p.logs[0].pathB64)
        XCTAssertNil(p.logs[1].path); XCTAssertEqual(p.logs[1].pathB64, raw.base64EncodedString())
        for (index, e) in p.logs.enumerated() {
            XCTAssertEqual(e.action, "trash"); XCTAssertEqual(e.inode, items[index].recorded.fileID)
            XCTAssertEqual(e.bytes, 10)
            if index == 0 { XCTAssertNotNil(e.trashURL); XCTAssertEqual(e.result, "ok") }
            else { XCTAssertNil(e.trashURL); XCTAssertEqual(e.result, "failed:\(EILSEQ)") }
            XCTAssertLessThan(abs(e.ts.timeIntervalSinceNow), 10)
            XCTAssertEqual(try JSONDecoder().decode(LogEntry.self, from: JSONEncoder().encode(e)), e)
        }
    }

    func test_containment_refuses_outside_and_symlink_escape_before_inner() throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let inside = try f.file("inside")
        let outside = try f.file("outside")
        let p = Probe()
        let contained = ContainedTrasher(fixtureRoot: inside.deletingLastPathComponent().appendingPathComponent("scope"),
                                         inner: p)
        try FileManager.default.createDirectory(at: contained.fixtureRoot, withIntermediateDirectories: false)
        let escape = contained.fixtureRoot.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        for url in [outside, escape] {
            try XCTExpectFailure("Deliberately reject a path outside the contained subtree") {
                XCTAssertThrowsError(try contained.trash(url))
            }
        }
        XCTAssertTrue(p.events.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data("fixture".utf8))
    }

    private func realItem(_ url: URL, n: UInt32 = 0) throws -> JetsamItem {
        let raw = url.withUnsafeFileSystemRepresentation { Data(bytes: $0!, count: strlen($0!)) }
        guard case .ok(let o, let id, false) = ProductionFileStat().lstat(raw) else {
            throw NSError(domain: "fixture stat", code: 1)
        }
        return JetsamItem(nodeIndex: n, path: raw,
            recorded: Recorded(fileID: id, device: o.device, isDirectory: o.isDirectory),
            recordedSize: 7, verdict: .ok)
    }

    private func realContext(_ f: DiskImageFixture, _ item: JetsamItem) -> GuardContext {
        GuardContext(scanRoot: Data(f.root.path.utf8), volumeRoot: Data(f.root.path.utf8),
            scanRootDevice: item.recorded.device, appBundle: context.appBundle, home: context.home)
    }

    func test_real_trash_happy_path_and_replaced_identity() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let a = try f.file("a"), b = try f.file("b")
        let items = try [realItem(a), realItem(b, n: 1)]
        // Keep the old inode alive so replacement cannot reuse it.
        try ContainedMover(fixtureRoot: f.root, inner: ProductionMover()).move(b, to: b.appendingPathExtension("old"))
        try Data("replacement".utf8).write(to: b)
        let replacement = try realItem(b)
        XCTAssertNotEqual(replacement.recorded.fileID, items[1].recorded.fileID)
        let log = Probe()
        let r = await Executor(trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()),
            stat: ProductionFileStat(), log: log, context: realContext(f, items[0])).run(items, confirmedWarnings: [])
        guard case .trashed(let trash) = r.outcomes[0].1 else { return XCTFail("Expected trash success") }
        XCTAssertTrue(trash.pathComponents.contains(".Trashes"))
        XCTAssertTrue(trash.pathComponents.starts(with: f.root.pathComponents))
        XCTAssertEqual(try Data(contentsOf: trash), Data("fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(r.outcomes[1].1, .identityChanged(.inodeChanged))
        XCTAssertEqual(try Data(contentsOf: b), Data("replacement".utf8))
        XCTAssertEqual(log.logs.map(\.result), ["ok", "identityChanged:inodeChanged"])
    }

    func test_extra_hard_links_warn_and_count_nothing_reclaimed() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let source = try f.file("a"), home = source.deletingLastPathComponent()
        let container = home.appendingPathComponent("Library/Containers/app")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let a = container.appendingPathComponent("a"), b = a.appendingPathExtension("link")
        try ContainedMover(fixtureRoot: f.root, inner: ProductionMover()).move(source, to: a)
        try FileManager.default.linkItem(at: a, to: b)
        let original = try realItem(a), log = Probe()
        let i = JetsamItem(nodeIndex: original.id, path: original.path, recorded: original.recorded,
            recordedSize: original.recordedSize, verdict: .warn(.appContainer), warnings: [.appContainer, .otherHardLinks])
        guard case .ok(let o, _, _) = ProductionFileStat().lstat(i.path) else { return XCTFail() }
        XCTAssertEqual(o.linkCount, 2)
        let ctx = GuardContext(scanRoot: Data(f.root.path.utf8), volumeRoot: Data(f.root.path.utf8),
            scanRootDevice: i.recorded.device, appBundle: context.appBundle, home: Data(home.path.utf8))
        XCTAssertEqual(allVerdicts(i.path, o, ctx), [.warn(.appContainer), .warn(.otherHardLinks)])
        let r = await Executor(trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()),
            stat: ProductionFileStat(), log: log, context: ctx).run([i], confirmedWarnings: [0])
        guard case .trashed = r.outcomes[0].1 else { return XCTFail("Expected confirmed hardlink trash") }
        XCTAssertEqual(r.reclaimableBytes, 0)
        XCTAssertEqual(try Data(contentsOf: b), Data("fixture".utf8))
        XCTAssertEqual(log.logs.map(\.result), ["ok"])
    }

    func test_volume_lost_mid_batch_fails_each_remaining_item() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let items = try (0..<3).map { try realItem(f.file("f\($0)"), n: UInt32($0)) }
        let p = Probe()
        p.hook = { try f.detach(force: true) }
        let r = await Executor(trasher: ContainedTrasher(fixtureRoot: f.root, inner: p),
            stat: ProductionFileStat(), log: p, context: realContext(f, items[0])).run(items, confirmedWarnings: [])
        XCTAssertEqual(r.outcomes.count, 3)
        guard case .trashed = r.outcomes[0].1 else { return XCTFail() }
        for outcome in r.outcomes.dropFirst().map({ $0.1 }) {
            switch outcome {
            case .failed, .identityChanged(.gone), .identityChanged(.unreadable): break
            default: XCTFail("Unexpected outcome: \(outcome)")
            }
        }
        XCTAssertEqual(p.events.filter { $0.hasPrefix("trash:") }.count, 1)
        XCTAssertEqual(p.logs.count, 3)
    }

    func test_deletion_suites_have_no_uncontained_foundation_moves() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let suites = ["ExecutorTests.swift", "PutBackTests.swift", "AppModelTests.swift", "JettisonLogTests.swift", "LiveTrashCheckTests.swift", "SizeOverlayTests.swift"]
        let pattern = #"\bmoveItem\s*\("#
        for name in suites {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertNil(source.range(of: pattern, options: .regularExpression), name)
        }
        XCTAssertNotNil(("manager.move" + "Item(at: a, to: b)").range(of: pattern, options: .regularExpression))
    }

    func test_destructive_source_surface_is_exactly_one_trash_call() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let all = try scannedSources(repo)
        XCTAssertEqual(try trashCallCount(in: all), 1)
        XCTAssertEqual(destructiveOperations(in: all), [])

        // Exercise the same scan on planted strings, without changing product sources.
        for forbidden in ["removeItem", "unlink(", "rmdir(", "deletelocalsnapshots", "thinlocalsnapshots",
                          #"runner.run(URL(fileURLWithPath: "/usr/bin/tmutil"), ["delete", "-p", path], 5)"#,
                          #"p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil"); p.arguments = ["-p", "delete"]"#,
                          "/usr/bin/tmutil delete -p /fixture"] {
            XCTAssertFalse(destructiveOperations(in: all + "\n" + forbidden).isEmpty, forbidden)
        }
        XCTAssertEqual(destructiveOperations(in:
            #"runner.run(URL(fileURLWithPath: "/usr/bin/tmutil"), ["listlocalsnapshots", path], 5)"#), [])
    }

    private func scannedSources(_ repo: URL) throws -> String {
        var all = ""
        for name in ["TesseraeKit", "Tesserae"] {
            let root = repo.appendingPathComponent(name)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            var count = 0
            for case let file as URL in enumerator {
                let type = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if type.isDirectory == true, file.pathExtension == "xcassets" {
                    enumerator.skipDescendants(); continue
                }
                guard type.isRegularFile == true else { continue }
                if ["png", "icns", "pdf"].contains(file.pathExtension) { continue }
                all += try String(contentsOf: file, encoding: .utf8); count += 1
            }
            XCTAssertGreaterThan(count, 0)
        }
        return all
    }

    func test_unknown_extension_is_scanned_in_temporary_tree() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["TesseraeKit", "Tesserae"] {
            try FileManager.default.copyItem(at: repo.appendingPathComponent(name), to: copy.appendingPathComponent(name))
        }
        let planted = copy.appendingPathComponent("TesseraeKit/planted.unknown")
        try "unlink(forbidden)\nmanager.trashItem (at: planted)".write(to: planted, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planted.path))
        let assetNamedFile = copy.appendingPathComponent("TesseraeKit/regular.xcassets")
        try "removeItem".write(to: assetNamedFile, atomically: true, encoding: .utf8)
        let source = try scannedSources(copy)
        XCTAssertEqual(destructiveOperations(in: source), ["removeItem", "unlink("])
        XCTAssertEqual(try trashCallCount(in: source), 2)
    }

    private func trashCallCount(in source: String) throws -> Int {
        let pattern = try NSRegularExpression(pattern: #"\btrashItem\s*\("#)
        return pattern.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
    }

    private func destructiveOperations(in source: String) -> [String] {
        var violations = ["removeItem", "unlink(", "rmdir(", "deletelocalsnapshots", "thinlocalsnapshots"]
            .filter { source.contains($0) }
        // Conservatively reject a delete argument array anywhere in sources using tmutil,
        // including Process arguments assigned separately from its executable URL.
        let arrayDelete = #"(?s)\[[^\]]*["']delete["'][^\]]*\]"#
        let shellDelete = #"\btmutil\b[^\n;]*\bdelete\b"#
        if source.contains("tmutil"),
           source.range(of: arrayDelete, options: .regularExpression) != nil
            || source.range(of: shellDelete, options: .regularExpression) != nil {
            violations.append("tmutil delete")
        }
        return violations
    }
}
