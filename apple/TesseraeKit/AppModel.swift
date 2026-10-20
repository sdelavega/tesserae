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
    /// Whether the renderer is animating a zoom. Only `setZoomRunning`, the
    /// generation-guarded report from the current treemap, and `settle` (when
    /// no treemap remains to report) change it.
    @Published public private(set) var zoomRunning = false {
        didSet {
            guard !zoomRunning, decorationsPending else { return }
            decorationsPending = false
            updateLabels()
            requestTable()
        }
    }
    private var decorationsPending = false
    /// Whether `labels` belong to the current layout: false from the start of
    /// every relayout (a resize hides the stale set at once) until placement
    /// for the current layout is applied. The overlay fades in on this.
    @Published public private(set) var labelsReady = false
    public private(set) var layoutGeneration: UInt64 = 0
    @Published public var droppedTileCount = 0
    @Published public private(set) var root: UInt32
    private var size = CGSize.zero
    private var observers: Set<AnyCancellable> = []
    private var tableTask: Task<Void, Never>?
    private var labelTask: Task<Void, Never>?
    /// How label text is measured; called off the main actor, so it must be
    /// thread-safe (`LabelStyle.measure` is). Tests substitute a probe.
    var labelMeasure: @Sendable (String) -> CGSize = LabelStyle.measure

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

    deinit {
        tableTask?.cancel()
        labelTask?.cancel()
    }

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
        labelsReady = false
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
        // An empty layout shows the empty state instead of a treemap, so
        // nothing animated before it, and nothing will report after it: the
        // view that shows the next layout is new, and its first update sees
        // the tiles `makeNSView` already installed. Either way no renderer
        // will end this navigation, so settle here.
        let noRenderer = tiles.isEmpty || next.isEmpty
        tiles = next
        if noRenderer {
            settle()
        } else if decorationsPending {
            labels = []
        } else {
            updateLabels()
        }
    }

    /// Ends any zoom and releases deferred decorations without a renderer report.
    private func settle() {
        if zoomRunning {
            zoomRunning = false  // didSet releases pending decorations
        } else if decorationsPending {
            decorationsPending = false
            updateLabels()
            requestTable()
        } else {
            updateLabels()
        }
    }

    /// Places labels for the current tiles off the main actor (text measurement
    /// dominates, up to ~67 ms on a Data-volume layout) and applies the result
    /// only if no relayout happened meanwhile. Until then the previous labels
    /// stay (a resize) or are already empty (a navigation).
    private func updateLabels() {
        labelTask?.cancel()
        guard !tiles.isEmpty else {
            labels = []
            labelTask = nil
            return
        }
        let tiles = self.tiles, snapshot = self.snapshot, measure = labelMeasure
        let generation = layoutGeneration
        let work = Task.detached(priority: .userInitiated) { () -> [PlacedLabel]? in
            let timing = FrameTimer.shared.begin("labels", tiles: tiles.count)
            defer { FrameTimer.shared.end(timing) }
            let placed = placeLabels(tiles, in: snapshot, measure: measure)
            return Task.isCancelled ? nil : placed
        }
        labelTask = Task { [weak self] in
            let placed = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let placed, let self, !Task.isCancelled, generation == self.layoutGeneration else { return }
            let apply = FrameTimer.shared.begin("labels-apply", tiles: placed.count)
            self.labels = placed
            self.labelsReady = true
            FrameTimer.shared.end(apply)
        }
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
        navigator.ascend(to: node)
    }

    private func requestTable() {
        tableTask?.cancel()
        // Clear and invalidate synchronously before scheduling async work.
        table.reset()
        tableTask = Task { [weak self] in await self?.loadTable() }
    }

    func waitForTable() async { await tableTask?.value }
    func waitForLabels() async { await labelTask?.value }

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
