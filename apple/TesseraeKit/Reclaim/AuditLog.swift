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

public struct CompressionAudit: Codable, Equatable, Sendable {
    public let runID: CompressRunID
    public let tool, version: String
    public let flags: [String]
    public let exitStatuses: [Int32]
    public let duration: TimeInterval
    public let filesChanged: Int
    public let skipped: [String: Int]
    public let failed: Int
    public let bytesBefore, bytesAfter: UInt64
    public let signatureStatus: Int32?
    public let manifestFailed: Bool
}

public struct ArchiveAudit: Codable, Equatable, Sendable {
    public let format, tool, version: String
    public let flags: [String]
    public let exitStatus: Int32?
    public let duration: TimeInterval
    public let archivePath, archivePathB64: String?
    public let archiveBytes: UInt64
    public let sha256: String?
    public let files, dirs, links, verifiedBytes: UInt64
    public let firstBadPathB64: String?
    public let verificationCode: Int32
    public var parentSyncError: Int32? = nil
}

public struct LogEntry: Codable, Equatable, Sendable {
    public let ts: Date
    public let action: String
    public let path: String?
    public let pathB64: String?
    public let inode: UInt64
    public let device: Int32?
    public let volumeUUID: String?
    public let isDirectory: Bool?
    public let hasUnknownContent: Bool?
    public let bytes: UInt64?
    public let trashURL: String?
    public let result: String
    public let compression: CompressionAudit?
    public let archive: ArchiveAudit?

    public init(ts: Date, action: String, path: String?, pathB64: String?, inode: UInt64,
                device: Int32? = nil, volumeUUID: String? = nil, isDirectory: Bool? = nil, hasUnknownContent: Bool? = nil, bytes: UInt64?, trashURL: String?, result: String, compression: CompressionAudit? = nil, archive: ArchiveAudit? = nil) {
        precondition((path != nil) != (pathB64 != nil), "Exactly one path representation is required")
        self.ts = ts
        self.action = action
        self.path = path
        self.pathB64 = pathB64
        self.inode = inode
        self.device = device
        self.volumeUUID = volumeUUID
        self.isDirectory = isDirectory
        self.hasUnknownContent = hasUnknownContent
        self.bytes = bytes
        self.trashURL = trashURL
        self.result = result
        self.compression = compression
        self.archive = archive
    }
}

public protocol AuditSink: Sendable {
    func append(_ e: LogEntry) -> Bool
    func compressEntry(run: CompressRunID) -> LogEntry?
}

public extension AuditSink {
    func compressEntry(run: CompressRunID) -> LogEntry? { nil }
}
