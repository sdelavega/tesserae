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

/// One label to draw: where (points, the tile's coordinate space) and what.
public struct PlacedLabel: Equatable {
    public var rect: CGRect
    public var text: String

    public init(rect: CGRect, text: String) {
        self.rect = rect
        self.text = text
    }
}

/// Space kept free between a label and the edge of its tile (spec §8 "Labels").
public let labelPadding: CGFloat = 4

/// Fewest characters of a name a truncated label may keep (head + tail).
private let minKeptCharacters = 3

/// The labels for `tiles` (spec §8 "Labels"): name plus size, middle-truncated,
/// one line, only where the text fits inside the tile with `labelPadding` on
/// every side.
///
/// * Candidates are visited largest tile first (ties in tile order) and at
///   most `max` labels are placed.
/// * A *subdivided* directory gets none (its children cover it, and a label
///   there would sit under theirs); a leaf, a terminal directory, a file and
///   an aggregate can.
/// * Permission-denied placeholders (`permDenied` with a node) get none; the
///   collapsed "N unreadable folders" square does, as do aggregates
///   ("N smaller items — X"), with the inspector's wording.
/// * A name's newlines and tabs read as spaces and any other control
///   character as U+FFFD (the name is decoded from its bytes, not taken from
///   `Snapshot.name`, which would make a newline U+FFFD too); a name that is
///   then empty reads "(unnamed)".
/// * `measure` gives the size of a one-line string in the label font. If the
///   whole text does not fit, the *name* is cut in the middle ("very-lo…ame.mov
///   4.2 GB"), keeping the most characters that fit, but at least
///   `minKeptCharacters`; if even that does not fit there is no label.
///   Fitting is assumed to be monotone in the characters kept.
public func placeLabels(
    _ tiles: [Tile], in s: Snapshot, measure: (String) -> CGSize, max: Int = 400
) -> [PlacedLabel] {
    guard max > 0 else { return [] }
    let pad = labelPadding
    let nodesWithTiles = Set(tiles.lazy.filter { $0.node != Tile.noNode }.map(\.node))
    let order = tiles.indices.filter { i in
        let r = tiles[i].rect
        return r.width > 2 * pad && r.height > 2 * pad
    }.sorted { a, b in
        let aa = tiles[a].rect.width * tiles[a].rect.height
        let ab = tiles[b].rect.width * tiles[b].rect.height
        return aa != ab ? aa > ab : a < b
    }
    var out: [PlacedLabel] = []
    for i in order {
        if out.count >= max { break }
        let t = tiles[i]
        guard let parts = labelParts(for: t, in: s, nodesWithTiles: nodesWithTiles) else { continue }
        let room = CGSize(width: t.rect.width - 2 * pad, height: t.rect.height - 2 * pad)
        guard let (text, size) = fit(parts.name, suffix: parts.suffix, in: room, measure: measure) else { continue }
        out.append(
            PlacedLabel(
                rect: CGRect(x: t.rect.minX + pad, y: t.rect.minY + pad, width: size.width, height: size.height),
                text: text))
    }
    return out
}

/// The truncatable name and the fixed tail of tile `t`'s label, or nil for a
/// tile that gets none.
private func labelParts(for t: Tile, in s: Snapshot, nodesWithTiles: Set<UInt32>) -> (name: String, suffix: String)? {
    if t.node == Tile.noNode {
        let info: InspectorInfo
        if t.isPermissionDenied {
            info = InspectorInfo(
                subject: .unreadable(count: t.aggregateCount), allocated: 0, logical: 0, kind: .unreadable,
                modified: nil)
        } else {
            info = InspectorInfo(
                subject: .aggregate(count: t.aggregateCount, bytes: t.aggregateBytes), allocated: t.aggregateBytes,
                logical: 0, kind: .aggregate, modified: nil)
        }
        return (info.title, "")
    }
    if t.isPermissionDenied { return nil }
    precondition(Int(t.node) < s.nodes.count, "placeLabels: tile node \(t.node) outside the snapshot")
    if s.isDirectory(t.node) {
        let kids = s.children(t.node)
        if !kids.isEmpty && nodesWithTiles.contains(kids.lowerBound) { return nil }
    }
    return (labelName(t.node, s), "  " + displaySize(s.allocated(t.node)))
}

/// Node `i`'s name on one line (see `placeLabels`).
func labelName(_ i: UInt32, _ s: Snapshot) -> String {
    var out = String.UnicodeScalarView()
    for u in String(decoding: s.nameBytes(i), as: UTF8.self).unicodeScalars {
        switch u.value {
        case 0x09, 0x0a, 0x0d, 0x2028, 0x2029: out.append(" ")
        case 0..<0x20, 0x7f..<0xa0: out.append("\u{FFFD}")
        default: out.append(u)
        }
    }
    let name = String(out).trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "(unnamed)" : name
}

/// The longest middle-truncation of `name` that, followed by `suffix`, fits
/// `room`; nil if none keeps enough of the name.
private func fit(
    _ name: String, suffix: String, in room: CGSize, measure: (String) -> CGSize
) -> (String, CGSize)? {
    func fits(_ text: String) -> CGSize? {
        let z = measure(text)
        return z.width <= room.width && z.height <= room.height ? z : nil
    }
    func text(keeping k: Int, of chars: [Character]) -> String {
        if k >= chars.count { return name + suffix }
        let head = (k + 1) / 2
        return String(chars[..<head]) + "…" + String(chars[(chars.count - (k - head))...]) + suffix
    }
    let chars = Array(name)
    if let z = fits(name + suffix) { return (name + suffix, z) }
    var lo = min(minKeptCharacters, chars.count)  // known only to be the floor
    guard lo < chars.count, fits(text(keeping: lo, of: chars)) != nil else { return nil }
    var hi = chars.count - 1  // the largest k not yet ruled out (k = count already failed)
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if fits(text(keeping: mid, of: chars)) != nil { lo = mid } else { hi = mid - 1 }
    }
    let result = text(keeping: lo, of: chars)
    return fits(result).map { (result, $0) }
}
