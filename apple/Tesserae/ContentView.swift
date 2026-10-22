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
import TesseraeKit

struct ContentView: View {
    static let minimumContentSize = CGSize(width: 1440, height: 720)
    @StateObject private var model = AppModel()
    @StateObject private var volumes = VolumeListModel()
    @StateObject private var reclaimUI = ReclaimPresentation()
    @State private var showReclaim = true
    #if TESSERAE_TEST_HOOKS
    /// The frame-gate runner exists only when `TESSERAE_FRAME_TIMING=1`.
    @State private var phaseGate: PhaseGateRunner? = FrameTimer.shared.isEnabled ? PhaseGateRunner() : nil
    #endif
    @State private var showScanReport = false
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            #if TESSERAE_TEST_HOOKS
            if let phaseGate { PhaseGateStatus(runner: phaseGate) }
            #endif
            if model.onboarding.showsLimitedAffordance {
                LimitedAccessView { model.sendOnboarding(.reopen) }
            }
            if model.colourChoice == 2 { focusControls }
            if model.startScreenPresented {
                startScreen
            } else if let session = model.session {
                SessionView(session: session, mode: model.colourMode, dark: dark, grantAccess: { model.sendOnboarding(.openSettings) },
                    stage: stage, stagingDisabled: model.stagingUnavailable || model.isScanning || model.reclaimBusy || reclaimUI.showingConfirmation,
                    reclaimUI: reclaimUI, showReclaim: showReclaim, showScanReport: showScanReport, appModel: model, sheetOpen: reclaimUI.showingConfirmation || model.onboardingPresented)
                    .id(session.id)
            } else {
                HSplitView {
                    welcome
                    if showReclaim {
                        ScrollView {
                            RecentlyTrashedView(entries: reclaimUI.history, messages: reclaimUI.messages, restoring: reclaimUI.restoring, canRestore: model.canPutBack,
                                restore: { entry in Task { await reclaimUI.restore(entry, model: model) } })
                            ReclaimStatusView(logFailed: reclaimUI.logFailed)
                        }.frame(minWidth: 300, idealWidth: 350)
                    }
                }
            }
        }
        .onChange(of: model.session?.id) { _ in
            if !reclaimUI.running { reclaimUI.showingConfirmation = false }
        }
        .focusedSceneValue(\.reclaimCommands, ReclaimCommandsValue(
            canStage: model.session != nil && !model.stagingUnavailable && !model.isScanning && !model.reclaimBusy && !reclaimUI.showingConfirmation,
            canRemove: model.session != nil && !model.reclaimBusy && !reclaimUI.showingConfirmation,
            stage: stage, remove: { if let session = model.session { session.reclaim.unstage(session.selection.nodes) } }))
        .focusedSceneValue(\.colourCommands, ColourCommandsValue(choice: $model.colourChoice))
        .focusedSceneValue(\.scanCommands, ScanCommandsValue(
            startupDiskTitle: model.startupDiskScanTitle, enabled: !reclaimUI.showingConfirmation,
            scanStartupDisk: model.scanStartupDisk, chooseFolder: chooseFolder,
            canRescan: model.canRescan, rescan: model.rescan, showStartScreen: model.showStartScreen))
        .sheet(isPresented: Binding(get: { reclaimUI.decompression != nil }, set: { if !$0 { reclaimUI.dismissDecompression() } })) {
            if let review = reclaimUI.decompression {
                if reclaimUI.running { TrashProgressView(done: 0, total: review.fileCount, cancellationRequested: reclaimUI.cancellationRequested, cancel: reclaimUI.cancelExecution) }
                else {
                    ConfirmDecompressSheet(confirmation: Binding(get: { reclaimUI.decompression ?? review },
                        set: { reclaimUI.decompression = $0 }),
                        cancel: reclaimUI.dismissDecompression,
                        execute: { reclaimUI.startDecompression(run: review.run, model: model) })
                }
            }
        }
        .sheet(isPresented: $reclaimUI.showingConfirmation) {
            Group {
                if reclaimUI.running {
                    TrashProgressView(done: reclaimUI.done, total: reclaimUI.confirmation.items.count, cancellationRequested: reclaimUI.cancellationRequested, cancel: reclaimUI.cancelExecution)
                } else {
                    ConfirmReclaimSheet(confirmation: $reclaimUI.confirmation,
                        cancel: { reclaimUI.showingConfirmation = false },
                        move: { reclaimUI.startExecution(model) })
                }
            }.interactiveDismissDisabled(reclaimUI.running)
        }
        .frame(minWidth: Self.minimumContentSize.width, minHeight: Self.minimumContentSize.height)
        #if TESSERAE_TEST_HOOKS
        .onReceive(NotificationCenter.default.publisher(for: .init("TesseraeRunFrameGate"))) { _ in
            guard let phaseGate, let session = model.session, case .success(let gate) = FrameGateConfiguration.current
            else { return }
            phaseGate.run(session: session, requiredRoot: "/System/Volumes/Data", minimumNodes: 1_000_000, output: gate.output, setMode: model.setColourMode)
        }
        .task {
            guard let phaseGate, case .success(let gate) = FrameGateConfiguration.current,
                let root = gate.autorunRoot else { return }
            await FrameGateAutorun.run(
                root: root, output: gate.output, timeout: gate.timeout, model: model, runner: phaseGate)
        }
        #endif
        .sheet(isPresented: Binding(get: { model.onboardingPresented }, set: model.setOnboardingPresented)) {
            VStack(spacing: 0) {
                OnboardingView(state: model.onboarding, send: model.sendOnboarding)
                Text(AppChrome.updateDisclosure)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom], 24)
            }.frame(width: 560)
        }
        .navigationTitle(model.windowTitle)
        .toolbar {
            ToolbarItemGroup {
                ForEach(ToolbarHelp.controls(startupDiskName: model.startupDiskName)) { control in
                    toolbarControl(control)
                        .help(control.help)
                        .accessibilityLabel(control.accessibilityLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func toolbarControl(_ control: ToolbarControl) -> some View {
        switch control.id {
        case .location:
            Button(action: model.showStartScreen) { Label(control.title, systemImage: control.systemImage) }
                .disabled(reclaimUI.showingConfirmation)
        case .folder:
            Button(action: chooseFolder) { Label(control.title, systemImage: control.systemImage) }
                .disabled(reclaimUI.showingConfirmation)
        case .rescan:
            Button(action: model.rescan) { Label(control.title, systemImage: control.systemImage) }
                .disabled(!model.canRescan || reclaimUI.showingConfirmation)
        case .reclaim:
            Button(control.title) { showReclaim.toggle() }
        case .report:
            if model.session != nil {
                Button { showScanReport.toggle() } label: { Label(control.title, systemImage: control.systemImage) }
            }
        case .cancel:
            if model.isScanning {
                Button(control.title, role: .cancel, action: model.cancel).keyboardShortcut(".", modifiers: .command)
            }
        case .colour:
            Picker(control.title, selection: $model.colourChoice) {
                ForEach(ColourMenuMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }.frame(width: 150)
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            if case .scanning(let progress) = model.scanState {
                ProgressView().controlSize(.large)
                Text(String(
                    localized: "contentView.scanning",
                    defaultValue: "Scanning…",
                    comment: "ContentView: Scanning…."
                )).font(.title2)
                Text(String(
                    localized: "scan.progress.counts",
                    defaultValue: "\(progress.dirs) folders · \(progress.files) files",
                    locale: L10n.pluralLocale(locale),
                    comment: "Folders and files visited so far; pluralize each count independently."
                ))
                Text(String(
                    localized: "contentView.entries.s",
                    defaultValue: "\(progress.displayedEntriesPerSecond.formatted()) entries/s · \(displaySize(progress.bytes, locale: locale))",
                    comment: "ContentView: {progress.displayedEntriesPerSecond.formatted()} entries/s · {displaySize(progress.bytes, locale: locale)}."
                ))
                    .monospacedDigit()
                if progress.errors > 0 { Text(String(
                    localized: "contentView.errors",
                    defaultValue: "\(progress.errors) errors",
                    locale: L10n.pluralLocale(locale),
                    comment: "ContentView: {progress.errors} errors."
                )).foregroundStyle(.secondary) }
            } else if case .failed(let errno) = model.scanState {
                ScanFailureView(errno: errno, chooseFolder: chooseFolder)
            } else {
                startScreen
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startScreen: some View {
        let cancel: (() -> Void)? = model.session == nil ? nil : { model.dismissStartScreen() }
        return StartView(volumes: volumes, scan: { model.scanVolume($0) }, chooseFolder: chooseFolder,
                         cancel: cancel)
    }

    private var focusControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(
                    localized: "contentView.focus.on.up.to.three.types",
                    defaultValue: "Focus on up to three types",
                    comment: "ContentView: Focus on up to three types."
                )).font(.caption).foregroundStyle(.secondary)
                ForEach(FileKind.allCases, id: \.self) { kind in
                    Toggle(kind.displayName, isOn: Binding(
                        get: { model.focusKinds.contains(kind) },
                        set: { _ in model.toggleFocus(kind) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(model.focusKinds.count == 3 && !model.focusKinds.contains(kind))
                }
            }
            HStack(spacing: 18) {
                ForEach(Array(model.focusLegend(dark: dark).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(colour(item.colour)).frame(width: 12, height: 12)
                        Text(item.accessibilityLabel).font(.caption)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stage() {
        guard !reclaimUI.showingConfirmation else { return }
        model.stageSelection()
        showReclaim = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(
            localized: "contentView.scan",
            defaultValue: "Scan",
            comment: "ContentView: Scan."
        )
        if panel.runModal() == .OK, let url = panel.url { model.scan(url) }
    }
}

#if TESSERAE_TEST_HOOKS
private struct PhaseGateStatus: View {
    @ObservedObject var runner: PhaseGateRunner
    var body: some View {
        if let status = runner.status {
            Text(status).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif

struct SessionView: View {
    @ObservedObject private var detail = DetailSettings.shared
    @ObservedObject var session: AppSession
    var mode: ColourMode
    var dark: Bool
    var grantAccess: () -> Void
    var stage: () -> Void
    var stagingDisabled: Bool
    @ObservedObject var reclaimUI: ReclaimPresentation
    var showReclaim: Bool
    var showScanReport = false
    var useMetal = true
    var reportLayout: ScanReportLayout? = nil
    let appModel: AppModel
    var sheetOpen = false
    @AppStorage("showFolderNames") private var showFolderNames = true
    @Environment(\.locale) private var locale

    var body: some View {
        let generation = session.layoutGeneration
        VStack(spacing: 0) {
            if let banner = session.banner(for: detail.current) { ScanWarningView(text: banner) }
            if session.droppedTileCount > 0 {
                ScanWarningView(text: String(
                    localized: "scan.rendering.limit",
                    defaultValue: "Rendering limit: \(session.droppedTileCount) tiles could not be displayed.",
                    locale: L10n.pluralLocale(locale),
                    comment: "Warning with number of tiles omitted by the rendering budget."
                ))
            }
            HStack(spacing: 6) {
                Button { session.navigator.ascend() } label: { Image(systemName: "arrow.up") }
                    .help(String(
                        localized: "contentView.parent.folder",
                        defaultValue: "Parent folder (⌘↑)",
                        comment: "ContentView: Parent folder (⌘↑)."
                    ))
                    .accessibilityLabel(String(
                        localized: "contentView.parent.folder",
                        defaultValue: "Parent folder (⌘↑)",
                        comment: "ContentView: Parent folder (⌘↑)."
                    ))
                    .disabled(session.root == session.snapshot.root)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.navigator.breadcrumbItems, id: \.node) { item in
                            Button(item.title) { session.go(to: item.node) }
                                .buttonStyle(.plain).lineLimit(1)
                            if item.node != session.root { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Spacer()
                Text(displaySize(session.root == Tile.noNode ? 0 : session.source.allocated(session.root), locale: locale)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            if session.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "folder").font(.largeTitle)
                                    Text(String(
                                        localized: "contentView.no.allocated.file.data.in.this.folder",
                                        defaultValue: "No allocated file data in this folder",
                                        comment: "ContentView: No allocated file data in this folder."
                                    )).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                TreemapView(
                                    tiles: session.tiles, palette: Palette.colours(mode, dark: dark), dark: dark,
                                    navigator: session.navigator, snapshot: session.snapshot, mode: mode,
                                    selection: session.selection, useMetal: useMetal,
                                    onZoomChanged: { session.setZoomRunning($0, generation: generation) },
                                    onDroppedTiles: { session.droppedTileCount = $0 },
                                    onHover: { session.hover(tile: $0) },
                                    onPointer: { session.pointerMoved(tile: $0, point: $1) },
                                    onDismissCallout: { session.hoverCallout.hide(for: $0) },
                                    onStage: stagingDisabled ? nil : stage,
                                    colourOf: { session.tileColourIndex($0, mode: mode) })
                                LabelsOverlay(
                                    labels: session.labels, palette: Palette.colours(mode, dark: dark),
                                    colourOf: { session.tileColourIndex($0, mode: mode) }, dark: dark,
                                    zoomRunning: session.zoomRunning, labelsReady: session.labelsReady)
                                ForEach(session.selectedTiles) { item in
                                    let tile = item.tile
                                    Rectangle().stroke(Color.primary, lineWidth: 2)
                                        .frame(width: tile.rect.width, height: tile.rect.height)
                                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                                        .allowsHitTesting(false)
                                }.opacity(session.zoomRunning ? 0 : 1)
                                deniedBadges
                                HoverCalloutOverlay(model: session.hoverCallout, hidden: session.zoomRunning || sheetOpen)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                        .onAppear { session.showFolderNames = showFolderNames; session.resize(to: geometry.size) }
                        .onChange(of: showFolderNames) { session.showFolderNames = $0 }
                        .onChange(of: geometry.size) { session.resize(to: $0) }
                    }.frame(minHeight: 220)
                    Divider()
                    TablePane(session: session, rows: session.table, selection: session.selection, stage: stage, stagingDisabled: stagingDisabled)
                        .frame(minHeight: 150, idealHeight: 220)
                }.frame(minWidth: 620, idealWidth: 700)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let model = session.reconciliation {
                            ReconciliationView(model: model, grantAccess: grantAccess).padding(16)
                            Divider()
                        }
                        InspectorPane(model: session.inspectorModel, stage: stage, stagingDisabled: stagingDisabled, unavailable: appModel.stagingUnavailable,
                            unavailableMessage: session.changedSinceScan ? ReclaimCopy.changedSinceScan : ReclaimCopy.unavailable)
                        if appModel.stagingUnavailable { Text(session.changedSinceScan ? ReclaimCopy.changedSinceScan : ReclaimCopy.unavailable).padding(16) }
                    }
                }.frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                if showReclaim {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ReclaimPane(reclaim: session.reclaim, unavailable: appModel.stagingUnavailable,
                                unavailableMessage: session.changedSinceScan ? ReclaimCopy.changedSinceScan : ReclaimCopy.unavailable,
                                busy: reclaimUI.showingConfirmation || appModel.isScanning || appModel.reclaimBusy || session.isPreparingReclaim, confirm: { reclaimUI.prepare(session.reclaim.viewModel.items, model: appModel) })
                            ReclaimStatusView(rescanCount: session.needsRescan ? session.overlay.deleted.count : nil,
                                logFailed: reclaimUI.logFailed)
                            if let result = reclaimUI.result {
                                ReclaimSummaryView(result: result, entries: reclaimUI.resultEntries, messages: reclaimUI.messages, restoring: reclaimUI.restoring, canRestore: appModel.canPutBack,
                                    restore: { entry in Task { await reclaimUI.restore(entry, model: appModel) } })
                            }
                            RecentlyCompressedView(entries: reclaimUI.compressedHistory,
                                busy: appModel.reclaimBusy || appModel.isScanning || reclaimUI.running,
                                decompress: { entry in Task { await reclaimUI.prepareDecompression(entry, model: appModel) } })
                            if let text = reclaimUI.decompressResult { Text(reclaimUI.decompressOutcome?.displayResult(detailLevel: detail.current) ?? text).padding(18) }
                            RecentlyTrashedView(entries: reclaimUI.history, messages: reclaimUI.messages, restoring: reclaimUI.restoring, canRestore: appModel.canPutBack,
                                restore: { entry in Task { await reclaimUI.restore(entry, model: appModel) } })
                        }
                    }.frame(minWidth: 260, idealWidth: 280, maxWidth: 350)
                }
                if showScanReport { ScanReportView(report: session.scanReport, layout: reportLayout) }
            }
        }
    }

    private var deniedBadges: some View {
        ForEach(session.deniedTiles) { item in
            let tile = item.tile
            let badge = FolderBadge(snapshot: session.snapshot, tile: tile, locale: locale)
            Image(systemName: badge.symbol)
                .font(.system(size: min(11, max(3, min(tile.rect.width, tile.rect.height) - 1))))
                .foregroundStyle(LabelStyle.inkColour(over: Palette.colours(mode, dark: dark)[Palette.statusIndex]))
                .frame(width: tile.rect.width, height: tile.rect.height, alignment: .topLeading)
                .offset(x: tile.rect.minX, y: tile.rect.minY)
                .accessibilityLabel(badge.label)
                .allowsHitTesting(false)
        }.opacity(session.zoomRunning ? 0 : 1)
    }

}

private struct InspectorPane: View {
    @ObservedObject var model: InspectorModel
    var stage: () -> Void
    var stagingDisabled: Bool
    var unavailable: Bool
    var unavailableMessage = ReclaimCopy.unavailable
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "contentView.inspector",
                defaultValue: "Inspector",
                comment: "ContentView: Inspector."
            )).font(.headline)
            Button(String(
                localized: "contentView.add.to.reclaim.space",
                defaultValue: "Add to Reclaim Space",
                comment: "ContentView: Add to Reclaim Space."
            ), action: stage).disabled(stagingDisabled)
                .help(unavailable ? unavailableMessage : String(
                    localized: "contentView.stage.the.selected.items",
                    defaultValue: "Stage the selected items (⌘⌫)",
                    comment: "ContentView: Stage the selected items (⌘⌫)."
                ))
            if let info = model.info {
                Text(info.displayTitle).font(.callout).lineLimit(1).truncationMode(.middle)
                    .help(info.displayTitle).textSelection(.enabled)
                Divider()
                detail(String(
                    localized: "contentView.kind",
                    defaultValue: "Kind",
                    comment: "ContentView: Kind."
                ), info.kind.displayName)
                detail(String(
                    localized: "contentView.allocated",
                    defaultValue: "Allocated",
                    comment: "ContentView: Allocated."
                ), displaySize(info.allocated, locale: locale))
                detail(String(
                    localized: "contentView.logical",
                    defaultValue: "Logical",
                    comment: "ContentView: Logical."
                ), displaySize(info.logical, locale: locale))
                detail(String(
                    localized: "contentView.modified",
                    defaultValue: "Modified",
                    comment: "ContentView: Modified."
                ), info.modified?.formatted(date: .abbreviated, time: .shortened) ?? String(
                    localized: "contentView.unknown",
                    defaultValue: "Unknown",
                    comment: "ContentView: Unknown."
                ))
            } else {
                Text(String(
                    localized: "contentView.point.to.a.tile.to.see.its.path",
                    defaultValue: "Point to a tile to see its path, size and modification date.",
                    comment: "ContentView: Point to a tile to see its path, size and modification date."
                ))
                    .foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
        }.padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

private struct TablePane: View {
    @ObservedObject var session: AppSession
    @AppStorage("fileListMode") private var mode: FileListMode = .folders
    @Environment(\.locale) private var locale
    @ObservedObject var rows: FileTableRows
    let selection: Selection
    var stage: () -> Void
    var stagingDisabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(String(localized: "contentView.fileListMode", defaultValue: "File list", comment: "Accessible label for file-list mode selector."), selection: $mode) {
                Text(String(localized: "contentView.folders", defaultValue: "Folders", comment: "Folder tree list mode.")).tag(FileListMode.folders)
                Text(String(localized: "contentView.largestFiles", defaultValue: "Largest Files", comment: "Largest files list mode.")).tag(FileListMode.largestFiles)
            }.pickerStyle(.segmented).labelsHidden().padding(8)
            if mode == .folders {
                FolderOutlineView(source: session.source, root: session.root, selection: selection,
                    navigator: session.navigator, expansion: session.folderExpansion, locale: locale,
                    onStage: stagingDisabled ? nil : stage)
            } else {
                Text(String(
                    localized: "contentView.largest.1.000.files.in.this.folder.column",
                    defaultValue: "Largest 1,000 files in this folder · column sorts apply to this list",
                    comment: "ContentView: Largest 1,000 files in this folder · column sorts apply to this list."
                ))
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                if let content = rows.content {
                    FileTableView(snapshot: content.snapshot, rows: content.rows, selection: selection, overlay: session.overlay, locale: locale, onStage: stagingDisabled ? nil : stage) { key, ascending in
                        Task { await rows.sort(by: key, ascending: ascending) }
                    }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
    }
}

private func colour(_ value: SIMD4<Float>) -> Color {
    Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: Double(value.w))
}

private struct ReclaimPane: View {
    @ObservedObject var reclaim: Reclaim
    var unavailable: Bool
    var unavailableMessage = ReclaimCopy.unavailable
    var busy: Bool
    var confirm: () -> Void
    var body: some View {
        ReclaimPreparedPane(model: reclaim.viewModel, unavailable: unavailable, unavailableMessage: unavailableMessage,
            busy: busy, remove: { reclaim.unstage([$0]) }, confirm: confirm)
            .onAppear { reclaim.prepareReview() }
            .onChange(of: reclaim.items) { _ in reclaim.prepareReview() }
    }
}
private struct ReclaimPreparedPane: View {
    @ObservedObject var model: ReclaimViewModel
    var unavailable: Bool
    var unavailableMessage: String
    var busy: Bool
    var remove: (UInt32) -> Void
    var confirm: () -> Void
    var body: some View {
        ReclaimView(items: model.items, viewModel: model, unavailable: unavailable, unavailableMessage: unavailableMessage, busy: busy,
            remove: remove, confirm: confirm)
    }
}
