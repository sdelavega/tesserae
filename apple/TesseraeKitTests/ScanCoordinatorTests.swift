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

import Combine
import Darwin
import Foundation
import TesseraeFFI
import XCTest

@testable import TesseraeKit

@MainActor
final class ScanCoordinatorTests: XCTestCase {
    private var cleanup: [URL] = []
    private var bag: [AnyCancellable] = []

    override func tearDown() async throws {
        bag = []
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
    }

    /// `dirs` directories of `filesPer` small files each, under a fresh root.
    private func makeTree(dirs: Int, filesPer: Int) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tess-coord-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        let payload = Data(repeating: 0x41, count: 100)
        for d in 0..<dirs {
            let dir = root.appendingPathComponent("d\(d)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            for f in 0..<filesPer {
                XCTAssertTrue(
                    fm.createFile(atPath: dir.appendingPathComponent("f\(f)").path, contents: payload))
            }
        }
        return root
    }

    /// Wait until `done` holds (polled on the main actor) or fail after `seconds`.
    private func wait(_ seconds: Double = 30, until done: () -> Bool, _ what: String) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(done(), "timed out waiting for \(what)")
    }

    private func isTerminal(_ s: ScanState) -> Bool {
        switch s {
        case .finished, .failed: return true
        default: return false
        }
    }

    func test_scan_of_a_temp_tree_finishes_with_matching_totals() async throws {
        let root = try makeTree(dirs: 3, filesPer: 4)
        let c = ScanCoordinator()
        XCTAssertEqual(c.state, .idle)
        XCTAssertNil(c.snapshot)
        c.start(root: root)
        await wait(until: { self.isTerminal(c.state) }, "scan to finish")
        XCTAssertEqual(c.state, .finished)
        let snap = try XCTUnwrap(c.snapshot)
        XCTAssertEqual(snap.stats.files, 12)
        XCTAssertEqual(snap.stats.dirs, 4)  // root + 3
        XCTAssertEqual(snap.stats.incomplete, UInt32(TESS_INCOMPLETE_NONE))
        XCTAssertEqual(snap.path(snap.root), root.path)
    }

    func test_progress_is_published_while_scanning() async throws {
        let fake = FakeScan()
        let c = ScanCoordinator(progressInterval: 0.01, factory: { _, _ in fake })
        var seen: [ScanProgress] = []
        c.$state.sink { if case .scanning(let p) = $0 { seen.append(p) } }.store(in: &bag)
        c.start(root: URL(fileURLWithPath: "/fake"))
        // The test, not the scan's speed, decides what progress the scan reports.
        for step in 1...4 {
            let files = UInt64(step) * 1000
            fake.report(dirs: UInt64(step), files: files, bytes: files * 100)
            await wait(until: { seen.last?.files == files }, "progress for \(files) files")
        }
        XCTAssertEqual(c.state, .scanning(seen.last!), "still scanning while the fake runs")
        fake.finishNow()
        await wait(until: { self.isTerminal(c.state) }, "scan to finish")
        XCTAssertEqual(c.state, .finished)
        let live = seen.filter { $0.files > 0 }
        XCTAssertGreaterThanOrEqual(live.count, 4)
        XCTAssertEqual(live.map(\.files), live.map(\.files).sorted(), "files must not go backwards")
        XCTAssertTrue(live.contains { $0.entriesPerSecond > 0 })
        XCTAssertEqual(seen.last?.bytes, 400_000)
    }

    func test_cancel_returns_a_partial_snapshot_flagged_cancelled() async throws {
        let root = try makeTree(dirs: 100, filesPer: 400)  // 40,000 files
        let c = ScanCoordinator()
        c.start(root: root)
        guard case .scanning = c.state else { return XCTFail("not scanning after start") }
        c.cancel()
        await wait(until: { self.isTerminal(c.state) }, "cancelled scan to deliver")
        XCTAssertEqual(c.state, .finished)
        let snap = try XCTUnwrap(c.snapshot)
        XCTAssertEqual(snap.stats.incomplete, UInt32(TESS_INCOMPLETE_CANCELLED))
        XCTAssertLessThan(snap.stats.files, 40_000, "scan completed before the cancel took effect")
    }

    func test_missing_root_fails_with_enoent() async throws {
        let c = ScanCoordinator()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tess-missing-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        c.start(root: missing)
        await wait(until: { self.isTerminal(c.state) }, "scan to fail")
        XCTAssertEqual(c.state, .failed(errno: ENOENT))
        XCTAssertNil(c.snapshot)
    }

    func test_restart_cancels_the_previous_scan_and_never_mixes_snapshots() async throws {
        let first = FakeScan(tag: 1, finishOnCancel: true)
        let second = FakeScan(tag: 2)
        let begun = Locked<[URL]>([])
        let fakes = ["/first": first, "/second": second]
        let c = ScanCoordinator(progressInterval: 0.01) { url, _ in
            begun.mutate { $0.append(url) }
            return fakes[url.path]
        }
        var published: [Snapshot] = []
        var terminals: [ScanState] = []
        var ended: [UInt32?] = []
        c.$snapshot.sink { if let s = $0 { published.append(s) } }.store(in: &bag)
        c.$state.sink { if self.isTerminal($0) { terminals.append($0) } }.store(in: &bag)
        c.onScanEnded = { snap, _ in ended.append(snap?.root) }

        c.start(root: URL(fileURLWithPath: "/first"))
        XCTAssertTrue(c.hasLiveHandle)
        c.start(root: URL(fileURLWithPath: "/second"))
        // The first is cancelled and finished before the second even begins.
        await wait(until: { ended.count == 1 }, "first scan to end")
        XCTAssertTrue(first.wasCancelled)
        XCTAssertEqual(ended, [1])
        await wait(until: { begun.value.count == 2 }, "second scan to begin")
        XCTAssertEqual(c.state, .scanning(ScanProgress()))
        XCTAssertNil(c.snapshot, "nothing from the first scan is published")
        second.finishNow()
        await wait(until: { self.isTerminal(c.state) }, "second scan to finish")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(ended, [1, 2])
        XCTAssertFalse(second.wasCancelled)
        XCTAssertEqual(terminals, [.finished], "exactly one terminal state, from the second scan")
        XCTAssertEqual(published.map(\.root), [2], "only the second scan's snapshot is published")
    }

    func test_releasing_the_coordinator_cancels_its_scan() async throws {
        let fake = FakeScan(tag: 7, finishOnCancel: true)
        var ended: [UInt32?] = []
        var c: ScanCoordinator? = ScanCoordinator(factory: { _, _ in fake })
        c?.onScanEnded = { snap, _ in ended.append(snap?.root) }
        c?.start(root: URL(fileURLWithPath: "/fake"))
        XCTAssertFalse(fake.wasCancelled)
        c = nil
        XCTAssertTrue(fake.wasCancelled, "deinit must cancel the scan")
        await wait(until: { !ended.isEmpty }, "the orphaned scan to be finished")
        XCTAssertEqual(ended, [7], "the orphaned handle is still finished exactly once")
    }

    func test_a_second_scan_after_the_first_finished_begins_at_once() async throws {
        let root = try makeTree(dirs: 2, filesPer: 3)
        let c = ScanCoordinator()
        c.start(root: root)
        await wait(until: { self.isTerminal(c.state) }, "first scan")
        c.start(root: root)
        // Begun synchronously: a finished scan leaves nothing in flight.
        XCTAssertTrue(c.hasLiveHandle, "second scan was not begun synchronously")
        await wait(until: { self.isTerminal(c.state) }, "second scan")
        XCTAssertEqual(c.snapshot?.stats.files, 6)
    }
}

/// A small lock-protected value, shared with the nonisolated factory.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return v
    }
    func mutate(_ f: (inout T) -> Void) {
        lock.lock()
        f(&v)
        lock.unlock()
    }
}

/// A scan the test drives: it stays running until `finishNow()` (or, with
/// `finishOnCancel`, until cancelled) and reports whatever `report` says.
private final class FakeScan: ScanDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var cancelled = false
    private var prog = TessProgress()
    private let tag: UInt32
    private let finishOnCancel: Bool

    init(tag: UInt32 = 0, finishOnCancel: Bool = false) {
        self.tag = tag
        self.finishOnCancel = finishOnCancel
    }

    func report(dirs: UInt64, files: UInt64, bytes: UInt64) {
        lock.lock()
        prog = TessProgress(dirs_done: dirs, files_done: files, bytes_seen: bytes, errors: 0)
        lock.unlock()
    }

    func finishNow() {
        lock.lock()
        running = false
        lock.unlock()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func progress() -> TessProgress? {
        lock.lock()
        defer { lock.unlock() }
        return prog
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if finishOnCancel { running = false }
        lock.unlock()
    }

    func status() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return running ? Int32(TESS_STATUS_RUNNING) : Int32(TESS_STATUS_FINISHED)
    }

    /// An empty snapshot whose `root` carries the tag.
    func finish() -> Snapshot? {
        Snapshot(
            testingNodes: UnsafeBufferPointer<TessNode>(start: nil, count: 0),
            names: UnsafeRawBufferPointer(start: nil, count: 0), root: tag)
    }
}
