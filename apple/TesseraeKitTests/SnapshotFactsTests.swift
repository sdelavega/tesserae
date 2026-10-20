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

final class SnapshotFactsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Volumes/Test volume;literal")

    func test_parses_names_dates_and_uses_fixed_command() throws {
        let root = root
        let output = """
            Snapshots for volume group containing disk \(root.path):
            com.apple.TimeMachine.2026-10-19-120006.local
            com.apple.TimeMachine.2026-10-18-085944.local

            """
        let called = expectation(description: "tmutil runner invoked")
        let facts = readSnapshotFacts(volumeRoot: root, runner: CommandRunner { executable, args, timeout in
            called.fulfill()
            XCTAssertEqual(executable.path, "/usr/bin/tmutil")
            XCTAssertEqual(args, ["listlocalsnapshots", root.path])
            XCTAssertEqual(timeout, 5)
            return .exited(status: 0, stdout: Data(output.utf8))
        })
        wait(for: [called], timeout: 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let expected = try XCTUnwrap(formatter.date(from: "2026-10-18-085944"))
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts.oldest, expected)
        XCTAssertNil(facts.aggregateBytes)
    }

    func test_listing_failure_yields_nil_not_zero() {
        let header = "Snapshots for disk \(root.path):\n"
        let outcomes: [CommandOutcome] = [
            .exited(status: 1, stdout: Data(header.utf8)), .timedOut, .launchFailed,
            .exited(status: 0, stdout: Data("garbage".utf8)),
            .exited(status: 0, stdout: Data()),
            .exited(status: 0, stdout: Data([0xff])),
            .exited(status: 0, stdout: Data((header + "garbage\n").utf8)),
            .exited(status: 0, stdout: Data((header + "com.apple.TimeMachine.2026-02-30-120000.local\n").utf8)),
            .exited(status: 0, stdout: Data("Snapshots for disk /wrong:\n".utf8))
        ]
        XCTAssertEqual(outcomes.count, 9)
        for outcome in outcomes {
            let called = expectation(description: "failure outcome consumed")
            let facts = readSnapshotFacts(volumeRoot: root, runner: CommandRunner { _, _, _ in
                called.fulfill()
                return outcome
            })
            wait(for: [called], timeout: 1)
            XCTAssertNil(facts.count, "\(outcome)")
            XCTAssertNil(facts.oldest)
            XCTAssertNil(facts.aggregateBytes)
        }
    }

    func test_header_only_is_known_zero() {
        let output = "Snapshots for disk \(root.path):\n"
        XCTAssertFalse(output.isEmpty)
        let called = expectation(description: "listing fixture consumed")
        let facts = readSnapshotFacts(volumeRoot: root, runner: CommandRunner { _, _, _ in
            called.fulfill()
            return .exited(status: 0, stdout: Data(output.utf8))
        })
        wait(for: [called], timeout: 1)
        XCTAssertEqual(facts.count, 0)
        XCTAssertNil(facts.oldest)
        XCTAssertNil(facts.aggregateBytes)
    }

    func test_undated_update_snapshots_have_count_but_unknown_oldest_and_size() {
        let output = """
            Snapshots for volume group containing disk \(root.path):
            com.apple.TimeMachine.2026-10-18-085944.local
            com.apple.os.update-ABC012
            com.apple.os.update-MSUPrepareUpdate
            """
        let called = expectation(description: "listing fixture consumed")
        let facts = readSnapshotFacts(volumeRoot: root, runner: CommandRunner { _, _, _ in
            called.fulfill()
            return .exited(status: 0, stdout: Data(output.utf8))
        })
        wait(for: [called], timeout: 1)
        XCTAssertEqual(facts.count, 3)
        XCTAssertNil(facts.oldest)
        XCTAssertNil(facts.aggregateBytes)
    }
}
