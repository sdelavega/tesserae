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

import AppKit
import Combine
import SwiftUI

/// The file table (spec §8): an `NSTableView` whose data source reads the
/// snapshot through `rows`, an array of node indices. Columns Name, Allocated,
/// Logical, Modified, Kind. Clicking a header reports the sort through
/// `onSort` (the caller sorts off the main actor and passes new `rows`).
/// Selecting rows writes `selection`; changes to `selection` select the
/// matching rows, so table and treemap highlight each other.
public struct FileTableView: NSViewRepresentable {
    public var snapshot: Snapshot
    public var rows: [UInt32]
    public var selection: Selection
    public var onSort: ((SortKey, Bool) -> Void)?
    public var locale: Locale

    public init(
        snapshot: Snapshot, rows: [UInt32], selection: Selection, locale: Locale = .current,
        onSort: ((SortKey, Bool) -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.rows = rows
        self.selection = selection
        self.locale = locale
        self.onSort = onSort
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot, rows: rows, selection: selection, locale: locale)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        c.onSort = onSort
        let scroll = NSScrollView()
        scroll.documentView = c.makeTableView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.onSort = onSort
        c.update(snapshot: snapshot, rows: rows)
    }

    /// Data source and delegate; owns the snapshot it reads.
    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columns: [(id: String, title: String, key: SortKey, width: CGFloat)] = [
            ("name", "Name", .name, 280), ("allocated", "Allocated", .allocated, 90),
            ("logical", "Logical", .logical, 90), ("modified", "Modified", .modified, 140),
            ("kind", "Kind", .kind, 100),
        ]

        /// What the Modified column shows for a stored time of 0 (never read).
        static let unknownDate = "—"

        // The strong reference keeps the borrowed Rust memory alive for the cells.
        private(set) var snapshot: Snapshot
        private(set) var rows: [UInt32]
        let selection: Selection
        let locale: Locale
        var onSort: ((SortKey, Bool) -> Void)?
        private(set) weak var table: NSTableView?
        private var cancellable: AnyCancellable?
        /// True while this side is writing the table's selection, so the
        /// resulting notification is not echoed back into `selection`.
        private var applyingSelection = false

        public init(snapshot: Snapshot, rows: [UInt32], selection: Selection, locale: Locale = .current) {
            self.snapshot = snapshot
            self.rows = rows
            self.selection = selection
            self.locale = locale
            super.init()
        }

        /// The table, wired to this coordinator and to `selection`.
        public func makeTableView() -> NSTableView {
            let t = NSTableView()
            for col in Coordinator.columns {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
                c.title = col.title
                c.width = col.width
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: col.key == .name)
                t.addTableColumn(c)
            }
            t.allowsMultipleSelection = true
            t.usesAlternatingRowBackgroundColors = true
            t.dataSource = self
            t.delegate = self
            table = t
            t.reloadData()
            cancellable = selection.$nodes.sink { [weak self] new in
                self?.select(new)
            }
            return t
        }

        func update(snapshot s: Snapshot, rows r: [UInt32]) {
            guard s !== snapshot || r != rows else { return }
            snapshot = s
            rows = r
            applyingSelection = true  // reloading drops the table's selection; that is not the user's
            table?.reloadData()
            applyingSelection = false
            select(selection.nodes)
        }

        /// Show `nodes` as the table's selection and scroll the first selected
        /// row into view. Nodes that are not among the current rows (a
        /// directory, or a file outside the top-K) are not shown in the table;
        /// they stay in `selection` until the table itself writes it.
        private func select(_ nodes: Set<UInt32>) {
            guard let table else { return }
            var idx = IndexSet()
            for (row, n) in rows.enumerated() where nodes.contains(n) { idx.insert(row) }
            guard idx != table.selectedRowIndexes else { return }
            applyingSelection = true
            table.selectRowIndexes(idx, byExtendingSelection: false)
            applyingSelection = false
            // A selection made elsewhere (the treemap): bring it into view.
            if let first = idx.first { table.scrollRowToVisible(first) }
        }

        // MARK: Text

        /// The text of one cell; the inspector's own formatting, so they agree.
        func text(column id: String, row: Int) -> String {
            let node = rows[row]
            // Rows and snapshot arrive separately from SwiftUI; never trap on a mismatch.
            guard Int(node) < snapshot.nodes.count else { return "" }
            let n = snapshot.nodes[Int(node)]
            switch id {
            case "name": return snapshot.displayName(node)
            case "allocated": return displaySize(n.allocated, locale: locale)
            case "logical": return displaySize(n.logical, locale: locale)
            case "modified":
                guard n.modified != 0 else { return Coordinator.unknownDate }
                return Date(timeIntervalSince1970: TimeInterval(n.modified))
                    .formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            default: return nodeKind(node, in: snapshot).displayName
            }
        }

        /// The VoiceOver label (spec §12): always the name and the allocated
        /// size ("report.pdf, 4.2 GB"), then what this column adds.
        func accessibilityLabel(column id: String, row: Int) -> String {
            let node = rows[row]
            guard Int(node) < snapshot.nodes.count else { return "" }
            let base = "\(snapshot.displayName(node)), \(displaySize(snapshot.allocated(node), locale: locale))"
            switch id {
            case "name": return base
            case "allocated": return base + " allocated"
            case "logical": return base + ", logical \(text(column: id, row: row))"
            case "modified":
                let m = snapshot.nodes[Int(node)].modified
                return base + (m == 0 ? ", modified unknown" : ", modified \(text(column: id, row: row))")
            default: return base + ", \(text(column: id, row: row))"
            }
        }

        // MARK: Data source and delegate

        public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: text(column: id, row: row))
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            if id == "allocated" || id == "logical" {
                field.alignment = .right
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            let label = accessibilityLabel(column: id, row: row)
            cell.setAccessibilityLabel(label)
            field.setAccessibilityLabel(label)
            return cell
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let chosen = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) && Int(rows[$0]) < snapshot.nodes.count ? rows[$0] : nil })
            if chosen != selection.nodes { selection.nodes = chosen }
        }

        public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key,
                let col = Coordinator.columns.first(where: { $0.id == key })
            else { return }
            onSort?(col.key, d.ascending)
        }
    }
}
