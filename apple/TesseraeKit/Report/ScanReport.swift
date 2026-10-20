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

/// A detached value: paths retain their raw identity independently of the tree
/// layout, and only the display strings are decoded and sanitised.
public struct ScanReport: Equatable, Sendable {
    public struct Location: Equatable, Sendable {
        public let rawPath: Data
        public let reason: String?
        public init(rawPath: Data, reason: String?) {
            self.rawPath = rawPath
            self.reason = reason
        }
        public var displayPath: String {
            rawPath.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
                .map { part in
                    part.isEmpty ? "" : Snapshot.displayName(bytes: Data(part))
                }.joined(separator: "/")
        }
    }

    public static let sharingNote = "This report contains file and folder names from your Mac. Review it before sharing."
    public let unreadable: [Location]
    public let skipped: [Location]
    public let incomplete: [String]
    public let caveats: [String]
    public let text: String

    public init(snapshot: Snapshot, caveats: [String], access: AccessState, scanTime: Date,
                appVersion: String, engineVersion: String, locale: Locale = .current, timeZone: TimeZone = .current) {
        unreadable = snapshot.unreadable.map { Location(rawPath: $0, reason: "permission denied") }
        skipped = snapshot.skipped.map { Location(rawPath: $0.path, reason: $0.reason) }
        self.caveats = caveats
        let stats = snapshot.stats
        var reasons = ScanBanner.incompleteReason(for: stats,
            stalledAt: snapshot.stalledAt.map { Location(rawPath: $0, reason: nil).displayPath }).map { [$0] } ?? []
        if snapshot.noMaterializeFailed { reasons.append(ReconciliationViewModel.downloadProtectionWarning) }
        incomplete = reasons
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        func number(_ value: UInt64) -> String { value.formatted(.number.locale(locale)) }
        let root = Location(rawPath: snapshot.rawPath(snapshot.root), reason: nil).displayPath
        var summary = ["Root: " + root, "Scan time: " + formatter.string(from: scanTime),
            "Entries: " + number(stats.files + stats.dirs), "Directories: " + number(stats.dirs),
            "Files: " + number(stats.files), "Errors: " + number(stats.errors), "Unreadable: " + number(stats.unreadable_count)]
        let knownReasons = ["limited scan", "not present", "other volume", "non-local mount", "dataless directory"]
        for reason in knownReasons + Set(skipped.compactMap(\.reason)).subtracting(knownReasons).sorted() {
            summary.append("Skipped (\(reason)): " + number(UInt64(skipped.filter { $0.reason == reason }.count)))
        }
        summary += ["Dataless files: " + number(stats.dataless_files), "Dataless directories: " + number(stats.dataless_directories),
            "Dataless logical bytes: " + number(stats.dataless_logical_bytes), "Hardlink duplicates: " + number(stats.hardlink_dups),
            "Lost entries: " + number(stats.lost_entries), "Depth capped: " + number(stats.depth_capped)]
        let accessText: String
        switch access {
        case .granted: accessText = "Full Disk Access: granted"
        case .unknown: accessText = "Full Disk Access: unknown"
        case .denied(let evidence): accessText = "Full Disk Access: denied — " + singleLine(evidence)
        }
        func section(_ name: String, _ lines: [String]) -> String {
            name + "\n" + (lines.isEmpty ? "None" : lines.joined(separator: "\n"))
        }
        text = [section("Summary", summary), section("Incomplete", incomplete),
            section("Reconciliation caveats", caveats), section("Access", [accessText]),
            section("Unreadable locations", unreadable.map { $0.displayPath + " — permission denied" }),
            section("Skipped locations", skipped.map { $0.displayPath + " — " + ($0.reason ?? "unknown") }),
            section("Versions", ["App: " + singleLine(appVersion), "Engine: " + singleLine(engineVersion)])]
            .joined(separator: "\n\n")
    }

    @MainActor
    @discardableResult
    public func copyDiagnostics(to pasteboard: any DiagnosticsPasteboard) -> Bool {
        pasteboard.writePlaintext(text)
    }
}

@MainActor
public protocol DiagnosticsPasteboard {
    @discardableResult func writePlaintext(_ text: String) -> Bool
}
