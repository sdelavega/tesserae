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

struct ConfirmTrashSheet: View {
    @Binding var confirmation: TrashConfirmation
    var scrolls = true
    var cancel: () -> Void
    var move: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move staged items to Trash?").font(.title2.bold())
            Text(JetsamCopy.staged(confirmation.items.count) + " · " + confirmation.total(locale: locale))
            Text("Review every warning. Only checked warning items and items without warnings will move.")
            if scrolls { ScrollView { warningRows } } else { warningRows; Spacer(minLength: 0) }
            HStack {
                Text(JetsamCopy.moving(confirmation.movingCount)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive, action: move).disabled(confirmation.movingCount == 0)
            }
        }.padding(24).frame(width: 620, height: 520)
    }
    private var warningRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(confirmation.warningRows) { item in
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
            if !confirmation.deniedItems.isEmpty {
                Text("Will be skipped").font(.headline)
                ForEach(confirmation.deniedItems) { item in
                    Text(String(decoding: item.path, as: UTF8.self)).bold()
                    if case .denied(let reason) = item.verdict { Text(reasonText(reason)) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct TrashProgressView: View {
    let done: Int
    let total: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Moving to Trash…").font(.title2.bold())
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(1, max(0, Double(done) / Double(max(1, total)))))
                }
            }.frame(height: 6).accessibilityLabel("Batch progress").accessibilityValue("\(done) of \(total)")
            Text(JetsamCopy.processed(done, total)).monospacedDigit()
            Text("Please wait for this batch to finish.").foregroundStyle(.secondary)
        }.padding(24).frame(width: 620, height: 180)
        .interactiveDismissDisabled()
    }
}
