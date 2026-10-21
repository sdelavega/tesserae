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

struct JetsamView: View {
    let items: [JetsamItem]
    var unavailable = false
    var unavailableMessage = JetsamCopy.unavailable
    var preparing = false
    var busy = false
    var remove: (UInt32) -> Void
    var confirm: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jetsam").font(.title2.bold())
            Text("Staged items stay where they are until you confirm Move to Trash.").foregroundStyle(.secondary)
            if unavailable { Text(unavailableMessage).font(.callout) }
            if preparing { Text("Preparing…").font(.headline) }
            Text(TrashConfirmation(items: items).total(locale: locale)).font(.headline)
            if items.isEmpty { Text("No items staged.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(String(decoding: item.path, as: UTF8.self)).font(.headline).textSelection(.enabled)
                        Spacer()
                        Button("Remove from Jetsam") { remove(item.id) }.disabled(busy || preparing)
                    }
                    Text(item.recordedSize.map { (item.recorded.isDirectory ? "Up to " : "") + displaySize($0, locale: locale) + (item.hasUnknownContent ? " + unknown content" : "") } ?? "Unknown size").foregroundStyle(.secondary)
                    switch item.verdict {
                    case .ok: Label("Ready to move to Trash", systemImage: "checkmark.circle")
                    case .warn: Label("Review warnings", systemImage: "exclamationmark.triangle")
                    case .denied(let reason):
                        Label("Will be skipped", systemImage: "hand.raised")
                        Text(reasonText(reason))
                    }
                    ForEach(Array(itemWarnings(item).enumerated()), id: \.offset) { _, reason in Text(reasonText(reason)) }
                }.padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)
            }
            Button("Move to Trash…", action: confirm).disabled(items.isEmpty || unavailable || busy || preparing)
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
            Text("Recently trashed").font(.title2.bold())
            if entries.isEmpty { Text("No items available to put back.").foregroundStyle(.secondary) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.path ?? "Path bytes: " + (entry.pathB64 ?? "")).textSelection(.enabled)
                    HStack {
                        Text(entry.ts, style: .date).foregroundStyle(.secondary)
                        Spacer()
                        Button("Put Back") { restore(entry) }.disabled(restoring.contains(entry.trashURL ?? "") || !canRestore(entry))
                            .help(canRestore(entry) ? "Restore this item" : JetsamCopy.putBackWhileScanning)
                    }
                    if let message = messages[entry.trashURL ?? ""] { Text(message).font(.callout) }
                }
                Divider()
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct JetsamStatusView: View {
    var rescanCount: Int?
    var logFailed = false
    var body: some View {
        if rescanCount != nil || logFailed {
            VStack(alignment: .leading, spacing: 10) {
                if let count = rescanCount { Label(JetsamCopy.rescan(count), systemImage: "arrow.clockwise") }
                if logFailed { Label(JetsamCopy.logFailure, systemImage: "exclamationmark.triangle") }
            }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class JetsamPresentation: ObservableObject {
    @Published var showingConfirmation = false
    @Published var confirmation = TrashConfirmation(items: [])
    @Published var running = false
    @Published var done = 0
    @Published var result: ExecutionResult?
    @Published var history: [LogEntry] = []
    @Published var resultEntries: [LogEntry] = []
    @Published var messages: [String: String] = [:]
    @Published var logFailed = false
    @Published var restoring: Set<String> = []
    let log: JettisonLog

    private let historyLoader: @Sendable () -> [LogEntry]
    private var reviewObservation: AnyCancellable?
    private var historyGeneration: UInt64 = 0
    private(set) var historyTask: Task<Void, Never>?

    init(log: JettisonLog = JettisonLog(), historyLoader: (@Sendable () -> [LogEntry])? = nil) {
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
        let work = Task.detached(priority: .utility) { (load(), log.lastWriteFailed) }
        let publication = Task { [weak self] in
            let (entries, failed) = await work.value
            guard let self, generation == self.historyGeneration else { return }
            self.history = entries
            self.logFailed = failed
        }
        historyTask = publication
        return publication
    }
    func prepare(_ items: [JetsamItem], model: AppModel? = nil) {
        guard !items.isEmpty, model?.jetsamBusy != true, model?.stagingUnavailable != true else { return }
        reviewObservation?.cancel()
        confirmation = TrashConfirmation(items: items)
        if let session = model?.session {
            reviewObservation = session.$overlay.combineLatest(session.$changedSinceScan).dropFirst().sink { [weak self] overlay, changed in
                guard let self, changed || overlay.revision != self.confirmation.overlayRevision, !self.running else { return }
                self.showingConfirmation = false
            }
        }
        showingConfirmation = true
    }
    func execute(_ model: AppModel, trasher: any Trasher = ProductionTrasher(),
                 stat: any FileStat = ProductionFileStat()) async {
        guard !running else { return }
        running = true
        let session = model.session
        done = 0
        let completed = await model.executeJetsam(confirmedWarnings: confirmation.confirmedWarnings, trasher: trasher, stat: stat, log: log,
            progress: { [weak self] count, _ in
                Task { @MainActor in if self?.running == true { self?.done = count } }
            }, reviewedVerdicts: Dictionary(uniqueKeysWithValues: confirmation.items.map { ($0.id, $0.verdict) }),
            reviewedWarnings: Dictionary(uniqueKeysWithValues: confirmation.items.map { ($0.id, Set(itemWarnings($0))) }),
            reviewedItems: confirmation.items)
        done = completed?.outcomes.count ?? 0
        result = completed
        // The returned destinations remain usable when the audit append failed.
        resultEntries = completed?.auditEntries.filter { $0.result == "ok" } ?? []
        if let completed {
            session?.jetsam.unstage(Set(completed.outcomes.compactMap { item, outcome in
                if case .trashed = outcome { return item.id }; return nil
            }))
        }
        refresh()
        running = false
        showingConfirmation = false
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

struct JetsamCommandsValue {
    var canStage: Bool
    var canRemove: Bool
    var stage: () -> Void
    var remove: () -> Void
}
private struct JetsamCommandsKey: FocusedValueKey { typealias Value = JetsamCommandsValue }
extension FocusedValues {
    var jetsamCommands: JetsamCommandsValue? {
        get { self[JetsamCommandsKey.self] }
        set { self[JetsamCommandsKey.self] = newValue }
    }
}
struct JetsamCommands: Commands {
    @FocusedValue(\.jetsamCommands) private var actions
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Add to Jetsam") { actions?.stage() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canStage != true)
            Button("Remove from Jetsam") { actions?.remove() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.canRemove != true)
        }
    }
}
