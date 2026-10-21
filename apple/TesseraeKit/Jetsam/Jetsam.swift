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

import Combine
import Foundation
import Darwin
import TesseraeFFI

// Compact references retain the immutable snapshot; paths are materialised only
// by the execution actor, never during the subtree preparation walk.
public struct StagedDescendants: Equatable, Sendable, RandomAccessCollection {
    public typealias Index = Int
    public struct Element: Sendable {
        public let path: Data
        public let recorded: Recorded
        public let bytes: UInt64
        public let unknown: Bool
    }
    let snapshot: Snapshot?
    let overlay: SizeOverlay
    let nodes: [UInt32]
    public var startIndex: Int { nodes.startIndex }
    public var endIndex: Int { nodes.endIndex }
    public subscript(index: Int) -> Element {
        let s = snapshot!, node = nodes[index]
        return Element(path: s.rawPath(node),
            recorded: Recorded(fileID: s.fileID(node) ?? 0, device: s.rootDevice, isDirectory: s.isDirectory(node)),
            bytes: overlay.adjusted(node, in: s),
            unknown: s.isPermissionDenied(node) || s.isDataless(node) || s.isSkippedByRequest(node))
    }
    public init(snapshot: Snapshot? = nil, overlay: SizeOverlay = SizeOverlay(), nodes: [UInt32] = []) {
        precondition(snapshot != nil || nodes.isEmpty)
        self.snapshot = snapshot; self.overlay = overlay; self.nodes = nodes
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot === rhs.snapshot && lhs.nodes == rhs.nodes && lhs.overlay.revision == rhs.overlay.revision && lhs.overlay.deleted == rhs.overlay.deleted
    }
}

public struct JetsamItem: Equatable, Identifiable, Sendable {
    public var id: UInt32 { nodeIndex }
    public let overlayRevision: UInt64
    public let sessionID: UUID?
    public let nodeIndex: UInt32
    public let path: Data
    public let recorded: Recorded
    public let recordedSize: UInt64?
    public let warnings: [Reason]
    public let hasUnknownContent: Bool
    public let descendants: StagedDescendants
    public var verdict: Verdict
    public init(nodeIndex: UInt32, path: Data, recorded: Recorded, recordedSize: UInt64?,
                verdict: Verdict, warnings: [Reason] = [], hasUnknownContent: Bool = false,
                descendants: StagedDescendants = StagedDescendants(), overlayRevision: UInt64 = 0, sessionID: UUID? = nil) {
        self.overlayRevision = overlayRevision
        self.sessionID = sessionID
        self.nodeIndex = nodeIndex
        self.path = path
        self.recorded = recorded
        self.recordedSize = recordedSize
        self.verdict = verdict
        self.warnings = warnings
        self.hasUnknownContent = hasUnknownContent
        self.descendants = descendants
    }

}

// Share the item's observation with verifyIdentity and the physics guard.
// Ancestor observations still go through the supplied lstat implementation.
private struct StagingStat: FileStat {
    let path: Data
    let result: StatResult
    let base: FileStat

    func lstat(_ rawPath: Data) -> StatResult {
        rawPath == path ? result : base.lstat(rawPath)
    }
}

func hasStagedAncestor(_ node: UInt32, in snapshot: Snapshot, staged: Set<UInt32>) -> Bool {
    var current = node
    var remaining = snapshot.nodes.count
    while current != Tile.noNode {
        precondition(remaining > 0, "Snapshot parent chain has a cycle")
        remaining -= 1
        if staged.contains(current) { return true }
        current = snapshot.nodes[Int(current)].parent
    }
    return false
}

@MainActor
public final class Jetsam: ObservableObject {
    @Published public private(set) var items: [JetsamItem] = []

    let sessionID: UUID?
    public init(sessionID: UUID? = nil) { self.sessionID = sessionID }

    func publish(_ prepared: [JetsamItem]) { items = prepared }

    nonisolated static func prepare(_ nodes: [UInt32], in snapshot: Snapshot, context: GuardContext,
                                   stat: FileStat, overlay: SizeOverlay, existing: [JetsamItem], sessionID: UUID? = nil) -> [JetsamItem] {
        let source = OverlaySource(snapshot, overlay)
        var next = existing
        var staged = Set(next.map(\.nodeIndex))
        for node in nodes {
            if Task.isCancelled { return [] }
            guard Int(node) < snapshot.nodes.count, !overlay.isDeleted(node, in: snapshot) else { continue }
            let path = snapshot.rawPath(node)
            guard !path.isEmpty else { continue }
            guard !hasStagedAncestor(node, in: snapshot, staged: staged) else { continue }
            let fileID = snapshot.fileID(node)
            // Zero is the snapshot ABI's missing-identity sentinel, never a verified inode.
            let recorded = Recorded(fileID: fileID ?? 0, device: snapshot.rootDevice,
                                    isDirectory: snapshot.isDirectory(node))
            var verdict: Verdict
            var freshDataless = false
            var warnings: [Reason] = []
            if fileID == nil {
                verdict = .denied(.noRecordedIdentity)
            } else {
                let observed = stat.lstat(path)
                switch verifyIdentity(path, recorded, stat: StagingStat(path: path, result: observed, base: stat)) {
                case .nowSymlink, .symlinkInPath: verdict = .denied(.symlinkInPath)
                case .same:
                    guard case .ok(let info, _, _) = observed else { preconditionFailure("Verified identity requires a stat") }
                    freshDataless = info.flags & UInt32(SF_DATALESS) != 0
                    let verdicts = allVerdicts(path, info, context)
                    verdict = verdicts.first ?? .ok
                    warnings = verdicts.compactMap { if case .warn(let reason) = $0 { return reason }; return nil }
                case .gone, .inodeChanged, .deviceChanged, .typeChanged, .unreadable:
                    verdict = .denied(.changedSinceScan)
                }
            }
            let unknown = snapshot.isPermissionDenied(node) || snapshot.isDataless(node) || snapshot.isSkippedByRequest(node) || freshDataless
            var hasUnknown = unknown
            var descendants: [UInt32] = []
            func warn(_ reason: Reason) {
                if !warnings.contains(reason) { warnings.append(reason) }
            }
            let denied: Bool
            if case .denied = verdict { denied = true } else { denied = false }
            if recorded.isDirectory {
                var pending = denied ? [] : Array(source.children(node))
                while let child = pending.popLast() {
                    if Task.isCancelled { return [] }
                    let childUnknown = snapshot.isPermissionDenied(child) || snapshot.isDataless(child) || snapshot.isSkippedByRequest(child)
                    if childUnknown { hasUnknown = true; warn(.containsUnknownSize) }
                    if snapshot.isDataless(child) { warn(.containsCloudOnly) }
                    if snapshot.nodes[Int(child)].flags & UInt16(TESS_FLAG_HARDLINK_DUP) != 0 { warn(.containsHardLinks) }
                    descendants.append(child)
                    pending.append(contentsOf: source.children(child))
                }
                next.removeAll {
                    if hasStagedAncestor($0.nodeIndex, in: snapshot, staged: [node]) {
                        for reason in itemWarnings($0) {
                            warn(reason)
                            if reason == .cloudOnly { warn(.containsCloudOnly); warn(.containsUnknownSize) }
                            if reason == .otherHardLinks { warn(.containsHardLinks) }
                        }
                        hasUnknown = hasUnknown || $0.hasUnknownContent || $0.recordedSize == nil
                        staged.remove($0.nodeIndex)
                        return true
                    }
                    return false
                }
            }
            if case .ok = verdict, let reason = warnings.first { verdict = .warn(reason) }
            staged.insert(node)
            next.append(JetsamItem(nodeIndex: node, path: path, recorded: recorded,
                                   recordedSize: unknown ? nil : source.allocated(node), verdict: verdict, warnings: warnings,
                                   hasUnknownContent: hasUnknown, descendants: StagedDescendants(snapshot: snapshot, overlay: overlay, nodes: descendants), overlayRevision: overlay.revision, sessionID: sessionID))
        }
        return next
    }

    public func unstage(_ nodes: Set<UInt32>) { items.removeAll { nodes.contains($0.nodeIndex) } }
    public func clear() { items = [] }
    public var stagedNodes: Set<UInt32> { Set(items.map(\.nodeIndex)) }

    public var knownBytes: UInt64 {
        items.reduce(0) { total, item in
            if case .denied = item.verdict { return total }
            let (sum, overflow) = total.addingReportingOverflow(item.recordedSize ?? 0)
            return overflow ? UInt64.max : sum
        }
    }

    public var unknownSizeCount: Int {
        items.filter {
            if case .denied = $0.verdict { return false }
            return $0.recordedSize == nil || $0.hasUnknownContent
        }.count
    }
}

public func applyStaging(_ tiles: inout [Tile], in snapshot: Snapshot, staged: Set<UInt32>) {
    for i in tiles.indices {
        let node = tiles[i].node
        if node != Tile.noNode, hasStagedAncestor(node, in: snapshot, staged: staged) {
            tiles[i].flags |= Tile.Flag.staged
        } else {
            tiles[i].flags &= ~Tile.Flag.staged
        }
    }
}
