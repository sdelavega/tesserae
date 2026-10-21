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
public struct PlacedLabel: Equatable, Sendable {
    public var rect: CGRect
    public var text: String
    /// The tile the label sits on, so the overlay can choose its ink from the
    /// tile's colour in whatever mode and appearance are current.
    public var tile: Tile

    public init(rect: CGRect, text: String, tile: Tile) {
        self.rect = rect
        self.text = text
        self.tile = tile
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
///   there would sit under theirs): one that is the `parent` of any tile,
///   whether a node, an aggregate or an unreadable-folders square. A leaf, a terminal directory, a file and an aggregate can.
/// * Permission-denied placeholders (`permDenied` with a node) get none; the
///   collapsed "N unreadable folders" square does, as do aggregates
///   ("N smaller items — X"), with the inspector's wording.
/// * A name's newlines and tabs read as spaces; any other control character,
///   bidi override or isolate, and invisible format character (category Cf,
///   except the joiners U+200C/U+200D that emoji and some scripts need) as
///   U+FFFD. The name is decoded from its bytes, not taken from
///   `Snapshot.name`, which would make a newline U+FFFD too. A name that is
///   then empty reads "(unnamed)".
/// * `measure` gives the size of a one-line string in the label font. If the
///   whole text does not fit, only the *words* (the name, or "N smaller
///   items") are cut in the middle, by whole characters (grapheme clusters),
///   keeping the most that fit but at least `minKeptCharacters`; the size is
///   never cut, and if the size and three characters do not fit there is no
///   label. Fitting is assumed to be monotone in the characters kept.
/// * Numbers are written for `locale`.
/// * Run inside a task that is cancelled, it stops early and returns what it
///   has placed so far; the caller discards that result.
public func placeLabels(
    _ tiles: [Tile], in s: Snapshot, measure: (String) -> CGSize, max: Int = 400,
    locale: Locale = .current, overlay: SizeOverlay = SizeOverlay()
) -> [PlacedLabel] {
    guard max > 0 else { return [] }
    let pad = labelPadding
    // Directories that were subdivided: the parent of any tile (a node, an
    // aggregate or a placeholder). One pass; no per-directory search.
    var subdivided = Set<UInt32>()
    for t in tiles where t.parent != Tile.noNode { subdivided.insert(t.parent) }
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
        if out.count >= max || Task.isCancelled { break }
        let t = tiles[i]
        guard
            let parts = labelParts(
                for: t, in: s, subdivided: subdivided, locale: locale, overlay: overlay)
        else { continue }
        let room = CGSize(width: t.rect.width - 2 * pad, height: t.rect.height - 2 * pad)
        guard let (text, size) = fit(parts.words, suffix: parts.suffix, in: room, measure: measure) else { continue }
        out.append(
            PlacedLabel(
                rect: CGRect(x: t.rect.minX + pad, y: t.rect.minY + pad, width: size.width, height: size.height),
                text: text, tile: t))
    }
    return out
}

/// The truncatable words and the fixed tail of tile `t`'s label, or nil for a
/// tile that gets none.
private func labelParts(
    for t: Tile, in s: Snapshot, subdivided: Set<UInt32>, locale: Locale, overlay: SizeOverlay
) -> (words: String, suffix: String)? {
    if t.node == Tile.noNode {
        if t.isPermissionDenied {
            return (InspectorInfo.unreadableWords(count: t.aggregateCount, locale: locale), "")
        }
        let (words, size) = InspectorInfo.aggregateParts(count: t.aggregateCount, bytes: t.aggregateBytes, locale: locale)
        return (words, InspectorInfo.aggregateSeparator + size)
    }
    if t.isPermissionDenied { return nil }
    precondition(Int(t.node) < s.nodes.count, "placeLabels: tile node \(t.node) outside the snapshot")
    if subdivided.contains(t.node) { return nil }
    return (s.displayName(t.node), "  " + displaySize(OverlaySource(s, overlay).allocated(t.node), locale: locale))
}

extension Snapshot {
    /// Node `i`'s name as the user reads it, on one line (`singleLine`):
    /// tile labels, the table's cells and VoiceOver labels and the breadcrumb
    /// all show this, so a crafted name (a bidi override, a newline, an
    /// invisible format character) cannot reorder or hide what any of them
    /// says (spec §8; final review I2). Display text only: actions use the
    /// node index and `rawPath(_:)`.
    public func displayName(_ i: UInt32) -> String {
        Self.displayName(bytes: nameBytes(i))
    }

    static func displayName(bytes: Data) -> String {
        let name = singleLine(String(decoding: bytes, as: UTF8.self)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "(unnamed)" : name
    }
}

/// `text` for one line of display (see `placeLabels`): newlines, tabs and
/// line/paragraph separators read as spaces; other control characters, bidi
/// overrides and isolates and invisible format characters (except the joiners
/// U+200C/U+200D) as U+FFFD.
func singleLine(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for u in text.unicodeScalars {
        switch u.value {
        case 0x09, 0x0a, 0x0d, 0x2028, 0x2029: out.append(" ")
        case 0..<0x20, 0x7f..<0xa0: out.append("\u{FFFD}")
        case 0x200c, 0x200d: out.append(u)
        default: out.append(u.properties.generalCategory == .format ? "\u{FFFD}" : u)
        }
    }
    return String(out)
}

/// The longest middle-truncation of `words` that, followed by `suffix`, fits
/// `room`; nil if none keeps enough of the words.
///
/// The shortest candidate is measured first: when it does not fit (a tile too
/// small or too short for any label), that is the only `measure` call.
private func fit(
    _ words: String, suffix: String, in room: CGSize, measure: (String) -> CGSize
) -> (String, CGSize)? {
    func fits(_ text: String) -> CGSize? {
        let z = measure(text)
        return z.width <= room.width && z.height <= room.height ? z : nil
    }
    let chars = Array(words)  // Characters: grapheme clusters, never split
    func text(keeping k: Int) -> String {
        if k >= chars.count { return words + suffix }
        let head = (k + 1) / 2
        return String(chars[..<head]) + "…" + String(chars[(chars.count - (k - head))...]) + suffix
    }
    let floor = min(minKeptCharacters, chars.count)
    guard fits(text(keeping: floor)) != nil else { return nil }
    if let z = fits(words + suffix) { return (words + suffix, z) }
    var lo = floor  // fits
    var hi = chars.count - 1  // the largest k not yet ruled out (k = count failed)
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if fits(text(keeping: mid)) != nil { lo = mid } else { hi = mid - 1 }
    }
    let result = text(keeping: lo)
    return fits(result).map { (result, $0) }
}
