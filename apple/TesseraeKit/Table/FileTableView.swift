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
/// snapshot and overlay through `rows`, an array of node indices. Columns Name, Reported Size,
/// Allocated, Modified, Kind. Clicking a header reports the sort through
/// `onSort` (the caller sorts off the main actor and passes new `rows`).
/// Selecting rows writes `selection`; changes to `selection` select the
/// matching rows, so table and treemap highlight each other.
public struct FileTableView: NSViewRepresentable {
    public var overlay: SizeOverlay
    public var snapshot: Snapshot
    public var rows: [UInt32]
    public var selection: Selection
    public var onSort: ((SortKey, Bool) -> Void)?
    public var onStage: (() -> Void)?
    public var locale: Locale

    public init(
        snapshot: Snapshot, rows: [UInt32], selection: Selection, overlay: SizeOverlay = SizeOverlay(), locale: Locale = .current, onStage: (() -> Void)? = nil,
        onSort: ((SortKey, Bool) -> Void)? = nil
    ) {
        self.overlay = overlay
        self.snapshot = snapshot
        self.rows = rows
        self.selection = selection
        self.locale = locale
        self.onStage = onStage
        self.onSort = onSort
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot, rows: rows, selection: selection, overlay: overlay, locale: locale)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        c.contextMenu.stage = onStage
        c.onSort = onSort
        let scroll = FittingTableScrollView()
        scroll.documentView = c.makeTableView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.contextMenu.stage = onStage
        c.onSort = onSort
        c.update(snapshot: snapshot, rows: rows, overlay: overlay)
    }

    /// Data source and delegate; owns the snapshot it reads.
    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columns: [(id: String, title: String, key: SortKey, width: CGFloat)] = [
            ("name", String(
                localized: "fileTableView.name",
                defaultValue: "Name",
                bundle: L10n.bundle,
                comment: "FileTableView: Name."
            ), .name, 280),
            ("logical", SizeColumnText.reported, .logical, 110),
            ("allocated", SizeColumnText.allocated, .allocated, 90), ("modified", String(
                localized: "fileTableView.modified",
                defaultValue: "Modified",
                bundle: L10n.bundle,
                comment: "FileTableView: Modified."
            ), .modified, TableDates.width(locale: .current)),
            ("kind", String(
                localized: "fileTableView.kind",
                defaultValue: "Kind",
                bundle: L10n.bundle,
                comment: "FileTableView: Kind."
            ), .kind, 80),
        ]

        /// What the Modified column shows for a stored time of 0 (never read).
        static let unknownDate = "—"

        // The strong reference keeps the borrowed Rust memory alive for the cells.
        private(set) var overlay: SizeOverlay
        private(set) var snapshot: Snapshot
        private(set) var rows: [UInt32]
        let selection: Selection
        let locale: Locale
        var onSort: ((SortKey, Bool) -> Void)?
        let contextMenu = ReclaimContextMenu()
        private(set) weak var table: NSTableView?
        private var cancellable: AnyCancellable?
        /// True while this side is writing the table's selection, so the
        /// resulting notification is not echoed back into `selection`.
        private var applyingSelection = false

        public init(snapshot: Snapshot, rows: [UInt32], selection: Selection, overlay: SizeOverlay = SizeOverlay(), locale: Locale = .current) {
            self.overlay = overlay
            self.snapshot = snapshot
            self.rows = rows
            self.selection = selection
            self.locale = locale
            super.init()
        }

        /// The table, wired to this coordinator and to `selection`.
        public func makeTableView() -> NSTableView {
            let t = ReclaimTableView()
            t.style = .plain
            t.reclaimMenu = contextMenu
            t.prepareContext = { [weak self, weak t] event in
                guard let self, let t else { return false }
                let row = t.row(at: t.convert(event.locationInWindow, from: nil))
                guard self.rows.indices.contains(row) else { return false }
                let node = self.rows[row]
                if !self.selection.nodes.contains(node) { self.selection.nodes = [node] }
                return true
            }
            for col in Coordinator.columns {
                let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
                c.title = col.title
                c.headerToolTip = SizeColumnText.help(col.id)
                let width = col.id == "modified" ? TableDates.width(locale: locale) : col.width
                c.width = width
                c.minWidth = col.id == "name" ? 180 : width
                c.maxWidth = col.id == "name" ? 10_000 : width
                c.resizingMask = []
                c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: col.key == .name)
                t.addTableColumn(c)
            }
            t.intercellSpacing = NSSize(width: 3, height: 0)
            t.columnAutoresizingStyle = .noColumnAutoresizing
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

        func update(snapshot s: Snapshot, rows r: [UInt32], overlay o: SizeOverlay = SizeOverlay()) {
            guard s !== snapshot || r != rows || o.revision != overlay.revision else { return }
            overlay = o
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
            let source = OverlaySource(snapshot, overlay)
            switch id {
            case "name": return snapshot.displayName(node)
            case "allocated": return displaySize(source.allocated(node), locale: locale)
            case "logical": return displaySize(source.logical(node), locale: locale)
            case "modified":
                guard n.modified != 0 else { return Coordinator.unknownDate }
                return TableDates.text(n.modified, locale: locale)
            default: return nodeKind(node, in: snapshot).displayName
            }
        }

        /// VoiceOver reads the name and both sizes before any other column detail.
        func accessibilityLabel(column id: String, row: Int) -> String {
            let node = rows[row]
            guard Int(node) < snapshot.nodes.count else { return "" }
            let base = SizeColumnText.accessibility(name: snapshot.displayName(node),
                reported: text(column: "logical", row: row), allocated: text(column: "allocated", row: row))
            switch id {
            case "name", "logical", "allocated": return base
            case "modified":
                let m = snapshot.nodes[Int(node)].modified
                return base + (m == 0 ? String(
                    localized: "fileTableView.modified.unknown",
                    defaultValue: ", modified unknown",
                    bundle: L10n.bundle,
                    comment: "FileTableView: , modified unknown."
                ) : String(
                    localized: "fileTableView.modified.v2",
                    defaultValue: ", modified \(text(column: id, row: row))",
                    bundle: L10n.bundle,
                    comment: "FileTableView: , modified {text(column: id, row: row)}."
                ))
            default: return base + String(
                localized: "fileTableView.value",
                defaultValue: ", \(text(column: id, row: row))",
                bundle: L10n.bundle,
                comment: "FileTableView: , {text(column: id, row: row)}."
            )
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

private final class ReclaimTableView: NSTableView {
    var reclaimMenu: ReclaimContextMenu?
    var prepareContext: ((NSEvent) -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard prepareContext?(event) == true else { return nil }
        return reclaimMenu?.make()
    }
}


/// Fit every column within the viewport, giving the remaining space to Name.
private final class FittingTableScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let table = documentView as? NSTableView else { return }
        let columns = table.tableColumns
        guard columns.count == FileTableView.Coordinator.columns.count else { return }
        let fixed = columns.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(columns.count)
        columns[0].width = max(180, contentSize.width - fixed - spacing)
        table.setFrameSize(NSSize(width: contentSize.width, height: table.frame.height))
    }
}

/// Shared medium-date formatting and measured column geometry for both lists.
@MainActor
enum TableDates {
    static func formatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    static func text(_ seconds: Int64, locale: Locale) -> String {
        guard seconds != 0 else { return FileTableView.Coordinator.unknownDate }
        return formatter(locale: locale).string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func width(locale: Locale) -> CGFloat {
        let formatter = formatter(locale: locale)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = (1...12).compactMap { calendar.date(from: DateComponents(year: 2026, month: $0, day: 28, hour: 12)) }
            + [Date(timeIntervalSince1970: 1798718400)]
        return max(120, dates.map { ceil((formatter.string(from: $0) as NSString).size(withAttributes: [.font: font]).width) + 8 }.max() ?? 120)
    }
}

/// Shared catalogued wording for the two size columns and their VoiceOver labels.
enum SizeColumnText {
    static var reported: String { String(localized: "sizeColumns.reported", defaultValue: "Reported Size",
        bundle: L10n.bundle, comment: "Logical bytes column, matching Finder's Size, including folder subtree totals.") }
    static var allocated: String { String(localized: "fileTableView.allocated", defaultValue: "Allocated",
        bundle: L10n.bundle, comment: "Bytes occupied on disk, including folder subtree totals.") }
    static func help(_ id: String) -> String? {
        switch id {
        case "logical": return String(localized: "sizeColumns.reported.help",
            defaultValue: "The size Finder reports: how much data the item holds.", bundle: L10n.bundle,
            comment: "Help for the Reported Size column header in both lists.")
        case "allocated": return String(localized: "sizeColumns.allocated.help",
            defaultValue: "Space the item takes on disk. Less than the reported size when it is compressed, sparse or stored in iCloud.",
            bundle: L10n.bundle, comment: "Help for the Allocated column header in both lists.")
        default: return nil
        }
    }
    static func accessibility(name: String, reported: String, allocated: String) -> String {
        String(localized: "sizeColumns.accessibility", defaultValue: "\(name), reported size \(reported), allocated \(allocated)",
            bundle: L10n.bundle, comment: "VoiceOver row label: item name, logical size reported by Finder, then occupied disk space.")
    }
}
