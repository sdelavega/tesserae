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

@testable import TesseraeKit

/// An in-memory tree laid out like a frozen snapshot: each node's children
/// contiguous, sorted by `allocated` descending, a directory's size the sum
/// over its children. Built breadth-first from a nested description.
struct SyntheticTree: TreeSource {
    /// A nested description: a file (`children == nil`) or a directory.
    struct Spec {
        var size: UInt64
        var children: [Spec]?

        static func file(_ size: UInt64) -> Spec { Spec(size: size, children: nil) }

        /// A directory, sized as the sum over `children`.
        static func dir(_ children: [Spec]) -> Spec {
            Spec(size: children.reduce(0) { $0 + $1.size }, children: children)
        }
    }

    private(set) var sizes: [UInt64] = []
    private(set) var starts: [UInt32] = []
    private(set) var counts: [UInt32] = []
    private(set) var dirs: [Bool] = []
    private(set) var parents: [UInt32] = []

    var rootIndex: UInt32 { 0 }
    var count: Int { sizes.count }

    init(_ root: Spec) {
        // Breadth-first, so each node's children get consecutive indices.
        var queue: [(spec: Spec, parent: UInt32)] = [(root, UInt32.max)]
        var head = 0
        sizes.append(root.size)
        dirs.append(root.children != nil)
        parents.append(UInt32.max)
        starts.append(0)
        counts.append(0)
        while head < queue.count {
            let (spec, _) = queue[head]
            let me = UInt32(head)
            head += 1
            guard let kids = spec.children, !kids.isEmpty else { continue }
            let sorted = kids.sorted { $0.size > $1.size }
            starts[Int(me)] = UInt32(sizes.count)
            counts[Int(me)] = UInt32(sorted.count)
            for k in sorted {
                sizes.append(k.size)
                dirs.append(k.children != nil)
                parents.append(me)
                starts.append(0)
                counts.append(0)
                queue.append((k, me))
            }
        }
        // The invariants the layout relies on, checked so no property passes
        // over a tree that a real snapshot could never be.
        for i in 0..<sizes.count {
            let r = children(UInt32(i))
            var sum: UInt64 = 0
            var prev = UInt64.max
            for c in r {
                precondition(sizes[Int(c)] <= prev, "children not sorted descending")
                prev = sizes[Int(c)]
                sum += sizes[Int(c)]
            }
            if dirs[i] { precondition(sum == sizes[i], "directory size is not its rollup") }
        }
    }

    func children(_ i: UInt32) -> Range<UInt32> {
        starts[Int(i)]..<(starts[Int(i)] + counts[Int(i)])
    }

    func allocated(_ i: UInt32) -> UInt64 { sizes[Int(i)] }

    func isDirectory(_ i: UInt32) -> Bool { dirs[Int(i)] }

    // MARK: Random trees

    /// A heavy-tailed file size: log-uniform over 36 bits (a few huge, very
    /// many tiny), occasionally zero, occasionally a thousandfold outlier.
    static func fileSize(_ rng: inout SplitMix64) -> UInt64 {
        let u = rng.unit()
        if u < 0.05 { return 0 }
        var s = UInt64(exp(rng.unit() * 36 * M_LN2))
        if u > 0.99 { s *= 1000 }
        return s
    }

    /// A random tree of at most about `maxNodes` nodes.
    static func random(seed: UInt64, maxNodes: Int = 3000) -> SyntheticTree {
        var rng = SplitMix64(seed: seed)
        var budget = maxNodes
        func dir(depth: Int) -> Spec {
            var n: Int
            if rng.unit() < 0.08 {
                n = 100 + Int(rng.next() % 1400)  // a big flat directory
            } else {
                n = Int(rng.next() % 13)
            }
            n = min(n, max(budget, 0))
            budget -= n
            var kids: [Spec] = []
            kids.reserveCapacity(n)
            for _ in 0..<n {
                let pDir = depth < 7 ? 0.35 / Double(depth + 1) + 0.05 : 0
                if rng.unit() < pDir {
                    kids.append(dir(depth: depth + 1))
                } else {
                    kids.append(.file(fileSize(&rng)))
                }
            }
            return .dir(kids)
        }
        // Root: always a directory with at least a few children.
        var root = dir(depth: 0)
        if root.children!.count < 3 {
            root = .dir(root.children! + [.file(fileSize(&rng) + 1), .dir([.file(fileSize(&rng))])])
        }
        return SyntheticTree(root)
    }

    /// A random tree whose siblings differ in size by at most a factor of
    /// ten: each directory's size is split among its children by weights in
    /// [1, 10]. Nothing here forces a thin tile, so the aspect bound applies
    /// to every tile (heavy-tailed trees can force one; see LayoutTests).
    static func balanced(seed: UInt64, maxNodes: Int = 2000) -> SyntheticTree {
        var rng = SplitMix64(seed: seed)
        var budget = maxNodes
        func node(size: UInt64, depth: Int) -> Spec {
            let isDir = depth == 0 || (depth < 6 && rng.unit() < 0.3)
            guard isDir else { return .file(size) }
            let n = min(2 + Int(rng.next() % 30), max(budget, 1))
            budget -= n
            let weights = (0..<n).map { _ in 1 + rng.unit() * 9 }
            let wsum = weights.reduce(0, +)
            var sizes = weights.map { UInt64(Double(size) * $0 / wsum) }
            sizes[0] += size - sizes.reduce(0, +)
            return .dir(sizes.map { node(size: $0, depth: depth + 1) })
        }
        return SyntheticTree(node(size: 1 << 50, depth: 0))
    }
}
