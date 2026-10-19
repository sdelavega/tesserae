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

/// Whether the caller is on the process's main thread (`Thread.isMainThread`
/// is unavailable from async contexts).
func onMainThread() -> Bool { pthread_main_np() != 0 }

/// A column the file table can sort by.
public enum SortKey: Sendable, Equatable {
    case name, allocated, logical, modified, kind
}

/// The rows of the file table: node indices into one snapshot, never copied
/// nodes. The model keeps the snapshot alive for as long as it exists, and
/// sorting captures it, so a sort in flight cannot outlive the memory it reads.
public final class FileTableModel: @unchecked Sendable {
    /// How many files the default view lists.
    public static let defaultLimit = 1000

    public let snapshot: Snapshot
    public let scope: UInt32
    public let limit: Int

    private let lock = NSLock()
    private var cached: [UInt32]?

    /// Test seam: called on the thread that sorts, with `onMainThread()`.
    var onSort: (@Sendable (Bool) -> Void)?

    /// The table for the subtree of `scope` (the current navigation root):
    /// its `limit` largest files.
    public init(snapshot: Snapshot, scope: UInt32, limit: Int = FileTableModel.defaultLimit) {
        precondition(Int(scope) < snapshot.nodes.count, "FileTableModel: scope outside the snapshot")
        self.snapshot = snapshot
        self.scope = scope
        self.limit = limit
    }

    /// The rows before any column sort: largest first, ties by node index.
    public func defaultRows() -> [UInt32] {
        lock.lock()
        if let c = cached {
            lock.unlock()
            return c
        }
        lock.unlock()
        let rows = topK(limit, files: snapshot, under: scope)
        lock.lock()
        cached = rows
        lock.unlock()
        return rows
    }

    /// The rows ordered by `key`, computed off the main actor. Equal keys keep
    /// the default order whichever way the sort runs (a stable sort), so
    /// reversing the direction never reverses a run of ties.
    public func sorted(by key: SortKey, ascending: Bool) async -> [UInt32] {
        let model = self
        return await Task.detached(priority: .userInitiated) {
            model.onSort?(onMainThread())
            return model.sortNow(by: key, ascending: ascending)
        }.value
    }

    func sortNow(by key: SortKey, ascending: Bool) -> [UInt32] {
        let rows = defaultRows()
        let s = snapshot
        // Keys are computed once per row; the sort then orders positions.
        let order: (Int, Int) -> Int  // <0: a before b, ascending
        switch key {
        case .allocated:
            let k = rows.map { s.allocated($0) }
            order = { k[$0] < k[$1] ? -1 : (k[$0] > k[$1] ? 1 : 0) }
        case .logical:
            let k = rows.map { s.nodes[Int($0)].logical }
            order = { k[$0] < k[$1] ? -1 : (k[$0] > k[$1] ? 1 : 0) }
        case .modified:
            // A stored 0 is "never read" (the Inspector reports it unknown): oldest.
            let k = rows.map { i -> Int64 in
                let m = s.nodes[Int(i)].modified
                return m == 0 ? Int64.min : m
            }
            order = { k[$0] < k[$1] ? -1 : (k[$0] > k[$1] ? 1 : 0) }
        case .name:
            let k = rows.map { s.name($0) }
            order = { Self.sign(k[$0].localizedStandardCompare(k[$1])) }
        case .kind:
            let k = rows.map { nodeKind($0, in: s).displayName }
            order = { Self.sign(k[$0].localizedStandardCompare(k[$1])) }
        }
        let positions = rows.indices.sorted { a, b in
            let c = order(a, b)
            if c != 0 { return ascending ? c < 0 : c > 0 }
            return a < b  // ties keep the default order
        }
        return positions.map { rows[$0] }
    }

    private static func sign(_ r: ComparisonResult) -> Int {
        switch r {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }
}

/// The rows the table currently shows, and the guard that keeps a slow sort
/// from landing on a table that has since moved on.
///
/// Every `load` and every sort request takes a new generation number; a
/// sorted result is applied only if its number is still the latest, so a sort
/// for an old snapshot, an old scope or an old column click is dropped.
@MainActor
public final class FileTableRows: ObservableObject {
    @Published public private(set) var rows: [UInt32] = []
    public private(set) var model: FileTableModel?
    private(set) var generation: UInt64 = 0

    public init() {}

    /// Show `model` (nil for none) with its default rows, dropping every sort in flight.
    /// The default rows are computed off the main actor too.
    public func load(_ model: FileTableModel?) async {
        self.model = model
        generation &+= 1
        let mine = generation
        guard let model else {
            rows = []
            return
        }
        let result = await Task.detached(priority: .userInitiated) { model.defaultRows() }.value
        _ = accept(result, generation: mine)
    }

    /// Start a sort; returns the generation its result must present.
    func beginSort() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Apply `result` if `generation` is still the latest. Returns whether it was.
    @discardableResult
    func accept(_ result: [UInt32], generation g: UInt64) -> Bool {
        guard g == generation else { return false }
        rows = result
        return true
    }

    /// Sort the shown model's rows by `key` off the main actor and show them,
    /// unless something newer happened meanwhile. Returns whether they were shown.
    @discardableResult
    public func sort(by key: SortKey, ascending: Bool) async -> Bool {
        guard let model else { return false }
        let mine = beginSort()
        let result = await model.sorted(by: key, ascending: ascending)
        return accept(result, generation: mine)
    }
}
