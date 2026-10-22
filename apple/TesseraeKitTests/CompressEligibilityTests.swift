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
import XCTest
@testable import TesseraeKit

final class CompressEligibilityTests: XCTestCase {
    private func eligible(_ path: String = "/Users/x/plain", _ facts: FileFacts = FileFacts(),
                          _ context: EligibilityContext = EligibilityContext()) -> SkipReason? {
        compressEligibility(path: Data(path.utf8), stat: facts, context: context)
    }
    func test_not_regular() {
        XCTAssertEqual(SkipReason.allCases.count, 14)
        for reason in SkipReason.allCases { XCTAssertFalse(reason.localizedDescription.isEmpty) }
        XCTAssertNil(eligible())
        XCTAssertEqual(eligible("/a", FileFacts(isRegular: false)), .notRegular)
    }
    func test_already_compressed() {
        XCTAssertNil(eligible())
        XCTAssertEqual(eligible("/a", FileFacts(flags: UInt32(UF_COMPRESSED))), .alreadyCompressed)
    }
    func test_hard_linked() {
        XCTAssertNil(eligible("/a", FileFacts(nlink: 1)))
        XCTAssertEqual(eligible("/a", FileFacts(nlink: 2)), .hardLinked)
    }
    func test_sparse() {
        XCTAssertNil(eligible("/a", FileFacts(size: 512, blocks: 1)))
        XCTAssertEqual(eligible("/a", FileFacts(size: 513, blocks: 1)), .sparse)
        XCTAssertNil(eligible("/a", FileFacts(blocks: UInt64.max)))
    }
    func test_cloud_only() {
        XCTAssertNil(eligible())
        XCTAssertEqual(eligible("/a", FileFacts(flags: UInt32(SF_DATALESS))), .cloudOnly)
    }
    func test_resource_fork() {
        XCTAssertNil(eligible("/a", FileFacts(hasResourceFork: false)))
        XCTAssertEqual(eligible("/a", FileFacts(hasResourceFork: true)), .resourceFork)
    }
    func test_empty() {
        XCTAssertNil(eligible("/a", FileFacts(size: 1)))
        XCTAssertEqual(eligible("/a", FileFacts(size: 0)), .empty)
    }
    func test_wont_shrink() {
        XCTAssertNil(eligible("/a.JPGx"))
        for ext in "jpg jpeg png heic gif webp mp4 mov m4v mkv avi mp3 m4a aac flac zip gz bz2 xz 7z rar zst icns pdf".split(separator: " ") {
            XCTAssertEqual(eligible("/a.\(ext.uppercased())"), .wontShrink)
        }
    }
    func test_live_database() {
        for ext in ["sqlite", "sqlite3", "sqlitedb", "db"] {
            let path = "/a.\(ext)"
            XCTAssertNil(eligible(path))
            for suffix in ["-wal", "-shm"] {
                XCTAssertEqual(eligible(path, FileFacts(), EligibilityContext(existingPaths: [Data((path + suffix).utf8)])), .liveDatabase)
            }
        }
        XCTAssertEqual(eligible("/a.realm"), .liveDatabase)
    }
    func test_vm_image() {
        XCTAssertNil(eligible("/a.dmgx/file"))
        for ext in "vmdk qcow2 utm pvm vbox vdi hds vmwarevm sparsebundle dmg".split(separator: " ") {
            XCTAssertEqual(eligible("/a.\(ext)"), .vmImage)
            XCTAssertEqual(eligible("/a.\(ext)/file"), .vmImage)
        }
    }
    func test_cloud_sync() {
        XCTAssertNil(eligible("/Users/x/MyLibrary/CloudStoragex/a"))
        XCTAssertNil(eligible("/Users/x/Dropboxx/a"))
        for component in ["Library/CloudStorage", "Library/Mobile Documents", "Dropbox", "Google Drive", "My Drive", "OneDrive"] {
            XCTAssertEqual(eligible("/Users/x/\(component)/a"), .cloudSync)
        }
    }
    func test_store_or_adobe_app() throws {
        XCTAssertNil(eligible("/a/ordinary.app/Contents/file"))
        for name in ["Adobe Photoshop", "aDoBe tool", "Creative Cloud"] {
            XCTAssertEqual(eligible("/a/\(name).app/Contents/file"), .storeOrAdobeApp)
        }
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let app = fixture.root.appendingPathComponent("Test.app")
        let receipt = app.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
        let path = app.appendingPathComponent("Contents/file").path
        XCTAssertNil(eligible(path))
        XCTAssertEqual(eligible(path, FileFacts(), EligibilityContext(existingPaths: [Data(receipt.path.utf8)])), .storeOrAdobeApp)
    }
    func test_open_for_writing() {
        let key = FileKey(dev: 5, ino: 8)
        let facts = FileFacts(key: key)
        XCTAssertNil(eligible("/a", facts))
        XCTAssertNil(eligible("/a", facts, EligibilityContext(openForWriting: [FileKey(dev: 6, ino: 8)])))
        XCTAssertEqual(eligible("/a", facts, EligibilityContext(openForWriting: [key])), .openForWriting)
    }
    func test_not_writable() {
        XCTAssertNil(eligible())
        XCTAssertEqual(eligible("/a", FileFacts(writable: false)), .notWritable)
    }
    func test_raw_path_bytes_survive() {
        let path = Data([47, 255, 46, 100, 98])
        XCTAssertNil(compressEligibility(path: path, stat: FileFacts(), context: EligibilityContext()))
        XCTAssertEqual(compressEligibility(path: path, stat: FileFacts(), context: EligibilityContext(existingPaths: [path + Data("-wal".utf8)])), .liveDatabase)
    }
}
