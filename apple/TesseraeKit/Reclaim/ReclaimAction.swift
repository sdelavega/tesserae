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

public enum ReclaimAction: Hashable, Sendable {
    case trash, compress, archive(ArchiveFormat)
}

public enum Availability: Equatable, Sendable {
    case available, unavailable(String)
}

public struct VolumeCapabilities: Sendable {
    public let isLocal, isWritable: Bool
    public let fsType: String
    public init(isLocal: Bool, isWritable: Bool, fsType: String) {
        self.isLocal = isLocal; self.isWritable = isWritable; self.fsType = fsType
    }
    public var canCompress: Bool { isLocal && isWritable && (fsType == "apfs" || fsType == "hfs") }
    public var canArchive: Bool { isWritable }
}

// Fresh walk evidence: dot-underscore content includes every such entry on
// native and unknown filesystems; only strictly recognized sidecars are excluded.
public struct ArchiveItemFacts: Equatable, Sendable {
    public var containsCloudOnly, containsUnknownContent, containsOtherVolume, parentWritable: Bool
    public var mutationAncestrySafe = true
    public var containsAppBundle = false
    public var isSidecar = false
    public var hasResourceFork, containsRealAppleDouble, containsGitWorkingTree: Bool
    public var largestFileSize, eligibleBytes: UInt64
    public init(containsCloudOnly: Bool = false, containsUnknownContent: Bool = false,
                containsOtherVolume: Bool = false, parentWritable: Bool = true,
                hasResourceFork: Bool = false, containsRealAppleDouble: Bool = false,
                containsGitWorkingTree: Bool = false, largestFileSize: UInt64 = 0, eligibleBytes: UInt64 = 0) {
        self.containsCloudOnly = containsCloudOnly; self.containsUnknownContent = containsUnknownContent
        self.containsOtherVolume = containsOtherVolume; self.parentWritable = parentWritable
        self.hasResourceFork = hasResourceFork; self.containsRealAppleDouble = containsRealAppleDouble
        self.containsGitWorkingTree = containsGitWorkingTree
        self.largestFileSize = largestFileSize; self.eligibleBytes = eligibleBytes
    }
}

public func formatSupports(_ f: ArchiveFormat, itemFacts: ArchiveItemFacts) -> Availability {
    if !itemFacts.mutationAncestrySafe { return .unavailable(unsafeMutationFolderReason()) }
    if itemFacts.isSidecar {
        return .unavailable(String(localized: "archive.sidecarItem",
            defaultValue: "This item is a macOS metadata sidecar. Archive its sibling instead.", bundle: L10n.bundle,
            comment: "Archive is disabled when the selected item itself is a recognized AppleDouble metadata sidecar."))
    }
    if itemFacts.containsCloudOnly { return .unavailable(reasonText(.containsCloudOnly)) }
    if itemFacts.containsUnknownContent { return .unavailable(reasonText(.containsUnknownSize)) }
    if itemFacts.containsOtherVolume { return .unavailable(reasonText(.containsOtherVolume)) }
    // ArchiveTree excludes only hidden, paired files with the full header up to 16 MiB
    // on sidecar volumes; every other dot-underscore entry needs literal storage.
    if itemFacts.containsRealAppleDouble && f != .appleArchiveFast && f != .appleArchiveSmallest {
        return .unavailable(String(localized: "archive.realAppleDouble",
            defaultValue: "Contains macOS metadata files this format can't store.", bundle: L10n.bundle,
            comment: "Disable an archive format that cannot preserve dot-underscore content, including orphan sidecars."))
    }
    return .available
}

public func availableActions(for item: ReclaimItem, volume: VolumeCapabilities, verdict: Verdict) -> [ReclaimAction: Availability] {
    if case .denied = verdict { return [:] }
    if case .denied = item.verdict { return [:] }
    let readOnly = String(localized: "reclaimAction.readOnly", defaultValue: "This disk is read-only.",
                          bundle: L10n.bundle, comment: "Disabled action on a read-only volume.")
    var actions: [ReclaimAction: Availability] = [.trash: volume.isWritable ? .available : .unavailable(readOnly),
        .compress: volume.canCompress ? .available : .unavailable(String(localized: "reclaimAction.cannotCompress",
            defaultValue: "This disk can't compress files in place. Archive instead?", bundle: L10n.bundle,
            comment: "Disabled in-place compression on an unsupported volume."))]
    if !item.archiveFacts.mutationAncestrySafe { actions[.compress] = .unavailable(unsafeMutationFolderReason()) }
    var facts = item.archiveFacts
    let warnings = itemWarnings(item) + { if case .warn(let r) = verdict { return [r] }; return [] }()
    facts.containsCloudOnly = facts.containsCloudOnly || warnings.contains(.cloudOnly) || warnings.contains(.containsCloudOnly)
    facts.containsUnknownContent = facts.containsUnknownContent || item.hasUnknownContent || item.recordedSize == nil || warnings.contains(.containsUnknownSize)
    facts.containsOtherVolume = facts.containsOtherVolume || warnings.contains(.containsOtherVolume)
    let name = foldedComponents(item.path).last ?? Data()
    let isArchive = !item.recorded.isDirectory && [".zip", ".tar.xz", ".tar.zst", ".aar"].contains { name.suffix($0.utf8.count) == Data($0.utf8) }
    for format in ArchiveFormat.allCases {
        let availability: Availability
        if !facts.mutationAncestrySafe { availability = .unavailable(unsafeMutationFolderReason()) }
        else if !volume.canArchive { availability = .unavailable(readOnly) }
        else if !facts.parentWritable {
            availability = .unavailable(String(localized: "reclaimAction.parentNotWritable",
                defaultValue: "The item's parent folder isn't writable.", bundle: L10n.bundle,
                comment: "Archive must be created beside the original item."))
        } else if isArchive { availability = .unavailable(reasonText(.isArchive)) }
        else { availability = formatSupports(format, itemFacts: facts) }
        actions[.archive(format)] = availability
    }
    return actions
}

public func actionWarnings(for item: ReclaimItem, action: ReclaimAction, facts: ArchiveItemFacts) -> [Reason] {
    guard action == .compress else { return [] }
    var reasons: [Reason] = []
    if facts.containsAppBundle || foldedComponents(item.path).contains(where: { $0.suffix(4) == Data(".app".utf8) }) { reasons.append(.appBundleCompress) }
    if facts.containsGitWorkingTree { reasons.append(.gitWorkingTree) }
    if facts.largestFileSize > 4 * 1024 * 1024 * 1024 { reasons.append(.largeFile) }
    if facts.eligibleBytes > 100_000_000_000 { reasons.append(.largeCompressRun) }
    return reasons
}

func unsafeMutationFolderReason() -> String {
    String(localized: "reclaimAction.unsafeMutationFolder",
        defaultValue: "Another user can change files in this folder, so Tesserae can't safely compress or archive here.",
        bundle: L10n.bundle, comment: "Compress and Archive are disabled when another local user can replace path entries.")
}

// The superuser is trusted: ordinary home paths have root-owned system ancestors.
// Sticky protection applies only when neither the directory owner nor the child
// entry owner is a different unprivileged user. All observations are fresh lstat.
func mutationAncestryIsSafe(_ path: Data, volumeRoot suppliedRoot: Data? = nil,
                           user: UInt32 = geteuid(), stat: any FileStat = ProductionFileStat()) -> Bool {
    func canonical(_ p: Data) -> Bool {
        p.first == 47 && !p.contains(0) && !p.split(separator: 47).contains { $0 == Data(".".utf8) || $0 == Data("..".utf8) }
    }
    guard canonical(path) else { return false }
    var root: Data
    if let suppliedRoot { root = suppliedRoot }
    else {
        var info = statfs()
        guard (path + Data([0])).withUnsafeBytes({ statfs($0.baseAddress!.assumingMemoryBound(to: CChar.self), &info) }) == 0 else { return false }
        root = withUnsafeBytes(of: &info.f_mntonname) { Data($0.prefix { $0 != 0 }) }
    }
    let physicalRoot = root
    let dataRoot = Data("/System/Volumes/Data".utf8)
    if root == dataRoot && !path.starts(with: dataRoot + Data([47])) { root = Data([47]) }
    guard canonical(root), path.starts(with: root == Data([47]) ? root : root + Data([47])),
          case .ok(var childInfo, _, false) = stat.lstat(path) else { return false }
    var child = path
    while child != root {
        guard let slash = child.lastIndex(of: 47) else { return false }
        let parent = slash == child.startIndex ? Data([47]) : Data(child[..<slash])
        let probe = parent == root ? physicalRoot : parent
        guard case .ok(let info, _, false) = stat.lstat(probe), info.isDirectory,
              info.owner == user || info.owner == 0 else { return false }
        let permissions = mode_t(info.permissions)
        if permissions & (S_IWGRP | S_IWOTH) != 0 {
            guard permissions & S_ISVTX != 0, childInfo.owner == user || childInfo.owner == 0 else { return false }
        }
        child = parent
        childInfo = info
        if child == Data([47]) && root != child { return false }
    }
    return true
}
