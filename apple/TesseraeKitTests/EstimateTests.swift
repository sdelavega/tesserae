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

import Compression
import Darwin
import XCTest
@testable import TesseraeKit

final class EstimateTests: XCTestCase {
    func test_estimate_ignores_incompressible_samples() {
        var state: UInt64 = 0x123456789abcdef
        let random = Data((0..<65536).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        XCTAssertGreaterThan(Set(random).count, 250)
        let files = [(Data("/a".utf8), UInt64(1_048_576))]
        XCTAssertEqual(SampleEstimate.compress(files: files) { _, _ in random }, 0)
        XCTAssertGreaterThan(SampleEstimate.compress(files: files) { _, n in Data(repeating: 0, count: n) }, 1_000_000)
    }
    func test_estimate_caps_at_200_files_and_1_mib() {
        let files = (1...205).map { (Data("/\($0)".utf8), UInt64($0) * 1_048_576) }
        var paths: [Data] = []
        let saved = SampleEstimate.compress(files: files) { path, count in
            paths.append(path)
            XCTAssertEqual(count, 1_048_576)
            return Data(repeating: 0, count: count)
        }
        XCTAssertGreaterThan(saved, 0)
        XCTAssertEqual(paths.count, 200)
        XCTAssertEqual(paths.first, Data("/205".utf8))
        XCTAssertEqual(paths.last, Data("/6".utf8))
    }
    func test_archive_algorithms_and_unreadable_samples() {
        let files = [(Data("/a".utf8), UInt64(65536))]
        for (f, algorithm) in [(ArchiveFormat.zip, COMPRESSION_ZLIB), (.tarXZ, COMPRESSION_LZMA),
                               (.tarZst, COMPRESSION_LZMA), (.appleArchiveFast, COMPRESSION_LZFSE),
                               (.appleArchiveSmallest, COMPRESSION_LZMA)] {
            XCTAssertEqual(SampleEstimate.algorithm(for: f), algorithm)
            let saved = SampleEstimate.archive(f, files: files) { _, n in Data(repeating: 0, count: n) }
            XCTAssertGreaterThan(saved, 60_000)
        }
        XCTAssertEqual(SampleEstimate.compress(files: files) { _, _ in nil }, 0)
        XCTAssertEqual(SampleEstimate.compress(files: []) { _, _ in XCTFail("No files"); return nil }, 0)
        XCTAssertEqual(SampleEstimate.compress(files: files) { _, _ in Data() }, 0)
    }
    func test_sampled_savings_are_exact_and_only_unsampled_bytes_are_extrapolated() {
        var state: UInt64 = 9
        let random = Data((0..<1_048_576).map { _ -> UInt8 in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let zero = Data(repeating: 0, count: 65536)
        let exact = SampleEstimate.compress(files: [(Data("/good".utf8), 65536)]) { _, _ in zero }
        XCTAssertGreaterThan(exact, 60_000)
        let files: [(Data, UInt64)] = [(Data("/bad".utf8), 2_097_152), (Data("/good".utf8), 65536)]
        let estimate = SampleEstimate.compress(files: files) { path, _ in path == Data("/bad".utf8) ? random : zero }
        XCTAssertEqual(estimate, exact * 17)
    }
    func test_sample_reader_no_follow_and_dataless() throws {
        let fixture = DiskImageFixture()
        try fixture.setUp()
        defer { try? fixture.tearDown() }
        let url = fixture.root.appendingPathComponent("sample")
        try Data(repeating: 7, count: 131072).write(to: url)
        XCTAssertEqual(SampleEstimate.readSample(Data(url.path.utf8), 65536)?.count, 65536)
        let link = fixture.root.appendingPathComponent("link")
        XCTAssertEqual(symlink(url.path, link.path), 0)
        XCTAssertNil(SampleEstimate.readSample(Data(link.path.utf8), 65536))
        XCTAssertTrue(SampleEstimate.mayRead(mode: UInt16(S_IFREG), flags: 0))
        XCTAssertFalse(SampleEstimate.mayRead(mode: UInt16(S_IFREG), flags: UInt32(SF_DATALESS)))
        XCTAssertFalse(SampleEstimate.mayRead(mode: UInt16(S_IFDIR), flags: 0))
    }
}
