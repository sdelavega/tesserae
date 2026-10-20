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
import XCTest

@testable import TesseraeKit

final class ReconcileTests: XCTestCase {
    private let snapshots = SnapshotFacts(count: 2, oldest: Date(timeIntervalSince1970: 1234), aggregateBytes: 99)

    private func volume(_ capacity: UInt64 = 100, free: UInt64 = 20, purgeable: UInt64? = 7) -> VolumeFacts {
        VolumeFacts(capacity: capacity, used: 999, free: free, available: 888, purgeable: purgeable)
    }

    private func scan(_ allocated: UInt64 = 40, reason: String? = nil, limited: Bool = false,
                      dataless: UInt64? = nil, access: AccessState = .granted,
                      unreadable: Int = 0) -> ScanFacts {
        ScanFacts(allocatedSum: allocated, unreadableLocations: unreadable, incompleteReason: reason,
                  limited: limited, datalessItems: dataless, access: access)
    }

    // Negative first, as required by spec §12. Every row compares the entire caveat array.
    func test_negative_residual_is_signed_and_explained() {
        for allocated: UInt64 in [81, 100] {
            let result = reconcile(volume(), systemVolumeUsed: 10, snapshots, scan(allocated))
            XCTAssertGreaterThan(allocated + 30, 100)
            XCTAssertEqual(result.residual, 70 - Int64(allocated))
            XCTAssertEqual(result.caveats, [.cloneDoubleCounting])
        }
    }

    func test_positive_residual_with_snapshots_annotates_count_and_oldest() {
        XCTAssertNotNil(snapshots.oldest)
        let result = reconcile(volume(), systemVolumeUsed: 10, snapshots, scan())
        XCTAssertEqual(result.residual, 30)
        XCTAssertEqual(result.snapshots, snapshots)
        XCTAssertEqual(result.capacity, 100)
        XCTAssertEqual(result.scanned, 40)
        XCTAssertEqual(result.free, 20)
        XCTAssertEqual(result.systemVolume, 10)
        XCTAssertEqual(result.caveats, [])
    }

    func test_snapshots_unavailable_renders_nil_not_zero() {
        for count: Int? in [nil, 0] {
            let facts = SnapshotFacts(count: count, oldest: nil, aggregateBytes: nil)
            let result = reconcile(volume(), systemVolumeUsed: 10, facts, scan())
            XCTAssertEqual(result.snapshots, facts)
            XCTAssertEqual(result.caveats, count == nil ? [.snapshotsUnavailable] : [])
            XCTAssertEqual(result.residual, 30)
        }
    }

    func test_partial_scan_suppresses_residual() {
        for reason in ["cancelled", "node limit", ""] {
            let result = reconcile(volume(), systemVolumeUsed: 10, snapshots, scan(100, reason: reason))
            XCTAssertNil(result.residual)
            XCTAssertEqual(result.caveats, [.partialScan(reason)])
        }
    }

    func test_inconsistent_capacity_used_free_is_reported_not_clamped() {
        for (capacity, free, allocated, expected): (UInt64, UInt64, UInt64, Int64) in [
            (100, 90, 30, -20), (10, 20, 0, -10), (0, 0, 0, 0)
        ] {
            let result = reconcile(volume(capacity, free: free), systemVolumeUsed: 0,
                                   snapshots, scan(allocated))
            XCTAssertEqual(result.residual, expected)
            XCTAssertEqual(result.caveats, expected < 0 ? [.cloneDoubleCounting] : [])
        }
    }

    func test_no_fda_and_unknown_access_add_their_caveats() {
        for (access, caveats): (AccessState, [Caveat]) in [
            (.denied(evidence: "EPERM"), [.noFullDiskAccess]), (.unknown, [.accessUnknown]), (.granted, [])
        ] {
            let result = reconcile(volume(), systemVolumeUsed: 10, snapshots, scan(access: access))
            XCTAssertEqual(result.caveats, caveats)
            XCTAssertEqual(result.residual, 30)
        }
    }

    func test_limited_scan_adds_its_caveat() {
        for limited in [true, false] {
            let result = reconcile(volume(), systemVolumeUsed: 10, snapshots, scan(limited: limited))
            XCTAssertEqual(result.caveats, limited ? [.limitedScan] : [])
            XCTAssertEqual(result.residual, 30)
        }
    }

    func test_summands_total_capacity_exactly() throws {
        var negatives = 0
        var positives = 0
        for seed: UInt64 in 0..<500 {
            var rng = SplitMix64(seed: seed)
            let capacity = rng.next() % 1_000_000
            let free = rng.next() % 1_000_000
            let scanned = rng.next() % 1_000_000
            let system = rng.next() % 1_000_000
            let result = reconcile(volume(capacity, free: free), systemVolumeUsed: system,
                                   snapshots, scan(scanned))
            let residual = try XCTUnwrap(result.residual, "seed \(seed)")
            if residual < 0 { negatives += 1 }
            if residual > 0 { positives += 1 }
            XCTAssertEqual(Int64(scanned) + Int64(system) + residual + Int64(free), Int64(capacity),
                           "seed \(seed)")
        }
        XCTAssertGreaterThan(negatives, 0)
        XCTAssertGreaterThan(positives, 0)
    }

    func test_overflow_safe_at_uint64_extremes() {
        let edge = UInt64(Int64.max) + 1
        let rows: [(UInt64, UInt64, UInt64, UInt64, Int64?)] = [
            (.max, .max, 0, 0, 0), (.max, 0, .max, 0, 0), (.max, 0, 0, .max, 0),
            (UInt64(Int64.max), 0, 0, 0, .max), (edge, 0, 0, 0, nil), (.max, 0, 0, 0, nil),
            (0, edge, 0, 0, .min), (0, edge + 1, 0, 0, nil),
            (.max, .max, edge, 0, .min), (.max, .max, .max, .max, nil),
            (.max, 1, .max, 0, -1), (.max, .max - 1, 0, edge, -.max),
            (0, .max, .max, .max, nil)
        ]
        XCTAssertGreaterThan(rows.count, 10)
        for (capacity, free, allocated, system, expected) in rows {
            let result = reconcile(volume(capacity, free: free), systemVolumeUsed: system,
                                   snapshots, scan(allocated))
            XCTAssertEqual(result.residual, expected, "\(capacity), \(free), \(allocated), \(system)")
            XCTAssertEqual(result.caveats, (expected ?? 0) < 0 ? [.cloneDoubleCounting] : [])
        }
    }

    func test_caveat_order_and_dataless_unknown_zero_and_positive() {
        let unknown = SnapshotFacts(count: nil, oldest: nil, aggregateBytes: nil)
        for dataless: UInt64? in [nil, 0, 3] {
            let result = reconcile(volume(), systemVolumeUsed: nil, unknown,
                                   scan(100, limited: true, dataless: dataless, access: .unknown))
            var expected: [Caveat] = [.cloneDoubleCounting, .accessUnknown, .limitedScan,
                                     .containerDataUnavailable, .snapshotsUnavailable]
            if let dataless, dataless > 0 { expected.append(.datalessNotCounted(dataless)) }
            XCTAssertNil(result.systemVolume)
            XCTAssertEqual(result.residual, -20)
            XCTAssertEqual(result.caveats, expected)
        }
        XCTAssertEqual(reconcile(volume(), systemVolumeUsed: nil, unknown,
            scan(reason: "stalled", limited: true, dataless: 2, access: .denied(evidence: "denied"))).caveats,
            [.noFullDiskAccess, .limitedScan, .partialScan("stalled"), .containerDataUnavailable,
             .snapshotsUnavailable, .datalessNotCounted(2)])
    }

    func test_purgeable_is_unchanged_and_unreadable_does_not_change_arithmetic() {
        for purgeable: UInt64? in [nil, 0, .max] {
            let result = reconcile(volume(purgeable: purgeable), systemVolumeUsed: 10, snapshots,
                                   scan(unreadable: 9))
            XCTAssertEqual(result.purgeableEstimate, purgeable)
            XCTAssertEqual(result.residual, 30)
            XCTAssertEqual(result.caveats, [])
        }
    }
}
