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

#if TESSERAE_TEST_HOOKS
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
            let output = try TestHookOutput(configuration.output)
            let result = probe.inspect()
            // Keep the probe evidence even if the subsequent scan cannot start or finish.
            try AccessReport(probe: result).encoded().withUnsafeBytes { try output.write($0) }
            guard let root = configuration.scanRoot else { return Int32(0) }
            let started = ContinuousClock.now
            guard let handle = ScanHandle(root: root, options: .init()) else {
                try AccessReport(probe: result, scanError: EINVAL).encoded()
                    .withUnsafeBytes { try output.write($0) }
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
                .withUnsafeBytes { try output.write($0) }
            return error == nil ? Int32(0) : Int32(1)
        }.value
    }
}

/// Test reports may create new files only inside this process's temporary directory.
/// Walk beneath an anchored directory descriptor so a symlink cannot escape it.
final class TestHookOutput {
    private let descriptor: Int32

    init(_ url: URL) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve the temporary directory's system alias (/var -> /private/var),
        // but never resolve caller-controlled components beneath it.
        let path = url.standardizedFileURL.path
        let aliases = [root, URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path]
        guard let prefix = aliases.first(where: { path.hasPrefix($0 + "/") }),
              !url.path.contains("\0") else { throw POSIXError(.EPERM) }
        let components = path.dropFirst(prefix.count + 1).split(separator: "/").map(String.init)
        guard let name = components.last else { throw POSIXError(.EINVAL) }
        var parent = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parent) }
        for component in components.dropLast() {
            let next = component.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            Darwin.close(parent)
            parent = next
        }
        descriptor = name.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { Darwin.close(descriptor) }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard ftruncate(descriptor, 0) == 0, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += count
        }
    }
}
#endif
