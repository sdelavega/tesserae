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

/// Child node indices, with an allocation-free snapshot range fast path.
public struct ChildList: RandomAccessCollection, Sendable {
    public typealias Index = Int
    public typealias Element = UInt32

    private enum Storage: Sendable {
        case range(Range<UInt32>)
        case array([UInt32])
    }
    private let storage: Storage

    public init(_ range: Range<UInt32>) { storage = .range(range) }
    public init(_ nodes: [UInt32]) { storage = .array(nodes) }

    var isRange: Bool {
        if case .range = storage { return true }
        return false
    }

    // Snapshot contiguity assertions use node bounds, never collection indices.
    var lowerBound: UInt32 {
        guard case .range(let range) = storage else { preconditionFailure("Children are not contiguous") }
        return range.lowerBound
    }
    var upperBound: UInt32 {
        guard case .range(let range) = storage else { preconditionFailure("Children are not contiguous") }
        return range.upperBound
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int {
        switch storage {
        case .range(let range): return Int(range.upperBound - range.lowerBound)
        case .array(let nodes): return nodes.count
        }
    }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
    public subscript(position: Int) -> UInt32 {
        precondition(position >= 0 && position < endIndex)
        switch storage {
        case .range(let range): return range.lowerBound + UInt32(position)
        case .array(let nodes): return nodes[position]
        }
    }
}

/// The tree the layout reads (spec §8). Children of a node are indices sorted by `allocated` descending, and a directory's `allocated`
/// equals the sum over its children (the freeze's rollup), so the layout
/// never sorts and never scans past the visible prefix of a sibling run.
public protocol TreeSource {
    var rootIndex: UInt32 { get }
    /// Sorted by allocated descending; empty for a leaf.
    func children(_ i: UInt32) -> ChildList
    func allocated(_ i: UInt32) -> UInt64
    func isDirectory(_ i: UInt32) -> Bool
    /// A directory the scan could not read (`TESS_FLAG_PERM_DENIED`): zero
    /// bytes and no children, so the layout gives it a placeholder tile.
    func isPermissionDenied(_ i: UInt32) -> Bool
}

extension Snapshot: TreeSource {
    public var rootIndex: UInt32 { root }

    public func isPermissionDenied(_ i: UInt32) -> Bool {
        let all = nodes
        precondition(Int(i) < all.count, "Snapshot node index out of range")
        return all[Int(i)].flags & UInt16(TESS_FLAG_PERM_DENIED) != 0
    }
}
