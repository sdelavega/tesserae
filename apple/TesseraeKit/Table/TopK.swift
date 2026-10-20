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

/// The `k` largest files (by `allocated`, directories excluded) in the
/// subtree of `root`, largest first, ties broken by lower node index.
///
/// A bounded min-heap of at most `k` entries whose root is the worst kept
/// entry, so memory is O(k) and time O(n log k) however large the snapshot.
/// `root` itself counts if it is a file. Inside a cancelled task it returns [].
public func topK(_ k: Int, files s: Snapshot, under root: UInt32) -> [UInt32] {
    precondition(Int(root) < s.nodes.count, "topK: root \(root) outside the snapshot")
    guard k > 0 else { return [] }
    var heap = BoundedHeap(capacity: k)
    var stack: [UInt32] = [root]
    while let i = stack.popLast() {
        // A superseded sort cancels its task; stop walking and return nothing
        // (a partial answer must never be mistaken for the real one).
        if Task.isCancelled { return [] }
        if s.isDirectory(i) {
            stack.append(contentsOf: s.children(i))
        } else {
            heap.offer(BoundedHeap.Entry(allocated: s.allocated(i), node: i))
        }
    }
    return heap.entries.sorted { BoundedHeap.better($0, $1) }.map(\.node)
}

/// A min-heap by "goodness": `entries[0]` is the worst entry kept.
private struct BoundedHeap {
    struct Entry {
        var allocated: UInt64
        var node: UInt32
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(min(capacity, 4096))
    }

    /// `a` ranks above `b`: larger, or equal and the lower index.
    static func better(_ a: Entry, _ b: Entry) -> Bool {
        a.allocated != b.allocated ? a.allocated > b.allocated : a.node < b.node
    }

    mutating func offer(_ e: Entry) {
        if entries.count < capacity {
            entries.append(e)
            var c = entries.count - 1
            while c > 0 {
                let p = (c - 1) / 2
                if BoundedHeap.better(entries[p], entries[c]) {
                    entries.swapAt(p, c)
                    c = p
                } else {
                    break
                }
            }
        } else if BoundedHeap.better(e, entries[0]) {
            entries[0] = e
            var p = 0
            while true {
                let l = 2 * p + 1, r = l + 1
                var worst = p
                if l < entries.count, BoundedHeap.better(entries[worst], entries[l]) { worst = l }
                if r < entries.count, BoundedHeap.better(entries[worst], entries[r]) { worst = r }
                if worst == p { break }
                entries.swapAt(p, worst)
                p = worst
            }
        }
    }
}
