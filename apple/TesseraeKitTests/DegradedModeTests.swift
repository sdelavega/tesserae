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

/// Synthetic Phase 3 gate: no scan, permission probe, subprocess or volume access.
/// App-only panes are also compiled into this target to render the shipped views.
@MainActor
final class DegradedModeTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let size = CGSize(width: 960, height: 1200)
    private static var references: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SnapshotTests")
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
            renderer.isOpaque = true
            renderer.colorMode = .nonLinear
            // Draw directly into a fixed sRGB bitmap: the convenience rasterizer
            // varies by one channel unit at antialiased glyph edges.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            let context = try XCTUnwrap(CGContext(data: nil, width: 960, height: 1200,
                bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            withTransaction(transaction) {
                renderer.render { _, draw in draw(context) }
            }
            let actual = try XCTUnwrap(context.makeImage(), name)
            XCTAssertEqual(actual.width, 960); XCTAssertEqual(actual.height, 1200)
            let url = Self.references.appendingPathComponent(name + ".png")
            let recordNames = ProcessInfo.processInfo.environment["TESSERAE_RECORD_SNAPSHOT_NAMES"]?.split(separator: ",").map(String.init)
            if ProcessInfo.processInfo.environment["TESSERAE_RECORD_SNAPSHOTS"] == "1",
               recordNames == nil || recordNames!.contains(name) {
                try png(actual, url)
                let review = Self.references.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/task-10-review")
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
                    .appendingPathComponent("build/task-10-review/" + name + ".actual.png")
                try png(actual, output)
                XCTFail("Exact RGBA mismatch: " + name + "; actual: " + output.path)
            }
        }
    }

    private func text(_ m: ReconciliationViewModel) -> String {
        ([m.title, m.scopeMessage, m.purgeable, m.warning] + m.caveats.map(Optional.some)
            + m.rows.flatMap { [$0.title, $0.value, $0.detail, $0.annotation] }).compactMap { $0 }.joined(separator: "\n")
    }

    private func contains(_ actual: String, _ required: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(required.isEmpty, "precondition: explicit semantic expectations", file: file, line: line)
        for value in required { XCTAssertTrue(actual.contains(value), "Missing: \(value) in \(actual)", file: file, line: line) }
    }

    private func scan(_ allocated: UInt64 = 40_000_000_000, reason: String? = nil,
                      access: AccessState = .granted, limited: Bool = false, unreadable: Int = 0, cloud: Bool = true) -> ScanFacts {
        ScanFacts(allocatedSum: allocated, unreadableLocations: unreadable, incompleteReason: reason,
            limited: limited, datalessItems: cloud ? 5 : 0, access: access, datalessLogicalBytes: cloud ? 15_729_664 : 0)
    }

    private func model(_ scan: ScanFacts, system: UInt64? = 10_000_000_000,
                       snapshots: Int? = 7, missing: Bool = false, overflow: Bool = false,
                       wholeVolume: Bool = true, removable: Bool = false) -> ReconciliationViewModel {
        let facts = VolumeFacts(capacity: overflow ? UInt64.max : 100_000_000_000,
            used: 80_000_000_000, free: 20_000_000_000, available: 20_000_000_000,
            purgeable: removable ? nil : 7_000_000_000)
        let result = reconcile(facts, systemVolumeUsed: system,
            SnapshotFacts(count: snapshots, oldest: snapshots == 0 ? nil : date, aggregateBytes: nil), scan)
        return ReconciliationViewModel(wholeVolume: wholeVolume, reconciliation: missing ? nil : result,
            scan: scan, locale: locale, timeZone: zone, systemVolumeApplicable: !removable)
    }

    private func panel(_ model: ReconciliationViewModel, banner: String? = nil,
                       limited: Bool = false, root: String = "/System/Volumes/Data") -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if limited { LimitedAccessView(reopen: {}) }
            if let banner { ScanWarningView(text: banner) }
            HStack { Text(root); Spacer(); Text(model.rows.first { $0.title == "Scanned" }?.value ?? "40 GB") }
                .padding(12)
            Divider()
            ReconciliationView(model: model, grantAccess: {}).padding(16).frame(width: 240)
        }
    }

    func test_main_window_all_panes_fit_at_1440_by_900() async throws {
        var stats = TessScanStats(); stats.files = 3; stats.dirs = 2
        let tree = TestSnapshot(.dir("/Fixture", [
            .dir("Projects", [.file("a-long-source-file-name.swift", 30_000_000_000), .file("archive.zip", 10_000_000_000)]),
            .file("photo.raw", 5_000_000_000)]), stats: stats)
        let report = ScanReport(snapshot: tree.snapshot, caveats: model(scan()).caveats, access: .granted,
            scanTime: date, appVersion: "test-app", engineVersion: "test-engine", locale: locale, timeZone: zone)
        let session = AppSession(snapshot: tree.snapshot, reconciliation: model(scan()), access: .granted, scanTime: date, report: report)
        session.reclaim.publish([tree["archive.zip"], tree["photo.raw"]].map { node in
            ReclaimItem(nodeIndex: node, path: tree.snapshot.rawPath(node),
                recorded: Recorded(fileID: UInt64(node) + 1, device: 1, isDirectory: false),
                recordedSize: tree.snapshot.allocated(node), verdict: .ok)
        })
        let volume = VolumeCapabilities(isLocal: true, isWritable: true, fsType: "apfs")
        session.reclaim.viewModel.replace(session.reclaim.items,
            volumes: Dictionary(uniqueKeysWithValues: session.reclaim.items.map { ($0.id, volume) }))
        XCTAssertEqual(session.reclaim.items.count, 2, "precondition: populated Reclaim pane")
        let app = AppModel(coordinator: ScanCoordinator(factory: { _, _ in nil }), accessLoader: { .granted })
        await app.waitForAccess()
        let ui = ReclaimPresentation(log: ReclaimLog(directory: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("unused-window-log")))
        let reportLayout = ScanReportLayout()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TesseraeKitTests.FileList." + UUID().uuidString))
        let content = SessionView(session: session, mode: .folder, dark: false, grantAccess: {}, stage: {},
            stagingDisabled: true, reclaimUI: ui, showReclaim: true, showScanReport: true, useMetal: false, reportLayout: reportLayout, appModel: app)
            .environment(\.locale, locale).environment(\.timeZone, zone)
            .environment(\.colorScheme, .light).background(Color.white)
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            await session.waitForTable(); await session.waitForLabels()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.tiles.isEmpty, "precondition: populated treemap")
        XCTAssertEqual(session.table.rows.count, 3, "precondition: populated table")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(table.numberOfColumns, 5)
        XCTAssertLessThanOrEqual(table.rect(ofColumn: 4).maxX, scroll.contentSize.width + 1, "every column fits: \(table.tableColumns.map(\.width)), spacing=\(table.intercellSpacing)")
        XCTAssertLessThanOrEqual(table.bounds.width, scroll.contentSize.width + 1, "no horizontal table overflow; columns: \(table.tableColumns.map(\.width))")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(table.tableColumns[0].width, 180, "Name stays readable")
        XCTAssertLessThanOrEqual(table.rect(ofColumn: 0).maxX, scroll.contentSize.width)
        let frame = reportLayout.copyDiagnosticsFrame
        XCTAssertGreaterThan(frame.width, 90, "precondition: full button has width")
        XCTAssertGreaterThan(frame.height, 15)
        XCTAssertGreaterThan(frame.minX, 1000, "precondition: button is in rightmost report pane")
        XCTAssertTrue(host.bounds.contains(frame), "Copy Diagnostics must be fully inside window: \(frame), \(host.bounds)")
        XCTAssertNotNil(session.reconciliation, "precondition: space breakdown visible")
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 1440 * 4, bitsPerPixel: 32))
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let actual = try XCTUnwrap(bitmap.cgImage)
        let output = Self.references.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ui-fixes/main-window-all-panes.actual.png")
        try png(actual, output)
        let reference = Self.references.appendingPathComponent("main-window-all-panes-1440x900.png")
        guard let source = CGImageSourceCreateWithURL(reference as CFURL, nil) else {
            XCTFail("Missing main-window reference; inspect " + output.path); return
        }
        let expected = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
        XCTAssertEqual(try pixels(actual), try pixels(expected), "main-window snapshot changed")
        XCTAssertEqual(ContentView.minimumContentSize, CGSize(width: 1440, height: 720))
        window.setContentSize(ContentView.minimumContentSize)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.bounds.contains(reportLayout.copyDiagnosticsFrame), "controls also fit at the window minimum")
        XCTAssertLessThanOrEqual(table.rect(ofColumn: 4).maxX, scroll.contentSize.width + 1)
        withExtendedLifetime(tree) {}
    }

    func test_start_screen_shows_volume_groups() async throws {
        let model = VolumeListModel(source: StartFixture())
        await model.refresh()
        XCTAssertEqual(model.volumes.map(\.name), ["Studio SSD", "External", "Server"])
        XCTAssertEqual(model.volumes.map(\.group), [.thisMac, .otherDisks, .network])
        // ImageRenderer cannot draw the AppKit scroll container; render its
        // actual production contents so the reference includes every row.
        try snapshot("start", StartView(volumes: model, scan: { _ in }, chooseFolder: {}).volumeGroups.padding(32))
        model.stop()
    }

    func test_cloud_only_folder_badge_is_distinct_from_permissions() throws {
        var cloud = TestSnapshot.Spec.denied("cloud")
        cloud.dataless = true
        let tree = TestSnapshot(.dir("/Fixture", [cloud, .denied("private")]))
        XCTAssertTrue(tree.snapshot.isDataless(tree["cloud"]), "precondition: dataless flag reaches the snapshot")
        XCTAssertFalse(tree.snapshot.isDataless(tree["private"]))
        let badge = FolderBadge(snapshot: tree.snapshot, node: tree["cloud"])
        let denied = FolderBadge(snapshot: tree.snapshot, node: tree["private"])
        XCTAssertEqual(badge.label, "Cloud-only folder")
        XCTAssertEqual(badge.symbol, "icloud")
        XCTAssertEqual(denied.label, "Unreadable folder")
        XCTAssertEqual(denied.symbol, "lock.fill")
        try snapshot("cloud-folder-badge", HStack {
            Image(systemName: badge.symbol).accessibilityLabel(badge.label)
            Text(badge.label)
        }.padding())
    }

    func test_refused_scan_start_has_plain_copy_and_errno_diagnostics() {
        let refused = ScanFailureViewModel(errno: EINVAL)
        XCTAssertGreaterThan(EINVAL, 0, "precondition: errno used by the begin refusal")
        XCTAssertEqual(refused.reason, "Couldn’t start the scan")
        XCTAssertFalse(refused.text.contains("Invalid argument"))
        XCTAssertTrue(refused.diagnostics.contains("errno: \(EINVAL)"))
        XCTAssertTrue(refused.diagnostics.contains(String(cString: strerror(EINVAL))))
    }

    func test_spec_matrix_status_reconciliation_and_banners() throws {
        let noFDA = model(scan(access: .denied(evidence: "synthetic EPERM"), limited: true, unreadable: 3))
        XCTAssertTrue(noFDA.showGrantAccess)
        contains(text(noFDA), ["Full Disk Access is missing.", "Limited scan.", "3 locations unreadable"])
        let limited = panel(noFDA, limited: true)
        contains(LimitedAccessViewModel.text + "\n" + noFDA.grantAccessTitle, ["Limited scan selected", "Review Full Disk Access", "Grant Access"])
        try snapshot("no-fda", limited)

        let diskutil = model(scan(), system: nil, snapshots: nil)
        XCTAssertEqual(diskutil.rows[2].value, "—")
        contains(text(diskutil), ["Local snapshots: —", "System volume information unavailable."])
        try snapshot("diskutil-unavailable", panel(diskutil))
        let snapshots = model(scan(), snapshots: nil)
        XCTAssertEqual(snapshots.rows[2].value, "10 GB", "precondition: container data still known")
        contains(text(snapshots), ["Local snapshots: —", "Local snapshot information unavailable."])
        try snapshot("snapshots-unavailable", panel(snapshots))

        let cases: [(String, Int32, String)] = [
            ("node-limit", TESS_INCOMPLETE_NODE_BUDGET, "Scan reached its node limit"),
            ("cancelled", TESS_INCOMPLETE_CANCELLED, "Scan cancelled"),
            ("stalled", TESS_INCOMPLETE_STALLED, "Scan stalled at /Volumes/Fixture/blocked"),
            ("volume-lost", TESS_INCOMPLETE_VOLUME_LOST, "Scan volume became unavailable")]
        for (name, code, reason) in cases {
            var stats = TessScanStats(); stats.incomplete = UInt32(code)
            let banner = try XCTUnwrap(ScanBanner.text(for: stats, stalledAt: "/Volumes/Fixture/blocked", volumePath: "/Volumes/Fixture"))
            contains(banner, ["Partial", reason])
            if code == TESS_INCOMPLETE_VOLUME_LOST { contains(banner, ["unavailable: /Volumes/Fixture"]) }
            let m = model(scan(reason: ScanBanner.incompleteReason(for: stats, stalledAt: "/Volumes/Fixture/blocked")))
            XCTAssertEqual(m.rows[3].value, "—"); XCTAssertNil(m.rows[3].fraction)
            contains(text(m), [reason])
            let view = panel(m, banner: banner, root: "/Volumes/Fixture")
            contains(banner, ["Partial", reason])
            try snapshot(name, view)
        }

        // CoreGraphics directly, with no device creation or Metal animation.
        let tiles = [Tile(rect: CGRect(x: 0, y: 0, width: 450, height: 240), node: 0, depth: 0),
                     Tile(rect: CGRect(x: 450, y: 0, width: 270, height: 240), node: 1, depth: 1)]
        XCTAssertEqual(tiles.count, 2)
        let m = model(scan())
        contains(text(m), ["Space breakdown", "+30 GB"])
        XCTAssertNil(m.warning, "a fallback needs no warning")
        try snapshot("no-metal", HStack(alignment: .top, spacing: 0) {
            FallbackPreview(tiles: tiles).frame(width: 720, height: 240)
            ReconciliationView(model: m, grantAccess: {}).padding(16).frame(width: 240)
        })
        let failure = ScanFailureView(errno: EIO, chooseFolder: {})
        contains(ScanFailureViewModel(errno: EIO).text, ["Couldn’t scan this folder", "Input/output error", "Copy Diagnostics"])
        try snapshot("rust-panic", failure)
    }

    func test_reconciliation_variants() throws {
        let positive = model(scan())
        contains(text(positive), ["+30 GB", "7 local snapshots, oldest 15 Jan", "about 7 GB purgeable"])
        try snapshot("positive-residual", panel(positive))
        let negative = model(scan(90_000_000_000))
        XCTAssertTrue(negative.rows[3].negative, "precondition: dashed negative bar")
        contains(text(negative), ["−20 GB", "the scan is double-counting shared blocks"])
        try snapshot("negative-residual", panel(negative))
        let missing = model(scan(), missing: true)
        XCTAssertNil(missing.rows[3].fraction)
        contains(text(missing), ["Volume information unavailable"])
        try snapshot("suppressed-volume-facts", panel(missing))
        let partial = model(scan(reason: "Scan cancelled"))
        contains(text(partial), ["Scan cancelled"]); XCTAssertEqual(partial.rows[3].value, "—")
        try snapshot("suppressed-partial", panel(partial))
        let overflow = model(scan(), overflow: true)
        contains(text(overflow), ["Too large to compute"]); XCTAssertEqual(overflow.rows[3].value, "—")
        try snapshot("suppressed-overflow", panel(overflow))
        let folder = model(scan(), wholeVolume: false)
        XCTAssertTrue(folder.rows.isEmpty)
        contains(text(folder), ["Space breakdown is available when you scan a whole volume."])
        try snapshot("folder", panel(folder, root: "/Fixture/Folder"))
        let removable = model(scan(cloud: false), system: 0, snapshots: 0, removable: true)
        XCTAssertNil(removable.purgeable)
        contains(text(removable), ["0 local snapshots", "Not applicable"])
        XCTAssertFalse(text(removable).contains("System volume information unavailable"))
        try snapshot("removable-non-apfs", panel(removable, root: "/Volumes/Fixture-exFAT"))
    }

    func test_onboarding_states() throws {
        XCTAssertEqual(OnboardingViewModel.privacy, "No telemetry. The only network traffic is the update check.")
        var state = Onboarding()
        state.send(.activated(.denied(evidence: "synthetic EPERM")))
        XCTAssertTrue(state.isPresented); XCTAssertFalse(state.needsRelaunch)
        let first = OnboardingView(state: state, send: { _ in })
        contains(OnboardingViewModel(relaunchRequired: state.needsRelaunch).text, ["Full Disk Access", "Use Limited Scan", "Open Settings",
            "Relaunch Tesserae", "Access changes apply only after relaunch."])
        try snapshot("onboarding-first-launch", first)
        state.send(.openSettings); state.send(.activated(.denied(evidence: "cached EPERM")))
        XCTAssertTrue(state.needsRelaunch)
        let relaunch = OnboardingView(state: state, send: { _ in })
        contains(OnboardingViewModel(relaunchRequired: state.needsRelaunch).text, ["Full Disk Access granted — relaunch to apply", "cannot confirm the grant"])
        try snapshot("fda-mid-session-relaunch", relaunch)
        state.send(.useLimited)
        XCTAssertFalse(state.isPresented); XCTAssertTrue(state.showsLimitedAffordance)
        let limited = LimitedAccessView(reopen: {})
        contains(LimitedAccessViewModel.text, ["Limited scan selected", "Review Full Disk Access"])
        try snapshot("onboarding-limited", limited)
        state.send(.reopen)
        XCTAssertTrue(state.isPresented, "reopen affordance returns to the real sheet")
        try snapshot("onboarding-reopened", OnboardingView(state: state, send: { _ in }))
    }

    func test_scan_report_counts_and_locations() throws {
        var stats = TessScanStats()
        stats.files = 12; stats.dirs = 8; stats.unreadable_count = 2; stats.errors = 2
        stats.dataless_files = 4; stats.dataless_directories = 1; stats.dataless_logical_bytes = 15_729_664
        let reasons = ["other volume", "non-local mount", "limited scan", "dataless directory"]
        let tree = TestSnapshot(.dir("/Fixture", [.file("local", 40_000_000_000)]), stats: stats,
            unreadable: [Data("/Fixture/private-a".utf8), Data("/Fixture/private-b".utf8)],
            skipped: reasons.enumerated().map { .init(path: Data("/Fixture/skip-\($0.offset)".utf8), reason: $0.element) })
        let report = ScanReport(snapshot: tree.snapshot, caveats: model(scan()).caveats, access: .granted,
            scanTime: date, appVersion: "0.3-fixture", engineVersion: "fixture (ABI 1)", locale: locale, timeZone: zone)
        XCTAssertEqual(report.unreadable.count, 2); XCTAssertEqual(report.skipped.count, 4)
        contains(report.text, ["Unreadable: 2", "Skipped (other volume): 1", "Skipped (non-local mount): 1",
            "Skipped (limited scan): 1", "Skipped (dataless directory): 1", "Dataless files: 4",
            "Dataless directories: 1", "Dataless logical bytes: 15,729,664", "2027-01-15 08:00:00 GMT"])
        let view = ScanReportView(report: report, scrolls: false)
        contains(report.text, ["/Fixture/private-a — permission denied", "/Fixture/skip-3 — dataless directory"])
        try snapshot("scan-report", view.frame(width: 520))
        withExtendedLifetime(tree) {}
    }
}

private struct FallbackPreview: View {
    let tiles: [Tile]
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        let image = CGTreemapRenderer(clearColour: Palette.surface(dark: dark)).render(tiles: tiles,
            colours: Palette.colours(.folder, dark: dark), colourOf: { UInt16(2 + $0.depth) },
            size: CGSize(width: 720, height: 240), scale: 1)
        Image(decorative: image, scale: 1)
    }
}

private struct StartFixture: VolumeSource {
    func mounted() async -> [RawVolume] {
        [("/", "Studio SSD", true), ("/Volumes/External", "External", true), ("/Volumes/Server", "Server", false)].map {
            RawVolume(url: URL(fileURLWithPath: $0.0), name: $0.1, local: $0.2,
                      browsable: true, hidden: false, readOnly: false, typeName: $0.2 ? "apfs" : "smbfs",
                      isDiskImage: false, isTimeMachine: false, total: $0.2 ? 1_000_000 : nil, free: $0.2 ? 400_000 : nil)
        }
    }
}
