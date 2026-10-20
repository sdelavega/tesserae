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
/// `subject` says what the tile stands for. Only a `.node` stands for a file,
/// and its actionable identity is its index (`node`) plus its raw path bytes
/// (`rawPath`, exactly as the filesystem names it). An action that needs a
/// real file (copy path, reveal in Finder, staging for deletion) gates on
/// `node` and uses `rawPath`; it never uses `displayPath` or `title`, which are
/// lossy display text that may name no file, or a different one (final review
/// I1). All three are nil for a tile that is not one node.
public struct InspectorInfo: Equatable {
    public enum Subject: Equatable {
        /// One node: its index, its exact path bytes (`Snapshot.rawPath`) and
        /// its path for display (`Snapshot.displayPath`).
        case node(UInt32, rawPath: Data, displayPath: String)
        /// An aggregate tile: `count` collapsed siblings of `bytes` in all.
        case aggregate(count: UInt32, bytes: UInt64)
        /// The collapsed placeholder of `count` unreadable folders.
        case unreadable(count: UInt32)
    }

    public enum Kind: Equatable {
        case folder, file
        case fileKind(FileKind)
        case aggregate, unreadable

        public var displayName: String {
            switch self {
            case .folder: return "Folder"
            case .file: return "File"
            case .fileKind(let k): return k.displayName
            case .aggregate: return "Smaller items"
            case .unreadable: return "Unreadable folders"
            }
        }
    }

    public var subject: Subject
    public var allocated, logical: UInt64
    public var kind: Kind
    /// Nil when unknown: no single node, or a stored time of 0 (never read).
    public var modified: Date?

    public init(subject: Subject, allocated: UInt64, logical: UInt64, kind: Kind, modified: Date?) {
        self.subject = subject
        self.allocated = allocated
        self.logical = logical
        self.kind = kind
        self.modified = modified
    }

    /// The node this tile stands for; nil for a tile that is not one node.
    public var node: UInt32? {
        if case .node(let n, _, _) = subject { return n }
        return nil
    }

    /// The node's path exactly as the filesystem names it, byte for byte
    /// (not necessarily UTF-8): what reveal, copy, stage and delete must use.
    /// Nil for a tile that is not one node.
    public var rawPath: Data? {
        if case .node(_, let raw, _) = subject { return raw }
        return nil
    }

    /// The node's path for display: lossy, so never acted on. Nil for a tile
    /// that is not one node.
    public var displayPath: String? {
        if case .node(_, _, let p) = subject { return p }
        return nil
    }

    /// The heading: the display path, "N smaller items — X" or "N unreadable folders",
    /// numbers written for the current locale.
    public var title: String { title(locale: .current) }

    /// `title` on one line, sanitised as tile labels are (`singleLine`), for
    /// the inspector heading. Display text: actions use `node` and `rawPath`.
    public var displayTitle: String { singleLine(title) }

    /// `title` with numbers written for `locale`.
    public func title(locale: Locale) -> String {
        switch subject {
        case .node(_, _, let p):
            return p
        case .aggregate(let n, let bytes):
            let (words, size) = InspectorInfo.aggregateParts(count: n, bytes: bytes, locale: locale)
            return words + InspectorInfo.aggregateSeparator + size
        case .unreadable(let n):
            return InspectorInfo.unreadableWords(count: n, locale: locale)
        }
    }

    /// What separates the words from the size in an aggregate's title.
    static let aggregateSeparator = " — "

    /// An aggregate's title in two parts, "N smaller items" and its size, so
    /// a caller that has to shorten the title can keep the size whole.
    static func aggregateParts(count n: UInt32, bytes: UInt64, locale: Locale) -> (words: String, size: String) {
        ("\(displayCount(n, locale: locale)) smaller \(n == 1 ? "item" : "items")", displaySize(bytes, locale: locale))
    }

    /// "N unreadable folders".
    static func unreadableWords(count n: UInt32, locale: Locale) -> String {
        "\(displayCount(n, locale: locale)) unreadable \(n == 1 ? "folder" : "folders")"
    }
}

/// How the inspector and the tile labels write a byte count ("4.2 GB"), in
/// `locale`'s digits and unit names (macOS 12+ `ByteCountFormatStyle`;
/// `ByteCountFormatter` has no locale property).
public func displaySize(_ bytes: UInt64, locale: Locale = .current) -> String {
    Int64(clamping: bytes).formatted(.byteCount(style: .file).locale(locale))
}

/// How the inspector and the tile labels write a count ("12,345").
func displayCount(_ n: UInt32, locale: Locale = .current) -> String {
    let f = NumberFormatter()
    f.locale = locale
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? String(n)
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

/// The kind of node `node`: a folder, a file of a known `FileKind`, or a file.
/// The inspector and the file table share it, so they always agree.
func nodeKind(_ node: UInt32, in s: Snapshot) -> InspectorInfo.Kind {
    if s.isDirectory(node) { return .folder }
    return FileKind.kind(forName: s.nameBytes(node)).map { .fileKind($0) } ?? .file
}

/// The inspector's view of node `node`.
///
/// * Sizes are the node's own: for a directory, rolled up over its subtree.
/// * `kind` is `.folder` for a directory, `.fileKind` for a file whose
///   extension has a `FileKind`, and `.file` otherwise.
/// * `modified` is the node's time as the snapshot holds it: a file's own
///   time as read; a directory's, the latest in its subtree not later than
///   the scan's start (the freeze's rollup). A stored 0 is what the scan
///   records when it got no time (the attribute was not returned), so it is
///   reported as unknown (nil), not as 1 January 1970.
public func inspect(_ node: UInt32, in s: Snapshot) -> InspectorInfo {
    precondition(Int(node) < s.nodes.count, "inspect: node \(node) outside the snapshot")
    let n = s.nodes[Int(node)]
    let kind = nodeKind(node, in: s)
    return InspectorInfo(
        subject: .node(node, rawPath: s.rawPath(node), displayPath: s.displayPath(node)), allocated: n.allocated, logical: n.logical, kind: kind,
        modified: n.modified == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(n.modified)))
}

/// The inspector's view of `tiles[index]`, which may stand for no single
/// node: an aggregate reports the collapsed siblings (their count and bytes,
/// their logical size summed from the snapshot); the collapsed
/// permission-denied placeholder reports how many folders it stands for.
/// Neither has a path or a date.
public func inspect(tileAt index: Int, in tiles: [Tile], snapshot s: Snapshot) -> InspectorInfo {
    precondition(tiles.indices.contains(index), "inspect: tile \(index) outside the list")
    let t = tiles[index]
    if t.node != Tile.noNode { return inspect(t.node, in: s) }
    if t.isPermissionDenied {
        return InspectorInfo(
            subject: .unreadable(count: t.aggregateCount), allocated: 0, logical: 0, kind: .unreadable,
            modified: nil)
    }
    return InspectorInfo(
        subject: .aggregate(count: t.aggregateCount, bytes: t.aggregateBytes), allocated: t.aggregateBytes,
        logical: aggregateLogical(index, tiles, s), kind: .aggregate, modified: nil)
}

/// The logical bytes behind aggregate `tiles[index]`: its parent is the
/// tile's own `parent` (the directory it was laid out in), and the tail it
/// collapses is the last `aggregateCount` positive-size children of that
/// parent (children are sorted by size, the zero-size ones last). This
/// mirrors `squarify`'s collapse rule (SquarifiedLayout.swift, "the tail is a
/// suffix"): change the two together. 0 if the tile names no parent in `s`.
///
/// No depth arithmetic: `Tile.depth` saturates at 255, so "one level up"
/// cannot be told from it (final review C1).
private func aggregateLogical(_ index: Int, _ tiles: [Tile], _ s: Snapshot) -> UInt64 {
    let t = tiles[index]
    guard t.parent != Tile.noNode, Int(t.parent) < s.nodes.count else { return 0 }
    let kids = s.children(t.parent)
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
