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
import Foundation

/// What the hover inspector shows (spec §8: "full path, both sizes, type, dates").
///
/// For a node, `path` is its full path. For a tile that stands for several
/// nodes it is a description instead, since there is no single path:
/// "N smaller items — X" for an aggregate, "N unreadable folders" for the
/// collapsed placeholder of a strip.
public struct InspectorInfo: Equatable {
    public var path: String
    public var allocated, logical: UInt64
    public var kind: String
    public var modified: Date?

    public init(path: String, allocated: UInt64, logical: UInt64, kind: String, modified: Date?) {
        self.path = path
        self.allocated = allocated
        self.logical = logical
        self.kind = kind
        self.modified = modified
    }
}

extension FileKind {
    /// The inspector's name for a file of this kind.
    public var displayName: String {
        switch self {
        case .video: return "Video"
        case .images: return "Image"
        case .audio: return "Audio"
        case .archives: return "Archive"
        case .documents: return "Document"
        }
    }
}

/// The inspector's view of node `node`.
///
/// * Sizes are the node's own: for a directory, rolled up over its subtree.
/// * `kind` is "Folder" for a directory, the `FileKind` display name for a
///   file whose extension has one, and "File" otherwise.
/// * `modified` is the node's time as the snapshot holds it: a file's own
///   time as read; a directory's, the latest in its subtree not later than
///   the scan's start (the freeze's rollup).
public func inspect(_ node: UInt32, in s: Snapshot) -> InspectorInfo {
    precondition(Int(node) < s.nodes.count, "inspect: node \(node) outside the snapshot")
    let n = s.nodes[Int(node)]
    let kind: String
    if s.isDirectory(node) {
        kind = "Folder"
    } else {
        kind = FileKind.kind(forName: s.nameBytes(node))?.displayName ?? "File"
    }
    return InspectorInfo(
        path: s.path(node), allocated: n.allocated, logical: n.logical, kind: kind,
        modified: Date(timeIntervalSince1970: TimeInterval(n.modified)))
}

/// The inspector's view of `tiles[index]`, which may stand for no single
/// node: an aggregate reports the collapsed siblings ("N smaller items — X",
/// their bytes, their logical size summed from the snapshot); the collapsed
/// permission-denied placeholder reports "N unreadable folders". Neither has
/// a date.
public func inspect(tileAt index: Int, in tiles: [Tile], snapshot s: Snapshot) -> InspectorInfo {
    precondition(tiles.indices.contains(index), "inspect: tile \(index) outside the list")
    let t = tiles[index]
    if t.node != Tile.noNode { return inspect(t.node, in: s) }
    if t.isPermissionDenied {
        let n = t.aggregateCount
        return InspectorInfo(
            path: "\(n) unreadable \(n == 1 ? "folder" : "folders")", allocated: 0, logical: 0,
            kind: "Unreadable folders", modified: nil)
    }
    let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: t.aggregateBytes), countStyle: .file)
    return InspectorInfo(
        path: "\(t.aggregateCount) smaller \(t.aggregateCount == 1 ? "item" : "items") — \(bytes)",
        allocated: t.aggregateBytes, logical: aggregateLogical(index, tiles, s), kind: "Smaller items",
        modified: nil)
}

/// The logical bytes behind aggregate `tiles[index]`: its parent is the
/// nearest earlier node tile one level up that contains it, and the tail it
/// collapses is the last `aggregateCount` positive-size children of that
/// parent (children are sorted by size, the zero-size ones last). 0 if the
/// parent cannot be found.
private func aggregateLogical(_ index: Int, _ tiles: [Tile], _ s: Snapshot) -> UInt64 {
    let t = tiles[index]
    let centre = CGPoint(x: t.rect.midX, y: t.rect.midY)
    var i = index - 1
    while i >= 0 {
        let p = tiles[i]
        if p.node != Tile.noNode, p.depth + 1 == t.depth, p.rect.contains(centre) { break }
        i -= 1
    }
    guard i >= 0 else { return 0 }
    let kids = s.children(tiles[i].node)
    var positiveEnd = kids.upperBound
    while positiveEnd > kids.lowerBound && s.allocated(positiveEnd - 1) == 0 { positiveEnd -= 1 }
    let count = min(UInt32(t.aggregateCount), positiveEnd - kids.lowerBound)
    var sum: UInt64 = 0
    for c in (positiveEnd - count)..<positiveEnd {
        let (v, overflow) = sum.addingReportingOverflow(s.nodes[Int(c)].logical)
        sum = overflow ? UInt64.max : v
    }
    return sum
}
