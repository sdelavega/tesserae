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

@testable import TesseraeKit

/// Owns allocations used by a synthetic snapshot.
final class TestSnapshotBuffers {
    let nodes: UnsafeMutablePointer<TessNode>
    let names: UnsafeMutablePointer<UInt8>

    init(nodes: UnsafeMutablePointer<TessNode>, names: UnsafeMutablePointer<UInt8>) {
        self.nodes = nodes
        self.names = names
    }

    convenience init(nodes: [TessNode], names: [UInt8]) {
        let nodeStorage = UnsafeMutablePointer<TessNode>.allocate(capacity: max(nodes.count, 1))
        nodeStorage.initialize(from: nodes, count: nodes.count)
        let nameStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(names.count, 1))
        nameStorage.initialize(from: names, count: names.count)
        self.init(nodes: nodeStorage, names: nameStorage)
    }

    deinit {
        nodes.deallocate()
        names.deallocate()
    }
}

/// A `Snapshot` over buffers this object owns, built breadth-first from a
/// nested description as a freeze would lay it out: each directory's
/// children contiguous and sorted by `allocated` descending (stable), sizes
/// rolled up, a directory's `modified` the given one (tests state the rollup
/// they want). The snapshot retains its buffer owner.
final class TestSnapshot {
    struct Spec {
        var name: String
        var allocated: UInt64
        var logical: UInt64
        var modified: Int64
        var children: [Spec]?
        var denied = false
        var dataless = false
        var hardlinkDuplicate = false
        var skippedByRequest = false
        /// The name's bytes when they are not `name`'s UTF-8 (`name` is then
        /// only the lookup key).
        var rawName: [UInt8]? = nil

        static func file(_ name: String, _ allocated: UInt64, logical: UInt64? = nil, modified: Int64 = 0) -> Spec {
            Spec(name: name, allocated: allocated, logical: logical ?? allocated, modified: modified, children: nil)
        }

        static func dir(_ name: String, modified: Int64 = 0, _ children: [Spec]) -> Spec {
            Spec(
                name: name, allocated: children.reduce(0) { $0 + $1.allocated },
                logical: children.reduce(0) { $0 + $1.logical }, modified: modified, children: children)
        }

        /// A file whose name is exactly `bytes` (not necessarily UTF-8),
        /// looked up by `key`.
        static func rawFile(_ bytes: [UInt8], key: String, _ allocated: UInt64) -> Spec {
            Spec(
                name: key, allocated: allocated, logical: allocated, modified: 0, children: nil, rawName: bytes)
        }

        static func denied(_ name: String) -> Spec {
            Spec(name: name, allocated: 0, logical: 0, modified: 0, children: [], denied: true)
        }
    }

    let buffers: TestSnapshotBuffers
    let snapshot: Snapshot
    /// Node index by name (names must be unique for this to be useful).
    let index: [String: UInt32]

    init(_ root: Spec, stats: TessScanStats = TessScanStats(), unreadable: [Data] = [], skipped: [Snapshot.RequestedSkip] = [], stalledAt: Data? = nil, fileIDs: Bool = false) {
        var out: [TessNode] = []
        var bytes: [UInt8] = []
        var byName: [String: UInt32] = [:]
        func node(_ s: Spec, parent: UInt32) -> TessNode {
            var n = TessNode()
            let raw = s.rawName ?? Array(s.name.utf8)
            n.name_off = UInt32(bytes.count)
            n.name_len = UInt16(raw.count)
            bytes.append(contentsOf: raw)
            n.parent = parent
            n.allocated = s.allocated
            n.logical = s.logical
            n.modified = s.modified
            if s.children != nil { n.flags |= UInt16(TESS_FLAG_DIR) }
            if s.hardlinkDuplicate { n.flags |= UInt16(TESS_FLAG_HARDLINK_DUP) }
            if s.dataless { n.flags |= UInt16(TESS_FLAG_DATALESS) }
            if s.skippedByRequest { n.flags |= UInt16(TESS_FLAG_SKIPPED_REQUEST) }
            if s.denied { n.flags |= UInt16(TESS_FLAG_PERM_DENIED) }
            return n
        }
        out.append(node(root, parent: UInt32.max))
        byName[root.name] = 0
        var queue: [Spec] = [root]
        var head = 0
        while head < queue.count {
            let spec = queue[head]
            let me = head
            head += 1
            guard let kids = spec.children, !kids.isEmpty else { continue }
            let sorted = kids.enumerated().sorted {
                $0.element.allocated != $1.element.allocated
                    ? $0.element.allocated > $1.element.allocated : $0.offset < $1.offset
            }.map(\.element)
            out[me].child_start = UInt32(out.count)
            out[me].child_count = UInt32(sorted.count)
            for k in sorted {
                byName[k.name] = UInt32(out.count)
                out.append(node(k, parent: UInt32(me)))
                queue.append(k)
            }
        }
        let nodes = UnsafeMutablePointer<TessNode>.allocate(capacity: out.count)
        nodes.initialize(from: out, count: out.count)
        let names = UnsafeMutablePointer<UInt8>.allocate(capacity: max(bytes.count, 1))
        names.initialize(from: bytes, count: bytes.count)
        buffers = TestSnapshotBuffers(nodes: nodes, names: names)
        snapshot = Snapshot(
            testingNodes: UnsafeBufferPointer(start: nodes, count: out.count),
            names: UnsafeRawBufferPointer(start: names, count: bytes.count), owner: buffers, root: 0, stats: stats, unreadable: unreadable, skipped: skipped, stalledAt: stalledAt, fileIDs: fileIDs ? out.indices.map { UInt64($0 + 1) } : [])
        index = byName
    }

    subscript(_ name: String) -> UInt32 {
        guard let i = index[name] else { preconditionFailure("no node named \(name)") }
        return i
    }
}

// Small semantic fixtures can stage synchronously. Production staging always
// uses AppModel's coordinator and background preparation actor.
extension Reclaim {
    @MainActor
    func stage(_ nodes: [UInt32], in snapshot: Snapshot, context: GuardContext, stat: FileStat,
               overlay: SizeOverlay = SizeOverlay()) {
        publish(Self.prepare(nodes, in: snapshot, context: context, stat: stat,
            overlay: overlay, existing: items, sessionID: sessionID))
    }
}
