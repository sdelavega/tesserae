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

/// Tile labels (spec §8 "Labels"): placement, truncation, and the overlay's
/// ink and fade.
final class LabelTests: XCTestCase {
    /// 7 pt per character, 12 pt tall: deterministic, no font involved.
    private let measure: (String) -> CGSize = { CGSize(width: 7 * CGFloat($0.count), height: 12) }

    private func tile(_ node: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Tile {
        Tile(rect: CGRect(x: x, y: y, width: w, height: h), node: node, depth: 1)
    }

    func test_labels_only_where_they_fit() {
        let t = TestSnapshot(
            .dir(
                "/R",
                [
                    .file("movie.mov", 4_200_000_000),
                    .dir("pack", [.file("inner.bin", 1_000_000_000)]),
                ]))
        let s = t.snapshot
        let text = "movie.mov  4.2 GB"
        XCTAssertEqual(measure(text), CGSize(width: 119, height: 12), "precondition: the label is 119 x 12")

        // Exactly the label plus 4 pt on every side: it fits, 4 pt in from the corner.
        let exact = placeLabels([tile(t["movie.mov"], 10, 20, 127, 20)], in: s, measure: measure)
        XCTAssertEqual(exact, [PlacedLabel(rect: CGRect(x: 14, y: 24, width: 119, height: 12), text: text)])

        // One point too narrow for the full text: the name is cut, not the size.
        let narrow = placeLabels([tile(t["movie.mov"], 0, 0, 126, 20)], in: s, measure: measure)
        XCTAssertEqual(narrow.count, 1)
        XCTAssertNotEqual(narrow.first?.text, text)
        XCTAssertTrue(narrow.first?.text.hasSuffix("  4.2 GB") ?? false)

        // The label alone would fit these, without the padding: 119 x 12 in a
        // 119 x 12 tile, or one point short of the padding in either axis.
        for (w, h) in [(119.0, 12.0), (127.0, 19.0), (127.0, 12.0), (8.0, 8.0), (9.0, 9.0)] as [(CGFloat, CGFloat)] {
            let labels = placeLabels([tile(t["movie.mov"], 0, 0, w, h)], in: s, measure: measure)
            XCTAssertTrue(labels.isEmpty, "\(w) x \(h): got \(labels)")
        }
        for l in placeLabels([tile(t["movie.mov"], 5, 5, 300, 60)], in: s, measure: measure) {
            XCTAssertTrue(CGRect(x: 5, y: 5, width: 300, height: 60).insetBy(dx: 4, dy: 4).contains(l.rect))
        }

        // A directory that is subdivided is covered by its children's tiles: no label.
        let tiles = [tile(t["pack"], 0, 0, 400, 100), tile(t["inner.bin"], 0, 0, 400, 100)]
        let both = placeLabels(tiles, in: s, measure: measure)
        XCTAssertEqual(both.map(\.text), ["inner.bin  1 GB"])
        // ...but the same directory as a terminal tile (no child tile) is labelled.
        XCTAssertEqual(placeLabels([tiles[0]], in: s, measure: measure).map(\.text), ["pack  1 GB"])
    }

    func test_labels_truncate_long_and_control_character_names() {
        let long = "very-long-name-of-a-file.mov"
        let t = TestSnapshot(
            .dir(
                "/R",
                [
                    .file(long, 4_200_000_000),
                    .file("a\nb\tc", 3_000_000_000),
                    .file("x\u{01}y\u{7f}z", 2_000_000_000),
                    .file("\t\n", 1_000_000_000),
                    .file("ab", 500_000_000),
                ]))
        let s = t.snapshot
        // Precondition: Snapshot.name would make the newline U+FFFD; the label must not.
        XCTAssertEqual(s.name(t["a\nb\tc"]), "a\u{FFFD}b\u{FFFD}c")

        // 24 characters wide: 8 of them the size, 1 the ellipsis, 15 the name.
        let cut = placeLabels([tile(t[long], 0, 0, 176, 20)], in: s, measure: measure)
        XCTAssertEqual(cut.map(\.text), ["very-lon…ile.mov  4.2 GB"])
        XCTAssertLessThanOrEqual(cut[0].rect.width, 168)
        // Whatever the width, the result fits and keeps both ends of the name.
        for w in stride(from: 60.0, through: 400.0, by: 7) {
            let r = CGFloat(w)
            guard let l = placeLabels([tile(t[long], 0, 0, r, 20)], in: s, measure: measure).first else { continue }
            XCTAssertLessThanOrEqual(l.rect.width, r - 8, "width \(w)")
            XCTAssertTrue(l.text.hasSuffix("  4.2 GB"))
            if l.text != long + "  4.2 GB" {
                XCTAssertTrue(l.text.hasPrefix("v"), l.text)
                XCTAssertTrue(l.text.contains("…"), l.text)
                XCTAssertTrue(l.text.dropLast(8).hasSuffix("v"), l.text)
            }
        }
        XCTAssertTrue(
            placeLabels([tile(t[long], 0, 0, 176, 20)], in: s, measure: measure).count == 1,
            "precondition: the sweep above places labels")
        // Too narrow to keep three characters of a long name: nothing.
        XCTAssertTrue(placeLabels([tile(t[long], 0, 0, 90, 20)], in: s, measure: measure).isEmpty)

        let tiles = ["a\nb\tc", "x\u{01}y\u{7f}z", "\t\n", "ab"].map { tile(t[$0], 0, 0, 300, 20) }
        let texts = placeLabels(tiles, in: s, measure: measure).map(\.text)
        XCTAssertEqual(
            Set(texts), ["a b c  3 GB", "x\u{FFFD}y\u{FFFD}z  2 GB", "(unnamed)  1 GB", "ab  500 MB"])
        for x in texts {
            XCTAssertFalse(x.contains("\n") || x.contains("\t"), "one line only")
            XCTAssertFalse(x.isEmpty)
        }
    }

    func test_at_most_max_labels_largest_first() {
        let names = (0..<10).map { "file\($0)" }
        // file0 is the biggest on disk, but the tile areas are what order them.
        let t = TestSnapshot(.dir("/R", names.enumerated().map { .file($1, UInt64(1_000_000 * (10 - $0))) }))
        let s = t.snapshot
        // Areas 20*(40 + 10*k) with k a permutation, so the order is not the list order.
        let ks = [3, 7, 0, 9, 5, 1, 8, 2, 6, 4]
        let tiles = names.indices.map { i in tile(t[names[i]], 0, CGFloat(i) * 100, 300, CGFloat(20 + 10 * ks[i])) }
        let all = placeLabels(tiles, in: s, measure: measure)
        XCTAssertEqual(all.count, 10, "precondition: every tile has room, so max is what limits")
        let byArea = names.indices.sorted { ks[$0] > ks[$1] }
        XCTAssertEqual(all.map { String($0.text.prefix(while: { $0 != " " })) }, byArea.map { names[$0] })

        let top3 = placeLabels(tiles, in: s, measure: measure, max: 3)
        XCTAssertEqual(top3.count, 3)
        XCTAssertEqual(top3.map { String($0.text.prefix(while: { $0 != " " })) }, byArea.prefix(3).map { names[$0] })
        XCTAssertTrue(placeLabels(tiles, in: s, measure: measure, max: 0).isEmpty)
        XCTAssertEqual(placeLabels(tiles, in: s, measure: measure).count, 10, "the default is 400, not a smaller cap")
    }

    func test_aggregate_tile_label_reads_n_smaller_items() {
        let t = TestSnapshot(.dir("/R", [.file("a", 1)]))
        let s = t.snapshot
        let agg = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 12_345, aggregateBytes: 4_200_000_000)
        XCTAssertEqual(
            placeLabels([agg], in: s, measure: measure),
            [PlacedLabel(rect: CGRect(x: 4, y: 4, width: 203, height: 12), text: "12,345 smaller items — 4.2 GB")])
        let one = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 1, aggregateBytes: 1_000_000)
        XCTAssertEqual(placeLabels([one], in: s, measure: measure).map(\.text), ["1 smaller item — 1 MB"])
        // The same words as the inspector.
        XCTAssertEqual(
            placeLabels([agg], in: s, measure: measure).first?.text,
            inspect(tileAt: 0, in: [agg], snapshot: s).title)

        let locked = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 17)
        XCTAssertEqual(placeLabels([locked], in: s, measure: measure).map(\.text), ["17 unreadable folders"])
        let tooSmall = Tile(
            rect: CGRect(x: 0, y: 0, width: 4, height: 4), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 17)
        XCTAssertTrue(placeLabels([tooSmall], in: s, measure: measure).isEmpty, "not large enough")
    }

    func test_permission_denied_placeholders_never_get_labels() {
        let denied = (0..<5).map { TestSnapshot.Spec.denied("locked\($0)") }
        let t = TestSnapshot(.dir("/R", [.file("big", 50_000_000)] + denied))
        let s = t.snapshot
        let tiles = squarify(s, root: s.root, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let squares = tiles.filter { $0.isPermissionDenied && !$0.isAggregate }
        XCTAssertEqual(squares.count, 5, "precondition: five placeholders")
        XCTAssertTrue(squares.allSatisfy { $0.rect.size == CGSize(width: 4, height: 4) }, "precondition: 4 pt squares")
        // Even a measure that makes every text tiny must not label them.
        let labels = placeLabels(tiles, in: s, measure: { _ in CGSize(width: 0, height: 0) })
        XCTAssertFalse(labels.isEmpty, "precondition: other tiles are labelled")
        for sq in squares {
            XCTAssertFalse(labels.contains { sq.rect.intersects($0.rect) }, "\(sq.rect)")
        }
        // And a permission-denied tile that is big enough (an unreadable root).
        let big = Tile(rect: CGRect(x: 0, y: 0, width: 300, height: 300), node: t["locked0"], depth: 0, flags: Tile.Flag.permDenied)
        XCTAssertTrue(placeLabels([big], in: s, measure: measure).isEmpty)
    }

    func test_overlay_ink_tokens_and_fade() {
        XCTAssertTrue(LabelStyle.ink(dark: false) == (0x0b, 0x0b, 0x0b))
        XCTAssertTrue(LabelStyle.ink(dark: true) == (0xf0, 0xef, 0xec))
        XCTAssertEqual(LabelStyle.fadeDuration, 0.15)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: true), 0)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: false), 1)

        var zoom = ZoomAnimation(
            from: CGRect(x: 10, y: 10, width: 100, height: 100), viewport: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(zoom.isFinished, "precondition: a real animation")
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished), 0)
        zoom.advance(to: 0.1)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished), 0)
        zoom.advance(to: 0.25)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished), 1)

        // The real font: wider text measures wider, and a line has a height.
        let a = LabelStyle.measure("ab"), b = LabelStyle.measure("abcdef")
        XCTAssertGreaterThan(a.height, 0)
        XCTAssertGreaterThan(b.width, a.width)
    }
}
