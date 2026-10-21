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

import Foundation
import XCTest
import TesseraeKit

final class DiskImageFixture: @unchecked Sendable {
    let name = "Tesserae-test-" + UUID().uuidString
    private(set) var root: URL!
    private var directory: URL!
    private var image: URL!
    private var attached = false

    @discardableResult
    static func command(_ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DiskImageFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
        return data
    }

    func setUp() throws {
        let info = try Self.command(["info"])
        guard !String(decoding: info, as: UTF8.self).contains(name) else {
            XCTFail("Unique fixture name was already attached")
            throw NSError(domain: "DiskImageFixture", code: 2)
        }
        directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        image = directory.appendingPathComponent("fixture.sparseimage")
        var attachAttempted = false
        do {
            try Self.command(["create", "-size", "64m", "-fs", "APFS", "-type", "SPARSE",
                              "-volname", name, image.path])
            // Private mountpoint: tests never access anything under /Volumes.
            root = directory.appendingPathComponent("mnt")
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw NSError(domain: "DiskImageFixture", code: 1)
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            attachAttempted = true
            try Self.command(["attach", "-nobrowse", "-noverify", "-owners", "on", "-mountpoint", root.path, image.path])
            let expected = Data(root.resolvingSymlinksInPath().path.utf8)
            guard try volumeRoot(of: expected) == expected else {
                throw NSError(domain: "DiskImageFixture", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Fixture path is not an attached volume"])
            }
            attached = true
        } catch {
            if attachAttempted, let root {
                let expected = Data(root.resolvingSymlinksInPath().path.utf8)
                attached = (try? volumeRoot(of: expected)) == expected
            }
            try tearDown()
            throw error
        }
    }

    func detach(force: Bool = false) throws {
        guard attached else { return }
        try Self.command(["detach"] + (force ? ["-force"] : []) + [root.path])
        attached = false
    }

    func tearDown() throws {
        if attached {
            do { try detach() } catch { try detach(force: true) }
        }
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        let info = try Self.command(["info"])
        XCTAssertFalse(String(decoding: info, as: UTF8.self).contains(name))
    }

    func file(_ name: String) throws -> URL {
        let parent = root.appendingPathComponent("tree/nested")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }
}
