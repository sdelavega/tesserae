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

public struct FolderOutlineView: NSViewRepresentable {
    public let source: OverlaySource
    public let root: UInt32
    public let selection: Selection
    public let navigator: Navigator
    public let expansion: FolderExpansionState
    public var locale: Locale
    public var onStage: (() -> Void)?

    public init(source: OverlaySource, root: UInt32, selection: Selection, navigator: Navigator,
                expansion: FolderExpansionState, locale: Locale = .current, onStage: (() -> Void)? = nil) {
        self.source = source
        self.root = root
        self.selection = selection
        self.navigator = navigator
        self.expansion = expansion
        self.locale = locale
        self.onStage = onStage
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(source: source, root: root, selection: selection, navigator: navigator, expansion: expansion, locale: locale)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = FittingOutlineScrollView()
        scroll.documentView = context.coordinator.makeOutlineView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.contextMenu.stage = onStage
        context.coordinator.update(source: source, root: root, locale: locale)
    }

    @MainActor
    public final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        final class Item: NSObject {
            let row: FolderRow
            init(_ row: FolderRow) { self.row = row }
        }
        private(set) var model: FolderTreeModel
        private weak var outline: NSOutlineView?
        private let selection: Selection
        private let navigator: Navigator
        private let expansion: FolderExpansionState
        private var locale: Locale
        private(set) var items: [FolderRow: Item] = [:]
        private var observer: AnyCancellable?
        private var applyingSelection = false
        private var restoringExpansion = false
        private var sortKey: SortKey = .allocated
        private var ascending = false
        let contextMenu = ReclaimContextMenu()

        init(source: OverlaySource, root: UInt32, selection: Selection, navigator: Navigator,
             expansion: FolderExpansionState, locale: Locale = .current) {
            model = FolderTreeModel(source: source, root: root)
            self.selection = selection
            self.navigator = navigator
            self.expansion = expansion
            self.locale = locale
        }

        static func modifiedColumnWidth(locale: Locale) -> CGFloat { TableDates.width(locale: locale) }

        func item(_ row: FolderRow) -> Item {
            if let existing = items[row] { return existing }
            let new = Item(row)
            items[row] = new
            return new
        }

        func makeOutlineView() -> NSOutlineView {
            let view = FolderOutline()
            view.reclaimMenu = contextMenu
            view.prepareContext = { [weak self, weak view] event in
                guard let self, let view else { return false }
                let row = view.row(at: view.convert(event.locationInWindow, from: nil))
                guard row >= 0, let item = view.item(atRow: row) as? Item, case .node(let node) = item.row else { return false }
                if !self.selection.nodes.contains(node) { self.selection.nodes = [node] }
                return true
            }
            let titles = [
                String(localized: "fileTableView.name", defaultValue: "Name", bundle: L10n.bundle, comment: "File name column."),
                SizeColumnText.reported,
                SizeColumnText.allocated,
                String(localized: "folderTree.share", defaultValue: "Share", bundle: L10n.bundle, comment: "Share of the navigation root's allocated bytes."),
                String(localized: "folderTree.items", defaultValue: "Items", bundle: L10n.bundle, comment: "Directory descendant count column."),
                String(localized: "fileTableView.modified", defaultValue: "Modified", bundle: L10n.bundle, comment: "Modification date column.")
            ]
            for (index, id) in ["name", "logical", "allocated", "share", "items", "modified"].enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = titles[index]
                column.headerToolTip = SizeColumnText.help(id)
                column.width = id == "name" ? 280 : (id == "modified" ? Self.modifiedColumnWidth(locale: locale) : (id == "logical" ? 110 : 90))
                column.minWidth = id == "name" ? 180 : column.width
                column.maxWidth = id == "name" ? 10_000 : column.width
                column.resizingMask = []
                column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "name")
                view.addTableColumn(column)
            }
            view.outlineTableColumn = view.tableColumns.first
            view.intercellSpacing = NSSize(width: 3, height: 0)
            view.columnAutoresizingStyle = .noColumnAutoresizing
            view.style = .plain
            view.allowsMultipleSelection = true
            view.usesAlternatingRowBackgroundColors = true
            view.delegate = self
            view.dataSource = self
            view.target = self
            view.doubleAction = #selector(doubleClick(_:))
            outline = view
            view.reloadData()
            restoreExpansion()
            observer = selection.$nodes.sink { [weak self] in self?.select($0) }
            return view
        }

        func update(source: OverlaySource, root: UInt32, locale: Locale? = nil) {
            let nextLocale = locale ?? self.locale
            guard source.snapshot !== model.source.snapshot || source.overlay.revision != model.source.overlay.revision
                || root != model.root || nextLocale != self.locale else { return }
            items.removeAll(keepingCapacity: true)
            self.locale = nextLocale
            model = FolderTreeModel(source: source, root: root)
            model.sort(sortKey, ascending: ascending)
            reload()
            if let column = outline?.tableColumns.last {
                let width = Self.modifiedColumnWidth(locale: nextLocale)
                column.minWidth = width; column.maxWidth = width; column.width = width
            }
        }

        private func reload() {
            applyingSelection = true
            restoringExpansion = true
            outline?.reloadData()
            restoringExpansion = false
            restoreExpansion()
            applyingSelection = false
            select(selection.nodes)
        }

        private func restoreExpansion() {
            guard let outline else { return }
            restoringExpansion = true
            for node in (expansion.roots[model.root] ?? []).sorted() where !model.path(to: node).isEmpty {
                outline.expandItem(item(.node(node)))
            }
            restoringExpansion = false
        }

        private func select(_ nodes: Set<UInt32>) {
            guard let outline else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            var indexes = IndexSet()
            for node in nodes.sorted() {
                let path = model.path(to: node)
                guard !path.isEmpty else { continue }
                for ancestor in path.dropFirst().dropLast() { outline.expandItem(item(.node(ancestor))) }
                let row = outline.row(forItem: item(.node(node)))
                if row >= 0 { indexes.insert(row) }
                else {
                    // The strict size cutoff represents this node by its
                    // first hidden ancestor's suffix, without rewriting selection.
                    for (parent, child) in zip(path, path.dropFirst()) {
                        let children = model.children(of: parent)
                        guard !children.contains(.node(child)), let summary = children.last,
                            case .smaller = summary else { continue }
                        let summaryRow = outline.row(forItem: item(summary))
                        if summaryRow >= 0 { indexes.insert(summaryRow) }
                        break
                    }
                }
            }
            guard indexes != outline.selectedRowIndexes else { return }
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
            if let first = indexes.first { outline.scrollRowToVisible(first) }
        }

        public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let item = item as? Item {
                if case .node(let node) = item.row { return model.children(of: node).count }
                return 0
            }
            return model.children(of: model.root).count
        }

        public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem parent: Any?) -> Any {
            let node: UInt32
            if let parent = parent as? Item, case .node(let value) = parent.row { node = value }
            else { node = model.root }
            return item(model.children(of: node)[index])
        }

        public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? Item, case .node(let node) = item.row else { return false }
            let source = model.source
            return source.isDirectory(node) && !source.isPermissionDenied(node) && source.snapshot.nodes[Int(node)].child_count > 0
        }

        public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let item = item as? Item, case .node = item.row else { return false }
            return true
        }

        public func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline else { return }
            selection.nodes = Set(outline.selectedRowIndexes.compactMap { index in
                guard let item = outline.item(atRow: index) as? Item, case .node(let node) = item.row else { return nil }
                return node
            })
        }

        public func outlineViewItemDidExpand(_ notification: Notification) { recordExpansion(notification, expanded: true) }
        public func outlineViewItemDidCollapse(_ notification: Notification) { recordExpansion(notification, expanded: false) }

        private func recordExpansion(_ notification: Notification, expanded: Bool) {
            guard !restoringExpansion, let item = notification.userInfo?["NSObject"] as? Item,
                case .node(let node) = item.row else { return }
            if expanded { expansion.roots[model.root, default: []].insert(node) }
            else { expansion.roots[model.root]?.remove(node) }
        }

        @objc private func doubleClick(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? Item else { return }
            activate(item.row)
        }

        func activate(_ row: FolderRow) {
            if case .node(let node) = row { navigator.descend(into: node) }
        }

        public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first else { return }
            switch descriptor.key {
            case "name": sortKey = .name
            case "modified": sortKey = .modified
            case "items": sortKey = .items
            case "logical": sortKey = .logical
            default: sortKey = .allocated
            }
            ascending = descriptor.ascending
            model.sort(sortKey, ascending: ascending)
            reload()
        }

        func share(of row: FolderRow) -> Double {
            let total = model.root == Tile.noNode ? 0 : model.source.allocated(model.root)
            guard total > 0 else { return 0 }
            let bytes: UInt64
            switch row {
            case .node(let node): bytes = model.source.allocated(node)
            case .smaller(_, let value, _): bytes = value
            }
            return min(1, Double(bytes) / Double(total))
        }

        func text(column: String, row: FolderRow) -> String {
            let source = model.source, s = source.snapshot
            switch row {
            case .smaller(let count, let bytes, let parent):
                if column == "logical" {
                    let shown = model.children(of: parent).compactMap { row -> UInt32? in
                        if case .node(let node) = row { return node }; return nil
                    }.reduce(UInt64(0)) { $0 + source.logical($1) }
                    let total = source.logical(parent)
                    return displaySize(total >= shown ? total - shown : 0, locale: locale)
                }
                if column == "allocated" { return displaySize(bytes, locale: locale) }
                guard column == "name" else { return "" }
                let size = displaySize(bytes, locale: locale)
                return String(localized: "folderTree.smaller", defaultValue: "\(count) smaller items — \(size)",
                    bundle: L10n.bundle, locale: L10n.pluralLocale(locale),
                    comment: "Summary of the contiguous suffix beyond 500 children: count and size on disk.")
            case .node(let node):
                switch column {
                case "name": return s.displayName(node)
                case "allocated": return displaySize(source.allocated(node), locale: locale)
                case "logical": return displaySize(source.logical(node), locale: locale)
                case "items": return source.isDirectory(node) ? source.descendantCount(node).formatted(.number.locale(locale)) : ""
                case "modified": return TableDates.text(s.nodes[Int(node)].modified, locale: locale)
                default: return ""
                }
            }
        }

        public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item, let id = tableColumn?.identifier.rawValue else { return nil }
            if id == "share" { return FolderShareBar(fraction: share(of: item.row), locale: locale) }
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: text(column: id, row: item.row))
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.lineBreakMode = id == "name" ? .byTruncatingMiddle : .byClipping
            if id == "logical" || id == "allocated" || id == "items" {
                field.alignment = .right
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            let base = SizeColumnText.accessibility(name: text(column: "name", row: item.row),
                reported: text(column: "logical", row: item.row), allocated: text(column: "allocated", row: item.row))
            let detail = ["name", "logical", "allocated"].contains(id) ? "" : text(column: id, row: item.row)
            let label = detail.isEmpty ? base : base + ", " + detail
            cell.setAccessibilityLabel(label)
            field.setAccessibilityLabel(label)
            return cell
        }
    }
}

@MainActor
final class FolderShareBar: NSView {
    let ink = NSColor.secondaryLabelColor
    private let fraction: Double
    init(fraction: Double, locale: Locale) {
        self.fraction = fraction
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(fraction.formatted(.percent.precision(.fractionLength(1)).locale(locale)))
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: 3, y: bounds.midY - 3, width: max(0, bounds.width - 6) * fraction, height: 6),
            xRadius: 2, yRadius: 2).fill()
    }
}

private final class FolderOutline: NSOutlineView {
    var reclaimMenu: ReclaimContextMenu?
    var prepareContext: ((NSEvent) -> Bool)?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard prepareContext?(event) == true else { return nil }
        return reclaimMenu?.make()
    }
}

/// Give Name the remaining viewport width, including in a narrow split pane.
private final class FittingOutlineScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let outline = documentView as? NSOutlineView, outline.tableColumns.count == 6 else { return }
        let columns = outline.tableColumns
        let fixed = columns.dropFirst().reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = outline.intercellSpacing.width * CGFloat(columns.count)
        columns[0].width = max(180, contentSize.width - fixed - spacing)
        outline.setFrameSize(NSSize(width: max(contentSize.width, fixed + spacing + columns[0].width), height: outline.frame.height))
    }
}
