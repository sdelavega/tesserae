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

import CoreGraphics
import Foundation
import XCTest

@testable import TesseraeKit

/// The hover inspector (spec §8: "full path, both sizes, type, dates").
final class InspectorTests: XCTestCase {
    func test_inspector_reports_both_sizes_kind_and_date() {
        let tiny = (0..<30).map { TestSnapshot.Spec.file("t\($0)", 1024, logical: UInt64(10 + $0), modified: 5) }
        let denied = (0..<17).map { TestSnapshot.Spec.denied("locked\($0)") }
        let t = TestSnapshot(
            .dir(
                "/Volumes/X", modified: 1_700_000_900,
                [
                    .dir(
                        "media", modified: 1_700_000_900,
                        [
                            .file("clip.MOV", 8_192_000, logical: 8_000_123, modified: 1_700_000_900),
                            .file("notes", 4096, logical: 12, modified: 1_600_000_000),
                            .file("data.xyz", 8192, logical: 5000, modified: -86_400),
                        ]),
                    .file("big.bin", 20_000_000, logical: 19_999_999, modified: 1_650_000_000),
                ] + tiny + denied))
        let s = t.snapshot

        let clip = inspect(t["clip.MOV"], in: s)
        XCTAssertEqual(
            clip,
            InspectorInfo(
                path: "/Volumes/X/media/clip.MOV", allocated: 8_192_000, logical: 8_000_123, kind: "Video",
                modified: Date(timeIntervalSince1970: 1_700_000_900)))
        XCTAssertNotEqual(clip.allocated, clip.logical, "precondition: the two sizes differ")
        XCTAssertEqual(inspect(t["notes"], in: s).kind, "File", "no extension")
        let xyz = inspect(t["data.xyz"], in: s)
        XCTAssertEqual(xyz.kind, "File", "an extension of no kind")
        XCTAssertEqual(xyz.modified, Date(timeIntervalSince1970: -86_400), "a time before 1970")

        let media = inspect(t["media"], in: s)
        XCTAssertEqual(media.kind, "Folder")
        XCTAssertEqual(media.path, "/Volumes/X/media")
        XCTAssertEqual(media.allocated, 8_192_000 + 4096 + 8192, "rolled up")
        XCTAssertEqual(media.logical, 8_000_123 + 12 + 5000, "rolled up")
        XCTAssertEqual(media.modified, Date(timeIntervalSince1970: 1_700_000_900), "the rolled-up time")
        XCTAssertEqual(inspect(t["locked3"], in: s).kind, "Folder")
        XCTAssertEqual(
            FileKind.allCases.map(\.displayName), ["Video", "Image", "Audio", "Archive", "Document"])

        // Tiles that stand for several nodes: no single path, no date.
        let tiles = squarify(s, root: s.root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let agg = tiles.indices.first { tiles[$0].isAggregate && !tiles[$0].isPermissionDenied }
        let locked = tiles.indices.first { tiles[$0].isAggregate && tiles[$0].isPermissionDenied }
        guard let agg, let locked else { return XCTFail("precondition: an aggregate and a collapsed strip") }
        let n = tiles[agg].aggregateCount
        XCTAssertGreaterThan(n, 1, "precondition: several items collapsed")
        let info = inspect(tileAt: agg, in: tiles, snapshot: s)
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(n) * 1024, countStyle: .file)
        // The tiny files tie on allocated, so they keep their order and the
        // tail is the last `n` of them.
        let tailLogical = (30 - Int(n)..<30).reduce(UInt64(0)) { $0 + UInt64(10 + $1) }
        XCTAssertEqual(
            info,
            InspectorInfo(
                path: "\(n) smaller items — \(bytes)", allocated: UInt64(n) * 1024, logical: tailLogical,
                kind: "Smaller items", modified: nil))
        XCTAssertEqual(
            inspect(tileAt: locked, in: tiles, snapshot: s),
            InspectorInfo(path: "17 unreadable folders", allocated: 0, logical: 0, kind: "Unreadable folders", modified: nil))
        let fileTile = tiles.firstIndex { $0.node == t["big.bin"] }!
        XCTAssertEqual(inspect(tileAt: fileTile, in: tiles, snapshot: s), inspect(t["big.bin"], in: s))
    }
}
