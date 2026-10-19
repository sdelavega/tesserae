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

/// Placeholder window until the treemap lands: shows that the app links the
/// engine by reporting its ABI version.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Tesserae")
                .font(.largeTitle)
            Text("Engine ABI \(TesseraeKit.abiVersion)")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}
