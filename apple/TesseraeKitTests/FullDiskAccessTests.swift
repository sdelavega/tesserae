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

final class FullDiskAccessTests: XCTestCase {
    let candidates = [URL(fileURLWithPath: "/fixture/Mail", isDirectory: true),
                      URL(fileURLWithPath: "/fixture/TCC.db")]

    func result(_ errnos: [Int32]) -> AccessProbeResult {
        XCTAssertEqual(errnos.count, candidates.count, "precondition: one errno per candidate")
        let inputs = Dictionary(uniqueKeysWithValues: zip(candidates, errnos))
        let result = AccessProbe(candidates: candidates, open: { inputs[$0]! }).inspect()
        XCTAssertEqual(result.candidates.map(\.path), candidates.map(\.path))
        XCTAssertEqual(result.candidates.map(\.errno), errnos, "every candidate must be probed")
        return result
    }

    func test_all_candidates_missing_is_indeterminate_not_granted() {
        XCTAssertEqual(result([ENOENT, ENOENT]).state, .unknown)
        XCTAssertEqual(AccessProbe(candidates: [], open: { _ in XCTFail("empty list"); return 0 }).probe(), .unknown)
    }
    func test_one_readable_candidate_is_granted() {
        XCTAssertEqual(result([0, ENOENT]).state, .granted)
        XCTAssertEqual(result([ENOENT, 0]).state, .granted)
        XCTAssertEqual(result([0, 0]).state, .granted)
        XCTAssertEqual(AccessProbe(candidates: candidates, open: { _ in 0 }).probe(), .granted)
    }
    func test_eperm_on_an_existing_candidate_is_denied() {
        let r = result([EPERM, ENOENT])
        XCTAssertEqual(r.state, .denied(evidence: "/fixture/Mail: errno 1 (EPERM)"))
        XCTAssertEqual(r.evidence, "/fixture/Mail: errno 1 (EPERM)")
    }
    func test_mixed_eperm_and_readable_is_denied_in_either_order() {
        for errors: [Int32] in [[0, EPERM], [EPERM, 0], [EACCES, EPERM]] {
            let r = result(errors)
            guard case .denied(let evidence) = r.state else { XCTFail("\(errors): \(r.state)"); continue }
            let index = errors.firstIndex(of: EPERM)!
            XCTAssertTrue(evidence.contains(candidates[index].path))
            XCTAssertTrue(evidence.contains("errno 1 (EPERM)"))
        }
    }
    func test_other_errno_is_unknown_with_evidence_even_when_one_is_readable() {
        for errors: [Int32] in [[0, EACCES], [EACCES, 0], [EACCES, ENOENT]] {
            let r = result(errors)
            XCTAssertEqual(r.state, .unknown)
            let index = errors.firstIndex(of: EACCES)!
            XCTAssertEqual(r.evidence, "\(candidates[index].path): errno 13")
        }
    }
    func test_default_candidates_are_user_paths_with_directory_flags() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual([URL].defaultCandidates.map(\.path), [
            "\(home)/Library/Mail", "\(home)/Library/Messages", "\(home)/Library/Safari",
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db"])
        XCTAssertEqual([URL].defaultCandidates.map(\.hasDirectoryPath), [true, true, true, false])
    }
    func test_real_open_handles_file_directory_and_missing_without_changing_contents() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("candidate")
        let bytes = Data("private fixture".utf8)
        try bytes.write(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "precondition")
        XCTAssertEqual(AccessProbe.realOpen(file), 0)
        XCTAssertEqual(AccessProbe.realOpen(URL(fileURLWithPath: root.path)), 0)
        XCTAssertEqual(AccessProbe.realOpen(root.appendingPathComponent("absent")), ENOENT)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
