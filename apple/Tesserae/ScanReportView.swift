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

/// A pane in the existing window. Nothing is exported until Copy Diagnostics.
struct ScanReportView: View {
    let report: ScanReport
    /// ImageRenderer cannot draw AppKit-backed scroll content. The static form
    /// renders the same report subtree for deterministic reference images.
    var scrolls = true
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scan report").font(.headline)
                Spacer()
                Button("Copy Diagnostics") { copyFailed = !report.copyDiagnostics(to: GeneralDiagnosticsPasteboard()) }
            }
            Text(ScanReport.sharingNote).font(.caption).foregroundStyle(.secondary)
            if copyFailed { Text("The clipboard could not be written. Try Copy Diagnostics again.").foregroundStyle(.red) }
            if scrolls {
                ScrollView([.horizontal, .vertical]) { reportText.textSelection(.enabled) }
            } else {
                reportText
            }
        }.padding(16).frame(minWidth: 400, idealWidth: 520, maxHeight: .infinity, alignment: .topLeading)
    }

    private var reportText: some View {
        Text(report.text).font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct GeneralDiagnosticsPasteboard: DiagnosticsPasteboard {
    func writePlaintext(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
