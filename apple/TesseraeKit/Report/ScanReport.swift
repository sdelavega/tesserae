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

/// A detached value: paths retain their raw identity independently of the tree
/// layout, and only the display strings are decoded and sanitised.
public struct ScanReport: Equatable, Sendable {
    public enum ReportCaveat: Equatable, Sendable {
        case text(String)
        case stalled(display: String, rawPath: Data)

        public var displayText: String {
            switch self {
            case .text(let text), .stalled(let text, _): return text
            }
        }

        var diagnosticsText: String {
            switch self {
            case .text(let text): return text
            case .stalled(_, let raw):
                var stats = TessScanStats()
                stats.incomplete = UInt32(TESS_INCOMPLETE_STALLED)
                return ScanBanner.incompleteReason(for: stats,
                    stalledAt: Location(rawPath: raw, reason: nil).diagnosticsPath)!
            }
        }
    }

    public struct Location: Equatable, Sendable {
        public let rawPath: Data
        public let reason: String?
        public init(rawPath: Data, reason: String?) {
            self.rawPath = rawPath
            self.reason = reason
        }
        public var displayPath: String { DisplayPath.text(rawPath) }
        var diagnosticsPath: String {
            rawPath.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
                .map { part in part.isEmpty ? "" : Snapshot.displayName(bytes: Data(part)) }
                .joined(separator: "/")
        }
    }

    public static let sharingNote = String(
        localized: "scanReport.this.report.contains.file.and.folder.names.from",
        defaultValue: "This report contains file and folder names from your Mac. Review it before sharing.",
        bundle: L10n.bundle,
        comment: "ScanReport: This report contains file and folder names from your Mac. Review it before sharing."
    )
    public let unreadable: [Location]
    public let skipped: [Location]
    public let incomplete: [String]
    public let caveats: [String]
    public let text: String
    private let diagnosticsText: String

    public init(snapshot: Snapshot, caveats: [String], access: AccessState, scanTime: Date,
                appVersion: String, engineVersion: String, locale: Locale = .current, timeZone: TimeZone = .current, reportCaveats: [ReportCaveat]? = nil) {
        self.init(snapshot: snapshot, caveats: reportCaveats ?? caveats.map { .text($0) }, access: access, scanTime: scanTime,
                  appVersion: appVersion, engineVersion: engineVersion, locale: locale, timeZone: timeZone,
                  displayPaths: true)
    }

    private init(snapshot: Snapshot, caveats: [ReportCaveat], access: AccessState, scanTime: Date,
                 appVersion: String, engineVersion: String, locale: Locale, timeZone: TimeZone, displayPaths: Bool) {
        func path(_ location: Location) -> String { displayPaths ? location.displayPath : location.diagnosticsPath }
        unreadable = snapshot.unreadable.map { Location(rawPath: $0, reason: String(
            localized: "scanReport.permission.denied",
            defaultValue: "permission denied",
            bundle: L10n.bundle,
            comment: "ScanReport: permission denied."
        )) }
        skipped = snapshot.skipped.map { Location(rawPath: $0.path, reason: $0.reason) }
        let stats = snapshot.stats
        self.caveats = caveats.map { displayPaths ? $0.displayText : $0.diagnosticsText }
        var reasons = ScanBanner.incompleteReason(for: stats,
            stalledAt: snapshot.stalledAt.map { path(Location(rawPath: $0, reason: nil)) }).map { [$0] } ?? []
        if snapshot.noMaterializeFailed { reasons.append(ReconciliationViewModel.downloadProtectionWarning) }
        incomplete = reasons
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        func number(_ value: UInt64) -> String { value.formatted(.number.locale(locale)) }
        let root = path(Location(rawPath: snapshot.rawPath(snapshot.root), reason: nil))
        var summary = [String(
            localized: "scanReport.root",
            defaultValue: "Root: \(root)",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Scan report row: Root: The placeholder is its formatted value."
        ), String(
            localized: "scanReport.scan.time",
            defaultValue: "Scan time: \(formatter.string(from: scanTime))",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Scan report row: Scan time: The placeholder is its formatted value."
        ),
            String(
                localized: "scanReport.entries",
                defaultValue: "Entries: \(number(stats.files + stats.dirs))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Entries: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.directories",
                defaultValue: "Directories: \(number(stats.dirs))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Directories: The placeholder is its formatted value."
            ),
            String(
                localized: "scanReport.files",
                defaultValue: "Files: \(number(stats.files))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Files: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.errors",
                defaultValue: "Errors: \(number(stats.errors))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Errors: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.unreadable",
                defaultValue: "Unreadable: \(number(stats.unreadable_count))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Unreadable: The placeholder is its formatted value."
            )]
        let knownReasons = [String(
            localized: "snapshot.limited.scan",
            defaultValue: "limited scan",
            bundle: L10n.bundle,
            comment: "ScanReport: limited scan."
        ), String(
            localized: "snapshot.not.present",
            defaultValue: "not present",
            bundle: L10n.bundle,
            comment: "ScanReport: not present."
        ), String(
            localized: "snapshot.other.volume",
            defaultValue: "other volume",
            bundle: L10n.bundle,
            comment: "ScanReport: other volume."
        ), String(
            localized: "snapshot.non.local.mount",
            defaultValue: "non-local mount",
            bundle: L10n.bundle,
            comment: "ScanReport: non-local mount."
        ), String(
            localized: "snapshot.dataless.directory",
            defaultValue: "dataless directory",
            bundle: L10n.bundle,
            comment: "ScanReport: dataless directory."
        ), Snapshot.systemIndexReason]
        for reason in knownReasons + Set(skipped.compactMap(\.reason)).subtracting(knownReasons).sorted() {
            summary.append(String(
                localized: "scanReport.skipped",
                defaultValue: "Skipped (\(reason)): ",
                bundle: L10n.bundle,
                comment: "ScanReport: Skipped ({reason}):."
            ) + number(UInt64(skipped.filter { $0.reason == reason }.count)))
        }
        summary += [String(
            localized: "scanReport.dataless.files",
            defaultValue: "Dataless files: \(number(stats.dataless_files))",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Scan report row: Dataless files: The placeholder is its formatted value."
        ), String(
            localized: "scanReport.dataless.directories",
            defaultValue: "Dataless directories: \(number(stats.dataless_directories))",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Scan report row: Dataless directories: The placeholder is its formatted value."
        ),
            String(
                localized: "scanReport.dataless.logical.bytes",
                defaultValue: "Dataless logical bytes: \(number(stats.dataless_logical_bytes))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Dataless logical bytes: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.hardlink.duplicates",
                defaultValue: "Hardlink duplicates: \(number(stats.hardlink_dups))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Hardlink duplicates: The placeholder is its formatted value."
            ),
            String(
                localized: "scanReport.lost.entries",
                defaultValue: "Lost entries: \(number(stats.lost_entries))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Lost entries: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.depth.capped",
                defaultValue: "Depth capped: \(number(stats.depth_capped))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Depth capped: The placeholder is its formatted value."
            )]
        let accessText: String
        switch access {
        case .granted: accessText = String(
            localized: "scanReport.full.disk.access.granted",
            defaultValue: "Full Disk Access: granted",
            bundle: L10n.bundle,
            comment: "ScanReport: Full Disk Access: granted."
        )
        case .unknown: accessText = String(
            localized: "scanReport.full.disk.access.unknown",
            defaultValue: "Full Disk Access: unknown",
            bundle: L10n.bundle,
            comment: "ScanReport: Full Disk Access: unknown."
        )
        case .denied(let evidence): accessText = String(
            localized: "scanReport.full.disk.access.denied",
            defaultValue: "Full Disk Access: denied — ",
            bundle: L10n.bundle,
            comment: "ScanReport: Full Disk Access: denied —."
        ) + singleLine(evidence)
        }
        func section(_ name: String, _ lines: [String]) -> String {
            name + "\n" + (lines.isEmpty ? String(
                localized: "scanReport.none",
                defaultValue: "None",
                bundle: L10n.bundle,
                comment: "ScanReport: None."
            ) : lines.joined(separator: "\n"))
        }
        text = [section(String(
            localized: "scanReport.summary",
            defaultValue: "Summary",
            bundle: L10n.bundle,
            comment: "ScanReport: Summary."
        ), summary), section(String(
            localized: "scanReport.incomplete",
            defaultValue: "Incomplete",
            bundle: L10n.bundle,
            comment: "ScanReport: Incomplete."
        ), incomplete),
            section(String(
                localized: "scanReport.reconciliation.caveats",
                defaultValue: "Reconciliation caveats",
                bundle: L10n.bundle,
                comment: "ScanReport: Reconciliation caveats."
            ), self.caveats), section(String(
                localized: "scanReport.access",
                defaultValue: "Access",
                bundle: L10n.bundle,
                comment: "ScanReport: Access."
            ), [accessText]),
            section(String(
                localized: "scanReport.unreadable.locations",
                defaultValue: "Unreadable locations",
                bundle: L10n.bundle,
                comment: "ScanReport: Unreadable locations."
            ), unreadable.map { path($0) + String(
                localized: "scanReport.permission.denied.v2",
                defaultValue: " — permission denied",
                bundle: L10n.bundle,
                comment: "ScanReport: — permission denied."
            ) }),
            section(String(
                localized: "scanReport.skipped.locations",
                defaultValue: "Skipped locations",
                bundle: L10n.bundle,
                comment: "ScanReport: Skipped locations."
            ), skipped.map { path($0) + " — " + ($0.reason ?? String(
                localized: "snapshot.unknown",
                defaultValue: "unknown",
                bundle: L10n.bundle,
                comment: "ScanReport: unknown."
            )) }),
            section(String(
                localized: "scanReport.versions",
                defaultValue: "Versions",
                bundle: L10n.bundle,
                comment: "ScanReport: Versions."
            ), [String(
                localized: "scanReport.app",
                defaultValue: "App: \(singleLine(appVersion))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: App: The placeholder is its formatted value."
            ), String(
                localized: "scanReport.engine",
                defaultValue: "Engine: \(singleLine(engineVersion))",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Scan report row: Engine: The placeholder is its formatted value."
            )])]
            .joined(separator: "\n\n")
        diagnosticsText = displayPaths ? Self(snapshot: snapshot, caveats: caveats, access: access, scanTime: scanTime,
            appVersion: appVersion, engineVersion: engineVersion, locale: locale, timeZone: timeZone,
            displayPaths: false).text : text
    }

    @MainActor
    @discardableResult
    public func copyDiagnostics(to pasteboard: any DiagnosticsPasteboard) -> Bool {
        pasteboard.writePlaintext(diagnosticsText)
    }
}

@MainActor
public protocol DiagnosticsPasteboard {
    @discardableResult func writePlaintext(_ text: String) -> Bool
}
