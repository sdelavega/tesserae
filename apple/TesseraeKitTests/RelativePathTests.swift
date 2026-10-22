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

import XCTest
@testable import TesseraeKit

final class RelativePathTests: XCTestCase {
    func test_relative_path_from_root_name() {
        let t = TestSnapshot(.dir("/Volumes/USB321FD", [.dir("Projects", [.file("tesserae", 10)])]))
        XCTAssertEqual(joinedForDisplay(relativePath(of: t["tesserae"], in: t.snapshot, rootName: "USB321FD")), "USB321FD › Projects › tesserae")
        XCTAssertEqual(relativePath(of: 0, in: t.snapshot, rootName: "USB321FD"), ["USB321FD"])
        XCTAssertEqual(inspect(t["tesserae"], in: t.snapshot).displayPath, "USB321FD › Projects › tesserae")
        XCTAssertEqual(inspect(t["tesserae"], in: t.snapshot).rawPath, Data("/Volumes/USB321FD/Projects/tesserae".utf8))
    }
    func test_relative_path_neutralises_controls_and_bidi() {
        let t = TestSnapshot(.dir("/R", [.file("a\t\u{202e}b", 10)]))
        XCTAssertEqual(relativePath(of: 1, in: t.snapshot, rootName: "R\u{202e}"), ["R�", "a �b"])
    }
    func test_relative_path_non_utf8_name() {
        let t = TestSnapshot(.dir("/R", [.rawFile([0xff, 0x09, 0x61], key: "raw", 10)]))
        XCTAssertEqual(relativePath(of: 1, in: t.snapshot, rootName: "R"), ["R", "� a ⟨/wlh⟩"])
    }
}
