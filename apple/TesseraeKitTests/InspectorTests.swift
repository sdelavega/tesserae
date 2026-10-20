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
    private let en = Locale(identifier: "en_US")

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
                            .file("undated.pdf", 4096, logical: 100, modified: 0),
                        ]),
                    .file("big.bin", 20_000_000, logical: 19_999_999, modified: 1_650_000_000),
                ] + tiny + denied))
        let s = t.snapshot

        let clip = inspect(t["clip.MOV"], in: s)
        XCTAssertEqual(
            clip,
            InspectorInfo(
                subject: .node(path: "/Volumes/X/media/clip.MOV"), allocated: 8_192_000, logical: 8_000_123,
                kind: .fileKind(.video), modified: Date(timeIntervalSince1970: 1_700_000_900)))
        XCTAssertEqual(clip.path, "/Volumes/X/media/clip.MOV")
        XCTAssertEqual(clip.title, "/Volumes/X/media/clip.MOV")
        XCTAssertEqual(clip.kind.displayName, "Video")
        XCTAssertNotEqual(clip.allocated, clip.logical, "precondition: the two sizes differ")
        XCTAssertEqual(inspect(t["notes"], in: s).kind, .file, "no extension")
        let xyz = inspect(t["data.xyz"], in: s)
        XCTAssertEqual(xyz.kind, .file, "an extension of no kind")
        XCTAssertEqual(xyz.kind.displayName, "File")
        XCTAssertEqual(xyz.modified, Date(timeIntervalSince1970: -86_400), "a time before 1970")
        let undated = inspect(t["undated.pdf"], in: s)
        XCTAssertEqual(undated.kind, .fileKind(.documents))
        XCTAssertNil(undated.modified, "a stored 0 is no time, not 1970")

        let media = inspect(t["media"], in: s)
        XCTAssertEqual(media.kind, .folder)
        XCTAssertEqual(media.kind.displayName, "Folder")
        XCTAssertEqual(media.path, "/Volumes/X/media")
        XCTAssertEqual(media.allocated, 8_192_000 + 4096 + 8192 + 4096, "rolled up")
        XCTAssertEqual(media.logical, 8_000_123 + 12 + 5000 + 100, "rolled up")
        XCTAssertEqual(media.modified, Date(timeIntervalSince1970: 1_700_000_900), "the rolled-up time")
        let locked3 = inspect(t["locked3"], in: s)
        XCTAssertEqual(locked3.kind, .folder)
        XCTAssertNil(locked3.modified, "an unreadable folder has no time")
        XCTAssertEqual(
            FileKind.allCases.map(\.displayName), ["Video", "Image", "Audio", "Archive", "Document"])

        // Tiles that stand for several nodes: no path (so no action can take
        // the display text for one), a title, no date.
        let tiles = squarify(s, root: s.root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let agg = tiles.indices.first { tiles[$0].isAggregate && !tiles[$0].isPermissionDenied }
        let locked = tiles.indices.first { tiles[$0].isAggregate && tiles[$0].isPermissionDenied }
        guard let agg, let locked else { return XCTFail("precondition: an aggregate and a collapsed strip") }
        let n = tiles[agg].aggregateCount
        XCTAssertGreaterThan(n, 1, "precondition: several items collapsed")
        let info = inspect(tileAt: agg, in: tiles, snapshot: s)
        let bytes = displaySize(UInt64(n) * 1024, locale: en)
        // The tiny files tie on allocated, so they keep their order and the
        // tail is the last `n` of them.
        let tailLogical = (30 - Int(n)..<30).reduce(UInt64(0)) { $0 + UInt64(10 + $1) }
        XCTAssertEqual(
            info,
            InspectorInfo(
                subject: .aggregate(count: n, bytes: UInt64(n) * 1024), allocated: UInt64(n) * 1024,
                logical: tailLogical, kind: .aggregate, modified: nil))
        XCTAssertNil(info.path)
        XCTAssertEqual(info.title(locale: en), "\(n) smaller items — \(bytes)")
        XCTAssertEqual(info.kind.displayName, "Smaller items")
        let lockedInfo = inspect(tileAt: locked, in: tiles, snapshot: s)
        XCTAssertEqual(
            lockedInfo,
            InspectorInfo(subject: .unreadable(count: 17), allocated: 0, logical: 0, kind: .unreadable, modified: nil))
        XCTAssertNil(lockedInfo.path)
        XCTAssertEqual(lockedInfo.title(locale: en), "17 unreadable folders")
        XCTAssertEqual(lockedInfo.kind.displayName, "Unreadable folders")
        let fileTile = tiles.firstIndex { $0.node == t["big.bin"] }!
        XCTAssertEqual(inspect(tileAt: fileTile, in: tiles, snapshot: s), inspect(t["big.bin"], in: s))
    }

    func test_display_title_is_one_line_and_sanitised_like_labels() {
        let name = "a\u{2028}b\u{202E}c\u{85}d\u{200D}e"
        let t = TestSnapshot(.dir("/R", [.file(name, 10)]))
        let info = inspect(t[name], in: t.snapshot)
        XCTAssertTrue(info.title.contains("\u{2028}"), "precondition: the raw path keeps the separator")
        XCTAssertEqual(info.path, info.title, "precondition: the path itself is untouched")
        XCTAssertEqual(info.displayTitle, "/R/a b\u{FFFD}c\u{FFFD}d\u{200D}e")
        XCTAssertFalse(info.displayTitle.contains { $0.isNewline })
        let aggregate = InspectorInfo(subject: .unreadable(count: 3), allocated: 0, logical: 0, kind: .unreadable, modified: nil)
        XCTAssertEqual(aggregate.displayTitle, aggregate.title)
    }
}
