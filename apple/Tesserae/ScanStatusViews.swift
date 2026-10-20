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

struct LimitedAccessViewModel {
    static let title = "Limited scan selected"
    static let reopen = "Review Full Disk Access"
    static var text: String { title + "\n" + reopen }
}

struct ScanFailureViewModel {
    let errno: Int32
    let title = "Couldn’t scan this folder"
    let copyTitle = "Copy Diagnostics"
    var reason: String { errno == EINVAL ? "Couldn’t start the scan" : String(cString: strerror(errno)) }
    var diagnostics: String { "Tesserae scan failed\nerrno: \(errno)\n" + String(cString: strerror(errno)) }
    var text: String { title + "\n" + reason + "\n" + copyTitle }
}

struct LimitedAccessView: View {
    let reopen: () -> Void
    var body: some View {
        HStack {
            Text(LimitedAccessViewModel.title).font(.caption)
            Spacer()
            Button(LimitedAccessViewModel.reopen, action: reopen)
        }.padding(10)
    }
}

struct ScanWarningView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.16))
    }
}

struct ScanFailureView: View {
    let errno: Int32
    let chooseFolder: () -> Void
    @State private var copyFailed = false
    private var model: ScanFailureViewModel { ScanFailureViewModel(errno: errno) }
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(model.title).font(.title2)
            Text(model.reason).foregroundStyle(.secondary)
            Button(model.copyTitle) {
                NSPasteboard.general.clearContents()
                copyFailed = !NSPasteboard.general.setString(model.diagnostics, forType: .string)
            }
            if copyFailed { Text("The clipboard could not be written. Try Copy Diagnostics again.").foregroundStyle(.red) }
            Button("Choose another folder…", action: chooseFolder)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FolderBadge {
    let symbol: String
    let label: String

    init(snapshot: Snapshot, node: UInt32) {
        let cloud = snapshot.isDataless(node)
        symbol = cloud ? "icloud" : "lock.fill"
        label = cloud ? "Cloud-only folder" : "Unreadable folder"
    }
}
