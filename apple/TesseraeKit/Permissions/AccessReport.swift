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

public struct AccessReport: Codable, Sendable {
    public struct Scan: Codable, Sendable {
        public let root: String
        public let entries, dirs, files, errors, unreadableCount: UInt64
        public let wallClockSeconds: Double
        public let incomplete: UInt32
    }
    public let verdict: String
    public let evidence: String?
    public let candidates: [AccessCandidateResult]
    public let scan: Scan?
    public let scanError: Int32?

    init(probe: AccessProbeResult, scan: Scan? = nil, scanError: Int32? = nil) {
        switch probe.state {
        case .granted: verdict = "granted"
        case .denied: verdict = "denied"
        case .unknown: verdict = "unknown"
        }
        evidence = probe.evidence
        candidates = probe.candidates
        self.scan = scan
        self.scanError = scanError
    }

    /// Pure encoding, shared by the app runner and fixture tests.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct AccessReportConfiguration: Sendable {
    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }
    public let output: URL
    public let scanRoot: URL?

    public init?(environment: [String: String]) throws {
        guard let output = environment["TESSERAE_ACCESS_REPORT_OUT"] else { return nil }
        func absolute(_ value: String, key: String) throws -> URL {
            guard value.hasPrefix("/") else { throw Invalid(description: "\(key) must be an absolute path") }
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        self.output = try absolute(output, key: "TESSERAE_ACCESS_REPORT_OUT")
        scanRoot = try environment["TESSERAE_ACCESS_REPORT_SCAN"].map {
            try absolute($0, key: "TESSERAE_ACCESS_REPORT_SCAN")
        }
    }
}

public enum AccessReportRunner {
    public static func run(_ configuration: AccessReportConfiguration,
                           probe: AccessProbe = AccessProbe()) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            let result = probe.inspect()
            // Keep the probe evidence even if the subsequent scan cannot start or finish.
            try AccessReport(probe: result).encoded().write(to: configuration.output, options: .atomic)
            guard let root = configuration.scanRoot else { return Int32(0) }
            let started = ContinuousClock.now
            guard let handle = ScanHandle(root: root, options: .init()) else {
                try AccessReport(probe: result, scanError: EINVAL).encoded()
                    .write(to: configuration.output, options: .atomic)
                return Int32(1)
            }
            // Always consume the handle, including on cancellation and failure.
            while handle.status() == 0 {
                if Task.isCancelled { handle.cancel() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let status = handle.status()
            let snapshot = handle.finish()
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let metrics = snapshot.map { snapshot in
                let stats = snapshot.stats
                return AccessReport.Scan(root: root.path, entries: stats.dirs + stats.files,
                    dirs: stats.dirs, files: stats.files, errors: stats.errors,
                    unreadableCount: stats.unreadable_count, wallClockSeconds: seconds,
                    incomplete: stats.incomplete)
            }
            let error: Int32? = status < 0 ? -status : (snapshot == nil ? EIO : nil)
            try AccessReport(probe: result, scan: metrics, scanError: error).encoded()
                .write(to: configuration.output, options: .atomic)
            return error == nil ? Int32(0) : Int32(1)
        }.value
    }
}
