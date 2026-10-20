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

public struct ReconciliationView: View {
    public let model: ReconciliationViewModel
    public var grantAccess: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    public init(model: ReconciliationViewModel, grantAccess: (() -> Void)? = nil) {
        self.model = model
        self.grantAccess = grantAccess
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = model.scopeMessage {
                Text(message).font(.caption).opacity(0.65)
            } else {
                Text(model.title).font(.headline)
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.title)
                            Spacer(minLength: 2)
                            Text(row.value).monospacedDigit()
                        }.font(.callout)
                        if let fraction = row.fraction {
                            GeometryReader { geometry in
                                // One scale for every row keeps clone over-counts proportional,
                                // even when a summand exceeds capacity. The faint track is capacity.
                                let scale = max(1, model.rows.compactMap(\.fraction).max() ?? 1)
                                let capacityWidth = geometry.size.width / scale
                                Rectangle().fill(Color.accentColor.opacity(0.1))
                                    .frame(width: capacityWidth)
                                    .overlay(alignment: .leading) {
                                        if row.negative {
                                            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                                .frame(width: capacityWidth * fraction)
                                        } else {
                                            Rectangle().fill(Color.accentColor.opacity(0.7))
                                                .frame(width: capacityWidth * fraction)
                                        }
                                    }
                            }.frame(height: 5)
                        }
                        if let detail = row.detail { Text(detail).font(.caption).opacity(0.7) }
                        if let annotation = row.annotation {
                            Text(annotation).font(.caption).opacity(0.7).padding(.leading, 8)
                        }
                    }
                }
                if let text = model.purgeable { Text(text).font(.caption).opacity(0.7) }
                if let text = model.warning {
                    Label(text, systemImage: "exclamationmark.triangle").font(.caption)
                }
                ForEach(Array(model.breakdownCaveats.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.caption).opacity(0.7)
                }
                if model.showGrantAccess {
                    Button(model.grantAccessTitle) {
                        if let grantAccess { grantAccess() }
                        else { NSWorkspace.shared.open(FullDiskAccessSettings.url) }
                    }.font(.caption)
                }
            }
        }.foregroundColor(LabelStyle.inkColour(dark: scheme == .dark))
    }
}
