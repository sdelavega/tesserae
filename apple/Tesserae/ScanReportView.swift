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
    var layout: ScanReportLayout? = nil
    @State private var copyFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(
                    localized: "scanReportView.scan.report",
                    defaultValue: "Scan report",
                    comment: "ScanReportView: Scan report."
                )).font(.headline)
                Button(String(
                    localized: "scanReportView.copy.diagnostics",
                    defaultValue: "Copy Diagnostics",
                    comment: "ScanReportView: Copy Diagnostics."
                )) { copyFailed = !report.copyDiagnostics(to: GeneralDiagnosticsPasteboard()) }
                    .background { if let layout { CopyDiagnosticsBounds(layout: layout) } }
            }
            Text(ScanReport.sharingNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if copyFailed { Text(String(
                localized: "scanReportView.the.clipboard.could.not.be.written.try.copy",
                defaultValue: "The clipboard could not be written. Try Copy Diagnostics again.",
                comment: "ScanReportView: The clipboard could not be written. Try Copy Diagnostics again."
            )).foregroundStyle(.red) }
            if scrolls {
                ScrollView(.vertical) { reportText.textSelection(.enabled) }
            } else {
                reportText
            }
        }
        .padding(16).frame(minWidth: 300, idealWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
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

/// The report control's laid-out bounds, in the window content's coordinate space.
/// Used to check fit alongside the native file table's viewport bounds.
final class ScanReportLayout {
    var copyDiagnosticsFrame = CGRect.zero
}
private struct CopyDiagnosticsBounds: NSViewRepresentable {
    let layout: ScanReportLayout
    func makeNSView(context: Context) -> BoundsView { BoundsView() }
    func updateNSView(_ view: BoundsView, context: Context) {
        view.reportLayout = layout
        view.needsLayout = true
    }

    final class BoundsView: NSView {
        var reportLayout: ScanReportLayout?
        override func layout() {
            super.layout()
            if let content = window?.contentView {
                reportLayout?.copyDiagnosticsFrame = content.convert(bounds, from: self)
            }
        }
    }
}
