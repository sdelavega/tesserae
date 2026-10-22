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

import Foundation
import TesseraeFFI

/// The ARC owner of one Rust snapshot (spec §6 "How the borrow is made safe").
///
/// Code rule: `nodes` and `names` borrow Rust memory that lives exactly as
/// long as this instance. Never let them, or a pointer taken from them,
/// outlive the `Snapshot`; never capture them in an escaping closure without
/// capturing the class.
public final class Snapshot {
    static let systemIndexReason = String(
        localized: "snapshot.system.managed.macos.index",
        defaultValue: "system-managed (macOS index)",
        bundle: L10n.bundle,
        comment: "Snapshot: system-managed (macOS index)."
    )

    public let root: UInt32
    /// Computed once while finish builds the snapshot off the main actor. 255 means no kind.
    let fileKinds: [UInt8]
    public let stats: TessScanStats
    public let stalledAt: Data?
    public struct RequestedSkip: Equatable, Sendable {
        public let path: Data
        public let reason: String
    }
    public let skippedByRequest: [RequestedSkip]
    public let unreadable: [Data]
    public let skipped: [RequestedSkip]

    /// nil only for snapshots built over Swift-owned buffers by the test seam.
    private let handle: OpaquePointer?
    private let testingOwner: AnyObject?
    private let testingFileIDs: [UInt64]
    private let _nodes: UnsafeBufferPointer<TessNode>
    private let _names: UnsafeRawBufferPointer
    private let descendantCounts: [Int32]

    #if DEBUG
    private let lock = NSLock()
    private var released = false
    private let bornAt: UInt64
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    /// How many snapshots have been released so far (process-wide).
    static var releasedCount: UInt64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return counter
    }

    /// A birth tag: the process-wide release count when this snapshot was
    /// made. Detection of use-after-release is driven by `released`, not by
    /// this value; reading it merely asserts the snapshot is still live.
    public var generation: UInt64 {
        assertLive()
        return bornAt
    }

    private func assertLive() {
        lock.lock()
        let dead = released
        lock.unlock()
        precondition(!dead, "Snapshot accessed after its Rust memory was released")
    }

    /// Release the Rust memory now, as if the borrow had outlived the owner.
    /// Debug builds only; any later access traps. Exists so the trap can be tested.
    func debugReleaseEarly() {
        releaseOnce()
    }

    private func releaseOnce() {
        lock.lock()
        let already = released
        released = true
        lock.unlock()
        guard !already else { return }
        if let handle { tess_snapshot_release(handle) }
        Snapshot.counterLock.lock()
        Snapshot.counter += 1
        Snapshot.counterLock.unlock()
    }
    #endif

    /// Takes ownership of `handle`, a snapshot from `tess_scan_finish`.
    init(handle: OpaquePointer) {
        self.handle = handle
        testingOwner = nil
        testingFileIDs = []
        var view = TessView()
        tess_snapshot_view(handle, &view)
        _nodes = UnsafeBufferPointer(start: view.nodes, count: Int(view.count))
        _names = UnsafeRawBufferPointer(start: view.names, count: Int(view.names_len))
        descendantCounts = Self.countDescendants(_nodes)
        root = view.root
        fileKinds = Self.classify(nodes: _nodes, names: _names)
        var s = TessScanStats()
        tess_snapshot_stats(handle, &s)
        stats = s
        skippedByRequest = (0..<s.skipped_by_request_count).compactMap { index in
            var length: UInt64 = 0
            var reason: UInt32 = 0
            guard let path = tess_snapshot_skipped_by_request(handle, index, &length, &reason) else { return nil }
            let description: String
            switch reason {
            case UInt32(TESS_SKIP_LIMITED_SCAN): description = String(
                localized: "snapshot.limited.scan",
                defaultValue: "limited scan",
                bundle: L10n.bundle,
                comment: "Snapshot: limited scan."
            )
            case UInt32(TESS_SKIP_NOT_PRESENT): description = String(
                localized: "snapshot.not.present",
                defaultValue: "not present",
                bundle: L10n.bundle,
                comment: "Snapshot: not present."
            )
            case UInt32(TESS_SKIP_SYSTEM_MANAGED_INDEX): description = Self.systemIndexReason
            default: description = String(
                localized: "snapshot.unknown",
                defaultValue: "unknown",
                bundle: L10n.bundle,
                comment: "Snapshot: unknown."
            )
            }
            return RequestedSkip(path: Data(bytes: path, count: Int(length)), reason: description)
        }
        unreadable = (0..<tess_snapshot_unreadable_count(handle)).compactMap { index in
            var length: UInt64 = 0
            guard let path = tess_snapshot_unreadable(handle, index, &length) else { return nil }
            return Data(bytes: path, count: Int(length))
        }
        skipped = (0..<tess_snapshot_skipped_count(handle)).compactMap { index in
            var length: UInt64 = 0
            var reason: UInt32 = 0
            guard let path = tess_snapshot_skipped(handle, index, &length, &reason) else { return nil }
            let description: String
            switch reason {
            case UInt32(TESS_SKIP_LIMITED_SCAN): description = String(
                localized: "snapshot.limited.scan",
                defaultValue: "limited scan",
                bundle: L10n.bundle,
                comment: "Snapshot: limited scan."
            )
            case UInt32(TESS_SKIP_NOT_PRESENT): description = String(
                localized: "snapshot.not.present",
                defaultValue: "not present",
                bundle: L10n.bundle,
                comment: "Snapshot: not present."
            )
            case UInt32(TESS_SKIP_SYSTEM_MANAGED_INDEX): description = Self.systemIndexReason
            case UInt32(TESS_SKIP_OTHER_VOLUME): description = String(
                localized: "snapshot.other.volume",
                defaultValue: "other volume",
                bundle: L10n.bundle,
                comment: "Snapshot: other volume."
            )
            case UInt32(TESS_SKIP_NON_LOCAL_MOUNT): description = String(
                localized: "snapshot.non.local.mount",
                defaultValue: "non-local mount",
                bundle: L10n.bundle,
                comment: "Snapshot: non-local mount."
            )
            case UInt32(TESS_SKIP_DATALESS_DIRECTORY): description = String(
                localized: "snapshot.dataless.directory",
                defaultValue: "dataless directory",
                bundle: L10n.bundle,
                comment: "Snapshot: dataless directory."
            )
            default: description = String(
                localized: "snapshot.unknown.v2",
                defaultValue: "unknown (\(reason))",
                bundle: L10n.bundle,
                comment: "Snapshot: unknown ({reason})."
            )
            }
            return RequestedSkip(path: Data(bytes: path, count: Int(length)), reason: description)
        }
        var len: UInt64 = 0
        if let p = tess_snapshot_stalled_at(handle, &len) {
            stalledAt = Data(bytes: p, count: Int(len))
        } else {
            stalledAt = nil
        }
        #if DEBUG
        Snapshot.counterLock.lock()
        bornAt = Snapshot.counter
        Snapshot.counterLock.unlock()
        #endif
    }

    /// Test seam: retains the owner of its buffers (no Rust handle), so
    /// tests can present malformed nodes to the accessors' bounds checks.
    init(testingNodes nodes: UnsafeBufferPointer<TessNode>, names: UnsafeRawBufferPointer, owner: AnyObject, root: UInt32, stats: TessScanStats = TessScanStats(), unreadable: [Data] = [], skipped: [RequestedSkip] = [], stalledAt: Data? = nil, fileIDs: [UInt64] = []) {
        handle = nil
        testingOwner = owner
        precondition(fileIDs.isEmpty || fileIDs.count == nodes.count)
        testingFileIDs = fileIDs
        _nodes = nodes
        _names = names
        descendantCounts = Self.countDescendants(nodes)
        fileKinds = Self.classify(nodes: nodes, names: names)
        self.root = root
        self.stats = stats
        self.unreadable = unreadable
        self.skipped = skipped
        skippedByRequest = skipped.filter { [String(
            localized: "snapshot.limited.scan",
            defaultValue: "limited scan",
            bundle: L10n.bundle,
            comment: "Snapshot: limited scan."
        ), String(
            localized: "snapshot.not.present",
            defaultValue: "not present",
            bundle: L10n.bundle,
            comment: "Snapshot: not present."
        )].contains($0.reason) }
        self.stalledAt = stalledAt
        #if DEBUG
        bornAt = 0
        #endif
    }

    private static func classify(nodes: UnsafeBufferPointer<TessNode>, names: UnsafeRawBufferPointer) -> [UInt8] {
        nodes.map { node in
            guard node.flags & UInt16(TESS_FLAG_DIR) == 0 else { return 255 }
            let start = Int(node.name_off), end = Int(node.name_off) + Int(node.name_len)
            precondition(end <= names.count, "Snapshot name range out of range")
            return FileKind.kind(forName: Data(names[start..<end]))?.rawValue ?? 255
        }
    }

    public func fileKind(_ index: UInt32) -> FileKind? {
        _ = node(index)  // same bounds and liveness contract as the other accessors
        return FileKind(rawValue: fileKinds[Int(index)])
    }

    deinit {
        #if DEBUG
        releaseOnce()
        #else
        if let handle { tess_snapshot_release(handle) }
        #endif
    }

    public var rootDevice: Int32 { stats.root_device }

    public func fileID(_ i: UInt32) -> UInt64? {
        _ = node(i)
        guard let handle else {
            let id = testingFileIDs.isEmpty ? 0 : testingFileIDs[Int(i)]
            return id == 0 ? nil : id
        }
        var id: UInt64 = 0
        return tess_snapshot_file_id(handle, i, &id) ? id : nil
    }

    public var datalessFiles: UInt64 { stats.dataless_files }
    public var datalessDirectories: UInt64 { stats.dataless_directories }
    public var datalessItems: UInt64 { datalessFiles + datalessDirectories }
    public var datalessLogicalBytes: UInt64 { stats.dataless_logical_bytes }
    public var noMaterializeFailed: Bool { stats.no_materialize_failed != 0 }

    public func isDataless(_ i: UInt32) -> Bool {
        node(i).flags & UInt16(TESS_FLAG_DATALESS) != 0
    }

    public func isSkippedByRequest(_ i: UInt32) -> Bool {
        node(i).flags & UInt16(TESS_FLAG_SKIPPED_REQUEST) != 0
    }

    public var nodes: UnsafeBufferPointer<TessNode> {
        #if DEBUG
        assertLive()
        #endif
        return _nodes
    }

    public var names: UnsafeRawBufferPointer {
        #if DEBUG
        assertLive()
        #endif
        return _names
    }

    /// Trap (in every build) unless `i` indexes a node.
    private func node(_ i: UInt32) -> TessNode {
        let all = nodes
        precondition(Int(i) < all.count, "Snapshot node index out of range")
        return all[Int(i)]
    }

    /// The raw bytes of node `i`'s name; not necessarily UTF-8.
    public func nameBytes(_ i: UInt32) -> Data {
        let n = node(i)
        let all = names
        precondition(
            Int(n.name_off) + Int(n.name_len) <= all.count, "Snapshot name range out of range")
        guard n.name_len > 0 else { return Data() }
        return Data(all[Int(n.name_off)..<Int(n.name_off) + Int(n.name_len)])
    }

    /// Lossy UTF-8 name with C0 control characters replaced by U+FFFD; never
    /// empty. Not for display: it leaves bidi overrides, DEL, C1 and format
    /// characters alone. What the user reads is `displayName(_:)`.
    public func name(_ i: UInt32) -> String {
        Snapshot.decodeName(nameBytes(i))
    }

    static func decodeName(_ bytes: Data) -> String {
        let decoded = String(decoding: bytes, as: UTF8.self)
        var out = String.UnicodeScalarView()
        for s in decoded.unicodeScalars {
            out.append(s.value < 0x20 ? "\u{FFFD}" : s)
        }
        let result = String(out)
        return result.isEmpty ? String(
            localized: "snapshot.unnamed",
            defaultValue: "(unnamed)",
            bundle: L10n.bundle,
            comment: "Snapshot: (unnamed)."
        ) : result
    }

    /// Computed once with the snapshot, not by walking subtrees while drawing rows.
    private static func countDescendants(_ nodes: UnsafeBufferPointer<TessNode>) -> [Int32] {
        precondition(nodes.count < Int(Int32.max), "Snapshot node count must fit below Int32.max")
        var counts = [Int32](repeating: 0, count: nodes.count)
        for i in nodes.indices.reversed() {
            let parent = nodes[i].parent
            // Malformed test snapshots remain constructible; their accessors
            // enforce the structural bounds when the offending node is read.
            if Int(parent) < i { counts[Int(parent)] += counts[i] + 1 }
        }
        return counts
    }

    public func descendantCount(_ node: UInt32) -> Int {
        _ = self.node(node)
        return Int(descendantCounts[Int(node)])
    }

    /// The children of node `i`, contiguous in `nodes`; empty for a leaf.
    public func children(_ i: UInt32) -> ChildList {
        let n = node(i)
        guard n.child_count > 0 else { return ChildList(0..<0) }
        precondition(
            Int(n.child_start) + Int(n.child_count) <= nodes.count,
            "Snapshot children range out of range")
        return ChildList(n.child_start..<(n.child_start + n.child_count))
    }

    /// Node `i`, its parent, and so on up to the root, which comes last.
    ///
    /// Bounded by the node count: a parent chain longer than that has a
    /// cycle, which only a malformed snapshot can have (the freeze gives
    /// every parent a smaller index than its children). That traps, in
    /// every build, like the other accessors' checks: a path assembled from a
    /// broken chain would name the wrong file, and spinning forever would
    /// hang the main actor on a hover.
    private func ancestry(_ i: UInt32) -> [UInt32] {
        let count = nodes.count
        var chain: [UInt32] = []
        var cur = i
        while true {
            precondition(chain.count < count, "Snapshot parent chain has a cycle")
            chain.append(cur)
            let p = node(cur).parent
            if p == UInt32.max { return chain }
            cur = p
        }
    }

    /// The path of node `i` for display, with startup firmlinks shortened and
    /// the same neutralisation as other displayed paths.
    ///
    /// Display text only: it is lossy, so it may name no file, or a different
    /// one. Anything that acts
    /// on a file (reveal, copy, stage, delete) uses `rawPath(_:)` and the node
    /// index, never this.
    public func displayPath(_ i: UInt32) -> String {
        if root == UInt32.max { return "" }
        return DisplayPath.text(rawPath(i))
    }

    /// The path of node `i` as the filesystem knows it: the root's name bytes
    /// joined with each name's raw bytes (`nameBytes(_:)`) by `/`, exactly,
    /// with no decoding. This, with the node index, is a node's actionable
    /// identity (final review I1). Empty for an empty snapshot.
    public func rawPath(_ i: UInt32) -> Data {
        if root == UInt32.max { return Data() }
        let slash = UInt8(ascii: "/")
        var parts = ancestry(i).map { nameBytes($0) }
        var result = parts.removeLast()
        for p in parts.reversed() {
            if result.last != slash { result.append(slash) }
            result.append(p)
        }
        return result
    }

    public func isDirectory(_ i: UInt32) -> Bool {
        node(i).flags & UInt16(TESS_FLAG_DIR) != 0
    }

    /// Bytes of disk node `i` occupies; for a directory, rolled up over
    /// everything beneath it, so it equals the sum over its children.
    public func allocated(_ i: UInt32) -> UInt64 {
        node(i).allocated
    }
}

/// Immutable after `init` (the Rust snapshot never mutates), so it may be
/// shared across threads; the debug bookkeeping is lock-protected.
extension Snapshot: @unchecked Sendable {}
