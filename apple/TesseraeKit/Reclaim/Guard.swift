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

public enum Reason: Hashable, Sendable {
    case nonCanonicalPath, osIntegrity, systemState, appTemporaryFiles, systemManaged, timeMachineBackup,
         userAccountCore, volumeRootOrTopLevel, otherVolume, selfOrAncestorOfApp, alreadyInTrash,
         restricted, immutable, symlinkInPath, appContainer, cloudOnly, otherHardLinks,
         changedSinceScan, changedSinceReview, noRecordedIdentity, containsUnknownSize, containsCloudOnly, containsHardLinks,
         appBundleCompress, gitWorkingTree, largeFile, largeCompressRun, containsOtherVolume, isArchive
}

public enum Verdict: Equatable, Sendable {
    case ok, warn(Reason), denied(Reason)
}

public struct GuardContext: Sendable {
    public let volumeRoot: Data
    public let scanRoot: Data
    public let scanRootDevice: Int32
    public let appBundle: URL
    public let home: Data
    public let physicalHome: Data?

    public init(scanRoot: Data, volumeRoot: Data, scanRootDevice: Int32, appBundle: URL, home: Data) {
        self.volumeRoot = volumeRoot
        self.scanRoot = scanRoot
        self.scanRootDevice = scanRootDevice
        self.appBundle = appBundle
        self.home = home
        // Context construction runs off-main in production. Action paths stay untouched.
        self.physicalHome = (home + Data([0])).withUnsafeBytes { bytes in
            guard !home.contains(0), let resolved = realpath(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), nil) else { return nil }
            defer { free(resolved) }
            return Data(bytes: resolved, count: strlen(resolved))
        }
    }
}

// Read the kernel mount point, preserving bytes even for non-UTF-8 names.
// Callers supply this separately from scanRoot; verdict evaluation stays pure.
public func volumeRoot(of rawPath: Data) throws -> Data {
    guard rawPath.first == 0x2f, !rawPath.contains(0) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    var info = statfs()
    let terminated = rawPath + Data([0])
    try terminated.withUnsafeBytes { bytes in
        if statfs(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), &info) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    return withUnsafeBytes(of: &info.f_mntonname) { bytes in
        Data(bytes.prefix { $0 != 0 })
    }
}

public struct Observed: Equatable, Sendable {
    public let device: Int32
    public let flags: UInt32
    public let isDirectory: Bool
    public let linkCount: UInt16
    public let owner: UInt32
    public let permissions: UInt16

    public init(device: Int32, flags: UInt32, isDirectory: Bool, linkCount: UInt16,
                owner: UInt32 = 0, permissions: UInt16 = 0o755) {
        self.device = device
        self.flags = flags
        self.isDirectory = isDirectory
        self.linkCount = linkCount
        self.owner = owner
        self.permissions = permissions
    }
}

// Components stay as bytes: lossy UTF-8 decoding would conflate distinct names.
private func components(_ path: Data) -> [[UInt8]] {
    path.split(separator: 0x2f).map { component in
        component.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }
    }
}

private func prefix(_ parent: [[UInt8]], of child: [[UInt8]]) -> Bool {
    child.starts(with: parent)
}

private func firmlinked(_ path: [[UInt8]]) -> [[UInt8]] {
    let dataRoot = components(Data("/System/Volumes/Data".utf8))
    return prefix(dataRoot, of: path) ? Array(path.dropFirst(3)) : path
}

// Reject non-canonical input first; account cores precede the volume rule.
// Otherwise keep the brief's table order, with Trash before system-managed.
// A shared ordering also resolves conflicts across the policy and physics layers.
private let reasonOrder: [Reason] = [
    .nonCanonicalPath, .osIntegrity, .systemState, .appTemporaryFiles, .alreadyInTrash, .systemManaged,
    .timeMachineBackup, .userAccountCore, .volumeRootOrTopLevel, .otherVolume, .selfOrAncestorOfApp,
    .restricted, .immutable, .symlinkInPath, .appContainer, .cloudOnly, .otherHardLinks,
    .changedSinceScan, .changedSinceReview, .noRecordedIdentity, .containsUnknownSize, .containsCloudOnly, .containsHardLinks,
    .appBundleCompress, .gitWorkingTree, .largeFile, .largeCompressRun, .containsOtherVolume, .isArchive
]

private func priority(_ verdict: Verdict) -> Int {
    switch verdict {
    case .ok: return reasonOrder.count * 2
    case .denied(let reason): return reasonOrder.firstIndex(of: reason)!
    case .warn(let reason): return reasonOrder.count + reasonOrder.firstIndex(of: reason)!
    }
}

private func strongest(_ verdicts: [Verdict]) -> Verdict {
    verdicts.min { priority($0) < priority($1) } ?? .ok
}

private func policyVerdicts(_ rawPath: Data, _ ctx: GuardContext) -> [Verdict] {
    let realPath = components(rawPath)
    let path = firmlinked(realPath)
    let root = firmlinked(components(ctx.volumeRoot))
    let homes = ([ctx.home] + [ctx.physicalHome].compactMap { $0 }).map { firmlinked(components($0)) }
    let app = ctx.appBundle.withUnsafeFileSystemRepresentation { bytes in
        firmlinked(components(Data(bytes: bytes!, count: strlen(bytes!))))
    }
    func under(_ fixedPath: String) -> Bool {
        prefix(components(Data(fixedPath.utf8)), of: path)
    }
    func contains(_ name: String) -> Bool {
        path.contains(Array(name.utf8))
    }
    let nonCanonical = rawPath.first != 0x2f || rawPath.split(separator: 0x2f).contains {
        $0 == Data(".".utf8) || $0 == Data("..".utf8)
    }
    let containers = homes.flatMap { home in
        ["/Library/Containers", "/Library/Group Containers"].map { home + components(Data($0.utf8)) }
    }
    // Evaluate every rule before choosing the strongest verdict.
    let checks: [(Bool, Verdict)] = [
        (nonCanonical, .denied(.nonCanonicalPath)),
        (["/System", "/bin", "/sbin", "/Library/Apple"].contains(where: under)
            || (under("/usr") && !under("/usr/local")), .denied(.osIntegrity)),
        (["/private/var/db", "/cores", "/private/var/vm"].contains(where: under), .denied(.systemState)),
        (under("/private/var/folders"), .denied(.appTemporaryFiles)),
        (contains(".trash") || contains(".trashes"), .denied(.alreadyInTrash)),
        ([".trashes", ".spotlight-v100", ".fseventsd"].contains(where: contains), .denied(.systemManaged)),
        (contains("backups.backupdb"), .denied(.timeMachineBackup)),
        (homes.contains { path == $0 || path == $0 + components(Data("/Library".utf8)) }, .denied(.userAccountCore)),
        (prefix(root, of: path) && path.count <= root.count + 1, .denied(.volumeRootOrTopLevel)),
        (prefix(path, of: app) || prefix(app, of: path), .denied(.selfOrAncestorOfApp)),
        (containers.contains { prefix($0, of: path) || prefix(path, of: $0) }, .warn(.appContainer))
    ]
    return checks.filter { $0.0 }.map { $0.1 }
}

private func physicsVerdicts(_ o: Observed, _ ctx: GuardContext) -> [Verdict] {
    // Values come from the SDK's <sys/stat.h>; no stat or filesystem calls here.
    let checks: [(Bool, Verdict)] = [
        (o.device != ctx.scanRootDevice, .denied(.otherVolume)),
        (o.flags & UInt32(SF_RESTRICTED) != 0, .denied(.restricted)),
        (o.flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0, .denied(.immutable)),
        (o.flags & UInt32(SF_DATALESS) != 0, .warn(.cloudOnly)),
        (!o.isDirectory && o.linkCount > 1, .warn(.otherHardLinks))
    ]
    return checks.filter { $0.0 }.map { $0.1 }
}

public func combinedVerdict(_ rawPath: Data, _ o: Observed, _ ctx: GuardContext) -> Verdict {
    allVerdicts(rawPath, o, ctx).first ?? .ok
}

public func policyVerdict(_ rawPath: Data, _ ctx: GuardContext) -> Verdict {
    strongest(policyVerdicts(rawPath, ctx))
}

public func physicsVerdict(_ o: Observed, _ ctx: GuardContext) -> Verdict {
    strongest(physicsVerdicts(o, ctx))
}

public func allVerdicts(_ rawPath: Data, _ o: Observed, _ ctx: GuardContext) -> [Verdict] {
    let verdicts = (policyVerdicts(rawPath, ctx) + physicsVerdicts(o, ctx)).sorted { priority($0) < priority($1) }
    return verdicts.isEmpty ? [.ok] : verdicts
}

public func orderedVerdicts(_ verdicts: [Verdict]) -> [Verdict] {
    verdicts.sorted { priority($0) < priority($1) }
}
