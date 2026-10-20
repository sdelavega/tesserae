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

import AppKit
import Combine
import Metal
import TesseraeFFI
import XCTest
@testable import TesseraeKit

@MainActor
final class AppModelTests: XCTestCase {
    func test_banner_text_for_every_incomplete_code() throws {
        let cases: [(UInt32, String)] = [
            (UInt32(TESS_INCOMPLETE_NONE), ""),
            (UInt32(TESS_INCOMPLETE_CANCELLED), "cancelled"),
            (UInt32(TESS_INCOMPLETE_NODE_BUDGET), "node limit"),
            (UInt32(TESS_INCOMPLETE_OUT_OF_MEMORY), "memory"),
            (UInt32(TESS_INCOMPLETE_STALLED), "stalled"),
            (UInt32(TESS_INCOMPLETE_FD_EXHAUSTED), "file descriptors"),
            (UInt32(TESS_INCOMPLETE_MALFORMED_BATCH), "malformed"),
            (UInt32(TESS_INCOMPLETE_VOLUME_LOST), "volume"),
        ]
        XCTAssertEqual(cases.count, 8)
        for (code, word) in cases {
            var stats = TessScanStats()
            stats.incomplete = code
            let text = ScanBanner.text(for: stats, stalledAt: "/blocked/path")
            if code == 0 { XCTAssertNil(text); continue }
            let message = try XCTUnwrap(text)
            XCTAssertTrue(message.lowercased().contains(word), message)
            XCTAssertTrue(message.contains("Partial"), message)
            if code == UInt32(TESS_INCOMPLETE_STALLED) { XCTAssertTrue(message.contains("/blocked/path")) }
        }
        var unknown = TessScanStats()
        unknown.incomplete = 999
        XCTAssertNotNil(ScanBanner.text(for: unknown, stalledAt: nil))
    }

    func test_banner_mentions_unreadable_and_errors_when_complete() throws {
        var stats = TessScanStats()
        stats.errors = 17
        stats.unreadable_count = 23
        let text = try XCTUnwrap(ScanBanner.text(for: stats, stalledAt: nil))
        XCTAssertTrue(text.contains("17 errors"), text)
        XCTAssertTrue(text.contains("23 unreadable"), text)
        stats.errors = 0
        XCTAssertNotNil(ScanBanner.text(for: stats, stalledAt: nil))
        stats.errors = 17
        stats.unreadable_count = 0
        XCTAssertNotNil(ScanBanner.text(for: stats, stalledAt: nil))
    }

    func test_empty_scan_shows_empty_state() throws {
        let tree = TestSnapshot(.dir("/empty", []))
        let app = AppModel()
        app.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 600, height: 400))
        XCTAssertTrue(session.tiles.isEmpty)
        XCTAssertTrue(session.isEmpty)
        let denied = TestSnapshot(.denied("/denied"))
        app.replaceSnapshot(denied.snapshot)
        let unreadable = try XCTUnwrap(app.session)
        unreadable.resize(to: CGSize(width: 600, height: 400))
        XCTAssertEqual(unreadable.tiles.count, 1)
        XCTAssertFalse(unreadable.isEmpty, "permission denial is not an empty folder")
        // Not empty, but nothing allocated: dataless (evicted) files or hardlink duplicates counted once elsewhere.
        let zero = TestSnapshot(.dir("/zero", [.file("dataless", 0, logical: 4096), .file("duplicate", 0, logical: 100)]))
        XCTAssertEqual(zero.snapshot.children(zero.snapshot.root).count, 2, "precondition: the folder has entries")
        app.replaceSnapshot(zero.snapshot)
        let unallocated = try XCTUnwrap(app.session)
        unallocated.resize(to: CGSize(width: 600, height: 400))
        XCTAssertTrue(unallocated.tiles.isEmpty)
        XCTAssertTrue(unallocated.isEmpty, "entries with no allocated bytes have nothing to draw")
    }

    func test_rescan_swaps_snapshot_atomically() async throws {
        var a: TestSnapshot? = TestSnapshot(.dir("/A", [.dir("sub", [.file("a", 20), .file("b", 10)])]))
        let b = TestSnapshot(.dir("/B", [.file("only", 100)]))
        let app = AppModel()
        app.replaceSnapshot(try XCTUnwrap(a).snapshot)
        weak let oldSnapshot = a?.snapshot
        var old: AppSession? = try XCTUnwrap(app.session)
        let sub = try XCTUnwrap(a)["sub"], fileB = try XCTUnwrap(a)["b"]
        try XCTUnwrap(old).resize(to: CGSize(width: 600, height: 400))
        try XCTUnwrap(old).navigator.descend(into: sub)
        try XCTUnwrap(old).selection.nodes = [fileB]
        let bTile = try XCTUnwrap(old?.tiles.firstIndex { $0.node == fileB })
        try XCTUnwrap(old).hover(tile: bTile)
        // The renderer completed navigation before this rescan.
        try XCTUnwrap(old).setZoomRunning(false, generation: try XCTUnwrap(old).layoutGeneration)
        await old?.waitForTable()
        await old?.waitForLabels()
        XCTAssertNotNil(old?.inspector)
        XCTAssertFalse(try XCTUnwrap(old).table.rows.isEmpty)
        XCTAssertFalse(try XCTUnwrap(old).selection.nodes.isEmpty)
        var sawNew = false
        let observation = app.$session.dropFirst().sink { session in
            guard let session else { return XCTFail("replacement must be a session") }
            sawNew = true
            XCTAssertTrue(session.snapshot === b.snapshot)
            XCTAssertEqual(session.navigator.root, b.snapshot.root)
            XCTAssertTrue(session.selection.nodes.isEmpty)
            XCTAssertNil(session.inspector)
            XCTAssertNil(session.table.content)
            XCTAssertTrue(session.tiles.isEmpty)
        }
        app.replaceSnapshot(b.snapshot)
        XCTAssertTrue(sawNew)
        withExtendedLifetime(observation) {}
        let current = try XCTUnwrap(app.session)
        current.resize(to: CGSize(width: 600, height: 400))
        await current.waitForTable()
        XCTAssertTrue(try XCTUnwrap(current.table.content).snapshot === b.snapshot)
        XCTAssertEqual(current.table.rows, [b["only"]])
        XCTAssertNil(current.inspector, "precondition: nothing has hovered the new session")
        old?.hover(tile: bTile)
        XCTAssertNotNil(old?.inspector, "precondition: the old session still answers its own hover")
        XCTAssertNil(current.inspector, "old callbacks cannot change the new session")
        XCTAssertNotNil(oldSnapshot, "precondition: the old session still owns its snapshot")
        old = nil
        a = nil
        XCTAssertNil(oldSnapshot, "the replaced session releases the old snapshot")
    }

    func test_navigation_relayouts_and_selection_reaches_tiles() throws {
        let tree = TestSnapshot(.dir("/R", [.dir("sub", [.file("one", 20), .file("two", 10)])]))
        let app = AppModel()
        app.replaceSnapshot(tree.snapshot)
        let s = try XCTUnwrap(app.session)
        s.resize(to: CGSize(width: 600, height: 400))
        XCTAssertEqual(s.tiles.first?.node, tree.snapshot.root)
        s.navigator.descend(into: tree["sub"])
        XCTAssertEqual(s.tiles.first?.node, tree["sub"])
        s.selection.nodes = [tree["two"]]
        let selected = s.tiles.filter { $0.flags & Tile.Flag.selected != 0 }
        XCTAssertEqual(selected.map(\.node), [tree["two"]])
        s.resize(to: .zero)
        XCTAssertTrue(s.tiles.isEmpty)
        s.resize(to: CGSize(width: 500, height: 300))
        XCTAssertEqual(s.tiles.first?.node, tree["sub"])
    }

    func test_focus_legend_has_voiceover_labels() {
        let app = AppModel()
        app.toggleFocus(.video)
        app.toggleFocus(.images)
        app.toggleFocus(.audio)
        app.toggleFocus(.archives)
        XCTAssertEqual(app.focusKinds, [.video, .images, .audio])
        let legend = app.focusLegend(dark: false)
        XCTAssertEqual(legend.count, 4, "three kinds plus the neutral category")
        XCTAssertEqual(legend.map(\.accessibilityLabel), ["Video files", "Image files", "Audio files", "Other files and folders"])
        XCTAssertEqual(legend.prefix(3).map(\.colour), Array(Palette.colours(.typeFocus(app.focusKinds), dark: false).dropFirst(2)))
        app.toggleFocus(.images)
        XCTAssertEqual(app.focusKinds, [.video, .audio])
    }

    func test_frame_capture_rejects_late_callbacks_and_keeps_duration_units() throws {
        let timer = FrameTimer(enabled: true)
        timer.startCapture()
        let stale = timer.begin("encode", at: 10)
        timer.startCapture()
        timer.end(stale, at: 100)
        XCTAssertTrue(timer.samples.isEmpty, "callbacks from an earlier capture cannot contaminate this one")
        let first = timer.begin("encode", at: 100)
        timer.end(first, at: 100.002)
        let second = timer.begin("encode", at: 101)
        timer.end(second, at: 101.020)
        let samples = timer.samples
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].seconds, 0.002, accuracy: 1e-10)
        XCTAssertEqual(samples[1].seconds, 0.020, accuracy: 1e-10)
        XCTAssertEqual(FrameTimer.percentile99(samples.map(\.seconds)), 0.020, accuracy: 1e-10)
    }

    func test_frame_gate_configuration_comes_from_the_environment_in_every_build() throws {
        let tmp = URL(fileURLWithPath: "/private/tmp/gate-test", isDirectory: true)
        let off = try FrameGateConfiguration(environment: [:], temporaryDirectory: tmp)
        XCTAssertFalse(off.timingEnabled)
        XCTAssertNil(off.autorunRoot)
        XCTAssertEqual(off.output.path, "/private/tmp/gate-test/tesserae-frame-gate.json")
        XCTAssertFalse(try FrameGateConfiguration(environment: ["TESSERAE_FRAME_TIMING": "yes"], temporaryDirectory: tmp).timingEnabled)
        let on = try FrameGateConfiguration(
            environment: [
                "TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": "/System/Volumes/Data",
                "TESSERAE_FRAME_GATE_OUT": "/Users/someone/gate.json",
            ], temporaryDirectory: tmp)
        XCTAssertTrue(on.timingEnabled)
        XCTAssertEqual(on.autorunRoot?.path, "/System/Volumes/Data")
        XCTAssertEqual(on.output.path, "/Users/someone/gate.json")
        XCTAssertNil(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": ""], temporaryDirectory: tmp).autorunRoot)
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_AUTORUN": "relative/root"], temporaryDirectory: tmp))
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_GATE_AUTORUN": "/System/Volumes/Data"], temporaryDirectory: tmp),
            "autorun measures nothing without timing")
        XCTAssertThrowsError(try FrameGateConfiguration(
            environment: ["TESSERAE_FRAME_TIMING": "1", "TESSERAE_FRAME_GATE_OUT": "gate.json"], temporaryDirectory: tmp))
        // Debug builds no longer record unless asked to: the same variable decides in every configuration.
        XCTAssertEqual(FrameTimer.shared.isEnabled, ProcessInfo.processInfo.environment["TESSERAE_FRAME_TIMING"] == "1")
        XCTAssertFalse(FrameTimer(enabled: false).isEnabled)
    }

    func test_frame_gate_timeout_from_the_environment() throws {
        let tmp = URL(fileURLWithPath: "/private/tmp/gate-test", isDirectory: true)
        XCTAssertEqual(try FrameGateConfiguration(environment: [:], temporaryDirectory: tmp).timeout, .seconds(900))
        XCTAssertEqual(
            try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": "120"], temporaryDirectory: tmp).timeout,
            .seconds(120))
        XCTAssertEqual(
            try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": "2.5"], temporaryDirectory: tmp).timeout,
            .milliseconds(2500))
        for bad in ["0", "-5", "soon", "nan", "inf"] {
            XCTAssertThrowsError(
                try FrameGateConfiguration(environment: ["TESSERAE_FRAME_GATE_TIMEOUT": bad], temporaryDirectory: tmp), bad)
        }
    }

    func test_frame_gate_deadline_bounds_every_wait() async throws {
        let clock = ContinuousClock()
        // A condition that never holds: the wait gives up at the deadline, not later.
        let short = FrameGateDeadline(after: .milliseconds(150))
        XCTAssertFalse(short.isExpired(), "precondition")
        let start = clock.now
        let ended = expectation(description: "the wait ended")
        var met: Bool?
        // In a task, so a wait that ignored its deadline fails here instead of hanging the suite.
        let waiting = Task { @MainActor in
            met = await short.wait(every: .milliseconds(20)) { false }
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 2)
        waiting.cancel()
        let waited = clock.now - start
        XCTAssertEqual(met, false)
        XCTAssertTrue(short.isExpired())
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(140))
        XCTAssertLessThan(waited, .seconds(2), "the wait ends at the deadline")
        // Once expired, later waits fail at once: one deadline covers every stage.
        let again = clock.now
        let late = await short.wait { false }
        XCTAssertFalse(late)
        XCTAssertLessThan(clock.now - again, .milliseconds(100))
        // A condition that holds returns true, including one that becomes true later.
        let long = FrameGateDeadline(after: .seconds(10))
        let alreadyMet = await long.wait { true }
        XCTAssertTrue(alreadyMet)
        var polls = 0
        let laterMet = await long.wait(every: .milliseconds(5)) { polls += 1; return polls >= 3 }
        XCTAssertTrue(laterMet)
        XCTAssertEqual(polls, 3)
        // An expired deadline fails even a condition that holds: one deadline ends every stage.
        let expired = FrameGateDeadline(after: .zero)
        XCTAssertTrue(expired.isExpired())
        let metLate = await expired.wait { true }
        XCTAssertFalse(metLate)
    }

    func test_phase_gate_cancel_stops_the_run_without_writing_a_capture() async throws {
        let t = TestSnapshot(.dir("/gate", (1...5).map { .dir("d\($0)", [.file("f\($0)", UInt64(10 * $0))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.setZoomRunning(true, generation: session.layoutGeneration)  // each transition would take 3 s
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(100))
        let done = expectation(description: "gate stopped")
        var outcome: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/gate", minimumNodes: 0, output: output) {
            outcome = $0
            done.fulfill()
        }
        XCTAssertTrue(runner.isRunning, "precondition")
        try await Task.sleep(for: .milliseconds(50))
        runner.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(outcome, .failed("The frame gate was cancelled."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancelled run writes nothing")
    }

    func test_phase_gate_runs_the_protocol_on_the_requested_root_and_writes_the_capture() async throws {
        let dirs = ["d1", "d2", "d3", "d4", "d5", "d6"]
        let t = TestSnapshot(.dir("/gate", dirs.enumerated().map { i, d in .dir(d, [.file("\(d).bin", UInt64(100 - i))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(1))

        var refused: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/elsewhere", minimumNodes: 0, output: output) { refused = $0 }
        guard case .failed(let reason)? = refused else { return XCTFail("a different root must be refused") }
        XCTAssertTrue(reason.contains("/elsewhere"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let done = expectation(description: "gate finished")
        var outcome: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/gate/", minimumNodes: 0, output: output) {
            outcome = $0
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(outcome, .saved(output))
        XCTAssertEqual(session.navigator.root, t.snapshot.root)
        struct Capture: Decodable {
            let root: String, build: String, nodes: Int, directories: [String], settleTimeouts: Int
            let samples: [FrameTimer.Sample]
        }
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: output))
        XCTAssertEqual(capture.root, "/gate")
        XCTAssertEqual(capture.directories, ["d1", "d2", "d3", "d4", "d5"], "the five largest readable root directories")
        XCTAssertEqual(capture.nodes, t.snapshot.nodes.count)
        XCTAssertEqual(capture.settleTimeouts, 0, "no treemap view, so every transition settles at once")
        #if DEBUG
        XCTAssertEqual(capture.build, "Debug")
        #else
        XCTAssertEqual(capture.build, "Release")
        #endif
    }

    func test_phase_gate_rejects_a_run_whose_zooms_never_finish() async throws {
        let t = TestSnapshot(.dir("/gate", (1...5).map { .dir("d\($0)", [.file("f\($0)", UInt64(10 * $0))]) }))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        // A view that never draws never ends its zoom.
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.zoomRunning, "precondition")
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let runner = PhaseGateRunner(timer: FrameTimer(enabled: true), pause: .milliseconds(1))
        let done = expectation(description: "gate finished")
        var outcome: PhaseGateRunner.Outcome?
        runner.run(session: session, requiredRoot: "/gate", minimumNodes: 0, output: output) {
            outcome = $0
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        guard case .failed(let reason)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(reason.contains("not a valid run"), reason)
        struct Capture: Decodable { let settleTimeouts: Int }
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: output))
        XCTAssertEqual(capture.settleTimeouts, 30, "the evidence is kept, and says why it is invalid")
    }

    func test_return_zoom_shrinks_the_old_root_into_its_parent_tile() throws {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let target = CGRect(x: 100, y: 50, width: 200, height: 300)
        let child = [Tile(rect: viewport, node: 7, depth: 0)]
        let parent = [Tile(rect: viewport, node: 0, depth: 0), Tile(rect: target, node: 7, depth: 1)]
        let from = try XCTUnwrap(TreemapView.navigationZoomRect(old: child, new: parent, viewport: viewport))
        let animation = ZoomAnimation(from: from, viewport: viewport)
        XCTAssertFalse(animation.isFinished)
        let result = viewport.applying(animation.transform(at: animation.duration))
        XCTAssertEqual(result.minX, target.minX, accuracy: 1e-8)
        XCTAssertEqual(result.minY, target.minY, accuracy: 1e-8)
        XCTAssertEqual(result.width, target.width, accuracy: 1e-8)
        XCTAssertEqual(result.height, target.height, accuracy: 1e-8)
        XCTAssertEqual(TreemapView.navigationZoomRect(old: parent, new: child, viewport: viewport), target)
        XCTAssertNil(TreemapView.navigationZoomRect(old: parent, new: parent, viewport: viewport))
        // A resize between the layouts cancels the zoom, as `cancelPendingZoom` does for a descend:
        // the old rects belong to the pre-resize viewport.
        let resized = CGRect(x: 0, y: 0, width: 700, height: 500)
        let resizedParent = [Tile(rect: resized, node: 0, depth: 0), Tile(rect: target, node: 7, depth: 1)]
        let resizedChild = [Tile(rect: resized, node: 7, depth: 0)]
        XCTAssertNotNil(TreemapView.navigationZoomRect(old: child, new: parent, viewport: viewport), "precondition")
        XCTAssertNil(TreemapView.navigationZoomRect(old: child, new: resizedParent, viewport: resized))
        XCTAssertNil(TreemapView.navigationZoomRect(old: parent, new: resizedChild, viewport: resized))
    }

    func test_navigation_defers_labels_and_table_until_zoom_settles() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        let oldGeneration = session.layoutGeneration
        session.navigator.descend(into: t["sub"])
        session.setZoomRunning(false, generation: oldGeneration)
        XCTAssertEqual(session.tiles.first?.node, t["sub"])
        XCTAssertTrue(session.labels.isEmpty, "do not measure labels on the navigation critical path")
        await session.waitForTable()
        XCTAssertNil(session.table.content, "defer table traversal and publication during motion")
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.labels.isEmpty)
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertEqual(Set(session.table.rows), [t["large"], t["small"]])
        session.navigator.ascend()
        XCTAssertTrue(session.labels.isEmpty)
        // A fallback or cancelled animation settles without starting.
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty)
        XCTAssertFalse(session.table.rows.isEmpty)
        session.navigator.descend(into: t["empty"])
        await session.waitForTable()
        XCTAssertTrue(session.isEmpty)
        XCTAssertNotNil(session.table.content, "an empty folder has no renderer to send a completion callback")
        XCTAssertTrue(session.table.rows.isEmpty)
    }

    func test_leaving_an_empty_folder_settles_labels_and_table() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty, "precondition")
        session.navigator.descend(into: t["empty"])
        XCTAssertTrue(session.isEmpty, "precondition: the view shows the empty state, with no treemap")
        await session.waitForTable()
        XCTAssertNotNil(session.table.content, "precondition: the empty folder settled")
        session.navigator.ascend()
        // The rebuilt treemap reports nothing: makeNSView installed these tiles,
        // so its first update sees no change and no zoom.
        XCTAssertFalse(session.isEmpty)
        await session.waitForTable()
        await session.waitForLabels()
        XCTAssertFalse(session.zoomRunning)
        XCTAssertFalse(session.labels.isEmpty, "labels must not stay pending after leaving an empty folder")
        XCTAssertNotNil(session.table.content, "the table must not stay pending after leaving an empty folder")
        XCTAssertFalse(session.table.rows.isEmpty)
    }

    func test_tearing_the_treemap_down_mid_zoom_clears_zoom_running() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80)]), .dir("empty", [])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.setZoomRunning(true, generation: session.layoutGeneration)
        XCTAssertTrue(session.zoomRunning, "precondition: a zoom is running")
        let running = session.layoutGeneration
        session.navigator.descend(into: t["empty"])
        XCTAssertTrue(session.isEmpty, "precondition: the treemap view is removed")
        // The removed view's final report carries the old generation and is dropped.
        session.setZoomRunning(false, generation: running)
        XCTAssertFalse(session.zoomRunning, "no renderer remains to end the zoom")
        await session.waitForTable()
        XCTAssertNotNil(session.table.content)
        XCTAssertTrue(session.labels.isEmpty)
    }

    func test_breadcrumb_jump_relayouts_once() throws {
        let t = TestSnapshot(.dir("/R", [.dir("a", [.dir("b", [.dir("c", [.file("f", 10)])])])]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        session.resize(to: CGSize(width: 800, height: 600))
        session.navigator.descend(into: t["c"])
        XCTAssertEqual(session.navigator.breadcrumb.count, 4, "precondition: three levels below the root")
        var published = 0
        let observation = session.$tiles.dropFirst().sink { _ in published += 1 }
        let before = session.layoutGeneration
        session.go(to: t.snapshot.root)
        XCTAssertEqual(session.navigator.root, t.snapshot.root)
        XCTAssertEqual(session.layoutGeneration, before &+ 1, "one squarify for a deep jump")
        XCTAssertEqual(published, 1, "one tiles publication for a deep jump")
        session.go(to: t["b"])
        XCTAssertEqual(session.navigator.root, t.snapshot.root, "only ancestors on the breadcrumb are targets")
        session.go(to: t.snapshot.root)
        XCTAssertEqual(session.layoutGeneration, before &+ 1, "jumping to the current root does nothing")
        withExtendedLifetime(observation) {}
    }

    func test_labels_are_placed_off_the_main_actor_under_the_generation_guard() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .file("top", 60)]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        let probe = MeasureProbe()
        session.labelMeasure = { text in probe.measure(text) }
        session.resize(to: CGSize(width: 800, height: 600))
        // Placement is blocked inside its first measurement; the main actor is not.
        XCTAssertTrue(probe.waitUntilBlocked(), "precondition: placement started")
        XCTAssertTrue(session.labels.isEmpty, "precondition: nothing placed yet")
        session.navigator.descend(into: t["sub"])
        probe.release()
        await session.waitForLabels()
        XCTAssertTrue(session.labels.isEmpty, "a placement for an earlier layout is never applied")
        session.setZoomRunning(false, generation: session.layoutGeneration)
        await session.waitForLabels()
        let texts = session.labels.map(\.text)
        XCTAssertFalse(texts.isEmpty)
        XCTAssertTrue(texts.contains { $0.hasPrefix("large") }, "\(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("top") }, "only the current layout's labels: \(texts)")
        XCTAssertGreaterThan(probe.calls, 0)
        XCTAssertEqual(probe.mainThreadCalls, 0, "label text is measured off the main thread")
    }

    func test_labels_ready_only_once_the_current_layouts_labels_are_applied() async throws {
        let t = TestSnapshot(.dir("/R", [.dir("sub", [.file("large", 80), .file("small", 20)]), .file("top", 60)]))
        let app = AppModel()
        app.replaceSnapshot(t.snapshot)
        let session = try XCTUnwrap(app.session)
        let probe = MeasureProbe()
        session.labelMeasure = { text in probe.measure(text) }
        XCTAssertFalse(session.labelsReady, "nothing placed yet")
        session.resize(to: CGSize(width: 800, height: 600))
        XCTAssertTrue(probe.waitUntilBlocked(), "precondition: placement started")
        XCTAssertFalse(session.labelsReady, "not ready while placement runs")
        probe.release()
        await session.waitForLabels()
        XCTAssertFalse(session.labels.isEmpty, "precondition")
        XCTAssertTrue(session.labelsReady)
        // A resize hides the stale labels at once, before the new ones are placed.
        session.resize(to: CGSize(width: 700, height: 500))
        XCTAssertFalse(session.labelsReady, "stale labels are hidden at the start of a resize relayout")
        await session.waitForLabels()
        XCTAssertTrue(session.labelsReady)
        // A navigation: not ready through the zoom and until the settle's placement is applied.
        session.navigator.descend(into: t["sub"])
        XCTAssertFalse(session.labelsReady)
        session.setZoomRunning(true, generation: session.layoutGeneration)
        session.setZoomRunning(false, generation: session.layoutGeneration)
        XCTAssertFalse(session.labelsReady, "the zoom ending is not the labels arriving")
        await session.waitForLabels()
        XCTAssertTrue(session.labelsReady)
    }

    func test_renderer_inputs_only_rebuild_when_their_identity_or_values_change() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = try XCTUnwrap(TreemapRenderer(device: device))
        let a = TestSnapshot(.dir("/A", [.file("one.mp4", 20)]))
        let b = TestSnapshot(.dir("/B", [.file("one.txt", 20)]))
        let coordinator = TreemapView.Coordinator()
        var tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 100, height: 80), node: 1, depth: 0)]
        var palette = Palette.colours(.depth, dark: false)
        var calls = 0
        func install(_ snapshot: Snapshot?, _ mode: ColourMode?, dark: Bool = false) {
            coordinator.updateRenderer(renderer, tiles: tiles, palette: palette, dark: dark,
                snapshot: snapshot, mode: mode, colourOf: { _ in calls += 1; return 2 })
        }
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 1)
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 1, "hover or zoom-state updates do not rebuild identical input")
        tiles[0].flags |= Tile.Flag.selected
        install(a.snapshot, .depth)
        XCTAssertEqual(calls, 2, "selection invalidates the input")
        install(a.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 3, "a mode change invalidates even if its palette bytes match")
        install(b.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 4, "new snapshot names can map to different colours")
        palette[2] = SIMD4(1, 0, 0, 1)
        install(b.snapshot, .typeFocus([.video]))
        XCTAssertEqual(calls, 5)
        install(b.snapshot, .typeFocus([.video]), dark: true)
        XCTAssertEqual(calls, 6)
        install(nil, nil)
        install(nil, nil)
        XCTAssertEqual(calls, 8, "arbitrary closures without an identity remain dynamic")
    }

    func test_treemap_click_writes_shared_selection() throws {
        let tree = TestSnapshot(.dir("/R", [.file("one", 20)]))
        let selection = Selection()
        let interaction = TreemapInteraction()
        interaction.navigator = Navigator(snapshot: tree.snapshot)
        interaction.selection = selection
        _ = interaction.setTiles([Tile(rect: CGRect(x: 0, y: 0, width: 200, height: 100), node: tree["one"], depth: 1)])
        interaction.press(at: CGPoint(x: 30, y: 30))
        XCTAssertFalse(interaction.release(at: CGPoint(x: 30, y: 30)))
        XCTAssertEqual(selection.nodes, [tree["one"]])
    }
}

/// A label measure that records which thread calls it and blocks its first
/// call until released (or a timeout, so a main-thread caller cannot hang the suite).
private final class MeasureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var first = true
    private var _calls = 0, _main = 0

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var mainThreadCalls: Int { lock.lock(); defer { lock.unlock() }; return _main }

    func measure(_ text: String) -> CGSize {
        lock.lock()
        _calls += 1
        if Thread.isMainThread { _main += 1 }
        let wait = first
        first = false
        lock.unlock()
        if wait {
            blocked.signal()
            _ = gate.wait(timeout: .now() + 2)
        }
        return CGSize(width: 6 * CGFloat(text.count), height: 12)
    }

    func waitUntilBlocked() -> Bool { blocked.wait(timeout: .now() + 2) == .success }
    func release() { gate.signal() }
}
