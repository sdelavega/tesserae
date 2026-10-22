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
    public static func text(for stats: TessScanStats, stalledAt: String?, volumePath: String? = nil, locale: Locale = .current, detailLevel: DetailLevel = .detailed) -> String? {
        var parts: [String] = []
        if let reason = incompleteReason(for: stats, stalledAt: stalledAt, detailLevel: detailLevel) {
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

    public static func incompleteReason(for stats: TessScanStats, stalledAt: String?, detailLevel: DetailLevel = .detailed) -> String? {
        if detailLevel == .simple, stats.incomplete > UInt32(TESS_INCOMPLETE_VOLUME_LOST) {
            return String(localized: "detail.scan.stopped", defaultValue: "The scan stopped before it finished.",
                bundle: L10n.bundle, comment: "Unknown scan stop reason without an internal code.")
        }
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
            if detailLevel == .simple {
                return String(localized: "detail.scan.stalled",
                    defaultValue: "The scan stopped because a folder wasn't responding.",
                    bundle: L10n.bundle, comment: "Plain explanation of a stalled scan without a path.")
            }
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

/// Identity is independent of translated text and the presentation detail setting.
public struct BannerID: Hashable, Sendable {
    private enum Payload: Hashable, Sendable {
        case partial(code: UInt32, counters: [UInt64], paths: [Data], reasons: [String])
        case droppedTiles(Int)
        case rescan(revision: UInt64, changed: Bool)
        case limitedScan
    }
    private let payload: Payload

    public static func partial(code: UInt32, counters: [UInt64], paths: [Data], reasons: [String]) -> Self {
        Self(payload: .partial(code: code, counters: counters, paths: paths, reasons: reasons))
    }
    public static func droppedTiles(_ count: Int) -> Self { Self(payload: .droppedTiles(count)) }
    public static func rescan(revision: UInt64, changed: Bool) -> Self {
        Self(payload: .rescan(revision: revision, changed: changed))
    }
    public static let limitedScan = Self(payload: .limitedScan)

    var isDroppedTiles: Bool {
        if case .droppedTiles = payload { return true }
        return false
    }
}

public struct SessionWarning: Identifiable {
    public let id: BannerID
    public let text: String
    public let explainsPartial: Bool
}

public struct PartialResultLine: Equatable {
    public let text: String
    public var location: Data? = nil
    public var count: Int? = nil
}

/// Unscanned locations have no reliable size. Rank recorded occurrences by
/// count, retaining raw identity until the final display boundary.
public func PartialResultExplanation(stats: TessScanStats, report: ScanReport, detail: DetailLevel,
                                     locale: Locale = .current) -> [PartialResultLine] {
    let reason: String
    switch stats.incomplete {
    case UInt32(TESS_INCOMPLETE_NONE):
        reason = String(localized: "partial.finished", defaultValue: "The scan finished, but some locations couldn't be included.",
            bundle: L10n.bundle, comment: "Explanation when the scan completed with omissions.")
    case UInt32(TESS_INCOMPLETE_CANCELLED):
        reason = String(localized: "partial.cancelled", defaultValue: "The scan was cancelled before it finished.",
            bundle: L10n.bundle, comment: "Plain explanation of a cancelled scan.")
    case UInt32(TESS_INCOMPLETE_NODE_BUDGET):
        reason = String(localized: "partial.nodeLimit", defaultValue: "The scan stopped because it reached the maximum number of items it can hold.",
            bundle: L10n.bundle, comment: "Plain explanation of the scan item limit.")
    case UInt32(TESS_INCOMPLETE_OUT_OF_MEMORY):
        reason = String(localized: "partial.memory", defaultValue: "The scan stopped because there wasn't enough memory to continue.",
            bundle: L10n.bundle, comment: "Plain explanation of memory exhaustion.")
    case UInt32(TESS_INCOMPLETE_STALLED):
        reason = String(localized: "partial.stalled", defaultValue: "The scan stopped because a folder wasn't responding.",
            bundle: L10n.bundle, comment: "Plain explanation of a stalled scan.")
    case UInt32(TESS_INCOMPLETE_FD_EXHAUSTED):
        reason = String(localized: "partial.openFiles", defaultValue: "The scan stopped because too many files or folders were open at once.",
            bundle: L10n.bundle, comment: "Plain explanation of file descriptor exhaustion.")
    case UInt32(TESS_INCOMPLETE_MALFORMED_BATCH):
        reason = String(localized: "partial.filesystem", defaultValue: "The scan stopped because the filesystem returned information it couldn't read.",
            bundle: L10n.bundle, comment: "Plain explanation of malformed filesystem data.")
    case UInt32(TESS_INCOMPLETE_VOLUME_LOST):
        reason = String(localized: "partial.diskUnavailable", defaultValue: "The scan stopped because the disk became unavailable.",
            bundle: L10n.bundle, comment: "Plain explanation of a lost scan volume.")
    default:
        reason = String(localized: "partial.unknown", defaultValue: "The scan stopped before it finished.",
            bundle: L10n.bundle, comment: "Plain explanation for a future scan stop code.")
    }
    var lines = [PartialResultLine(text: reason)]
    if let raw = report.stalledPath, stats.incomplete == UInt32(TESS_INCOMPLETE_STALLED) {
        lines.append(PartialResultLine(text: DisplayPath.text(raw)))
    }
    if detail == .detailed {
        lines.append(PartialResultLine(text: String(localized: "partial.stopCode", defaultValue: "Stop code: \(stats.incomplete)",
            bundle: L10n.bundle, locale: locale, comment: "Numeric scan stop code in Detailed mode.")))
    }
    var grouped: [Data: [ScanReport.Location]] = [:]
    for location in report.unreadable + report.skipped { grouped[location.rawPath, default: []].append(location) }
    let ranked = grouped.sorted {
        $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key.lexicographicallyPrecedes($1.key)
    }
    for (raw, locations) in ranked.prefix(10) {
        let path = DisplayPath.text(raw)
        var text = path
        if detail == .detailed {
            let count = locations.count
            let reasons = Array(Set(locations.compactMap(\.reason))).sorted().map(singleLine).joined(separator: "; ")
            text = String(localized: "partial.locationCount", defaultValue: "\(path) — \(count) recorded omissions",
                bundle: L10n.bundle, locale: L10n.pluralLocale(locale), comment: "Location with the count of recorded skipped or unreadable occurrences.")
            if !reasons.isEmpty { text += " — " + reasons }
        }
        lines.append(PartialResultLine(text: text, location: raw, count: locations.count))
    }
    if !ranked.isEmpty {
        lines.append(PartialResultLine(text: String(localized: "partial.ranking", defaultValue: "Up to ten locations are shown, with the most recorded omissions first. Sizes of unscanned items are unknown.",
            bundle: L10n.bundle, comment: "Explains location ranking and unavailable unscanned sizes.")))
    } else {
        lines.append(PartialResultLine(text: String(localized: "partial.noLocations", defaultValue: "No skipped or unreadable locations were recorded. Items beyond where the scan stopped may also be missing.",
            bundle: L10n.bundle, comment: "Explains why a partial scan may have no recorded skipped paths.")))
    }
    return lines
}
