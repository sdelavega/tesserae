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

import Combine
import SwiftUI
import XCTest
import TesseraeFFI
@testable import TesseraeKit

@MainActor
final class DetailLevelTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private func breakdown(_ allocated: UInt64 = 40) -> ReconciliationViewModel {
        let scan = ScanFacts(allocatedSum: allocated, unreadableLocations: 0, incompleteReason: nil,
            limited: false, datalessItems: 0, access: .granted)
        let facts = VolumeFacts(capacity: 100, used: 80, free: 20, available: 20, purgeable: nil)
        return ReconciliationViewModel(wholeVolume: true,
            reconciliation: reconcile(facts, systemVolumeUsed: 10,
                SnapshotFacts(count: 2, oldest: nil, aggregateBytes: nil), scan), scan: scan, locale: locale)
    }
    private func report(_ count: UInt64 = 12) -> ScanReport {
        var stats = TessScanStats()
        stats.unreadable_count = count; stats.dataless_files = 3; stats.errors = 1
        let tree = TestSnapshot(.dir("/root", []), stats: stats)
        return ScanReport(snapshot: tree.snapshot, caveats: [], access: .granted,
            scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test", locale: locale)
    }
    func test_default_is_simple() {
        let defaults = UserDefaults(suiteName: "DetailLevelTests." + UUID().uuidString)!
        XCTAssertNil(defaults.object(forKey: "detailLevel"))
        let value = DetailSettings(defaults: defaults)
        XCTAssertEqual(value.current, .simple)
        value.current = .detailed
        XCTAssertEqual(defaults.string(forKey: "detailLevel"), "detailed")
        XCTAssertEqual(DetailSettings(defaults: defaults).current, .detailed)
        defaults.set("future", forKey: "detailLevel")
        XCTAssertEqual(DetailSettings(defaults: defaults).current, .simple)
    }
    func test_simple_breakdown_folds_snapshots_system_residual_into_other() throws {
        for (allocated, other) in [(UInt64(40), "40 bytes"), (UInt64(90), "−10 bytes")] {
            let model = breakdown(allocated)
            XCTAssertEqual(model.rows.count, 5)
            let rows = model.rows(for: .simple)
            XCTAssertEqual(rows.map(\.title), ["Used", "Free", "Other"])
            XCTAssertEqual(rows.map(\.value), ["\(allocated) bytes", "20 bytes", other])
            XCTAssertEqual(rows[2].negative, allocated == 90)
            XCTAssertNotNil(rows[2].help)
            let used = try XCTUnwrap(rows[0].fraction)
            let free = try XCTUnwrap(rows[1].fraction)
            let remainder = try XCTUnwrap(rows[2].fraction)
            XCTAssertEqual(used + free + (rows[2].negative ? -1 : 1) * remainder, 1, accuracy: 0.0001)
        }
    }
    func test_simple_free_row_is_shared_without_positional_indexing() throws {
        let model = breakdown()
        let detailedFree = try XCTUnwrap(model.rows(for: .detailed).first { $0.title == "Free" })
        let simpleFree = try XCTUnwrap(model.rows(for: .simple).first { $0.title == "Free" })
        XCTAssertEqual(detailedFree.value, "20 bytes")
        XCTAssertEqual(simpleFree, detailedFree)
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("TesseraeKit/Reconciliation/ReconciliationViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertNil(source.range(of: #"rows\[\d+\]"#, options: .regularExpression),
            "Simple must reuse Free by identity rather than Detailed row position")
    }
    func test_simple_stalled_report_states_reason_once() {
        var stats = TessScanStats()
        stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
        let raw = Data("/root/hung".utf8)
        let tree = TestSnapshot(.dir("/root", []), stats: stats, stalledAt: raw)
        let detailed = "Scan stalled at /root/hung"
        let caveat = ScanReport.ReportCaveat.stalled(display: "Scan stalled at /different/display", rawPath: raw)
        XCTAssertEqual(tree.snapshot.stats.incomplete, UInt32(TESS_INCOMPLETE_STALLED))
        XCTAssertEqual(tree.snapshot.stalledAt, raw)
        for caveats in [[], [caveat], [caveat, caveat]] {
            let value = ScanReport(snapshot: tree.snapshot, caveats: [], access: .granted,
                scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test",
                locale: locale, reportCaveats: caveats)
            XCTAssertEqual(value.summaryLines, ["The scan stopped because a folder wasn't responding."])
            XCTAssertEqual(value.incomplete, [detailed])
            XCTAssertEqual(value.caveats, caveats.map(\.displayText))
            XCTAssertTrue(value.text(for: .detailed).contains(detailed))
            XCTAssertTrue(caveats.allSatisfy { $0.diagnosticsText == detailed })
        }
    }
    func test_simple_report_summary_lines() {
        XCTAssertEqual(report().summaryLines, ["12 folders couldn't be read", "3 items are only in iCloud", "1 problem occurred during the scan"])
        XCTAssertEqual(report(1).summaryLines.first, "1 folder couldn't be read")
        XCTAssertFalse(report().text(for: .simple).contains("Dataless"))
        XCTAssertTrue(report().text(for: .detailed).contains("Unreadable: 12"))
        var stats = TessScanStats(); stats.incomplete = 999
        let tree = TestSnapshot(.dir("/root", []), stats: stats)
        let unknown = ScanReport(snapshot: tree.snapshot, caveats: [], access: .granted,
            scanTime: Date(), appVersion: "test", engineVersion: "test", locale: locale)
        XCTAssertFalse(unknown.text(for: .simple).contains("999"))
        XCTAssertFalse(ScanBanner.text(for: stats, stalledAt: nil, detailLevel: .simple)!.contains("999"))
        XCTAssertTrue(unknown.text(for: .detailed).contains("999"))
    }
    func test_detailed_matches_existing_output() {
        let model = breakdown()
        XCTAssertEqual(model.rows(for: .detailed), model.rows)
        let value = report()
        XCTAssertEqual(value.text(for: .detailed), value.text)
        XCTAssertEqual(reasonText(.cloudOnly, detailLevel: .detailed), reasonText(.cloudOnly))
        XCTAssertEqual(outcomeText(.failed(errno: 13, message: "Permission denied"), detailLevel: .detailed),
            "Failed: Permission denied (errno 13).")
    }
    func test_switch_updates_without_rerunning() throws {
        let settings = DetailSettings.shared
        let saved = settings.current
        settings.current = .simple
        defer { settings.current = saved }
        var probes = 0
        let scan = ScanFacts(allocatedSum: 40, unreadableLocations: 0, incompleteReason: nil,
            limited: false, datalessItems: 0, access: .granted)
        let model = ReconciliationViewModel.load(root: URL(fileURLWithPath: "/Fixture"), scan: scan,
            wholeVolume: { _ in true }, systemApplies: { _ in false }, volumeFacts: { _ in
                probes += 1
                return VolumeFacts(capacity: 100, used: 80, free: 20, available: 20, purgeable: nil)
            }, snapshots: { _ in SnapshotFacts(count: 0, oldest: nil, aggregateBytes: nil) }, locale: locale)
        XCTAssertEqual(probes, 1)
        let value = report()
        var confirmation = TrashConfirmation(items: [ReclaimItem(nodeIndex: 1, path: Data("/root/a".utf8),
            recorded: Recorded(fileID: 1, device: 1, isDirectory: false), recordedSize: 1, verdict: .warn(.cloudOnly))])
        XCTAssertEqual(confirmation.movingCount, 0)
        confirmation.setConfirmed(1, true)
        let reportRenderer = ImageRenderer(content: ScanReportView(report: value, scrolls: false)
            .frame(width: 420, height: 1200).environment(\.locale, locale))
        let sheetRenderer = ImageRenderer(content: ConfirmReclaimSheet(
            confirmation: Binding(get: { confirmation }, set: { confirmation = $0 }),
            scrolls: false, cancel: {}, move: {}).environment(\.locale, locale))
        func pixels<V: View>(_ renderer: ImageRenderer<V>) throws -> Data {
            renderer.scale = 1
            renderer.colorMode = .nonLinear
            var image: CGImage?
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                renderer.render { size, draw in
                    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    draw(context)
                    image = context.makeImage()
                }
            }
            return try XCTUnwrap(XCTUnwrap(image).dataProvider?.data) as Data
        }
        let simpleReport = try pixels(reportRenderer)
        let simpleSheet = try pixels(sheetRenderer)
        var changes: [DetailLevel] = []
        let token = settings.$current.sink { changes.append($0) }
        XCTAssertEqual(model.rows(for: settings.current).count, 3)
        let before = value.text(for: settings.current)
        settings.current = .detailed
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNotEqual(try pixels(reportRenderer), simpleReport, "The already-open report must update")
        XCTAssertNotEqual(try pixels(sheetRenderer), simpleSheet, "The already-open confirmation must update")
        XCTAssertEqual(model.rows(for: settings.current).count, 5)
        XCTAssertNotEqual(value.text(for: settings.current), before)
        settings.current = .simple
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try pixels(reportRenderer), simpleReport)
        XCTAssertEqual(try pixels(sheetRenderer), simpleSheet)
        XCTAssertEqual(value.text(for: settings.current), before)
        XCTAssertEqual(probes, 1, "Switching presentation must never reload volume facts")
        XCTAssertEqual(confirmation.confirmedWarnings, [1])
        XCTAssertEqual(confirmation.movingCount, 1)
        XCTAssertEqual(changes, [.simple, .detailed, .simple])
        withExtendedLifetime(token) {}
    }
    func test_copy_diagnostics_always_detailed() {
        final class Writer: DiagnosticsPasteboard {
            var text = ""
            func writePlaintext(_ text: String) -> Bool { self.text = text; return true }
        }
        let value = report()
        let writer = Writer()
        XCTAssertFalse(value.text(for: .simple).contains("Unreadable: 12"))
        XCTAssertTrue(value.copyDiagnostics(to: writer))
        XCTAssertEqual(writer.text, value.text(for: .detailed))
    }
    func test_simple_reclaim_keeps_warnings_refusals_and_hides_codes() {
        for reason: Reason in [.cloudOnly, .containsCloudOnly, .containsHardLinks, .changedSinceReview, .osIntegrity] {
            XCTAssertFalse(reasonText(reason, detailLevel: .simple).isEmpty)
            XCTAssertFalse(reasonText(reason, detailLevel: .simple).contains("\n"))
        }
        XCTAssertEqual(reasonText(.cloudOnly, detailLevel: .simple), "Trashing removes this item from iCloud on all devices and frees no space here.")
        XCTAssertEqual(reasonText(.containsHardLinks, detailLevel: .simple), "Space is freed only when every hard link is gone.")
        XCTAssertEqual(outcomeText(.failed(errno: 13, message: "Permission denied"), detailLevel: .simple), "This item couldn't be changed. Check its permissions and try again.")
        var compressed = CompressOutcome(runID: UUID())
        compressed.compressed = 2; compressed.signatureStatus = 77; compressed.auditFailed = true
        let simple = outcomeText(.compressed(compressed), detailLevel: .simple)
        XCTAssertFalse(simple.contains("\n"))
        XCTAssertFalse(simple.contains("77"))
        XCTAssertTrue(simple.contains("signature check failed"))
        XCTAssertTrue(simple.contains(ReclaimCopy.logFailure))
        var kept = CompressOutcome(runID: UUID())
        kept.skipped[.notWritable] = 1
        XCTAssertEqual(keptOutcomeReason(.compressed(kept), detailLevel: .simple), SkipReason.notWritable.localizedDescription)
        XCTAssertEqual(keptOutcomeReason(.failed(errno: 13, message: "Permission denied"), detailLevel: .simple),
            "This item couldn't be changed. Check its permissions and try again.")
        XCTAssertFalse(outcomeText(.identityChanged(.unreadable(errno: 13)), detailLevel: .simple).contains("13"))
    }
}
