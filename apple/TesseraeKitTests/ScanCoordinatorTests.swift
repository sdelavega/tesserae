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
        let root = try makeTree(dirs: 40, filesPer: 1000)  // 40,000 files
        let c = ScanCoordinator(progressInterval: 0.005)
        var seen: [ScanProgress] = []
        c.$state.sink { if case .scanning(let p) = $0 { seen.append(p) } }.store(in: &bag)
        var opts = TessScanOptions()
        opts.workers = 1  // slowest scan, so the tree spans several ticks
        c.start(root: root, options: opts)
        await wait(until: { self.isTerminal(c.state) }, "scan to finish")
        XCTAssertEqual(c.state, .finished)
        XCTAssertEqual(c.snapshot?.stats.files, 40_000)
        // Precondition: a real update arrived beyond the initial zero state.
        let live = seen.filter { $0.files + $0.dirs > 0 }
        XCTAssertFalse(live.isEmpty, "no progress publication arrived during the scan")
        XCTAssertTrue(live.contains { $0.entriesPerSecond > 0 })
        XCTAssertEqual(live.map(\.files), live.map(\.files).sorted(), "files must not go backwards")
        XCTAssertTrue(live.allSatisfy { $0.files <= 40_000 })
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
        let big = try makeTree(dirs: 100, filesPer: 400)  // 40,000 files
        let small = try makeTree(dirs: 2, filesPer: 3)
        let c = ScanCoordinator()
        var published: [Snapshot] = []
        var terminals: [ScanState] = []
        c.$snapshot.sink { if let s = $0 { published.append(s) } }.store(in: &bag)
        c.$state.sink { if self.isTerminal($0) { terminals.append($0) } }.store(in: &bag)

        var ended: [(snap: Snapshot?, gen: UInt64)] = []
        c.onScanEnded = { ended.append(($0, $1)) }

        c.start(root: big)
        guard case .scanning = c.state else { return XCTFail("first scan not running") }
        c.start(root: small)
        await wait(until: { self.isTerminal(c.state) }, "second scan to finish")
        // Let any stray late delivery from the first scan land.
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(c.state, .finished)
        // The first scan really was cancelled and finished before the second ended.
        XCTAssertEqual(ended.count, 2)
        let first = try XCTUnwrap(ended.first?.snap)
        XCTAssertEqual(first.stats.incomplete, UInt32(TESS_INCOMPLETE_CANCELLED))
        XCTAssertLessThan(first.stats.files, 40_000)
        XCTAssertEqual(first.path(first.root), big.path)
        XCTAssertEqual(terminals, [.finished], "exactly one terminal state, from the second scan")
        XCTAssertEqual(published.count, 1, "only the second scan's snapshot is ever published")
        let snap = try XCTUnwrap(c.snapshot)
        XCTAssertEqual(snap.path(snap.root), small.path)
        XCTAssertEqual(snap.stats.files, 6)
        XCTAssertEqual(snap.stats.incomplete, UInt32(TESS_INCOMPLETE_NONE))
    }

    func test_releasing_the_coordinator_cancels_its_scan() async throws {
        let root = try makeTree(dirs: 100, filesPer: 400)  // 40,000 files
        var ended: [Snapshot?] = []
        var c: ScanCoordinator? = ScanCoordinator()
        c?.onScanEnded = { snap, _ in ended.append(snap) }
        c?.start(root: root)
        guard case .scanning = c?.state else { return XCTFail("not scanning after start") }
        c = nil
        await wait(until: { !ended.isEmpty }, "the orphaned scan to be finished")
        let snap = try XCTUnwrap(ended.first ?? nil)
        XCTAssertEqual(snap.stats.incomplete, UInt32(TESS_INCOMPLETE_CANCELLED))
        XCTAssertLessThan(snap.stats.files, 40_000)
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
