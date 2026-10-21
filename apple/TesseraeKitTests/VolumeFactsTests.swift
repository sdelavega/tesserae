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

import Darwin
import Foundation
import XCTest

@testable import TesseraeKit

final class VolumeFactsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/System/Volumes/Data")

    func test_facts_match_diskutil_within_a_few_megabytes() throws {
        let executable = "/usr/sbin/diskutil"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("diskutil is missing; live volume comparison NOT run")
        }
        let tolerance: UInt64 = 8 * 1024 * 1024
        var differences: [String] = []
        for sample in 1...3 {
            let facts = try readVolumeFacts(at: root)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["info", "-plist", root.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard !process.isRunning else {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                XCTFail("diskutil exceeded its five-second deadline")
                return
            }
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, "diskutil must succeed for a meaningful comparison")
            guard process.terminationStatus == 0 else { return }
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let capacity = try XCTUnwrap(plist["APFSContainerSize"] as? NSNumber).uint64Value
            let used = try XCTUnwrap(
                (plist["CapacityInUse"] ?? plist["VolumeUsedSpace"] ?? plist["APFSVolumeUsage"]) as? NSNumber
            ).uint64Value
            let free = try XCTUnwrap(plist["APFSContainerFree"] as? NSNumber).uint64Value
            XCTAssertGreaterThan(capacity, 0)
            XCTAssertGreaterThan(used, 0)
            XCTAssertGreaterThan(capacity, used)
            let delta = [(facts.capacity, capacity), (facts.used, used), (facts.free, free)].map {
                actual, expected in actual > expected ? actual - expected : expected - actual
            }
            differences.append("sample \(sample): capacity=\(delta[0]), used=\(delta[1]), free=\(delta[2]) bytes")
            if delta.allSatisfy({ $0 <= tolerance }) { return }
        }
        XCTFail("No paired sample within \(tolerance) bytes; " + differences.joined(separator: "; "))
    }

    func test_purgeable_is_nil_when_foundation_does_not_report() throws {
        var reads = 0
        let facts = try readVolumeFacts(at: root, readAttributes: { _, mask in
            reads += 1
            return self.reply(mask == UInt32(ATTR_VOL_SPACEUSED) ? [40] : [100, 60, 50])
        }, importantCapacity: { _ in nil })
        XCTAssertEqual(reads, 2, "precondition: both attribute replies were consumed")
        XCTAssertEqual(facts.available, 50)
        XCTAssertNil(facts.purgeable)
    }

    func test_used_is_read_by_a_separate_call() throws {
        var masks: [UInt32] = []
        let facts = try readVolumeFacts(at: root, readAttributes: { url, mask in
            XCTAssertEqual(url, self.root)
            masks.append(mask)
            return self.reply(mask == UInt32(ATTR_VOL_SPACEUSED) ? [37] : [100, 60, 50])
        }, importantCapacity: { _ in 75 })
        XCTAssertEqual(
            masks,
            [UInt32(ATTR_VOL_SIZE | ATTR_VOL_SPACEFREE | ATTR_VOL_SPACEAVAIL), UInt32(ATTR_VOL_SPACEUSED)])
        XCTAssertEqual(facts, VolumeFacts(capacity: 100, used: 37, free: 60, available: 50, purgeable: 25))
    }

    func test_purgeable_estimate_distinguishes_zero_from_unknown() throws {
        let cases: [(Int64?, UInt64, UInt64?)] = [
            (75, 50, 25), (50, 50, 0), (49, 50, nil), (nil, 50, nil), (-1, 50, nil)
        ]
        XCTAssertEqual(cases.count, 5)
        for (important, available, expected) in cases {
            XCTAssertEqual(purgeableEstimate(important: important, available: available), expected,
                           "important=\(String(describing: important)), available=\(available)")
        }
    }

    private func reply(_ values: [Int64]) -> Data {
        var length = UInt32(4 + values.count * 8)
        var data = withUnsafeBytes(of: &length) { Data($0) }
        for var value in values { data.append(withUnsafeBytes(of: &value) { Data($0) }) }
        return data
    }
}
