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

/// Session-local deletions; the snapshot and its borrowed buffers never change.
public struct SizeOverlay: Sendable {
    public private(set) var revision: UInt64 = 0
    public private(set) var deltas: [UInt32: Int64] = [:]
    public private(set) var logicalDeltas: [UInt32: Int64] = [:]
    public private(set) var deleted: Set<UInt32> = []
    // Counts also mark ancestors of zero-byte deletions, which have no delta.
    public private(set) var replacedIdentities: [UInt32: UInt64] = [:]
    private var changedParents: Set<UInt32> = []
    private var removedCounts: [UInt32: Int] = [:]
    private var descendantDeletions: [UInt32: Int] = [:]

    public init() {}

    func affectsChildren(_ node: UInt32) -> Bool { descendantDeletions[node] != nil || changedParents.contains(node) }

    public mutating func replaceIdentity(node: UInt32, newFileID: UInt64) {
        guard replacedIdentities[node] != newFileID else { return }
        replacedIdentities[node] = newFileID
        revision += 1
    }

    public func recorded(_ recorded: Recorded, node: UInt32) -> Recorded {
        Recorded(fileID: replacedIdentities[node] ?? recorded.fileID, device: recorded.device, isDirectory: recorded.isDirectory)
    }

    public mutating func applyDelta(node: UInt32, allocated: Int64, logical: Int64, in s: Snapshot) {
        guard allocated != 0 || logical != 0 else { return }
        revision += 1
        var current = node
        while current != UInt32.max {
            let delta = (deltas[current] ?? 0) + allocated
            deltas[current] = delta == 0 ? nil : delta
            let logicalDelta = (logicalDeltas[current] ?? 0) + logical
            logicalDeltas[current] = logicalDelta == 0 ? nil : logicalDelta
            let parent = s.nodes[Int(current)].parent
            if parent != UInt32.max { changedParents.insert(parent) }
            if deleted.contains(current) { break }
            current = parent
        }
    }

    public func isDeleted(_ node: UInt32, in s: Snapshot) -> Bool {
        guard !deleted.isEmpty else { return false }
        var current = node
        while current != UInt32.max {
            if deleted.contains(current) { return true }
            current = s.nodes[Int(current)].parent
        }
        return false
    }

    public mutating func remove(_ node: UInt32, in s: Snapshot) {
        guard !isDeleted(node, in: s) else { return }
        let bytes = adjusted(node, in: s)
        precondition(bytes <= UInt64(Int64.max), "Overlay delta exceeds Int64")
        let logical = adjustedLogical(node, in: s)
        precondition(logical <= UInt64(Int64.max), "Overlay logical delta exceeds Int64")
        revision += 1
        deleted.insert(node)
        propagate(node, amount: -Int64(bytes), logicalAmount: -Int64(logical), count: 1, removed: s.descendantCount(node) - (removedCounts[node] ?? 0) + 1, in: s)
    }

    public mutating func restore(_ node: UInt32, in s: Snapshot) {
        guard deleted.remove(node) != nil else { return }
        revision += 1
        let bytes = adjusted(node, in: s)
        precondition(bytes <= UInt64(Int64.max), "Overlay delta exceeds Int64")
        let logical = adjustedLogical(node, in: s)
        precondition(logical <= UInt64(Int64.max), "Overlay logical delta exceeds Int64")
        propagate(node, amount: Int64(bytes), logicalAmount: Int64(logical), count: -1, removed: -(s.descendantCount(node) - (removedCounts[node] ?? 0) + 1), in: s)
    }

    private mutating func propagate(_ node: UInt32, amount: Int64, logicalAmount: Int64, count: Int, removed: Int, in s: Snapshot) {
        var parent = s.nodes[Int(node)].parent
        var changesSize = true
        while parent != UInt32.max {
            let descendants = (descendantDeletions[parent] ?? 0) + count
            descendantDeletions[parent] = descendants == 0 ? nil : descendants
            if changesSize {
                let removedCount = (removedCounts[parent] ?? 0) + removed
                removedCounts[parent] = removedCount == 0 ? nil : removedCount
                let delta = (deltas[parent] ?? 0) + amount
                deltas[parent] = delta == 0 ? nil : delta
                let logical = (logicalDeltas[parent] ?? 0) + logicalAmount
                logicalDeltas[parent] = logical == 0 ? nil : logical
            }
            // A removed ancestor's own size changes, but its contribution to
            // ancestors stays zero until that ancestor is restored.
            if deleted.contains(parent) { changesSize = false }
            parent = s.nodes[Int(parent)].parent
        }
    }

    func descendantCount(_ node: UInt32, in s: Snapshot) -> Int {
        max(0, s.descendantCount(node) - (removedCounts[node] ?? 0))
    }

    func adjusted(_ node: UInt32, in s: Snapshot) -> UInt64 {
        let base = s.allocated(node)
        let delta = deltas[node] ?? 0
        if delta < 0 { return base > delta.magnitude ? base - delta.magnitude : 0 }
        return base + UInt64(delta)
    }

    func adjustedLogical(_ node: UInt32, in s: Snapshot) -> UInt64 {
        let base = s.nodes[Int(node)].logical
        let delta = logicalDeltas[node] ?? 0
        if delta < 0 { return base > delta.magnitude ? base - delta.magnitude : 0 }
        return base + UInt64(delta)
    }

    public func needsRescan(rootAllocated: UInt64) -> Bool {
        // Snapshot roots have index zero (the freeze's breadth-first contract).
        deleted.count > 10_000 || (deltas[0] ?? 0).magnitude > rootAllocated / 10
    }
}

public struct OverlaySource: TreeSource, Sendable {
    public let snapshot: Snapshot
    public let overlay: SizeOverlay

    public init(_ s: Snapshot, _ o: SizeOverlay) { snapshot = s; overlay = o }
    public var rootIndex: UInt32 { snapshot.root }
    public func allocated(_ i: UInt32) -> UInt64 { overlay.adjusted(i, in: snapshot) }
    public func descendantCount(_ i: UInt32) -> Int { overlay.descendantCount(i, in: snapshot) }
    public func logical(_ i: UInt32) -> UInt64 { overlay.adjustedLogical(i, in: snapshot) }
    public func isDirectory(_ i: UInt32) -> Bool { snapshot.isDirectory(i) }
    public func isPermissionDenied(_ i: UInt32) -> Bool { snapshot.isPermissionDenied(i) }

    public func children(_ i: UInt32) -> ChildList {
        let children = snapshot.children(i)
        guard overlay.affectsChildren(i) else { return children }
        return ChildList(children.filter { !overlay.deleted.contains($0) }.sorted {
            let a = allocated($0), b = allocated($1)
            return a == b ? $0 < $1 : a > b
        })
    }
}
