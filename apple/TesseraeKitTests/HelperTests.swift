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

final class HelperTests: XCTestCase, @unchecked Sendable {
    func test_helper_probe_has_only_async_entrypoints_and_no_blocking_shim() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: apple.appendingPathComponent("TesseraeKit/Reclaim/Helpers.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("public static func locateAsync"))
        XCTAssertTrue(source.contains("public static func supportsVerifyAsync"))
        for forbidden in ["DispatchSemaphore", "VerifyProbe", "func locate(", "func supportsVerify("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func test_locate_reports_missing_helper() async throws {
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let root = fixture.root.appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.empty"],
                                                       format: .xml, options: 0)
        try info.write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        switch await CompressionHelper.locateAsync(bundle: bundle) {
        case .failure(.missing): break
        default: XCTFail("Expected missing helper")
        }
    }

    func test_locate_validates_signature_and_verify_capability() async throws {
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let root = fixture.root.appendingPathComponent("Helper.bundle")
        let helpers = root.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.helper"],
                                                       format: .xml, options: 0)
        try info.write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let helper = helpers.appendingPathComponent("applesauce")
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/applesauce")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: built.path), "Run just applesauce first")
        try FileManager.default.copyItem(at: built, to: helper)
        let runner = SpawnRunner()
        let removed = await runner.run("/usr/bin/codesign", [Data("--remove-signature".utf8), Data(helper.path.utf8)])
        XCTAssertEqual(removed, .exited(0))
        switch await CompressionHelper.locateAsync(bundle: bundle) {
        case .failure(.unsigned): break
        default: XCTFail("Expected unsigned helper rejection")
        }
        let signed = await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", helper.path].map { Data($0.utf8) })
        XCTAssertEqual(signed, .exited(0))
        switch await CompressionHelper.locateAsync(bundle: bundle) {
        case .success(let url): XCTAssertEqual(url, helper)
        default: XCTFail("Expected valid ad-hoc helper acceptance")
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let thin = fixture.root.appendingPathComponent("thin-helper")
        let thinned = await runner.run("/usr/bin/lipo", [helper.path, "-thin", architecture, "-output", thin.path].map { Data($0.utf8) })
        XCTAssertEqual(thinned, .exited(0))
        var damaged = try Data(contentsOf: thin)
        XCTAssertGreaterThan(damaged.count, 4096)
        damaged[4096] ^= 1
        try damaged.write(to: helper)
        switch await CompressionHelper.locateAsync(bundle: bundle) {
        case .failure(.unsigned): break
        default: XCTFail("Expected tampered helper rejection")
        }
        // A signed executable without the capability must also be refused.
        let echo = try Data(contentsOf: URL(fileURLWithPath: "/bin/echo"))
        try echo.write(to: helper)
        let resigned = await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", helper.path].map { Data($0.utf8) })
        XCTAssertEqual(resigned, .exited(0))
        switch await CompressionHelper.locateAsync(bundle: bundle) {
        case .failure(.noVerifyFlag): break
        default: XCTFail("Expected missing --verify rejection")
        }
    }

    func test_tar_arguments_per_format() {
        let parent = Data([47, 112, 255])
        let name = Data([45, 110, 254])
        let flags: [ArchiveFormat: [String]] = [
            .zip: ["-c", "--format", "zip"], .tarXZ: ["-c", "-J", "--options", "xz:threads=0"], .tarZst: ["-c"]
        ]
        XCTAssertEqual(flags.count, 3)
        for format in flags.keys {
            let prefix = flags[format]! + ["--one-file-system"] + (format == .zip ? [] : ["--no-read-sparse"]) + ["-f", "-", "-C"]
            XCTAssertEqual(tarArguments(format, parent: parent, name: name),
                           prefix.map { Data($0.utf8) } + [parent, Data("--".utf8), name])
            XCTAssertEqual(format.fileExtension, format.rawValue)
        }
    }

    func test_capture_read_error_is_reported_instead_of_eof() async {
        let runner = SpawnRunner(captureRead: { _, _, _ in errno = EIO; return -1 })
        let result = await runner.runCapturing("/bin/echo", [Data("payload".utf8)])
        XCTAssertEqual(result.0, .captureFailed(errno: EIO))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func test_no_shell_and_minimal_environment() async {
        let runner = SpawnRunner()
        let environment = await runner.runCapturing("/usr/bin/env", [])
        XCTAssertEqual(environment.0, .exited(0))
        XCTAssertEqual(environment.stdout, Data("PATH=/usr/bin:/bin\n".utf8))
        XCTAssertTrue(environment.stderr.isEmpty)
        let bytes = Data([36, 40, 42, 59, 255])
        let echoed = await runner.runCapturing("/bin/echo", [bytes])
        XCTAssertEqual(echoed.0, .exited(0))
        XCTAssertEqual(echoed.stdout, bytes + Data([10]))
        let relative = await runner.run("echo", [])
        XCTAssertEqual(relative, .spawnFailed(errno: EINVAL))
        let nul = await runner.run("/bin/echo", [Data([65, 0, 66])])
        XCTAssertEqual(nul, .spawnFailed(errno: EINVAL))
        let missing = await runner.run("/nonexistent/tesserae-helper", [])
        XCTAssertEqual(missing, .spawnFailed(errno: ENOENT))
    }

    func test_stdout_descriptor_and_capture_draining() async throws {
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let outputFile = try fixture.file("archive-output")
        let fd = open(outputFile.path, O_RDWR | O_TRUNC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let result = await SpawnRunner().run("/bin/echo", [Data("archive".utf8)], stdoutFD: fd)
        XCTAssertEqual(result, .exited(0))
        XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0)
        var bytes = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(read(fd, &bytes, bytes.count), 8)
        XCTAssertEqual(Data(bytes), Data("archive\n".utf8))
        let output = await SpawnRunner().runCapturing("/usr/bin/seq", [Data("1".utf8), Data("50000".utf8)])
        XCTAssertEqual(output.0, .exited(0))
        XCTAssertGreaterThan(output.stdout.count, 200_000)
        XCTAssertTrue(output.stdout.suffix(6) == Data("50000\n".utf8))
        let error = await SpawnRunner().runCapturing("/usr/bin/tar", [Data("--invalid-tesserae-option".utf8)])
        XCTAssertEqual(error.0, .exited(1))
        XCTAssertFalse(error.stderr.isEmpty)
    }
}
