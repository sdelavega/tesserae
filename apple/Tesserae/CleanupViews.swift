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

private func swatch(_ value: SIMD4<Float>) -> Color {
    Color(.sRGB, red: Double(value.x), green: Double(value.y), blue: Double(value.z), opacity: Double(value.w))
}

// MARK: - Changes since the last scan

struct ChangeLegendView: View {
    let index: ChangeIndex?
    let loading: Bool
    let snapshot: Snapshot?
    let legend: [FocusLegendItem]
    let go: (UInt32) -> Void
    @Environment(\.locale) private var locale

    private var caption: String {
        if loading {
            return String(localized: "changes.loading", defaultValue: "Comparing with the previous scan…",
                          comment: "Change colour mode while the comparison is computed.")
        }
        guard let index else {
            return String(localized: "changes.none",
                          defaultValue: "No earlier complete scan of this location to compare with. Scan it again later to see what changed.",
                          comment: "Change colour mode when there is no earlier scan of the location.")
        }
        let date = index.baselineDate.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "changes.since", defaultValue: "Changes since the scan of \(date)",
                      comment: "Change colour mode caption; the placeholder is the earlier scan's date and time.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption).font(.caption).foregroundStyle(Aether.muted)
            if index != nil {
                HStack(spacing: 18) {
                    ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(swatch(item.colour)).frame(width: 12, height: 12)
                            Text(item.accessibilityLabel).font(.caption)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.accessibilityLabel)
                    }
                }
            }
            if let index, let snapshot, !index.largestGrowth.isEmpty {
                HStack(spacing: 12) {
                    Text(String(localized: "changes.grewMost", defaultValue: "Grew most:",
                                comment: "Label before the folders that grew most since the previous scan."))
                        .font(.caption).foregroundStyle(Aether.muted)
                    ForEach(index.largestGrowth, id: \.node) { growth in
                        let name = snapshot.displayName(growth.node)
                        let size = displaySize(growth.bytes, locale: locale)
                        Button(String(localized: "changes.growth.item", defaultValue: "\(name) +\(size)",
                                      comment: "A folder that grew and by how much; opens it in the map.")) { go(growth.node) }
                            .buttonStyle(.link).font(.caption)
                            .help(snapshot.displayPath(growth.node))
                    }
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Finding duplicates and rebuildable folders

@MainActor
final class CleanupPresentation: ObservableObject {
    enum Sheet: String, Identifiable {
        case duplicates, rebuildable
        var id: String { rawValue }
    }

    typealias DuplicateState = DuplicateSearchState

    @Published var sheet: Sheet?
    @Published private(set) var duplicates: DuplicateState = .done([])
    @Published private(set) var rebuildable: [RegenerableItem]?
    @Published var selected: Set<UInt32> = []
    private(set) weak var session: AppSession?
    private var task: Task<Void, Never>?

    func findDuplicates(in session: AppSession) {
        start(session, sheet: .duplicates)
        duplicates = .searching(DuplicateFinder.Progress(filesRead: 0, filesToRead: 0))
        let snapshot = session.snapshot, overlay = session.overlay, root = session.root
        let report: @Sendable (DuplicateFinder.Progress) -> Void = { progress in
            Task { @MainActor in self.show(progress) }
        }
        task = Task { [weak self] in
            let groups = await DuplicateFinder.run(in: snapshot, under: root, overlay: overlay, progress: report)
            guard let self, !Task.isCancelled else { return }
            self.duplicates = .finished(groups)
            guard let groups else { return }
            session.rememberDuplicateGroups(groups)
            // Keep the oldest copy of each file; select the rest.
            self.selected = Set(groups.flatMap { $0.members.dropFirst() })
        }
    }

    private func show(_ progress: DuplicateFinder.Progress) {
        if case .searching = duplicates { duplicates = .searching(progress) }
    }

    func findRebuildable(in session: AppSession) {
        start(session, sheet: .rebuildable)
        rebuildable = nil
        let snapshot = session.snapshot, overlay = session.overlay, root = session.root
        let work = Task.detached(priority: .userInitiated) {
            RegenerableFinder.find(in: snapshot, under: root, overlay: overlay)
        }
        task = Task { [weak self] in
            let items = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.rebuildable = items
            self.selected = Set(items.filter(\.preselected).map(\.node))
        }
    }

    private func start(_ session: AppSession, sheet: Sheet) {
        task?.cancel()
        self.session = session
        selected = []
        self.sheet = sheet
    }

    func close() {
        task?.cancel()
        task = nil
        sheet = nil
        selected = []
    }

    func binding(for node: UInt32) -> Binding<Bool> {
        Binding(get: { self.selected.contains(node) },
                set: { if $0 { self.selected.insert(node) } else { self.selected.remove(node) } })
    }
}

struct DuplicatesSheet: View {
    @ObservedObject var cleanup: CleanupPresentation
    let snapshot: Snapshot
    let canStage: Bool
    let stage: ([UInt32]) -> Void
    @Environment(\.locale) private var locale

    private var selectedBytes: UInt64 {
        guard case .done(let groups) = cleanup.duplicates else { return 0 }
        return groups.reduce(0) { total, group in
            total + group.allocatedEach * UInt64(group.members.filter { cleanup.selected.contains($0) }.count)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "duplicates.title", defaultValue: "Duplicate Files",
                        comment: "Title of the duplicate files sheet.")).font(.title2.bold())
            Text(String(localized: "duplicates.explanation",
                        defaultValue: "Files of 1 MB or more with identical content in the current view. Cloud-only files are not downloaded or compared. The oldest copy of each file is left unselected. Copies that are APFS clones already share space, so removing them frees less.",
                        comment: "Explains how duplicate files are found and what is preselected."))
                .font(.callout).foregroundStyle(Aether.muted).fixedSize(horizontal: false, vertical: true)
            content.frame(maxHeight: .infinity)
            HStack {
                if case .done(let groups) = cleanup.duplicates, !groups.isEmpty {
                    let size = displaySize(selectedBytes, locale: locale)
                    Text(String(localized: "duplicates.selected.size", defaultValue: "Selected copies use \(size)",
                                comment: "Space used by the duplicate copies selected for Reclaim Space."))
                        .foregroundStyle(Aether.muted)
                }
                Spacer()
                Button(String(localized: "cleanup.cancel", defaultValue: "Cancel", comment: "Close a cleanup sheet.")) {
                    cleanup.close()
                }.keyboardShortcut(.cancelAction)
                Button(String(localized: "cleanup.addToReclaim", defaultValue: "Add Selected to Reclaim Space",
                              comment: "Stage the selected items in Reclaim Space for review.")) {
                    stage(cleanup.selected.sorted())
                }
                .buttonStyle(AetherPrimaryButtonStyle())
                .disabled(!canStage || cleanup.selected.isEmpty)
            }
        }.padding(20).frame(width: 760, height: 540)
    }

    @ViewBuilder private var content: some View {
        switch cleanup.duplicates {
        case .searching(let progress):
            VStack(spacing: 10) {
                ProgressView(value: Double(progress.filesRead), total: Double(max(progress.filesToRead, 1)))
                let read = progress.filesRead.formatted(), total = progress.filesToRead.formatted()
                Text(String(localized: "duplicates.progress", defaultValue: "Comparing files: \(read) of \(total)",
                            comment: "Progress while reading candidate files to find duplicates."))
                    .foregroundStyle(Aether.muted).monospacedDigit()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            Text(String(localized: "duplicates.failed",
                        defaultValue: "Duplicate search could not safely read files. Try again later.",
                        comment: "Duplicate search failed to enforce safe file reading."))
                .foregroundStyle(Aether.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let groups) where groups.isEmpty:
            Text(String(localized: "duplicates.none", defaultValue: "No duplicate files were found here.",
                        comment: "The duplicate search finished without finding any."))
                .foregroundStyle(Aether.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let groups):
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.members, id: \.self) { node in
                            memberRow(node, in: group)
                        }
                    } header: {
                        let copies = group.members.count.formatted()
                        let size = displaySize(group.allocatedEach, locale: locale)
                        Text(String(localized: "duplicates.group.header", defaultValue: "Copies: \(copies) · \(size) each",
                                    comment: "Header of a group of identical files: how many copies and the size of each."))
                    }
                }
            }
        }
    }

    private func memberRow(_ node: UInt32, in group: DuplicateGroup) -> some View {
        let unselected = group.members.filter { !cleanup.selected.contains($0) }
        // At least one copy always stays out of the selection.
        let lastKept = unselected.count == 1 && unselected[0] == node
        let modified = Date(timeIntervalSince1970: Double(snapshot.nodes[Int(node)].modified))
        return Toggle(isOn: cleanup.binding(for: node)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayPath(node)).lineLimit(1).truncationMode(.middle)
                Text(modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Aether.muted)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(lastKept)
        .help(lastKept ? String(localized: "duplicates.keepOne", defaultValue: "One copy is always kept.",
                                comment: "Why the last unselected copy of a duplicate cannot be selected.") : snapshot.displayPath(node))
    }
}

struct RebuildableSheet: View {
    @ObservedObject var cleanup: CleanupPresentation
    let snapshot: Snapshot
    let canStage: Bool
    let stage: ([UInt32]) -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "rebuildable.title", defaultValue: "Rebuildable Folders",
                        comment: "Title of the rebuildable folders sheet.")).font(.title2.bold())
            Text(String(localized: "rebuildable.explanation",
                        defaultValue: "Folders in the current view that developer tools recreate when needed, such as build output, installed packages and download caches. Removing them frees space now; rebuilding them later takes time and may need a network connection.",
                        comment: "Explains what rebuildable folders are and the cost of removing them."))
                .font(.callout).foregroundStyle(Aether.muted).fixedSize(horizontal: false, vertical: true)
            content.frame(maxHeight: .infinity)
            HStack {
                if let items = cleanup.rebuildable, !items.isEmpty {
                    let bytes = items.filter { cleanup.selected.contains($0.node) }.reduce(UInt64(0)) { $0 + $1.allocated }
                    let size = displaySize(bytes, locale: locale)
                    Text(String(localized: "rebuildable.selected.size", defaultValue: "Selected folders use \(size)",
                                comment: "Space used by the rebuildable folders selected for Reclaim Space."))
                        .foregroundStyle(Aether.muted)
                }
                Spacer()
                Button(String(localized: "cleanup.cancel", defaultValue: "Cancel", comment: "Close a cleanup sheet.")) {
                    cleanup.close()
                }.keyboardShortcut(.cancelAction)
                Button(String(localized: "cleanup.addToReclaim", defaultValue: "Add Selected to Reclaim Space",
                              comment: "Stage the selected items in Reclaim Space for review.")) {
                    stage(cleanup.selected.sorted())
                }
                .buttonStyle(AetherPrimaryButtonStyle())
                .disabled(!canStage || cleanup.selected.isEmpty)
            }
        }.padding(20).frame(width: 760, height: 540)
    }

    @ViewBuilder private var content: some View {
        if let items = cleanup.rebuildable {
            if items.isEmpty {
                Text(String(localized: "rebuildable.none", defaultValue: "No rebuildable folders of 1 MB or more were found here.",
                            comment: "The rebuildable folder search finished without finding any."))
                    .foregroundStyle(Aether.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(RegenerableKind.allCases, id: \.self) { kind in
                        let matches = items.filter { $0.kind == kind }
                        if !matches.isEmpty {
                            Section {
                                ForEach(matches) { item in
                                    Toggle(isOn: cleanup.binding(for: item.node)) {
                                        VStack(alignment: .leading) {
                                            HStack {
                                                Text(snapshot.displayPath(item.node)).lineLimit(1).truncationMode(.middle)
                                                Spacer()
                                                Text(displaySize(item.allocated, locale: locale)).monospacedDigit()
                                                    .foregroundStyle(Aether.muted)
                                            }
                                            if let reason = item.selectionReason { Text(reason).foregroundStyle(Aether.muted) }
                                        }
                                    }.toggleStyle(.checkbox)
                                }
                            } header: {
                                let total = displaySize(matches.reduce(UInt64(0)) { $0 + $1.allocated }, locale: locale)
                                Text(String(localized: "rebuildable.kind.header", defaultValue: "\(kind.title) · \(total)",
                                            comment: "Header of a group of rebuildable folders: the kind and its total size."))
                            } footer: {
                                Text(kind.restoration).font(.caption).foregroundStyle(Aether.muted)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct CleanupCommandsValue {
    var enabled: Bool
    var findDuplicates: () -> Void
    var findRebuildable: () -> Void
}
private struct CleanupCommandsKey: FocusedValueKey { typealias Value = CleanupCommandsValue }
extension FocusedValues {
    var cleanupCommands: CleanupCommandsValue? {
        get { self[CleanupCommandsKey.self] }
        set { self[CleanupCommandsKey.self] = newValue }
    }
}

struct CleanupCommands: Commands {
    @FocusedValue(\.cleanupCommands) private var actions
    var body: some Commands {
        CommandMenu(String(localized: "cleanup.menu", defaultValue: "Clean Up", comment: "Menu with tools that find space to reclaim.")) {
            Button(String(localized: "cleanup.findDuplicates", defaultValue: "Find Duplicate Files…",
                          comment: "Search the current view for files with identical content.")) { actions?.findDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.enabled != true)
            Button(String(localized: "cleanup.findRebuildable", defaultValue: "Find Rebuildable Folders…",
                          comment: "Search the current view for build output and caches that tools recreate.")) { actions?.findRebuildable() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(actions?.enabled != true)
        }
    }
}

// MARK: - Saved and excluded locations

struct LocationsSettingsView: View {
    @ObservedObject private var locations = LocationSettings.shared
    @State private var confirmingClear = false
    @State private var clearError: String?

    var body: some View {
        Form {
            Section {
                list(locations.saved, remove: locations.removeSaved)
                addButton { locations.addSaved($0) }
            } header: {
                Text(String(localized: "locations.saved.header", defaultValue: "Saved locations",
                            comment: "Settings section listing folders the user scans often."))
            } footer: {
                Text(String(localized: "locations.saved.footer", defaultValue: "Scan these from File → Saved Locations.",
                            comment: "Where saved locations appear.")).font(.footnote).foregroundStyle(Aether.muted)
            }
            Section {
                list(locations.excluded, remove: locations.removeExcluded)
                addButton { locations.addExcluded($0) }
            } header: {
                Text(String(localized: "locations.excluded.header", defaultValue: "Never scan",
                            comment: "Settings section listing folders every scan skips."))
            } footer: {
                Text(String(localized: "locations.excluded.footer",
                            defaultValue: "Scans skip these folders, and the scan report lists them as excluded in Settings. Their space counts as unscanned.",
                            comment: "What excluding a folder does.")).font(.footnote).foregroundStyle(Aether.muted)
            }
            Section {
                Button(String(localized: "history.clear", defaultValue: "Clear Scan History…",
                               comment: "Remove stored scan comparison baselines.")) { confirmingClear = true }
                if let clearError { Text(clearError) }
            }
        }.padding(20)
        .confirmationDialog(String(localized: "history.clear.confirm",
            defaultValue: "Remove all stored scan history? Future scans will start new comparisons.",
             comment: "Confirm permanent removal of scan comparison metadata."),
            isPresented: $confirmingClear) {
            Button(String(localized: "history.clear.action", defaultValue: "Clear Scan History",
                           comment: "Confirm clearing scan history."), role: .destructive) {
                do { try ScanHistoryStore.production?.clear(); clearError = nil }
                catch {
                    clearError = String(localized: "history.clear.failed", defaultValue: "Could not clear scan history. Try again.",
                         comment: "Scan history deletion failed.")
                }
            }
        }
    }

    private func list(_ urls: [URL], remove: @escaping @MainActor (URL) -> Void) -> some View {
        ForEach(urls, id: \.self) { url in
            HStack {
                Text(url.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(String(localized: "locations.remove", defaultValue: "Remove", comment: "Remove a folder from a locations list.")) {
                    remove(url)
                }
            }
        }
    }

    private func addButton(_ add: @escaping @MainActor (URL) -> Void) -> some View {
        Button(String(localized: "locations.add", defaultValue: "Add Folder…", comment: "Add a folder to a locations list.")) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            panel.prompt = String(localized: "locations.add.prompt", defaultValue: "Add", comment: "Folder chooser button for adding a location.")
            if panel.runModal() == .OK {
                for url in panel.urls { add(url) }
            }
        }
    }
}
