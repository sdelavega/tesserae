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

import Combine
import SwiftUI
import TesseraeKit

struct ReclaimView: View {
    @ObservedObject private var detail = DetailSettings.shared
    let items: [ReclaimItem]
    var viewModel: ReclaimViewModel?
    var advancedExpanded = false
    var unavailable = false
    var unavailableMessage = ReclaimCopy.unavailable
    var busy = false
    var remove: (UInt32) -> Void
    var confirm: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                localized: "reclaimView.reclaim.space",
                defaultValue: "Reclaim Space",
                comment: "ReclaimView: Reclaim Space."
            )).font(.title2.bold())
            Text(String(
                localized: "reclaimView.staged.until.confirmation",
                defaultValue: "Staged items stay where they are until you confirm their actions.",
                comment: "ReclaimView: Staged items stay where they are until you confirm their actions."
            )).foregroundStyle(.secondary)
            if unavailable { Text(unavailableMessage).font(.callout) }
            Text(TrashConfirmation(items: items).total(locale: locale)).font(.headline)
            if items.isEmpty { Text(String(
                localized: "reclaimView.no.items.staged",
                defaultValue: "No items staged.",
                comment: "ReclaimView: No items staged."
            )).foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.displayPath).font(.headline).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(
                            localized: "reclaimView.remove.from.reclaim.space",
                            defaultValue: "Remove from Reclaim Space",
                            comment: "ReclaimView: Remove from Reclaim Space."
                        )) { remove(item.id) }.disabled(busy)
                    }
                    if let reason = item.outcomeReason {
                        let reason = detail.current == .simple ? item.presentationOutcome.map { keptOutcomeReason($0, detailLevel: .simple) } ?? reason : reason
                        Text(reason).font(.callout).lineLimit(1).help(reason) }
                    if let viewModel {
                        ReclaimActionPicker(model: viewModel, item: item, advancedExpanded: advancedExpanded)
                            .disabled(busy)
                        Text(viewModel.estimateText(for: item, locale: locale)).foregroundStyle(.secondary)
                    } else {
                        Text(ReclaimCopy.size(item.recordedSize, upperBound: item.recorded.isDirectory, unknownContent: item.hasUnknownContent, locale: locale)).foregroundStyle(.secondary)
                    }
                    if case .unavailable(let reason) = item.actionAvailability, !item.isCheckingArchive { Text(reason).font(.callout) }
                    if item.actionAvailability == .available {
                    switch item.verdict {
                    case .ok: Label(String(
                        localized: "reclaimView.ready.to.review",
                        defaultValue: "Ready to review",
                        comment: "ReclaimView: Ready to review."
                    ), systemImage: "checkmark.circle")
                    case .warn: Label(String(
                        localized: "reclaimView.review.warnings",
                        defaultValue: "Review warnings",
                        comment: "ReclaimView: Review warnings."
                    ), systemImage: "exclamationmark.triangle")
                    case .denied(let reason):
                        Label(String(
                            localized: "reclaimView.will.be.skipped",
                            defaultValue: "Will be skipped",
                            comment: "ReclaimView: Will be skipped."
                        ), systemImage: "hand.raised")
                        Text(reasonText(reason, detailLevel: detail.current))
                    }
                    } else if !item.isCheckingArchive {
                        Label(String(localized: "reclaimView.will.be.skipped", defaultValue: "Will be skipped",
                            comment: "ReclaimView: Will be skipped."), systemImage: "hand.raised")
                    }
                    ForEach(Array((viewModel?.previewText(for: item) ?? []).enumerated()), id: \.offset) { _, text in Text(text) }
                    ForEach(Array(itemWarnings(item).enumerated()), id: \.offset) { _, reason in Text(reasonText(reason, detailLevel: detail.current)) }
                }.padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)
            }
            Button(ReclaimCopy.review, action: confirm).disabled(items.isEmpty || unavailable || busy)

        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentlyTrashedView: View {
    let entries: [LogEntry]
    var messages: [String: String] = [:]
    var restoring: Set<String> = []
    var canRestore: (LogEntry) -> Bool = { _ in true }
    var restore: (LogEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "reclaimView.recently.trashed",
                defaultValue: "Recently trashed",
                comment: "ReclaimView: Recently trashed."
            )).font(.title2.bold())
            if entries.isEmpty { Text(String(
                localized: "reclaimView.no.items.available.to.put.back",
                defaultValue: "No items available to put back.",
                comment: "ReclaimView: No items available to put back."
            )).foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.displayPath).textSelection(.enabled)
                    HStack {
                        Text(entry.ts, style: .date).foregroundStyle(.secondary)
                        Spacer()
                        Button(String(
                            localized: "reclaimView.put.back",
                            defaultValue: "Put Back",
                            comment: "ReclaimView: Put Back."
                        )) { restore(entry) }.disabled(restoring.contains(entry.trashURL ?? "") || !canRestore(entry))
                            .help(canRestore(entry) ? String(
                                localized: "reclaimView.restore.this.item",
                                defaultValue: "Restore this item",
                                comment: "ReclaimView: Restore this item."
                            ) : ReclaimCopy.putBackWhileScanning)
                    }
                    if let message = messages[entry.trashURL ?? ""] { Text(message).font(.callout) }
                }
                Divider()
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReclaimStatusView: View {
    var rescanCount: Int?
    var logFailed = false
    var body: some View {
        if rescanCount != nil || logFailed {
            VStack(alignment: .leading, spacing: 10) {
                if let count = rescanCount { Label(ReclaimCopy.rescan(count), systemImage: "arrow.clockwise") }
                if logFailed { Label(ReclaimCopy.logFailure, systemImage: "exclamationmark.triangle") }
            }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class ReclaimPresentation: ObservableObject {
    @Published var showingConfirmation = false
    @Published var confirmation = TrashConfirmation(items: [])
    @Published var running = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var preparingDecompression = false
    private(set) var executionTask: Task<Void, Never>?
    private var decompressGeneration: UInt64 = 0
    private let compressorFactory: @MainActor (GuardContext, ReclaimLog) async -> Compressor?
    @Published var done = 0
    @Published var result: ExecutionResult?
    @Published var compressedHistory: [LogEntry] = []
    @Published var decompression: DecompressConfirmation?
    @Published var decompressResult: String?
    @Published var decompressOutcome: CompressOutcome?
    private var decompressEngine: Compressor?
    private var decompressSession: UUID?
    private var decompressRevision: UInt64?
    @Published var history: [LogEntry] = []
    @Published var resultEntries: [LogEntry] = []
    @Published var messages: [String: String] = [:]
    @Published var logFailed = false
    @Published var restoring: Set<String> = []
    let log: ReclaimLog

    private let historyLoader: @Sendable () -> [LogEntry]
    private var choicesChanged = false
    private var choiceObservation: AnyCancellable?
    private var reviewObservation: AnyCancellable?
    private var historyGeneration: UInt64 = 0
    private(set) var historyTask: Task<Void, Never>?

    init(log: ReclaimLog = ReclaimLog(), historyLoader: (@Sendable () -> [LogEntry])? = nil,
         compressorFactory: @escaping @MainActor (GuardContext, ReclaimLog) async -> Compressor? = { context, log in
             await Compressor.production(context: context, log: log)
         }) {
        self.compressorFactory = compressorFactory
        self.log = log
        self.historyLoader = historyLoader ?? { log.restorableEntries() }
        refresh()
    }
    @discardableResult
    func refresh() -> Task<Void, Never> {
        historyGeneration &+= 1
        let generation = historyGeneration
        let load = historyLoader
        let log = log
        let work = Task.detached(priority: .utility) {
            (load(), log.lastWriteFailed, log.entries().filter { $0.action == "compress" && ($0.compression?.filesChanged ?? 0) > 0 })
        }
        let publication = Task { [weak self] in
            let (entries, failed, compressed) = await work.value
            guard let self, generation == self.historyGeneration else { return }
            self.history = entries
            self.compressedHistory = compressed
            self.logFailed = failed
        }
        historyTask = publication
        return publication
    }
    func prepare(_ items: [ReclaimItem], model: AppModel? = nil, viewModel: ReclaimViewModel? = nil) {
        guard !items.isEmpty, model?.reclaimBusy != true, model?.stagingUnavailable != true else { return }
        reviewObservation?.cancel()
        choicesChanged = false
        confirmation = TrashConfirmation(items: items)
        if let vm = viewModel ?? model?.session?.reclaim.viewModel {
            confirmation.notes = Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, [vm.estimateText(for: $0)] + vm.previewText(for: $0))
            })
        }
        choiceObservation?.cancel()
        if let viewModel = viewModel ?? model?.session?.reclaim.viewModel {
            choiceObservation = viewModel.$items.dropFirst().sink { [weak self] current in
                guard let self, !self.running else { return }
                // A completed inspection leaves its frozen, unavailable row excluded.
                guard !self.preservesReview(current) else { return }
                self.choicesChanged = true
                self.showingConfirmation = false
            }
        }
        if let session = model?.session {
            reviewObservation = session.$overlay.combineLatest(session.$changedSinceScan).dropFirst().sink { [weak self] overlay, changed in
                guard let self, changed || overlay.revision != self.confirmation.overlayRevision, !self.running else { return }
                self.showingConfirmation = false
            }
        }
        showingConfirmation = true
    }
    private func preservesReview(_ current: [ReclaimItem]) -> Bool {
        let frozen = confirmation.items
        guard frozen.count == current.count else { return false }
        for (reviewed, updated) in zip(frozen, current) {
            if reviewed == updated { continue }
            guard reviewed.isCheckingArchive, reviewed.id == updated.id, reviewed.action == updated.action else { return false }
            guard reviewed.path == updated.path, reviewed.recorded == updated.recorded else { return false }
            guard reviewed.sessionID == updated.sessionID, reviewed.overlayRevision == updated.overlayRevision else { return false }
        }
        return true
    }
    @discardableResult
    func startExecution(_ model: AppModel, trasher: any Trasher = ProductionTrasher(),
                        stat: any FileStat = ProductionFileStat(), compressor: Compressor? = nil) -> Task<Void, Never>? {
        guard !running, executionTask == nil else { return nil }
        running = true; cancellationRequested = false; done = 0
        let task = Task {
            await performExecution(model, trasher: trasher, stat: stat, compressor: compressor)
            executionTask = nil
        }
        executionTask = task
        return task
    }
    func cancelExecution() {
        guard running else { return }
        cancellationRequested = true
        executionTask?.cancel()
    }
    func execute(_ model: AppModel, trasher: any Trasher = ProductionTrasher(),
                 stat: any FileStat = ProductionFileStat()) async {
        guard let task = startExecution(model, trasher: trasher, stat: stat) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func performExecution(_ model: AppModel, trasher: any Trasher, stat: any FileStat, compressor: Compressor?) async {
        let completed = await model.executeReclaim(confirmedWarnings: confirmation.confirmedWarnings, trasher: trasher, stat: stat, log: log,
            progress: { [weak self] count, _ in
                Task { @MainActor in if self?.running == true { self?.done = count } }
            }, reviewedVerdicts: Dictionary(uniqueKeysWithValues: confirmation.items.map {
                ($0.id, choicesChanged ? Verdict.denied(.changedSinceReview) : $0.verdict)
            }),
            reviewedWarnings: Dictionary(uniqueKeysWithValues: confirmation.items.map { ($0.id, Set(itemWarnings($0))) }),
            reviewedItems: confirmation.items, compressor: compressor)
        done = completed?.outcomes.count ?? 0
        result = completed
        // The returned destinations remain usable when the audit append failed.
        resultEntries = completed?.auditEntries.filter { $0.result == "ok" } ?? []
        refresh()
        running = false
        showingConfirmation = false
    }
    func dismissDecompression() {
        decompressGeneration &+= 1
        preparingDecompression = false
        decompression = nil; decompressEngine = nil; decompressSession = nil; decompressRevision = nil
    }
    func prepareDecompression(_ entry: LogEntry, model: AppModel) async {
        guard !running, !model.reclaimBusy, !model.isScanning, let context = model.session?.guardContext,
              let run = entry.compression?.runID, let session = model.session else { return }
        dismissDecompression()
        let generation = decompressGeneration, revision = session.overlay.revision
        preparingDecompression = true
        defer { if generation == decompressGeneration { preparingDecompression = false } }
        let engine = await compressorFactory(context, log)
        guard generation == decompressGeneration, !Task.isCancelled, !running,
              !model.reclaimBusy, !model.isScanning, model.session === session,
              revision == session.overlay.revision, let engine else { return }
        let review = await engine.reviewDecompression(run: run)
        guard generation == decompressGeneration, !Task.isCancelled, !running, !model.reclaimBusy,
              model.session === session, revision == session.overlay.revision, !model.isScanning else { return }
        decompressSession = session.id; decompressRevision = revision
        decompressEngine = engine; decompression = review
    }
    @discardableResult
    func startDecompression(run: CompressRunID, model: AppModel) -> Task<Void, Never>? {
        guard !model.reclaimBusy, !model.isScanning, !running, executionTask == nil, let session = model.session,
              session.id == decompressSession, session.overlay.revision == decompressRevision,
              let review = decompression, review.run == run, let engine = decompressEngine else { return nil }
        running = true; cancellationRequested = false
        let task = Task {
            let result = await session.decompress(run: run, using: engine, reviewed: review)
            decompressOutcome = result
            decompressResult = result.displayResult
            running = false; executionTask = nil
            dismissDecompression()
            refresh()
        }
        executionTask = task
        return task
    }
    func decompress(run: CompressRunID, model: AppModel) async {
        guard let task = startDecompression(run: run, model: model) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func restore(_ entry: LogEntry, model: AppModel, stat: any FileStat = ProductionFileStat(),
                 mover: any Mover = ProductionMover()) async {
        let key = entry.trashURL ?? ""
        guard restoring.insert(key).inserted else { return }
        defer { restoring.remove(key) }
        let restored = await model.putBack(entry, stat: stat, mover: mover, log: log)
        messages[entry.trashURL ?? ""] = putBackText(restored)
        if restored == .restored { resultEntries.removeAll { $0.trashURL == entry.trashURL } }
        refresh()
    }
}

struct ReclaimCommandsValue {
    var canStage: Bool
    var canRemove: Bool
    var stage: () -> Void
    var remove: () -> Void
}
private struct ReclaimCommandsKey: FocusedValueKey { typealias Value = ReclaimCommandsValue }
extension FocusedValues {
    var reclaimCommands: ReclaimCommandsValue? {
        get { self[ReclaimCommandsKey.self] }
        set { self[ReclaimCommandsKey.self] = newValue }
    }
}
struct ReclaimCommands: Commands {
    @FocusedValue(\.reclaimCommands) private var actions
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button(String(
                localized: "reclaimView.add.to.reclaim.space",
                defaultValue: "Add to Reclaim Space",
                comment: "ReclaimView: Add to Reclaim Space."
            )) { actions?.stage() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canStage != true)
            Button(String(
                localized: "reclaimView.remove.from.reclaim.space",
                defaultValue: "Remove from Reclaim Space",
                comment: "ReclaimView: Remove from Reclaim Space."
            )) { actions?.remove() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.canRemove != true)
        }
    }
}

struct ReclaimActionPicker: View {
    @ObservedObject var model: ReclaimViewModel
    let item: ReclaimItem
    @State var advancedExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu(item.action.title) {
                let actions: [ReclaimAction] = model.volume(for: item).canCompress
                    ? [.compress, model.archiveAction(for: item), .trash]
                    : [.trash, .compress, model.archiveAction(for: item)]
                ForEach(actions, id: \.self) { action in choice(action, title: action.title) }
            }
            if case .unavailable(let reason) = model.availability(.compress, for: item) { Text(reason).font(.callout) }
            if case .archive = item.action {
                formatPicker(advanced: false)
                DisclosureGroup(ReclaimCopy.advanced, isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        formatPicker(advanced: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func choice(_ action: ReclaimAction, title: String) -> some View {
        let availability = model.availability(action, for: item)
        return Button(title) { model.setAction(action, for: item.id) }
            .disabled(availability != .available)
            .help({ if case .unavailable(let reason) = availability { return reason }; return title }())
    }
    private func formatPicker(advanced: Bool) -> some View {
        Picker(item.action.title, selection: Binding(get: { model.selectedFormat(for: item) },
            set: { model.setAction(.archive($0), for: item.id) })) {
            ForEach(model.formats(for: item, advanced: advanced), id: \.self) { format in
                let availability = model.availability(.archive(format), for: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(format.title)
                    Text(format.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.tag(format).disabled(availability != .available)
                    .help({ if case .unavailable(let reason) = availability { return reason }; return format.note }())
            }
        }.pickerStyle(.radioGroup).labelsHidden()
    }
}

struct RecentlyCompressedView: View {
    let entries: [LogEntry]
    let busy: Bool
    let decompress: (LogEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ReclaimCopy.recentlyCompressed).font(.title2.bold())
            if entries.isEmpty { Text(ReclaimCopy.noCompressedItems).foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                Text(entry.displayPath).textSelection(.enabled)
                if let count = entry.compression?.filesChanged { Text(ReclaimCopy.items(count)) }
                Button(ReclaimCopy.decompress) { decompress(entry) }.disabled(busy)
            }
        }.padding(18)
    }
}

struct ConfirmDecompressSheet: View {
    @ObservedObject private var detail = DetailSettings.shared
    @Binding var confirmation: DecompressConfirmation
    let cancel: () -> Void
    let execute: () -> Void
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(confirmation.title(locale: locale)).font(.title2.bold())
            ScrollView {
                ForEach(confirmation.rows, id: \.path) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        if confirmation.warningRows.contains(row) {
                            Toggle(isOn: Binding(get: { confirmation.confirmedPaths.contains(row.path) },
                                set: { confirmation.setConfirmed(row.path, $0) })) {
                                Text(DisplayPath.text(row.path))
                            }.toggleStyle(.checkbox)
                        } else { Text(DisplayPath.text(row.path)) }
                        ForEach(confirmation.warnings[row.path] ?? [], id: \.self) { reason in
                            Text(reasonText(reason, detailLevel: detail.current)).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(8)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "reclaim.cancel", defaultValue: "Cancel", comment: "Cancel decompression."),
                    role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(ReclaimCopy.decompress, action: execute).disabled(confirmation.allowedPaths.isEmpty)
            }
        }.padding(24).frame(width: 620, height: 520)
    }
}
