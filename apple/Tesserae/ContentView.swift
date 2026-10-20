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
    @StateObject private var model = AppModel()
    /// The frame-gate runner exists only when `TESSERAE_FRAME_TIMING=1`.
    @State private var phaseGate: PhaseGateRunner? = FrameTimer.shared.isEnabled ? PhaseGateRunner() : nil
    @State private var showScanReport = false
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            if let phaseGate { PhaseGateStatus(runner: phaseGate) }
            if model.onboarding.showsLimitedAffordance {
                LimitedAccessView { model.sendOnboarding(.reopen) }
            }
            if model.colourChoice == 2 { focusControls }
            if let session = model.session {
                HSplitView {
                    SessionView(session: session, mode: model.colourMode, dark: dark, grantAccess: { model.sendOnboarding(.openSettings) })
                        .id(session.id)
                    if showScanReport { ScanReportView(report: session.scanReport) }
                }
            } else {
                welcome
            }
        }
        .frame(minWidth: 960, minHeight: 580)
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
        .sheet(isPresented: Binding(get: { model.onboardingPresented }, set: model.setOnboardingPresented)) {
            OnboardingView(state: model.onboarding, send: model.sendOnboarding)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.scan(URL(fileURLWithPath: "/System/Volumes/Data")) } label: {
                    Label("Scan Data Volume", systemImage: "internaldrive")
                }
                Button { chooseFolder() } label: { Label("Scan Folder…", systemImage: "folder") }
                if model.session != nil {
                    Button { showScanReport.toggle() } label: { Label("Scan report", systemImage: "doc.text.magnifyingglass") }
                        .help("Show or hide the scan report")
                }
                if model.isScanning { Button("Cancel", role: .cancel) { model.cancel() } }
                Picker("Colour", selection: $model.colourChoice) {
                    Text("Depth").tag(0)
                    Text("Age").tag(1)
                    Text("Type focus").tag(2)
                }.frame(width: 150)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            if case .scanning(let progress) = model.scanState {
                ProgressView().controlSize(.large)
                Text("Scanning…").font(.title2)
                Text("\(progress.dirs.formatted()) folders · \(progress.files.formatted()) files")
                Text("\(Int(progress.entriesPerSecond).formatted()) entries/s · \(displaySize(progress.bytes, locale: locale))")
                    .monospacedDigit()
                if progress.errors > 0 { Text("\(progress.errors.formatted()) errors").foregroundStyle(.secondary) }
            } else if case .failed(let errno) = model.scanState {
                ScanFailureView(errno: errno, chooseFolder: chooseFolder)
            } else {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 48)).foregroundStyle(.blue)
                Text("See where your space goes").font(.largeTitle)
                Text("Scan a folder or your Data volume to explore its files by size.").foregroundStyle(.secondary)
                Button("Scan Folder…") { chooseFolder() }.keyboardShortcut("o")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var focusControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Focus on up to three types").font(.caption).foregroundStyle(.secondary)
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { model.scan(url) }
    }
}

private struct PhaseGateStatus: View {
    @ObservedObject var runner: PhaseGateRunner
    var body: some View {
        if let status = runner.status {
            Text(status).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SessionView: View {
    @ObservedObject var session: AppSession
    var mode: ColourMode
    var dark: Bool
    var grantAccess: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        let generation = session.layoutGeneration
        VStack(spacing: 0) {
            if let banner = session.banner { ScanWarningView(text: banner) }
            if session.droppedTileCount > 0 {
                ScanWarningView(text: "Rendering limit: \(session.droppedTileCount.formatted()) tiles could not be displayed.")
            }
            HStack(spacing: 6) {
                Button { session.navigator.ascend() } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder (⌘↑)")
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
                Text(displaySize(session.root == Tile.noNode ? 0 : session.snapshot.allocated(session.root), locale: locale)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            if session.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "folder").font(.largeTitle)
                                    Text("No allocated file data in this folder").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                TreemapView(
                                    tiles: session.tiles, palette: Palette.colours(mode, dark: dark), dark: dark,
                                    navigator: session.navigator, snapshot: session.snapshot, mode: mode,
                                    selection: session.selection,
                                    onZoomChanged: { session.setZoomRunning($0, generation: generation) },
                                    onDroppedTiles: { session.droppedTileCount = $0 },
                                    onHover: { session.hover(tile: $0) },
                                    colourOf: { colourIndex(for: $0, in: session.snapshot, mode: mode) })
                                LabelsOverlay(
                                    labels: session.labels, palette: Palette.colours(mode, dark: dark),
                                    colourOf: { colourIndex(for: $0, in: session.snapshot, mode: mode) }, dark: dark,
                                    zoomRunning: session.zoomRunning, labelsReady: session.labelsReady)
                                ForEach(session.selectedTiles) { item in
                                    let tile = item.tile
                                    Rectangle().stroke(Color.primary, lineWidth: 2)
                                        .frame(width: tile.rect.width, height: tile.rect.height)
                                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                                        .allowsHitTesting(false)
                                }.opacity(session.zoomRunning ? 0 : 1)
                                deniedBadges
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                        .onAppear { session.resize(to: geometry.size) }
                        .onChange(of: geometry.size) { session.resize(to: $0) }
                    }.frame(minHeight: 220)
                    Divider()
                    TablePane(rows: session.table, selection: session.selection)
                        .frame(minHeight: 150, idealHeight: 220)
                }.frame(minWidth: 600)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let model = session.reconciliation {
                            ReconciliationView(model: model, grantAccess: grantAccess).padding(16)
                            Divider()
                        }
                        InspectorPane(model: session.inspectorModel)
                    }
                }.frame(width: 240)
            }
        }
    }

    private var deniedBadges: some View {
        ForEach(session.deniedTiles) { item in
            let tile = item.tile
            let badge = FolderBadge(snapshot: session.snapshot, node: tile.node)
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
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector").font(.headline)
            if let info = model.info {
                Text(info.displayTitle).font(.callout).lineLimit(1).truncationMode(.middle)
                    .help(info.displayTitle).textSelection(.enabled)
                Divider()
                detail("Kind", info.kind.displayName)
                detail("Allocated", displaySize(info.allocated, locale: locale))
                detail("Logical", displaySize(info.logical, locale: locale))
                detail("Modified", info.modified?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
            } else {
                Text("Point to a tile to see its path, size and modification date.")
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
    @ObservedObject var rows: FileTableRows
    let selection: Selection
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Largest 1,000 files in this folder · column sorts apply to this list")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            if let content = rows.content {
                FileTableView(snapshot: content.snapshot, rows: content.rows, selection: selection) { key, ascending in
                    Task { await rows.sort(by: key, ascending: ascending) }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

private func colour(_ value: SIMD4<Float>) -> Color {
    Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: Double(value.w))
}
