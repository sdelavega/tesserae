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

/// Scan-relative display components. Filesystem actions continue to use rawPath.
public func relativePath(of node: UInt32, in s: Snapshot, rootName: String) -> [String] {
    guard s.root != Tile.noNode else { return [] }
    var parts: [String] = []
    var current = node
    while current != s.root {
        precondition(parts.count < s.nodes.count, "Snapshot parent chain has a cycle")
        parts.append(s.displayName(current))
        current = s.nodes[Int(current)].parent
    }
    parts.append(Snapshot.displayName(bytes: Data(rootName.utf8)))
    return parts.reversed()
}

public func joinedForDisplay(_ parts: [String]) -> String { parts.joined(separator: " › ") }

extension Snapshot {
    /// The final raw component of the scan root; never trim an absolute display path.
    public var scanRootName: String {
        let parts = nameBytes(root).split(separator: UInt8(ascii: "/"))
        return parts.last.map { Self.displayName(bytes: Data($0)) } ?? "/"
    }
}
