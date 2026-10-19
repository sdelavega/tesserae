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

/// The tree the layout reads (spec §8). Children of a node are contiguous
/// indices sorted by `allocated` descending, and a directory's `allocated`
/// equals the sum over its children (the freeze's rollup), so the layout
/// never sorts and never scans past the visible prefix of a sibling run.
public protocol TreeSource {
    var rootIndex: UInt32 { get }
    /// Contiguous, sorted by allocated descending; empty for a leaf.
    func children(_ i: UInt32) -> Range<UInt32>
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
