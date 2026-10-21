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

struct TrashSummaryView: View {
    let result: ExecutionResult
    var entries: [LogEntry] = []
    var messages: [String: String] = [:]
    var restoring: Set<String> = []
    var canRestore: (LogEntry) -> Bool = { _ in true }
    var restore: (LogEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trash results").font(.title2.bold())
            SummaryLine(result: result)
            Button("Open Trash") { openTrash() }
            ForEach(Array(result.outcomes.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(decoding: pair.0.path, as: UTF8.self)).font(.headline).textSelection(.enabled)
                    Text(outcomeText(pair.1))
                    if case .trashed(let url) = pair.1 {
                        if let entry = entries.first(where: { $0.trashURL == url.absoluteString }) {
                            Button("Put Back") { restore(entry) }.disabled(restoring.contains(entry.trashURL ?? "") || !canRestore(entry))
                                .help(canRestore(entry) ? "Restore this item" : JetsamCopy.putBackWhileScanning)
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
    var body: some View { Text(trashSummaryText(result, locale: locale)).font(.headline) }
}
