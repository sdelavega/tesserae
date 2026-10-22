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

public enum FileListMode: String, CaseIterable {
    case folders, largestFiles
}

public enum FolderRow: Equatable, Hashable {
    public static let childLimit = 500
    case node(UInt32)
    case smaller(count: Int, bytes: UInt64, parent: UInt32)
}

/// A lazy, bounded view of sibling lists. Column sorts retain the same
/// size-selected prefix and contiguous-suffix summary as the treemap.
public final class FolderTreeModel {
    public let source: OverlaySource
    public let root: UInt32
    private let readChildren: (UInt32) -> ChildList
    private var base: [UInt32: [FolderRow]] = [:]
    private var sorted: [UInt32: [FolderRow]] = [:]
    private var key: SortKey = .allocated
    private var ascending = false

    public convenience init(source: OverlaySource, root: UInt32) {
        self.init(source: source, root: root, children: source.children)
    }

    init(source: OverlaySource, root: UInt32, children: @escaping (UInt32) -> ChildList) {
        self.source = source
        self.root = root
        readChildren = children
    }

    public func children(of node: UInt32) -> [FolderRow] {
        if let rows = sorted[node] { return rows }
        guard Int(node) < source.snapshot.nodes.count, source.isDirectory(node),
            !source.isPermissionDenied(node), !source.overlay.isDeleted(node, in: source.snapshot) else { return [] }
        let rows: [FolderRow]
        if let cached = base[node] { rows = cached }
        else {
            let children = readChildren(node)
            let prefix = Array(children.prefix(FolderRow.childLimit))
            var built = prefix.map { FolderRow.node($0) }
            if children.count > prefix.count {
                let shown = prefix.reduce(UInt64(0)) { $0 + source.allocated($1) }
                let total = source.allocated(node)
                built.append(.smaller(count: children.count - prefix.count,
                    bytes: total >= shown ? total - shown : 0, parent: node))
            }
            base[node] = built
            rows = built
        }
        var nodes = rows.compactMap { row -> UInt32? in
            if case .node(let n) = row { return n }; return nil
        }
        let s = source.snapshot
        switch key {
        case .name, .kind:
            let names = Dictionary(uniqueKeysWithValues: nodes.map { ($0, key == .name ? s.displayName($0) : nodeKind($0, in: s).displayName) })
            nodes.sort {
                let order = names[$0]!.localizedStandardCompare(names[$1]!)
                if order == .orderedSame { return $0 < $1 }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        default:
            func compare<T: Comparable>(_ a: T, _ b: T, _ i: UInt32, _ j: UInt32) -> Bool {
                a == b ? i < j : (ascending ? a < b : a > b)
            }
            nodes.sort { a, b in
                switch key {
                case .logical: return compare(source.logical(a), source.logical(b), a, b)
                case .modified:
                    let x = s.nodes[Int(a)].modified, y = s.nodes[Int(b)].modified
                    return compare(x == 0 ? Int64.min : x, y == 0 ? Int64.min : y, a, b)
                case .items: return compare(source.descendantCount(a), source.descendantCount(b), a, b)
                default: return compare(source.allocated(a), source.allocated(b), a, b)
                }
            }
        }
        var result = nodes.map { FolderRow.node($0) }
        if let last = rows.last, case .smaller = last { result.append(last) }
        sorted[node] = result
        return result
    }

    /// Root through node, inclusive; empty outside this root or after deletion.
    public func path(to node: UInt32) -> [UInt32] {
        let s = source.snapshot
        guard Int(node) < s.nodes.count, !source.overlay.isDeleted(node, in: s) else { return [] }
        var chain: [UInt32] = []
        var current = node
        while Int(current) < s.nodes.count, chain.count < s.nodes.count {
            chain.append(current)
            if current == root { return chain.reversed() }
            current = s.nodes[Int(current)].parent
        }
        return []
    }

    public func sort(_ key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
        sorted.removeAll(keepingCapacity: true)
    }
}

/// Session-owned expansion, keyed by navigation root; never written to disk.
@MainActor
public final class FolderExpansionState {
    var roots: [UInt32: Set<UInt32>] = [:]
    public init() {}
}
