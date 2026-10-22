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
import TesseraeFFI

public protocol ExclusiveCreator: Sendable {
    func create(parent: Data, parentRecorded: Recorded, baseName: Data, ext: String) throws -> (fd: Int32, name: Data)
}
public struct ProductionExclusiveCreator: ExclusiveCreator {
    public init() {}
    public func create(parent: Data, parentRecorded: Recorded, baseName: Data, ext: String) throws -> (fd: Int32, name: Data) {
        guard !baseName.isEmpty, !baseName.contains(0), !baseName.contains(47), baseName != Data(".".utf8),
              baseName != Data("..".utf8), (parent == Data([47]) || (try? archiveParts(parent)) != nil), ["zip", "tar.xz", "tar.zst", "aar"].contains(ext), parentRecorded.isDirectory,
              verifyIdentity(parent, parentRecorded, stat: ProductionFileStat()) == .same else { throw archiveError(ESTALE) }
        let fd = archiveCString(parent) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_ino == parentRecorded.fileID, info.st_dev == parentRecorded.device,
              info.st_mode & S_IFMT == S_IFDIR else { throw archiveError(ESTALE) }
        for number in 1...99 {
            let name = baseName + Data((number == 1 ? "" : " \(number)").utf8) + Data(("." + ext).utf8)
            let archive = archiveCString(name) { openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) }
            if archive >= 0 { return (archive, name) }
            if errno != EEXIST { throw archiveError(errno) }
        }
        throw archiveError(EEXIST)
    }
}

public protocol ArchiveFileSystem: FileStat {
    func inspect(_ path: Data) throws -> ArchiveInspection
    func freeSpace(_ path: Data) -> UInt64?
    func readArchive(_ path: Data, matching fd: Int32) throws -> Int32
    func archiveStamp(_ fd: Int32) throws -> ArchiveStamp
    func usage(_ fd: Int32) throws -> (allocated: UInt64, logical: UInt64)
    func digest(_ fd: Int32) throws -> String
    func syncParent(_ path: Data, recorded: Recorded) throws
}
public struct ProductionArchiveFileSystem: ArchiveFileSystem {
    private let syncDirectory: @Sendable (Int32) -> Int32
    private let verificationFlags: @Sendable (Data) throws -> UInt32
    public init() { self.init(syncDirectory: { fsync($0) }) }
    init(syncDirectory: @escaping @Sendable (Int32) -> Int32 = { fsync($0) },
         verificationFlags: @escaping @Sendable (Data) throws -> UInt32 = { try archiveVerificationFlags($0) }) {
        self.syncDirectory = syncDirectory; self.verificationFlags = verificationFlags
    }
    public func lstat(_ path: Data) -> StatResult { ProductionFileStat().lstat(path) }
    public func volumeUUID(_ path: Data) -> String? { ProductionFileStat().volumeUUID(path) }
    public func inspect(_ path: Data) throws -> ArchiveInspection {
        let tree = try ArchiveTree.scan(path, hashFiles: false, flags: try verificationFlags(path))
        return ArchiveInspection(facts: tree.facts, files: tree.files, stamps: tree.stamps)
    }
    public func freeSpace(_ path: Data) -> UInt64? { ProductionCompressionFileSystem().freeSpace(path) }
    public func readArchive(_ path: Data, matching fd: Int32) throws -> Int32 {
        var reserved = Darwin.stat(), current = Darwin.stat()
        guard fstat(fd, &reserved) == 0, reserved.st_mode & S_IFMT == S_IFREG else { throw archiveError(ESTALE) }
        let readFD = archiveCString(path) { open($0, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC) }
        guard readFD >= 0 else { throw archiveError(errno) }
        guard fstat(readFD, &current) == 0, current.st_dev == reserved.st_dev, current.st_ino == reserved.st_ino,
              current.st_mode & S_IFMT == S_IFREG, current.st_size == reserved.st_size else {
            close(readFD); throw archiveError(ESTALE)
        }
        return readFD
    }
    public func archiveStamp(_ fd: Int32) throws -> ArchiveStamp {
        var s = Darwin.stat()
        guard fstat(fd, &s) == 0 else { throw archiveError(errno) }
        return ArchiveStamp(s)
    }
    public func usage(_ fd: Int32) throws -> (allocated: UInt64, logical: UInt64) {
        var s = Darwin.stat()
        guard fstat(fd, &s) == 0, s.st_size >= 0, s.st_blocks >= 0 else { throw archiveError(errno) }
        return (UInt64(s.st_blocks) * 512, UInt64(s.st_size))
    }
    public func syncParent(_ path: Data, recorded: Recorded) throws {
        let fd = archiveCString(path) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_ino == recorded.fileID, info.st_dev == recorded.device,
              info.st_mode & S_IFMT == S_IFDIR else { throw archiveError(ESTALE) }
        guard syncDirectory(fd) == 0 else { throw archiveError(errno) }
    }
    public func digest(_ fd: Int32) throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw archiveError(errno) }
        return try archiveHash(fd).1.map { String(format: "%02x", $0) }.joined()
    }
}

public protocol ArchiveRunner: Sendable {
    func run(item: Data, format: ArchiveFormat, to fd: Int32) async -> Int32
}
public struct ProductionArchiveRunner: ArchiveRunner {
    public static func zipFlags(isDirectory: Bool) -> [String] {
        ["-c", "-k", "--sequesterRsrc"] + (isDirectory ? ["--keepParent"] : [])
    }
    private let apple: any AppleArchiveWriter
    public init(apple: any AppleArchiveWriter = ProductionAppleArchiveWriter()) { self.apple = apple }
    public func run(item: Data, format: ArchiveFormat, to fd: Int32) async -> Int32 {
        do {
            let parts = try archiveParts(item)
            let status: Int32
            switch format {
            case .appleArchiveFast, .appleArchiveSmallest:
                _ = try apple.write(item: item, to: fd, compression: format == .appleArchiveFast ? .lzfse : .lzma)
                status = 0
            case .zip:
                var info = Darwin.stat()
                guard archiveCString(item, { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                      info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { return -ESTALE }
                let args = Self.zipFlags(isDirectory: info.st_mode & S_IFMT == S_IFDIR).map { Data($0.utf8) } + [item, Data("/dev/fd/1".utf8)]
                status = Self.exitCode(await SpawnRunner().run("/usr/bin/ditto", args, stdoutFD: fd))
            case .tarXZ:
                guard let args = tarArguments(format, parent: parts.parent, name: parts.name) else { return -EINVAL }
                status = Self.exitCode(await SpawnRunner().run("/usr/bin/tar", args, stdoutFD: fd))
            case .tarZst:
                guard let args = tarArguments(format, parent: parts.parent, name: parts.name) else { return -EINVAL }
                var descriptors: [Int32] = [0, 0]
                guard pipe(&descriptors) == 0 else { return -errno }
                let source = descriptors[0], destination = descriptors[1]
                let encode = Task.detached { () -> Int32 in
                    defer { close(source) }
                    var bytes: UInt64 = 0
                    return tess_zstd_stream(source, fd, 3, &bytes)
                }
                let tar = Self.exitCode(await SpawnRunner().run("/usr/bin/tar", args, stdoutFD: destination))
                close(destination)
                let zstd = await encode.value
                status = tar == 0 ? zstd : tar
            }
            if status == 0 && fsync(fd) != 0 { return -errno }
            return status
        } catch { return -Int32(clamping: (error as NSError).code) }
    }
    private static func exitCode(_ status: SpawnResult) -> Int32 {
        switch status { case .exited(let code): return code; case .signalled(let signal): return -signal; case .spawnFailed(let code), .captureFailed(let code): return -code }
    }
}

public enum ArchiveOutcome: Equatable, Sendable {
    case archivedAndTrashed(archive: URL, bytes: UInt64, trashURL: URL)
    case archivedOriginalsKept(archive: URL, reason: String)
    case failed(String, archiveTrashed: URL?)
}
public struct ArchiveRun: Equatable, Sendable {
    public var outcome: ArchiveOutcome
    public var allocatedBytes: UInt64 = 0, logicalBytes: UInt64 = 0
    public var auditEntry: LogEntry?
    public func apply(item: ReclaimItem, to overlay: inout SizeOverlay, snapshot: Snapshot) {
        let parent = snapshot.nodes[Int(item.nodeIndex)].parent
        if parent != UInt32.max { overlay.applyDelta(node: parent, allocated: Int64(clamping: allocatedBytes), logical: Int64(clamping: logicalBytes), in: snapshot) }
        if case .archivedAndTrashed = outcome { overlay.remove(item.nodeIndex, in: snapshot) }
    }
}

public actor Archiver {
    private let creator: any ExclusiveCreator
    private let runner: any ArchiveRunner
    private let verifier: any ArchiveVerifier
    private let files: any ArchiveFileSystem
    private let trasher: any Trasher
    private let log: any AuditSink
    private let context: GuardContext
    private var busy = false
    public init(creator: any ExclusiveCreator = ProductionExclusiveCreator(), runner: any ArchiveRunner = ProductionArchiveRunner(),
                verifier: any ArchiveVerifier = ProductionArchiveVerifier(), files: any ArchiveFileSystem = ProductionArchiveFileSystem(),
                trasher: any Trasher = ProductionTrasher(), log: any AuditSink = ReclaimLog(), context: GuardContext) {
        self.creator = creator; self.runner = runner; self.verifier = verifier; self.files = files
        self.trasher = trasher; self.log = log; self.context = context
    }
    public nonisolated static func requiredSpace(estimatedBytes: UInt64) -> UInt64 {
        let (quarter, a) = estimatedBytes.addingReportingOverflow(3)
        let (extra, b) = estimatedBytes.addingReportingOverflow(a ? UInt64.max : quarter / 4)
        let (total, c) = extra.addingReportingOverflow(512 * 1024 * 1024)
        return a || b || c ? UInt64.max : total
    }
    public func archive(_ item: ReclaimItem, format: ArchiveFormat, estimatedBytes: UInt64? = nil,
                        confirmedWarnings: Set<Reason> = [], trashOriginal: @Sendable () async -> Outcome) async -> ArchiveOutcome {
        await perform(item, format: format, estimatedBytes: estimatedBytes, confirmedWarnings: confirmedWarnings) { validate in
            guard validate() else { return .identityChanged(.inodeChanged) }
            return await trashOriginal()
        }.outcome
    }
    public func perform(_ item: ReclaimItem, format: ArchiveFormat, estimatedBytes: UInt64? = nil,
                        confirmedWarnings: Set<Reason> = [], trashOriginal: @Sendable (@escaping @Sendable () -> Bool) async -> Outcome) async -> ArchiveRun {
        let refusal = String(localized: "archive.refused", defaultValue: "Archive couldn't proceed. Files or permissions changed, or verification failed.",
            bundle: L10n.bundle, comment: "Archive refused after an identity, guard, content or verification check.")
        guard !busy else { return ArchiveRun(outcome: .failed(refusal, archiveTrashed: nil)) }
        busy = true; defer { busy = false }
        let start = Date(), volumeUUID = files.volumeUUID(item.path)
        var result = ArchiveRun(outcome: .failed(refusal, archiveTrashed: nil))
        var path: Data?, descriptor: Int32?, status: Int32?, verdict = ArchiveVerdict(), sha: String?
        var discardedStamp: ArchiveStamp?, parentSyncError: Int32?
        defer { if let descriptor { close(descriptor) } }
        do {
            let parts = try archiveParts(item.path)
            guard verifyIdentity(item.path, item.recorded, stat: files) == .same,
                  case .ok(let observation, _, false) = files.lstat(item.path),
                  case .ok(let parentInfo, let parentID, false) = files.lstat(parts.parent), parentInfo.isDirectory,
                  item.recorded.device == parentInfo.device, item.recordedSize != nil, !item.hasUnknownContent,
                  Set(itemWarnings(item)).isSubset(of: confirmedWarnings), item.verdict != .denied(.changedSinceReview) else { throw archiveError(ESTALE) }
            if case .denied = item.verdict { throw archiveError(EPERM) }
            guard allVerdicts(item.path, observation, context).allSatisfy({ verdict in
                switch verdict { case .ok: return true; case .warn(let reason): return confirmedWarnings.contains(reason) || (reason == .otherHardLinks && confirmedWarnings.contains(.containsHardLinks)); case .denied: return false }
            }) else { throw archiveError(EPERM) }
            let tree = try files.inspect(item.path)
            if case .unavailable(let reason) = formatSupports(format, itemFacts: tree.facts) { throw ArchiveMessage(reason) }
            guard tree.stamps[item.path]?.recorded == item.recorded,
                  ![".zip", ".tar.xz", ".tar.zst", ".aar"].contains(where: { !item.recorded.isDirectory && String(decoding: parts.name, as: UTF8.self).lowercased().hasSuffix($0) }) else { throw archiveError(EPERM) }
            for child in item.descendants {
                guard let stamp = tree.stamps[child.path], stamp.recorded == child.recorded,
                      (stamp.mode & S_IFMT == S_IFLNK) == child.isSymlink else { throw archiveError(ESTALE) }
            }
            for (child, stamp) in tree.stamps {
                if stamp.mode & S_IFMT == S_IFREG && stamp.links > 1 && !confirmedWarnings.contains(.containsHardLinks) && !confirmedWarnings.contains(.otherHardLinks) { throw archiveError(EPERM) }
                if child != item.path && stamp.mode & S_IFMT != S_IFLNK {
                    let observed = Observed(device: stamp.recorded.device, flags: stamp.flags, isDirectory: stamp.recorded.isDirectory, linkCount: stamp.links)
                    guard allVerdicts(child, observed, context).allSatisfy({ verdict in
                        switch verdict { case .ok: return true; case .warn(let reason): return confirmedWarnings.contains(reason) || (reason == .otherHardLinks && confirmedWarnings.contains(.containsHardLinks)); case .denied: return false }
                    }) else { throw archiveError(EPERM) }
                }
            }
            let saved = SampleEstimate.archive(format, files: tree.files)
            let estimate = estimatedBytes ?? (tree.facts.eligibleBytes - min(tree.facts.eligibleBytes, saved))
            let needed = Self.requiredSpace(estimatedBytes: estimate), free = files.freeSpace(parts.parent)
            guard let free else {
                throw ArchiveMessage(String(localized: "archive.freeSpaceUnknown", defaultValue: "Tesserae couldn't read this disk's free space.",
                    bundle: L10n.bundle, comment: "Archive refused because the available disk space could not be read."))
            }
            guard free >= needed else {
                let requiredSize = displaySize(needed), availableSize = displaySize(free)
                let message = String(localized: "archive.freeSpace", defaultValue: "Archive needs \(requiredSize) free; \(availableSize) are available.",
                    bundle: L10n.bundle, comment: "Archive refusal with formatted required and available free space, in that order.")
                throw ArchiveMessage(message)
            }
            let made = try creator.create(parent: parts.parent,
                parentRecorded: Recorded(fileID: parentID, device: parentInfo.device, isDirectory: true), baseName: parts.name, ext: format.fileExtension)
            descriptor = made.fd; path = parts.parent + (parts.parent == Data([47]) ? Data() : Data([47])) + made.name
            status = await runner.run(item: item.path, format: format, to: made.fd)
            guard status == 0, !Task.isCancelled else {
                throw ArchiveMessage(String(format: String(localized: "archive.writeFailed",
                    defaultValue: "Archive creation failed (status %d). The originals were kept.", bundle: L10n.bundle,
                    comment: "Archive creation failure with the subprocess or encoder status."), status ?? -EIO))
            }
            let readFD = try files.readArchive(path!, matching: made.fd); defer { close(readFD) }
            let archiveStamp = try files.archiveStamp(readFD)
            verdict = verifier.verify(fd: readFD, path: path!, format: format, item: item.path)
            guard verdict.code == 0 else {
                throw ArchiveMessage(String(format: String(localized: "archive.verifyFailed",
                    defaultValue: "Archive verification failed (code %d). The originals were kept.", bundle: L10n.bundle,
                    comment: "Archive verification failure with the verifier error code."), verdict.code))
            }
            sha = try files.digest(readFD)
            let usage = try files.usage(readFD)
            // Check ALL original identities, timestamps and directory membership again,
            // including changes after verification, before entering §10's unchanged path.
            let reservedPath = path!
            let validate: @Sendable () -> Bool = { [files] in
                guard (try? files.inspect(item.path).stamps) == tree.stamps,
                      (try? files.archiveStamp(readFD)) == archiveStamp else { return false }
                guard let current = try? files.readArchive(reservedPath, matching: made.fd) else { return false }
                close(current); return true
            }
            guard validate() else { throw archiveError(ESTALE) }
            let freshFD = try files.readArchive(path!, matching: made.fd); close(freshFD)
            let archive = try archiveRawURL(path!)
            // The runner has synced the completed archive. Persist its directory entry
            // before handing the originals to Executor; unsupported directory sync is nonfatal.
            do { try files.syncParent(parts.parent, recorded: Recorded(fileID: parentID, device: parentInfo.device, isDirectory: true)) }
            catch { parentSyncError = Int32(clamping: (error as NSError).code) }
            let trash = await trashOriginal(validate)
            switch trash {
            case .trashed(let url):
                result.outcome = .archivedAndTrashed(archive: archive, bytes: usage.logical, trashURL: url)
            case .failed(let code, let message):
                let reason = code == ENOTSUP ? String(localized: "archive.noTrash",
                    defaultValue: "Archive kept. This disk has no Trash, so the originals remain in place.", bundle: L10n.bundle,
                    comment: "A verified archive is kept when this volume does not support Trash.") : String(format: String(localized: "archive.trashFailed",
                    defaultValue: "Archive kept. The originals couldn't be moved to the Trash: %@", bundle: L10n.bundle,
                    comment: "A verified archive and the originals are kept; the placeholder is the Trash error message."), message)
                result.outcome = .archivedOriginalsKept(archive: archive, reason: reason)
            default: throw archiveError(ESTALE)
            }
            result.allocatedBytes = usage.allocated; result.logicalBytes = usage.logical
        } catch {
            var discarded: URL?
            if let path, let descriptor {
                // Never Trash an arriving replacement of our reserved archive.
                if let fd = try? files.readArchive(path, matching: descriptor) {
                    defer { close(fd) }
                    if let stamp = try? files.archiveStamp(fd) {
                        discarded = try? trasher.trash(archiveRawURL(path))
                        if discarded != nil { discardedStamp = stamp }
                    }
                }
            }
            var reason = (error as? ArchiveMessage)?.text ?? refusal
            if path != nil && discarded == nil {
                reason += " " + String(localized: "archive.cleanupFailed",
                    defaultValue: "The incomplete archive couldn't be moved to Trash.", bundle: L10n.bundle,
                    comment: "An archive failure also failed to discard the incomplete or stale archive.")
            }
            result.outcome = .failed(reason, archiveTrashed: discarded)
            // A failed discard still leaves our new file beside the originals.
            if discarded == nil, let descriptor, let usage = try? files.usage(descriptor), path != nil {
                result.allocatedBytes = usage.allocated; result.logicalBytes = usage.logical
            }
        }
        // A discarded archive restores to its own path and identity, never over the originals.
        let loggedPath = discardedStamp != nil ? path! : item.path
        let loggedIdentity = discardedStamp?.recorded ?? item.recorded
        let originalPath = String(data: loggedPath, encoding: .utf8)
        var trashURL: String?, resultText: String
        switch result.outcome {
        case .archivedAndTrashed(_, _, let url): trashURL = url.absoluteString; resultText = "ok"
        case .archivedOriginalsKept: resultText = "originalsKept"
        case .failed(_, let url): trashURL = url?.absoluteString; resultText = "failed"
        }
        let writtenBytes = descriptor.flatMap { try? files.usage($0).logical } ?? 0
        var version = ProcessInfo.processInfo.operatingSystemVersionString
        if format == .tarXZ || format == .tarZst {
            let captured = await SpawnRunner().runCapturing("/usr/bin/tar", [Data("--version".utf8)])
            if captured.0 == .exited(0), let first = captured.stdout.split(separator: 10).first {
                version = String(decoding: first, as: UTF8.self)
            }
        }
        let details = ArchiveAudit(format: format.rawValue, tool: format == .zip ? "ditto" : format.fileExtension == "aar" ? "AppleArchive" : "bsdtar",
            version: version,
            flags: format == .zip ? ProductionArchiveRunner.zipFlags(isDirectory: item.recorded.isDirectory) : format == .tarXZ ? ["-c", "-J", "--options", "xz:threads=0", "--one-file-system", "--no-read-sparse"] : format == .tarZst ? ["-c", "--one-file-system", "--no-read-sparse", "zstd:level=3"] : [format == .appleArchiveFast ? "lzfse" : "lzma", "all-metadata"],
            exitStatus: status, duration: Date().timeIntervalSince(start), archivePath: path.flatMap { String(data: $0, encoding: .utf8) },
            archivePathB64: path.flatMap { String(data: $0, encoding: .utf8) == nil ? $0.base64EncodedString() : nil },
            archiveBytes: writtenBytes, sha256: sha, files: verdict.files, dirs: verdict.dirs, links: verdict.links,
            verifiedBytes: verdict.bytes, firstBadPathB64: verdict.firstBadPath.isEmpty ? nil : verdict.firstBadPath.base64EncodedString(), verificationCode: verdict.code, parentSyncError: parentSyncError)
        let entry = LogEntry(ts: Date(), action: "archive", path: originalPath, pathB64: originalPath == nil ? loggedPath.base64EncodedString() : nil,
            inode: loggedIdentity.fileID, device: loggedIdentity.device, volumeUUID: volumeUUID, isDirectory: loggedIdentity.isDirectory,
            hasUnknownContent: discardedStamp == nil ? item.hasUnknownContent : false, bytes: discardedStamp == nil ? item.recordedSize : writtenBytes, trashURL: trashURL, result: resultText, archive: details)
        result.auditEntry = entry; _ = log.append(entry)
        return result
    }
}
private struct ArchiveMessage: Error { let text: String; init(_ text: String) { self.text = text } }
