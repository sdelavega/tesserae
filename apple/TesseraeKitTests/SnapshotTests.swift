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
import TesseraeFFI
import XCTest

@testable import TesseraeKit

/// The ARC owner of Rust memory (spec §6 "How the borrow is made safe" and
/// §12 "Lifetime"). Every snapshot here is a real one: a temporary directory
/// scanned through the C ABI.
final class SnapshotTests: XCTestCase {
    // MARK: Fixture

    /// A scanned fixture: the root as given to the scan, plus what was built.
    private struct Fixture {
        let root: String
        let snapshotHandle: OpaquePointer
    }

    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup = []
        super.tearDown()
    }

    /// Create a file of `size` bytes at `dir`/`nameBytes` using open(2), so the
    /// name may be arbitrary bytes. Returns false if the filesystem refused.
    @discardableResult
    private func makeFile(in dir: URL, nameBytes: [UInt8], size: Int) -> Bool {
        var path = Array(dir.path.utf8CString.dropLast().map { UInt8(bitPattern: $0) })
        path.append(UInt8(ascii: "/"))
        path.append(contentsOf: nameBytes)
        path.append(0)
        let fd = path.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                open($0, O_CREAT | O_WRONLY | O_EXCL, 0o644)
            }
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if size > 0 {
            let data = [UInt8](repeating: 0x41, count: size)
            XCTAssertEqual(write(fd, data, size), size)
        }
        return true
    }

    private func makeFile(in dir: URL, name: String, size: Int) {
        XCTAssertTrue(makeFile(in: dir, nameBytes: Array(name.utf8), size: size), name)
    }

    /// Scan `root` through the C ABI and return the finished handle.
    private func scan(_ root: String) -> OpaquePointer {
        guard let s = tess_scan_begin(root, nil) else {
            XCTFail("tess_scan_begin returned null")
            fatalError()
        }
        while tess_scan_status(s) == Int32(TESS_STATUS_RUNNING) { usleep(1000) }
        XCTAssertEqual(tess_scan_status(s), Int32(TESS_STATUS_FINISHED))
        guard let snap = tess_scan_finish(s) else {
            XCTFail("tess_scan_finish returned null")
            fatalError()
        }
        return snap
    }

    /// root/ { big(200000) mid(50000) small(1)  sub/{ inner(70000) }  empty/ }
    private func makeTree() throws -> (root: String, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tess-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        makeFile(in: url, name: "small", size: 1)
        makeFile(in: url, name: "big", size: 200_000)
        makeFile(in: url, name: "mid", size: 50_000)
        let sub = url.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        makeFile(in: sub, name: "inner", size: 70_000)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("empty"), withIntermediateDirectories: false)
        return (url.path, url)
    }

    private func makeSnapshot() throws -> (Snapshot, String) {
        let (root, _) = try makeTree()
        return (Snapshot(handle: scan(root)), root)
    }

    // MARK: Tests

    func test_counts_and_root_match_the_view() throws {
        let (root, _) = try makeTree()
        let handle = scan(root)
        var view = TessView()
        tess_snapshot_view(handle, &view)
        var stats = TessScanStats()
        tess_snapshot_stats(handle, &stats)
        // Preconditions: the scan found what the fixture holds.
        XCTAssertEqual(stats.files, 4)
        XCTAssertEqual(stats.dirs, 3)  // root, sub, empty
        XCTAssertGreaterThan(view.count, 0)

        let snap = Snapshot(handle: handle)
        XCTAssertEqual(snap.root, view.root)
        XCTAssertEqual(UInt64(snap.nodes.count), view.count)
        XCTAssertEqual(UInt64(snap.names.count), view.names_len)
        XCTAssertEqual(snap.nodes.baseAddress, view.nodes)
        XCTAssertEqual(snap.stats.files, stats.files)
        XCTAssertEqual(snap.stats.dirs, stats.dirs)
        XCTAssertEqual(snap.stats.incomplete, UInt32(TESS_INCOMPLETE_NONE))
        XCTAssertNil(snap.stalledAt)
        XCTAssertTrue(snap.isDirectory(snap.root))
        XCTAssertFalse(snap.isDirectory(snap.children(snap.root).first { snap.name($0) == "big" }!))
    }

    func test_children_are_contiguous_and_sorted_by_allocated_descending() throws {
        let (snap, _) = try makeSnapshot()
        let kids = snap.children(snap.root)
        XCTAssertEqual(kids.count, 5)  // big mid small sub empty
        XCTAssertEqual(Int(kids.upperBound), Int(kids.lowerBound) + 5)
        XCTAssertLessThanOrEqual(Int(kids.upperBound), snap.nodes.count)
        let sizes = kids.map { snap.nodes[Int($0)].allocated }
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertGreaterThan(Set(sizes).count, 1, "sorting check would be vacuous")
        XCTAssertEqual(snap.name(kids.lowerBound), "big")
        for k in kids { XCTAssertEqual(snap.nodes[Int(k)].parent, snap.root) }
        // A leaf has an empty range.
        let leaf = kids.first { snap.name($0) == "small" }!
        XCTAssertTrue(snap.children(leaf).isEmpty)
        // The empty directory has an empty range too.
        let empty = kids.first { snap.name($0) == "empty" }!
        XCTAssertTrue(snap.children(empty).isEmpty)
        XCTAssertTrue(snap.isDirectory(empty))
    }

    func test_names_decode_lossily_and_never_empty() throws {
        let (root, url) = try makeTree()
        // Invalid UTF-8 first; APFS may refuse it (EILSEQ).
        let invalid: [UInt8] = [0x62, 0x61, 0x64, 0xFF, 0x6E]
        let rawOK = makeFile(in: url, nameBytes: invalid, size: 10)
        var wanted: [(bytes: [UInt8], expected: String)] = []
        if rawOK {
            wanted.append((invalid, "bad\u{FFFD}n"))
        } else {
            NSLog("APFS refused the 0xFF name (errno %d); relying on the control-character name", errno)
        }
        let ctl: [UInt8] = [0x63, 0x74, 0x6C, 0x01, 0x78, 0x0A, 0x79]  // ctl<SOH>x<LF>y
        XCTAssertTrue(makeFile(in: url, nameBytes: ctl, size: 10), "control-character name must be creatable")
        wanted.append((ctl, "ctl\u{FFFD}x\u{FFFD}y"))
        makeFile(in: url, name: "plain-é", size: 10)

        let snap = Snapshot(handle: scan(root))
        let kids = Array(snap.children(snap.root))
        for (bytes, expected) in wanted {
            let idx = kids.first { snap.nameBytes($0) == Data(bytes) }
            XCTAssertNotNil(idx, "node with raw name bytes \(bytes) not found")
            if let idx { XCTAssertEqual(snap.name(idx), expected) }
        }
        let plain = kids.first { snap.name($0) == "plain-é" }
        XCTAssertNotNil(plain)
        // No decoded name is empty or contains a C0 control character.
        for i in 0..<UInt32(snap.nodes.count) {
            let n = snap.name(i)
            XCTAssertFalse(n.isEmpty)
            XCTAssertFalse(n.unicodeScalars.contains { $0.value < 0x20 }, n)
        }
    }

    func test_invalid_utf8_bytes_decode_to_replacement_characters() {
        // APFS refuses such names (EILSEQ), so this covers the decoder directly.
        XCTAssertEqual(Snapshot.decodeName(Data([0x61, 0xFF, 0x62])), "a\u{FFFD}b")
    }

    func test_empty_name_becomes_unnamed() {
        XCTAssertEqual(Snapshot.decodeName(Data()), "(unnamed)")
    }

    func test_path_joins_from_the_root_as_given() throws {
        let (snap, root) = try makeSnapshot()
        XCTAssertEqual(snap.displayPath(snap.root), root)
        let sub = snap.children(snap.root).first { snap.name($0) == "sub" }!
        XCTAssertEqual(snap.displayPath(sub), root + "/sub")
        let inner = snap.children(sub).first!
        XCTAssertEqual(snap.name(inner), "inner")
        XCTAssertEqual(snap.displayPath(inner), root + "/sub/inner")
        XCTAssertEqual(snap.rawPath(inner), Data((root + "/sub/inner").utf8))
        XCTAssertEqual(snap.rawPath(snap.root), Data(root.utf8))
    }

    func test_path_does_not_double_a_trailing_slash_on_the_root() throws {
        let (root, _) = try makeTree()
        let snap = Snapshot(handle: scan(root + "/"))
        let big = snap.children(snap.root).first { snap.name($0) == "big" }!
        XCTAssertEqual(snap.displayPath(big), root + "/big")
        XCTAssertEqual(snap.rawPath(big), Data((root + "/big").utf8))
    }

    func test_buffers_survive_while_snapshot_is_retained() throws {
        var snap: Snapshot? = try makeSnapshot().0
        let expectedCount = snap!.nodes.count
        let expectedRootName = snap!.name(snap!.root)
        let started = expectation(description: "task started")
        let finished = expectation(description: "task finished")
        let sum = LockedBox<UInt64>(0)
        let held = snap!
        DispatchQueue.global().async {
            started.fulfill()
            Thread.sleep(forTimeInterval: 0.3)  // the local reference is gone by now
            var total: UInt64 = 0
            for _ in 0..<50 {
                for i in 0..<held.nodes.count {
                    total &+= held.nodes[i].allocated
                    _ = held.name(UInt32(i))
                }
            }
            XCTAssertEqual(held.nodes.count, expectedCount)
            XCTAssertEqual(held.name(held.root), expectedRootName)
            sum.value = total
            finished.fulfill()
        }
        wait(for: [started], timeout: 5)
        weak let weakSnap = snap
        snap = nil  // drop the local reference; only the task holds it
        XCTAssertNotNil(weakSnap, "the task must be keeping the snapshot alive")
        wait(for: [finished], timeout: 10)
        XCTAssertGreaterThan(sum.value, 0)
    }

    func test_release_happens_when_the_last_reference_goes() throws {
        let before = Snapshot.releasedCount
        var snap: Snapshot? = try makeSnapshot().0
        XCTAssertEqual(Snapshot.releasedCount, before, "must not release while retained")
        _ = snap
        snap = nil
        XCTAssertEqual(Snapshot.releasedCount, before + 1)
    }

    func test_testing_buffers_survive_the_fixture_and_release_with_snapshot() throws {
        var fixture: TestSnapshot? = TestSnapshot(.dir("/lifetime", [
            .file("plain", 20), .rawFile([0xff, 0x0a, 0x78], key: "raw", 10), .dir("empty", [])
        ]))
        weak var owner = fixture!.buffers
        weak var releasedFixture = fixture
        var snapshot: Snapshot? = fixture!.snapshot
        let expected = (0..<UInt32(snapshot!.nodes.count)).map { snapshot!.nameBytes($0) }
        XCTAssertEqual(expected.count, 4)
        XCTAssertTrue(expected.contains(Data([0xff, 0x0a, 0x78])))
        fixture = nil
        XCTAssertNil(releasedFixture)
        XCTAssertNotNil(owner, "Snapshot must retain its buffer owner after the fixture is released")
        // Avoid dereferencing freed pointers on the deterministic red run.
        guard owner != nil else { return }
        for index in expected.indices {
            XCTAssertEqual(snapshot!.nameBytes(UInt32(index)), expected[index])
        }
        snapshot = nil
        XCTAssertNil(owner, "The last snapshot reference must release its buffers")
    }

    // MARK: Use after release (spec §12)

    private static let childEnv = "TESSERAE_SNAPSHOT_TRAP_CHILD"

    /// Runs only inside the child process the trap tests spawn. The env value
    /// is "<kind>:<control|trap>"; "control" does the same work legally.
    func test_child_only_access_after_release() throws {
        guard let mode = ProcessInfo.processInfo.environment[Self.childEnv] else { return }
        let parts = mode.split(separator: ":").map(String.init)
        let kind = parts[0]
        let trap = parts[1] == "trap"
        if kind == "release" {
            let (snap, _) = try makeSnapshot()
            if trap { snap.debugReleaseEarly() }
            _ = snap.generation
            _ = snap.name(snap.root)
        } else if kind.hasPrefix("cycle") {
            // Two nodes, "r" and its child "c"; the trap makes each the
            // other's parent, so neither reaches a root.
            let nodes = UnsafeMutablePointer<TessNode>.allocate(capacity: 2)
            var r = TessNode(), c = TessNode()
            r.name_len = 1; r.parent = trap ? 1 : UInt32.max
            r.child_start = 1; r.child_count = 1; r.flags = UInt16(TESS_FLAG_DIR)
            c.name_off = 1; c.name_len = 1; c.parent = 0
            nodes.initialize(to: r)
            (nodes + 1).initialize(to: c)
            let names = UnsafeMutablePointer<UInt8>.allocate(capacity: 2)
            names.initialize(to: 0x72)
            (names + 1).initialize(to: 0x63)
            let snap = Snapshot(
                testingNodes: UnsafeBufferPointer(start: nodes, count: 2),
                names: UnsafeRawBufferPointer(start: names, count: 2), owner: TestSnapshotBuffers(nodes: nodes, names: names), root: 0)
            if kind == "cycle-raw" {
                XCTAssertEqual(snap.rawPath(1), Data("r/c".utf8))
            } else {
                XCTAssertEqual(snap.displayPath(1), "r/c")
            }
        } else {
            // Hand-built malformed nodes owned by the snapshot.
            let nodes = UnsafeMutablePointer<TessNode>.allocate(capacity: 1)
            var node = TessNode()
            node.parent = UInt32.max
            node.name_len = 1
            switch kind {
            case "name": if trap { node.name_len = 9 }
            case "children":
                node.child_start = 0
                node.child_count = trap ? 5 : 0
            default: break
            }
            nodes.initialize(to: node)
            let names = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            names.initialize(to: 0x72)
            let snap = Snapshot(
                testingNodes: UnsafeBufferPointer(start: nodes, count: 1),
                names: UnsafeRawBufferPointer(start: names, count: 1), owner: TestSnapshotBuffers(nodes: nodes, names: names), root: 0)
            switch kind {
            case "index": _ = snap.name(trap ? 5 : 0)
            case "name": _ = snap.name(0)
            case "children": _ = snap.children(0)
            default: XCTFail("unknown kind \(kind)")
            }
        }
        print("CHILD-SURVIVED-ACCESS")
    }

    private struct ChildResult {
        let reason: Process.TerminationReason
        let status: Int32
        let output: String
    }

    private func runChild(_ mode: String) throws -> ChildResult {
        let bundle = Bundle(for: SnapshotTests.self)
        let bundlePath = bundle.bundlePath
        let frameworksDir = (bundlePath as NSString).deletingLastPathComponent
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = [
            "xctest", "-XCTest", "TesseraeKitTests.SnapshotTests/test_child_only_access_after_release",
            bundlePath,
        ]
        // The parent runs under xcodebuild's test session; a child that
        // inherits its XCTest/DYLD variables tries to join that session and
        // hangs. Start from a clean environment.
        var env = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XC") && !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("__XPC")
        }
        env[Self.childEnv] = mode
        env["DYLD_FRAMEWORK_PATH"] = frameworksDir
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // A watchdog so a hung child fails the test instead of the run.
        let watchdog = DispatchWorkItem {
            guard p.isRunning else { return }
            p.terminate()
            // If SIGTERM does not end it, SIGKILL after a few seconds.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ChildResult(
            reason: p.terminationReason, status: p.terminationStatus,
            output: String(decoding: data, as: UTF8.self))
    }

    /// Run the child twice: legal (must exit 0 having run the test) and
    /// illegal (must start the test, print the precondition message, and die
    /// by SIGILL/SIGTRAP without reaching the survive marker).
    private func assertTraps(kind: String, message: String) throws {
        let control = try runChild("\(kind):control")
        XCTAssertEqual(control.reason, .exit, control.output)
        XCTAssertEqual(control.status, 0, control.output)
        XCTAssertTrue(control.output.contains("CHILD-SURVIVED-ACCESS"), control.output)
        XCTAssertTrue(control.output.contains("Executed 1 test"), control.output)

        let trapped = try runChild("\(kind):trap")
        XCTAssertTrue(
            trapped.output.contains("test_child_only_access_after_release"),
            "the child never started the test: \(trapped.output)")
        XCTAssertFalse(trapped.output.contains("CHILD-SURVIVED-ACCESS"), trapped.output)
        XCTAssertEqual(trapped.reason, .uncaughtSignal, "child did not crash: \(trapped.output)")
        XCTAssertTrue([SIGILL, SIGTRAP].contains(trapped.status), "signal \(trapped.status)")
        XCTAssertTrue(trapped.output.contains(message), "missing '\(message)' in: \(trapped.output)")
    }

    func test_access_after_release_traps_in_debug() throws {
        #if DEBUG
        try assertTraps(
            kind: "release", message: "Snapshot accessed after its Rust memory was released")
        #else
        throw XCTSkip("the generation check exists in Debug builds only")
        #endif
    }

    func test_node_index_out_of_range_traps() throws {
        try assertTraps(kind: "index", message: "Snapshot node index out of range")
    }

    func test_name_range_out_of_range_traps() throws {
        try assertTraps(kind: "name", message: "Snapshot name range out of range")
    }

    func test_children_range_out_of_range_traps() throws {
        try assertTraps(kind: "children", message: "Snapshot children range out of range")
    }

    func test_path_of_an_empty_snapshot_is_empty() {
        let snap = Snapshot(
            testingNodes: UnsafeBufferPointer(start: nil, count: 0),
            names: UnsafeRawBufferPointer(start: nil, count: 0), owner: TestSnapshotBuffers(nodes: [], names: []), root: UInt32.max)
        XCTAssertEqual(snap.displayPath(0), "")
        XCTAssertEqual(snap.rawPath(0), Data())
    }

    func test_path_under_a_slash_root_has_a_single_slash() {
        // root "/" with one child "usr"
        var nodes = [TessNode](repeating: TessNode(), count: 2)
        nodes[0].name_off = 0; nodes[0].name_len = 1; nodes[0].parent = UInt32.max
        nodes[0].child_start = 1; nodes[0].child_count = 1; nodes[0].flags = UInt16(TESS_FLAG_DIR)
        nodes[1].name_off = 1; nodes[1].name_len = 3; nodes[1].parent = 0
        let names = Array("/usr".utf8)
        let buffers = TestSnapshotBuffers(nodes: nodes, names: names)
        let snap = Snapshot(
            testingNodes: UnsafeBufferPointer(start: buffers.nodes, count: nodes.count),
            names: UnsafeRawBufferPointer(start: buffers.names, count: names.count), owner: buffers, root: 0)
        XCTAssertEqual(snap.displayPath(0), "/")
        XCTAssertEqual(snap.displayPath(1), "/usr")
        XCTAssertEqual(snap.rawPath(0), Data("/".utf8))
        XCTAssertEqual(snap.rawPath(1), Data("/usr".utf8))
    }

    /// Final review I1: the raw path is the actionable identity, so it keeps
    /// every byte of every name: invalid UTF-8, C0 controls (a newline, a
    /// tab, ESC), DEL and a bidi override, none of which the display path
    /// can carry.
    func test_raw_path_keeps_every_byte_of_every_name() {
        let weird: [UInt8] = [0x66, 0xFF, 0xFE, 0x0A, 0x09, 0x1B, 0xE2, 0x80, 0xAE, 0x7F, 0xC3]
        let leaf = Array("x\r".utf8)
        let names = Array("/R".utf8) + weird + leaf
        var nodes = [TessNode](repeating: TessNode(), count: 3)
        nodes[0].name_off = 0; nodes[0].name_len = 2; nodes[0].parent = UInt32.max
        nodes[0].child_start = 1; nodes[0].child_count = 1; nodes[0].flags = UInt16(TESS_FLAG_DIR)
        nodes[1].name_off = 2; nodes[1].name_len = UInt16(weird.count); nodes[1].parent = 0
        nodes[1].child_start = 2; nodes[1].child_count = 1; nodes[1].flags = UInt16(TESS_FLAG_DIR)
        nodes[2].name_off = UInt32(2 + weird.count); nodes[2].name_len = UInt16(leaf.count); nodes[2].parent = 1
        let buffers = TestSnapshotBuffers(nodes: nodes, names: names)
        let snap = Snapshot(
            testingNodes: UnsafeBufferPointer(start: buffers.nodes, count: nodes.count),
            names: UnsafeRawBufferPointer(start: buffers.names, count: names.count), owner: buffers, root: 0)
        let expected = Data(Array("/R/".utf8) + weird + [0x2F] + leaf)
        XCTAssertEqual(snap.rawPath(2), expected)
        XCTAssertEqual(snap.rawPath(1), Data(Array("/R/".utf8) + weird))
        XCTAssertNotEqual(
            Data(snap.displayPath(2).utf8), expected, "precondition: the display path is lossy")
    }

    /// A parent chain that loops (only a malformed snapshot can have one)
    /// traps instead of spinning forever, for both path builders.
    func test_raw_path_traps_on_a_parent_cycle() throws {
        try assertTraps(kind: "cycle-raw", message: "Snapshot parent chain has a cycle")
    }

    func test_display_path_traps_on_a_parent_cycle() throws {
        try assertTraps(kind: "cycle-display", message: "Snapshot parent chain has a cycle")
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
