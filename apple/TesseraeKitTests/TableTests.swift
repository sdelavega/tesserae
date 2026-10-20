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

/// The file table (spec §8 "File table", §12 accessibility).
final class TableTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func names(_ rows: [UInt32], _ s: Snapshot) -> [String] { rows.map { s.name($0) } }

    // MARK: Sorting

    private func fixture() -> TestSnapshot {
        TestSnapshot(
            .dir(
                "/R",
                [
                    .file("b10.txt", 300, logical: 10, modified: 500),
                    .file("b2.txt", 200, logical: 400, modified: 0),
                    .file("A.mov", 100, logical: 300, modified: 100),
                    .file("c.zip", 400, logical: 20, modified: -50),
                    .file("noext", 50, logical: 5, modified: 900),
                    .dir("d", [.file("inner.png", 250, logical: 30, modified: 700)]),
                ]))
    }

    func test_name_sort_uses_the_displayed_name() async {
        let t = TestSnapshot(.dir("/R", [.file("a\n", 100), .file("a ", 200), .file("a\u{202E}", 300), .file("a", 400)]))
        let model = FileTableModel(snapshot: t.snapshot, scope: t.snapshot.root)
        let rows = model.defaultRows()
        XCTAssertEqual(rows.count, 4)
        let expected = rows.sorted {
            let cmp = t.snapshot.displayName($0).localizedStandardCompare(t.snapshot.displayName($1))
            return cmp == .orderedSame ? rows.firstIndex(of: $0)! < rows.firstIndex(of: $1)! : cmp == .orderedAscending
        }
        let legacy = rows.sorted {
            t.snapshot.name($0).localizedStandardCompare(t.snapshot.name($1)) == .orderedAscending
        }
        XCTAssertNotEqual(expected, legacy, "precondition: display sanitization affects ordering")
        let actual = await model.sorted(by: .name, ascending: true)
        XCTAssertEqual(actual, expected)
    }

    func test_sort_orders_indices_not_nodes_for_every_key() async {
        let t = fixture()
        let s = t.snapshot
        let ranOnMain = LockedFlags()
        let model = FileTableModel(snapshot: s, scope: 0, onSort: { ranOnMain.record($0) })

        let cases: [(SortKey, [String])] = [
            (.name, ["A.mov", "b2.txt", "b10.txt", "c.zip", "inner.png", "noext"]),
            (.allocated, ["noext", "A.mov", "b2.txt", "inner.png", "b10.txt", "c.zip"]),
            (.logical, ["noext", "b10.txt", "c.zip", "inner.png", "A.mov", "b2.txt"]),
            // A time of 0 (never read) is the oldest of all, older than -50.
            (.modified, ["b2.txt", "c.zip", "A.mov", "b10.txt", "inner.png", "noext"]),
            // Equal kinds (the two documents) keep the default order, b10 then b2.
            (.kind, ["c.zip", "b10.txt", "b2.txt", "noext", "inner.png", "A.mov"]),
        ]
        let universe = Set(model.defaultRows())
        XCTAssertEqual(universe.count, 6, "precondition: the six files; the directory d is not a row")
        XCTAssertFalse(universe.contains(t["d"]))
        for (key, ascendingNames) in cases {
            let up = await model.sorted(by: key, ascending: true)
            XCTAssertEqual(names(up, s), ascendingNames, "\(key) ascending")
            XCTAssertEqual(Set(up), universe, "\(key): the same indices, reordered")
            XCTAssertTrue(up.allSatisfy { Int($0) < s.nodes.count }, "rows are node indices")
            let down = await model.sorted(by: key, ascending: false)
            // Descending reverses the order of distinct keys but not of ties.
            let expectedDown: [String] =
                key == .kind
                ? ["A.mov", "inner.png", "noext", "b10.txt", "b2.txt", "c.zip"] : ascendingNames.reversed()
            XCTAssertEqual(names(down, s), expectedDown, "\(key) descending")
        }
        XCTAssertFalse(ranOnMain.values.isEmpty, "precondition: the sort ran")
        XCTAssertFalse(ranOnMain.values.contains(true), "sorting must run off the main thread")
    }

    func test_sort_is_stable_on_ties() async {
        // Few distinct sizes and kinds, so there are many ties.
        var rng = SplitMix64(seed: 0x57AB1E)
        let exts = ["mov", "png", "zip", "txt", "bin"]
        var files: [TestSnapshot.Spec] = []
        for i in 0..<300 {
            let size = UInt64(1 + rng.next() % 6) * 100
            files.append(.file("f\(i).\(exts[Int(rng.next() % 5)])", size, logical: UInt64(1 + rng.next() % 3)))
        }
        let t = TestSnapshot(.dir("/R", files))
        let s = t.snapshot
        let model = FileTableModel(snapshot: s, scope: 0)
        let base = model.defaultRows()
        XCTAssertEqual(base.count, 300)
        XCTAssertLessThan(Set(base.map { s.allocated($0) }).count, 10, "precondition: heavy ties")

        let keys: [(SortKey, (UInt32) -> String)] = [
            (.allocated, { String(format: "%020llu", s.allocated($0)) }),
            (.logical, { String(format: "%020llu", s.nodes[Int($0)].logical) }),
            (.kind, { nodeKind($0, in: s).displayName }),
        ]
        for (key, sortable) in keys {
            XCTAssertLessThan(Set(base.map(sortable)).count, 10, "precondition: \(key) has ties")
            for ascending in [true, false] {
                let got = await model.sorted(by: key, ascending: ascending)
                // Reference: group by key; groups ordered by key, members in default order.
                let groups = Dictionary(grouping: base, by: sortable)
                let order = groups.keys.sorted { ascending ? $0 < $1 : $0 > $1 }
                let expected = order.flatMap { groups[$0]! }
                XCTAssertEqual(got, expected, "\(key) ascending=\(ascending)")
            }
        }
    }

    // MARK: Top-K

    func test_top_k_matches_a_full_sort() {
        var sawDirBiggerThanFile = 0
        var sawTruncation = 0
        for seed in 0..<200 {
            var rng = SplitMix64(seed: UInt64(seed) ^ 0x70B_C0DE)
            var budget = 60 + Int(rng.next() % 200)
            func dir(_ name: String, depth: Int) -> TestSnapshot.Spec {
                var kids: [TestSnapshot.Spec] = []
                let n = min(budget, 1 + Int(rng.next() % 9))
                budget -= n
                for j in 0..<n {
                    if depth < 4 && rng.unit() < 0.3 {
                        kids.append(dir("\(name).d\(j)", depth: depth + 1))
                    } else {
                        // Few distinct sizes so ties are common.
                        kids.append(.file("\(name).f\(j)", UInt64(rng.next() % 12) * 1000))
                    }
                }
                return .dir(name, kids)
            }
            let t = TestSnapshot(dir("r", depth: 0))
            let s = t.snapshot
            // Scope: the root, or any directory.
            let dirs = (0..<UInt32(s.nodes.count)).filter { s.isDirectory($0) }
            let scope = seed % 3 == 0 ? UInt32(0) : dirs[Int(rng.next() % UInt64(dirs.count))]
            var files: [UInt32] = []
            var stack = [scope]
            while let i = stack.popLast() {
                if s.isDirectory(i) { stack.append(contentsOf: s.children(i)) } else { files.append(i) }
            }
            let full = files.sorted {
                s.allocated($0) != s.allocated($1) ? s.allocated($0) > s.allocated($1) : $0 < $1
            }
            if let top = full.first, let d = dirs.first(where: { s.allocated($0) > s.allocated(top) }) {
                _ = d
                sawDirBiggerThanFile += 1
            }
            for k in [0, 1, 5, 17, files.count, files.count + 10] {
                let got = topK(k, files: s, under: scope)
                XCTAssertEqual(got, Array(full.prefix(k)), "seed \(seed) scope \(scope) k \(k)")
                XCTAssertTrue(got.allSatisfy { !s.isDirectory($0) }, "files only")
                if k > 0 && k < files.count { sawTruncation += 1 }
            }
        }
        XCTAssertGreaterThan(sawDirBiggerThanFile, 100, "precondition: directories outweigh files, so including one would show")
        XCTAssertGreaterThan(sawTruncation, 250, "precondition: the heap really had to evict")
    }

    func test_table_default_view_is_the_top_1000_files() async {
        let files = (0..<1500).map { TestSnapshot.Spec.file("f\($0)", UInt64($0 + 1)) }
        let t = TestSnapshot(.dir("/R", files))
        let model = FileTableModel(snapshot: t.snapshot, scope: 0)
        let rows = model.defaultRows()
        XCTAssertEqual(rows.count, 1000)
        XCTAssertEqual(t.snapshot.allocated(rows[0]), 1500)
        XCTAssertEqual(t.snapshot.allocated(rows[999]), 501)
        let sorted = await model.sorted(by: .allocated, ascending: true)
        XCTAssertEqual(sorted.count, 1000, "sorting reorders the 1000, it does not widen them")
    }

    // MARK: Staleness

    @MainActor
    func test_a_stale_sort_is_never_applied_to_a_newer_snapshot() async {
        let a = TestSnapshot(.dir("/A", [.file("a1", 10), .file("a2", 20)]))
        let b = TestSnapshot(.dir("/B", [.file("b1", 5), .file("b2", 6), .file("b3", 7)]))
        let rows = FileTableRows()
        await rows.load(FileTableModel(snapshot: a.snapshot, scope: 0))
        XCTAssertEqual(names(rows.rows, a.snapshot), ["a2", "a1"])

        // A sort of A is in flight; B is loaded before it lands.
        let staleToken = rows.beginRequest()
        let staleResult = await rows.model!.sorted(by: .allocated, ascending: true)
        XCTAssertEqual(names(staleResult, a.snapshot), ["a1", "a2"], "precondition: the stale result differs from what B shows")
        await rows.load(FileTableModel(snapshot: b.snapshot, scope: 0))
        XCTAssertFalse(rows.accept(staleResult, generation: staleToken))
        XCTAssertEqual(names(rows.rows, b.snapshot), ["b3", "b2", "b1"], "B's rows stand")

        // Same through the public async path: load another scope during a sort.
        // The sort is held at the `onSort` seam until the reload has happened, so
        // "begun before the reload" is a fact, not a scheduling guess.
        let gate = DispatchSemaphore(value: 0)
        let began = Counter()
        let held = FileTableModel(snapshot: b.snapshot, scope: 0, onSort: { _ in
            _ = began.next()
            gate.wait()
        })
        await rows.load(held)
        let sortTask = Task { @MainActor in await rows.sort(by: .name, ascending: true) }
        for _ in 0..<1000 where began.count < 1 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(began.count, 1, "precondition: the sort has begun and is held at the gate")
        await rows.load(FileTableModel(snapshot: a.snapshot, scope: 0))
        gate.signal()
        let applied = await sortTask.value
        XCTAssertFalse(applied, "a sort begun before the reload is dropped")
        XCTAssertEqual(names(rows.rows, a.snapshot), ["a2", "a1"], "the reload's default order, not the stale sort")

        // And a later sort of the current model is applied.
        let ok = await rows.sort(by: .name, ascending: true)
        XCTAssertTrue(ok)
        XCTAssertEqual(names(rows.rows, a.snapshot), ["a1", "a2"])
    }

    @MainActor
    func test_the_newest_of_two_sorts_wins() async {
        let a = TestSnapshot(.dir("/A", [.file("a1", 10), .file("a2", 20)]))
        let rows = FileTableRows()
        await rows.load(FileTableModel(snapshot: a.snapshot, scope: 0))
        let first = beginAndSort(rows, .allocated, true)
        let second = beginAndSort(rows, .allocated, false)
        let (r1, r2) = (await first.value, await second.value)
        XCTAssertFalse(r1, "the older request is superseded")
        XCTAssertTrue(r2)
        XCTAssertEqual(names(rows.rows, a.snapshot), ["a2", "a1"])
    }

    @MainActor
    private func beginAndSort(_ rows: FileTableRows, _ k: SortKey, _ asc: Bool) -> Task<Bool, Never> {
        Task { @MainActor in await rows.sort(by: k, ascending: asc) }
    }

    // MARK: Selection

    func test_apply_selection_sets_and_clears_bit_zero() {
        var tiles = [
            Tile(rect: .zero, node: 0, depth: 0),
            Tile(rect: .zero, node: 3, depth: 1, flags: Tile.Flag.selected | Tile.Flag.staged),
            Tile(rect: .zero, node: 4, depth: 1, flags: Tile.Flag.staged),
            Tile(rect: .zero, node: Tile.noNode, depth: 1, flags: Tile.Flag.aggregated, aggregateCount: 3),
        ]
        applySelection(&tiles, [4, Tile.noNode])
        XCTAssertEqual(tiles.map { $0.flags & Tile.Flag.selected }, [0, 0, 1, 0])
        XCTAssertEqual(tiles[1].flags, Tile.Flag.staged, "other bits survive, the stale selection clears")
        XCTAssertEqual(tiles[2].flags, Tile.Flag.staged | Tile.Flag.selected)
        XCTAssertEqual(tiles[3].flags, Tile.Flag.aggregated, "an aggregate is never selected")
    }

    @MainActor
    func test_selection_round_trips_between_table_and_treemap() {
        let t = TestSnapshot(
            .dir("/R", [.file("a", 40), .file("b", 30), .file("c", 20), .file("d", 10), .dir("sub", [.file("e", 5)])]))
        let s = t.snapshot
        let rows = topK(10, files: s, under: 0)
        XCTAssertEqual(rows.count, 5)
        let selection = Selection()
        let coord = FileTableView.Coordinator(snapshot: s, rows: rows, selection: selection, locale: en)
        let table = coord.makeTableView()
        XCTAssertEqual(table.numberOfRows, 5)
        XCTAssertTrue(table.selectedRowIndexes.isEmpty, "precondition: nothing selected")

        func flagged(_ tiles: [Tile]) -> Set<UInt32> {
            var copy = tiles
            applySelection(&copy, selection.nodes)
            return Set(copy.filter { $0.flags & Tile.Flag.selected != 0 }.map(\.node))
        }
        let tiles = (0..<UInt32(s.nodes.count)).map { Tile(rect: .zero, node: $0, depth: 0) }

        // Table -> selection -> treemap tiles.
        let b = rows.firstIndex(of: t["b"])!, d = rows.firstIndex(of: t["d"])!
        table.selectRowIndexes(IndexSet([b, d]), byExtendingSelection: false)
        XCTAssertEqual(selection.nodes, [t["b"], t["d"]])
        XCTAssertEqual(flagged(tiles), [t["b"], t["d"]])

        // Treemap click (writes the shared set) -> table rows.
        selection.nodes = [t["a"], t["c"]]
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([rows.firstIndex(of: t["a"])!, rows.firstIndex(of: t["c"])!]))
        XCTAssertEqual(flagged(tiles), [t["a"], t["c"]])

        // A node the table does not list (a directory) is kept in the set until the table writes it.
        selection.nodes = [t["sub"], t["d"]]
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([d]))
        XCTAssertEqual(selection.nodes, [t["sub"], t["d"]], "showing the table's share did not rewrite the set")

        // Clearing either side clears the other.
        table.deselectAll(nil)
        XCTAssertTrue(selection.nodes.isEmpty)
        selection.nodes = [t["a"]]
        selection.nodes = []
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
    }

    // MARK: VoiceOver

    @MainActor
    func test_table_cells_have_voiceover_labels() throws {
        let t = TestSnapshot(
            .dir(
                "/R",
                [
                    .file("report.pdf", 4_200_000_000, logical: 4_100_000_000, modified: 1_700_000_000),
                    .file("tiny", 1500, logical: 7, modified: 0),
                ]))
        let s = t.snapshot
        let rows = topK(10, files: s, under: 0)
        let coord = FileTableView.Coordinator(snapshot: s, rows: rows, selection: Selection(), locale: en)
        let table = coord.makeTableView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = table
        window.contentView!.addSubview(scroll)
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Name", "Allocated", "Logical", "Modified", "Kind"])

        let pdfRow = try XCTUnwrap(rows.firstIndex(of: t["report.pdf"]))
        for column in 0..<table.numberOfColumns {
            for row in 0..<table.numberOfRows {
                let cell = try XCTUnwrap(table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
                let label = try XCTUnwrap(cell.accessibilityLabel(), "column \(column) row \(row)")
                let name = s.name(rows[row])
                XCTAssertTrue(label.hasPrefix(name + ", "), "\(label) names the file")
                XCTAssertTrue(label.contains(displaySize(s.allocated(rows[row]), locale: en)), "\(label) gives the size")
                XCTAssertFalse(try XCTUnwrap(cell.textField?.stringValue).isEmpty)
            }
        }
        let nameCell = try XCTUnwrap(table.view(atColumn: 0, row: pdfRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(nameCell.accessibilityLabel(), "report.pdf, 4.2 GB")
        XCTAssertEqual(nameCell.textField?.stringValue, "report.pdf")
        let logicalCell = try XCTUnwrap(table.view(atColumn: 2, row: pdfRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(logicalCell.textField?.stringValue, "4.1 GB")
        XCTAssertEqual(logicalCell.accessibilityLabel(), "report.pdf, 4.2 GB, logical 4.1 GB")
        let kindCell = try XCTUnwrap(table.view(atColumn: 4, row: pdfRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(kindCell.textField?.stringValue, "Document", "the Inspector's kind")
        let tinyRow = try XCTUnwrap(rows.firstIndex(of: t["tiny"]))
        let undated = try XCTUnwrap(table.view(atColumn: 3, row: tinyRow, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(undated.textField?.stringValue, "—", "a stored 0 is unknown, not 1970")
        XCTAssertEqual(undated.accessibilityLabel(), "tiny, 2 kB, modified unknown", "VoiceOver reads words, not a dash")
    }
    // MARK: Atomic content, bounds, scrolling, cancellation

    @MainActor
    func test_loading_never_publishes_a_snapshot_with_another_snapshots_rows() async {
        let a = TestSnapshot(.dir("/A", [.file("a1", 10), .file("a2", 20)]))
        let many = (0..<1200).map { TestSnapshot.Spec.file("b\($0)", UInt64($0 + 1)) }
        let b = TestSnapshot(.dir("/B", many))
        let rows = FileTableRows()
        await rows.load(FileTableModel(snapshot: a.snapshot, scope: 0))
        XCTAssertEqual(rows.rows.count, 2, "precondition: A shown")

        var samples = 0, sawCleared = false, sawB = false
        func check() {
            guard let c = rows.content else { sawCleared = true; return }
            samples += 1
            let expected = topK(1000, files: c.snapshot, under: 0)
            XCTAssertTrue(c.rows == expected, "rows are not this snapshot's default rows")
            for r in c.rows {
                XCTAssertLessThan(Int(r), c.snapshot.nodes.count, "row outside its own snapshot")
                let n = c.snapshot.name(r)
                XCTAssertEqual(n.first, c.snapshot === a.snapshot ? "a" : "b", "\(n) paired with the wrong snapshot")
            }
            if c.snapshot === b.snapshot { sawB = true }
        }
        let loading = Task { @MainActor in await rows.load(FileTableModel(snapshot: b.snapshot, scope: 0)) }
        for _ in 0..<2000 {
            check()
            await Task.yield()
            if sawB { break }
        }
        await loading.value
        check()
        XCTAssertTrue(sawB, "precondition: B's content arrived")
        XCTAssertEqual(rows.content?.rows.count, 1000)
        XCTAssertGreaterThan(samples, 0)
        XCTAssertTrue(sawCleared || samples > 0)
    }

    /// Final review I2: the table is the list a user scans to decide what to
    /// delete, so a crafted name must not reorder or hide what it shows. Cells
    /// and VoiceOver labels use the labels' sanitiser (`Snapshot.displayName`).
    @MainActor
    func test_name_cells_and_voiceover_labels_neutralise_crafted_names() throws {
        let bidi = "invoice\u{202E}fdp.app"
        let multi = "two\nlines\u{2066}x\u{2069}\u{7F}\u{85}"
        let t = TestSnapshot(.dir("/R", [.file(bidi, 2000), .file(multi, 1000)]))
        let s = t.snapshot
        let rows = topK(10, files: s, under: 0)
        let coord = FileTableView.Coordinator(snapshot: s, rows: rows, selection: Selection(), locale: en)
        let table = coord.makeTableView()
        XCTAssertEqual(table.numberOfRows, 2, "precondition: both files are rows")
        let expected = [bidi: "invoice\u{FFFD}fdp.app", multi: "two lines\u{FFFD}x\u{FFFD}\u{FFFD}\u{FFFD}"]
        for (name, shown) in expected {
            let row = try XCTUnwrap(rows.firstIndex(of: t[name]))
            XCTAssertEqual(coord.text(column: "name", row: row), shown)
            XCTAssertEqual(coord.text(column: "name", row: row), s.displayName(t[name]))
            let size = displaySize(s.allocated(t[name]), locale: en)
            XCTAssertEqual(coord.accessibilityLabel(column: "name", row: row), "\(shown), \(size)")
            for id in ["allocated", "logical", "modified", "kind"] {
                XCTAssertTrue(coord.accessibilityLabel(column: id, row: row).hasPrefix("\(shown), \(size)"), id)
            }
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
            XCTAssertEqual(cell.textField?.stringValue, shown)
            XCTAssertEqual(cell.accessibilityLabel(), "\(shown), \(size)")
        }
    }

    @MainActor
    func test_cells_never_trap_on_rows_outside_the_snapshot() {
        let t = TestSnapshot(.dir("/R", [.file("a", 40)]))
        let coord = FileTableView.Coordinator(snapshot: t.snapshot, rows: [1, 9999, UInt32.max - 1], selection: Selection(), locale: en)
        let table = coord.makeTableView()
        XCTAssertEqual(table.numberOfRows, 3, "precondition: three rows")
        XCTAssertEqual(coord.text(column: "name", row: 0), "a")
        for row in 1...2 {
            for id in ["name", "allocated", "logical", "modified", "kind"] {
                XCTAssertEqual(coord.text(column: id, row: row), "")
                XCTAssertEqual(coord.accessibilityLabel(column: id, row: row), "")
            }
        }
        table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        XCTAssertEqual(coord.selection.nodes, [1], "invalid rows are not written to the selection")
    }

    @MainActor
    func test_a_selection_from_the_treemap_scrolls_into_view() throws {
        let files = (0..<300).map { TestSnapshot.Spec.file("f\($0)", UInt64(1000 - $0)) }
        let t = TestSnapshot(.dir("/R", files))
        let rows = topK(300, files: t.snapshot, under: 0)
        let selection = Selection()
        let coord = FileTableView.Coordinator(snapshot: t.snapshot, rows: rows, selection: selection, locale: en)
        let table = coord.makeTableView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = table
        window.contentView!.addSubview(scroll)
        scroll.layoutSubtreeIfNeeded()
        let target = 250
        XCTAssertFalse(scroll.contentView.bounds.intersects(table.rect(ofRow: target)), "precondition: row 250 is off screen")
        selection.nodes = [rows[target]]
        XCTAssertTrue(scroll.contentView.bounds.intersects(table.rect(ofRow: target)), "the selected row was scrolled into view")
    }

    @MainActor
    func test_a_superseded_sort_is_cancelled_not_just_ignored() async throws {
        let a = TestSnapshot(.dir("/A", [.file("a1", 10), .file("a2", 20)]))
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        let model = FileTableModel(snapshot: a.snapshot, scope: 0, onSort: { _ in if calls.next() == 0 { gate.wait() } })
        let rows = FileTableRows()
        await rows.load(model)
        let first = Task { @MainActor in await rows.sort(by: .name, ascending: true) }
        for _ in 0..<500 where calls.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 1, "precondition: the first sort is running, held at the gate")
        let running = try XCTUnwrap(rows.inFlight)
        XCTAssertFalse(running.isCancelled)
        let second = Task { @MainActor in await rows.sort(by: .name, ascending: false) }
        for _ in 0..<500 where !running.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(running.isCancelled, "starting a new sort cancels the one in flight")
        gate.signal()
        let (r1, r2) = (await first.value, await second.value)
        XCTAssertFalse(r1)
        XCTAssertTrue(r2)
        XCTAssertEqual(names(rows.rows, a.snapshot), ["a2", "a1"])
    }

    func test_top_k_stops_when_its_task_is_cancelled() async {
        let t = TestSnapshot(.dir("/R", (0..<50).map { .file("f\($0)", UInt64($0 + 1)) }))
        let s = t.snapshot
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached { () -> [UInt32] in
            block(gate)
            return topK(5, files: s, under: 0)
        }
        task.cancel()
        gate.signal()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.isEmpty, "a cancelled walk returns nothing, not a partial answer")
        XCTAssertEqual(topK(5, files: s, under: 0).count, 5, "precondition: uncancelled it answers")
    }
}

/// Collects values recorded from another thread.
private final class LockedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    func record(_ v: Bool) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return _values }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// `DispatchSemaphore.wait` is unavailable in async closures; a sync wrapper is fine.
private func block(_ g: DispatchSemaphore) { g.wait() }
