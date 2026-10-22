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

struct ContainedMover: Mover {
    let fixtureRoot: URL
    let inner: any Mover
    // A live volume may return a Trash outside the marked test subtree.
    // Only that exact returned source is allowed; the destination stays contained.
    var allowedTrashURL: URL? = nil
    var failOnEscape = false
    func move(_ from: URL, to: URL) throws {
        let root = fixtureRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for (index, url) in [from, to].enumerated() {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let returnedTrash = index == 0 && allowedTrashURL == from
            guard returnedTrash || (path.count > root.count && path.starts(with: root)) else {
                if failOnEscape { XCTFail("Put Back escaped its marked root or recorded Trash source") }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
        }
        try inner.move(from, to: to)
    }
}

final class PutBackTests: XCTestCase {
    struct FailingMover: Mover {
        func move(_ from: URL, to: URL) throws { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
    }

    struct MissingStat: FileStat {
        let code: Int32
        func lstat(_ path: Data) -> StatResult { .error(errno: code) }
    }

    func test_invalid_trash_url_is_failed() {
        for url in [nil, "https://example.com/trash", "file://server/trash", "file://localhost/trash", "file:relative", "relative"] as [String?] {
            let entry = LogEntry(ts: Date(), action: "trash", path: "/fixture/file", pathB64: nil,
                inode: 1, bytes: 1, trashURL: url, result: "ok")
            XCTAssertEqual(putBack(entry, stat: MissingStat(code: ENOENT), mover: FailingMover()),
                .failed("missing or invalid trashURL"), "\(String(describing: url))")
        }
    }

    func test_valid_missing_trash_path_is_gone() {
        let entry = LogEntry(ts: Date(), action: "trash", path: "/fixture/file", pathB64: nil,
            inode: 1, bytes: 1, trashURL: "file:///fixture/trash", result: "ok")
        XCTAssertTrue(URL(string: entry.trashURL!)!.isFileURL)
        for code in [ENOENT, ENOTDIR] {
            XCTAssertEqual(putBack(entry, stat: MissingStat(code: code), mover: FailingMover()), .trashItemGone)
        }
        guard case .failed = putBack(entry, stat: MissingStat(code: EACCES), mover: FailingMover()) else {
            return XCTFail("Other stat failures must remain errors")
        }
    }

    func test_trash_item_gone() throws { try check("gone") }
    func test_trash_item_changed() throws { try check("changed") }
    func test_original_occupied() throws { try check("occupied") }
    func test_parent_missing() throws { try check("parent") }
    func test_move_failed() throws { try check("failed") }
    func test_restored_and_logged() throws { try check("restored") }
    func test_base64_path_restored() throws { try check("base64") }

    private func unsupportedRename(_ code: Int32 = ENOTSUP) -> ProductionMover {
        ProductionMover(renameExclusive: { _, _, flags in
            XCTAssertEqual(flags, UInt32(RENAME_EXCL))
            errno = code
            return -1
        })
    }

    func test_unsupported_exclusive_rename_refuses_collision_after_stat() throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        for code in [ENOTSUP, EINVAL] {
            let source = try f.file("source-\(code)")
            let destination = source.appendingPathExtension("restored")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let mover = ProductionMover(renameExclusive: { _, _, flags in
                XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                errno = code; return -1
            }, readStat: { path, info in
                XCTFail("Unsupported exclusive rename must never reach fallback stat or move")
                if String(cString: path) == destination.path {
                    // Deterministic arrival after an absence observation, before rename.
                    try! Data("new unselected file".utf8).write(to: destination)
                    errno = ENOENT; return -1
                }
                return Darwin.lstat(path, info)
            })
            XCTAssertThrowsError(try ContainedMover(fixtureRoot: f.root, inner: mover).move(source, to: destination)) {
                XCTAssertEqual(($0 as NSError).code, Int(code))
            }
            XCTAssertEqual(try Data(contentsOf: source), Data("fixture".utf8))
            if FileManager.default.fileExists(atPath: destination.path) {
                XCTAssertEqual(try Data(contentsOf: destination), Data("new unselected file".utf8))
            }
        }
    }

    final class RestoreProbe: FileStat, Mover, AuditSink, @unchecked Sendable {
        var calls = 0
        var uuid: String? = "volume-A"
        var device: Int32 = 7
        var directory = false
        var blocked: Data?
        var unreadable = false
        func volumeUUID(_ path: Data) -> String? { uuid }
        func lstat(_ path: Data) -> StatResult {
            if path == Data("/tree/parent/file".utf8) { return .error(errno: ENOENT) }
            if path == blocked {
                if unreadable { return .error(errno: EACCES) }
                return .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: 1, isSymlink: true)
            }
            return .ok(Observed(device: device, flags: 0,
                isDirectory: path == Data("/trash/parent/file".utf8) ? directory : true, linkCount: 1),
                fileID: 42, isSymlink: false)
        }
        func move(_ from: URL, to: URL) throws { calls += 1 }
        func append(_ e: LogEntry) -> Bool { true }
    }

    private func identityEntry() throws -> LogEntry {
        let e = LogEntry(ts: Date(), action: "trash", path: "/tree/parent/file", pathB64: nil,
            inode: 42, bytes: 7, trashURL: "file:///trash/parent/file", result: "ok")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(e)) as? [String: Any])
        json["volumeUUID"] = "volume-A"; json["device"] = 7; json["isDirectory"] = false
        return try JSONDecoder().decode(LogEntry.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_persisted_volume_device_and_type_identity_are_required() throws {
        let e = try identityEntry()
        let good = RestoreProbe()
        XCTAssertEqual(putBack(e, stat: good, mover: good, log: good), .restored)
        XCTAssertEqual(good.calls, 1, "positive control: same path and inode")
        for scenario in 0..<4 {
            let p = RestoreProbe()
            if scenario == 0 { p.uuid = "volume-B" }
            if scenario == 1 { p.device = 8 }
            if scenario == 2 { p.directory = true }
            if scenario == 3 { p.uuid = nil }
            XCTAssertNotEqual(putBack(e, stat: p, mover: p, log: p), .restored)
            XCTAssertEqual(p.calls, 0, "same paths and inode on replacement volume/type: \(scenario)")
        }
        let legacy = LogEntry(ts: e.ts, action: e.action, path: e.path, pathB64: nil,
            inode: e.inode, bytes: e.bytes, trashURL: e.trashURL, result: "ok")
        let p = RestoreProbe()
        XCTAssertEqual(putBack(legacy, stat: p, mover: p, log: p), .failed("can't verify this volume"))
        XCTAssertEqual(p.calls, 0)
    }

    func test_put_back_refuses_source_ancestor_and_destination_grandparent_symlinks_and_unreadable_ancestry() throws {
        let e = try identityEntry()
        for path in ["/trash", "/tree"] {
            for unreadable in [false, true] {
                let p = RestoreProbe(); p.blocked = Data(path.utf8); p.unreadable = unreadable
                XCTAssertNotEqual(putBack(e, stat: p, mover: p, log: p), .restored)
                XCTAssertEqual(p.calls, 0, "ancestry must fail closed: \(path)")
            }
        }
    }

    private func check(_ scenario: String) throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let log = ReclaimLog(directory: f.root.appendingPathComponent("audit"))
        let mover = ContainedMover(fixtureRoot: f.root, inner: ProductionMover())
        let stat = ProductionFileStat()
        do {
            let url = try f.file(scenario)
            guard case .ok(let observed, let inode, _) = stat.lstat(Data(url.path.utf8)) else { return XCTFail() }
            let trash = try ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()).trash(url)
            XCTAssertTrue(trash.pathComponents.starts(with: f.root.pathComponents))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let original = scenario == "parent" ? f.root.appendingPathComponent("absent/child") : url
            let e = LogEntry(ts: Date(timeIntervalSince1970: 1_800_000_000), action: "trash",
                path: scenario == "base64" ? nil : original.path,
                pathB64: scenario == "base64" ? Data(original.path.utf8).base64EncodedString() : nil,
                inode: scenario == "changed" ? inode + 1 : inode, device: observed.device,
                volumeUUID: stat.volumeUUID(Data(trash.path.utf8)), isDirectory: false, bytes: 7,
                trashURL: scenario == "gone" ? trash.appendingPathExtension("missing").absoluteString : trash.absoluteString, result: "ok")
            XCTAssertTrue(log.append(e))
            if scenario == "occupied" { try Data("occupied".utf8).write(to: url) }
            let selected: any Mover = scenario == "failed" ? ContainedMover(fixtureRoot: f.root, inner: FailingMover()) : mover
            let result = putBack(e, stat: stat, mover: selected, log: log)
            switch scenario {
            case "gone": XCTAssertEqual(result, .trashItemGone)
            case "changed": XCTAssertEqual(result, .trashItemChanged)
            case "occupied":
                XCTAssertEqual(result, .originalOccupied)
                XCTAssertEqual(try Data(contentsOf: url), Data("occupied".utf8))
            case "parent": XCTAssertEqual(result, .parentMissing)
            case "failed": guard case .failed = result else { return XCTFail("Expected move failure") }
            default:
                XCTAssertEqual(result, .restored)
                XCTAssertEqual(try Data(contentsOf: url), Data("fixture".utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
                guard case .ok(_, let restoredID, _) = stat.lstat(Data(url.path.utf8)) else { return XCTFail() }
                XCTAssertEqual(restoredID, inode)
                XCTAssertEqual(log.entries().last?.action, "putBack")
                XCTAssertFalse(log.restorableEntries().contains(e))
            }
        }
        XCTAssertEqual(log.entries().filter { $0.action == "putBack" }.count,
            ["restored", "base64"].contains(scenario) ? 1 : 0)
    }

    func test_production_move_refuses_overwrite_and_containment_refuses_escape() throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let a = try f.file("a"), b = try f.file("b")
        try Data("destination".utf8).write(to: b)
        let mover = ContainedMover(fixtureRoot: f.root, inner: ProductionMover())
        XCTAssertThrowsError(try mover.move(a, to: b))
        XCTAssertEqual(try Data(contentsOf: a), Data("fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("destination".utf8))
        for (from, to) in [(URL(fileURLWithPath: "/outside"), a), (a, URL(fileURLWithPath: "/outside"))] {
            XCTAssertThrowsError(try mover.move(from, to: to))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        let narrow = f.root.appendingPathComponent("restore/nested")
        try FileManager.default.createDirectory(at: narrow, withIntermediateDirectories: true)
        let recorded = ContainedMover(fixtureRoot: narrow, inner: ProductionMover(), allowedTrashURL: a)
        let outside = f.root.appendingPathComponent("outside")
        XCTAssertThrowsError(try recorded.move(a, to: outside), "allowlisted source never permits an outside destination")
        XCTAssertThrowsError(try recorded.move(b, to: narrow.appendingPathComponent("wrong-source")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        let restored = narrow.appendingPathComponent("restored")
        XCTAssertNoThrow(try recorded.move(a, to: restored))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.path))
    }
}
