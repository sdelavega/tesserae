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

import CoreGraphics

/// One rectangle of the treemap, in paint order (spec §8 "Metal").
public struct Tile: Equatable, Sendable {
    /// The `node` of an aggregate tile: `TESS_NODE_NONE` (`UInt32.max`).
    public static let noNode = UInt32.max

    /// `flags` bits (spec §8). The layout sets only `aggregated`; selection,
    /// staging and permission state belong to the renderer's caller.
    public enum Flag {
        public static let selected: UInt8 = 1 << 0
        public static let staged: UInt8 = 1 << 1
        public static let permDenied: UInt8 = 1 << 2
        public static let aggregated: UInt8 = 1 << 3
    }

    public var rect: CGRect  // points
    public var node: UInt32  // TESS_NODE_NONE for an aggregate
    public var depth: UInt8
    public var flags: UInt8  // bit 0 selected, 1 staged, 2 permDenied, 3 aggregated (spec §8)
    public var aggregateCount: UInt32  // number of collapsed siblings, 0 otherwise
    public var aggregateBytes: UInt64
    /// The directory whose subtree this tile was laid out in (the node whose
    /// children it is one of, or an aggregate / placeholder for); `noNode` for
    /// the layout's root tile. Lets a caller find which directories were
    /// subdivided in one pass.
    public var parent: UInt32

    public init(
        rect: CGRect, node: UInt32, depth: UInt8, flags: UInt8 = 0,
        aggregateCount: UInt32 = 0, aggregateBytes: UInt64 = 0, parent: UInt32 = Tile.noNode
    ) {
        self.rect = rect
        self.node = node
        self.depth = depth
        self.flags = flags
        self.aggregateCount = aggregateCount
        self.aggregateBytes = aggregateBytes
        self.parent = parent
    }

    public var isAggregate: Bool { flags & Flag.aggregated != 0 }
    public var isPermissionDenied: Bool { flags & Flag.permDenied != 0 }
}
