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

public enum ScanBanner {
    /// `stalledAt` is shown as names are (`singleLine`): it is made of them.
    public static func text(for stats: TessScanStats, stalledAt: String?, volumePath: String? = nil, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let reason = incompleteReason(for: stats, stalledAt: stalledAt) {
            parts.append(reason + (stats.incomplete == UInt32(TESS_INCOMPLETE_VOLUME_LOST)
                ? volumePath.map { ": " + singleLine($0) } ?? "" : ""))
        }
        if stats.errors > 0 { parts.append(String(
            localized: "scanBanner.errors",
            defaultValue: "\(stats.errors) errors",
            bundle: L10n.bundle,
            locale: L10n.pluralLocale(locale),
            comment: "ScanBanner: {stats.errors} errors."
        )) }
        if stats.unreadable_count > 0 { parts.append(String(
            localized: "scanBanner.unreadable.folders",
            defaultValue: "\(stats.unreadable_count) unreadable folders",
            bundle: L10n.bundle,
            locale: L10n.pluralLocale(locale),
            comment: "ScanBanner: {stats.unreadable_count} unreadable folders."
        )) }
        guard !parts.isEmpty else { return nil }
        return String(
            localized: "scan.partialResult",
            defaultValue: "Partial result — \(parts.joined(separator: "; "))",
            bundle: L10n.bundle,
            comment: "Warning banner. The placeholder lists translated stop reasons and counts."
        )
    }

    public static func incompleteReason(for stats: TessScanStats, stalledAt: String?) -> String? {
        switch stats.incomplete {
        case UInt32(TESS_INCOMPLETE_NONE): return nil
        case UInt32(TESS_INCOMPLETE_CANCELLED): return String(
            localized: "scanBanner.scan.cancelled",
            defaultValue: "Scan cancelled",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan cancelled."
        )
        case UInt32(TESS_INCOMPLETE_NODE_BUDGET): return String(
            localized: "scanBanner.scan.reached.its.node.limit",
            defaultValue: "Scan reached its node limit",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan reached its node limit."
        )
        case UInt32(TESS_INCOMPLETE_OUT_OF_MEMORY): return String(
            localized: "scanBanner.scan.ran.out.of.memory",
            defaultValue: "Scan ran out of memory",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan ran out of memory."
        )
        case UInt32(TESS_INCOMPLETE_STALLED):
            return String(
                localized: "scanBanner.scan.stalled",
                defaultValue: "Scan stalled",
                bundle: L10n.bundle,
                comment: "ScanBanner: Scan stalled."
            ) + (stalledAt.map { String(
                localized: "scanBanner.at",
                defaultValue: " at ",
                bundle: L10n.bundle,
                comment: "ScanBanner: at."
            ) + singleLine($0) } ?? "")
        case UInt32(TESS_INCOMPLETE_FD_EXHAUSTED): return String(
            localized: "scanBanner.scan.exhausted.file.descriptors",
            defaultValue: "Scan exhausted file descriptors",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan exhausted file descriptors."
        )
        case UInt32(TESS_INCOMPLETE_MALFORMED_BATCH): return String(
            localized: "scanBanner.scan.stopped.at.a.malformed.filesystem.batch",
            defaultValue: "Scan stopped at a malformed filesystem batch",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan stopped at a malformed filesystem batch."
        )
        case UInt32(TESS_INCOMPLETE_VOLUME_LOST): return String(
            localized: "scanBanner.scan.volume.became.unavailable",
            defaultValue: "Scan volume became unavailable",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan volume became unavailable."
        )
        default: return String(
            localized: "scanBanner.scan.ended.with.unknown.incomplete.code",
            defaultValue: "Scan ended with unknown incomplete code \(stats.incomplete)",
            bundle: L10n.bundle,
            comment: "ScanBanner: Scan ended with unknown incomplete code {stats.incomplete}."
        )
        }
    }
}
