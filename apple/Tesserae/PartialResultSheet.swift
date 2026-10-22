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
import TesseraeFFI
import TesseraeKit

@MainActor
final class PartialResultPresentation: ObservableObject {
    @Published var showingExplanation = false
    func explain() { showingExplanation = true }
    func done() { showingExplanation = false }
    func showReport(_ open: () -> Void) {
        showingExplanation = false
        open()
    }
}

struct PartialResultSheet: View {
    @ObservedObject private var detail = DetailSettings.shared
    let stats: TessScanStats
    let report: ScanReport
    let showReport: () -> Void
    let done: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "partial.title", defaultValue: "What wasn't scanned?",
                comment: "Title of the partial scan explanation sheet.")).font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(PartialResultExplanation(stats: stats, report: report, detail: detail.current,
                        locale: locale).enumerated()), id: \.offset) { _, line in
                        Text(line.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.textSelection(.enabled)
            }
            HStack {
                Button(String(localized: "partial.showReport", defaultValue: "Show Scan Report",
                    comment: "Open the full scan report pane from the explanation sheet."), action: showReport)
                Spacer()
                Button(String(localized: "partial.done", defaultValue: "Done",
                    comment: "Close the partial scan explanation sheet."), action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 480)
    }
}
