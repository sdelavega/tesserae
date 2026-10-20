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

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest

@testable import TesseraeKit

/// Tile labels (spec §8 "Labels"): placement, truncation, and the overlay's
/// ink and fade.
final class LabelTests: XCTestCase {
    /// 7 pt per character, 12 pt tall: deterministic, no font involved.
    private let measure: (String) -> CGSize = { CGSize(width: 7 * CGFloat($0.count), height: 12) }

    private let en = Locale(identifier: "en_US")

    private func place(_ tiles: [Tile], in s: Snapshot, measure: (String) -> CGSize, max: Int = 400) -> [PlacedLabel] {
        placeLabels(tiles, in: s, measure: measure, max: max, locale: en)
    }

    /// 7 pt per UTF-16 code unit: unlike a Character count, it would notice
    /// a truncation that splits or miscounts a grapheme cluster.
    private let measureUnits: (String) -> CGSize = { CGSize(width: 7 * CGFloat($0.utf16.count), height: 12) }

    private func tile(
        _ node: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, parent: UInt32 = Tile.noNode
    ) -> Tile {
        Tile(rect: CGRect(x: x, y: y, width: w, height: h), node: node, depth: 1, parent: parent)
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
        let exact = place([tile(t["movie.mov"], 10, 20, 127, 20)], in: s, measure: measure)
        XCTAssertEqual(
            exact,
            [PlacedLabel(
                rect: CGRect(x: 14, y: 24, width: 119, height: 12), text: text,
                tile: tile(t["movie.mov"], 10, 20, 127, 20))])

        // One point too narrow for the full text: the name is cut, not the size.
        let narrow = place([tile(t["movie.mov"], 0, 0, 126, 20)], in: s, measure: measure)
        XCTAssertEqual(narrow.count, 1)
        XCTAssertNotEqual(narrow.first?.text, text)
        XCTAssertTrue(narrow.first?.text.hasSuffix("  4.2 GB") ?? false)

        // The label alone would fit these, without the padding: 119 x 12 in a
        // 119 x 12 tile, or one point short of the padding in either axis.
        for (w, h) in [(119.0, 12.0), (127.0, 19.0), (127.0, 12.0), (8.0, 8.0), (9.0, 9.0)] as [(CGFloat, CGFloat)] {
            let labels = place([tile(t["movie.mov"], 0, 0, w, h)], in: s, measure: measure)
            XCTAssertTrue(labels.isEmpty, "\(w) x \(h): got \(labels)")
        }
        for l in place([tile(t["movie.mov"], 5, 5, 300, 60)], in: s, measure: measure) {
            XCTAssertTrue(CGRect(x: 5, y: 5, width: 300, height: 60).insetBy(dx: 4, dy: 4).contains(l.rect))
        }

        // A directory that is subdivided is covered by its children's tiles: no label.
        let tiles = [tile(t["pack"], 0, 0, 400, 100), tile(t["inner.bin"], 0, 0, 400, 100, parent: t["pack"])]
        let both = place(tiles, in: s, measure: measure)
        XCTAssertEqual(both.map(\.text), ["inner.bin  1 GB"])
        // ...but the same directory as a terminal tile (no child tile) is labelled.
        XCTAssertEqual(place([tiles[0]], in: s, measure: measure).map(\.text), ["pack  1 GB"])
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
        let cut = place([tile(t[long], 0, 0, 176, 20)], in: s, measure: measure)
        XCTAssertEqual(cut.map(\.text), ["very-lon…ile.mov  4.2 GB"])
        XCTAssertLessThanOrEqual(cut[0].rect.width, 168)
        // Whatever the width, the result fits and keeps both ends of the name.
        for w in stride(from: 60.0, through: 400.0, by: 7) {
            let r = CGFloat(w)
            guard let l = place([tile(t[long], 0, 0, r, 20)], in: s, measure: measure).first else { continue }
            XCTAssertLessThanOrEqual(l.rect.width, r - 8, "width \(w)")
            XCTAssertTrue(l.text.hasSuffix("  4.2 GB"))
            if l.text != long + "  4.2 GB" {
                XCTAssertTrue(l.text.hasPrefix("v"), l.text)
                XCTAssertTrue(l.text.contains("…"), l.text)
                XCTAssertTrue(l.text.dropLast(8).hasSuffix("v"), l.text)
            }
        }
        XCTAssertTrue(
            place([tile(t[long], 0, 0, 176, 20)], in: s, measure: measure).count == 1,
            "precondition: the sweep above places labels")
        // Too narrow to keep three characters of a long name: nothing.
        XCTAssertTrue(place([tile(t[long], 0, 0, 90, 20)], in: s, measure: measure).isEmpty)

        let tiles = ["a\nb\tc", "x\u{01}y\u{7f}z", "\t\n", "ab"].map { tile(t[$0], 0, 0, 300, 20) }
        let texts = place(tiles, in: s, measure: measure).map(\.text)
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
        let all = place(tiles, in: s, measure: measure)
        XCTAssertEqual(all.count, 10, "precondition: every tile has room, so max is what limits")
        let byArea = names.indices.sorted { ks[$0] > ks[$1] }
        XCTAssertEqual(all.map { String($0.text.prefix(while: { $0 != " " })) }, byArea.map { names[$0] })

        let top3 = place(tiles, in: s, measure: measure, max: 3)
        XCTAssertEqual(top3.count, 3)
        XCTAssertEqual(top3.map { String($0.text.prefix(while: { $0 != " " })) }, byArea.prefix(3).map { names[$0] })
        XCTAssertTrue(place(tiles, in: s, measure: measure, max: 0).isEmpty)
        XCTAssertEqual(place(tiles, in: s, measure: measure).count, 10, "the default is 400, not a smaller cap")
    }

    func test_aggregate_tile_label_reads_n_smaller_items() {
        let t = TestSnapshot(.dir("/R", [.file("a", 1)]))
        let s = t.snapshot
        let agg = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 12_345, aggregateBytes: 4_200_000_000)
        XCTAssertEqual(
            place([agg], in: s, measure: measure),
            [PlacedLabel(rect: CGRect(x: 4, y: 4, width: 203, height: 12), text: "12,345 smaller items — 4.2 GB", tile: agg)])
        let one = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 1, aggregateBytes: 1_000_000)
        XCTAssertEqual(place([one], in: s, measure: measure).map(\.text), ["1 smaller item — 1 MB"])
        // The same words as the inspector.
        XCTAssertEqual(
            place([agg], in: s, measure: measure).first?.text,
            inspect(tileAt: 0, in: [agg], snapshot: s).title(locale: en))

        let locked = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 17)
        XCTAssertEqual(place([locked], in: s, measure: measure).map(\.text), ["17 unreadable folders"])
        let tooSmall = Tile(
            rect: CGRect(x: 0, y: 0, width: 4, height: 4), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 17)
        XCTAssertTrue(place([tooSmall], in: s, measure: measure).isEmpty, "not large enough")
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
        let labels = place(tiles, in: s, measure: { _ in CGSize(width: 0, height: 0) })
        XCTAssertFalse(labels.isEmpty, "precondition: other tiles are labelled")
        for sq in squares {
            XCTAssertFalse(labels.contains { sq.rect.intersects($0.rect) }, "\(sq.rect)")
        }
        // And a permission-denied tile that is big enough (an unreadable root).
        let big = Tile(rect: CGRect(x: 0, y: 0, width: 300, height: 300), node: t["locked0"], depth: 0, flags: Tile.Flag.permDenied)
        XCTAssertTrue(place([big], in: s, measure: measure).isEmpty)
    }

    // MARK: Ink per tile (final review I3)

    /// WCAG 2.x contrast of two sRGB-encoded colours, computed here
    /// independently of `LabelStyle`.
    private func wcag(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        func lum(_ c: SIMD3<Double>) -> Double {
            func lin(_ v: Double) -> Double {
                let s = (v * 255).rounded() / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
        }
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func rgb(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.z)) }
    private func rgb(_ c: (red: Int, green: Int, blue: Int)) -> SIMD3<Double> {
        SIMD3(Double(c.red), Double(c.green), Double(c.blue)) / 255
    }
    private func hex(_ c: SIMD3<Double>) -> String {
        String(format: "#%02x%02x%02x", Int((c.x * 255).rounded()), Int((c.y * 255).rounded()), Int((c.z * 255).rounded()))
    }

    private static let kinds: [FileKind] = [.video, .images, .audio]
    nonisolated(unsafe) private static let modes: [(String, ColourMode)] = [
        ("depth", .depth), ("age", .age(now: Date(timeIntervalSince1970: 2_000_000_000))), ("type focus", .typeFocus(kinds)),
    ]

    /// Every colour of every shipped palette (depth, age, type focus; light and
    /// dark; with the neutral and status entries each palette carries) gets
    /// whichever ink token reads better on it, and every one clears WCAG AA
    /// for text (4.5:1). The minimum best contrast is reported and pinned
    /// (#256bc0, the light depth step 3 and type-focus slot 1, darkened from
    /// #2a78d6 at 4.46:1 for exactly this), so a palette change re-reports it.
    func test_label_ink_is_the_token_with_the_higher_contrast_on_every_palette_colour() {
        let darkInk = rgb(LabelStyle.ink(dark: false)), lightInk = rgb(LabelStyle.ink(dark: true))
        XCTAssertEqual(hex(darkInk), "#0b0b0b", "precondition: the light-mode token")
        XCTAssertEqual(hex(lightInk), "#f0efec", "precondition: the dark-mode token")
        var minimum = (ratio: Double.infinity, colour: "", palette: "")
        var seen = Set<String>()
        for (name, mode) in Self.modes {
            for dark in [false, true] {
                let palette = Palette.colours(mode, dark: dark)
                XCTAssertGreaterThanOrEqual(palette.count, 5, "precondition: neutral, status and a ramp")
                for (i, colour) in palette.enumerated() {
                    let fill = rgb(colour)
                    let onDark = wcag(fill, darkInk), onLight = wcag(fill, lightInk)
                    let chosen = rgb(LabelStyle.ink(over: colour))
                    let expected = onDark >= onLight ? darkInk : lightInk
                    let label = "\(name) \(dark ? "dark" : "light") [\(i)] \(hex(fill))"
                    XCTAssertEqual(hex(chosen), hex(expected), label)
                    XCTAssertEqual(wcag(fill, chosen), max(onDark, onLight), label)
                    seen.insert(hex(fill))
                    let best = max(onDark, onLight)
                    if best < minimum.ratio { minimum = (best, hex(fill), label) }
                }
            }
        }
        XCTAssertEqual(seen.count, 17, "precondition: every distinct shipped colour was visited")
        print("label ink: minimum best contrast \(String(format: "%.3f", minimum.ratio)):1 on \(minimum.colour) (\(minimum.palette))")
        XCTAssertGreaterThanOrEqual(minimum.ratio, 4.5, "a label fails WCAG AA on \(minimum.colour)")
        XCTAssertEqual(minimum.colour, "#256bc0")
        XCTAssertEqual((minimum.ratio * 100).rounded() / 100, 4.63)
    }

    /// The overlay picks each label's ink from its tile's actual colour, so the
    /// ink follows the mode and the appearance without a relayout: the darkest
    /// depth step, a neutral aggregate and an unreadable (status) tile.
    @MainActor
    func test_overlay_ink_follows_each_tiles_colour_in_every_mode() {
        let t = TestSnapshot(.dir("/R", [.file("deep.bin", 10), .denied("locked")]))
        let s = t.snapshot
        let deep = Tile(rect: CGRect(x: 0, y: 0, width: 100, height: 20), node: t["deep.bin"], depth: 4, parent: 0)
        let agg = Tile(
            rect: CGRect(x: 0, y: 20, width: 100, height: 20), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 3, aggregateBytes: 30, parent: 0)
        let locked = Tile(
            rect: CGRect(x: 0, y: 40, width: 100, height: 20), node: t["locked"], depth: 1,
            flags: Tile.Flag.permDenied, parent: 0)
        let labels = [deep, agg, locked].map { PlacedLabel(rect: $0.rect, text: "x", tile: $0) }
        let darkInk = "#0b0b0b", lightInk = "#f0efec"
        func inks(_ mode: ColourMode, dark: Bool) -> [String] {
            let overlay = LabelsOverlay(
                labels: labels, palette: Palette.colours(mode, dark: dark),
                colourOf: { colourIndex(for: $0, in: s, mode: mode) }, dark: dark, zoomRunning: false, labelsReady: true)
            return labels.map { hex(rgb(overlay.ink(for: $0))) }
        }
        let age = Self.modes[1].1
        XCTAssertEqual(colourIndex(for: deep, in: s, mode: .depth), UInt16(Palette.firstColourIndex + 4), "precondition")
        // Light depth: #0d366b (darkest) light ink; #5598e7 for the aggregate at depth 1; amber.
        XCTAssertEqual(inks(.depth, dark: false), [lightInk, darkInk, darkInk])
        // Dark depth: #9ec5f4 (lightest) dark ink; #256abf light ink; amber.
        XCTAssertEqual(inks(.depth, dark: true), [darkInk, lightInk, darkInk])
        // Age: the aggregate is neutral (#d6d5cf / #3a3a37); amber stays dark ink.
        XCTAssertEqual(inks(age, dark: false)[1...], [darkInk, darkInk])
        XCTAssertEqual(inks(age, dark: true)[1...], [lightInk, darkInk])
        // An index outside the palette falls back to the appearance's token.
        let broken = LabelsOverlay(
            labels: labels, palette: [], colourOf: { _ in 7 }, dark: true, zoomRunning: false, labelsReady: true)
        XCTAssertEqual(hex(rgb(broken.ink(for: labels[0]))), lightInk)
    }

    /// Each label carries the tile it was placed on (the overlay's ink comes
    /// from that tile's colour), not some other tile of the layout.
    func test_each_label_carries_its_own_tile() {
        let t = TestSnapshot(.dir("/R", [.file("a", 30), .file("b", 20), .file("c", 10)]))
        let tiles = [
            tile(t["a"], 0, 0, 200, 30, parent: 0), tile(t["b"], 0, 30, 200, 30, parent: 0),
            tile(t["c"], 0, 60, 200, 30, parent: 0),
        ]
        let labels = place(tiles, in: t.snapshot, measure: measure)
        XCTAssertEqual(labels.count, 3, "precondition: every tile is labelled")
        for label in labels {
            XCTAssertTrue(label.tile.rect.insetBy(dx: labelPadding, dy: labelPadding).contains(label.rect), label.text)
            XCTAssertTrue(label.text.hasPrefix(t.snapshot.displayName(label.tile.node)), label.text)
        }
        XCTAssertEqual(Set(labels.map(\.tile.node)), Set(tiles.map(\.node)))
    }

    /// Drawn for real: a label over the darkest light-mode depth step
    /// (#0d366b) is painted in the light ink, so its glyphs are lighter than
    /// the fill, where the old fixed light-mode ink drew them darker.
    @MainActor
    func test_a_label_over_the_darkest_depth_step_renders_in_the_light_ink() throws {
        let t = TestSnapshot(.dir("/R", [.file("deep.bin", 10)]))
        let s = t.snapshot
        let size = CGSize(width: 200, height: 40)
        let deep = Tile(rect: CGRect(origin: .zero, size: size), node: t["deep.bin"], depth: 4, parent: 0)
        let palette = Palette.colours(.depth, dark: false)
        let fillIndex = Int(colourIndex(for: deep, in: s, mode: .depth))
        let fill = palette[fillIndex]
        XCTAssertEqual(hex(rgb(fill)), "#0d366b", "precondition: the darkest light-mode depth step")
        let label = PlacedLabel(rect: CGRect(x: 4, y: 4, width: 150, height: 14), text: "WWWW MMMM 4.2 GB", tile: deep)
        let view = NSHostingView(
            rootView: ZStack(alignment: .topLeading) {
                Color(.sRGB, red: Double(fill.x), green: Double(fill.y), blue: Double(fill.z))
                LabelsOverlay(
                    labels: [label], palette: palette, colourOf: { colourIndex(for: $0, in: s, mode: .depth) },
                    dark: false, zoomRunning: false, labelsReady: true)
            }.frame(width: size.width, height: size.height))
        view.frame = CGRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let srgb = try XCTUnwrap(rep.converting(to: .sRGB, renderingIntent: .default))
        var brightest = 0.0, darkest = 1.0
        let w = srgb.pixelsWide, h = srgb.pixelsHigh
        for y in 0..<h { for x in 0..<w {
            guard let c = srgb.colorAt(x: x, y: y) else { continue }
            let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            brightest = max(brightest, l)
            darkest = min(darkest, l)
        } }
        let fillLevel = Double(fill.x + fill.y + fill.z) / 3
        XCTAssertGreaterThan(brightest, 0.8, "glyphs in the light ink (#f0efec) appear over the fill")
        XCTAssertGreaterThan(darkest, fillLevel - 0.06, "nothing is drawn darker than the fill (no dark ink)")
    }

    func test_overlay_ink_tokens_and_fade() {
        XCTAssertTrue(LabelStyle.ink(dark: false) == (0x0b, 0x0b, 0x0b))
        XCTAssertTrue(LabelStyle.ink(dark: true) == (0xf0, 0xef, 0xec))
        XCTAssertEqual(LabelStyle.fadeDuration, 0.15)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: true, labelsReady: true), 0)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: false, labelsReady: true), 1)

        var zoom = ZoomAnimation(
            from: CGRect(x: 10, y: 10, width: 100, height: 100), viewport: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(zoom.isFinished, "precondition: a real animation")
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished, labelsReady: true), 0)
        zoom.advance(to: 0.1)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished, labelsReady: true), 0)
        zoom.advance(to: 0.25)
        XCTAssertEqual(LabelStyle.opacity(zoomRunning: !zoom.isFinished, labelsReady: true), 1)

        // The real font: wider text measures wider, and a line has a height.
        let a = LabelStyle.measure("ab"), b = LabelStyle.measure("abcdef")
        XCTAssertGreaterThan(a.height, 0)
        XCTAssertGreaterThan(b.width, a.width)
    }

    /// Labels arrive after the zoom ends (placement runs off the main actor),
    /// so the fade is keyed on their arrival: hidden, without animation, while
    /// motion runs or before the current layout's labels are applied; faded in
    /// over `fadeDuration` once both hold.
    func test_label_fade_waits_for_the_labels_to_arrive() {
        typealias State = (zoomRunning: Bool, labelsReady: Bool)
        func step(_ s: State) -> (Double, TimeInterval?) {
            (LabelStyle.opacity(zoomRunning: s.zoomRunning, labelsReady: s.labelsReady),
             LabelStyle.fadeDuration(zoomRunning: s.zoomRunning, labelsReady: s.labelsReady))
        }
        // A navigation: zoom starts, ends, then the labels are applied.
        let navigation: [State] = [(false, true), (true, false), (false, false), (false, true)]
        let seen = navigation.map(step)
        XCTAssertEqual(seen.map(\.0), [1, 0, 0, 1])
        XCTAssertEqual(seen.map(\.1), [0.15, nil, nil, 0.15], "hide at once; fade in only on arrival")
        // The zoom ending alone does not show anything: the old fade ran on an empty overlay.
        XCTAssertEqual(step((false, false)).0, 0)
        // A resize hides the stale labels at once, then fades the new ones in.
        XCTAssertEqual(step((false, false)).1, nil)
        XCTAssertEqual(step((false, true)).1, LabelStyle.fadeDuration)
        // Labels that are ready stay hidden while motion runs.
        XCTAssertEqual(step((true, true)).0, 0)
        XCTAssertNil(step((true, true)).1)
    }

    func test_label_measure_matches_appkit_and_is_safe_off_the_main_thread() {
        func appKit(_ text: String) -> CGSize {
            let z = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: LabelStyle.fontSize)])
            return CGSize(width: z.width.rounded(.up), height: z.height.rounded(.up))
        }
        let samples = [
            "a", "movie.mov  4.2 GB", "WWWWWWWWWW", "12,345 smaller items — 4.2 GB", "na\u{EF}ve caf\u{E9}",
            "\u{65E5}\u{672C}\u{8A9E}\u{306E}\u{30D5}\u{30A1}\u{30A4}\u{30EB}", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}  1 MB",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family", "abc…xyz  12 KB",
            // Fallback fonts with taller or shorter metrics than the label font.
            "\u{0E20}\u{0E32}\u{0E29}\u{0E32}\u{0E44}\u{0E17}\u{0E22}", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}  3 KB",
            "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}", "\u{0F40}\u{0F41}\u{0F42}", "\u{D55C}\u{AD6D}\u{C5B4}",
            "\u{1D518}\u{1D52B}\u{1D526}", "\u{A997}\u{A9AE}", "A\u{0301}\u{0327}\u{0316} zalgo", "", " ",
        ]
        for text in samples {
            XCTAssertEqual(LabelStyle.measure(text), appKit(text), text)
        }
        let expected = samples.map(LabelStyle.measure)
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var sizes: [Int: CGSize] = [:]
            var offMain = 0
        }
        let results = Results()
        let count = samples.count * 8
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let size = LabelStyle.measure(samples[i % samples.count])
            results.lock.lock()
            results.sizes[i] = size
            if !Thread.isMainThread { results.offMain += 1 }
            results.lock.unlock()
        }
        XCTAssertGreaterThan(results.offMain, 0, "precondition: some measurements ran on worker threads")
        for i in 0..<count { XCTAssertEqual(results.sizes[i], expected[i % samples.count]) }
    }

    // MARK: fix round 1

    func test_size_is_never_truncated_only_the_words() {
        let t = TestSnapshot(.dir("/R", [.file("movie.mov", 4_200_000_000)]))
        let s = t.snapshot
        let agg = { (w: CGFloat) in
            Tile(
                rect: CGRect(x: 0, y: 0, width: w, height: 20), node: Tile.noNode, depth: 1,
                flags: Tile.Flag.aggregated, aggregateCount: 12_345, aggregateBytes: 4_200_000_000)
        }
        // "12,345 smaller items — 4.2 GB" is 29 characters = 203 pt: 211 fits whole.
        XCTAssertEqual(place([agg(211)], in: s, measure: measure).map(\.text), ["12,345 smaller items — 4.2 GB"])
        // Narrower: the words are cut, the " — 4.2 GB" stays.
        let cut = place([agg(150)], in: s, measure: measure)
        XCTAssertEqual(cut.count, 1)
        XCTAssertTrue(cut[0].text.hasSuffix(" — 4.2 GB"), cut[0].text)
        XCTAssertTrue(cut[0].text.contains("…"), cut[0].text)
        XCTAssertLessThanOrEqual(cut[0].rect.width, 142)
        // The size plus three characters of the words: " — 4.2 GB" is 9, "…" 1, 3 kept = 13 characters = 91 pt.
        XCTAssertEqual(place([agg(99)], in: s, measure: measure).map(\.text), ["12…s — 4.2 GB"])
        XCTAssertTrue(place([agg(98)], in: s, measure: measure).isEmpty, "never a label without the size")
        // The unreadable-folders tile has no size and cuts its words.
        let locked = Tile(
            rect: CGRect(x: 0, y: 0, width: 100, height: 20), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 17)
        XCTAssertTrue(place([locked], in: s, measure: measure).first?.text.contains("…") ?? false)
    }

    func test_narrow_boundary_keeps_three_characters_and_the_size() {
        let long = "very-long-name-of-a-file.mov"
        let t = TestSnapshot(.dir("/R", [.file(long, 4_200_000_000)]))
        let s = t.snapshot
        // Three characters (2 + "…" + 1) and "  4.2 GB": 12 characters = 84 pt + 8 padding.
        XCTAssertEqual(place([tile(t[long], 0, 0, 92, 20)], in: s, measure: measure).map(\.text), ["ve…v  4.2 GB"])
        XCTAssertTrue(place([tile(t[long], 0, 0, 91, 20)], in: s, measure: measure).isEmpty)
        XCTAssertTrue(place([tile(t[long], 0, 0, 92, 19)], in: s, measure: measure).isEmpty, "too short")
    }

    func test_truncation_never_splits_a_grapheme_cluster() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let flags = "\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}\u{1F1EB}\u{1F1F7}\u{1F1E9}\u{1F1EA}\u{1F1EE}\u{1F1F9}\u{1F1E8}\u{1F1E6}"
        let acute = "e\u{301}"
        let names = [
            String(repeating: "\u{1F642}", count: 10), "ab" + family + "cdefgh", flags,
            String(repeating: acute, count: 6),
        ]
        let t = TestSnapshot(.dir("/R", names.enumerated().map { .file($1, UInt64(4_200_000_000 - $0)) }))
        let s = t.snapshot
        for n in names { XCTAssertEqual(measureUnits(n).width / 7, CGFloat(n.utf16.count)) }
        XCTAssertEqual(names.map(\.count), [10, 9, 6, 6], "precondition: Characters, not scalars or units")
        XCTAssertGreaterThan(names[1].unicodeScalars.count, 12, "precondition: the family is many scalars")
        func label(_ i: Int, units: CGFloat) -> String? {
            // (units + 8 for "  4.2 GB" is already counted in `units`) plus padding.
            place([tile(t[names[i]], 0, 0, units * 7 + 8, 20)], in: s, measure: measureUnits).first?.text
        }
        let size = "  4.2 GB"
        XCTAssertEqual(label(0, units: 19), "\u{1F642}\u{1F642}\u{1F642}…\u{1F642}\u{1F642}" + size)
        XCTAssertEqual(label(1, units: 24), "ab" + family + "…gh" + size)
        XCTAssertEqual(label(2, units: 21), "\u{1F1FA}\u{1F1F8}\u{1F1EF}\u{1F1F5}…\u{1F1E8}\u{1F1E6}" + size)
        XCTAssertEqual(label(3, units: 15), acute + acute + "…" + acute + size)
    }

    func test_bidi_and_invisible_format_characters_are_neutralised() {
        let name = "a\u{202E}b\u{2066}c\u{200B}d\u{FEFF}e\u{061C}f\u{200E}g"
        let t = TestSnapshot(.dir("/R", [.file(name, 4_200_000_000)]))
        let s = t.snapshot
        XCTAssertEqual(
            place([tile(t[name], 0, 0, 400, 20)], in: s, measure: measure).map(\.text),
            ["a\u{FFFD}b\u{FFFD}c\u{FFFD}d\u{FFFD}e\u{FFFD}f\u{FFFD}g  4.2 GB"])
    }

    func test_directory_whose_children_collapsed_is_not_labelled_over_them() {
        let tiny = (0..<30).map { TestSnapshot.Spec.file("t\($0)", 1024) }
        let denied = TestSnapshot.Spec.denied("locked")
        let t = TestSnapshot(
            .dir("/R", [.dir("onlytiny", tiny), .dir("onlylocked", [denied]), .dir("bare", [])]))
        let s = t.snapshot
        let agg = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 100), node: Tile.noNode, depth: 2,
            flags: Tile.Flag.aggregated, aggregateCount: 30, aggregateBytes: 30 * 1024, parent: t["onlytiny"])
        let dirTile = Tile(rect: CGRect(x: 0, y: 0, width: 300, height: 100), node: t["onlytiny"], depth: 1)
        // The aggregate is labelled; the directory around it is not.
        XCTAssertEqual(place([dirTile, agg], in: s, measure: measure).map(\.text), ["30 smaller items — 31 kB"])
        XCTAssertEqual(place([dirTile], in: s, measure: measure).map(\.text), ["onlytiny  31 kB"], "alone it is terminal")
        // A placeholder square child (a node with a tile) covers it too.
        let ph = Tile(rect: CGRect(x: 0, y: 0, width: 4, height: 4), node: t["locked"], depth: 2, flags: Tile.Flag.permDenied, parent: t["onlylocked"])
        let lockedDir = Tile(rect: CGRect(x: 0, y: 0, width: 300, height: 100), node: t["onlylocked"], depth: 1)
        XCTAssertTrue(place([lockedDir, ph], in: s, measure: measure).isEmpty)
        // An aggregate elsewhere (not inside) does not hide it.
        let far = Tile(
            rect: CGRect(x: 500, y: 500, width: 300, height: 100), node: Tile.noNode, depth: 2,
            flags: Tile.Flag.aggregated, aggregateCount: 3, aggregateBytes: 3000, parent: t["bare"])
        XCTAssertEqual(place([dirTile, far], in: s, measure: measure).count, 2)
    }

    func test_placement_with_20000_tiles_and_many_aggregates_is_linear_enough() {
        // 2,000 directories, each with a terminal-sized child, an aggregate and a
        // placeholder square: 20,000 tiles in all, and 4,000 anonymous ones.
        let dirs = (0..<2000).map { TestSnapshot.Spec.dir("d\($0)", [.file("f\($0)", 1_000_000)]) }
        let t = TestSnapshot(.dir("/R", dirs))
        let s = t.snapshot
        var tiles: [Tile] = []
        for i in 0..<2000 {
            let x = CGFloat(i % 20) * 200, y = CGFloat(i / 20) * 40
            let d = t["d\(i)"]
            tiles.append(Tile(rect: CGRect(x: x, y: y, width: 200, height: 40), node: d, depth: 1, parent: 0))
            tiles.append(Tile(rect: CGRect(x: x, y: y, width: 100, height: 40), node: t["f\(i)"], depth: 2, parent: d))
            tiles.append(
                Tile(
                    rect: CGRect(x: x + 100, y: y, width: 100, height: 40), node: Tile.noNode, depth: 2,
                    flags: Tile.Flag.aggregated, aggregateCount: 5, aggregateBytes: 5000, parent: d))
            tiles.append(
                Tile(
                    rect: CGRect(x: x, y: y + 30, width: 4, height: 4), node: Tile.noNode, depth: 2,
                    flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 3, parent: d))
            for k in 0..<6 {
                tiles.append(
                    Tile(
                        rect: CGRect(x: x + 100 + CGFloat(k) * 3, y: y + 30, width: 3, height: 3), node: Tile.noNode,
                        depth: 2, flags: Tile.Flag.aggregated, aggregateCount: 1, aggregateBytes: 10, parent: d))
            }
        }
        XCTAssertEqual(tiles.count, 20_000)
        let start = Date()
        let labels = place(tiles, in: s, measure: { CGSize(width: CGFloat($0.count), height: 12) })
        print("placeLabels over \(tiles.count) tiles: \(Date().timeIntervalSince(start) * 1000) ms, \(labels.count) labels")
        XCTAssertEqual(labels.count, 400, "precondition: the cap was reached by real labels")
        XCTAssertFalse(labels.contains { $0.text.hasPrefix("d") }, "no covered directory is labelled")
    }

    /// German writes "4,2 GB" with a no-break space; compare with plain ones.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func test_locale_is_injectable() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(displayCount(12_345, locale: en), "12,345")
        XCTAssertEqual(displayCount(12_345, locale: de), "12.345")
        XCTAssertEqual(displaySize(4_200_000_000, locale: en), "4.2 GB")
        XCTAssertEqual(plain(displaySize(4_200_000_000, locale: de)), "4,2 GB")
        let t = TestSnapshot(.dir("/R", [.file("a", 1)]))
        let agg = Tile(
            rect: CGRect(x: 0, y: 0, width: 300, height: 30), node: Tile.noNode, depth: 1,
            flags: Tile.Flag.aggregated, aggregateCount: 12_345, aggregateBytes: 4_200_000_000)
        XCTAssertEqual(
            placeLabels([agg], in: t.snapshot, measure: measure, locale: de).map { plain($0.text) },
            ["12.345 smaller items — 4,2 GB"])
    }
}
