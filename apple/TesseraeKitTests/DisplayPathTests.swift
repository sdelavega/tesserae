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

import XCTest
import TesseraeFFI
@testable import TesseraeKit

final class DisplayPathTests: XCTestCase {
    private let root = "/System/Volumes/Data"

    private func display(_ raw: Data, startupData: Data, firmlinks: [Data],
                         mountOn: (Data) -> Data?) -> String {
        // Model a foreign candidate mount in the one-time mount table.
        let candidateMount = mountOn(raw)
        let config = DisplayPath.Configuration(startupData: startupData, firmlinks: firmlinks,
            mountOn: mountOn, mounts: { candidateMount == startupData ? [startupData] : [startupData, raw] })
        return DisplayPath.text(raw, configuration: config)
    }

    func test_users_path_is_shortened() throws {
        let links = try String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        XCTAssertTrue(links.split(separator: "\n").contains("/Users\tUsers"), "precondition: measured Users mapping")
        XCTAssertEqual(DisplayPath.text(Data((root + "/Users").utf8)), "/Users")
        XCTAssertEqual(DisplayPath.text(Data((root + "/Users/missing-task3/file").utf8)), "/Users/missing-task3/file")
    }

    func test_root_of_data_volume_reads_slash() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: root), "precondition: startup Data mount exists")
        XCTAssertEqual(DisplayPath.text(Data(root.utf8)), "/")
        XCTAssertEqual(DisplayPath.text(Data((root + "/").utf8)), "/")
    }

    func test_non_firmlinked_data_paths_unchanged() {
        for suffix in ["/.Spotlight-V100", "/usr/bin", "/UsersElsewhere", "/System/Library/AssetsV20", "/Users/../.Spotlight-V100"] {
            let raw = Data((root + suffix).utf8)
            XCTAssertEqual(DisplayPath.text(raw), String(decoding: raw, as: UTF8.self))
        }
    }

    func test_other_volumes_unchanged() {
        for path in ["/Volumes/Second Data/Users/x", "/Volumes/image/System/Volumes/Data/Users/x", root + "-image/Users/x"] {
            XCTAssertEqual(DisplayPath.text(Data(path.utf8)), path)
        }
        let startup = StartupDisk.dataRoot
        let candidate = startup + Data("/Users/foreign/file".utf8)
        var candidateChecks = 0
        XCTAssertEqual(display(candidate, startupData: startup,
            firmlinks: [Data("/Users".utf8)], mountOn: { path in
                if path == startup { return startup }
                candidateChecks += 1
                return Data("/Volumes/foreign".utf8)
            }), neutralisedPath(candidate))
        XCTAssertEqual(candidateChecks, 1, "precondition: foreign identity was consulted")
        let other = Data("/Volumes/Second Data".utf8)
        XCTAssertEqual(display(Data("/Volumes/Second Data/Users/x".utf8), startupData: other,
            firmlinks: [Data("/Users".utf8)], mountOn: { _ in other }), "/Volumes/Second Data/Users/x")
        XCTAssertEqual(DisplayPath.text(Data("/Volumes/Second Data/Users/x".utf8), startupData: other), "/Volumes/Second Data/Users/x")
    }

    func test_displays_do_no_filesystem_calls_after_verification() {
        let startup = Data(root.utf8)
        let raw = startup + Data("/Users/x".utf8)
        var calls = 0
        let lookup: (Data) -> Data? = { _ in calls += 1; return startup }
        let config = DisplayPath.Configuration(startupData: startup, firmlinks: [Data("/Users".utf8)],
            mountOn: lookup, mounts: { calls += 1; return [startup] })
        XCTAssertTrue(config.verified)
        XCTAssertEqual(calls, 2, "one root lookup and one mount-table read")
        calls = 0
        for _ in 0..<100 {
            XCTAssertEqual(DisplayPath.text(raw, configuration: config), "/Users/x")
        }
        XCTAssertEqual(calls, 0)
    }

    func test_nested_mount_is_not_shortened_without_display_filesystem_calls() {
        let startup = Data(root.utf8)
        let nested = startup + Data("/Users/x/image".utf8)
        let raw = nested + Data("/file".utf8)
        var calls = 0
        let lookup: (Data) -> Data? = { path in calls += 1; return path == startup ? startup : nested }
        let config = DisplayPath.Configuration(startupData: startup, firmlinks: [Data("/Users".utf8)],
            mountOn: lookup, mounts: { calls += 1; return [startup, nested] })
        XCTAssertTrue(config.verified)
        XCTAssertEqual(config.nestedMounts, [nested])
        XCTAssertEqual(DisplayPath.text(nested, configuration: config), neutralisedPath(nested))
        XCTAssertEqual(DisplayPath.text(nested + Data("-other/file".utf8), configuration: config), "/Users/x/image-other/file")
        XCTAssertEqual(calls, 2)
        calls = 0
        XCTAssertEqual(DisplayPath.text(raw, configuration: config), neutralisedPath(raw))
        XCTAssertEqual(calls, 0)
        let aliasConfig = DisplayPath.Configuration(startupData: startup, firmlinks: [Data("/Users".utf8)],
            mountOn: lookup, mounts: { [startup, Data("/Users/x/image".utf8)] })
        XCTAssertTrue(aliasConfig.verified)
        XCTAssertEqual(DisplayPath.text(raw, configuration: aliasConfig), neutralisedPath(raw),
            "mount table may use the firmlink spelling")
    }

    @MainActor
    func test_changed_caveat_wording_keeps_raw_path_in_diagnostics() {
        final class Writer: DiagnosticsPasteboard {
            var text = ""
            func writePlaintext(_ text: String) -> Bool { self.text = text; return true }
        }
        var stats = TessScanStats()
        stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
        let stalled = Data((root + "/Users/hung").utf8)
        let tree = TestSnapshot(.dir(root, []), stats: stats, stalledAt: stalled)
        let wording = "Changed display wording: " + DisplayPath.text(stalled)
        let scan = ScanFacts(allocatedSum: 0, unreadableLocations: 0, incompleteReason: wording,
            limited: false, datalessItems: nil, access: .granted, stalledAt: stalled)
        let reconciliation = ReconciliationViewModel(wholeVolume: false, reconciliation: nil, scan: scan)
        XCTAssertEqual(reconciliation.caveats, [wording])
        let report = ScanReport(snapshot: tree.snapshot, caveats: [wording], access: .unknown,
            scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test",
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!,
            reportCaveats: reconciliation.reportCaveats)
        XCTAssertTrue(report.text.contains(wording))
        let writer = Writer()
        XCTAssertTrue(report.copyDiagnostics(to: writer))
        let session = AppSession(snapshot: tree.snapshot, reconciliation: reconciliation)
        let sessionWriter = Writer()
        XCTAssertTrue(session.scanReport.copyDiagnostics(to: sessionWriter))
        XCTAssertFalse(sessionWriter.text.contains(wording))
        XCTAssertEqual(sessionWriter.text.components(separatedBy: root + "/Users/hung").count - 1, 2)
        XCTAssertFalse(writer.text.contains(wording))
        XCTAssertEqual(writer.text.components(separatedBy: root + "/Users/hung").count - 1, 2)
    }

    func test_neutralisation_still_applies() {
        let suffix = Data("/Users/a\n\u{202e}b-".utf8) + Data([255])
        let raw = Data(root.utf8) + suffix
        XCTAssertNil(String(data: raw, encoding: .utf8), "precondition: invalid UTF-8")
        XCTAssertEqual(DisplayPath.text(raw), neutralisedPath(suffix))
        XCTAssertEqual(DisplayPath.text(Data("/else/a\n\u{202e}".utf8)), "/else/a �")
    }

    func test_copy_path_and_actions_use_raw_bytes() {
        let tree = TestSnapshot(.dir(root + "/Users", [.file("task3", 10)]))
        let node = tree["task3"]
        let raw = Data((root + "/Users/task3").utf8)
        XCTAssertEqual(DisplayPath.text(raw), "/Users/task3", "precondition: presentation differs")
        let info = inspect(node, in: tree.snapshot)
        XCTAssertEqual(info.rawPath, raw, "Copy Path and Reveal identity")
        XCTAssertEqual(tree.snapshot.rawPath(node), raw)
        let staged = StagedDescendants(snapshot: tree.snapshot, nodes: [node])
        XCTAssertEqual(staged.first?.path, raw, "filesystem action identity")
    }
    func test_firmlinks_are_measured_component_mappings() throws {
        let contents = try Data(contentsOf: URL(fileURLWithPath: "/usr/share/firmlinks"))
        let links = DisplayPath.parseFirmlinks(contents)
        XCTAssertTrue(links.contains(Data("/Users".utf8)))
        XCTAssertTrue(links.contains(Data("/private".utf8)), "precondition: /private is firmlinked on this host")
        XCTAssertEqual(DisplayPath.text(Data((root + "/private/var/db/task3").utf8)), "/private/var/db/task3")
        XCTAssertEqual(DisplayPath.text(Data((root + "/System/Library/Caches/task3").utf8)), "/System/Library/Caches/task3")
        XCTAssertEqual(DisplayPath.parseFirmlinks(Data("/Users Users\n/Users\tElsewhere\n/Users\tUsers\n".utf8)), [Data("/Users".utf8)])
    }

    func test_missing_firmlinks_and_unverified_mount_keep_raw_paths() {
        let raw = Data((root + "/Users/x").utf8)
        let startup = Data(root.utf8)
        let links = [Data("/Users".utf8)]
        XCTAssertNotEqual(raw, Data("/Users/x".utf8), "precondition: shortening changes the path")
        XCTAssertEqual(display(raw, startupData: startup, firmlinks: [], mountOn: { _ in startup }), neutralisedPath(raw))
        XCTAssertEqual(display(startup, startupData: startup, firmlinks: [], mountOn: { _ in startup }), root)
        XCTAssertEqual(display(raw, startupData: startup, firmlinks: links, mountOn: { _ in nil }), neutralisedPath(raw))
        XCTAssertEqual(display(raw, startupData: startup, firmlinks: links,
            mountOn: { $0 == startup ? startup : Data("/Volumes/image".utf8) }), neutralisedPath(raw))
        XCTAssertEqual(display(raw, startupData: startup, firmlinks: links,
            mountOn: { $0 == startup ? Data("/".utf8) : startup }), neutralisedPath(raw))
        XCTAssertEqual(DisplayPath.mountOn(startup), startup, "precondition: real statfs mount-on name")
    }

    @MainActor
    func test_display_surfaces_keep_volume_name_and_diagnostics_keep_raw_paths() {
        final class Writer: DiagnosticsPasteboard {
            var text = ""
            func writePlaintext(_ text: String) -> Bool { self.text = text; return true }
        }
        var stats = TessScanStats()
        stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
        let stalled = Data((root + "/Users/hung").utf8)
        let tree = TestSnapshot(.dir(root, [.dir("Users", [.file("task3", 10)])]), stats: stats,
            unreadable: [Data((root + "/Users/locked").utf8)], stalledAt: stalled)
        let session = AppSession(snapshot: tree.snapshot, startupDiskName: "Studio SSD")
        XCTAssertEqual(session.navigator.breadcrumbItems.first?.title, "Studio SSD")
        XCTAssertEqual(inspect(tree["task3"], in: tree.snapshot).displayPath, "/ › Users › task3")
        let nested = TestSnapshot(.dir(root + "/Users", []))
        XCTAssertEqual(Navigator(snapshot: nested.snapshot).breadcrumbItems.first?.title, "/Users")
        XCTAssertEqual(nested.snapshot.displayPath(0), "/Users")
        let reason = ScanBanner.incompleteReason(for: stats, stalledAt: DisplayPath.text(stalled))!
        let report = ScanReport(snapshot: tree.snapshot, caveats: [reason], access: .unknown,
            scanTime: Date(timeIntervalSince1970: 0), appVersion: "test", engineVersion: "test",
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!,
            reportCaveats: [.stalled(display: reason, rawPath: stalled)])
        XCTAssertTrue(report.text.contains("Root: /\n"))
        XCTAssertTrue(report.text.contains("/Users/locked"))
        XCTAssertFalse(report.text.contains(root))
        let writer = Writer()
        XCTAssertTrue(report.copyDiagnostics(to: writer))
        XCTAssertTrue(writer.text.contains("Root: " + root + "\n"))
        XCTAssertTrue(writer.text.contains(root + "/Users/locked"))
        XCTAssertFalse(writer.text.contains("at /Users/hung"))
        XCTAssertEqual(writer.text.components(separatedBy: root + "/Users/hung").count - 1, 2,
            "both Incomplete and reconciliation caveats retain the raw path")
        let item = ReclaimItem(nodeIndex: 0, path: Data((root + "/Users/task3").utf8),
            recorded: Recorded(fileID: 1, device: 1, isDirectory: false), recordedSize: 10, verdict: .ok)
        XCTAssertEqual(item.displayPath, "/Users/task3")
        XCTAssertEqual(TrashConfirmation(items: [item]).items.first?.path, item.path)
        let log = LogEntry(ts: Date(), action: "compress", path: root + "/Users/task3", pathB64: nil,
            inode: 1, bytes: 10, trashURL: nil, result: "ok")
        XCTAssertEqual(log.displayPath, "/Users/task3")
        XCTAssertEqual(log.path, root + "/Users/task3")
    }

}
