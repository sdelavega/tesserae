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

import SwiftUI
import TesseraeKit

struct ReclaimSummaryView: View {
    @ObservedObject private var detail = DetailSettings.shared
    let result: ExecutionResult
    var entries: [LogEntry] = []
    var messages: [String: String] = [:]
    var restoring: Set<String> = []
    var canRestore: (LogEntry) -> Bool = { _ in true }
    var restore: (LogEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(
                localized: "reclaimSummaryView.results",
                defaultValue: "Reclaim results",
                comment: "ReclaimSummaryView: Reclaim results."
            )).font(.title2.bold())
            SummaryLine(result: result)
            if result.hasTrashedItems { Button(String(
                localized: "trashSummaryView.open.trash",
                defaultValue: "Open Trash",
                comment: "ReclaimSummaryView: Open Trash."
            )) { openTrash() } }
            ForEach(Array(result.outcomes.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    Text(pair.0.displayPath).font(.headline).textSelection(.enabled)
                    Text(outcomeText(pair.1, detailLevel: detail.current))
                    if let url = pair.1.trashDestination {
                        if let entry = entries.first(where: { $0.trashURL == url.absoluteString }) {
                            Button(String(
                                localized: "trashSummaryView.put.back",
                                defaultValue: "Put Back",
                                comment: "ReclaimSummaryView: Put Back."
                            )) { restore(entry) }.disabled(restoring.contains(entry.trashURL ?? "") || !canRestore(entry))
                                .help(canRestore(entry) ? String(
                                    localized: "trashSummaryView.restore.this.item",
                                    defaultValue: "Restore this item",
                                    comment: "ReclaimSummaryView: Restore this item."
                                ) : ReclaimCopy.putBackWhileScanning)
                        }
                        if let message = messages[url.absoluteString] { Text(message).foregroundStyle(.secondary) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04)).cornerRadius(8)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SummaryLine: View {
    let result: ExecutionResult
    @Environment(\.locale) private var locale
    var body: some View {
        if let text = result.summary(locale: locale) { Text(text).font(.headline) }
    }
}
