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

/// The set of selected nodes, shared by the file table and the treemap
/// (spec §8): either side writes it, both observe it.
@MainActor
public final class Selection: ObservableObject {
    @Published public var nodes: Set<UInt32>

    public init(nodes: Set<UInt32> = []) {
        self.nodes = nodes
    }
}

/// Set (or clear) the selected flag, bit 0, on every tile whose node is in
/// `selection`. Aggregate and placeholder tiles stand for no single node and
/// are never selected. Call this when the treemap's instances are built.
public func applySelection(_ tiles: inout [Tile], _ selection: Set<UInt32>) {
    for i in tiles.indices {
        let n = tiles[i].node
        if n != Tile.noNode, selection.contains(n) {
            tiles[i].flags |= Tile.Flag.selected
        } else {
            tiles[i].flags &= ~Tile.Flag.selected
        }
    }
}
