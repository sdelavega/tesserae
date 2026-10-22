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
    public let title = String(
        localized: "reconciliationViewModel.space.breakdown",
        defaultValue: "Space breakdown",
        bundle: L10n.bundle,
        comment: "ReconciliationViewModel: Space breakdown."
    )
    public let grantAccessTitle = String(
        localized: "reconciliationViewModel.grant.access",
        defaultValue: "Grant Access",
        bundle: L10n.bundle,
        comment: "ReconciliationViewModel: Grant Access."
    )
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
        let details = Set(rows.filter { $0.title == String(
            localized: "reconciliationViewModel.residual",
            defaultValue: "Residual",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Residual."
        ) }.compactMap(\.detail).map(normalized))
        return caveats.filter { !details.contains(normalized($0)) }
    }
    public static let downloadProtectionWarning = String(
        localized: "reconciliationViewModel.cloud.only.download.protection.could.not.be.enabled",
        defaultValue: "Cloud-only download protection could not be enabled for this scan.",
        bundle: L10n.bundle,
        comment: "ReconciliationViewModel: Cloud-only download protection could not be enabled for this scan."
    )

    public init(wholeVolume: Bool, reconciliation r: Reconciliation?, scan: ScanFacts,
                locale: Locale = .current, timeZone: TimeZone = .current, systemVolumeApplicable: Bool = true) {
        func size(_ bytes: UInt64?) -> String { bytes.map { displaySize($0, locale: locale) } ?? "—" }
        let unavailableReason = wholeVolume && r == nil ? String(
            localized: "reconciliationViewModel.volume.information.unavailable",
            defaultValue: "Volume information unavailable",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Volume information unavailable."
        ) : nil
        let partial = r?.caveats.contains { if case .partialScan = $0 { return true }; return false } ?? false
        let overflowReason = r != nil && r?.residual == nil && !partial ? String(
            localized: "reconciliationViewModel.too.large.to.compute",
            defaultValue: "Too large to compute",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Too large to compute."
        ) : nil
        caveats = (r?.caveats ?? Self.scanCaveats(scan)).map {
            switch $0 {
            case .cloneDoubleCounting: return String(
                localized: "reconciliationViewModel.the.scan.is.double.counting.shared.blocks",
                defaultValue: "The scan is double-counting shared blocks.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: The scan is double-counting shared blocks."
            )
            case .noFullDiskAccess: return String(
                localized: "reconciliationViewModel.full.disk.access.is.missing",
                defaultValue: "Full Disk Access is missing.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Full Disk Access is missing."
            )
            case .accessUnknown: return String(
                localized: "reconciliationViewModel.full.disk.access.is.unknown",
                defaultValue: "Full Disk Access is unknown.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Full Disk Access is unknown."
            )
            case .limitedScan: return String(
                localized: "reconciliationViewModel.limited.scan",
                defaultValue: "Limited scan.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Limited scan."
            )
            case .partialScan(let reason): return reason
            case .containerDataUnavailable: return String(
                localized: "reconciliationViewModel.system.volume.information.unavailable",
                defaultValue: "System volume information unavailable.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: System volume information unavailable."
            )
            case .snapshotsUnavailable: return String(
                localized: "reconciliationViewModel.local.snapshot.information.unavailable",
                defaultValue: "Local snapshot information unavailable.",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Local snapshot information unavailable."
            )
            case .datalessNotCounted(let count): return String(
                localized: "reconciliationViewModel.cloud.only.items.not.stored.on.this.mac",
                defaultValue: "\(count) cloud-only items (\(size(scan.datalessLogicalBytes))) — not stored on this Mac",
                bundle: L10n.bundle,
                locale: L10n.pluralLocale(locale),
                comment: "ReconciliationViewModel: {count} cloud-only items ({size(scan.datalessLogicalBytes)}) — not stored on this Mac."
            )
            }
        } + [unavailableReason, overflowReason].compactMap { $0 } + (scan.noMaterializeFailed ? [Self.downloadProtectionWarning] : [])
        scopeMessage = wholeVolume ? nil : String(
            localized: "reconciliationViewModel.space.breakdown.is.available.when.you.scan.a",
            defaultValue: "Space breakdown is available when you scan a whole volume.",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Space breakdown is available when you scan a whole volume."
        )
        guard wholeVolume else {
            rows = []; purgeable = nil; warning = nil
            showGrantAccess = false; return
        }
        func fraction(_ bytes: UInt64?) -> Double? {
            guard let bytes, let capacity = r?.capacity, capacity > 0 else { return nil }
            return Double(bytes) / Double(capacity)
        }
        let reason: String? = r == nil ? String(
            localized: "reconciliationViewModel.volume.information.unavailable",
            defaultValue: "Volume information unavailable",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Volume information unavailable."
        ) : r?.caveats.compactMap {
            if case .partialScan(let reason) = $0 { return reason }; return nil
        }.first
        let snapshotAnnotation: String?
        if let count = r?.snapshots.count {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "d MMM"
            let date = r?.snapshots.oldest.map { formatter.string(from: $0) } ?? "—"
            snapshotAnnotation = count == 0 ? String(
                localized: "reconciliationViewModel.0.local.snapshots",
                defaultValue: "0 local snapshots",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: 0 local snapshots."
            )
                : String(
                    localized: "reconciliationViewModel.local.snapshots.oldest.size.not.reported.by.macos",
                    defaultValue: "\(count) local snapshots, oldest \(date) — size not reported by macOS",
                    bundle: L10n.bundle,
                    locale: L10n.pluralLocale(locale),
                    comment: "ReconciliationViewModel: {count} local snapshots, oldest {date} — size not reported by macOS."
                )
        } else { snapshotAnnotation = String(
            localized: "reconciliationViewModel.local.snapshots",
            defaultValue: "Local snapshots: —",
            bundle: L10n.bundle,
            comment: "ReconciliationViewModel: Local snapshots: —."
        ) }
        let residual = r?.residual
        rows = [
            Row(title: String(
                localized: "reconciliationViewModel.capacity",
                defaultValue: "Capacity",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Capacity."
            ), value: size(r?.capacity), detail: nil, fraction: nil, negative: false),
            Row(title: String(
                localized: "reconciliationViewModel.scanned",
                defaultValue: "Scanned",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Scanned."
            ), value: size(scan.allocatedSum), detail: nil,
                fraction: fraction(scan.allocatedSum), negative: false),
            Row(title: String(
                localized: "reconciliationViewModel.system.volume",
                defaultValue: "System volume",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: System volume."
            ), value: systemVolumeApplicable ? size(r?.systemVolume) : String(
                localized: "reconciliationViewModel.not.applicable",
                defaultValue: "Not applicable",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Not applicable."
            ),
                detail: systemVolumeApplicable ? String(
                    localized: "reconciliationViewModel.read.only.not.scanned.by.default",
                    defaultValue: "read-only, not scanned by default",
                    bundle: L10n.bundle,
                    comment: "ReconciliationViewModel: read-only, not scanned by default."
                ) : nil,
                fraction: fraction(r?.systemVolume), negative: false),
            Row(title: String(
                localized: "reconciliationViewModel.residual",
                defaultValue: "Residual",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Residual."
            ), value: residual.map { ($0 == 0 ? "" : ($0 < 0 ? "−" : "+")) + size($0.magnitude) } ?? "—",
                detail: residual.map { $0 == 0 ? String(
                    localized: "reconciliationViewModel.nothing.unaccounted.for",
                    defaultValue: "nothing unaccounted for",
                    bundle: L10n.bundle,
                    comment: "ReconciliationViewModel: nothing unaccounted for."
                ) : ($0 < 0 ? String(
                    localized: "reconciliationViewModel.the.scan.is.double.counting.shared.blocks.v2",
                    defaultValue: "the scan is double-counting shared blocks",
                    bundle: L10n.bundle,
                    comment: "ReconciliationViewModel: the scan is double-counting shared blocks."
                ) : String(
                    localized: "reconciliationViewModel.space.the.scan.can.t.see",
                    defaultValue: "space the scan can't see",
                    bundle: L10n.bundle,
                    comment: "ReconciliationViewModel: space the scan can't see."
                )) }
                    ?? reason ?? String(
                        localized: "reconciliationViewModel.too.large.to.compute",
                        defaultValue: "Too large to compute",
                        bundle: L10n.bundle,
                        comment: "ReconciliationViewModel: Too large to compute."
                    ),
                fraction: fraction(residual?.magnitude), negative: (residual ?? 0) < 0, annotation: snapshotAnnotation),
            Row(title: String(
                localized: "reconciliationViewModel.free",
                defaultValue: "Free",
                bundle: L10n.bundle,
                comment: "ReconciliationViewModel: Free."
            ), value: size(r?.free), detail: nil, fraction: fraction(r?.free), negative: false)]
        purgeable = r?.purgeableEstimate.map { String(
            localized: "reconciliationViewModel.about.purgeable.derived",
            defaultValue: "about \(size($0)) purgeable (derived)",
            bundle: L10n.bundle,
            locale: locale,
            comment: "ReconciliationViewModel: about {size($0)} purgeable (derived)."
        ) }
        showGrantAccess = scan.access != .granted
        warning = scan.unreadableLocations > 0
            ? (showGrantAccess ? String(
                localized: "reconciliationViewModel.locations.unreadable.grant.full.disk.access.to.include",
                defaultValue: "\(scan.unreadableLocations) locations unreadable — grant Full Disk Access to include them",
                bundle: L10n.bundle,
                locale: L10n.pluralLocale(locale),
                comment: "ReconciliationViewModel: {scan.unreadableLocations} locations unreadable — grant Full Disk Access to include them."
            ) : String(
                localized: "reconciliationViewModel.locations.unreadable",
                defaultValue: "\(scan.unreadableLocations) locations unreadable",
                bundle: L10n.bundle,
                locale: L10n.pluralLocale(locale),
                comment: "ReconciliationViewModel: {scan.unreadableLocations} locations unreadable."
            )) : nil

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
