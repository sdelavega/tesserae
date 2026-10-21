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

final class JettisonLogTests: XCTestCase, @unchecked Sendable {
    private func entry(_ n: UInt64, action: String = "trash", result: String = "ok", raw: Bool = false) -> LogEntry {
        LogEntry(ts: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), action: action,
            path: raw ? nil : "/fixture/f\(n)", pathB64: raw ? Data([47, 255]).base64EncodedString() : nil,
            inode: n, bytes: 42, trashURL: "file:///fixture/.Trashes/f\(n)", result: result)
    }

    func test_canonical_stores_share_failure_state() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a directory".utf8).write(to: dir)
        let a = JettisonLog(directory: dir), b = JettisonLog(directory: dir)
        XCTAssertFalse(a.lastWriteFailed); XCTAssertFalse(b.lastWriteFailed)
        XCTAssertFalse(a.append(entry(0)))
        XCTAssertTrue(a.lastWriteFailed); XCTAssertTrue(b.lastWriteFailed)
    }

    func test_two_stores_coordinate_rotation_and_reads_with_directory_flock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = JettisonLog(directory: dir, maxBytes: 1, keep: 100)
        let b = JettisonLog(directory: dir.appendingPathComponent("."), maxBytes: 1, keep: 100)
        XCTAssertTrue(a.append(entry(0)))
        let fd = open(dir.appendingPathComponent("jettison.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let began = DispatchSemaphore(value: 0), appended = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        let row = entry(1)
        DispatchQueue.global().async { began.signal(); XCTAssertTrue(b.append(row)); appended.signal() }
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(appended.wait(timeout: .now() + 0.15), .timedOut, "append must wait for directory lock")
        DispatchQueue.global().async { _ = a.entries(); read.signal() }
        XCTAssertEqual(read.wait(timeout: .now() + 0.15), .timedOut, "read must not interleave rotation")
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(appended.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(read.wait(timeout: .now() + 3), .success)
        let rows = (2...41).map { entry(UInt64($0)) }
        DispatchQueue.concurrentPerform(iterations: rows.count) { i in
            XCTAssertTrue((i.isMultiple(of: 2) ? a : b).append(rows[i]))
        }
        XCTAssertEqual(a.entries().count, 42)
        XCTAssertEqual(Set(a.entries().map(\.inode)), Set(0...41))
        XCTAssertEqual(a.entries(), b.entries())
    }

    func test_existing_log_directory_is_tightened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let log = JettisonLog(directory: dir)
        XCTAssertTrue(log.append(entry(1)))
        XCTAssertFalse(log.lastWriteFailed)
        XCTAssertEqual(log.entries(), [entry(1)])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func test_json_lines_rotation_round_trip_and_recent_entries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let first = entry(9), second = entry(10)
        let exactBytes = try encoder.encode(first).count + encoder.encode(second).count + 2
        let boundaryDir = dir.appendingPathExtension("boundary")
        defer { try? FileManager.default.removeItem(at: boundaryDir) }
        let boundary = JettisonLog(directory: boundaryDir, maxBytes: exactBytes)
        XCTAssertTrue(boundary.append(first)); XCTAssertTrue(boundary.append(second))
        XCTAssertEqual(boundary.entries(), [first, second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundaryDir.appendingPathComponent("jettison.log.1").path))
        XCTAssertTrue(boundary.append(entry(11)))
        XCTAssertEqual(boundary.entries(), [first, second, entry(11)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundaryDir.appendingPathComponent("jettison.log.1").path))
        let log = JettisonLog(directory: dir, maxBytes: 1, keep: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let rows = [entry(1), entry(2, raw: true), entry(3)]
        for row in rows { XCTAssertTrue(log.append(row)) }
        XCTAssertFalse(log.lastWriteFailed)
        XCTAssertEqual(log.entries(), rows)
        let line = try String(contentsOf: dir.appendingPathComponent("jettison.log.1"), encoding: .utf8)
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["pathB64"] as? String, Data([47, 255]).base64EncodedString())
        XCTAssertNil(json["path"])
        XCTAssertTrue((json["ts"] as? String)?.hasSuffix("Z") == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        XCTAssertEqual(log.restorableEntries(), rows.reversed())
        XCTAssertTrue(log.append(entry(3, action: "putBack")))
        XCTAssertEqual(log.restorableEntries(), [rows[1], rows[0]])
        XCTAssertTrue(log.append(entry(4, result: "failed:5")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
            ["jettison.lock", "jettison.log", "jettison.log.1", "jettison.log.2", "jettison.log.3"])
        XCTAssertEqual(JettisonLog(directory: dir).entries(), [rows[1], rows[2], entry(3, action: "putBack"), entry(4, result: "failed:5")])
        XCTAssertEqual(log.restorableEntries(), [rows[1]])
    }

    func test_failed_write_is_surfaced_and_executor_still_trashes() async throws {
        let f = DiskImageFixture()
        try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let dir = f.root.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(dir.path, 0o500), 0)
        defer { _ = chmod(dir.path, 0o700) }
        let log = JettisonLog(directory: dir)
        XCTAssertFalse(log.append(entry(0)))
        XCTAssertTrue(log.lastWriteFailed)
        let url = try f.file("logged")
        let raw = Data(url.path.utf8)
        guard case .ok(let o, let id, _) = ProductionFileStat().lstat(raw) else { return XCTFail() }
        let item = JetsamItem(nodeIndex: 0, path: raw, recorded: Recorded(fileID: id, device: o.device,
            isDirectory: false), recordedSize: 7, verdict: .ok)
        let ctx = GuardContext(scanRoot: Data(f.root.path.utf8), volumeRoot: Data(f.root.path.utf8),
            scanRootDevice: o.device, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8))
        let r = await Executor(trasher: ContainedTrasher(fixtureRoot: f.root, inner: ProductionTrasher()),
            stat: ProductionFileStat(), log: log, context: ctx).run([item], confirmedWarnings: [])
        guard case .trashed(let trash) = r.outcomes[0].1 else { return XCTFail("Logging must not prevent trash") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertTrue(log.lastWriteFailed)
        XCTAssertEqual(chmod(dir.path, 0o700), 0)
        XCTAssertTrue(log.append(entry(1)))
        XCTAssertFalse(log.lastWriteFailed)
    }
}
