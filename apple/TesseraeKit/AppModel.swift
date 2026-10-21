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
    @Published public private(set) var isPreparingJetsam = false
    @Published public private(set) var changedSinceScan = false
    public let jetsam: Jetsam
    @Published public private(set) var overlay = SizeOverlay()
    public var source: OverlaySource { OverlaySource(snapshot, overlay) }
    public var needsRescan: Bool { overlay.needsRescan(rootAllocated: snapshot.allocated(snapshot.root)) }
    private var trashedNodes: [String: UInt32] = [:]
    public let guardContext: GuardContext?
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

    init(snapshot: Snapshot, reconciliation: ReconciliationViewModel? = nil, access: AccessState = .unknown, scanTime: Date = Date(), guardContext: GuardContext? = nil) {
        scanReport = ScanReport(snapshot: snapshot, caveats: reconciliation?.caveats ?? [], access: access,
            scanTime: scanTime, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            engineVersion: engineVersion + " (ABI \(abiVersion))")
        self.reconciliation = reconciliation
        self.snapshot = snapshot
        jetsam = Jetsam(sessionID: id)
        self.guardContext = guardContext
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
        jetsam.$items.sink { [weak self] items in
            guard let self else { return }
            var next = self.tiles
            applyStaging(&next, in: self.snapshot, staged: Set(items.map(\.nodeIndex)))
            self.tiles = next
        }.store(in: &observers)
        requestTable()
    }

    deinit {
        tableTask?.cancel()
        labelTask?.cancel()
    }

    public var isEmpty: Bool {
        snapshot.root == Tile.noNode || (source.allocated(root) == 0 && !snapshot.isPermissionDenied(root))
    }

    public var banner: String? {
        if changedSinceScan { return JetsamCopy.changedSinceScan }
        let path = snapshot.stalledAt.map { String(decoding: $0, as: UTF8.self) }
        let scan = ScanBanner.text(for: snapshot.stats, stalledAt: path,
            volumePath: ScanReport.Location(rawPath: snapshot.rawPath(snapshot.root), reason: nil).displayPath)
        guard needsRescan else { return scan }
        let prompt = JetsamCopy.rescan(overlay.deleted.count)
        return scan.map { $0 + " " + prompt } ?? prompt
    }

    public func execute(using executor: Executor, confirmedWarnings: Set<UInt32>,
                        progress: (@Sendable (Int, Int) -> Void)? = nil,
                        reviewedVerdicts: [UInt32: Verdict]? = nil, reviewedWarnings: [UInt32: Set<Reason>]? = nil,
                        reviewedItems: [JetsamItem]? = nil, stagingStat: any FileStat = ProductionFileStat()) async -> ExecutionResult {
        let items = reviewedItems ?? jetsam.items
        await JetsamCoordinator.shared.acquire()
        defer { JetsamCoordinator.shared.release() }
        guard !changedSinceScan else {
            return ExecutionResult(outcomes: items.map { ($0, .skipped(.changedSinceScan)) },
                reclaimableBytes: 0, unknownSizeTrashed: 0)
        }
        let revision = overlay.revision
        let result = await executor.run(items, confirmedWarnings: confirmedWarnings, progress: progress,
            reviewedVerdicts: reviewedVerdicts, reviewedWarnings: reviewedWarnings,
            currentRevision: revision, currentSessionID: id)
        for (item, outcome) in result.outcomes {
            if case .trashed(let url) = outcome {
                overlay.remove(item.nodeIndex, in: snapshot)
                trashedNodes[url.absoluteString] = item.nodeIndex
            }
        }
        jetsam.unstage(Set(result.outcomes.compactMap { item, outcome in
            if case .trashed = outcome { return item.id }; return nil
        }))
        if overlay.revision != revision { await reprepareStaged(stat: stagingStat) }
        refreshOverlay()
        return result
    }

    private func reprepareStaged(stat: any FileStat) async {
        guard let context = guardContext, !jetsam.items.isEmpty else { return }
        isPreparingJetsam = true
        defer { isPreparingJetsam = false }
        let prepared = await PutBackExecutor.shared.prepare(jetsam.items.map(\.nodeIndex),
            snapshot: snapshot, context: context, stat: stat, overlay: overlay, existing: [], sessionID: id)
        jetsam.publish(prepared)
    }

    public func putBack(_ entry: LogEntry, stat: any FileStat, mover: any Mover,
                        log: any AuditSink = JettisonLog()) async -> PutBackResult {
        await JetsamCoordinator.shared.acquire()
        defer { JetsamCoordinator.shared.release() }
        return await putBackUnderPermit(entry, stat: stat, mover: mover, log: log)
    }

    fileprivate func putBackUnderPermit(_ entry: LogEntry, stat: any FileStat, mover: any Mover,
                                       log: any AuditSink) async -> PutBackResult {
        // History outside this session has no snapshot/overlay membership to
        // restore safely. Finder followed by a rescan rebuilds those facts.
        guard let key = entry.trashURL, trashedNodes[key] != nil else {
            return .failed("This item belongs to an earlier scan. Use Finder's Put Back, then rescan.")
        }
        guard let path = entry.path.map({ Data($0.utf8) }) ?? entry.pathB64.flatMap({ Data(base64Encoded: $0) }) else {
            return .failed("Invalid original path")
        }
        guard !JetsamCoordinator.shared.isScanning(containing: path) else { return .failed(JetsamCopy.putBackWhileScanning) }
        let result = await PutBackExecutor.shared.restore(entry, stat: stat, mover: mover, log: log)
        if result == .restored, let url = entry.trashURL, let node = trashedNodes.removeValue(forKey: url) {
            overlay.restore(node, in: snapshot)
            await reprepareStaged(stat: stat)
            refreshOverlay()
        }
        if result == .restored { JetsamCoordinator.shared.recordRestoration(path, fileID: entry.inode) }
        return result
    }

    func recordRestoration(_ entry: LogEntry) {
        guard let path = entry.path.map({ Data($0.utf8) }) ?? entry.pathB64.flatMap({ Data(base64Encoded: $0) }) else { return }
        recordRestoration(path, fileID: entry.inode)
    }

    func markChangedSinceScan() {
        changedSinceScan = true
        jetsam.clear()
    }

    func recordRestoration(_ path: Data, fileID: UInt64) {
        guard snapshot.root != Tile.noNode else { return }
        let rootPath = snapshot.rawPath(snapshot.root)
        let prefix = rootPath == Data([0x2f]) ? rootPath : rootPath + Data([0x2f])
        guard pathIsWithin(path, root: rootPath) else { return }
        var node: UInt32? = snapshot.root
        if path != rootPath {
            for component in path.dropFirst(prefix.count).split(separator: 0x2f) {
                node = node.flatMap { parent in
                    snapshot.children(parent).first { snapshot.nameBytes($0) == Data(component) }
                }
                if node == nil { break }
            }
        }
        guard let node, snapshot.fileID(node) == fileID else {
            markChangedSinceScan()
            return
        }
    }

    private func refreshOverlay() {
        // No suspension: invalidate stale rows and layout in the same actor turn.
        requestTable()
        navigator.updateOverlay(overlay)
        relayout()
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
        var next = squarify(source, root: root, in: CGRect(origin: .zero, size: size))
        FrameTimer.shared.end(layout)
        applySelection(&next, selection.nodes)
        applyStaging(&next, in: snapshot, staged: jetsam.stagedNodes)
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
        let tiles = self.tiles, snapshot = self.snapshot, measure = labelMeasure, overlay = self.overlay
        let generation = layoutGeneration
        let work = Task.detached(priority: .userInitiated) { () -> [PlacedLabel]? in
            let timing = FrameTimer.shared.begin("labels", tiles: tiles.count)
            defer { FrameTimer.shared.end(timing) }
            let placed = placeLabels(tiles, in: snapshot, measure: measure, overlay: overlay)
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
        inspectorModel.info = inspect(tileAt: tile, in: tiles, snapshot: snapshot, overlay: overlay)
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
        await table.load(FileTableModel(snapshot: snapshot, scope: root, overlay: overlay))
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var isExecutingJetsam = false
    public var jetsamBusy: Bool { isPreparingJetsam || isExecutingJetsam || !restoresInFlight.isEmpty }
    @Published public private(set) var restoresInFlight: Set<String> = []
    @Published public private(set) var stagingUnavailable = false
    @Published public private(set) var session: AppSession? {
        didSet { stagingUnavailable = session != nil && (session?.guardContext == nil || session?.changedSinceScan == true) }
    }
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
    private var factsWork: Task<(ReconciliationViewModel, AccessState, GuardContext?), Never>?
    private var scanStartedAt = Date()
    private var scanGeneration: UInt64 = 0
    private var scanRoot: Data?
    private var scanChangedSinceScan = false
    @Published public private(set) var scanPending = false
    private var scanStartTask: Task<Void, Never>?
    private var accessWork: Task<AccessState, Never>?
    private let accessLoader: @Sendable () -> AccessState
    private var factsGeneration = 0
    private let stagingStat: FileStat
    private let contextLoader: @Sendable (Snapshot) -> GuardContext?
    private let factsLoader: @Sendable (URL, ScanFacts) -> ReconciliationViewModel

    public convenience init() { self.init(coordinator: ScanCoordinator()) }

    init(coordinator: ScanCoordinator,
         accessLoader: @escaping @Sendable () -> AccessState = { AccessProbe().probe() },
         onboardingStore: OnboardingStore = OnboardingStore(),
         openSettings: @escaping () -> Bool = { NSWorkspace.shared.open(FullDiskAccessSettings.url) },
         relaunch: @escaping () async throws -> Void = AppModel.openNewInstance,
         terminate: @escaping () -> Void = { NSApp.terminate(nil) },
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
         stagingStat: FileStat = ProductionFileStat(),
         contextLoader: @escaping @Sendable (Snapshot) -> GuardContext? = AppModel.loadGuardContext,
         factsLoader: @escaping @Sendable (URL, ScanFacts) -> ReconciliationViewModel = ReconciliationViewModel.load) {
        self.homeDirectory = homeDirectory
        self.onboardingStore = onboardingStore
        onboarding = Onboarding(choice: onboardingStore.choice)
        self.openSettings = openSettings
        self.relaunch = relaunch
        self.terminate = terminate
        self.accessLoader = accessLoader
        self.factsLoader = factsLoader
        self.contextLoader = contextLoader
        self.stagingStat = stagingStat
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
        JetsamCoordinator.shared.register(self)
        refreshAccess()
    }

    deinit {
        scanStartTask?.cancel()
        stagingTask?.cancel()
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

    nonisolated static func loadGuardContext(_ snapshot: Snapshot) -> GuardContext? {
        guard snapshot.root != Tile.noNode else { return nil }
        let scanRoot = snapshot.rawPath(snapshot.root)
        guard let volume = try? volumeRoot(of: scanRoot) else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory()).withUnsafeFileSystemRepresentation {
            Data(bytes: $0!, count: strlen($0!))
        }
        return GuardContext(scanRoot: scanRoot, volumeRoot: volume, scanRootDevice: snapshot.rootDevice,
                            appBundle: Bundle.main.bundleURL.resolvingSymlinksInPath(), home: home)
    }

    @Published public private(set) var isPreparingJetsam = false
    private var stagingGeneration: UInt64 = 0
    private var stagingTask: Task<Void, Never>?

    public func cancelStaging() {
        stagingGeneration &+= 1
        stagingTask?.cancel()
        isPreparingJetsam = false
    }

    func waitForStaging() async { await stagingTask?.value }

    public func stageSelection() {
        guard !isScanning, let session, !session.changedSinceScan, let context = session.guardContext else { return }
        cancelStaging()
        let generation = stagingGeneration
        let nodes = session.selection.nodes.sorted(), stat = stagingStat
        isPreparingJetsam = true
        stagingTask = Task { [weak self] in
            await JetsamCoordinator.shared.acquire()
            defer { JetsamCoordinator.shared.release() }
            guard let self else { return }
            defer { if generation == self.stagingGeneration { self.isPreparingJetsam = false } }
            guard !Task.isCancelled, !self.isScanning, !session.changedSinceScan,
                  generation == self.stagingGeneration, self.session === session else { return }
            let snapshot = session.snapshot, overlay = session.overlay, existing = session.jetsam.items
            let prepared = await PutBackExecutor.shared.prepare(nodes, snapshot: snapshot, context: context,
                stat: stat, overlay: overlay, existing: existing, sessionID: session.id)
            guard !Task.isCancelled, generation == self.stagingGeneration,
                  self.session === session, !self.isScanning, !session.changedSinceScan,
                  session.overlay.revision == overlay.revision else { return }
            session.jetsam.publish(prepared)
        }
    }

    public func executeJetsam(confirmedWarnings: Set<UInt32>, trasher: any Trasher = ProductionTrasher(),
                              stat: any FileStat = ProductionFileStat(), log: any AuditSink = JettisonLog(),
                              progress: (@Sendable (Int, Int) -> Void)? = nil,
                              reviewedVerdicts: [UInt32: Verdict]? = nil, reviewedWarnings: [UInt32: Set<Reason>]? = nil,
                              reviewedItems: [JetsamItem]? = nil) async -> ExecutionResult? {
        guard !jetsamBusy, !isScanning, let session, !session.changedSinceScan,
              let context = session.guardContext else { return nil }
        isExecutingJetsam = true
        defer { isExecutingJetsam = false }
        return await session.execute(using: Executor(trasher: trasher, stat: stat, log: log, context: context),
            confirmedWarnings: confirmedWarnings, progress: progress, reviewedVerdicts: reviewedVerdicts,
            reviewedWarnings: reviewedWarnings, reviewedItems: reviewedItems, stagingStat: stagingStat)
    }

    public func putBack(_ entry: LogEntry, stat: any FileStat = ProductionFileStat(),
                        mover: any Mover = ProductionMover(), log: any AuditSink = JettisonLog()) async -> PutBackResult {
        let key = entry.trashURL ?? ""
        guard restoresInFlight.insert(key).inserted else { return .failed("Put Back is already in progress.") }
        defer { restoresInFlight.remove(key) }
        let captured = session, generation = scanGeneration
        await JetsamCoordinator.shared.acquire()
        defer { JetsamCoordinator.shared.release() }
        guard !isScanning, generation == scanGeneration, let captured, session === captured,
              entry.device == captured.snapshot.rootDevice else { return .failed(JetsamCopy.putBackWhileScanning) }
        return await captured.putBackUnderPermit(entry, stat: stat, mover: mover, log: log)
    }

    func isScanning(containing path: Data) -> Bool {
        isScanning && scanRoot.map { pathIsWithin(path, root: $0) } == true
    }

    func recordRestoration(_ path: Data, fileID: UInt64) {
        if isScanning(containing: path) { scanChangedSinceScan = true }
        session?.recordRestoration(path, fileID: fileID)
        if session?.changedSinceScan == true {
            cancelStaging()
            stagingUnavailable = true
        }
    }

    func prepareSnapshot(_ snapshot: Snapshot?) {
        cancelStaging()
        session?.jetsam.clear()
        factsTask?.cancel()
        factsWork?.cancel()
        factsWork = nil
        factsTask = nil
        factsGeneration += 1
        let generation = factsGeneration
        guard let snapshot else { session = nil; return }
        scanRoot = snapshot.rawPath(snapshot.root)
        let path = String(decoding: snapshot.rawPath(snapshot.root), as: UTF8.self)
        let root = URL(fileURLWithPath: path)
        let access = accessWork
        let loader = factsLoader
        let loadContext = contextLoader
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
            return (loader(root, scan), state, loadContext(snapshot))
        }
        factsWork = work
        factsTask = Task { [weak self] in
            let (model, state, context) = await work.value
            guard let self, !Task.isCancelled, generation == self.factsGeneration else { return }
            let session = AppSession(snapshot: snapshot, reconciliation: model, access: state, scanTime: scanTime, guardContext: context)
            if self.scanChangedSinceScan { session.markChangedSinceScan() }
            self.session = session
            self.factsTask = nil
            self.factsWork = nil
            self.scanState = self.coordinator.state
        }
    }

    func waitForFacts() async { await factsTask?.value }

    func replaceSnapshot(_ snapshot: Snapshot?) {
        scanGeneration &+= 1
        scanChangedSinceScan = false
        cancelStaging()
        session?.jetsam.clear()
        session = snapshot.map { AppSession(snapshot: $0, guardContext: contextLoader($0)) }
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
        scanRoot = url.withUnsafeFileSystemRepresentation { p in p.map { Data(bytes: $0, count: strlen($0)) } }
        scanChangedSinceScan = false
        cancelStaging()
        session?.jetsam.clear()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanStartTask?.cancel()
        scanPending = true
        let mode = scanMode
        let skip = mode == .limited ? ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"]
            .map { homeDirectory.appendingPathComponent($0) } : []
        scanStartTask = Task { [weak self] in
            await JetsamCoordinator.shared.acquire()
            defer { JetsamCoordinator.shared.release() }
            guard let self, !Task.isCancelled, generation == self.scanGeneration else { return }
            self.scanStartedAt = Date()
            self.scanPending = false
            self.coordinator.start(root: url, mode: mode, skip: skip)
            self.scanStartTask = nil
        }
    }

    public func cancel() {
        scanGeneration &+= 1
        scanStartTask?.cancel()
        scanStartTask = nil
        scanPending = false
        coordinator.cancel()
    }
    public var isScanning: Bool {
        if scanPending || factsTask != nil { return true }
        if case .scanning = scanState { return true }
        return false
    }
    public func canPutBack(_ entry: LogEntry) -> Bool {
        guard !isScanning, session != nil, entry.device == session?.snapshot.rootDevice,
              let path = entry.path.map({ Data($0.utf8) }) ?? entry.pathB64.flatMap({ Data(base64Encoded: $0) }) else { return false }
        return !JetsamCoordinator.shared.isScanning(containing: path)
    }
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
