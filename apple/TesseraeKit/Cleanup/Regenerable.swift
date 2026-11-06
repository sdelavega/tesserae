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

/// Folders that developer tools recreate on demand.
public enum RegenerableKind: String, CaseIterable, Sendable {
    case nodeModules, xcodeDerivedData, xcodeDeviceSupport, simulatorCaches, packageCache, swiftBuild, cacheDirectoryTag

    public var title: String {
        switch self {
        case .nodeModules: return String(localized: "regenerable.nodeModules.title", defaultValue: "Node.js packages",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: node_modules folders.")
        case .xcodeDerivedData: return String(localized: "regenerable.derivedData.title", defaultValue: "Xcode build data",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: Xcode DerivedData.")
        case .xcodeDeviceSupport: return String(localized: "regenerable.deviceSupport.title", defaultValue: "Xcode device support",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: Xcode device support files.")
        case .simulatorCaches: return String(localized: "regenerable.simulatorCaches.title", defaultValue: "Simulator caches",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: CoreSimulator caches.")
        case .packageCache: return String(localized: "regenerable.packageCache.title", defaultValue: "Package manager caches",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: Homebrew, npm, pip and similar download caches.")
        case .swiftBuild: return String(localized: "regenerable.swiftBuild.title", defaultValue: "Swift package builds",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: SwiftPM .build folders.")
        case .cacheDirectoryTag: return String(localized: "regenerable.cacheTag.title", defaultValue: "Marked as cache",
            bundle: L10n.bundle, comment: "Rebuildable folder kind: folders containing a CACHEDIR.TAG file.")
        }
    }

    /// How the folder comes back after it is removed.
    public var restoration: String {
        switch self {
        case .nodeModules: return String(localized: "regenerable.nodeModules.restore",
            defaultValue: "Reinstalled by npm install, yarn or pnpm in the project.",
            bundle: L10n.bundle, comment: "How node_modules folders are recreated.")
        case .xcodeDerivedData: return String(localized: "regenerable.derivedData.restore",
            defaultValue: "Rebuilt by Xcode the next time each project builds.",
            bundle: L10n.bundle, comment: "How Xcode DerivedData is recreated.")
        case .xcodeDeviceSupport: return String(localized: "regenerable.deviceSupport.restore",
            defaultValue: "Copied again from a device the next time it is connected for development.",
            bundle: L10n.bundle, comment: "How Xcode device support files are recreated.")
        case .simulatorCaches: return String(localized: "regenerable.simulatorCaches.restore",
            defaultValue: "Recreated by Simulator as needed.",
            bundle: L10n.bundle, comment: "How CoreSimulator caches are recreated.")
        case .packageCache: return String(localized: "regenerable.packageCache.restore",
            defaultValue: "Downloaded again by the package manager when needed.",
            bundle: L10n.bundle, comment: "How package manager caches are recreated.")
        case .swiftBuild: return String(localized: "regenerable.swiftBuild.restore",
            defaultValue: "Rebuilt by swift build or Xcode.",
            bundle: L10n.bundle, comment: "How SwiftPM .build folders are recreated.")
        case .cacheDirectoryTag: return String(localized: "regenerable.cacheTag.restore",
            defaultValue: "The tool that made it marked it as a cache it can recreate.",
            bundle: L10n.bundle, comment: "Why folders with a CACHEDIR.TAG file are rebuildable.")
        }
    }
}

public struct RegenerableItem: Identifiable, Equatable, Sendable {
    public let node: UInt32
    public let kind: RegenerableKind
    public let allocated: UInt64
    public var id: UInt32 { node }
    public var hasUnknownContent: Bool = false
    public var preselected: Bool { !hasUnknownContent }
    public var selectionReason: String? {
        guard hasUnknownContent else { return nil }
        return String(localized: "regenerable.unknownContent",
            defaultValue: "Not selected: this folder contains excluded, unreadable or cloud-only content that was not checked.",
            bundle: L10n.bundle, comment: "Why a rebuildable folder is not preselected.")
    }
}

public enum RegenerableFinder {
    public static let defaultMinimumSize: UInt64 = 1 << 20
    static let cacheTagName = Data("CACHEDIR.TAG".utf8)
    static let cacheTagSignature = Data("Signature: 8a477f597d28d172789f06886806bc55".utf8)

    /// Download caches directly in `~/Library/Caches`.
    private static let libraryCaches: Set<String> = ["homebrew", "pip", "yarn", "cocoapods", "go-build", "ms-playwright"]
    private static let deviceSupport: Set<String> = ["ios devicesupport", "watchos devicesupport", "tvos devicesupport",
                                                     "macos devicesupport", "visionos devicesupport"]

    private static func lower(_ bytes: Data) -> String {
        String(decoding: bytes.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    /// The kind of folder `node` is, given the lowercased names of its parent,
    /// grandparent and great-grandparent (empty where there is none).
    static func kind(of node: UInt32, in s: Snapshot, ancestors: [String],
                     verifyTag: (Data) -> Bool) -> RegenerableKind? {
        let name = lower(s.nameBytes(node))
        func up(_ level: Int) -> String { level < ancestors.count ? ancestors[level] : "" }
        if name == "node_modules", s.nodes[Int(node)].parent != Tile.noNode,
           s.children(s.nodes[Int(node)].parent).contains(where: {
               !s.isDirectory($0) && s.nameBytes($0) == Data("package.json".utf8)
                   && s.nodes[Int($0)].flags & UInt16(TESS_FLAG_SYMLINK | TESS_FLAG_DATALESS | TESS_FLAG_PERM_DENIED) == 0
           }) { return .nodeModules }
        if name == "deriveddata", up(0) == "xcode", up(1) == "developer" { return .xcodeDerivedData }
        if deviceSupport.contains(name), up(0) == "xcode", up(1) == "developer" { return .xcodeDeviceSupport }
        if name == "caches", up(0) == "coresimulator", up(1) == "developer" { return .simulatorCaches }
        if libraryCaches.contains(name), up(0) == "caches", up(1) == "library" { return .packageCache }
        if name == "_cacache", up(0) == ".npm" { return .packageCache }
        if name == "caches", up(0) == ".gradle" { return .packageCache }
        if name == "cache", up(0) == "registry", up(1) == ".cargo" { return .packageCache }
        if name == "store", up(0) == "pnpm", up(1) == "library" { return .packageCache }
        let children = s.children(node)
        if children.contains(where: {
            !s.isDirectory($0) && s.nameBytes($0) == cacheTagName
                && s.nodes[Int($0)].flags & UInt16(TESS_FLAG_DATALESS | TESS_FLAG_SYMLINK | TESS_FLAG_PERM_DENIED) == 0
                && verifyTag(s.rawPath($0))
        }) {
            return .cacheDirectoryTag
        }
        if name == ".build", s.nodes[Int(node)].parent != UInt32.max {
            let siblings = s.children(s.nodes[Int(node)].parent)
            if siblings.contains(where: { !s.isDirectory($0) && s.nameBytes($0) == Data("Package.swift".utf8) }) {
                return .swiftBuild
            }
        }
        return nil
    }

    /// Rebuildable folders under `root` of at least `minimumSize`, largest
    /// first. A match is not searched inside, so nested matches (a
    /// node_modules inside another) are covered by the outer one.
    public static func find(in s: Snapshot, under root: UInt32, overlay: SizeOverlay = SizeOverlay(),
                            minimumSize: UInt64 = defaultMinimumSize,
                            verifyTag: (Data) -> Bool = RegenerableFinder.readTag) -> [RegenerableItem] {
        guard root != Tile.noNode, !overlay.isDeleted(root, in: s) else { return [] }
        let source = OverlaySource(s, overlay)
        let unreadable = UInt16(TESS_FLAG_PERM_DENIED | TESS_FLAG_DATALESS | TESS_FLAG_SKIPPED_REQUEST | TESS_FLAG_SYMLINK)
        // The names above `root`, nearest first, for rules that look upward.
        var rootAncestors: [String] = []
        var cursor = s.nodes[Int(root)].parent
        while cursor != UInt32.max, rootAncestors.count < 3 {
            rootAncestors.append(lower(s.nameBytes(cursor)))
            cursor = s.nodes[Int(cursor)].parent
        }
        var found: [RegenerableItem] = []
        var stack: [(node: UInt32, ancestors: [String])] = [(root, rootAncestors)]
        while let entry = stack.popLast() {
            if Task.isCancelled { return [] }
            let node = entry.node, ancestors = entry.ancestors
            guard s.isDirectory(node), s.nodes[Int(node)].flags & unreadable == 0 else { continue }
            if let kind = kind(of: node, in: s, ancestors: ancestors, verifyTag: verifyTag) {
                let size = source.allocated(node)
                if size >= minimumSize {
                    found.append(RegenerableItem(node: node, kind: kind, allocated: size,
                        hasUnknownContent: containsUnknown(node, in: s, source: source)))
                }
                continue
            }
            let mine = Array(([lower(s.nameBytes(node))] + ancestors).prefix(3))
            for child in source.children(node) where s.isDirectory(child) {
                stack.append((child, mine))
            }
        }
        return found.sorted { $0.allocated == $1.allocated ? $0.node < $1.node : $0.allocated > $1.allocated }
    }

    private static func containsUnknown(_ root: UInt32, in s: Snapshot, source: OverlaySource) -> Bool {
        var stack = [root]
        while let node = stack.popLast() {
            if Task.isCancelled { return true }
            if s.nodes[Int(node)].flags & UInt16(TESS_FLAG_PERM_DENIED | TESS_FLAG_DATALESS
                | TESS_FLAG_SKIPPED_REQUEST | TESS_FLAG_AGGREGATED) != 0 { return true }
            if s.isDirectory(node) { stack.append(contentsOf: source.children(node)) }
        }
        return false
    }

    /// Whether the file at `path` starts with the CACHEDIR.TAG signature
    /// (https://bford.info/cachedir/). Reads at most 43 bytes.
    public static func readTag(_ path: Data) -> Bool {
        readTagOnThread(path, policy: { setiopolicy_np(3, 1, 1) == 0 })
    }

    static func readTagOnThread(_ path: Data, policy: @escaping @Sendable () -> Bool) -> Bool {
        let result = TagResult()
        let thread = Thread {
            defer { result.done.signal() }
            guard policy() else { return }
            result.value = readLocalTag(path)
        }
        thread.qualityOfService = .utility
        thread.start()
        result.done.wait()
        return result.value
    }

    private final class TagResult: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var value = false
    }

    private static func readLocalTag(_ path: Data) -> Bool {
        guard path.first == 0x2f, !path.contains(0) else { return false }
        let fd = (path + Data([0])).withUnsafeBytes {
            open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_flags & UInt32(SF_DATALESS) == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: cacheTagSignature.count)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        return count == cacheTagSignature.count && Data(buffer) == cacheTagSignature
    }
}
