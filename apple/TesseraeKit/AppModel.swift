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

/// Hover has its own observation boundary; SessionView never observes it.
@MainActor
public final class InspectorModel: ObservableObject {
    @Published public fileprivate(set) var info: InspectorInfo?
}

/// One snapshot and everything that indexes it. Replacing this object also
/// replaces the view identity, navigation, selection, hover and table together.
@MainActor
public final class AppSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let reconciliation: ReconciliationViewModel?
    public let scanReport: ScanReport
    public let snapshot: Snapshot
    public let navigator: Navigator
    public let selection = Selection()
    public let table = FileTableRows()
    public struct OverlayTile: Identifiable {
        public let id: Int
        public let tile: Tile
    }
    public private(set) var selectedTiles: [OverlayTile] = []
    public private(set) var deniedTiles: [OverlayTile] = []
    @Published public private(set) var tiles: [Tile] = [] {
        didSet {
            selectedTiles = []; deniedTiles = []
            for (index, tile) in tiles.enumerated() {
                let overlay = OverlayTile(id: index, tile: tile)
                if tile.flags & Tile.Flag.selected != 0 { selectedTiles.append(overlay) }
                if tile.isPermissionDenied { deniedTiles.append(overlay) }
            }
        }
    }
    @Published public private(set) var labels: [PlacedLabel] = []
    public let inspectorModel = InspectorModel()
    public var inspector: InspectorInfo? { inspectorModel.info }
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

    init(snapshot: Snapshot, reconciliation: ReconciliationViewModel? = nil, access: AccessState = .unknown, scanTime: Date = Date()) {
        scanReport = ScanReport(snapshot: snapshot, caveats: reconciliation?.caveats ?? [], access: access,
            scanTime: scanTime, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            engineVersion: engineVersion + " (ABI \(abiVersion))")
        self.reconciliation = reconciliation
        self.snapshot = snapshot
        navigator = Navigator(snapshot: snapshot)
        root = snapshot.root
        navigator.$root.dropFirst().sink { [weak self] root in
            guard let self else { return }
            self.root = root
            self.inspectorModel.info = nil
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
        return ScanBanner.text(for: snapshot.stats, stalledAt: path,
            volumePath: ScanReport.Location(rawPath: snapshot.rawPath(snapshot.root), reason: nil).displayPath)
    }

    public func resize(to size: CGSize) {
        guard size != self.size else { return }
        self.size = size
        relayout()
    }

    private func relayout() {
        layoutGeneration &+= 1
        inspectorModel.info = nil
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
        guard let tile, tiles.indices.contains(tile) else { inspectorModel.info = nil; return }
        inspectorModel.info = inspect(tileAt: tile, in: tiles, snapshot: snapshot)
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
    @Published public private(set) var onboarding: Onboarding
    @Published public private(set) var onboardingPresented = false
    private var relaunchGeneration = 0
    public var scanMode: ScanMode { onboarding.scanMode }
    private let onboardingStore: OnboardingStore
    private let homeDirectory: URL
    private let openSettings: () -> Bool
    private let relaunch: () async throws -> Void
    private let terminate: () -> Void
    private var accessTask: Task<Void, Never>?
    private var accessGeneration = 0
    private var pendingScan: URL?
    private let coordinator: ScanCoordinator
    private var observers: Set<AnyCancellable> = []
    private var factsTask: Task<Void, Never>?
    private var factsWork: Task<(ReconciliationViewModel, AccessState), Never>?
    private var scanStartedAt = Date()
    private var accessWork: Task<AccessState, Never>?
    private let accessLoader: @Sendable () -> AccessState
    private var factsGeneration = 0
    private let factsLoader: @Sendable (URL, ScanFacts) -> ReconciliationViewModel

    public convenience init() { self.init(coordinator: ScanCoordinator()) }

    init(coordinator: ScanCoordinator,
         accessLoader: @escaping @Sendable () -> AccessState = { AccessProbe().probe() },
         onboardingStore: OnboardingStore = OnboardingStore(),
         openSettings: @escaping () -> Bool = { NSWorkspace.shared.open(FullDiskAccessSettings.url) },
         relaunch: @escaping () async throws -> Void = AppModel.openNewInstance,
         terminate: @escaping () -> Void = { NSApp.terminate(nil) },
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
         factsLoader: @escaping @Sendable (URL, ScanFacts) -> ReconciliationViewModel = ReconciliationViewModel.load) {
        self.homeDirectory = homeDirectory
        self.onboardingStore = onboardingStore
        onboarding = Onboarding(choice: onboardingStore.choice)
        self.openSettings = openSettings
        self.relaunch = relaunch
        self.terminate = terminate
        self.accessLoader = accessLoader
        self.factsLoader = factsLoader
        self.coordinator = coordinator
        coordinator.$snapshot.sink { [weak self] snapshot in
            self?.prepareSnapshot(snapshot)
        }.store(in: &observers)
        coordinator.$state.sink { [weak self] state in
            guard let self else { return }
            // A finished app scan includes its facts; frame-gate callers also
            // rely on finished meaning a session is ready.
            if state == .finished, self.factsTask != nil { return }
            self.scanState = state
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshAccess() }.store(in: &observers)
        refreshAccess()
    }

    deinit {
        factsTask?.cancel()
        factsWork?.cancel()
        accessWork?.cancel()
        accessTask?.cancel()
    }

    func refreshAccess() {
        accessWork?.cancel()
        accessTask?.cancel()
        accessGeneration += 1
        let generation = accessGeneration
        let probe = accessLoader
        let work = Task.detached(priority: .utility) { probe() }
        accessWork = work
        accessTask = Task { [weak self] in
            let access = await work.value
            guard let self, !Task.isCancelled, generation == self.accessGeneration else { return }
            self.sendOnboarding(.activated(access))
        }
    }

    func waitForAccess() async { await accessTask?.value }

    public func sendOnboarding(_ event: Onboarding.Event) {
        let command = onboarding.send(event)
        onboardingPresented = onboarding.isPresented
        if !onboarding.isRelaunching { relaunchGeneration += 1 }
        if onboardingStore.choice != onboarding.choice { onboardingStore.choice = onboarding.choice }
        switch command {
        case .openSettings:
            if !openSettings() {
                // No activation will follow a failed open; allow a manual retry.
                sendOnboarding(.settingsFailed("Couldn’t open System Settings. Open Privacy & Security → Full Disk Access in System Settings."))
            }
        case .relaunch:
            relaunchGeneration += 1
            let generation = relaunchGeneration
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.relaunch()
                    guard self.onboarding.isRelaunching, generation == self.relaunchGeneration else { return }
                    self.terminate()
                } catch {
                    guard self.onboarding.isRelaunching, generation == self.relaunchGeneration else { return }
                    self.sendOnboarding(.relaunchFailed("Couldn’t relaunch Tesserae: \(error.localizedDescription)"))
                }
            }
        case nil: break
        }
        if onboarding.canScan, let url = pendingScan {
            pendingScan = nil
            startScan(url)
        }
    }

    public func setOnboardingPresented(_ presented: Bool) {
        guard !presented else { return }
        sendOnboarding(.dismissed)
        onboardingPresented = false
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.onboardingPresented = self.onboarding.isPresented
        }
    }

    static func openNewInstance() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    func prepareSnapshot(_ snapshot: Snapshot?) {
        factsTask?.cancel()
        factsWork?.cancel()
        factsWork = nil
        factsTask = nil
        factsGeneration += 1
        let generation = factsGeneration
        guard let snapshot else { session = nil; return }
        let path = String(decoding: snapshot.rawPath(snapshot.root), as: UTF8.self)
        let root = URL(fileURLWithPath: path)
        let access = accessWork
        let loader = factsLoader
        let scanTime = scanStartedAt
        let limited = coordinator.scanMode == .limited
        let work = Task.detached(priority: .userInitiated) {
            let state = await access?.value ?? .unknown
            let scan = ScanFacts(allocatedSum: snapshot.root == Tile.noNode ? 0 : snapshot.allocated(snapshot.root),
                unreadableLocations: Int(clamping: snapshot.stats.unreadable_count),
                incompleteReason: ScanBanner.incompleteReason(for: snapshot.stats,
                    stalledAt: snapshot.stalledAt.map { String(decoding: $0, as: UTF8.self) }),
                limited: limited, datalessItems: snapshot.datalessItems, access: state,
                datalessLogicalBytes: snapshot.datalessLogicalBytes, noMaterializeFailed: snapshot.noMaterializeFailed)
            return (loader(root, scan), state)
        }
        factsWork = work
        factsTask = Task { [weak self] in
            let (model, state) = await work.value
            guard let self, !Task.isCancelled, generation == self.factsGeneration else { return }
            self.session = AppSession(snapshot: snapshot, reconciliation: model, access: state, scanTime: scanTime)
            self.factsTask = nil
            self.factsWork = nil
            self.scanState = self.coordinator.state
        }
    }

    func waitForFacts() async { await factsTask?.value }

    func replaceSnapshot(_ snapshot: Snapshot?) {
        session = snapshot.map { AppSession(snapshot: $0) }
    }

    public func scan(_ url: URL) {
        guard onboarding.canScan else {
            pendingScan = url
            sendOnboarding(.reopen)
            return
        }
        startScan(url)
    }

    private func startScan(_ url: URL) {
        scanStartedAt = Date()
        let mode = scanMode
        let skip = mode == .limited ? ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { homeDirectory.appendingPathComponent($0) } : []
        coordinator.start(root: url, mode: mode, skip: skip)
    }

    public func cancel() { coordinator.cancel() }
    public var isScanning: Bool { if case .scanning = scanState { return true }; return false }
    public var colourMode: ColourMode {
        switch colourChoice {
        case 1: return .age(now: Date(timeIntervalSince1970: Double(session?.snapshot.stats.started_at ?? 0)))
        case 2: return .typeFocus(focusKinds)
        default: return .depth
        }
    }

    public func setColourMode(_ mode: ColourMode) {
        switch mode {
        case .depth: colourChoice = 0
        case .age: colourChoice = 1
        case .typeFocus(let kinds):
            focusKinds = Array(kinds.prefix(3))
            colourChoice = 2
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
