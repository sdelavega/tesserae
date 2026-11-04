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
import Foundation
import TesseraeFFI

/// What a scan summary keeps. Only nodes at or above these sizes are
/// recorded, so a summary of a whole disk stays small. Sizes roll up, so a
/// recorded node's parent is always large enough to be recorded as well.
public struct ScanHistoryPolicy: Equatable, Sendable {
    public var minimumDirectory: UInt64 = 1 << 20
    public var minimumFile: UInt64 = 64 << 20
    /// The most entries one summary holds; the largest are kept.
    public var limit = 200_000
    /// A change smaller than this, or than 1% of the earlier size, is noise.
    public var significant: UInt64 = 1 << 20

    public init() {}
}

/// A compact record of one complete scan, kept so a later scan of the same
/// location can be compared with it. Paths are relative to the scan root, as
/// raw name bytes joined by `/` (the root itself is the empty path), so
/// non-UTF-8 names survive.
public struct ScanSummary: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public let version: Int
    public let rootPath: Data
    public let scannedAt: Date
    public let limited: Bool
    public let paths: [Data]
    public let allocated: [UInt64]

    public init(rootPath: Data, scannedAt: Date, limited: Bool, paths: [Data], allocated: [UInt64]) {
        precondition(paths.count == allocated.count, "ScanSummary: one size per path")
        version = Self.formatVersion
        self.rootPath = rootPath
        self.scannedAt = scannedAt
        self.limited = limited
        self.paths = paths
        self.allocated = allocated
    }
}

/// One file per scanned location, holding the summary of its latest complete
/// scan. Files are named by a SHA-256 of the root's raw path bytes.
public struct ScanHistoryStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Tesserae/Scan History`.
    public static var production: ScanHistoryStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ScanHistoryStore(directory: base.appendingPathComponent("Tesserae", isDirectory: true)
            .appendingPathComponent("Scan History", isDirectory: true))
    }

    func fileURL(for root: Data) -> URL {
        let name = SHA256.hash(data: root).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".plist", isDirectory: false)
    }

    /// The stored summary for `root`, or nil when there is none or it cannot
    /// be read as this version's format.
    public func load(root: Data) -> ScanSummary? {
        guard let data = try? Data(contentsOf: fileURL(for: root)),
              let summary = try? PropertyListDecoder().decode(ScanSummary.self, from: data),
              summary.version == ScanSummary.formatVersion, summary.rootPath == root,
              summary.paths.count == summary.allocated.count else { return nil }
        return summary
    }

    public func save(_ summary: ScanSummary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(summary).write(to: fileURL(for: summary.rootPath), options: .atomic)
    }
}

/// How each node changed since an earlier scan of the same location.
///
/// A node the earlier summary recorded gets its own classification; any other
/// node takes its nearest recorded ancestor's, so the whole area of a grown
/// folder shows as grown. Identity is the instance: two indexes are equal only
/// when they are the same object.
public final class ChangeIndex: @unchecked Sendable, Equatable {
    public enum Change: UInt8, CaseIterable, Sendable {
        case unchanged = 0, grewSmall, grewMedium, grewLarge, appeared, shrankSmall, shrankLarge
    }

    /// A node the growth is concentrated in, and by how much it grew (for a
    /// node that appeared, its whole size).
    public struct Growth: Equatable, Sendable {
        public let node: UInt32
        public let bytes: UInt64
        public let appeared: Bool
    }

    public let baselineDate: Date
    /// Up to five places where growth is concentrated, largest first.
    public let largestGrowth: [Growth]
    private let classes: [UInt8]

    public static func == (a: ChangeIndex, b: ChangeIndex) -> Bool { a === b }

    public func change(_ node: UInt32) -> Change {
        guard Int(node) < classes.count else { return .unchanged }
        return Change(rawValue: classes[Int(node)]) ?? .unchanged
    }

    public convenience init(snapshot s: Snapshot, baseline: ScanSummary, policy: ScanHistoryPolicy = .init()) {
        self.init(snapshot: s, entries: ScanHistory.entries(of: s, policy: policy), baseline: baseline, policy: policy)
    }

    init(snapshot s: Snapshot, entries: [ScanHistory.Entry], baseline: ScanSummary, policy: ScanHistoryPolicy) {
        baselineDate = baseline.scannedAt
        var before: [Data: UInt64] = Dictionary(minimumCapacity: baseline.paths.count)
        for (path, size) in zip(baseline.paths, baseline.allocated) { before[path] = size }
        // A baseline cut at its limit lost its smallest entries; below its
        // smallest kept size an absent path says nothing.
        let truncatedBelow = baseline.paths.count >= policy.limit ? (baseline.allocated.min() ?? 0) : 0

        var own: [UInt32: (change: Change, delta: Int64)] = Dictionary(minimumCapacity: entries.count)
        for entry in entries {
            if let old = before[entry.path] {
                let delta = Int64(clamping: entry.allocated) &- Int64(clamping: old)
                own[entry.node] = (Self.classify(delta: delta, old: old, policy: policy), delta)
            } else if entry.allocated >= truncatedBelow {
                own[entry.node] = (.appeared, Int64(clamping: entry.allocated))
            } else {
                own[entry.node] = (.unchanged, 0)
            }
        }

        let nodes = s.nodes
        var classes = [UInt8](repeating: 0, count: nodes.count)
        for i in 0..<nodes.count {
            if let mine = own[UInt32(i)] {
                classes[i] = mine.change.rawValue
            } else {
                let parent = nodes[i].parent
                if parent != UInt32.max, Int(parent) < i { classes[i] = classes[Int(parent)] }
            }
        }
        self.classes = classes

        // Where growth is concentrated: a grown node none of whose recorded
        // children accounts for half its growth, or the top of a new subtree.
        var largestChild: [UInt32: Int64] = [:]
        for (node, mine) in own where mine.delta > 0 {
            let parent = nodes[Int(node)].parent
            if parent != UInt32.max { largestChild[parent] = max(largestChild[parent] ?? 0, mine.delta) }
        }
        var candidates: [Growth] = []
        for (node, mine) in own {
            switch mine.change {
            case .appeared:
                let parent = nodes[Int(node)].parent
                if parent == UInt32.max || own[parent]?.change != .appeared {
                    candidates.append(Growth(node: node, bytes: UInt64(max(mine.delta, 0)), appeared: true))
                }
            case .grewSmall, .grewMedium, .grewLarge:
                if (largestChild[node] ?? 0) * 2 < mine.delta {
                    candidates.append(Growth(node: node, bytes: UInt64(mine.delta), appeared: false))
                }
            case .unchanged, .shrankSmall, .shrankLarge:
                break
            }
        }
        largestGrowth = Array(candidates.sorted { $0.bytes == $1.bytes ? $0.node < $1.node : $0.bytes > $1.bytes }.prefix(5))
    }

    static func classify(delta: Int64, old: UInt64, policy: ScanHistoryPolicy) -> Change {
        let magnitude = delta.magnitude
        guard magnitude >= max(policy.significant, old / 100) else { return .unchanged }
        if delta > 0 {
            if magnitude >= 1 << 30 { return .grewLarge }
            if magnitude >= 100 << 20 { return .grewMedium }
            return .grewSmall
        }
        return magnitude >= 100 << 20 ? .shrankLarge : .shrankSmall
    }
}

public enum ScanHistory {
    struct Entry: Equatable {
        let node: UInt32
        let path: Data
        let allocated: UInt64
    }

    /// Flags that make a node's size unknown or not its own.
    private static let unknownSize = UInt16(TESS_FLAG_PERM_DENIED | TESS_FLAG_SKIPPED_REQUEST | TESS_FLAG_DATALESS
        | TESS_FLAG_AGGREGATED | TESS_FLAG_SYMLINK | TESS_FLAG_HARDLINK_DUP)

    /// The nodes a summary records, with their root-relative paths. Relies on
    /// the snapshot's layout: every parent has a smaller index than its
    /// children.
    static func entries(of s: Snapshot, policy: ScanHistoryPolicy) -> [Entry] {
        guard s.root != Tile.noNode else { return [] }
        let nodes = s.nodes
        let slash = UInt8(ascii: "/")
        var paths: [UInt32: Data] = [s.root: Data()]
        var out = [Entry(node: s.root, path: Data(), allocated: nodes[Int(s.root)].allocated)]
        for i in 0..<nodes.count where UInt32(i) != s.root {
            let node = nodes[i]
            guard node.flags & unknownSize == 0, let parentPath = paths[node.parent] else { continue }
            let directory = node.flags & UInt16(TESS_FLAG_DIR) != 0
            guard node.allocated >= (directory ? policy.minimumDirectory : policy.minimumFile) else { continue }
            var path = parentPath
            if !path.isEmpty { path.append(slash) }
            path.append(s.nameBytes(UInt32(i)))
            if directory { paths[UInt32(i)] = path }
            out.append(Entry(node: UInt32(i), path: path, allocated: node.allocated))
        }
        if out.count > policy.limit {
            out = Array(out.sorted { $0.allocated == $1.allocated ? $0.node < $1.node : $0.allocated > $1.allocated }
                .prefix(policy.limit))
        }
        return out
    }

    /// A summary of `s` for storing; nil for an empty snapshot.
    public static func summary(of s: Snapshot, scannedAt: Date, limited: Bool,
                               policy: ScanHistoryPolicy = .init()) -> ScanSummary? {
        guard s.root != Tile.noNode else { return nil }
        return summary(of: s, entries: entries(of: s, policy: policy), scannedAt: scannedAt, limited: limited)
    }

    private static func summary(of s: Snapshot, entries: [Entry], scannedAt: Date, limited: Bool) -> ScanSummary {
        ScanSummary(rootPath: s.rawPath(s.root), scannedAt: scannedAt, limited: limited,
                    paths: entries.map(\.path), allocated: entries.map(\.allocated))
    }

    /// Compare `s` with the stored summary of the same location and scan mode,
    /// then store `s`'s own summary if the scan was complete. Returns nil when
    /// there is nothing earlier to compare with.
    public static func compareAndRecord(snapshot s: Snapshot, store: ScanHistoryStore, scannedAt: Date,
                                        limited: Bool, complete: Bool,
                                        policy: ScanHistoryPolicy = .init()) -> ChangeIndex? {
        guard s.root != Tile.noNode else { return nil }
        let list = entries(of: s, policy: policy)
        let root = s.rawPath(s.root)
        let index = store.load(root: root)
            .flatMap { $0.limited == limited && $0.scannedAt < scannedAt ? $0 : nil }
            .map { ChangeIndex(snapshot: s, entries: list, baseline: $0, policy: policy) }
        if complete {
            try? store.save(summary(of: s, entries: list, scannedAt: scannedAt, limited: limited))
        }
        return index
    }
}
