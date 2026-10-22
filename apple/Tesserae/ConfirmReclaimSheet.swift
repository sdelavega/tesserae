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

struct ConfirmReclaimSheet: View {
    @Binding var confirmation: TrashConfirmation
    var scrolls = true
    var cancel: () -> Void
    var move: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                localized: "confirmReclaimSheet.apply",
                defaultValue: "Apply staged actions?",
                comment: "ConfirmReclaimSheet: Apply staged actions?."
            )).font(.title2.bold())
            Text(ReclaimCopy.staged(confirmation.items.count, locale: locale) + " · " + confirmation.total(locale: locale))
            Text(String(
                localized: "confirmReclaimSheet.warnings",
                defaultValue: "Review every warning. Only checked warning items and items without warnings will proceed.",
                comment: "ConfirmReclaimSheet: Review every warning. Only checked warning items and items without warnings will proceed."
            )).fixedSize(horizontal: false, vertical: true)
            if scrolls { ScrollView { warningRows } } else { warningRows; Spacer(minLength: 0) }
            HStack {
                Text(ReclaimCopy.proceeding(confirmation.movingCount, locale: locale)).foregroundStyle(.secondary)
                Spacer()
                Button(String(
                    localized: "confirmTrashSheet.cancel",
                    defaultValue: "Cancel",
                    comment: "ConfirmReclaimSheet: Cancel."
                ), role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(String(
                    localized: "confirmReclaimSheet.execute",
                    defaultValue: "Apply actions",
                    comment: "ConfirmReclaimSheet: Apply actions."
                ), role: .destructive, action: move).disabled(confirmation.movingCount == 0)
            }
        }.padding(24).frame(width: 620, height: scrolls ? 520 : 780)
    }
    private var warningRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(confirmation.groupedForConfirmation.enumerated()), id: \.offset) { _, group in
                Text(group.0.title).font(.headline)
                ForEach(group.1) { item in
                    if let row = confirmation.warningRows.first(where: { $0.id == item.id }) {
                        warningRow(row)
                    } else {
                        Text(item.displayPath).fixedSize(horizontal: false, vertical: true)
                    }
                    if case .archive(let format) = item.action { Text(format.title).font(.caption) }
                    ForEach(Array((confirmation.notes[item.id] ?? []).enumerated()), id: \.offset) { _, text in
                        Text(text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !confirmation.deniedItems.isEmpty {
                Text(String(
                    localized: "confirmTrashSheet.will.be.skipped",
                    defaultValue: "Will be skipped",
                    comment: "ConfirmReclaimSheet: Will be skipped."
                )).font(.headline)
                ForEach(confirmation.deniedItems) { item in
                    Text(item.displayPath).bold()
                    if case .denied(let reason) = item.verdict { Text(reasonText(reason)) }
                    else if case .unavailable(let reason) = item.actionAvailability { Text(reason) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func warningRow(_ item: WarningRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { confirmation.confirmedWarnings.contains(item.id) },
                set: { confirmation.setConfirmed(item.id, $0) })) {
                Text(item.path).font(.headline).fixedSize(horizontal: false, vertical: true)
            }.toggleStyle(.checkbox)
            ForEach(Array(item.texts.enumerated()), id: \.offset) { _, text in
                Text(text).fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            }
        }.padding(12).background(Color.primary.opacity(0.04)).cornerRadius(8)
    }

}

struct TrashProgressView: View {
    let done: Int
    let total: Int
    var cancellationRequested = false
    var cancel: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(
                localized: "confirmReclaimSheet.progress",
                defaultValue: "Applying actions…",
                comment: "ConfirmReclaimSheet: Applying actions…."
            )).font(.title2.bold())
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(1, max(0, Double(done) / Double(max(1, total)))))
                }
            }.frame(height: 6).accessibilityLabel(String(
                localized: "confirmTrashSheet.batch.progress",
                defaultValue: "Batch progress",
                comment: "ConfirmReclaimSheet: Batch progress."
            )).accessibilityValue(String(
                localized: "confirmTrashSheet.of",
                defaultValue: "\(done) of \(total)",
                comment: "ConfirmReclaimSheet: {done} of {total}."
            ))
            Text(ReclaimCopy.processed(done, total)).monospacedDigit()
            Text(String(
                localized: "confirmTrashSheet.please.wait.for.this.batch.to.finish",
                defaultValue: "Please wait for this batch to finish.",
                comment: "ConfirmReclaimSheet: Please wait for this batch to finish."
            )).foregroundStyle(.secondary)
            Button(String(localized: "reclaim.stopAfterBatch", defaultValue: "Stop after this batch",
                comment: "Request cancellation after the current compression or decompression batch finishes."),
                action: cancel).disabled(cancellationRequested)
        }.padding(24).frame(width: 620, height: 220)
        .interactiveDismissDisabled()
    }
}
