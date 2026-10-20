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

public struct ReconciliationViewModel: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let title: String
        public let value: String
        public let detail: String?
        public let fraction: Double?
        public let negative: Bool
        public var annotation: String? = nil
    }
    public let title = "Space breakdown"
    public let grantAccessTitle = "Grant Access"
    public let scopeMessage: String?
    public let rows: [Row]
    public let purgeable: String?
    public let warning: String?
    public let showGrantAccess: Bool
    public let caveats: [String]
    /// The report keeps `caveats`; the breakdown omits the Residual row’s explanation.
    public var breakdownCaveats: [String] {
        Self.breakdownCaveats(rows: rows, caveats: caveats)
    }
    static func breakdownCaveats(rows: [Row], caveats: [String]) -> [String] {
        func normalized(_ text: String) -> String {
            text.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).lowercased()
        }
        let details = Set(rows.filter { $0.title == "Residual" }.compactMap(\.detail).map(normalized))
        return caveats.filter { !details.contains(normalized($0)) }
    }
    public static let downloadProtectionWarning = "Cloud-only download protection could not be enabled for this scan."

    public init(wholeVolume: Bool, reconciliation r: Reconciliation?, scan: ScanFacts,
                locale: Locale = .current, timeZone: TimeZone = .current, systemVolumeApplicable: Bool = true) {
        func size(_ bytes: UInt64?) -> String { bytes.map { displaySize($0, locale: locale) } ?? "—" }
        let unavailableReason = wholeVolume && r == nil ? "Volume information unavailable" : nil
        let partial = r?.caveats.contains { if case .partialScan = $0 { return true }; return false } ?? false
        let overflowReason = r != nil && r?.residual == nil && !partial ? "Too large to compute" : nil
        caveats = (r?.caveats ?? Self.scanCaveats(scan)).map {
            switch $0 {
            case .cloneDoubleCounting: return "The scan is double-counting shared blocks."
            case .noFullDiskAccess: return "Full Disk Access is missing."
            case .accessUnknown: return "Full Disk Access is unknown."
            case .limitedScan: return "Limited scan."
            case .partialScan(let reason): return reason
            case .containerDataUnavailable: return "System volume information unavailable."
            case .snapshotsUnavailable: return "Local snapshot information unavailable."
            case .datalessNotCounted(let count): return "\(count.formatted(.number.locale(locale))) cloud-only items (\(size(scan.datalessLogicalBytes))) — not stored on this Mac"
            }
        } + [unavailableReason, overflowReason].compactMap { $0 } + (scan.noMaterializeFailed ? [Self.downloadProtectionWarning] : [])
        scopeMessage = wholeVolume ? nil : "Space breakdown is available when you scan a whole volume."
        guard wholeVolume else {
            rows = []; purgeable = nil; warning = nil
            showGrantAccess = false; return
        }
        func fraction(_ bytes: UInt64?) -> Double? {
            guard let bytes, let capacity = r?.capacity, capacity > 0 else { return nil }
            return Double(bytes) / Double(capacity)
        }
        let reason: String? = r == nil ? "Volume information unavailable" : r?.caveats.compactMap {
            if case .partialScan(let reason) = $0 { return reason }; return nil
        }.first
        let snapshotAnnotation: String?
        if let count = r?.snapshots.count {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "d MMM"
            let date = r?.snapshots.oldest.map { formatter.string(from: $0) } ?? "—"
            snapshotAnnotation = count == 0 ? "0 local snapshots"
                : "\(count.formatted(.number.locale(locale))) local snapshots, oldest \(date) — size not reported by macOS"
        } else { snapshotAnnotation = "Local snapshots: —" }
        let residual = r?.residual
        rows = [
            Row(title: "Capacity", value: size(r?.capacity), detail: nil, fraction: nil, negative: false),
            Row(title: "Scanned", value: size(scan.allocatedSum), detail: nil,
                fraction: fraction(scan.allocatedSum), negative: false),
            Row(title: "System volume", value: systemVolumeApplicable ? size(r?.systemVolume) : "Not applicable",
                detail: systemVolumeApplicable ? "read-only, not scanned by default" : nil,
                fraction: fraction(r?.systemVolume), negative: false),
            Row(title: "Residual", value: residual.map { ($0 == 0 ? "" : ($0 < 0 ? "−" : "+")) + size($0.magnitude) } ?? "—",
                detail: residual.map { $0 == 0 ? "nothing unaccounted for" : ($0 < 0 ? "the scan is double-counting shared blocks" : "space the scan can't see") }
                    ?? reason ?? "Too large to compute",
                fraction: fraction(residual?.magnitude), negative: (residual ?? 0) < 0, annotation: snapshotAnnotation),
            Row(title: "Free", value: size(r?.free), detail: nil, fraction: fraction(r?.free), negative: false)]
        purgeable = r?.purgeableEstimate.map { "about " + size($0) + " purgeable (derived)" }
        showGrantAccess = scan.access != .granted
        let count = scan.unreadableLocations.formatted(.number.locale(locale))
        warning = scan.unreadableLocations > 0
            ? "\(count) \(scan.unreadableLocations == 1 ? "location" : "locations") unreadable"
                + (showGrantAccess ? " — grant Full Disk Access to include them" : "") : nil

    }

    private static func scanCaveats(_ scan: ScanFacts) -> [Caveat] {
        var result: [Caveat] = []
        switch scan.access {
        case .granted: break
        case .denied: result.append(.noFullDiskAccess)
        case .unknown: result.append(.accessUnknown)
        }
        if scan.limited { result.append(.limitedScan) }
        if let reason = scan.incompleteReason { result.append(.partialScan(reason)) }
        if let count = scan.datalessItems, count > 0 { result.append(.datalessNotCounted(count)) }
        return result
    }

    static func isWholeVolume(root: URL) -> Bool {
        let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume
        return volume?.standardizedFileURL.path == root.standardizedFileURL.path
    }

    static func systemVolumeApplies(root: URL, identity: (URL) -> NSObject? = { url in
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) as? NSObject
    }) -> Bool {
        guard let scanned = identity(root) else { return false }
        return ["/System/Volumes/Data"].contains { path in
            identity(URL(fileURLWithPath: path)).map { scanned.isEqual($0) } ?? false
        }
    }

    static func load(root: URL, scan: ScanFacts) -> Self {
        load(root: root, scan: scan, wholeVolume: isWholeVolume)
    }

    static func load(root: URL, scan: ScanFacts,
                     wholeVolume: (URL) -> Bool,
                     systemApplies: (URL) -> Bool = { systemVolumeApplies(root: $0) },
                     volumeFacts: (URL) throws -> VolumeFacts = readVolumeFacts,
                     systemUsed: () -> UInt64? = readSystemVolumeUsed,
                     snapshots: (URL) -> SnapshotFacts = { readSnapshotFacts(volumeRoot: $0) },
                     locale: Locale = .current) -> Self {
        guard wholeVolume(root) else { return Self(wholeVolume: false, reconciliation: nil, scan: scan) }
        let facts = try? volumeFacts(root)
        let systemApplicable = systemApplies(root)
        let result = facts.map { reconcile($0, systemVolumeUsed: systemApplicable ? systemUsed() : 0,
                                          snapshots(root), scan) }
        return Self(wholeVolume: true, reconciliation: result, scan: scan, locale: locale, systemVolumeApplicable: systemApplicable)
    }
}
