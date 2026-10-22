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
import SwiftUI
import XCTest
@testable import TesseraeKit

final class FolderTreeTests: XCTestCase {
    private func fixture() -> TestSnapshot {
        TestSnapshot(.dir("root", [.dir("zeta", [.file("leaf", 40, modified: 1798718400), .file("empty", 0)]),
            .file("beta", 30), .file("alpha", 30), .dir("other", [.file("tiny", 1)])]))
    }
    func test_children_sorted_by_allocated_desc_ties_by_index() {
        let t = fixture(), model = FolderTreeModel(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0)
        XCTAssertEqual(t.snapshot.children(0).count, 4)
        XCTAssertEqual(model.children(of: 0), ["zeta", "beta", "alpha", "other"].map { .node(t[$0]) })
    }
    func test_more_than_500_children_end_with_smaller_row() {
        let t = TestSnapshot(.dir("root", (0..<501).map { .file("f\($0)", UInt64(501 - $0)) }))
        let model = FolderTreeModel(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0)
        XCTAssertEqual(t.snapshot.children(0).count, 501)
        let rows = model.children(of: 0)
        XCTAssertEqual(FolderRow.childLimit, 500)
        XCTAssertEqual(rows.count, 501)
        XCTAssertEqual(Array(rows.prefix(500)), (1...500).map { .node(UInt32($0)) })
        XCTAssertEqual(rows.last, .smaller(count: 1, bytes: 1, parent: 0))
        model.sort(.name, ascending: false)
        XCTAssertEqual(model.children(of: 0).last, .smaller(count: 1, bytes: 1, parent: 0))
    }
    func test_trashed_child_disappears_and_parent_shrinks() {
        let t = fixture(), s = t.snapshot
        var overlay = SizeOverlay()
        XCTAssertEqual(s.descendantCount(t["zeta"]), 2)
        overlay.remove(t["leaf"], in: s)
        let source = OverlaySource(s, overlay)
        let model = FolderTreeModel(source: source, root: 0)
        XCTAssertEqual(model.children(of: t["zeta"]), [.node(t["empty"])])
        XCTAssertEqual(source.allocated(t["zeta"]), 0)
        XCTAssertEqual(source.descendantCount(t["zeta"]), 1)
        XCTAssertEqual(source.descendantCount(0), 6)
        overlay.remove(t["zeta"], in: s)
        XCTAssertEqual(OverlaySource(s, overlay).descendantCount(0), 4)
        overlay.restore(t["leaf"], in: s)
        XCTAssertEqual(OverlaySource(s, overlay).descendantCount(0), 4)
        overlay.restore(t["zeta"], in: s)
        XCTAssertEqual(OverlaySource(s, overlay).descendantCount(0), 7)
    }
    func test_path_to_node_for_reveal() {
        let t = fixture(), source = OverlaySource(t.snapshot, SizeOverlay())
        let model = FolderTreeModel(source: source, root: 0)
        XCTAssertNotEqual(t["leaf"], t["zeta"])
        XCTAssertEqual(model.path(to: t["leaf"]), [0, t["zeta"], t["leaf"]])
        XCTAssertEqual(model.path(to: 0), [0])
        XCTAssertEqual(model.path(to: UInt32.max), [])
        XCTAssertEqual(FolderTreeModel(source: source, root: t["other"]).path(to: t["leaf"]), [])
        var overlay = SizeOverlay()
        overlay.remove(t["zeta"], in: t.snapshot)
        XCTAssertEqual(FolderTreeModel(source: OverlaySource(t.snapshot, overlay), root: 0).path(to: t["leaf"]), [])
    }
    func test_sort_by_name_sorts_each_sibling_list() {
        let t = fixture(), model = FolderTreeModel(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0)
        XCTAssertEqual(model.children(of: 0).first, .node(t["zeta"]))
        model.sort(.name, ascending: true)
        XCTAssertEqual(model.children(of: 0), ["alpha", "beta", "other", "zeta"].map { .node(t[$0]) })
        XCTAssertEqual(model.children(of: t["zeta"]), ["empty", "leaf"].map { .node(t[$0]) })
        model.sort(.name, ascending: false)
        XCTAssertEqual(model.children(of: t["zeta"]), ["leaf", "empty"].map { .node(t[$0]) })
    }
    func test_children_are_lazy() {
        let t = fixture()
        var calls: [UInt32] = []
        let model = FolderTreeModel(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0, children: {
            calls.append($0)
            return t.snapshot.children($0)
        })
        XCTAssertTrue(calls.isEmpty)
        _ = model.children(of: t["zeta"])
        _ = model.children(of: t["zeta"])
        XCTAssertEqual(calls, [t["zeta"]])
    }
    @MainActor
    func test_modified_column_fits_medium_date() throws {
        let t = fixture()
        for locale in ["en_US", "de_DE", "fr_FR", "ja_JP", "ar_SA"].map({ Locale(identifier: $0) }) {
            let c = FileTableView.Coordinator(snapshot: t.snapshot, rows: [t["leaf"]], selection: Selection(), locale: locale)
            let table = c.makeTableView()
            let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "modified" })
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            let date = Date(timeIntervalSince1970: 1798718400)
            let text = formatter.string(from: date)
            XCTAssertFalse(text.isEmpty)
            XCTAssertEqual(c.text(column: "modified", row: 0), text)
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
            XCTAssertGreaterThanOrEqual(column.width, ceil(width) + 4)
            XCTAssertGreaterThanOrEqual(FolderOutlineView.Coordinator.modifiedColumnWidth(locale: locale), ceil(width) + 4)
        }
    }
    @MainActor
    func test_outline_selection_reveals_without_changing_focus_and_navigates_directories() throws {
        let t = fixture(), selection = Selection(), navigator = Navigator(snapshot: t.snapshot)
        let state = FolderExpansionState()
        let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
            selection: selection, navigator: navigator, expansion: state, locale: Locale(identifier: "en_US"))
        let outline = c.makeOutlineView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        let focus = NSTextView(frame: NSRect(x: 0, y: 250, width: 100, height: 40))
        content.addSubview(focus)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        scroll.documentView = outline
        content.addSubview(scroll)
        XCTAssertTrue(window.makeFirstResponder(focus))
        XCTAssertEqual(outline.numberOfRows, 4)
        XCTAssertEqual(outline.row(forItem: c.item(.node(t["leaf"]))), -1)
        selection.nodes = [t["leaf"]]
        let row = outline.row(forItem: c.item(.node(t["leaf"])))
        XCTAssertGreaterThanOrEqual(row, 0)
        XCTAssertTrue(outline.isItemExpanded(c.item(.node(t["zeta"])) ))
        XCTAssertEqual(outline.selectedRow, row)
        XCTAssertTrue(window.firstResponder === focus)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: c.item(.node(t["other"])))), byExtendingSelection: false)
        XCTAssertEqual(selection.nodes, [t["other"]])
        c.activate(.node(t["leaf"]))
        XCTAssertEqual(navigator.root, 0)
        c.activate(.node(t["zeta"]))
        XCTAssertEqual(navigator.root, t["zeta"])
        window.orderOut(nil)
    }
    @MainActor
    func test_expansion_survives_root_changes_and_view_recreation() {
        let t = fixture(), selection = Selection(), navigator = Navigator(snapshot: t.snapshot)
        let source = OverlaySource(t.snapshot, SizeOverlay()), state = FolderExpansionState()
        let c = FolderOutlineView.Coordinator(source: source, root: 0, selection: selection,
            navigator: navigator, expansion: state)
        let outline = c.makeOutlineView()
        let folder = c.item(.node(t["zeta"]))
        XCTAssertFalse(outline.isItemExpanded(folder))
        outline.expandItem(folder)
        XCTAssertTrue(outline.isItemExpanded(folder))
        c.update(source: source, root: t["other"])
        c.update(source: source, root: 0)
        XCTAssertTrue(outline.isItemExpanded(c.item(.node(t["zeta"]))))
        let recreated = FolderOutlineView.Coordinator(source: source, root: 0, selection: selection,
            navigator: navigator, expansion: state)
        let second = recreated.makeOutlineView()
        XCTAssertTrue(second.isItemExpanded(recreated.item(.node(t["zeta"]))))
        second.collapseItem(recreated.item(.node(t["zeta"])))
        recreated.update(source: source, root: t["other"])
        recreated.update(source: source, root: 0)
        XCTAssertFalse(second.isItemExpanded(recreated.item(.node(t["zeta"]))))
    }
    @MainActor
    func test_outline_overlay_refresh_counts_share_and_plural_summary() throws {
        let t = fixture(), s = t.snapshot
        let c = FolderOutlineView.Coordinator(source: OverlaySource(s, SizeOverlay()), root: 0,
            selection: Selection(), navigator: Navigator(snapshot: s), expansion: FolderExpansionState(),
            locale: Locale(identifier: "en_US"))
        let outline = c.makeOutlineView()
        XCTAssertEqual(c.text(column: "items", row: .node(t["zeta"])), "2")
        XCTAssertEqual(c.share(of: .node(t["zeta"])), 40.0 / 101.0, accuracy: 0.0001)
        XCTAssertEqual(c.text(column: "name", row: .smaller(count: 1, bytes: 1, parent: 0)), "1 smaller item — 1 byte")
        XCTAssertEqual(c.text(column: "name", row: .smaller(count: 2, bytes: 2, parent: 0)), "2 smaller items — 2 bytes")
        let bar = try XCTUnwrap(c.outlineView(outline, viewFor: try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == "share" }), item: c.item(.node(t["zeta"]))) as? FolderShareBar)
        XCTAssertEqual(bar.ink, NSColor.secondaryLabelColor)
        var overlay = SizeOverlay()
        overlay.remove(t["leaf"], in: s)
        c.update(source: OverlaySource(s, overlay), root: 0)
        XCTAssertEqual(c.text(column: "items", row: .node(t["zeta"])), "1")
        XCTAssertEqual(c.share(of: .node(t["zeta"])), 0)
        XCTAssertEqual(c.model.children(of: t["zeta"]), [.node(t["empty"])])
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        XCTAssertEqual(c.model.children(of: 0).first, .node(t["alpha"]))
    }

    @MainActor
    func test_reveal_scrolls_to_distant_row() {
        let t = TestSnapshot(.dir("root", [.dir("folder", (0..<80).map { .file("file\($0)", UInt64(80 - $0)) })]))
        let selection = Selection()
        let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
            selection: selection, navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState())
        let outline = c.makeOutlineView()
        outline.frame = NSRect(x: 0, y: 0, width: 800, height: 2000)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        scroll.documentView = outline
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertLessThan(scroll.contentSize.height, 80 * outline.rowHeight)
        selection.nodes = [t["file79"]]
        let row = outline.row(forItem: c.item(.node(t["file79"])))
        XCTAssertEqual(row, 80)
        XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: row)))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
    }

    @MainActor
    func test_overlay_revisions_bound_cached_items_to_current_model() throws {
        let t = TestSnapshot(.dir("root", [.dir("folder", (0..<520).map { .file("f\($0)", UInt64(520 - $0)) })]))
        let s = t.snapshot, state = FolderExpansionState()
        let c = FolderOutlineView.Coordinator(source: OverlaySource(s, SizeOverlay()), root: 0,
            selection: Selection(), navigator: Navigator(snapshot: s), expansion: state)
        let outline = c.makeOutlineView()
        outline.expandItem(c.item(.node(t["folder"])))
        XCTAssertEqual(outline.numberOfRows, 502)
        var overlay = SizeOverlay()
        var summaries = Set<FolderRow>()
        for index in 0..<10 {
            overlay.remove(t["f\(519 - index)"], in: s)
            c.update(source: OverlaySource(s, overlay), root: 0)
            XCTAssertTrue(outline.isItemExpanded(c.item(.node(t["folder"]))))
            let summary = try XCTUnwrap(c.model.children(of: t["folder"]).last)
            guard case .smaller = summary else { return XCTFail("Expected an aggregated suffix") }
            XCTAssertTrue(summaries.insert(summary).inserted)
            let current = Set((0..<outline.numberOfRows).compactMap {
                (outline.item(atRow: $0) as? FolderOutlineView.Coordinator.Item)?.row
            })
            XCTAssertEqual(current.count, 502)
            XCTAssertEqual(c.items.count, current.count)
            XCTAssertTrue(Set(c.items.keys) == current)
            let item = c.item(summary)
            XCTAssertTrue(item === c.item(summary))
            c.update(source: OverlaySource(s, overlay), root: 0)
            XCTAssertTrue(item === c.item(summary), "Unchanged generation preserves identity")
        }
        XCTAssertEqual(summaries.count, 10)
    }

    @MainActor
    func test_same_selection_does_not_scroll_again() {
        let t = TestSnapshot(.dir("root", [.dir("folder", (0..<80).map { .file("file\($0)", UInt64(80 - $0)) })]))
        let selection = Selection()
        let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
            selection: selection, navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState())
        let outline = c.makeOutlineView()
        outline.frame = NSRect(x: 0, y: 0, width: 800, height: 2000)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        scroll.documentView = outline
        selection.nodes = [t["file79"]]
        XCTAssertEqual(outline.selectedRow, 80)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        outline.scrollRowToVisible(0)
        let origin = scroll.contentView.bounds.origin
        XCTAssertFalse(outline.visibleRect.intersects(outline.rect(ofRow: 80)))
        selection.nodes = [t["file79"]]
        XCTAssertEqual(outline.selectedRow, 80)
        XCTAssertEqual(scroll.contentView.bounds.origin, origin)
    }

    @MainActor
    func test_selection_in_aggregated_suffix_reveals_summary_and_keeps_node() {
        let t = TestSnapshot(.dir("root", (0..<501).map { .file("f\($0)", UInt64(501 - $0)) }))
        let selection = Selection()
        let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
            selection: selection, navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState())
        let outline = c.makeOutlineView()
        XCTAssertEqual(outline.numberOfRows, 501)
        XCTAssertEqual(outline.row(forItem: c.item(.node(t["f500"]))), -1)
        selection.nodes = [t["f500"]]
        XCTAssertEqual(outline.selectedRow, 500)
        XCTAssertEqual(selection.nodes, [t["f500"]])
        let summary = c.item(.smaller(count: 1, bytes: 1, parent: 0))
        XCTAssertEqual(outline.row(forItem: summary), 500)
        XCTAssertFalse(c.outlineView(outline, shouldSelectItem: summary))
    }

    @MainActor
    private func sizeColumnsFixture() -> (TestSnapshot, FolderOutlineView.Coordinator, NSOutlineView) {
        let t = TestSnapshot(.dir("root", [.dir("folder", [.file("compressed", 100, logical: 900)]),
            .file("plain", 200, logical: 300)]))
        let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
            selection: Selection(), navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState(),
            locale: Locale(identifier: "en_US"))
        return (t, c, c.makeOutlineView())
    }

    @MainActor
    func test_folder_tree_has_reported_and_allocated_columns_in_order() {
        let (_, _, outline) = sizeColumnsFixture()
        XCTAssertEqual(outline.tableColumns.map(\.identifier.rawValue), ["name", "logical", "allocated", "share", "items", "modified"])
        XCTAssertEqual(outline.tableColumns.map(\.title), ["Name", "Reported Size", "Allocated", "Share", "Items", "Modified"])
        XCTAssertEqual(outline.tableColumns.first { $0.identifier.rawValue == "logical" }?.headerToolTip,
            "The size Finder reports: how much data the item holds.")
        XCTAssertEqual(outline.tableColumns.first { $0.identifier.rawValue == "allocated" }?.headerToolTip,
            "Space the item takes on disk. Less than the reported size when it is compressed, sparse or stored in iCloud.")
    }

    @MainActor
    func test_file_table_column_titles_and_order() {
        let (t, _, _) = sizeColumnsFixture()
        let c = FileTableView.Coordinator(snapshot: t.snapshot, rows: [t["compressed"]], selection: Selection())
        let table = c.makeTableView()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.tableColumns.map(\.identifier.rawValue), ["name", "logical", "allocated", "modified", "kind"])
        XCTAssertEqual(table.tableColumns.map(\.title), ["Name", "Reported Size", "Allocated", "Modified", "Kind"])
        XCTAssertEqual(table.tableColumns[1].headerToolTip, "The size Finder reports: how much data the item holds.")
        XCTAssertEqual(table.tableColumns[2].headerToolTip,
            "Space the item takes on disk. Less than the reported size when it is compressed, sparse or stored in iCloud.")
    }

    @MainActor
    func test_sort_by_reported_size_sorts_siblings() {
        let (t, c, outline) = sizeColumnsFixture()
        XCTAssertEqual(c.model.children(of: 0), [.node(t["plain"]), .node(t["folder"])])
        outline.sortDescriptors = [NSSortDescriptor(key: "logical", ascending: false)]
        XCTAssertEqual(c.model.children(of: 0), [.node(t["folder"]), .node(t["plain"])])
        outline.sortDescriptors = [NSSortDescriptor(key: "logical", ascending: true)]
        XCTAssertEqual(c.model.children(of: 0), [.node(t["plain"]), .node(t["folder"])])
    }

    @MainActor
    func test_default_sort_is_allocated() {
        let (t, c, outline) = sizeColumnsFixture()
        XCTAssertGreaterThan(t.snapshot.nodes[Int(t["folder"])].logical, t.snapshot.nodes[Int(t["plain"])].logical)
        XCTAssertEqual(c.model.children(of: 0), [.node(t["plain"]), .node(t["folder"])])
        XCTAssertEqual(c.share(of: .node(t["folder"])), 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(outline.numberOfRows, 2)
        XCTAssertEqual(FileTableModel(snapshot: t.snapshot, scope: 0).defaultRows(), [t["plain"], t["compressed"]])
    }

    @MainActor
    func test_compressed_overlay_lowers_allocated_not_reported() {
        let (t, c, _) = sizeColumnsFixture()
        var overlay = SizeOverlay()
        var outcome = CompressOutcome(runID: CompressRunID())
        outcome.allocatedDeltas = [t["compressed"]: -80]
        outcome.apply(to: &overlay, snapshot: t.snapshot)
        let source = OverlaySource(t.snapshot, overlay)
        XCTAssertEqual(t.snapshot.allocated(t["folder"]), 100)
        XCTAssertEqual(source.allocated(t["folder"]), 20)
        XCTAssertEqual(source.logical(t["folder"]), 900)
        XCTAssertEqual(source.logical(0), 1200)
        c.update(source: source, root: 0)
        XCTAssertEqual(c.text(column: "logical", row: .node(t["folder"])), "900 bytes")
        XCTAssertEqual(c.text(column: "allocated", row: .node(t["folder"])), "20 bytes")
        let files = FileTableView.Coordinator(snapshot: t.snapshot, rows: [t["compressed"]], selection: Selection(), locale: Locale(identifier: "en_US"))
        let table = files.makeTableView()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(files.text(column: "allocated", row: 0), "100 bytes")
        files.update(snapshot: t.snapshot, rows: [t["compressed"]], overlay: overlay)
        XCTAssertEqual(files.text(column: "logical", row: 0), "900 bytes")
        XCTAssertEqual(files.text(column: "allocated", row: 0), "20 bytes")
        XCTAssertEqual(files.accessibilityLabel(column: "name", row: 0), "compressed, reported size 900 bytes, allocated 20 bytes")
        // Deleted files disappear and both rolled-up sizes shrink.
        overlay.remove(t["plain"], in: t.snapshot)
        XCTAssertEqual(OverlaySource(t.snapshot, overlay).logical(0), 900)
        XCTAssertEqual(OverlaySource(t.snapshot, overlay).allocated(0), 20)
    }

    @MainActor
    func test_accessibility_label_reads_both_sizes() throws {
        let (t, c, outline) = sizeColumnsFixture()
        let expected = "folder, reported size 900 bytes, allocated 100 bytes"
        for id in ["name", "logical", "allocated"] {
            let col = try XCTUnwrap(outline.tableColumns.first { $0.identifier.rawValue == id })
            let cell = try XCTUnwrap(c.outlineView(outline, viewFor: col, item: c.item(.node(t["folder"]))) as? NSTableCellView)
            XCTAssertEqual(cell.accessibilityLabel(), expected)
        }
        let file = FileTableView.Coordinator(snapshot: t.snapshot, rows: [t["compressed"]], selection: Selection(), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(file.accessibilityLabel(column: "name", row: 0), "compressed, reported size 900 bytes, allocated 100 bytes")
    }

    @MainActor
    func test_column_widths_fit_at_minimum_window_width() throws {
        // en is the catalog translation; en_GB exercises the other English date/number region.
        for identifier in ["en_US", "en_GB"] {
            let locale = Locale(identifier: identifier)
            let (t, _, _) = sizeColumnsFixture()
            let c = FolderOutlineView.Coordinator(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
                selection: Selection(), navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState(), locale: locale)
            let outline = c.makeOutlineView()
            let required = outline.tableColumns.reduce(CGFloat(0)) { $0 + $1.minWidth } + CGFloat(outline.numberOfColumns) * outline.intercellSpacing.width
            XCTAssertEqual(outline.numberOfColumns, 6)
            let view = FolderOutlineView(source: OverlaySource(t.snapshot, SizeOverlay()), root: 0,
                selection: Selection(), navigator: Navigator(snapshot: t.snapshot), expansion: FolderExpansionState(), locale: locale)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 620, height: 180)
            host.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            scroll.tile()
            let document = try XCTUnwrap(scroll.documentView as? NSOutlineView)
            XCTAssertEqual(document.numberOfColumns, 6)
            XCTAssertGreaterThan(document.numberOfRows, 0)
            XCTAssertEqual(document.tableColumns[0].width, 180)
            XCTAssertEqual(document.tableColumns[1].width, 110)
            XCTAssertGreaterThan(required, scroll.contentSize.width)
            XCTAssertEqual(document.frame.width, required, accuracy: 1)
            XCTAssertTrue(scroll.hasHorizontalScroller)
            XCTAssertTrue(try XCTUnwrap(scroll.horizontalScroller).isEnabled)
            let modified = document.rect(ofColumn: 5)
            document.scrollToVisible(modified)
            XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
            XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.maxX, modified.maxX - 1)
            XCTAssertLessThanOrEqual(scroll.contentView.bounds.minX, modified.minX)
            let files = NSHostingView(rootView: FileTableView(snapshot: t.snapshot, rows: [t["compressed"]],
                selection: Selection(), locale: locale))
            files.frame = CGRect(x: 0, y: 0, width: 400, height: 180)
            files.layoutSubtreeIfNeeded()
            let fileScroll = try XCTUnwrap(descendants(files).compactMap { $0 as? NSScrollView }.first)
            fileScroll.tile()
            let fileTable = try XCTUnwrap(fileScroll.documentView as? NSTableView)
            XCTAssertEqual(fileTable.numberOfRows, 1)
            XCTAssertEqual(fileTable.numberOfColumns, 5)
            let fileWidth = fileTable.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
                + CGFloat(fileTable.numberOfColumns) * fileTable.intercellSpacing.width
            XCTAssertEqual(fileTable.tableColumns[0].width, 180)
            XCTAssertGreaterThan(fileWidth, fileScroll.contentSize.width)
            XCTAssertEqual(fileTable.frame.width, fileWidth, accuracy: 1)
            XCTAssertTrue(fileScroll.hasHorizontalScroller)
            XCTAssertTrue(try XCTUnwrap(fileScroll.horizontalScroller).isEnabled)
            let kind = fileTable.rect(ofColumn: 4)
            fileTable.scrollToVisible(kind)
            XCTAssertGreaterThan(fileScroll.contentView.bounds.minX, 0)
            XCTAssertGreaterThanOrEqual(fileScroll.contentView.bounds.maxX, kind.maxX - 1)
            XCTAssertLessThanOrEqual(fileScroll.contentView.bounds.minX, kind.minX)
            for column in outline.tableColumns.dropFirst() {
                XCTAssertEqual(column.minWidth, column.maxWidth)
                let textWidth = (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
                XCTAssertLessThanOrEqual(textWidth + 16, column.width, column.title)
            }
        }
    }

}
