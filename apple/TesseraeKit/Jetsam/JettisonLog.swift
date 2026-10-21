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

// Wrappers for one canonical directory share transaction and failure state.
private final class LogCoordinator: @unchecked Sendable {
    let lock = NSLock()
    var writeFailed = false
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: LogCoordinator] = [:]

    static func shared(_ directory: URL) -> LogCoordinator {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = directory.path
        if let existing = registry[key] { return existing }
        let store = LogCoordinator()
        registry[key] = store
        return store
    }
}

public final class JettisonLog: AuditSink, @unchecked Sendable {
    private let directory: URL
    private let maxBytes: Int
    private let keep: Int
    private let coordinator: LogCoordinator

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                in: .userDomainMask)[0].appendingPathComponent("Tesserae"),
                maxBytes: Int = 5 * 1024 * 1024, keep: Int = 3) {
        precondition(maxBytes > 0 && keep > 0)
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.coordinator = LogCoordinator.shared(self.directory)
        self.maxBytes = maxBytes
        self.keep = keep
    }

    public var lastWriteFailed: Bool {
        coordinator.lock.lock(); defer { coordinator.lock.unlock() }
        return coordinator.writeFailed
    }

    private func file(_ index: Int = 0) -> URL {
        directory.appendingPathComponent(index == 0 ? "jettison.log" : "jettison.log.\(index)")
    }

    public func append(_ e: LogEntry) -> Bool {
        coordinator.lock.lock(); defer { coordinator.lock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var line = try encoder.encode(e)
            line.append(0x0a)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var directoryInfo = Darwin.stat()
            if lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & 0o077 != 0 {
                _ = chmod(directory.path, 0o700)
            }
            let transaction = try acquireDirectoryLock()
            defer { _ = flock(transaction, LOCK_UN); close(transaction) }
            let current = file()
            var info = Darwin.stat()
            if lstat(current.path, &info) == 0, info.st_size > 0,
               info.st_size > Int64(maxBytes) - Int64(line.count) {
                // rename replaces the oldest archive; no separate removal is needed.
                for index in stride(from: keep - 1, through: 0, by: -1) {
                    if rename(file(index).path, file(index + 1).path) != 0 && errno != ENOENT {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            let fd = open(current.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(fd) }
            try line.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
                    written += count
                }
            }
            coordinator.writeFailed = false
            return true
        } catch {
            coordinator.writeFailed = true
            return false
        }
    }

    public func entries() -> [LogEntry] {
        coordinator.lock.lock(); defer { coordinator.lock.unlock() }
        guard let transaction = try? acquireDirectoryLock() else { return [] }
        defer { _ = flock(transaction, LOCK_UN); close(transaction) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return stride(from: keep, through: 0, by: -1).flatMap { index -> [LogEntry] in
            guard let data = try? Data(contentsOf: file(index)) else { return [] }
            return data.split(separator: 0x0a).compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
        }
    }

    private func acquireDirectoryLock() throws -> Int32 {
        let fd = open(directory.appendingPathComponent("jettison.lock").path,
                      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    public func restorableEntries() -> [LogEntry] {
        struct Identity: Hashable {
            let inode: UInt64
            let volumeUUID: String?
            let device: Int32?
            let trashURL: String?
        }
        var restored: Set<Identity> = []
        return entries().reversed().filter { entry in
            let key = Identity(inode: entry.inode, volumeUUID: entry.volumeUUID, device: entry.device, trashURL: entry.trashURL)
            if entry.action == "putBack" { restored.insert(key); return false }
            return entry.action == "trash" && entry.result == "ok" && !restored.contains(key)
        }
    }
}
