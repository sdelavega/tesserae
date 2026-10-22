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

struct StartView: View {
    @ObservedObject var volumes: VolumeListModel
    let scan: (VolumeInfo) -> Void
    let chooseFolder: () -> Void
    var cancel: (() -> Void)? = nil
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(String(localized: "start.title", defaultValue: "See where your space goes",
                        comment: "Heading above the mounted volumes available to scan.")).font(.largeTitle)
            ScrollView { volumeGroups.padding(.trailing, 8) }
            HStack {
                Button(String(localized: "start.chooseFolder", defaultValue: "Choose a Folder…",
                              comment: "Open a folder chooser to scan a folder."), action: chooseFolder)
                Spacer()
                if let cancel {
                    Button(String(localized: "start.cancel", defaultValue: "Cancel",
                                  comment: "Return to the existing scan session."), action: cancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }.padding(32).frame(maxWidth: 850, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { volumes.start() }
            .onDisappear { volumes.stop() }
    }

    var volumeGroups: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(VolumeGroup.allCases, id: \.rawValue) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(title(group)).font(.headline)
                    ForEach(volumes.volumes.filter { $0.group == group }) { volume in
                        row(volume)
                    }
                    if group == .network {
                        Text(String(localized: "start.network.note", defaultValue: "Network volumes scan more slowly.",
                                    comment: "Explanation below the Network group.")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func title(_ group: VolumeGroup) -> String {
        switch group {
        case .thisMac: return String(localized: "start.thisMac", defaultValue: "This Mac", comment: "Group containing the startup disk.")
        case .otherDisks: return String(localized: "start.otherDisks", defaultValue: "Other disks", comment: "Other local mounted disks.")
        case .network: return String(localized: "start.network", defaultValue: "Network", comment: "Mounted network volumes.")
        }
    }

    private func row(_ volume: VolumeInfo) -> some View {
        HStack(spacing: 14) {
            Image(systemName: volume.group == .network ? "server.rack" : (volume.isStartup ? "internaldrive" : "externaldrive"))
                .font(.title).frame(width: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(volume.name).font(.headline)
                Text(volume.filesystem).foregroundStyle(.secondary)
                Text(sizeText(volume)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "start.scan", defaultValue: "Scan", comment: "Scan this mounted volume.")) { scan(volume) }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle()).onTapGesture(count: 2) { scan(volume) }
    }

    private func sizeText(_ volume: VolumeInfo) -> String {
        guard let total = volume.total, let free = volume.free, total >= 0, free >= 0, free <= total else {
            return String(localized: "start.sizeUnknown", defaultValue: "Size unknown", comment: "Capacity could not be read from this volume.")
        }
        let usedText = displaySize(UInt64(total - free), locale: locale)
        let totalText = displaySize(UInt64(total), locale: locale)
        let freeText = displaySize(UInt64(free), locale: locale)
        return String(localized: "start.capacity", defaultValue: "\(usedText) used of \(totalText) — \(freeText) free",
                      comment: "Used space, total capacity, and free space of a mounted volume.")
    }
}
