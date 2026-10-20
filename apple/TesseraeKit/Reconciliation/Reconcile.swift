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

public struct ScanFacts: Equatable, Sendable {
    public let allocatedSum: UInt64
    public let unreadableLocations: Int
    public let incompleteReason: String?
    public let limited: Bool
    public let datalessItems: UInt64?
    public let datalessLogicalBytes: UInt64?
    public let noMaterializeFailed: Bool
    public let access: AccessState

    public init(allocatedSum: UInt64, unreadableLocations: Int, incompleteReason: String?,
                limited: Bool, datalessItems: UInt64?, access: AccessState,
                datalessLogicalBytes: UInt64? = nil, noMaterializeFailed: Bool = false) {
        self.allocatedSum = allocatedSum
        self.unreadableLocations = unreadableLocations
        self.incompleteReason = incompleteReason
        self.limited = limited
        self.datalessItems = datalessItems
        self.datalessLogicalBytes = datalessLogicalBytes
        self.noMaterializeFailed = noMaterializeFailed
        self.access = access
    }
}

public enum Caveat: Equatable, Sendable {
    case cloneDoubleCounting, noFullDiskAccess, accessUnknown, limitedScan, partialScan(String),
         containerDataUnavailable, snapshotsUnavailable, datalessNotCounted(UInt64)
}

public struct Reconciliation: Equatable, Sendable {
    public let capacity, scanned, free: UInt64
    public let systemVolume: UInt64?
    public let snapshots: SnapshotFacts
    public let residual: Int64?
    public let purgeableEstimate: UInt64?
    public let caveats: [Caveat]
}

public func reconcile(_ v: VolumeFacts, systemVolumeUsed: UInt64?, _ s: SnapshotFacts,
                      _ scan: ScanFacts) -> Reconciliation {
    let residual = scan.incompleteReason == nil
        ? signedResidual(capacity: v.capacity, free: v.free, scanned: scan.allocatedSum,
                         system: systemVolumeUsed ?? 0) : nil
    var caveats: [Caveat] = []
    if let residual, residual < 0 { caveats.append(.cloneDoubleCounting) }
    switch scan.access {
    case .granted: break
    case .denied: caveats.append(.noFullDiskAccess)
    case .unknown: caveats.append(.accessUnknown)
    }
    if scan.limited { caveats.append(.limitedScan) }
    if let reason = scan.incompleteReason { caveats.append(.partialScan(reason)) }
    if systemVolumeUsed == nil { caveats.append(.containerDataUnavailable) }
    if s.count == nil { caveats.append(.snapshotsUnavailable) }
    if let count = scan.datalessItems, count > 0 { caveats.append(.datalessNotCounted(count)) }
    return Reconciliation(capacity: v.capacity, scanned: scan.allocatedSum, free: v.free,
                          systemVolume: systemVolumeUsed, snapshots: s, residual: residual,
                          purgeableEstimate: v.purgeable, caveats: caveats)
}

private func signedResidual(capacity: UInt64, free: UInt64, scanned: UInt64,
                            system: UInt64) -> Int64? {
    // Cancel against capacity first: the sum of the deductions may exceed UInt64
    // even when the final signed difference fits. Only the deficit accumulates.
    var remaining = capacity
    var deficit: UInt64 = 0
    for deduction in [free, scanned, system] {
        if deduction <= remaining {
            remaining -= deduction
        } else {
            let (next, overflow) = deficit.addingReportingOverflow(deduction - remaining)
            guard !overflow else { return nil }
            deficit = next
            remaining = 0
        }
    }
    if deficit == 0 { return Int64(exactly: remaining) }
    if deficit == UInt64(Int64.max) + 1 { return Int64.min }
    guard let magnitude = Int64(exactly: deficit) else { return nil }
    return -magnitude
}
