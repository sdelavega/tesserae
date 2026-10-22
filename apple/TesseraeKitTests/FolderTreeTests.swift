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
        let bar = try XCTUnwrap(c.outlineView(outline, viewFor: outline.tableColumns[2], item: c.item(.node(t["zeta"]))) as? FolderShareBar)
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

}
