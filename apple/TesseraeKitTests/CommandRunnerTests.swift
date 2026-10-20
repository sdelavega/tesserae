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

final class CommandRunnerTests: XCTestCase {
    func test_system_drains_large_stdout_and_preserves_status() throws {
        let outcome = CommandRunner.system.run(URL(fileURLWithPath: "/usr/bin/perl"),
            ["-e", "print 'x' x 1048576; exit 7"], 5)
        guard case let .exited(status, stdout) = outcome else {
            return XCTFail("Expected completed large-output child, got \(outcome)")
        }
        XCTAssertEqual(status, 7)
        XCTAssertEqual(stdout, Data(repeating: 120, count: 1_048_576))
    }

    func test_grandchild_holding_stdout_bounds_both_exit_and_timeout() throws {
        for timeoutChild in [false, true] {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("build/drain-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("pid")
            XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = CommandRunner.system.run(URL(fileURLWithPath: "/bin/sh"),
                ["-c", "(trap '' TERM HUP; exec sleep 30) & echo $! > \"$1\"; echo hi; " + (timeoutChild ? "wait" : "exit 0"),
                 "drain-test", pidFile.path], timeoutChild ? 0.5 : 5)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertGreaterThan(pid, 1)
            defer { kill(pid, SIGKILL) }
            XCTAssertEqual(kill(pid, 0), 0, "grandchild must still hold stdout when run returns")
            XCTAssertLessThan(elapsed, 3)
            if timeoutChild {
                XCTAssertEqual(outcome, .timedOut)
            } else {
                XCTAssertEqual(outcome, .exited(status: 0, stdout: Data("hi\n".utf8)))
            }
        }
    }

    func test_system_stdin_is_dev_null() {
        let outcome = CommandRunner.system.run(URL(fileURLWithPath: "/usr/bin/perl"),
            ["-e", "my $n = sysread(STDIN, my $s, 1); exit(defined($n) && $n == 0 ? 0 : 9)"], 2)
        XCTAssertEqual(outcome, .exited(status: 0, stdout: Data()))
    }

    func test_system_launch_failure() {
        let path = "/nonexistent-tesserae-command-\(UUID().uuidString)"
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(CommandRunner.system.run(URL(fileURLWithPath: path), [], 1), .launchFailed)
    }

    func test_timeout_kills_and_reaps_child_including_sigterm_resistant_child() throws {
        for ignoreTERM in [false, true] {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/task2-child-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("pid")
            XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
            let program = """
                $SIG{TERM} = \(ignoreTERM ? "'IGNORE'" : "'DEFAULT'");
                open(my $f, '>', $ARGV[0]) or die $!;
                print $f "$$"; close($f); sleep 30;
                """
            let start = ProcessInfo.processInfo.systemUptime
            let outcome = CommandRunner.system.run(URL(fileURLWithPath: "/usr/bin/perl"),
                ["-e", program, pidFile.path], 0.5)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            // The file proves a real child ran, even if a runner incorrectly returns immediately.
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try XCTUnwrap(Int32(pidText))
            XCTAssertGreaterThan(pid, 1)
            defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
            XCTAssertEqual(outcome, .timedOut)
            XCTAssertGreaterThanOrEqual(elapsed, 0.5)
            XCTAssertLessThan(elapsed, 3, "timeout must return promptly")
            errno = 0
            XCTAssertEqual(kill(pid, 0), -1, "child PID must no longer exist")
            XCTAssertEqual(errno, ESRCH)
            var status: Int32 = 0
            errno = 0
            XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "child must already be reaped")
            XCTAssertEqual(errno, ECHILD)
        }
    }
}
