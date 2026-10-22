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

@MainActor
final class LiveCompressTests: XCTestCase {
    func fixture(size: String = "4g") throws -> (DiskImageFixture, URL) {
        guard ProcessInfo.processInfo.environment["TESSERAE_LIVE_COMPRESS"] == "1" else {
            throw XCTSkip("Opt in with TESSERAE_LIVE_COMPRESS=1; tests create their own disposable APFS image")
        }
        let f = DiskImageFixture(); try f.setUp(size: size)
        do {
            let root = f.root.appendingPathComponent("compress/nested")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(".tesserae-live-test"))
            try validate(root, mount: f.root)
            return (f, root)
        } catch { try f.tearDown(); throw error }
    }
    func validate(_ root: URL, mount: URL) throws {
        let root = root.resolvingSymlinksInPath(), mount = mount.resolvingSymlinksInPath()
        XCTAssertEqual(try volumeRoot(of: Data(root.path.utf8)), Data(mount.path.utf8))
        guard root.pathComponents.starts(with: mount.pathComponents),
              root.pathComponents.count >= mount.pathComponents.count + 2 else { throw Failure.containment }
        var s = Darwin.stat()
        guard lstat(root.appendingPathComponent(".tesserae-live-test").path, &s) == 0,
              s.st_mode & S_IFMT == S_IFREG else { throw Failure.containment }
    }
    enum Failure: Error { case containment, helper }
    func helper() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/DerivedData/Build/Products/Release/Tesserae.app/Contents/Helpers/applesauce")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw Failure.helper }
        return url
    }
    func item(_ url: URL) throws -> ReclaimItem {
        let raw = Data(url.path.utf8), fs = ProductionCompressionFileSystem()
        let f = try XCTUnwrap(fs.inspect(raw))
        return ReclaimItem(nodeIndex: 1, path: raw, recorded: f.recorded, recordedSize: f.allocated, verdict: .ok,
                           warnings: url.pathExtension == "app" ? [.appBundleCompress] : [], action: .compress)
    }
    func compressor(root: URL, mount: URL, runner: any HelperRunner = ProductionHelperRunner(), argvLimit: Int = 256 * 1024) throws -> Compressor {
        try validate(root, mount: mount)
        let raw = Data(root.path.utf8), fs = ProductionCompressionFileSystem()
        return Compressor(helper: try helper(), runner: ContainedCompressionRunner(root: root, inner: runner), files: fs,
            openFiles: LibprocOpenFilesProbe(), log: ReclaimLog(directory: root.appendingPathComponent("audit")),
            manifests: CompressManifest(directory: root.appendingPathComponent("audit/manifests")),
            context: GuardContext(scanRoot: raw, volumeRoot: Data(mount.path.utf8),
                scanRootDevice: try XCTUnwrap(fs.inspect(raw)).recorded.device,
                appBundle: URL(fileURLWithPath: "/Applications/Tesserae.app"), home: Data("/Users/tester".utf8)), argvLimit: argvLimit)
    }
    func write(_ url: URL, bytes: Int = 131072) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url, options: .withoutOverwriting)
    }
    func digest(_ raw: Data) throws -> SHA256.Digest {
        let fd = (raw + Data([0])).withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw Failure.containment }; defer { close(fd) }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw Failure.containment }; if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize()
    }
    func test_round_trip_preserves_sha256() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let tree = root.appendingPathComponent("corpus")
        let urls = [tree.appendingPathComponent("text"), tree.appendingPathComponent("nested/-name"),
                    tree.appendingPathComponent("small"), tree.appendingPathComponent("empty"), tree.appendingPathComponent("big")]
        for (url, size) in zip(urls, [131072, 262144, 13, 0, 65 * 1024 * 1024]) { try write(url, bytes: size) }
        let rejected = Data(tree.path.utf8) + Data([47, 255])
        let probeFD = (rejected + Data([0])).withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        XCTAssertEqual(probeFD, -1); XCTAssertEqual(errno, EILSEQ, "Measured APFS refuses non-UTF-8 names; raw argv is covered by the fake runner")
        if probeFD >= 0 { close(probeFD) }
        let raw = Data(tree.appendingPathComponent("unicode-é").path.utf8)
        let fd = (raw + Data([0])).withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        XCTAssertGreaterThanOrEqual(fd, 0, "raw filename errno=\(errno)"); guard fd >= 0 else { return }
        let data = Data(repeating: 65, count: 131072)
        XCTAssertEqual(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, data.count); close(fd)
        let paths = urls.map { Data($0.path.utf8) } + [raw]
        let before = try paths.map { try digest($0) }; XCTAssertEqual(before.count, 6)
        let c = try compressor(root: root, mount: f.root)
        let result = await c.compress(try item(tree))
        XCTAssertEqual(result.compressed, 4); XCTAssertEqual(result.failed, [Data(urls[2].path.utf8)], "Sub-block text does not beat the helper ratio threshold")
        let undo = await c.decompress(run: result.runID)
        XCTAssertEqual(undo.compressed, result.compressed)
        XCTAssertEqual(try paths.map { try digest($0) }, before)
    }
    func test_hard_link_sparse_resource_fork_untouched() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let tree = root.appendingPathComponent("excluded")
        let hard = tree.appendingPathComponent("hard"), sparse = tree.appendingPathComponent("sparse"), fork = tree.appendingPathComponent("fork")
        try write(hard); try FileManager.default.linkItem(at: hard, to: tree.appendingPathComponent("link"))
        try write(sparse, bytes: 0)
        let fd = open(sparse.path, O_WRONLY); XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 1024 * 1024), 0); close(fd)
        try write(fork)
        XCTAssertEqual("fork".withCString { setxattr(fork.path, "com.apple.ResourceFork", $0, 4, 0, 0) }, 0)
        let symlink = tree.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: hard)
        let fs = ProductionCompressionFileSystem(), paths = [hard, sparse, fork].map { Data($0.path.utf8) }
        let before = try paths.map { try XCTUnwrap(fs.inspect($0)).recorded.fileID }
        let hashes = try paths.map { try digest($0) }
        let r = await (try compressor(root: root, mount: f.root)).compress(try item(tree))
        XCTAssertEqual(r.compressed, 0); XCTAssertEqual(r.skipped[.hardLinked], 2)
        XCTAssertEqual(r.skipped[.sparse], 1); XCTAssertEqual(r.skipped[.resourceFork], 1); XCTAssertEqual(r.skipped[.notRegular], 1)
        XCTAssertEqual(try paths.map { try XCTUnwrap(fs.inspect($0)).recorded.fileID }, before)
        XCTAssertEqual(try paths.map { try digest($0) }, hashes)
        XCTAssertEqual(getxattr(fork.path, "com.apple.ResourceFork", nil, 0, 0, 0), 4)
    }
    func test_kill_mid_run_leaves_no_truncated_file() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        for suspended in [true, false] {
            let tree = root.appendingPathComponent(suspended ? "between" : "during")
            let urls = (0..<4).map { tree.appendingPathComponent("file\($0)") }
            for (index, url) in urls.enumerated() { try write(url, bytes: (index == 0 ? 256 : 65) * 1024 * 1024) }
            let hashes = try urls.map { try digest(Data($0.path.utf8)) }; XCTAssertEqual(hashes.count, 4)
            let killer = KillingCompressionRunner(suspended: suspended)
            let limit = suspended ? Compressor.argvBytes(executable: try helper().path,
                args: Compressor.compressFlags + [Data(urls[0].path.utf8)]) + 1 : 256 * 1024
            let r = await (try compressor(root: root, mount: f.root, runner: killer, argvLimit: limit)).compress(try item(tree))
            XCTAssertEqual(killer.signal, SIGKILL); XCTAssertFalse(r.failed.isEmpty)
            if suspended { XCTAssertEqual(r.compressed, 1); XCTAssertGreaterThan(killer.calls, 1) }
            else { XCTAssertTrue(killer.observedTemporaryWrite, "Kill only after a temporary resource fork has been written") }
            XCTAssertEqual(try urls.map { try digest(Data($0.path.utf8)) }, hashes)
        }
    }
    func test_nearly_full_image_fails_safely() async throws {
        let (f, root) = try fixture(size: "256m"); defer { XCTAssertNoThrow(try f.tearDown()) }
        let url = root.appendingPathComponent("leaf"); try write(url)
        let original = try digest(Data(url.path.utf8))
        let fs = ProductionCompressionFileSystem(), rawRoot = Data(root.path.utf8)
        let filler = root.appendingPathComponent("filler")
        XCTAssertTrue(FileManager.default.createFile(atPath: filler.path, contents: nil))
        let handle = try FileHandle(forWritingTo: filler)
        let block = Data(repeating: 66, count: 1024 * 1024)
        while let free = fs.freeSpace(rawRoot), free > 16 * 1024 * 1024 { try handle.write(contentsOf: block) }
        try handle.close()
        XCTAssertLessThanOrEqual(try XCTUnwrap(fs.freeSpace(rawRoot)), 16 * 1024 * 1024)
        let r = await (try compressor(root: root, mount: f.root)).compress(try item(url))
        XCTAssertNotNil(r.refusal); XCTAssertLessThan(try XCTUnwrap(r.availableFreeBytes), r.requiredFreeBytes!)
        XCTAssertEqual(try digest(Data(url.path.utf8)), original)
    }
    func test_app_bundle_signature_still_verifies() async throws {
        let (f, root) = try fixture(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let app = root.appendingPathComponent("Fixture.app"), executable = app.appendingPathComponent("Contents/MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try write(app.appendingPathComponent("Contents/Resources/text"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "fixture", "CFBundleIdentifier": "test.tesserae.compress"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let signed = await SpawnRunner().run("/usr/bin/codesign", ["--force", "--sign", "-", app.path].map { Data($0.utf8) })
        XCTAssertEqual(signed, .exited(0))
        let r = await (try compressor(root: root, mount: f.root)).compress(try item(app), confirmedWarnings: [.appBundleCompress])
        XCTAssertGreaterThan(r.compressed, 0); XCTAssertEqual(r.signatureStatus, 0)
        let verified = await SpawnRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path].map { Data($0.utf8) })
        XCTAssertEqual(verified, .exited(0))
    }
}

private struct ContainedCompressionRunner: HelperRunner {
    let root: URL
    let inner: any HelperRunner
    func run(_ exe: URL, _ args: [Data]) async -> Int32 {
        let prefix = Data(root.path.utf8), files = args.dropFirst(args.first == Data("compress".utf8) ? 7 : 2)
        guard !files.isEmpty, files.allSatisfy({ pathIsWithin($0, root: prefix) }) else { XCTFail("Helper escaped fixture"); return -1 }
        return await inner.run(exe, args)
    }
}

private final class KillingCompressionRunner: HelperRunner, @unchecked Sendable {
    let suspended: Bool
    var signal: Int32 = 0
    var calls = 0
    var observedTemporaryWrite = false
    init(suspended: Bool) { self.suspended = suspended }
    private static func hasTemporaryWrite(in parent: URL) -> Bool {
        guard let entries = FileManager.default.enumerator(at: parent, includingPropertiesForKeys: nil) else { return false }
        for case let temp as URL in entries where temp.lastPathComponent.hasPrefix("applesauce_tmp") {
            if getxattr(temp.path, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) > 0 { return true }
        }
        return false
    }
    func run(_ exe: URL, _ args: [Data]) async -> Int32 {
        calls += 1
        if suspended && calls == 1 { return await ProductionHelperRunner().run(exe, args) }
        return await Task.detached { [self] in
            let allocations = ([Data(exe.path.utf8)] + args + [Data("PATH=/usr/bin:/bin".utf8)]).map { bytes in
                let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
                for (i,b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }; p[bytes.count] = 0; return p
            }
            defer { allocations.forEach { $0.deallocate() } }
            var argv = allocations.dropLast().map(Optional.some) + [nil], envp = [Optional(allocations.last!), nil]
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
            if suspended { posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED)) }
            var pid: pid_t = 0
            guard posix_spawn(&pid, exe.path, nil, &attributes, &argv, &envp) == 0 else { return -1 }
            if !suspended {
                let parent = URL(fileURLWithPath: String(decoding: args[7], as: UTF8.self)).deletingLastPathComponent()
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline && !observedTemporaryWrite {
                    observedTemporaryWrite = Self.hasTemporaryWrite(in: parent)
                    if !observedTemporaryWrite { usleep(100) }
                }
            }
            XCTAssertEqual(kill(pid, SIGKILL), 0)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            signal = status & 0x7f
            return -signal
        }.value
    }
}
