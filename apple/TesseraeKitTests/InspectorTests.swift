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
                subject: .node(
                    t["clip.MOV"], rawPath: Data("/Volumes/X/media/clip.MOV".utf8),
                    displayPath: "/Volumes/X/media/clip.MOV"),
                allocated: 8_192_000, logical: 8_000_123,
                kind: .fileKind(.video), modified: Date(timeIntervalSince1970: 1_700_000_900)))
        XCTAssertEqual(clip.node, t["clip.MOV"])
        XCTAssertEqual(clip.rawPath, Data("/Volumes/X/media/clip.MOV".utf8))
        XCTAssertEqual(clip.displayPath, "/Volumes/X/media/clip.MOV")
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
        XCTAssertEqual(media.displayPath, "/Volumes/X/media")
        XCTAssertEqual(media.rawPath, Data("/Volumes/X/media".utf8))
        XCTAssertEqual(media.allocated, 8_192_000 + 4096 + 8192 + 4096, "rolled up")
        XCTAssertEqual(media.logical, 8_000_123 + 12 + 5000 + 100, "rolled up")
        XCTAssertEqual(media.modified, Date(timeIntervalSince1970: 1_700_000_900), "the rolled-up time")
        let locked3 = inspect(t["locked3"], in: s)
        XCTAssertEqual(locked3.kind, .folder)
        XCTAssertNil(locked3.modified, "an unreadable folder has no time")
        XCTAssertEqual(
            FileKind.allCases.map(\.displayName), ["Video", "Image", "Audio", "Archive", "Document"])

        // Tiles that stand for several nodes: no node and no path (so no
        // action can take the display text for one), a title, no date.
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
        XCTAssertNil(info.node)
        XCTAssertNil(info.rawPath)
        XCTAssertNil(info.displayPath)
        XCTAssertEqual(info.title(locale: en), "\(n) smaller items — \(bytes)")
        XCTAssertEqual(info.kind.displayName, "Smaller items")
        let lockedInfo = inspect(tileAt: locked, in: tiles, snapshot: s)
        XCTAssertEqual(
            lockedInfo,
            InspectorInfo(subject: .unreadable(count: 17), allocated: 0, logical: 0, kind: .unreadable, modified: nil))
        XCTAssertNil(lockedInfo.node)
        XCTAssertNil(lockedInfo.rawPath)
        XCTAssertNil(lockedInfo.displayPath)
        XCTAssertEqual(lockedInfo.title(locale: en), "17 unreadable folders")
        XCTAssertEqual(lockedInfo.kind.displayName, "Unreadable folders")
        let fileTile = tiles.firstIndex { $0.node == t["big.bin"] }!
        XCTAssertEqual(inspect(tileAt: fileTile, in: tiles, snapshot: s), inspect(t["big.bin"], in: s))
    }

    /// Final review C1: a single-child chain keeps the whole view rect at
    /// every level, so the layout's depth saturates at 255. Hovering the
    /// aggregate at the bottom used to trap (`p.depth + 1` on a `UInt8`) and,
    /// at a saturated depth, could not find the parent anyway.
    @MainActor
    func test_hovering_tiles_below_a_saturated_depth_neither_traps_nor_loses_the_parent() throws {
        let tiny = (0..<2000).map { TestSnapshot.Spec.file("tiny\($0)", 1, logical: 3) }
        var level = TestSnapshot.Spec.dir("d256", [.file("big", 100_000_000, logical: 99)] + tiny)
        for d in stride(from: 255, through: 0, by: -1) { level = .dir("d\(d)", [level]) }
        let t = TestSnapshot(.dir("/R", [level]))
        let session = AppSession(snapshot: t.snapshot)
        session.resize(to: CGSize(width: 400, height: 300))
        let tiles = session.tiles
        XCTAssertEqual(tiles.map(\.depth).max(), 255, "precondition: the layout's depth saturates")
        let agg = try XCTUnwrap(tiles.firstIndex { $0.isAggregate }, "precondition: the tiny files collapse")
        XCTAssertEqual(tiles[agg].parent, t["d256"], "precondition: the aggregate is the bottom folder's")
        let parentTile = try XCTUnwrap(tiles.first { $0.node == t["d256"] })
        XCTAssertEqual(parentTile.depth, 255, "precondition: the parent's depth is saturated too")
        XCTAssertEqual(tiles[agg].depth, 255, "precondition: so is the aggregate's")
        let n = tiles[agg].aggregateCount
        XCTAssertGreaterThan(n, 1, "precondition: several tiny files collapsed")

        session.hover(tile: agg)
        XCTAssertEqual(
            session.inspector,
            InspectorInfo(
                subject: .aggregate(count: n, bytes: UInt64(n)), allocated: UInt64(n), logical: 3 * UInt64(n),
                kind: .aggregate, modified: nil))

        let big = try XCTUnwrap(tiles.firstIndex { $0.node == t["big"] })
        XCTAssertEqual(tiles[big].depth, 255, "precondition: a node tile below the saturation")
        session.hover(tile: big)
        let chain = (0...256).map { "d\($0)" }.joined(separator: "/")
        XCTAssertEqual(session.inspector?.node, t["big"])
        XCTAssertEqual(session.inspector?.displayPath, "/R/\(chain)/big")
        XCTAssertEqual(session.inspector?.rawPath, Data("/R/\(chain)/big".utf8))
        XCTAssertEqual(session.inspector?.logical, 99)
    }

    /// Final review I1: what an action may use is the node and its raw path,
    /// byte for byte; the display path is lossy and is for reading only.
    func test_a_node_carries_its_index_and_its_exact_raw_path() {
        let invalid: [UInt8] = [0x62, 0x61, 0x64, 0xFF, 0x6E]  // "bad", 0xFF, "n"
        let controls: [UInt8] = [0x63, 0x01, 0x0A, 0x09, 0x7F, 0xE2, 0x80, 0xAE, 0x7A]  // c SOH LF TAB DEL U+202E z
        let t = TestSnapshot(
            .dir("/R", [.rawFile(invalid, key: "invalid", 20), .rawFile(controls, key: "controls", 10)]))
        for (key, bytes) in [("invalid", invalid), ("controls", controls)] {
            let info = inspect(t[key], in: t.snapshot)
            XCTAssertEqual(info.node, t[key], key)
            XCTAssertEqual(info.rawPath, Data(Array("/R/".utf8) + bytes), key)
            XCTAssertEqual(info.rawPath, t.snapshot.rawPath(t[key]), key)
            XCTAssertNotNil(info.displayPath, key)
            XCTAssertNotEqual(
                info.displayPath.map { Data($0.utf8) }, info.rawPath, "precondition: \(key) displays lossily")
        }
    }

    func test_display_title_is_one_line_and_sanitised_like_labels() {
        let name = "a\u{2028}b\u{202E}c\u{85}d\u{200D}e"
        let t = TestSnapshot(.dir("/R", [.file(name, 10)]))
        let info = inspect(t[name], in: t.snapshot)
        XCTAssertTrue(info.title.contains("\u{2028}"), "precondition: the raw path keeps the separator")
        XCTAssertEqual(info.displayPath, info.title, "precondition: the path itself is untouched")
        XCTAssertEqual(info.displayTitle, "/R/a b\u{FFFD}c\u{FFFD}d\u{200D}e")
        XCTAssertFalse(info.displayTitle.contains { $0.isNewline })
        let aggregate = InspectorInfo(subject: .unreadable(count: 3), allocated: 0, logical: 0, kind: .unreadable, modified: nil)
        XCTAssertEqual(aggregate.displayTitle, aggregate.title)
    }
}
