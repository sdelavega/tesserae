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
import XCTest
import TesseraeFFI
@testable import TesseraeKit

final class ScanReportTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = TimeZone(secondsFromGMT: 0)!

    private func report(_ snapshot: Snapshot, caveats: [String] = []) -> ScanReport {
        ScanReport(snapshot: snapshot, caveats: caveats, access: .denied(evidence: "/probe"),
                   scanTime: Date(timeIntervalSince1970: 0), appVersion: "test-app", engineVersion: "test-engine",
                   locale: locale, timeZone: zone)
    }

    func test_synthetic_report_golden_is_stable_and_lists_every_path_and_count() {
        var stats = TessScanStats()
        stats.files = 9; stats.dirs = 4; stats.errors = 2; stats.unreadable_count = 2
        stats.hardlink_dups = 3; stats.lost_entries = 5; stats.depth_capped = 6
        stats.dataless_files = 7; stats.dataless_directories = 1; stats.dataless_logical_bytes = 1024
        stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED); stats.no_materialize_failed = 1
        let paths = [Data("/root/zero/locked".utf8), Data([47, 255, 10, 127])]
        let skips: [Snapshot.RequestedSkip] = [
            .init(path: Data("/limited".utf8), reason: "limited scan"),
            .init(path: Data("/missing".utf8), reason: "not present"),
            .init(path: Data("/other".utf8), reason: "other volume"),
            .init(path: Data("/smb".utf8), reason: "non-local mount"),
            .init(path: Data("/cloud".utf8), reason: "dataless directory")]
        let tree = TestSnapshot(.dir("/root", [.dir("zero", [.denied("locked")])]), stats: stats,
                                unreadable: paths, skipped: skips, stalledAt: Data("/root/hung".utf8))
        XCTAssertEqual(tree.snapshot.allocated(tree["zero"]), 0, "precondition: invisible in size layout")
        let value = report(tree.snapshot, caveats: ["Limited scan."])
        XCTAssertEqual(value.unreadable.map(\.rawPath), paths)
        XCTAssertEqual(value.skipped.map(\.rawPath), skips.map(\.path))
        XCTAssertEqual(value.text, """
        Summary
        Root: /root
        Scan time: 1970-01-01 00:00:00 GMT
        Entries: 13
        Directories: 4
        Files: 9
        Errors: 2
        Unreadable: 2
        Skipped (limited scan): 1
        Skipped (not present): 1
        Skipped (other volume): 1
        Skipped (non-local mount): 1
        Skipped (dataless directory): 1
        Dataless files: 7
        Dataless directories: 1
        Dataless logical bytes: 1,024
        Hardlink duplicates: 3
        Lost entries: 5
        Depth capped: 6

        Incomplete
        Scan stalled at /root/hung
        Cloud-only download protection could not be enabled for this scan.

        Reconciliation caveats
        Limited scan.

        Access
        Full Disk Access: denied — /probe

        Unreadable locations
        /root/zero/locked — permission denied
        /� � — permission denied

        Skipped locations
        /limited — limited scan
        /missing — not present
        /other — other volume
        /smb — non-local mount
        /cloud — dataless directory

        Versions
        App: test-app
        Engine: test-engine
        """)
    }

    func test_every_incomplete_code_uses_banner_wording_including_unknown() {
        for code: UInt32 in [0, 1, 2, 3, 4, 5, 6, 7, 999] {
            var stats = TessScanStats(); stats.incomplete = code
            let tree = TestSnapshot(.dir("/root", []), stats: stats)
            let reason = ScanBanner.incompleteReason(for: stats, stalledAt: nil)
            XCTAssertEqual(report(tree.snapshot).incomplete, reason.map { [$0] } ?? [])
            XCTAssertTrue(report(tree.snapshot).text.contains(reason ?? "Incomplete\nNone"))
        }
    }

    func test_every_caveat_reuses_reconciliation_wording() {
        let scan = ScanFacts(allocatedSum: 1, unreadableLocations: 0, incompleteReason: nil,
                             limited: true, datalessItems: 2, access: .unknown, datalessLogicalBytes: 1024)
        let caveats: [Caveat] = [.cloneDoubleCounting, .noFullDiskAccess, .accessUnknown, .limitedScan,
            .partialScan("Scan cancelled"), .containerDataUnavailable, .snapshotsUnavailable, .datalessNotCounted(2)]
        let r = Reconciliation(capacity: 1, scanned: 1, free: 0, systemVolume: nil,
            snapshots: SnapshotFacts(count: nil, oldest: nil, aggregateBytes: nil), residual: nil, purgeableEstimate: nil, caveats: caveats)
        let vm = ReconciliationViewModel(wholeVolume: true, reconciliation: r, scan: scan, locale: locale, timeZone: zone)
        XCTAssertEqual(vm.caveats.count, 8, "precondition: every caveat")
        let tree = TestSnapshot(.dir("/root", []))
        let value = report(tree.snapshot, caveats: vm.caveats)
        XCTAssertEqual(value.caveats, vm.caveats)
        for wording in vm.caveats { XCTAssertTrue(value.text.contains(wording), wording) }
    }

    func test_unreadable_under_zero_size_directory_is_in_report_without_layout_filtering() {
        let path = Data("/root/zero/locked".utf8)
        var stats = TessScanStats(); stats.unreadable_count = 1; stats.dirs = 3
        let tree = TestSnapshot(.dir("/root", [.dir("zero", [.denied("locked")])]), stats: stats, unreadable: [path])
        XCTAssertEqual(tree.snapshot.allocated(tree["zero"]), 0)
        XCTAssertTrue(tree.snapshot.isDirectory(tree["locked"]))
        let value = report(tree.snapshot)
        XCTAssertEqual(value.unreadable.map(\.rawPath), [path])
        XCTAssertTrue(value.text.contains("Unreadable locations\n/root/zero/locked"))
    }

    func test_display_sanitization_matches_table_for_each_path_component_and_keeps_raw_bytes() {
        let bytes: [UInt8] = [32, 255, 10, 127, 0, 32]
        let tree = TestSnapshot(.dir("/root", [.rawFile(bytes, key: "raw", 0)]))
        let raw = tree.snapshot.rawPath(tree["raw"])
        let location = ScanReport.Location(rawPath: raw, reason: nil)
        XCTAssertEqual(location.displayPath, "/root/" + tree.snapshot.displayName(tree["raw"]))
        XCTAssertEqual(location.rawPath, raw)
    }

    @MainActor
    func test_copy_diagnostics_writes_only_plaintext_pasteboard_no_files_or_defaults() throws {
        final class Writer: DiagnosticsPasteboard {
            var writes: [String] = []
            func writePlaintext(_ text: String) -> Bool { writes.append(text); return true }
        }
        let tree = TestSnapshot(.dir("/root", []))
        let value = report(tree.snapshot)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let domain = Bundle.main.bundleIdentifier ?? "TesseraeKitTests"
        let defaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        let writer = Writer()
        XCTAssertTrue(value.copyDiagnostics(to: writer))
        XCTAssertEqual(writer.writes, [value.text])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), files)
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary? ?? [:], defaults as NSDictionary)
        XCTAssertEqual(ScanReport.sharingNote, "This report contains file and folder names from your Mac. Review it before sharing.")
    }
}
