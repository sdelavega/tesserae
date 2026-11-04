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

import CryptoKit
import Darwin
import Foundation
import TesseraeFFI

/// Files with identical content. `members` are ordered oldest first (then by
/// node index), so the first is the natural one to keep.
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public let id: Int
    public let size: UInt64
    public let allocatedEach: UInt64
    public let members: [UInt32]

    /// What removing every copy but one could free. APFS clones already share
    /// their blocks, so for them it frees less.
    public var reclaimable: UInt64 { allocatedEach * UInt64(max(members.count - 1, 0)) }
}

/// Reads a file's content for comparison. Implementations must never cause a
/// cloud-only (dataless) file to download.
public protocol ContentReader: Sendable {
    /// SHA-256 of the first `limit` bytes of the file at `path` (all of it
    /// when nil), or nil if the file is not a regular local file of
    /// `expectedSize` bytes with `fileID`, cannot be read, or `stop` returns
    /// true.
    func digest(of path: Data, fileID: UInt64?, expectedSize: UInt64, limit: UInt64?,
                stop: () -> Bool) -> Data?
}

public struct ProductionContentReader: ContentReader {
    public init() {}

    public func digest(of path: Data, fileID: UInt64?, expectedSize: UInt64, limit: UInt64?,
                       stop: () -> Bool) -> Data? {
        guard path.first == 0x2f, !path.contains(0) else { return nil }
        let fd = (path + Data([0])).withUnsafeBytes {
            open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_flags & UInt32(SF_DATALESS) == 0,
              UInt64(info.st_size) == expectedSize else { return nil }
        if let fileID, info.st_ino != fileID { return nil }
        _ = fcntl(fd, F_NOCACHE, 1)
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var remaining = min(limit ?? expectedSize, expectedSize)
        while remaining > 0 {
            if stop() { return nil }
            let count = read(fd, buffer, Int(min(UInt64(chunk), remaining)))
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            remaining -= UInt64(count)
        }
        return Data(hasher.finalize())
    }
}

public enum DuplicateFinder {
    public static let defaultMinimumSize: UInt64 = 1 << 20
    /// Bytes compared before reading whole files.
    static let prefixBytes: UInt64 = 64 << 10

    public struct Progress: Equatable, Sendable {
        public var filesRead: Int
        public var filesToRead: Int
    }

    /// Flags that rule a file out: not a regular local file whose content
    /// this scan owns.
    private static let excluded = UInt16(TESS_FLAG_DIR | TESS_FLAG_SYMLINK | TESS_FLAG_HARDLINK_DUP
        | TESS_FLAG_PERM_DENIED | TESS_FLAG_AGGREGATED | TESS_FLAG_SKIPPED_REQUEST | TESS_FLAG_DATALESS)

    /// Files under `root` that could have a duplicate: at least `minimumSize`
    /// bytes long and sharing their length with another such file.
    static func candidates(in s: Snapshot, under root: UInt32, overlay: SizeOverlay,
                           minimumSize: UInt64) -> [[UInt32]] {
        let source = OverlaySource(s, overlay)
        guard !overlay.isDeleted(root, in: s) else { return [] }
        var bySize: [UInt64: [UInt32]] = [:]
        var stack: [UInt32] = [root]
        while let node = stack.popLast() {
            let raw = s.nodes[Int(node)]
            if raw.flags & UInt16(TESS_FLAG_DIR) != 0 {
                if raw.flags & UInt16(TESS_FLAG_PERM_DENIED | TESS_FLAG_DATALESS | TESS_FLAG_SKIPPED_REQUEST) == 0 {
                    stack.append(contentsOf: source.children(node))
                }
                continue
            }
            guard raw.flags & excluded == 0, raw.logical >= minimumSize else { continue }
            bySize[raw.logical, default: []].append(node)
        }
        return bySize.values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    /// Group the duplicates under `root`. Synchronous and slow (it reads
    /// files); `stop` is polled between and during reads, and a stopped
    /// search returns nil.
    public static func find(in s: Snapshot, under root: UInt32, overlay: SizeOverlay = SizeOverlay(),
                            minimumSize: UInt64 = defaultMinimumSize, reader: any ContentReader,
                            stop: () -> Bool = { false },
                            progress: ((Progress) -> Void)? = nil) -> [DuplicateGroup]? {
        let sizeGroups = candidates(in: s, under: root, overlay: overlay, minimumSize: minimumSize)
        var state = Progress(filesRead: 0, filesToRead: sizeGroups.reduce(0) { $0 + $1.count })
        progress?(state)

        var found: [[UInt32]] = []
        for group in sizeGroups {
            let size = s.nodes[Int(group[0])].logical
            // Compare a prefix first; only files that agree on it are read whole.
            guard let prefixed = split(group, in: s, size: size, limit: prefixBytes, reader: reader, stop: stop) else {
                return nil
            }
            if size <= prefixBytes {
                found += prefixed
            } else {
                for candidates in prefixed {
                    guard let whole = split(candidates, in: s, size: size, limit: nil, reader: reader, stop: stop) else {
                        return nil
                    }
                    found += whole
                }
            }
            state.filesRead += group.count
            progress?(state)
        }

        let groups = found.map { members -> (UInt64, UInt64, [UInt32]) in
            let ordered = members.sorted {
                let a = s.nodes[Int($0)].modified, b = s.nodes[Int($1)].modified
                return a == b ? $0 < $1 : a < b
            }
            let first = s.nodes[Int(ordered[0])]
            return (first.logical, first.allocated, ordered)
        }.sorted { a, b in
            let wasteA = a.1 * UInt64(a.2.count - 1), wasteB = b.1 * UInt64(b.2.count - 1)
            return wasteA == wasteB ? a.2[0] < b.2[0] : wasteA > wasteB
        }
        return groups.enumerated().map { index, group in
            DuplicateGroup(id: index, size: group.0, allocatedEach: group.1, members: group.2)
        }
    }

    /// `group` regrouped by the digest of each file's first `limit` bytes
    /// (all of it when nil); files that match no other are dropped.
    private static func split(_ group: [UInt32], in s: Snapshot, size: UInt64, limit: UInt64?,
                              reader: any ContentReader, stop: () -> Bool) -> [[UInt32]]? {
        var byDigest: [Data: [UInt32]] = [:]
        for node in group {
            if stop() { return nil }
            if let digest = reader.digest(of: s.rawPath(node), fileID: s.fileID(node), expectedSize: size,
                                          limit: limit, stop: stop) {
                byDigest[digest, default: []].append(node)
            }
            if stop() { return nil }
        }
        return byDigest.values.filter { $0.count > 1 }
    }

    /// Run `find` on its own thread with materialization of cloud-only files
    /// turned off for that thread, as the scan engine does. Cancelling the
    /// calling task stops the search and returns nil.
    public static func run(in s: Snapshot, under root: UInt32, overlay: SizeOverlay,
                           minimumSize: UInt64 = defaultMinimumSize,
                           reader: any ContentReader = ProductionContentReader(),
                           progress: (@Sendable (Progress) -> Void)? = nil) async -> [DuplicateGroup]? {
        let flag = StopFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[DuplicateGroup]?, Never>) in
                let thread = Thread {
                    // Values from <sys/resource.h>, as the engine's dataless.rs uses them.
                    _ = setiopolicy_np(3 /* IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES */,
                                       1 /* IOPOL_SCOPE_THREAD */, 1 /* IOPOL_MATERIALIZE_DATALESS_FILES_OFF */)
                    let result = find(in: s, under: root, overlay: overlay, minimumSize: minimumSize, reader: reader,
                                      stop: { flag.isSet }, progress: progress)
                    continuation.resume(returning: flag.isSet ? nil : result)
                }
                thread.qualityOfService = .utility
                thread.start()
            }
        } onCancel: {
            flag.set()
        }
    }
}

/// A one-way flag shared between a task and the thread doing its work.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
