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
import TesseraeFFI

/// Which directory the treemap shows (spec §8 "Zoom and navigation").
///
/// `root` is always a directory of `snapshot` that can be laid out: the
/// snapshot's root, or a readable directory beneath it. Every move that would
/// break that is a no-op, so a caller can forward any click or key press
/// without checking it first:
///
/// * `descend(into:)` accepts any readable directory strictly beneath the
///   current root (a click may land several levels down), and ignores a
///   file, an aggregate (`Tile.noNode`), an unreadable directory (nothing to
///   show), an index outside the snapshot, and anything not beneath `root`.
/// * `ascend()` (⌘↑) goes to the parent; at the snapshot's root it does nothing.
///   `ascend(to:)` goes straight to any ancestor on the `breadcrumb`.
/// * `sibling(_:)` (← / →) moves among the current root's parent's readable
///   directory children, in the snapshot's order (largest first), clamped at
///   both ends; at the snapshot's root there are no siblings.
@MainActor
public final class Navigator: ObservableObject {
    public let snapshot: Snapshot
    @Published public private(set) var root: UInt32

    public init(snapshot: Snapshot) {
        self.snapshot = snapshot
        root = snapshot.root
    }

    /// The snapshot's root, then each directory down to the current `root`.
    public var breadcrumb: [UInt32] {
        guard root != Tile.noNode else { return [] }
        var chain = [root]
        var cur = root
        while let p = parent(cur) {
            chain.append(p)
            cur = p
        }
        return chain.reversed()
    }

    /// Whether `descend(into: node)` would change `root`.
    public func canDescend(into node: UInt32) -> Bool {
        guard node != Tile.noNode, Int(node) < snapshot.nodes.count, node != root,
            isNavigable(node)
        else { return false }
        var cur = node
        while let p = parent(cur) {
            if p == root { return true }
            cur = p
        }
        return false
    }

    public func descend(into node: UInt32) {
        guard canDescend(into: node) else { return }
        root = node
    }

    public func ascend() {
        guard let p = parent(root) else { return }
        root = p
    }

    /// Jumps straight to `node` (a breadcrumb click) if it is an ancestor of
    /// `root`, in one change of `root`; anything else does nothing.
    public func ascend(to node: UInt32) {
        guard node != root, breadcrumb.contains(node) else { return }
        root = node
    }

    public func sibling(_ step: Int) {
        guard step != 0, let p = parent(root) else { return }
        let siblings = snapshot.children(p).filter(isNavigable)
        guard let here = siblings.firstIndex(of: root) else { return }
        let (sum, overflow) = here.addingReportingOverflow(step)
        let target = overflow ? (step > 0 ? siblings.count - 1 : 0) : min(max(sum, 0), siblings.count - 1)
        root = siblings[target]
    }

    /// A directory with something to lay out: readable.
    private func isNavigable(_ node: UInt32) -> Bool {
        snapshot.isDirectory(node) && !snapshot.isPermissionDenied(node)
    }

    private func parent(_ node: UInt32) -> UInt32? {
        let all = snapshot.nodes
        guard Int(node) < all.count else { return nil }
        let p = all[Int(node)].parent
        return p == UInt32.max ? nil : p
    }
}
