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

import TesseraeFFI
import TesseraeKit
import XCTest

/// The first link of the Rust static library into Swift: the framework calls
/// into `libtesserae.a`, and Swift sees `TessNode` with the layout the C
/// header (and so the Rust `#[repr(C)]` type) has.
final class LinkTests: XCTestCase {
    func test_links_the_rust_library_and_reads_abi_version() {
        XCTAssertEqual(TesseraeKit.abiVersion, 1)
    }

    func test_node_layout_matches_the_header() {
        XCTAssertEqual(MemoryLayout<TessNode>.size, 48)
        XCTAssertEqual(MemoryLayout<TessNode>.offset(of: \TessNode.modified), 40)
    }
}
