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
import Foundation

public struct FocusLegendItem {
    public let accessibilityLabel: String
    public let colour: SIMD4<Float>
}

/// One snapshot and everything that indexes it. Replacing this object also
/// replaces the view identity, navigation, selection, hover and table together.
@MainActor
public final class AppSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let snapshot: Snapshot
    public let navigator: Navigator
    public let selection = Selection()
    public let table = FileTableRows()
    @Published public private(set) var tiles: [Tile] = []
    @Published public private(set) var labels: [PlacedLabel] = []
    @Published public private(set) var inspector: InspectorInfo?
    @Published public var zoomRunning = false {
        didSet {
            guard !zoomRunning, decorationsPending else { return }
            decorationsPending = false
            updateLabels()
            requestTable()
        }
    }
    private var decorationsPending = false
    public private(set) var layoutGeneration: UInt64 = 0
    @Published public var droppedTileCount = 0
    @Published public private(set) var root: UInt32
    private var size = CGSize.zero
    private var observers: Set<AnyCancellable> = []
    private var tableTask: Task<Void, Never>?

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
        navigator = Navigator(snapshot: snapshot)
        root = snapshot.root
        navigator.$root.dropFirst().sink { [weak self] root in
            guard let self else { return }
            self.root = root
            self.inspector = nil
            self.decorationsPending = true
            self.tableTask?.cancel()
            self.table.reset()
            self.relayout()
        }.store(in: &observers)
        selection.$nodes.sink { [weak self] nodes in
            guard let self else { return }
            var next = self.tiles
            applySelection(&next, nodes)
            self.tiles = next
        }.store(in: &observers)
        requestTable()
    }

    deinit { tableTask?.cancel() }

    public var isEmpty: Bool {
        snapshot.root == Tile.noNode || (snapshot.allocated(root) == 0 && !snapshot.isPermissionDenied(root))
    }

    public var banner: String? {
        let path = snapshot.stalledAt.map { String(decoding: $0, as: UTF8.self) }
        return ScanBanner.text(for: snapshot.stats, stalledAt: path)
    }

    public func resize(to size: CGSize) {
        guard size != self.size else { return }
        self.size = size
        relayout()
    }

    private func relayout() {
        layoutGeneration &+= 1
        inspector = nil
        guard root != Tile.noNode, size.width.isFinite, size.height.isFinite,
            size.width >= 1, size.height >= 1 else {
            tiles = []
            labels = []
            return
        }
        let preparation = FrameTimer.shared.begin("prepare")
        defer { FrameTimer.shared.end(preparation) }
        let layout = FrameTimer.shared.begin("layout")
        var next = squarify(snapshot, root: root, in: CGRect(origin: .zero, size: size))
        FrameTimer.shared.end(layout)
        applySelection(&next, selection.nodes)
        tiles = next
        if next.isEmpty && decorationsPending {
            decorationsPending = false
            requestTable()
        }
        if decorationsPending { labels = [] } else { updateLabels() }
    }

    private func updateLabels() {
        let timing = FrameTimer.shared.begin("labels")
        defer { FrameTimer.shared.end(timing) }
        labels = placeLabels(tiles, in: snapshot, measure: LabelStyle.measure)
    }

    public func setZoomRunning(_ running: Bool, generation: UInt64) {
        guard generation == layoutGeneration, running != zoomRunning || decorationsPending else { return }
        zoomRunning = running
    }

    public func hover(tile: Int?) {
        guard let tile, tiles.indices.contains(tile) else { inspector = nil; return }
        inspector = inspect(tileAt: tile, in: tiles, snapshot: snapshot)
    }

    public func go(to node: UInt32) {
        guard navigator.breadcrumb.contains(node) else { return }
        while navigator.root != node { navigator.ascend() }
    }

    private func requestTable() {
        tableTask?.cancel()
        // Clear and invalidate synchronously before scheduling async work.
        table.reset()
        tableTask = Task { [weak self] in await self?.loadTable() }
    }

    func waitForTable() async { await tableTask?.value }

    public func loadTable() async {
        guard !Task.isCancelled else { return }
        guard root != Tile.noNode else { return }
        await table.load(FileTableModel(snapshot: snapshot, scope: root))
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var session: AppSession?
    @Published public private(set) var scanState: ScanState = .idle
    @Published public var colourChoice = 0
    @Published public private(set) var focusKinds: [FileKind] = []
    private let coordinator: ScanCoordinator
    private var observers: Set<AnyCancellable> = []
    private let ageReference = Date()

    public convenience init() { self.init(coordinator: ScanCoordinator()) }

    init(coordinator: ScanCoordinator) {
        self.coordinator = coordinator
        coordinator.$snapshot.sink { [weak self] snapshot in
            self?.replaceSnapshot(snapshot)
        }.store(in: &observers)
        coordinator.$state.sink { [weak self] state in self?.scanState = state }.store(in: &observers)
    }

    func replaceSnapshot(_ snapshot: Snapshot?) {
        session = snapshot.map(AppSession.init)
    }

    public func scan(_ url: URL) { coordinator.start(root: url) }
    public func cancel() { coordinator.cancel() }
    public var isScanning: Bool { if case .scanning = scanState { return true }; return false }
    public var colourMode: ColourMode {
        switch colourChoice {
        case 1: return .age(now: ageReference)
        case 2: return .typeFocus(focusKinds)
        default: return .depth
        }
    }

    public func toggleFocus(_ kind: FileKind) {
        if let index = focusKinds.firstIndex(of: kind) { focusKinds.remove(at: index) }
        else if focusKinds.count < 3 { focusKinds.append(kind) }
    }

    public func focusLegend(dark: Bool) -> [FocusLegendItem] {
        let palette = Palette.colours(.typeFocus(focusKinds), dark: dark)
        return focusKinds.enumerated().map { slot, kind in
            FocusLegendItem(accessibilityLabel: kind.displayName + " files", colour: palette[slot + 2])
        } + [FocusLegendItem(accessibilityLabel: "Other files and folders", colour: palette[0])]
    }
}
