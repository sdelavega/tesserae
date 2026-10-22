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

import SwiftUI
import XCTest
import TesseraeFFI
@testable import TesseraeKit

@MainActor
final class ScanBannerTests: XCTestCase {
    private func session(_ code: UInt32 = UInt32(TESS_INCOMPLETE_STALLED)) -> AppSession {
        var stats = TessScanStats(); stats.incomplete = code
        return AppSession(snapshot: TestSnapshot(.dir("/root", []), stats: stats,
            stalledAt: Data("/root/hung".utf8)).snapshot)
    }

    func test_dismiss_hides_banner_for_this_session_only() throws {
        let first = session(); let second = session()
        let warning = try XCTUnwrap(first.warnings(for: .simple).first)
        XCTAssertFalse(first.dismissedBanners.contains(warning.id))
        first.dismiss(warning.id)
        XCTAssertTrue(first.warnings(for: .simple).isEmpty)
        XCTAssertTrue(first.warnings(for: .detailed).isEmpty)
        XCTAssertEqual(second.warnings(for: .simple).count, 1)
        XCTAssertEqual(first.snapshot.stats.incomplete, UInt32(TESS_INCOMPLETE_STALLED))
        XCTAssertFalse(first.scanReport.incomplete.isEmpty)
        XCTAssertTrue(first.isVisible(.limitedScan))
        first.dismiss(.limitedScan)
        XCTAssertFalse(first.isVisible(.limitedScan))
        first.markChangedSinceScan()
        let rescan = try XCTUnwrap(first.warnings(for: .simple).first)
        XCTAssertEqual(rescan.id, .rescan(revision: 0, changed: true))
        first.dismiss(rescan.id)
        XCTAssertTrue(first.warnings(for: .detailed).isEmpty)
    }

    func test_new_different_warning_shows_after_dismiss() throws {
        let value = session()
        value.droppedTileCount = 3
        let warnings = value.warnings(for: .simple)
        XCTAssertEqual(warnings.count, 2)
        for warning in warnings { value.dismiss(warning.id) }
        XCTAssertTrue(value.warnings(for: .simple).isEmpty)
        value.droppedTileCount = 4
        let next = try XCTUnwrap(value.warnings(for: .simple).first)
        XCTAssertEqual(next.id, .droppedTiles(4))
        XCTAssertEqual(value.warnings(for: .simple).count, 1)
        XCTAssertFalse(warnings.map(\.id).contains(next.id))
    }

    func test_new_scan_resets_dismissals() throws {
        let old = session()
        old.dismiss(try XCTUnwrap(old.warnings(for: .simple).first).id)
        XCTAssertFalse(old.dismissedBanners.isEmpty)
        let replacement = session()
        XCTAssertNotEqual(old.id, replacement.id)
        XCTAssertTrue(replacement.dismissedBanners.isEmpty)
        XCTAssertEqual(replacement.warnings(for: .simple).count, 1)
    }

    func test_partial_explanation_lines_per_stop_reason() {
        let expected = [
            "The scan finished, but some locations couldn't be included.",
            "The scan was cancelled before it finished.",
            "The scan stopped because it reached the maximum number of items it can hold.",
            "The scan stopped because there wasn't enough memory to continue.",
            "The scan stopped because a folder wasn't responding.",
            "The scan stopped because too many files or folders were open at once.",
            "The scan stopped because the filesystem returned information it couldn't read.",
            "The scan stopped because the disk became unavailable.",
            "The scan stopped before it finished."]
        for (index, code) in ([UInt32(0), 1, 2, 3, 4, 5, 6, 7, 999]).enumerated() {
            let value = session(code)
            let plain = PartialResultExplanation(stats: value.snapshot.stats, report: value.scanReport, detail: .simple)
            let detailed = PartialResultExplanation(stats: value.snapshot.stats, report: value.scanReport, detail: .detailed)
            XCTAssertFalse(plain.isEmpty)
            XCTAssertEqual(plain.first?.text, expected[index])
            XCTAssertEqual(detailed.first?.text, expected[index])
            XCTAssertFalse(plain.map(\.text).joined().contains("999"))
            XCTAssertTrue(detailed.map(\.text).joined().contains("Stop code: \(code)"))
            if code == UInt32(TESS_INCOMPLETE_STALLED) {
                XCTAssertTrue(plain.map(\.text).joined().contains("/root/hung"))
            }
        }
    }

    func test_top_locations_are_bounded_ranked_and_use_typed_paths() {
        var stats = TessScanStats(); stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
        let raw = Data("/root/stalled\nname".utf8)
        let paths = (0..<12).map { Data("/root/location-\($0)".utf8) }
        let tree = TestSnapshot(.dir("/root", []), stats: stats, unreadable: paths + [paths[5], paths[5]],
            skipped: [.init(path: paths[5], reason: "future_errno_123")])
        let report = ScanReport(snapshot: tree.snapshot, caveats: [], access: .granted,
            scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test",
            reportCaveats: [.stalled(display: "WRONG DISPLAY", rawPath: raw)])
        XCTAssertEqual(report.unreadable.count, 14)
        let simple = PartialResultExplanation(stats: stats, report: report, detail: .simple)
        let detailed = PartialResultExplanation(stats: stats, report: report, detail: .detailed)
        let locations = simple.filter { $0.location != nil }
        XCTAssertEqual(locations.count, 10)
        XCTAssertEqual(locations.first?.location, paths[5])
        XCTAssertEqual(locations.first?.count, 4)
        XCTAssertTrue(simple.map(\.text).joined().contains(DisplayPath.text(raw)))
        XCTAssertFalse(simple.map(\.text).joined().contains("WRONG DISPLAY"))
        XCTAssertFalse(simple.map(\.text).joined().contains("future_errno_123"))
        XCTAssertTrue(detailed.map(\.text).joined().contains("future_errno_123"))
    }

    func test_link_opens_sheet_and_show_report_opens_pane() throws {
        let presentation = PartialResultPresentation()
        var opened = false
        let banner = ScanWarningView(text: "partial", explain: presentation.explain, dismiss: {})
        XCTAssertFalse(presentation.showingExplanation)
        banner.explain?()
        XCTAssertTrue(presentation.showingExplanation)
        let sheet = PartialResultSheet(stats: session().snapshot.stats, report: session().scanReport,
            showReport: { presentation.showReport { opened = true } }, done: presentation.done)
        sheet.showReport()
        XCTAssertTrue(opened)
        XCTAssertFalse(presentation.showingExplanation)
        presentation.explain(); sheet.done()
        XCTAssertFalse(presentation.showingExplanation)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Tesserae/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("openScanReport: { showScanReport = true }"))
        XCTAssertTrue(content.contains("showReport: { partial.showReport(openScanReport) }"))
        XCTAssertTrue(content.contains("if showScanReport { ScanReportView(report: session.scanReport"))
    }
}
