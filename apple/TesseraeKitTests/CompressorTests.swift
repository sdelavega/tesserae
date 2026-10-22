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

@MainActor
final class CompressorTests: XCTestCase {
    final class World: CompressionFileSystem, HelperRunner, OpenFilesProbe, AuditSink, Trasher, Mover, @unchecked Sendable {
        var files: [Data: CompressionFile] = [:]
        var gone: Set<Data> = []
        var manifestDirectory: URL!
        var childrenByPath: [Data: [Data]] = [:]
        var calls: [[Data]] = []
        var logs: [LogEntry] = []
        var trashPaths: [Data] = []
        var free: UInt64 = 20 * 1024 * 1024 * 1024
        var unchanged = false, growing = false, logSucceeds = true
        var sweepCount = 0
        var beforeRun: (@Sendable () async -> Void)?
        var afterRun: (@Sendable () -> Void)?
        func inspect(_ path: Data) -> CompressionFile? { files[path] }
        func children(_ path: Data) throws -> [Data] { childrenByPath[path] ?? [] }
        func freeSpace(_ path: Data) -> UInt64? { free }
        func canCompress(_ path: Data) -> Bool { true }
        func lstat(_ path: Data) -> StatResult {
            if gone.contains(path) { return .error(errno: ENOENT) }
            guard let f = files[path] else {
                if ["/.git", "-wal", "-shm", "/Contents/_MASReceipt/receipt"].contains(where: { path.suffix($0.utf8.count) == Data($0.utf8) }) { return .error(errno: ENOENT) }
                return .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1), fileID: 1, isSymlink: false)
            }
            return .ok(Observed(device: f.facts.key.dev, flags: f.facts.flags, isDirectory: f.recorded.isDirectory,
                linkCount: UInt16(f.facts.nlink)), fileID: f.recorded.fileID, isSymlink: !f.facts.isRegular && !f.recorded.isDirectory)
        }
        func volumeUUID(_ path: Data) -> String? { "volume-A" }
        func openForWriting() -> (keys: Set<FileKey>, inspectedAll: Bool) { sweepCount += 1; return ([], true) }
        func append(_ e: LogEntry) -> Bool { if logSucceeds { logs.append(e) }; return logSucceeds }
        func compressEntry(run: CompressRunID) -> LogEntry? { logs.last { $0.action == "compress" && $0.compression?.runID == run } }
        func trash(_ url: URL) throws -> URL {
            let path = Data(url.path.utf8), trash = Data("/fake-trash/leaf".utf8)
            trashPaths.append(path); files[trash] = files.removeValue(forKey: path); gone.insert(path)
            return URL(fileURLWithPath: "/fake-trash/leaf")
        }
        func move(_ from: URL, to: URL) throws {
            let source = Data(from.path.utf8), destination = Data(to.path.utf8)
            files[destination] = files.removeValue(forKey: source); gone.remove(destination); gone.insert(source)
        }
        func run(_ exe: URL, _ args: [Data]) async -> Int32 {
            calls.append(args)
            await beforeRun?()
            if !unchanged {
                let undo = args.first == Data("decompress".utf8)
                for path in args.dropFirst(undo ? 2 : 7) {
                    guard let f = files[path] else { continue }
                    let id = f.recorded.fileID + 1000
                    files[path] = CompressionFile(facts: FileFacts(flags: undo ? 0 : UInt32(UF_COMPRESSED),
                        size: f.facts.size, blocks: undo ? f.facts.size / 512 : 8,
                        key: FileKey(dev: 7, ino: id)),
                        recorded: Recorded(fileID: id, device: 7, isDirectory: false),
                        allocated: undo ? f.facts.size : (growing ? f.allocated + 512 : 4096))
                }
            }
            afterRun?()
            return 0
        }
        func seed(_ path: Data, id: UInt64 = 20, size: UInt64 = 131072, directory: Bool = false) {
            files[path] = CompressionFile(facts: FileFacts(isRegular: !directory, size: size, blocks: size / 512,
                key: FileKey(dev: 7, ino: id)), recorded: Recorded(fileID: id, device: 7, isDirectory: directory), allocated: size)
        }
    }

    let root = Data("/scan/root/item".utf8)
    var context: GuardContext { GuardContext(scanRoot: Data("/scan/root".utf8), volumeRoot: Data("/".utf8),
        scanRootDevice: 7, appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8)) }
    func item(_ w: World, directory: Bool = false) -> ReclaimItem {
        w.seed(root, directory: directory)
        return ReclaimItem(nodeIndex: 1, path: root, recorded: w.files[root]!.recorded,
                           recordedSize: 131072, verdict: .ok, action: .compress)
    }
    func compressor(_ w: World, limit: Int = 256 * 1024) throws -> Compressor {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/task-10/manifest-" + UUID().uuidString)
        w.manifestDirectory = directory
        return Compressor(helper: URL(fileURLWithPath: "/fixture/Contents/Helpers/applesauce"), runner: w,
            files: w, openFiles: w, log: w, manifests: CompressManifest(directory: directory), context: context, argvLimit: limit)
    }

    func test_presentation_cancel_accounts_batch_keeps_staging_and_stops_mixed_actions() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        let tree = TestSnapshot(.dir("/scan/root", [.dir("item", [.file("a", 131072), .file("b", 131072), .file("c", 131072)]), .file("later", 100)]), stats: stats, fileIDs: true)
        let w = World(), latch = BatchLatch()
        for node in 0..<UInt32(tree.snapshot.nodes.count) {
            w.seed(tree.snapshot.rawPath(node), id: tree.snapshot.fileID(node)!, directory: tree.snapshot.isDirectory(node))
        }
        let paths = ["a", "b", "c"].map { tree.snapshot.rawPath(tree[$0]) }
        w.childrenByPath[root] = paths
        w.beforeRun = { if w.calls.count == 1 { await latch.enter() } }
        let oneBatch = Compressor.argvBytes(executable: "/fixture/Contents/Helpers/applesauce",
            args: ["compress", "--verify", "-c", "lzfse", "-r", "0.95", "--"].map { Data($0.utf8) } + [paths[0]])
        let c = try compressor(w, limit: oneBatch + 1)
        let ctx = context
        let model = AppModel(coordinator: ScanCoordinator(), stagingStat: w, contextLoader: { _ in ctx })
        model.replaceSnapshot(tree.snapshot)
        let session = try XCTUnwrap(model.session)
        session.selection.nodes = [tree["item"], tree["later"]]
        model.stageSelection(); await model.waitForStaging()
        XCTAssertEqual(session.reclaim.items.count, 2)
        let selected = try ["item", "later"].map { name -> ReclaimItem in
            var i = try XCTUnwrap(session.reclaim.items.first { $0.id == tree[name] })
            i.action = name == "item" ? .compress : .trash
            return i
        }
        let ui = ReclaimPresentation(log: ReclaimLog(directory: w.manifestDirectory.appendingPathComponent("audit")), historyLoader: { [] })
        ui.prepare(selected)
        let task = try XCTUnwrap(ui.startExecution(model, trasher: w, stat: w, compressor: c))
        await latch.waitUntilEntered()
        XCTAssertTrue(ui.running); XCTAssertEqual(w.calls.count, 1)
        ui.cancelExecution()
        XCTAssertTrue(ui.running, "helper is allowed to finish its current batch")
        XCTAssertTrue(w.trashPaths.isEmpty)
        await latch.release(); await task.value
        guard case .compressed(let result) = ui.result?.outcomes.first?.1 else { return XCTFail("Expected compression") }
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.compressed, 1)
        XCTAssertEqual(ui.result?.outcomes.count, 1, "later mixed action must never start")
        XCTAssertEqual(w.calls.count, 1); XCTAssertTrue(w.trashPaths.isEmpty)
        XCTAssertEqual(session.reclaim.stagedNodes, [tree["item"], tree["later"]])
        XCTAssertEqual(session.overlay.replacedIdentities[tree["a"]], tree.snapshot.fileID(tree["a"])! + 1000)
        XCTAssertEqual(session.source.allocated(tree["a"]), 4096)
        XCTAssertFalse(ui.running); XCTAssertNil(ui.executionTask)
    }

    func test_presentation_decompress_cancel_finishes_only_current_batch() async throws {
        let w = World(), i = item(w, directory: true)
        let paths = (0..<3).map { root + Data(("/" + String(repeating: "p", count: 100) + String($0)).utf8) }
        paths.forEach { w.seed($0) }; w.childrenByPath[root] = paths
        let oneBatch = Compressor.argvBytes(executable: "/fixture/Contents/Helpers/applesauce",
            args: ["compress", "--verify", "-c", "lzfse", "-r", "0.95", "--"].map { Data($0.utf8) } + [paths[0]])
        let c = try compressor(w, limit: oneBatch + 1)
        let compressed = await c.compress(i)
        XCTAssertEqual(compressed.compressed, 3)
        let entry = try XCTUnwrap(w.logs.last), latch = BatchLatch()
        let ctx = context
        let model = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
        var stats = TessScanStats(); stats.root_device = 7
        let tree = TestSnapshot(.dir("/scan/root", [.dir("item", [])]), stats: stats, fileIDs: true)
        model.replaceSnapshot(tree.snapshot)
        let ui = ReclaimPresentation(log: ReclaimLog(directory: w.manifestDirectory.appendingPathComponent("audit")),
            historyLoader: { [] }, compressorFactory: { _, _ in c })
        await ui.prepareDecompression(entry, model: model)
        XCTAssertEqual(ui.decompression?.fileCount, 3)
        w.calls = []; w.beforeRun = { if w.calls.count == 1 { await latch.enter() } }
        let task = try XCTUnwrap(ui.startDecompression(run: compressed.runID, model: model))
        await latch.waitUntilEntered(); ui.cancelExecution()
        XCTAssertTrue(ui.running); XCTAssertEqual(w.calls.count, 1)
        await latch.release(); await task.value
        XCTAssertEqual(w.calls.count, 1)
        XCTAssertEqual(paths.filter { w.files[$0]!.facts.flags & UInt32(UF_COMPRESSED) == 0 }.count, 1)
        XCTAssertTrue(try XCTUnwrap(ui.decompressResult).contains("Cancelled"))
        XCTAssertFalse(ui.running); XCTAssertNil(ui.executionTask)
    }

    func test_decompress_preparation_latest_request_and_dismissal_win() async throws {
        let w = World(), c = try compressor(w)
        let first = await c.compress(item(w))
        let entryA = try XCTUnwrap(w.logs.last)
        let other = root + Data("-other".utf8); w.seed(other, id: 99)
        let secondItem = ReclaimItem(nodeIndex: 2, path: other, recorded: w.files[other]!.recorded,
            recordedSize: 131072, verdict: .ok, action: .compress)
        let second = await c.compress(secondItem), entryB = try XCTUnwrap(w.logs.last)
        XCTAssertNotEqual(first.runID, second.runID)
        XCTAssertEqual(first.compressed, 1); XCTAssertEqual(second.compressed, 1)
        let ctx = context
        let model = AppModel(coordinator: ScanCoordinator(), contextLoader: { _ in ctx })
        let tree = TestSnapshot(.dir("/scan/root", [.file("item", 131072)]))
        model.replaceSnapshot(tree.snapshot)
        let latch = BatchLatch()
        var calls = 0
        let ui = ReclaimPresentation(log: ReclaimLog(directory: w.manifestDirectory.appendingPathComponent("audit")),
            historyLoader: { [] }, compressorFactory: { _, _ in
                calls += 1
                if calls == 1 || calls == 3 { await latch.enter() }
                return c
            })
        let a = Task { await ui.prepareDecompression(entryA, model: model) }
        await latch.waitUntilEntered()
        await ui.prepareDecompression(entryB, model: model)
        XCTAssertEqual(ui.decompression?.run, second.runID)
        await latch.release(); await a.value
        XCTAssertEqual(ui.decompression?.run, second.runID, "late A cannot replace B")
        let pending = Task { await ui.prepareDecompression(entryA, model: model) }
        // The factory's third request must suspend before dismissal.
        for _ in 0..<1000 { if calls == 3 { break }; await Task.yield() }
        XCTAssertEqual(calls, 3)
        ui.dismissDecompression()
        await latch.release(); await pending.value
        XCTAssertNil(ui.decompression, "dismissal invalidates pending publication")
        XCTAssertFalse(ui.preparingDecompression)
    }

    func test_argv_always_has_verify_and_explicit_files() async throws {
        let w = World(), i = item(w, directory: true)
        let paths = [root + Data("/nested/-leaf".utf8), root + Data([47,255])]
        for p in paths { w.seed(p) }
        w.childrenByPath[root] = paths
        let c = try compressor(w)
        let r = await c.compress(i)
        XCTAssertEqual(r.compressed, 2); XCTAssertEqual(w.calls.count, 1)
        XCTAssertEqual(Array(w.calls[0].prefix(8)), ["compress", "--verify", "-c", "lzfse", "-r", "0.95", "--"].map { Data($0.utf8) } + [paths[0]])
        XCTAssertEqual(Set(w.calls[0].dropFirst(7)), Set(paths))
        XCTAssertFalse(w.calls[0].contains(root)); XCTAssertEqual(w.sweepCount, 1)
    }

    func test_batches_stay_under_256_kib() async throws {
        let w = World(), i = item(w, directory: true)
        let paths = (0..<700).map { root + Data(("/" + String(repeating: "x", count: 400) + String($0)).utf8) }
        paths.forEach { w.seed($0) }; w.childrenByPath[root] = paths
        let r = await (try compressor(w)).compress(i)
        XCTAssertEqual(r.compressed, paths.count); XCTAssertGreaterThan(w.calls.count, 1)
        for args in w.calls { XCTAssertLessThan(Compressor.argvBytes(executable: "/fixture/Contents/Helpers/applesauce", args: args), 256 * 1024) }
    }

    func test_cancel_between_batches_only() async throws {
        let w = World(), i = item(w, directory: true)
        let paths = (0..<3).map { root + Data("/file\($0)".utf8) }
        paths.forEach { w.seed($0) }; w.childrenByPath[root] = paths
        let latch = BatchLatch()
        w.beforeRun = { await latch.enter() }
        let c = try compressor(w, limit: 235)
        let task = Task { await c.compress(i) }
        await latch.waitUntilEntered(); task.cancel(); await latch.release()
        let r = await task.value
        XCTAssertTrue(r.cancelled); XCTAssertEqual(w.calls.count, 1)
        XCTAssertEqual(r.compressed, 1, "Current batch is inspected and persisted even after cancellation")
    }

    func test_exit_zero_with_unchanged_files_counts_as_failed() async throws {
        let w = World(), i = item(w); w.unchanged = true
        let r = await (try compressor(w)).compress(i)
        XCTAssertEqual(w.calls.count, 1); XCTAssertEqual(r.compressed, 0); XCTAssertEqual(r.failed, [root])
    }

    func test_new_file_id_recorded_in_overlay_and_used_by_later_trash() async throws {
        var stats = TessScanStats(); stats.root_device = 7
        let fixture = TestSnapshot(.dir("/scan/root", [.file("item", 131072)]), stats: stats, fileIDs: true)
        let s = fixture.snapshot, node = fixture["item"], w = World()
        w.seed(root, id: s.fileID(node)!)
        let session = AppSession(snapshot: s, guardContext: context)
        let i = ReclaimItem(nodeIndex: node, path: root, recorded: w.files[root]!.recorded, recordedSize: 131072,
            verdict: .ok, sessionID: session.id, action: .compress)
        let c = try compressor(w)
        let executor = Executor(trasher: w, stat: w, log: w, context: context, compressor: c)
        let execution = await session.execute(using: executor, confirmedWarnings: [], reviewedItems: [i], stagingStat: w)
        guard case .compressed(let r) = execution.outcomes.first?.1 else { return XCTFail("Action must dispatch to compressor") }
        XCTAssertEqual(r.compressed, 1)
        let overlay = session.overlay
        let id = try XCTUnwrap(r.replaced[node]); XCTAssertNotEqual(id, i.recorded.fileID)
        XCTAssertEqual(overlay.replacedIdentities[node], id)
        XCTAssertEqual(verifyIdentity(root, i.recorded, stat: w, overlay: overlay, node: node), .same)
        XCTAssertEqual(OverlaySource(s, overlay).allocated(node), 4096)
        let staged = Reclaim.prepare([node], in: s, context: context, stat: w, overlay: overlay, existing: [], sessionID: session.id)
        XCTAssertEqual(staged.count, 1); XCTAssertEqual(staged[0].verdict, .ok); XCTAssertEqual(staged[0].recorded.fileID, id)
        let r2 = await session.execute(using: executor, confirmedWarnings: [], reviewedItems: staged, stagingStat: w)
        guard case .trashed = r2.outcomes.first?.1 else { return XCTFail("Compressed replacement must be trashable") }
        XCTAssertEqual(w.trashPaths, [root]); XCTAssertEqual(r2.auditEntries[0].inode, id)
        let back = await session.putBack(r2.auditEntries[0], stat: w, mover: w, log: w)
        XCTAssertEqual(back, .restored); XCTAssertFalse(session.changedSinceScan)
        XCTAssertEqual(verifyIdentity(root, i.recorded, stat: w, overlay: session.overlay, node: node), .same)
        let reopened = Compressor(helper: URL(fileURLWithPath: "/fixture/Contents/Helpers/applesauce"), runner: w, files: w,
            openFiles: w, log: w, manifests: CompressManifest(directory: w.manifestDirectory), context: context)
        let undo = await session.decompress(run: r.runID, using: reopened, stagingStat: w)
        XCTAssertEqual(undo.compressed, 1)
        XCTAssertEqual(session.overlay.replacedIdentities[node], id + 1000)
        XCTAssertEqual(session.source.allocated(node), 131072)
        XCTAssertEqual(verifyIdentity(root, i.recorded, stat: w, overlay: session.overlay, node: node), .same)
    }

    func test_free_space_precondition_refuses_with_numbers() async throws {
        let w = World(), i = item(w); w.free = 17
        let r = await (try compressor(w)).compress(i)
        XCTAssertTrue(w.calls.isEmpty); XCTAssertEqual(r.requiredFreeBytes, 2 * 1024 * 1024 * 1024 + 2 * 131072)
        XCTAssertEqual(r.availableFreeBytes, 17); XCTAssertNotNil(r.refusal)
        let refusal = try XCTUnwrap(r.refusal)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(refusal, "This operation needs " + displaySize(2_147_745_792, locale: locale)
            + " free; " + displaySize(17, locale: locale) + " are available.")
    }

    func test_decompress_only_touches_manifest_files_still_matching() async throws {
        let w = World(), i = item(w, directory: true)
        let paths = (0..<3).map { root + Data("/file\($0)".utf8) }
        paths.forEach { w.seed($0) }; w.childrenByPath[root] = paths
        let c = try compressor(w), r = await c.compress(i)
        XCTAssertEqual(r.compressed, 3)
        w.seed(paths[1], id: 999); w.seed(root + Data("/unrelated".utf8), id: 55)
        let undo = await c.decompress(run: r.runID)
        XCTAssertEqual(undo.compressed, 2)
        XCTAssertTrue(undo.summary.hasPrefix("Decompressed"))
        XCTAssertEqual(w.calls.last?.first, Data("decompress".utf8))
        XCTAssertEqual(Set(w.calls.last!.dropFirst(2)), Set([paths[0], paths[2]]))
        XCTAssertEqual(w.files[paths[0]]?.recorded.fileID, 2020, "Decompression also replaces the inode")
        let unlogged = World(), single = item(unlogged); unlogged.logSucceeds = false
        let compressed = await (try compressor(unlogged)).compress(single)
        XCTAssertEqual(compressed.compressed, 1); XCTAssertTrue(compressed.auditFailed); XCTAssertTrue(unlogged.logs.isEmpty)
        let reopened = Compressor(helper: URL(fileURLWithPath: "/fixture/Contents/Helpers/applesauce"), runner: unlogged,
            files: unlogged, openFiles: unlogged, log: unlogged,
            manifests: CompressManifest(directory: unlogged.manifestDirectory), context: context)
        let restored = await reopened.decompress(run: compressed.runID)
        XCTAssertEqual(restored.compressed, 1, "The manifest remains usable if the audit append failed or rotated away")
        XCTAssertNil(restored.refusal)
        let isolated = World(), old = item(isolated), engine = try compressor(isolated)
        let run = await engine.compress(old)
        XCTAssertEqual(run.compressed, 1)
        let other = TestSnapshot(.dir("/scan/other", [.file("unrelated", 100)]), stats: { var s = TessScanStats(); s.root_device = 7; return s }(), fileIDs: true)
        let separate = await engine.decompress(run: run.runID, snapshot: other.snapshot)
        XCTAssertEqual(separate.compressed, 1)
        XCTAssertTrue(separate.replaced.isEmpty, "An earlier scan's node IDs must not reach an unrelated snapshot")
        XCTAssertTrue(separate.allocatedDeltas.isEmpty)
        XCTAssertEqual(separate.replacedPaths[root], isolated.files[root]?.recorded.fileID)
        XCTAssertEqual(separate.auditEntry?.inode, isolated.files[root]?.recorded.fileID)
    }

    func test_negative_savings_reported_as_negative() async throws {
        let w = World(), i = item(w); w.growing = true
        let r = await (try compressor(w)).compress(i)
        XCTAssertEqual(r.compressed, 1); XCTAssertEqual(r.savings, -512)
        XCTAssertTrue(r.summary.contains("-"))
        let fixture = TestSnapshot(.dir("root", [.file("leaf", 100)]))
        var o = SizeOverlay()
        o.applyDelta(node: fixture["leaf"], allocated: 30, logical: -20, in: fixture.snapshot)
        XCTAssertEqual(OverlaySource(fixture.snapshot, o).allocated(0), 130)
        XCTAssertEqual(OverlaySource(fixture.snapshot, o).logical(0), 80)
    }

    func test_audit_entries_have_no_file_lists() async throws {
        let w = World(), i = item(w, directory: true)
        let leaf = root + Data("/private-child".utf8); w.seed(leaf); w.childrenByPath[root] = [leaf]
        let r = await (try compressor(w)).compress(i)
        XCTAssertEqual(r.compressed, 1); XCTAssertEqual(w.logs.count, 1)
        let data = try JSONEncoder().encode(w.logs[0]), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-child")); XCTAssertTrue(text.contains("--verify"))
        XCTAssertEqual(w.logs[0].compression?.filesChanged, 1)
        XCTAssertEqual(w.logs[0].compression?.bytesBefore, 131072)
        XCTAssertEqual(w.logs[0].compression?.exitStatuses, [0])
        let manifest = CompressManifest(directory: w.manifestDirectory)
        let rows = try manifest.read(r.runID)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].path, leaf)
        XCTAssertEqual(rows[0].fileID, w.files[leaf]?.recorded.fileID)
        var st = Darwin.stat()
        XCTAssertEqual(lstat(manifest.url(r.runID).path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(w.manifestDirectory.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }

    func test_zero_files_inspected_is_failure() async throws {
        let w = World(), i = item(w, directory: true)
        let r = await (try compressor(w)).compress(i)
        XCTAssertEqual(r.inspected, 0); XCTAssertNotNil(r.refusal); XCTAssertTrue(w.calls.isEmpty)
    }

    func test_guards_identity_and_eligibility_are_rechecked() async throws {
        let live = World(), directory = item(live, directory: true)
        let paths = (0..<2).map { root + Data("/file\($0)".utf8) }
        paths.forEach { live.seed($0) }; live.childrenByPath[root] = paths
        live.afterRun = {
            if live.calls.count == 1 {
                live.files[paths[1]] = CompressionFile(facts: FileFacts(flags: UInt32(UF_IMMUTABLE), size: 131072,
                    blocks: 256, key: FileKey(dev: 7, ino: 20)), recorded: Recorded(fileID: 20, device: 7, isDirectory: false), allocated: 131072)
            }
        }
        let changed = await (try compressor(live, limit: 235)).compress(directory)
        XCTAssertEqual(changed.compressed, 1); XCTAssertEqual(live.calls.count, 1); XCTAssertEqual(changed.failed, [paths[1]])
        let swapped = World(), parentItem = item(swapped, directory: true)
        let parent = root + Data("/folder".utf8)
        let nested = (0..<2).map { parent + Data("/file\($0)".utf8) }
        swapped.seed(parent, id: 30, directory: true)
        nested.forEach { swapped.seed($0) }
        swapped.childrenByPath[root] = [parent]; swapped.childrenByPath[parent] = nested
        swapped.afterRun = {
            if swapped.calls.count == 1 { swapped.seed(parent, id: 999, directory: true) }
        }
        let replacement = await (try compressor(swapped, limit: 235)).compress(parentItem)
        XCTAssertEqual(replacement.compressed, 1); XCTAssertEqual(swapped.calls.count, 1)
        XCTAssertEqual(replacement.failed, [nested[1]], "A replaced proper ancestor must invalidate the later batch")
        for change in 0..<3 {
            let w = World(), i = item(w)
            if change == 0 { w.seed(root, id: 999) }
            if change == 1 { w.files[root] = CompressionFile(facts: FileFacts(nlink: 2, size: 131072, blocks: 256,
                key: FileKey(dev: 7, ino: 20)), recorded: i.recorded, allocated: 131072) }
            if change == 2 { w.files[root] = CompressionFile(facts: FileFacts(flags: UInt32(UF_IMMUTABLE), size: 131072,
                blocks: 256, key: FileKey(dev: 7, ino: 20)), recorded: i.recorded, allocated: 131072) }
            let r = await (try compressor(w)).compress(i)
            XCTAssertEqual(r.compressed, 0); XCTAssertTrue(w.calls.isEmpty)
        }
    }
}

private actor BatchLatch {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        await withCheckedContinuation { exitWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }; await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { exitWaiter?.resume(); exitWaiter = nil }
}
