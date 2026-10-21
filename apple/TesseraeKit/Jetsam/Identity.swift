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

public struct Recorded: Equatable, Sendable {
    public let fileID: UInt64
    public let device: Int32
    public let isDirectory: Bool

    public init(fileID: UInt64, device: Int32, isDirectory: Bool) {
        self.fileID = fileID
        self.device = device
        self.isDirectory = isDirectory
    }
}

public enum IdentityResult: Equatable, Sendable {
    case same, gone, inodeChanged, deviceChanged, nowSymlink, typeChanged
    case symlinkInPath(Data), unreadable(errno: Int32)
}

public enum StatResult: Equatable, Sendable {
    case ok(Observed, fileID: UInt64, isSymlink: Bool)
    case error(errno: Int32)
}

public protocol FileStat: Sendable {
    func lstat(_ rawPath: Data) -> StatResult
    func volumeUUID(_ rawPath: Data) -> String?
}

public extension FileStat {
    func volumeUUID(_ rawPath: Data) -> String? { nil }
}

// Keep raw filename bytes intact; Foundation string conversion can be lossy.
public struct ProductionFileStat: FileStat {
    public init() {}

    public func volumeUUID(_ rawPath: Data) -> String? {
        guard rawPath.first == 0x2f, !rawPath.contains(0) else { return nil }
        return (rawPath + Data([0])).withUnsafeBytes { bytes in
            let url = URL(fileURLWithFileSystemRepresentation: bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                          isDirectory: false, relativeTo: nil)
            return try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
    }

    public func lstat(_ rawPath: Data) -> StatResult {
        guard !rawPath.contains(0) else { return .error(errno: EINVAL) }
        var info = Darwin.stat()
        let terminated = rawPath + Data([0])
        return terminated.withUnsafeBytes { bytes in
            guard fstatat(AT_FDCWD, bytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                          &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                return .error(errno: errno)
            }
            let kind = info.st_mode & mode_t(S_IFMT)
            return .ok(Observed(device: info.st_dev, flags: info.st_flags,
                                isDirectory: kind == mode_t(S_IFDIR), linkCount: info.st_nlink),
                       fileID: info.st_ino, isSymlink: kind == mode_t(S_IFLNK))
        }
    }
}

private enum AncestorResult {
    case clear, symlink(Data), error(Int32)
}

// The item itself is checked separately. Root is a proper prefix except for /.
private func inspectAncestors(_ rawPath: Data, stat: FileStat) -> AncestorResult {
    let bytes = Array(rawPath)
    let ends = bytes.indices.filter { $0 > 0 && bytes[$0] == 0x2f }
    let prefixes = rawPath.count > 1 ? [Data([0x2f])] + ends.map { Data(bytes[..<$0]) } : []
    for prefix in prefixes {
        switch stat.lstat(prefix) {
        case .ok(_, _, let isSymlink):
            if isSymlink { return .symlink(prefix) }
        case .error(let code): return .error(code)
        }
    }
    return .clear
}

private func identityError(_ code: Int32) -> IdentityResult {
    code == ENOENT || code == ENOTDIR ? .gone : .unreadable(errno: code)
}

// The guard has already validated a canonical absolute path. These checks reduce
// ordinary filesystem churn; the Trash API cannot make the check and action atomic.
public func verifyIdentity(_ rawPath: Data, _ r: Recorded, stat: FileStat) -> IdentityResult {
    switch stat.lstat(rawPath) {
    case .error(let code): return identityError(code)
    case .ok(let observed, let fileID, let isSymlink):
        switch inspectAncestors(rawPath, stat: stat) {
        case .symlink(let component): return .symlinkInPath(component)
        case .error(let code): return identityError(code)
        case .clear: break
        }
        if isSymlink { return .nowSymlink }
        if observed.device != r.device { return .deviceChanged }
        if fileID != r.fileID { return .inodeChanged }
        if observed.isDirectory != r.isDirectory { return .typeChanged }
        return .same
    }
}

public func symlinkedAncestor(_ rawPath: Data, stat: FileStat) -> Data? {
    if case .symlink(let component) = inspectAncestors(rawPath, stat: stat) { return component }
    return nil
}

// Both restoration paths must pass this inspection, including unreadable prefixes.
func ancestorsAreSafe(_ rawPath: Data, stat: any FileStat) -> Bool {
    if case .clear = inspectAncestors(rawPath, stat: stat) { return true }
    return false
}
