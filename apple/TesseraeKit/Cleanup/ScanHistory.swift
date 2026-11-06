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
import OSLog
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
    public static let formatVersion = 2

    public let version: Int
    public let rootPath: Data
    public let scannedAt: Date
    public let limited: Bool
    public let scope: Data
    public let paths: [Data]
    public let allocated: [UInt64]

    public init(rootPath: Data, scannedAt: Date, limited: Bool, paths: [Data], allocated: [UInt64], scope: Data = Data()) {
        precondition(paths.count == allocated.count, "ScanSummary: one size per path")
        version = Self.formatVersion
        self.rootPath = ExclusionFilter.normalized(rootPath)
        self.scope = scope
        self.scannedAt = scannedAt
        self.limited = limited
        self.paths = paths
        self.allocated = allocated
    }
}

/// One file per normalized location and scan mode, holding its latest complete
/// scan. At most 50 recently used locations are retained.
public struct ScanHistoryStore: Sendable {
    public let directory: URL
    public static let rootLimit = 50
    // File operations and retention are serialized across windows. Expensive
    // comparisons use a separate lock per normalized root (both modes).
    private static let lock = NSRecursiveLock()
    private final class State: @unchecked Sendable {
        var roots: [URL: NSRecursiveLock] = [:]
        var generations: [URL: UInt64] = [:]
    }
    private static let state = State()

    fileprivate func transactionLock(root: Data) -> NSRecursiveLock {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let key = fileURL(for: root).standardizedFileURL
        if let existing = Self.state.roots[key] { return existing }
        let next = NSRecursiveLock()
        Self.state.roots[key] = next
        return next
    }

    var generation: UInt64 {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.state.generations[directory.standardizedFileURL, default: 0]
    }

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

    func fileURL(for root: Data, limited: Bool = false) -> URL {
        let name = SHA256.hash(data: ExclusionFilter.normalized(root)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + (limited ? "-limited" : "-full") + ".plist")
    }

    public func load(root: Data, limited: Bool = false) -> ScanSummary? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let url = fileURL(for: root, limited: limited)
        guard let data = try? Data(contentsOf: url),
              let summary = try? PropertyListDecoder().decode(ScanSummary.self, from: data),
              summary.version == ScanSummary.formatVersion,
              summary.rootPath == ExclusionFilter.normalized(root), summary.limited == limited,
              summary.paths.count == summary.allocated.count else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return summary
    }

    public func save(_ summary: ScanSummary) throws {
        try save(summary, generation: nil)
    }

    func save(_ summary: ScanSummary, generation expected: UInt64?) throws {
        let transaction = transactionLock(root: summary.rootPath)
        transaction.lock()
        defer { transaction.unlock() }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !Task.isCancelled, expected == nil || expected == generation else { return }
        if let current = load(root: summary.rootPath, limited: summary.limited),
           current.scannedAt >= summary.scannedAt { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard !Task.isCancelled else { return }
        let encoded = try encoder.encode(summary)
        guard !Task.isCancelled else { return }
        try encoded.write(to: fileURL(for: summary.rootPath, limited: summary.limited), options: .atomic)
        // Retire legacy summaries in place on the first new-format write.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            where url.pathExtension == "plist" {
            let name = url.deletingPathExtension().lastPathComponent
            if name.count == 64 && name.allSatisfy({ $0.isHexDigit }),
               try url.resourceValues(forKeys: [.fileSizeKey]).fileSize != 0 {
                try Data().write(to: url, options: .atomic)
            }
        }
        try prune()
    }

    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]).filter {
                $0.pathExtension == "plist" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            }
        let roots = Dictionary(grouping: files) { url in
            url.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init) ?? url.lastPathComponent
        }
        let ordered = roots.values.sorted { a, b in
            func latest(_ urls: [URL]) -> Date {
                urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
            }
            return latest(a) > latest(b)
        }
        for urls in ordered.dropFirst(Self.rootLimit) {
            for url in urls { try Data().write(to: url, options: .atomic) }
        }
    }

    public func clear() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        // A comparison already running when Clear was pressed must not
        // recreate the metadata after the clear completes.
        Self.state.generations[directory.standardizedFileURL, default: 0] &+= 1
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "plist" {
            try Data().write(to: url, options: .atomic)
        }
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
        var compared = entries
        let retained = Set(entries.map(\.path))
        // Resolve only baseline paths: shrinking below an admission threshold
        // must not erase a known node's own classification.
        compared += ScanHistory.previousEntries(paths: baseline.paths.filter { !retained.contains($0) }, in: s)
        for entry in compared {
            if Task.isCancelled { break }
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
            if i & 1023 == 0, Task.isCancelled { break }
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

    private final class PathTrie {
        var path: Data?
        var children: [Data: PathTrie] = [:]
    }

    /// Resolve missing baseline entries in one traversal of the relevant
    /// parents, even when thousands of sibling folders fell below threshold.
    static func previousEntries(paths: [Data], in s: Snapshot) -> [Entry] {
        guard s.root != Tile.noNode else { return [] }
        let trie = PathTrie()
        for path in paths {
            if Task.isCancelled { return [] }
            var cursor = trie
            for component in path.split(separator: 0x2f) {
                let name = Data(component)
                if cursor.children[name] == nil { cursor.children[name] = PathTrie() }
                cursor = cursor.children[name]!
            }
            cursor.path = path
        }
        var stack = [(s.root, trie)]
        var result: [Entry] = []
        while let (node, branch) = stack.popLast() {
            if Task.isCancelled { return [] }
            guard s.nodes[Int(node)].flags & unknownSize == 0 else { continue }
            if let path = branch.path { result.append(Entry(node: node, path: path, allocated: s.nodes[Int(node)].allocated)) }
            if !branch.children.isEmpty {
                for child in s.children(node) {
                    if let next = branch.children[s.nameBytes(child)] { stack.append((child, next)) }
                }
            }
        }
        return result
    }

    /// Retain only the largest entries; parents have smaller snapshot indices.
    static func entries(of s: Snapshot, policy: ScanHistoryPolicy) -> [Entry] {
        guard s.root != Tile.noNode, policy.limit > 0 else { return [] }
        let nodes = s.nodes
        // Min-heap of node IDs; paths are constructed only for retained nodes.
        var heap: [UInt32] = []
        func smaller(_ a: UInt32, _ b: UInt32) -> Bool {
            nodes[Int(a)].allocated == nodes[Int(b)].allocated ? a > b : nodes[Int(a)].allocated < nodes[Int(b)].allocated
        }
        for i in nodes.indices {
            if Task.isCancelled { return [] }
            let id = UInt32(i), raw = nodes[i]
            guard id == s.root || raw.flags & unknownSize == 0 else { continue }
            let threshold = raw.flags & UInt16(TESS_FLAG_DIR) != 0 ? policy.minimumDirectory : policy.minimumFile
            guard id == s.root || raw.allocated >= threshold else { continue }
            var ancestor = raw.parent
            var known = true
            while ancestor != Tile.noNode {
                if nodes[Int(ancestor)].flags & unknownSize != 0 { known = false; break }
                ancestor = nodes[Int(ancestor)].parent
            }
            guard known else { continue }
            if heap.count < policy.limit {
                heap.append(id)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    if !smaller(heap[child], heap[parent]) { break }
                    heap.swapAt(child, parent); child = parent
                }
            } else if smaller(heap[0], id) {
                heap[0] = id
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, smaller(heap[child + 1], heap[child]) { child += 1 }
                    if !smaller(heap[child], heap[parent]) { break }
                    heap.swapAt(child, parent); parent = child
                }
            }
        }
        return heap.sorted().map { id in
            var components: [Data] = []
            var cursor = id
            while cursor != s.root, cursor != Tile.noNode {
                components.append(s.nameBytes(cursor)); cursor = nodes[Int(cursor)].parent
            }
            var path = Data()
            for component in components.reversed() {
                if !path.isEmpty { path.append(0x2f) }
                path.append(component)
            }
            return Entry(node: id, path: path, allocated: nodes[Int(id)].allocated)
        }
    }

    public static func isComplete(_ s: Snapshot) -> Bool {
        let stats = s.stats
        return stats.incomplete == 0 && stats.lost_entries == 0 && stats.depth_capped == 0
    }

    public static func scope(limited: Bool, exclusions: Set<Data>) -> Data {
        var data = Data([limited ? 1 : 0])
        for path in Set(exclusions.map { ExclusionFilter.normalized($0) }).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            data.append(path); data.append(0)
        }
        return Data(SHA256.hash(data: data))
    }

    /// Preserve raw path bytes and compare only the top-most unreadable set.
    static func scopeIncludingUnreadable(_ paths: [Data], base: Data) -> Data {
        let paths = Set(paths.map { ExclusionFilter.normalized($0) })
        guard !paths.isEmpty else { return base }
        let outermost = paths.filter { path in
            !paths.contains { other in
                other != path && (other == Data("/".utf8) || path.starts(with: other + Data([0x2f])))
            }
        }.sorted { $0.lexicographicallyPrecedes($1) }
        var data = base
        data.append(0)
        for path in outermost { data.append(path); data.append(0) }
        return Data(SHA256.hash(data: data))
    }

    /// A summary of `s` for storing; nil for an empty snapshot.
    public static func summary(of s: Snapshot, scannedAt: Date, limited: Bool, scope: Data = Data(),
                               policy: ScanHistoryPolicy = .init()) -> ScanSummary? {
        guard s.root != Tile.noNode else { return nil }
        return summary(of: s, entries: entries(of: s, policy: policy), scannedAt: scannedAt, limited: limited,
                       scope: scopeIncludingUnreadable(s.unreadable, base: scope))
    }

    private static func summary(of s: Snapshot, entries: [Entry], scannedAt: Date, limited: Bool, scope: Data) -> ScanSummary {
        ScanSummary(rootPath: s.rawPath(s.root), scannedAt: scannedAt, limited: limited,
                    paths: entries.map(\.path), allocated: entries.map(\.allocated), scope: scope)
    }

    /// Compare `s` with the stored summary of the same location and scan mode,
    /// then store `s`'s own summary if the scan was complete. Returns nil when
    /// there is nothing earlier to compare with.
    public static func compareAndRecord(snapshot s: Snapshot, store: ScanHistoryStore, scannedAt: Date,
                                        limited: Bool, complete: Bool, scope: Data = Data(),
                                        policy: ScanHistoryPolicy = .init()) -> ChangeIndex? {
        guard s.root != Tile.noNode, !Task.isCancelled else { return nil }
        let scope = scopeIncludingUnreadable(s.unreadable, base: scope)
        let generation = store.generation
        let root = s.rawPath(s.root)
        let transaction = store.transactionLock(root: root)
        transaction.lock()
        defer { transaction.unlock() }
        guard !Task.isCancelled, generation == store.generation else { return nil }
        let list = entries(of: s, policy: policy)
        guard !Task.isCancelled, generation == store.generation else { return nil }
        let index = store.load(root: root, limited: limited)
            .flatMap { $0.scope == scope && $0.scannedAt < scannedAt ? $0 : nil }
            .map { ChangeIndex(snapshot: s, entries: list, baseline: $0, policy: policy) }
        guard !Task.isCancelled, generation == store.generation else { return nil }
        if complete && isComplete(s) {
            do {
                try store.save(summary(of: s, entries: list, scannedAt: scannedAt, limited: limited, scope: scope),
                               generation: generation)
            } catch {
                Logger(subsystem: "com.sdelavega.Tesserae", category: "ScanHistory")
                    .error("Could not save scan history: \(error.localizedDescription, privacy: .private)")
            }
        }
        return index
    }
}
