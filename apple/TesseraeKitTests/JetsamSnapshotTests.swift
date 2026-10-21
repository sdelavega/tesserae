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
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TesseraeFFI
@testable import TesseraeKit

/// Synthetic UI references with a fixed AppKit, locale, time zone and date.
@MainActor
final class JetsamSnapshotTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let size = CGSize(width: 960, height: 1200)
    private static var references: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SnapshotTests")
    }
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func png(_ image: CGImage, _ url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        var data = Data(count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private func snapshot<V: View>(_ name: String, _ view: V) throws {
        for dark in [false, true] {
            let name = "degraded-" + name + (dark ? "-dark" : "-light")
            let content = view
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(dark ? Color(red: 0.10, green: 0.10, blue: 0.11) : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.locale, locale).environment(\.timeZone, zone)
                .environment(\.calendar, Calendar(identifier: .gregorian))
                .environment(\.displayScale, 1)
                .tint(.blue)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(size)
            renderer.scale = 1
            // Render into a fixed sRGB bitmap rather than a lazily chosen image format.
            let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 1200,
                bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            renderer.render { _, draw in draw(context) }
            let actual = try XCTUnwrap(context.makeImage(), name)
            XCTAssertEqual(actual.width, 960); XCTAssertEqual(actual.height, 1200)
            let url = Self.references.appendingPathComponent(name + ".png")
            let recordNames = ProcessInfo.processInfo.environment["TESSERAE_RECORD_SNAPSHOT_NAMES"]?.split(separator: ",").map(String.init)
            if ProcessInfo.processInfo.environment["TESSERAE_RECORD_SNAPSHOTS"] == "1",
               recordNames == nil || recordNames!.contains(name) {
                try png(actual, url)
                let review = Self.references.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/task-8-review")
                try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
                try png(actual, review.appendingPathComponent(name + ".png"))
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                XCTFail("Missing reference: " + name); continue
            }
            let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(actual.width, expected.width, name); XCTAssertEqual(actual.height, expected.height, name)
            if try pixels(actual) != pixels(expected) {
                let output = Self.references.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/task-8-review/" + name + ".actual.png")
                try png(actual, output)
                XCTFail("Exact RGBA mismatch: " + name + "; actual: " + output.path)
            }
        }
    }

    func test_empty_status_has_no_layout_footprint() {
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            JetsamStatusView()
            Color.clear.frame(width: 100, height: 20)
        })
        XCTAssertEqual(host.fittingSize.height, 20, accuracy: 0.01)
        let visible = NSHostingView(rootView: JetsamStatusView(rescanCount: 1))
        XCTAssertGreaterThan(visible.fittingSize.height, 20, "precondition: visible status takes space")
    }

    func test_shipped_scrolling_confirmation_contains_every_full_warning() throws {
        let items = (0..<24).map { n in
            JetsamItem(nodeIndex: UInt32(n), path: Data(("/Fixture/long-warning-row-\(n)").utf8),
                recorded: Recorded(fileID: UInt64(n + 1), device: 1, isDirectory: false),
                recordedSize: nil, verdict: .warn(.appContainer), warnings: [.appContainer, .cloudOnly, .otherHardLinks])
        }
        let sheet = ConfirmTrashSheet(confirmation: .constant(TrashConfirmation(items: items)), scrolls: true, cancel: {}, move: {})
        XCTAssertTrue(sheet.scrolls)
        let rows = sheet.confirmation.warningRows
        XCTAssertEqual(rows.count, 24)
        for (n, row) in rows.enumerated() {
            XCTAssertEqual(row.id, UInt32(n))
            XCTAssertEqual(row.path, "/Fixture/long-warning-row-\(n)")
            XCTAssertEqual(row.texts, [reasonText(.appContainer), reasonText(.cloudOnly), reasonText(.otherHardLinks)])
        }
        let host = NSHostingView(rootView: sheet)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 520, accuracy: 0.01)
        // The shipped rows use this exact model, with unlimited vertically fixed text.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Tesserae/ConfirmTrashSheet.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("ForEach(confirmation.warningRows)"))
        XCTAssertTrue(source.contains("Text(text).fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(source.contains(".lineLimit("))
    }

    func test_jetsam_views_light_and_dark() throws {
        func item(_ id: UInt32, _ name: String, _ size: UInt64?, _ verdict: Verdict, _ warnings: [Reason] = [], directory: Bool = false, unknown: Bool = false) -> JetsamItem {
            JetsamItem(nodeIndex: id, path: Data(("/Fixture/" + name).utf8),
                recorded: Recorded(fileID: UInt64(id) + 1, device: 1, isDirectory: directory),
                recordedSize: size, verdict: verdict, warnings: warnings, hasUnknownContent: unknown)
        }
        let items = [item(0, "Archive.zip", 2_000_000_000, .ok),
            item(1, "Cloud.mov", nil, .warn(.cloudOnly), [.cloudOnly, .otherHardLinks]),
            item(2, "App documents", 1_000_000_000, .warn(.appContainer),
                [.appContainer, .containsUnknownSize, .containsCloudOnly, .containsHardLinks], directory: true, unknown: true),
            item(3, "System", nil, .denied(.osIntegrity))]
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(itemWarnings(items[1]).count, 2)
        XCTAssertNil(items[1].recordedSize)
        let confirmation = TrashConfirmation(items: items)
        XCTAssertTrue(confirmation.confirmedWarnings.isEmpty)
        try snapshot("jetsam-pane", JetsamView(items: items, remove: { _ in }, confirm: {}).frame(width: 620))
        try snapshot("jetsam-confirmation", ConfirmTrashSheet(confirmation: .constant(confirmation), scrolls: false, cancel: {}, move: {}))
        try snapshot("jetsam-progress", TrashProgressView(done: 2, total: 5))
        let trash = URL(fileURLWithPath: "/Fixture/Trash/Archive.zip")
        let entry = LogEntry(ts: date, action: "trash", path: "/Fixture/Archive.zip", pathB64: nil,
            inode: 1, bytes: 2_000_000_000, trashURL: trash.absoluteString, result: "ok")
        let cloudTrash = URL(fileURLWithPath: "/Fixture/Trash/Cloud.mov")
        let cloudEntry = LogEntry(ts: date, action: "trash", path: "/Fixture/Cloud.mov", pathB64: nil,
            inode: 2, bytes: nil, trashURL: cloudTrash.absoluteString, result: "ok")
        let result = ExecutionResult(outcomes: [(items[0], .trashed(trashURL: trash)),
            (items[1], .trashed(trashURL: cloudTrash)),
            (items[3], .skipped(.osIntegrity)), (items[2], .trashed(trashURL: URL(fileURLWithPath: "/Fixture/Trash/App documents"))),
            (item(6, "Not reviewed", 20, .warn(.appContainer)), .notConfirmed(.appContainer)),
            (item(4, "Replaced.pdf", 20, .ok), .identityChanged(.inodeChanged)),
            (item(5, "Offline.mp4", nil, .ok), .failed(errno: 5, message: "Volume unavailable"))],
            reclaimableBytes: 3_000_000_000, unknownSizeTrashed: 2)
        XCTAssertEqual(result.outcomes.count, 7)
        XCTAssertTrue(trashSummaryText(result, locale: locale).contains("plus 2 items of unknown size"))
        try snapshot("jetsam-summary", TrashSummaryView(result: result, entries: [entry, cloudEntry], restore: { _ in }).frame(width: 760))
        try snapshot("jetsam-recent", RecentlyTrashedView(entries: [entry], restore: { _ in }).frame(width: 620))
        try snapshot("jetsam-rescan", JetsamStatusView(rescanCount: 12))
        try snapshot("jetsam-log-failure", JetsamStatusView(logFailed: true))
        try snapshot("jetsam-unavailable", JetsamView(items: [], unavailable: true, remove: { _ in }, confirm: {}).frame(width: 620))
        let tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 450, height: 240), node: 0, depth: 0, flags: Tile.Flag.staged),
            Tile(rect: CGRect(x: 450, y: 0, width: 270, height: 240), node: 1, depth: 1)]
        XCTAssertEqual(tiles.filter { $0.flags & Tile.Flag.staged != 0 }.count, 1)
        try snapshot("jetsam-staged-treemap", JetsamFallbackPreview(tiles: tiles))
    }

}

private struct JetsamFallbackPreview: View {
    let tiles: [Tile]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let image = CGTreemapRenderer(clearColour: Palette.surface(dark: dark)).render(tiles: tiles,
            colours: Palette.colours(.depth, dark: dark), colourOf: { UInt16(2 + $0.depth) },
            size: CGSize(width: 720, height: 240), scale: 1)
        Image(decorative: image, scale: 1)
    }
}
