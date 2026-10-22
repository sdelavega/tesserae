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

import AppleArchive
import CryptoKit
import Darwin
import Foundation
import System
import TesseraeFFI

func archiveCString<T>(_ bytes: Data, _ body: (UnsafePointer<CChar>) throws -> T) rethrows -> T {
    try (bytes + Data([0])).withUnsafeBytes { try body($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
}
func archiveParts(_ path: Data) throws -> (parent: Data, name: Data) {
    let parts = path.split(separator: 47, omittingEmptySubsequences: false)
    guard path.first == 47, !path.contains(0), parts.count > 1,
          parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != Data(".".utf8) && $0 != Data("..".utf8) }),
          let slash = path.lastIndex(of: 47) else { throw archiveError(EINVAL) }
    return (slash == 0 ? Data([47]) : Data(path[..<slash]), Data(path[(slash + 1)...]))
}
func archiveError(_ code: Int32 = EIO) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
func archiveRawURL(_ path: Data) throws -> URL {
    let url = archiveCString(path) { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil) }
    guard url.withUnsafeFileSystemRepresentation({ $0.map { Data(bytes: $0, count: strlen($0)) } }) == path else { throw archiveError(EILSEQ) }
    return url
}
func archiveHash(_ fd: Int32) throws -> (UInt64, Data) {
    var digest = SHA256(), count: UInt64 = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 { if errno == EINTR { continue }; throw archiveError(errno) }
        if n == 0 { return (count, Data(digest.finalize())) }
        count += UInt64(n); digest.update(data: Data(buffer.prefix(n)))
    }
}

func archiveVerificationFlags(volumeFSType: String) -> UInt32 {
    switch volumeFSType {
    case "exfat", "msdos", "smbfs", "afpfs", "nfs", "webdav", "ntfs":
        return UInt32(TESS_ARCHIVE_SIDECARS_ARE_METADATA)
    default: return 0
    }
}
func archiveVerificationFlags(_ item: Data) throws -> UInt32 {
    _ = try archiveParts(item)
    var info = statfs()
    guard archiveCString(item, { statfs($0, &info) }) == 0 else { throw ArchiveFailure(code: 7, path: item, reason: .volumeStat, systemError: errno) }
    let kind = withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    guard !kind.isEmpty else { throw ArchiveFailure(code: 7, path: item, reason: .volumeType) }
    return archiveVerificationFlags(volumeFSType: kind)
}
// Return owned, zero-based bytes; neither display escaping nor UTF-8 repair
// belongs in a filesystem lookup. Data callers may supply a nonzero-index slice.
func archiveSidecarSibling(_ name: Data) -> Data? {
    guard name.starts(with: [46, 95]), name.count > 2 else { return nil }
    return Data(name.dropFirst(2))
}
func archivePairedSidecar(parent: Int32, name: Data, stamp: Darwin.stat, flags: UInt32) throws -> Bool {
    guard flags & UInt32(TESS_ARCHIVE_SIDECARS_ARE_METADATA) != 0,
          stamp.st_mode & S_IFMT == S_IFREG, (24...16 * 1024 * 1024).contains(stamp.st_size),
          stamp.st_flags & UInt32(UF_HIDDEN) != 0,
          let siblingName = archiveSidecarSibling(name) else { return false }
    func bad(_ reason: ArchiveFailureReason, _ systemError: Int32? = nil) -> ArchiveFailure {
        ArchiveFailure(code: 7, path: name, reason: reason, systemError: systemError)
    }
    var sibling = Darwin.stat()
    guard archiveCString(siblingName, { fstatat(parent, $0, &sibling, AT_SYMLINK_NOFOLLOW) }) == 0 else {
        guard errno == ENOENT else { throw bad(.sidecarLookup, errno) }
        return false
    }
    let fd = archiveCString(name) { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
    guard fd >= 0 else { throw bad(.entryOpen, errno) }; defer { close(fd) }
    let before = ArchiveStamp(stamp)
    var opened = Darwin.stat()
    guard fstat(fd, &opened) == 0 else { throw bad(.openedStat, errno) }
    guard ArchiveStamp(opened) == before else { throw bad(.openedStampChanged) }
    var header = [UInt8](repeating: 0, count: 24), offset = 0
    while offset < header.count {
        let n = header.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if n < 0 { if errno == EINTR { continue }; throw bad(.fileRead, errno) }
        guard n > 0 else { throw bad(.readSizeChanged) }
        offset += n
    }
    var after = Darwin.stat()
    guard fstat(fd, &after) == 0 else { throw bad(.finalDescriptorStat, errno) }
    guard ArchiveStamp(after) == before else { throw bad(.finalDescriptorStampChanged) }
    guard archiveCString(name, { fstatat(parent, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw bad(.finalPathStat, errno) }
    guard ArchiveStamp(after) == before else { throw bad(.finalPathStampChanged) }
    // Big-endian magic and version, then the measured macOS or spec filler.
    return header.prefix(8).elementsEqual([0, 5, 22, 7, 0, 2, 0, 0]) &&
        (header.suffix(16).elementsEqual("Mac OS X        ".utf8) || header.suffix(16).allSatisfy { $0 == 0 })
}

public struct ArchiveVerdict: Equatable, Sendable {
    public var code: Int32
    public var files, dirs, links, bytes: UInt64
    public var firstBadPath: Data
    public var firstBadLength: Int
    public init(code: Int32 = 0, files: UInt64 = 0, dirs: UInt64 = 0, links: UInt64 = 0, bytes: UInt64 = 0,
                firstBadPath: Data = Data(), firstBadLength: Int? = nil) {
        self.code = code; self.files = files; self.dirs = dirs; self.links = links; self.bytes = bytes
        self.firstBadPath = Data(firstBadPath.prefix(1024)); self.firstBadLength = firstBadLength ?? firstBadPath.count
    }
}

public struct ArchiveStamp: Equatable, Sendable {
    public let recorded: Recorded
    public let size: UInt64
    var linkTarget: Data?
    var mode: UInt16 = 0, flags: UInt32 = 0, links: UInt16 = 0
    var modified: Int64 = 0, modifiedNS: Int64 = 0, changed: Int64 = 0, changedNS: Int64 = 0
    public init(recorded: Recorded, size: UInt64) { self.recorded = recorded; self.size = size }
    init(_ s: Darwin.stat) {
        recorded = Recorded(fileID: s.st_ino, device: s.st_dev, isDirectory: s.st_mode & S_IFMT == S_IFDIR)
        size = UInt64(max(0, s.st_size)); mode = s.st_mode; flags = s.st_flags; links = s.st_nlink
        modified = Int64(s.st_mtimespec.tv_sec); modifiedNS = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changedNS = Int64(s.st_ctimespec.tv_nsec)
    }
}
public struct ArchiveInspection: Sendable {
    public var facts: ArchiveItemFacts
    public var files: [(Data, UInt64)]
    public var stamps: [Data: ArchiveStamp]
    public init(facts: ArchiveItemFacts, files: [(Data, UInt64)], stamps: [Data: ArchiveStamp]) {
        self.facts = facts; self.files = files; self.stamps = stamps
    }
}

enum ArchiveContent: Equatable {
    case file(UInt64, Data), directory, link(Data)
}
struct ArchiveTree {
    var entries: [Data: ArchiveContent] = [:]
    var stamps: [Data: ArchiveStamp] = [:]
    var files: [(Data, UInt64)] = []
    var facts = ArchiveItemFacts()
    var verificationFlags: UInt32 = 0
    var excludedSidecars: Set<Data> = []
    static func scan(_ item: Data, hashFiles: Bool, flags: UInt32 = 0) throws -> ArchiveTree {
        let parts = try archiveParts(item)
        let parent = archiveCString(parts.parent) { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) }
        guard parent >= 0 else { throw ArchiveFailure(code: 7, path: item, reason: .parentOpen, systemError: errno) }
        defer { close(parent) }
        var s = Darwin.stat()
        guard archiveCString(parts.name, { fstatat(parent, $0, &s, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw ArchiveFailure(code: 7, path: item, reason: .entryStat, systemError: errno)
        }
        var tree = ArchiveTree()
        tree.verificationFlags = flags
        try tree.walk(parent: parent, name: parts.name, relative: parts.name, absolute: item, device: s.st_dev, depth: 0, hashFiles: hashFiles)
        tree.facts.isSidecar = tree.excludedSidecars.contains(parts.name)
        tree.facts.mutationAncestrySafe = mutationAncestryIsSafe(item)
        return tree
    }
    mutating func walk(parent: Int32, name: Data, relative: Data, absolute: Data, device: Int32, depth: Int, hashFiles: Bool) throws {
        func bad(_ reason: ArchiveFailureReason, _ systemError: Int32? = nil) -> ArchiveFailure {
            ArchiveFailure(code: 7, path: relative, reason: reason, systemError: systemError)
        }
        var s = Darwin.stat()
        guard depth <= 256 else { throw bad(.depthLimit) }
        guard archiveCString(name, { fstatat(parent, $0, &s, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw bad(.entryStat, errno) }
        guard s.st_dev == device else { throw bad(.deviceChanged) }
        guard s.st_flags & UInt32(SF_DATALESS) == 0 else { throw bad(.dataless) }
        guard s.st_size >= 0 else { throw bad(.negativeSize) }
        let before = ArchiveStamp(s), kind = s.st_mode & S_IFMT
        stamps[absolute] = before
        // Keep identity stamps for excluded metadata; the executor still rechecks it.
        do {
            if try archivePairedSidecar(parent: parent, name: name, stamp: s, flags: verificationFlags) {
                excludedSidecars.insert(relative); return
            }
        } catch let failure as ArchiveFailure { throw bad(failure.reason, failure.systemError) }
        if name.starts(with: Data("._".utf8)) { facts.containsRealAppleDouble = true }
        if kind == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: 65536)
            let n = archiveCString(name) { readlinkat(parent, $0, &bytes, bytes.count) }
            guard n >= 0 else { throw bad(.linkRead, errno) }
            guard n < bytes.count else { throw bad(.linkTooLong) }
            let target = Data(bytes.prefix(n))
            entries[relative] = .link(target)
            stamps[absolute]?.linkTarget = target
        } else if kind == S_IFREG || kind == S_IFDIR {
            let fd = archiveCString(name) { openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0)) }
            guard fd >= 0 else { throw bad(.entryOpen, errno) }; defer { close(fd) }
            var opened = Darwin.stat()
            guard fstat(fd, &opened) == 0 else { throw bad(.openedStat, errno) }
            guard ArchiveStamp(opened) == before else { throw bad(.openedStampChanged) }
            if kind == S_IFDIR {
                let duplicate = dup(fd)
                guard duplicate >= 0 else { throw bad(.directoryDuplicate, errno) }
                guard let directory = fdopendir(duplicate) else {
                    let code = errno; close(duplicate); throw bad(.directoryOpen, code)
                }
                defer { closedir(directory) }
                while true {
                    errno = 0
                    guard let entry = readdir(directory) else { if errno != 0 { throw bad(.directoryRead, errno) }; break }
                    let child = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(Int(entry.pointee.d_namlen))) }
                    if child == Data(".".utf8) || child == Data("..".utf8) { continue }
                    try walk(parent: fd, name: child, relative: relative + Data([47]) + child,
                        absolute: absolute + Data([47]) + child, device: device, depth: depth + 1, hashFiles: hashFiles)
                }
                entries[relative] = .directory
            } else {
                files.append((absolute, UInt64(s.st_size)))
                let (sum, overflow) = facts.eligibleBytes.addingReportingOverflow(UInt64(s.st_size))
                guard !overflow else { throw bad(.sizeOverflow) }; facts.eligibleBytes = sum
                let fork = fgetxattr(fd, "com.apple.ResourceFork", nil, 0, 0, 0)
                if fork > 0 { facts.hasResourceFork = true }
                else if fork < 0 && errno != ENOATTR { throw bad(.resourceFork, errno) }
                if hashFiles {
                    let size: UInt64, digest: Data
                    do { (size, digest) = try archiveHash(fd) }
                    catch { throw bad(.fileRead, Int32(clamping: (error as NSError).code)) }
                    guard size == UInt64(s.st_size) else { throw bad(.readSizeChanged) }
                    entries[relative] = .file(size, digest)
                } else { entries[relative] = .file(UInt64(s.st_size), Data()) }
            }
            var after = Darwin.stat()
            guard fstat(fd, &after) == 0 else { throw bad(.finalDescriptorStat, errno) }
            guard ArchiveStamp(after) == before else { throw bad(.finalDescriptorStampChanged) }
        } else { throw bad(.unsupportedType) }
        var after = Darwin.stat()
        guard archiveCString(name, { fstatat(parent, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw bad(.finalPathStat, errno) }
        guard ArchiveStamp(after) == before else { throw bad(.finalPathStampChanged) }
    }
}

enum ArchiveFailureReason: String, Codable, Sendable {
    case archiveEntry, volumeStat, volumeType, parentOpen, entryStat, depthLimit, deviceChanged, dataless, negativeSize
    case sidecarLookup, linkRead, linkTooLong, entryOpen, openedStat, openedStampChanged
    case directoryDuplicate, directoryOpen, directoryRead, sizeOverflow, resourceFork, fileRead, readSizeChanged
    case finalDescriptorStat, finalDescriptorStampChanged, unsupportedType, finalPathStat, finalPathStampChanged
}
struct ArchiveFailure: Error, LocalizedError {
    let code: Int32
    let path: Data
    var reason: ArchiveFailureReason = .archiveEntry
    var systemError: Int32? = nil
    var errorDescription: String? {
        "ArchiveFailure code \(code), check \(reason.rawValue), errno \(systemError.map(String.init) ?? "none"), pathBase64 \(path.base64EncodedString())"
    }
}

public enum AppleArchiveCompression: Sendable { case lzfse, lzma }
public protocol AppleArchiveWriter: Sendable {
    func write(item: Data, to fd: Int32, compression: AppleArchiveCompression) throws -> UInt64
}
public struct ProductionAppleArchiveWriter: AppleArchiveWriter {
    public init() {}
    public func write(item: Data, to fd: Int32, compression: AppleArchiveCompression) throws -> UInt64 {
        let parts = try archiveParts(item)
        var info = Darwin.stat()
        guard archiveCString(item, { fstatat(AT_FDCWD, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG else { throw archiveError(ESTALE) }
        // The directory helper omits a regular-file root. Use the SDK's explicit
        // single-path list for files, and recursive directory contents for folders.
        let paths = archiveCString(parts.parent) { directory in archiveCString(parts.name) { name in
            info.st_mode & S_IFMT == S_IFDIR
                ? __AAPathListCreateWithDirectoryContents(directory, name, nil, nil, 0, 0)
                : __AAPathListCreateWithPath(directory, name)
        } }
        guard let paths else { throw archiveError() }; defer { __AAPathListDestroy(paths) }
        guard let keys = __AAFieldKeySetCreateWithString("TYP,PAT,LNK,DEV,UID,GID,MOD,FLG,MTM,BTM,CTM,XAT,ACL,DAT,HLC,CLC") else { throw archiveError() }
        defer { __AAFieldKeySetDestroy(keys) }
        guard let file = __AAFileStreamOpenWithFD(fd, 0) else { throw archiveError() }
        var fileOpen = true; defer { if fileOpen { _ = __AAByteStreamClose(file) } }
        guard let compressed = __AACompressionOutputStreamOpen(file,
            (compression == .lzfse ? __AA_COMPRESSION_ALGORITHM_LZFSE : __AA_COMPRESSION_ALGORITHM_LZMA).rawValue, 1 << 20, 0, 0) else { throw archiveError() }
        var compressedOpen = true; defer { if compressedOpen { _ = __AAByteStreamClose(compressed) } }
        guard let encoder = __AAEncodeArchiveOutputStreamOpen(compressed, nil, nil, 0, 0) else { throw archiveError() }
        var encoderOpen = true; defer { if encoderOpen { _ = __AAArchiveStreamClose(encoder) } }
        let status = archiveCString(parts.parent) { __AAArchiveStreamWritePathList(encoder, paths, keys, $0, nil, nil, 0, 0) }
        let encoded = __AAArchiveStreamClose(encoder); encoderOpen = false
        let flushed = __AAByteStreamClose(compressed); compressedOpen = false
        let closed = __AAByteStreamClose(file); fileOpen = false
        guard status == 0, encoded == 0, flushed == 0, closed == 0 else { throw archiveError() }
        let offset = lseek(fd, 0, SEEK_CUR)
        guard offset >= 0 else { throw archiveError(errno) }; return UInt64(offset)
    }
}

// Match the Rust verifier: byte-exact paths, ASCII-case + NFD only for the
// metadata collision guard, duplicate rejection before any metadata exemption.
func archiveEntryPath(_ raw: Data) throws -> Data {
    guard raw.first != 47, !raw.contains(0), !raw.split(separator: 47).contains(Data("..".utf8)) else {
        throw ArchiveFailure(code: 8, path: raw)
    }
    let parts = raw.split(separator: 47).filter { $0 != Data(".".utf8) }
    guard !parts.isEmpty else { throw ArchiveFailure(code: 8, path: raw) }
    return Data(parts.joined(separator: [UInt8(47)]))
}
func archiveCollisionKey(_ raw: Data) -> Data {
    // Normalize each valid UTF-8 run; retain invalid bytes verbatim, as Rust does.
    let bytes = Array(raw); var result = Data(), start = 0
    while start < bytes.count {
        var end = start
        while end < bytes.count {
            let lead = bytes[end]
            let length = lead < 128 ? 1 : lead >= 194 && lead <= 223 ? 2 : lead >= 224 && lead <= 239 ? 3 : lead >= 240 && lead <= 244 ? 4 : 0
            guard length > 0, end + length <= bytes.count,
                  String(bytes: bytes[end..<(end + length)], encoding: .utf8) != nil else { break }
            end += length
        }
        if end > start {
            let normalized = String(bytes: bytes[start..<end], encoding: .utf8)!.decomposedStringWithCanonicalMapping
            result.append(contentsOf: normalized.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
        }
        if end < bytes.count { result.append(bytes[end]); end += 1 }
        start = end
    }
    return result
}
func archiveMetadataPath(_ path: Data) -> Bool {
    let parts = path.split(separator: 47)
    return parts.last?.starts(with: Data("._".utf8)) == true || parts.contains(Data("__MACOSX".utf8))
}

public func verifyAppleArchive(fd: Int32, item: Data, flags: UInt32 = 0) -> ArchiveVerdict {
    do {
        let tree = try ArchiveTree.scan(item, hashFiles: true, flags: flags)
        var manifest = tree.entries, seen: Set<Data> = [], collisions = Set(manifest.keys.map(archiveCollisionKey))
        let excludedCollisions = Set(tree.excludedSidecars.map(archiveCollisionKey))
        var groups: [String: ArchiveContent] = [:], ignoredGroups: Set<String> = []
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ArchiveFailure(code: 9, path: Data()) }
        try ArchiveByteStream.withFileStream(fd: FileDescriptor(rawValue: fd), automaticClose: false) { file in
            try ArchiveByteStream.withDecompressionStream(readingFrom: file) { bytes in
                try ArchiveStream.withDecodeStream(readingFrom: bytes) { stream in
                    while let header = try stream.readHeader() {
                        guard Set(header.map { $0.key }).count == header.count else { throw ArchiveFailure(code: 8, path: Data()) }
                        guard let raw = rawAppleArchiveString(header, key: "PAT") else { throw ArchiveFailure(code: 8, path: Data()) }
                        let path = try archiveEntryPath(raw), matched = manifest[path] != nil
                        guard seen.insert(path).inserted else { throw ArchiveFailure(code: 10, path: path) }
                        let key = archiveCollisionKey(path)
                        if !tree.excludedSidecars.contains(path) && excludedCollisions.contains(key) { throw ArchiveFailure(code: 2, path: path) }
                        if !matched && archiveMetadataPath(path) && collisions.contains(key) { throw ArchiveFailure(code: 2, path: path) }
                        collisions.insert(key)
                        if !matched && !archiveMetadataPath(path) { throw ArchiveFailure(code: 2, path: path) }
                        var entryGroups: [String] = []
                        for name in ["HLC", "CLC", "SLC"] {
                            if let field = header.field(forKey: ArchiveHeader.FieldKey(name)) {
                                guard case .uint(_, let id) = field else { throw ArchiveFailure(code: 8, path: path) }
                                entryGroups.append(name + ":" + String(id))
                            }
                        }
                        if let field = header.field(forKey: ArchiveHeader.FieldKey("DAT")) {
                            guard case .blob = field else { throw ArchiveFailure(code: 8, path: path) }
                        }
                        var dataSize: UInt64?, dataDigest: Data?
                        // Drain every blob, including metadata on ignored sidecars.
                        for field in header {
                            guard case .blob(let blobKey, let size, _) = field else { continue }
                            var digest = SHA256(), remaining = size
                            var buffer = [UInt8](repeating: 0, count: 65536)
                            while remaining > 0 {
                                let count = Int(min(remaining, UInt64(buffer.count)))
                                try buffer.withUnsafeMutableBytes { try stream.readBlob(key: blobKey, into: UnsafeMutableRawBufferPointer(rebasing: $0[..<count])) }
                                if blobKey == ArchiveHeader.FieldKey("DAT"), matched { digest.update(data: Data(buffer.prefix(count))) }
                                remaining -= UInt64(count)
                            }
                            if blobKey == ArchiveHeader.FieldKey("DAT") { dataSize = size; dataDigest = Data(digest.finalize()) }
                        }
                        if !matched {
                            // Unhashed metadata must never supply or alter a real file's cluster.
                            guard !entryGroups.contains(where: { groups[$0] != nil }) else { throw ArchiveFailure(code: 2, path: path) }
                            ignoredGroups.formUnion(entryGroups)
                            continue
                        }
                        guard !entryGroups.contains(where: { ignoredGroups.contains($0) }) else { throw ArchiveFailure(code: 2, path: path) }
                        if !entryGroups.isEmpty && header.entryType != .regularFile { throw ArchiveFailure(code: 8, path: path) }
                        let content: ArchiveContent
                        switch header.entryType {
                        case .directory?: content = .directory
                        case .link?:
                            // Read LNK as raw encoded string bytes; Swift String would repair invalid UTF-8.
                            guard let target = rawAppleArchiveString(header, key: "LNK") else { throw ArchiveFailure(code: 8, path: path) }
                            content = .link(target)
                        case .regularFile?:
                            if let dataSize, let dataDigest { content = .file(dataSize, dataDigest) }
                            else if !entryGroups.isEmpty {
                                guard let prior = entryGroups.compactMap({ groups[$0] }).first else { throw ArchiveFailure(code: 8, path: path) }
                                content = prior
                            } else { content = .file(0, Data(SHA256.hash(data: Data()))) }
                        default: throw ArchiveFailure(code: 5, path: path)
                        }
                        // Native extraction uses the first DAT in a cluster, even when a
                        // later member declares different bytes. Require coherent contents.
                        for key in entryGroups {
                            guard groups[key] == nil || groups[key] == content else { throw ArchiveFailure(code: 8, path: path) }
                            groups[key] = content
                        }
                        let want = manifest.removeValue(forKey: path)!
                        switch (want, content) {
                        case (.file(let a, _), .file(let b, _)) where a != b: throw ArchiveFailure(code: 3, path: path)
                        case (.file, .file) where want != content: throw ArchiveFailure(code: 4, path: path)
                        case (.link, .link) where want != content: throw ArchiveFailure(code: 6, path: path)
                        case (.file, .file), (.directory, .directory), (.link, .link): break
                        default: throw ArchiveFailure(code: 5, path: path)
                        }
                    }
                }
            }
        }
        if let missing = manifest.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }).first { throw ArchiveFailure(code: 1, path: missing) }
        var result = ArchiveVerdict()
        for content in tree.entries.values {
            switch content { case .file(let size, _): result.files += 1; result.bytes += size
            case .directory: result.dirs += 1; case .link: result.links += 1 }
        }
        return result
    } catch let failure as ArchiveFailure { return ArchiveVerdict(code: failure.code, firstBadPath: failure.path) }
    catch { return ArchiveVerdict(code: 8) }
}
func rawAppleArchiveString(_ header: ArchiveHeader, key: String) -> Data? {
    header.withAAEncodedData { encoded in
        guard let raw = __AAHeaderCreateWithEncodedData(encoded.count, encoded.baseAddress!) else { return nil }
        defer { __AAHeaderDestroy(raw) }
        let bytes = Array(key.utf8)
        let fieldKey = __AAFieldKey(ikey: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16)
        let index = __AAHeaderGetKeyIndex(raw, fieldKey)
        guard index >= 0 else { return nil }
        var count = 0
        guard __AAHeaderGetFieldString(raw, UInt32(index), 0, nil, &count) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: count + 1)
        guard __AAHeaderGetFieldString(raw, UInt32(index), buffer.count, &buffer, &count) == 0 else { return nil }
        return buffer.withUnsafeBytes { Data($0.prefix(count)) }
    }
}

public protocol ArchiveVerifier: Sendable {
    func verify(fd: Int32, path: Data, format: ArchiveFormat, item: Data) -> ArchiveVerdict
}
public struct ProductionArchiveVerifier: ArchiveVerifier {
    private let verificationFlags: @Sendable (Data) throws -> UInt32
    public init() { self.init(verificationFlags: { try archiveVerificationFlags($0) }) }
    init(verificationFlags: @escaping @Sendable (Data) throws -> UInt32) { self.verificationFlags = verificationFlags }
    public func verify(fd: Int32, path: Data, format: ArchiveFormat, item: Data) -> ArchiveVerdict {
        let flags: UInt32
        do { flags = try verificationFlags(item) }
        catch { return ArchiveVerdict(code: 7, firstBadPath: item) }
        if format == .appleArchiveFast || format == .appleArchiveSmallest { return verifyAppleArchive(fd: fd, item: item, flags: flags) }
        var report = TessArchiveReport()
        let code = path.withUnsafeBytes { archive in item.withUnsafeBytes { original in
            tess_archive_verify(archive.baseAddress!.assumingMemoryBound(to: UInt8.self), archive.count,
                format == .zip ? 0 : format == .tarXZ ? 1 : 2,
                original.baseAddress!.assumingMemoryBound(to: UInt8.self), original.count, flags, &report)
        } }
        let bad = withUnsafeBytes(of: report.first_bad_path) { Data($0.prefix(min(report.first_bad_len, 1024))) }
        return ArchiveVerdict(code: code, files: report.files, dirs: report.dirs, links: report.links, bytes: report.bytes,
            firstBadPath: bad, firstBadLength: report.first_bad_len)
    }
}
