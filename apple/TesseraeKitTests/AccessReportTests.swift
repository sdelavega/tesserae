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
import XCTest
@testable import TesseraeKit

final class AccessReportTests: XCTestCase {
    func test_json_preserves_verdict_evidence_every_errno_and_optional_scan() throws {
        let candidates = [AccessCandidateResult(path: "/fixture/Mail", errno: EPERM),
                          AccessCandidateResult(path: "/fixture/TCC.db", errno: ENOENT)]
        let evidence = "/fixture/Mail: errno 1 (EPERM)"
        let metrics = AccessReport.Scan(root: "/fixture", entries: 12, dirs: 3, files: 9,
            errors: 2, unreadableCount: 1, wallClockSeconds: 0.25, incomplete: 0)
        for (state, verdict, detail): (AccessState, String, String?) in [
            (.granted, "granted", nil), (.denied(evidence: evidence), "denied", evidence),
            (.unknown, "unknown", "/fixture/Mail: errno 13")] {
            let result = AccessProbeResult(state: state, evidence: detail, candidates: candidates)
            let report = AccessReport(probe: result, scan: metrics)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
            XCTAssertEqual(json["verdict"] as? String, verdict)
            XCTAssertEqual(json["evidence"] as? String, detail)
            let rows = try XCTUnwrap(json["candidates"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 2, "precondition: both candidates encoded")
            XCTAssertEqual(rows.map { $0["path"] as? String }, candidates.map(\.path))
            XCTAssertEqual(rows.map { $0["errno"] as? Int32 }, [EPERM, ENOENT])
            let scan = try XCTUnwrap(json["scan"] as? [String: Any])
            XCTAssertEqual(scan["root"] as? String, "/fixture")
            for (key, value) in [("entries", 12), ("dirs", 3), ("files", 9), ("errors", 2), ("unreadableCount", 1), ("incomplete", 0)] {
                XCTAssertEqual(scan[key] as? Int, value)
            }
            XCTAssertEqual(scan["wallClockSeconds"] as? Double, 0.25)
            let noScan = AccessReport(probe: result, scanError: EINVAL)
            let minimal = try XCTUnwrap(JSONSerialization.jsonObject(with: noScan.encoded()) as? [String: Any])
            XCTAssertNil(minimal["scan"])
            XCTAssertEqual(minimal["scanError"] as? Int32, EINVAL)
        }
    }

    func test_report_configuration_is_inert_without_out_and_validates_paths() throws {
        XCTAssertNil(try AccessReportConfiguration(environment: [:]))
        XCTAssertNil(try AccessReportConfiguration(environment: ["TESSERAE_ACCESS_REPORT_SCAN": "invalid"]))
        for output in ["", "relative.json"] {
            XCTAssertThrowsError(try AccessReportConfiguration(environment: ["TESSERAE_ACCESS_REPORT_OUT": output]))
        }
        XCTAssertThrowsError(try AccessReportConfiguration(environment: [
            "TESSERAE_ACCESS_REPORT_OUT": "/fixture/out.json", "TESSERAE_ACCESS_REPORT_SCAN": "relative"]))
        let probeOnly = try XCTUnwrap(AccessReportConfiguration(environment: ["TESSERAE_ACCESS_REPORT_OUT": "/fixture/out.json"]))
        XCTAssertEqual(probeOnly.output.path, "/fixture/out.json")
        XCTAssertNil(probeOnly.scanRoot)
        let scan = try XCTUnwrap(AccessReportConfiguration(environment: [
            "TESSERAE_ACCESS_REPORT_OUT": "/fixture/out.json", "TESSERAE_ACCESS_REPORT_SCAN": "/fixture/root"]))
        XCTAssertEqual(scan.scanRoot?.path, "/fixture/root")
    }

    func test_report_runner_refuses_existing_output_without_probing_or_overwriting() async throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("report-\(UUID().uuidString).json")
        let sentinel = Data("existing report".utf8)
        try sentinel.write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(try Data(contentsOf: output), sentinel, "precondition")
        let configuration = try XCTUnwrap(AccessReportConfiguration(environment: ["TESSERAE_ACCESS_REPORT_OUT": output.path]))
        let probe = AccessProbe(candidates: [output], open: { _ in
            XCTFail("an existing output must be refused before probing")
            return 0
        })
        do {
            _ = try await AccessReportRunner.run(configuration, probe: probe)
            XCTFail("existing output accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func test_hook_output_is_private_and_refuses_symlinks_and_paths_outside_temp() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output")
        let data = Data("private".utf8)
        try data.withUnsafeBytes { try TestHookOutput(output).write($0) }
        XCTAssertEqual(try Data(contentsOf: output), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try TestHookOutput(link))
        let directoryLink = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        XCTAssertThrowsError(try TestHookOutput(directoryLink.appendingPathComponent("escaped")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
        let outside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("refused-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "precondition")
        XCTAssertThrowsError(try TestHookOutput(outside))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    func test_report_runner_saves_probe_then_normal_engine_scan() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("one"))
        let output = root.appendingPathComponent("../report-\(UUID().uuidString).json").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = AccessProbe(candidates: [root], open: { _ in
            XCTAssertFalse(Thread.isMainThread)
            return 0
        })
        let configuration = try XCTUnwrap(AccessReportConfiguration(environment: [
            "TESSERAE_ACCESS_REPORT_OUT": output.path, "TESSERAE_ACCESS_REPORT_SCAN": root.path]))
        let status = try await AccessReportRunner.run(configuration, probe: probe)
        XCTAssertEqual(status, 0)
        let report = try JSONDecoder().decode(AccessReport.self, from: Data(contentsOf: output))
        XCTAssertEqual(report.verdict, "granted")
        XCTAssertEqual(report.candidates, [AccessCandidateResult(path: root.path, errno: 0)])
        let scan = try XCTUnwrap(report.scan)
        XCTAssertEqual(scan.root, root.path)
        XCTAssertEqual(scan.entries, 2)
        XCTAssertEqual(scan.dirs, 1)
        XCTAssertEqual(scan.files, 1)
        XCTAssertEqual(scan.errors, 0)
        XCTAssertEqual(scan.unreadableCount, 0)
        XCTAssertEqual(scan.incomplete, 0)
        XCTAssertGreaterThan(scan.wallClockSeconds, 0)
        XCTAssertNil(report.scanError)
        let onlyProbe = try XCTUnwrap(AccessReportConfiguration(environment: ["TESSERAE_ACCESS_REPORT_OUT": output.path]))
        try FileManager.default.removeItem(at: output)
        let probeStatus = try await AccessReportRunner.run(onlyProbe, probe: probe)
        XCTAssertEqual(probeStatus, 0)
        let minimal = try JSONDecoder().decode(AccessReport.self, from: Data(contentsOf: output))
        XCTAssertNil(minimal.scan)
        XCTAssertEqual(minimal.verdict, "granted")
    }
}
