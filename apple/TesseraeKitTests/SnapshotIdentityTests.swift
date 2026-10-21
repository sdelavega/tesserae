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

final class SnapshotIdentityTests: XCTestCase {
    func test_fileID_and_rootDevice_match_lstat() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tess-identity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data("identity".utf8).write(to: root.appendingPathComponent("file"))
        try fm.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("symlink").path, withDestinationPath: "file")
        try fm.linkItem(at: root.appendingPathComponent("file"), to: root.appendingPathComponent("hardlink"))
        let scan = try XCTUnwrap(tess_scan_begin(root.path, nil))
        while tess_scan_status(scan) == Int32(TESS_STATUS_RUNNING) { usleep(1000) }
        XCTAssertEqual(tess_scan_status(scan), Int32(TESS_STATUS_FINISHED))
        let snapshot = Snapshot(handle: try XCTUnwrap(tess_scan_finish(scan)))
        XCTAssertEqual(snapshot.nodes.count, 5)
        var links: [UInt64] = []
        for i in 0..<UInt32(snapshot.nodes.count) {
            var metadata = stat()
            let path = snapshot.rawPath(i) + Data([0])
            let result = path.withUnsafeBytes { bytes in
                lstat(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), &metadata)
            }
            XCTAssertEqual(result, 0)
            XCTAssertNotEqual(metadata.st_ino, 0)
            XCTAssertEqual(snapshot.fileID(i), metadata.st_ino)
            if i == snapshot.root { XCTAssertEqual(snapshot.rootDevice, metadata.st_dev) }
            if ["file", "hardlink"].contains(snapshot.name(i)) {
                links.append(try XCTUnwrap(snapshot.fileID(i)))
            }
        }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0], links[1])
    }
}
