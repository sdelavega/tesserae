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


import Foundation
import TesseraeFFI
import XCTest

@testable import TesseraeKit

/// Colour modes (spec §8 "Colour"). The palette test pins every exact hex, so
/// nudging any colour fails CI: that is spec §12's durability goal, met by
/// pinning the validated values rather than running the (external) validator.
final class ColourTests: XCTestCase {
    // MARK: Fixtures

    /// A snapshot over a flat list of hand-built nodes; owns the buffers.
    private final class Fake {
        struct Item {
            var name: String
            var dir = false
            var denied = false
            var modified: Int64 = 0
        }
        let nodes: UnsafeMutablePointer<TessNode>
        let names: UnsafeMutablePointer<UInt8>
        let snapshot: Snapshot

        init(_ items: [Item]) {
            var bytes: [UInt8] = []
            nodes = .allocate(capacity: items.count)
            for (i, it) in items.enumerated() {
                var n = TessNode()
                n.name_off = UInt32(bytes.count)
                n.name_len = UInt16(it.name.utf8.count)
                bytes.append(contentsOf: Array(it.name.utf8))
                n.parent = UInt32.max
                n.modified = it.modified
                if it.dir { n.flags |= UInt16(TESS_FLAG_DIR) }
                if it.denied { n.flags |= UInt16(TESS_FLAG_PERM_DENIED) }
                (nodes + i).initialize(to: n)
            }
            names = .allocate(capacity: max(bytes.count, 1))
            names.initialize(from: bytes, count: bytes.count)
            snapshot = Snapshot(
                testingNodes: UnsafeBufferPointer(start: nodes, count: items.count),
                names: UnsafeRawBufferPointer(start: names, count: bytes.count), root: 0)
        }
        deinit {
            nodes.deallocate()
            names.deallocate()
        }
    }

    private func hex(_ c: SIMD4<Float>) -> String {
        func b(_ f: Float) -> Int { Int((f * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.x), b(c.y), b(c.z))
    }

    private func hexes(_ m: ColourMode, dark: Bool) -> [String] {
        Palette.colours(m, dark: dark).map(hex)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: Int64 = 86_400

    private func ageSlot(secondsAgo: Int64, dark: Bool = false) -> Int {
        let f = Fake([.init(name: "f.txt", modified: 2_000_000_000 - secondsAgo)])
        return Int(colourIndex(0, depth: 0, in: f.snapshot, mode: .age(now: now))) - Palette.firstColourIndex
    }

    // MARK: Tests

    func test_palette_values_are_exactly_the_spec_values() {
        let first = Palette.firstColourIndex
        func expect(_ m: ColourMode, dark: Bool, _ colours: [String], file: StaticString = #filePath, line: UInt = #line) {
            let got = hexes(m, dark: dark)
            XCTAssertEqual(got.count, first + colours.count, file: file, line: line)
            XCTAssertEqual(Array(got.dropFirst(first)), colours, file: file, line: line)
            XCTAssertEqual(got[Palette.neutralIndex], dark ? "#3a3a37" : "#d6d5cf", file: file, line: line)
            XCTAssertEqual(got[Palette.statusIndex], "#fab219", file: file, line: line)
        }
        let kinds: [FileKind] = [.video, .images, .audio]
        expect(.depth, dark: false, ["#86b6ef", "#5598e7", "#2a78d6", "#1c5cab", "#104281"])
        expect(.depth, dark: true, ["#184f95", "#256abf", "#3987e5", "#6da7ec", "#9ec5f4"])
        let age = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
        expect(.age(now: now), dark: false, age)
        expect(.age(now: now), dark: true, age.reversed())
        expect(.typeFocus(kinds), dark: false, ["#2a78d6", "#eb6834", "#1baf7a"])
        expect(.typeFocus(kinds), dark: true, ["#3987e5", "#d95926", "#199e70"])
        XCTAssertEqual(hex(Palette.surface(dark: false)), "#fcfcfb")
        XCTAssertEqual(hex(Palette.surface(dark: true)), "#1a1a19")
        for c in Palette.colours(.depth, dark: false) { XCTAssertEqual(c.w, 1) }
    }

    func test_light_mode_aqua_contrast_is_the_documented_2_74() {
        func lum(_ c: SIMD4<Float>) -> Double {
            func lin(_ v: Float) -> Double {
                let s = Double((v * 255).rounded()) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
        }
        let aqua = Palette.colours(.typeFocus([.video, .images, .audio]), dark: false)[Palette.firstColourIndex + 2]
        XCTAssertEqual(hex(aqua), "#1baf7a")  // precondition: we are measuring the right colour
        let a = lum(aqua), b = lum(Palette.surface(dark: false))
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        XCTAssertEqual((ratio * 100).rounded() / 100, 2.74)
    }

    func test_depth_cycles_every_five_levels() {
        let f = Fake([.init(name: "d", dir: true), .init(name: "f.txt")])
        var seen = Set<UInt16>()
        for d in 0..<15 {
            let a = colourIndex(1, depth: UInt8(d), in: f.snapshot, mode: .depth)
            let b = colourIndex(0, depth: UInt8(d), in: f.snapshot, mode: .depth)
            XCTAssertEqual(a, b)
            XCTAssertEqual(Int(a), Palette.firstColourIndex + d % 5)
            if d < 5 { seen.insert(a) } else {
                XCTAssertEqual(a, colourIndex(1, depth: UInt8(d - 5), in: f.snapshot, mode: .depth))
            }
        }
        XCTAssertEqual(seen.count, 5)
        XCTAssertEqual(Int(colourIndex(1, depth: 255, in: f.snapshot, mode: .depth)), Palette.firstColourIndex)
    }

    func test_age_buckets_boundaries() {
        let limits: [Int64] = [7, 30, 90, 365, 730, 1825]
        for (slot, days) in limits.enumerated() {
            XCTAssertEqual(ageSlot(secondsAgo: days * day), slot, "exactly \(days) d")
            XCTAssertEqual(ageSlot(secondsAgo: days * day + 1), slot + 1, "\(days) d + 1 s")
        }
        XCTAssertEqual(ageSlot(secondsAgo: 0), 0)
        XCTAssertEqual(ageSlot(secondsAgo: 100 * 365 * day), 6)
        XCTAssertEqual(ageSlot(secondsAgo: 2_000_000_000), 6, "modified == 0 is the oldest bucket")
        let extreme = Fake([.init(name: "f", modified: Int64.min), .init(name: "g", modified: Int64.max)])
        XCTAssertEqual(
            Int(colourIndex(0, depth: 0, in: extreme.snapshot, mode: .age(now: now))), Palette.firstColourIndex + 6,
            "Int64.min must saturate, not trap")
        XCTAssertEqual(
            Int(colourIndex(1, depth: 0, in: extreme.snapshot, mode: .age(now: now))), Palette.firstColourIndex)
        XCTAssertEqual(ageSlot(secondsAgo: -3600), 0, "a future file counts as recent")
        XCTAssertEqual(ageSlot(secondsAgo: -1000 * day), 0)
        // Directories use the same rule on their rolled-up time.
        let d = Fake([.init(name: "d", dir: true, modified: 2_000_000_000 - 31 * day)])
        XCTAssertEqual(
            Int(colourIndex(0, depth: 0, in: d.snapshot, mode: .age(now: now))), Palette.firstColourIndex + 2)
    }

    func test_type_focus_takes_at_most_three_kinds() {
        let f = Fake([
            .init(name: "a.mp4"), .init(name: "b.png"), .init(name: "c.mp3"), .init(name: "d.zip"),
            .init(name: "e.pdf"), .init(name: "f.xyz"), .init(name: "d", dir: true),
            .init(name: "movies.mp4", dir: true),
        ])
        let four: [FileKind] = [.video, .images, .audio, .archives]
        let idx = (0..<8).map { colourIndex(UInt32($0), depth: 0, in: f.snapshot, mode: .typeFocus(four)) }
        let first = UInt16(Palette.firstColourIndex), neutral = UInt16(Palette.neutralIndex)
        XCTAssertEqual(Array(idx[0..<3]), [first, first + 1, first + 2])
        XCTAssertEqual(idx[3], neutral, "a fourth kind has no slot")
        XCTAssertEqual(idx[4], neutral)
        XCTAssertEqual(idx[5], neutral)
        XCTAssertEqual(idx[6], neutral, "directories are neutral")
        XCTAssertEqual(idx[7], neutral, "a directory named like a video is still neutral")
        // One kind: only its slot is used.
        XCTAssertEqual(colourIndex(3, depth: 0, in: f.snapshot, mode: .typeFocus([.archives])), first)
        XCTAssertEqual(colourIndex(0, depth: 0, in: f.snapshot, mode: .typeFocus([.archives])), neutral)
        // Every listed extension maps to its kind.
        let table: [FileKind: String] = [
            .video: "mp4 mov m4v mkv avi webm mts",
            .images: "jpg jpeg png heic heif gif tif tiff webp raw cr2 cr3 nef arw dng psd",
            .audio: "mp3 m4a aac wav aiff aif flac ogg opus",
            .archives: "zip dmg iso tar gz tgz xz bz2 7z rar pkg xip",
            .documents: "pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md epub",
        ]
        for (kind, exts) in table {
            let list = exts.split(separator: " ").map(String.init)
            XCTAssertGreaterThan(list.count, 5)
            for e in list { XCTAssertEqual(FileKind.kind(forName: Data("x.\(e)".utf8)), kind, e) }
        }
        XCTAssertEqual(FileKind.allCases.count, 5)
    }

    func test_kind_matching_is_case_insensitive_and_ignores_dotfiles() {
        let f = Fake([
            .init(name: "CLIP.MP4"), .init(name: ".mp4"), .init(name: "clip.Mp4"),
            .init(name: "mp4"), .init(name: "clip."), .init(name: "a.tar.GZ"),
        ])
        let m = ColourMode.typeFocus([.video, .archives])
        let first = UInt16(Palette.firstColourIndex), neutral = UInt16(Palette.neutralIndex)
        let idx = (0..<6).map { colourIndex(UInt32($0), depth: 0, in: f.snapshot, mode: m) }
        XCTAssertEqual(idx, [first, neutral, first, neutral, neutral, first + 1])
    }

    func test_permission_denied_overrides_every_mode() {
        let f = Fake([
            .init(name: "locked", dir: true, denied: true, modified: 2_000_000_000),
            .init(name: "ok", dir: true, modified: 2_000_000_000),
        ])
        let status = UInt16(Palette.statusIndex)
        let modes: [ColourMode] = [.depth, .age(now: now), .typeFocus([.video])]
        for m in modes {
            XCTAssertEqual(colourIndex(0, depth: 3, in: f.snapshot, mode: m), status)
            XCTAssertNotEqual(colourIndex(1, depth: 3, in: f.snapshot, mode: m), status)
            // Tiles with no node (the placeholder / "N unreadable folders" aggregate).
            let placeholder = Tile(
                rect: .zero, node: Tile.noNode, depth: 2,
                flags: Tile.Flag.permDenied | Tile.Flag.aggregated, aggregateCount: 3)
            XCTAssertEqual(colourIndex(for: placeholder, in: f.snapshot, mode: m), status)
        }
        // Aggregate tiles: depth colour in depth mode, neutral otherwise.
        let agg = Tile(rect: .zero, node: Tile.noNode, depth: 7, flags: Tile.Flag.aggregated, aggregateCount: 9)
        XCTAssertEqual(Int(colourIndex(for: agg, in: f.snapshot, mode: .depth)), Palette.firstColourIndex + 2)
        XCTAssertEqual(colourIndex(for: agg, in: f.snapshot, mode: .age(now: now)), UInt16(Palette.neutralIndex))
        XCTAssertEqual(colourIndex(for: agg, in: f.snapshot, mode: .typeFocus([.video])), UInt16(Palette.neutralIndex))
    }
}
