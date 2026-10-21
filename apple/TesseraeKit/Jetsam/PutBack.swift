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

public enum PutBackResult: Equatable, Sendable {
    case restored, trashItemGone, trashItemChanged, originalOccupied, parentMissing, failed(String)
}

public protocol Mover: Sendable {
    func move(_ from: URL, to: URL) throws
}

public struct ProductionMover: Mover {
    private let renameExclusive: @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32
    // Retain the old stat seam to trip the collision regression if a fallback reappears.
    private let readStat: @Sendable (UnsafePointer<CChar>, UnsafeMutablePointer<Darwin.stat>) -> Int32

    public init() {
        self.init(renameExclusive: { renamex_np($0, $1, $2) })
    }

    init(renameExclusive: @escaping @Sendable (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32,
         readStat: @escaping @Sendable (UnsafePointer<CChar>, UnsafeMutablePointer<Darwin.stat>) -> Int32 = { Darwin.lstat($0, $1) }) {
        self.renameExclusive = renameExclusive
        self.readStat = readStat
    }

    public func move(_ from: URL, to: URL) throws {
        try from.withUnsafeFileSystemRepresentation { source in
            try to.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
                }
                // SDK sys/stdio.h: RENAME_EXCL = 0x00000004.
                if renameExclusive(source, destination, UInt32(RENAME_EXCL)) == 0 { return }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }
}

public func putBack(_ e: LogEntry, stat: any FileStat, mover: any Mover,
                    log: any AuditSink = JettisonLog()) -> PutBackResult {
    guard let string = e.trashURL, let trash = URL(string: string), trash.isFileURL,
          (trash.host == nil || trash.host == ""), trash.path.hasPrefix("/"),
          let trashPath = trash.withUnsafeFileSystemRepresentation({ p in p.map { Data(bytes: $0, count: strlen($0)) } }),
          trashPath.first == 0x2f else { return .failed("missing or invalid trashURL") }
    switch stat.lstat(trashPath) {
    case .error(let code):
        if code == ENOENT || code == ENOTDIR { return .trashItemGone }
        return .failed(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
    case .ok(let observed, let inode, let symlink):
        guard let uuid = e.volumeUUID, let device = e.device, let directory = e.isDirectory,
              let currentUUID = stat.volumeUUID(trashPath) else { return .failed("can't verify this volume") }
        guard inode == e.inode && !symlink && observed.device == device && observed.isDirectory == directory
                && currentUUID == uuid else { return .trashItemChanged }
    }
    guard ancestorsAreSafe(trashPath, stat: stat) else { return .failed("Unsafe Trash ancestry") }
    guard let raw = e.path.map({ Data($0.utf8) }) ?? e.pathB64.flatMap({ Data(base64Encoded: $0) }),
          raw.first == 0x2f, !raw.contains(0), raw.count > 1,
          !raw.split(separator: 0x2f).contains(where: { $0 == Data(".".utf8) || $0 == Data("..".utf8) }) else {
        return .failed("Invalid original path")
    }
    switch stat.lstat(raw) {
    case .ok: return .originalOccupied
    case .error(let code):
        guard code == ENOENT else {
            return .failed(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
        }
    }
    let parent = raw.prefix(upTo: raw.lastIndex(of: 0x2f)!)
    guard case .ok(let info, _, false) = stat.lstat(parent.isEmpty ? Data([0x2f]) : Data(parent)),
          info.isDirectory else { return .parentMissing }
    guard ancestorsAreSafe(raw, stat: stat) else { return .failed("Unsafe original ancestry") }
    let terminated = raw + Data([0])
    let original = terminated.withUnsafeBytes {
        URL(fileURLWithFileSystemRepresentation: $0.baseAddress!.assumingMemoryBound(to: CChar.self),
            isDirectory: false, relativeTo: nil)
    }
    let represented = original.withUnsafeFileSystemRepresentation { p in p.map { Data(bytes: $0, count: strlen($0)) } }
    guard represented == raw else { return .failed("File URL changed the raw path bytes") }
    do {
        try mover.move(trash, to: original)
        _ = log.append(LogEntry(ts: Date(), action: "putBack", path: e.path, pathB64: e.pathB64,
            inode: e.inode, device: e.device, volumeUUID: e.volumeUUID, isDirectory: e.isDirectory, hasUnknownContent: e.hasUnknownContent, bytes: e.bytes, trashURL: e.trashURL, result: "ok"))
        return .restored
    } catch {
        let code = (error as NSError).code
        if (error as NSError).domain == NSPOSIXErrorDomain && (code == Int(ENOTSUP) || code == Int(EINVAL)) {
            return .failed("Put Back isn't available on this volume — use Finder's Put Back")
        }
        return .failed(error.localizedDescription)
    }
}

// No suspension in a restore: validation, exclusive rename and audit stay serial.
public actor PutBackExecutor {
    public static let shared = PutBackExecutor()
    func prepare(_ nodes: [UInt32], snapshot: Snapshot, context: GuardContext, stat: any FileStat,
                 overlay: SizeOverlay, existing: [JetsamItem], sessionID: UUID? = nil) -> [JetsamItem] {
        Jetsam.prepare(nodes, in: snapshot, context: context, stat: stat, overlay: overlay, existing: existing, sessionID: sessionID)
    }

    public func restore(_ entry: LogEntry, stat: any FileStat, mover: any Mover,
                        log: any AuditSink) -> PutBackResult {
        putBack(entry, stat: stat, mover: mover, log: log)
    }
}

// Holds the operation permit across actor work AND main-actor overlay/publication.
// Actor reentrancy alone cannot serialize those two halves of an operation.
@MainActor
final class JetsamCoordinator {
    static let shared = JetsamCoordinator()
    private final class WeakModel {
        weak var value: AppModel?
        init(_ value: AppModel) { self.value = value }
    }
    private var models: [WeakModel] = []
    private var liveModels: [AppModel] {
        models.removeAll { $0.value == nil }
        return models.compactMap(\.value)
    }

    func register(_ model: AppModel) {
        _ = liveModels
        models.append(WeakModel(model))
    }

    func isScanning(containing path: Data) -> Bool {
        liveModels.contains { $0.isScanning(containing: path) }
    }

    func recordRestoration(_ path: Data, fileID: UInt64) {
        for model in liveModels { model.recordRestoration(path, fileID: fileID) }
    }

    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !active { active = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { active = false }
        else { waiters.removeFirst().resume() }
    }
}

func pathIsWithin(_ path: Data, root: Data) -> Bool {
    let prefix = root == Data([0x2f]) ? root : root + Data([0x2f])
    return path == root || path.starts(with: prefix)
}
