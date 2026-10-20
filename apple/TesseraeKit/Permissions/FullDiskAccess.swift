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

public struct AccessCandidateResult: Codable, Equatable, Sendable {
    public let path: String
    public let errno: Int32
}

public struct AccessProbeResult: Equatable, Sendable {
    public let state: AccessState
    public let evidence: String?
    public let candidates: [AccessCandidateResult]
}

public extension Array where Element == URL {
    static var defaultCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Library/Mail", "Library/Messages", "Library/Safari"].map {
            home.appendingPathComponent($0, isDirectory: true)
        } + [home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")]
    }
}

public struct AccessProbe: Sendable {
    private let candidates: [URL]
    private let open: @Sendable (URL) -> Int32

    public init(candidates: [URL] = .defaultCandidates,
                open: @escaping @Sendable (URL) -> Int32 = AccessProbe.realOpen) {
        self.candidates = candidates
        self.open = open
    }

    public func probe() -> AccessState { inspect().state }

    public func inspect() -> AccessProbeResult {
        let results = candidates.map { AccessCandidateResult(path: $0.path, errno: open($0)) }
        // Spec §11: measured 2026-10-20, EPERM on an existing candidate means no FDA.
        // EACCES and other errors are indeterminate; a readable path cannot override them.
        if let denied = results.first(where: { $0.errno == EPERM }) {
            let evidence = "\(denied.path): errno \(denied.errno) (EPERM)"
            return AccessProbeResult(state: .denied(evidence: evidence), evidence: evidence, candidates: results)
        }
        if let other = results.first(where: { $0.errno != 0 && $0.errno != ENOENT }) {
            return AccessProbeResult(state: .unknown, evidence: "\(other.path): errno \(other.errno)", candidates: results)
        }
        let state: AccessState = results.contains { $0.errno == 0 } ? .granted : .unknown
        return AccessProbeResult(state: state, evidence: nil, candidates: results)
    }

    /// Determine the directory flag from metadata, then open and close without reading contents.
    /// The open errno remains authoritative if metadata lookup fails or the path changes between calls.
    public static func realOpen(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let directory = exists ? isDirectory.boolValue : url.hasDirectoryPath
            let fd = Darwin.open(path, O_RDONLY | (directory ? O_DIRECTORY : 0))
            guard fd >= 0 else { return errno }
            Darwin.close(fd)
            return 0
        }
    }
}
