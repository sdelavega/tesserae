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

/// The sheet's displayed copy, available without launching privacy probes.
struct OnboardingViewModel {
    static let title = "Full Disk Access"
    static let purpose = "Tesserae needs Full Disk Access to measure files in protected folders and explain where your disk space goes."
    static let privacy = "Tesserae makes no network connections and collects no telemetry."
    static let consent = "Without Full Disk Access, scans can wait for macOS privacy consent prompts. You can choose a Limited scan instead."
    static let restart = "Grant access, then Tesserae will restart"
    static let instructions = "In System Settings, enable Tesserae under Privacy & Security → Full Disk Access, then click Relaunch Tesserae. Access changes apply only after relaunch."
    static let relaunchTitle = "Full Disk Access granted — relaunch to apply"
    static let relaunchReason = "If you enabled access in Settings, relaunch to apply it. Tesserae cannot confirm the grant in this running process."
    static let limited = "Use Limited Scan"
    static let settings = "Open Settings"
    static let relaunch = "Relaunch Tesserae"
    let relaunchRequired: Bool
    var text: String {
        ([Self.title, Self.purpose, Self.privacy, Self.consent, Self.restart, Self.instructions,
          Self.limited, Self.settings, Self.relaunch]
         + (relaunchRequired ? [Self.relaunchTitle, Self.relaunchReason] : [])).joined(separator: "\n")
    }
}

struct OnboardingView: View {
    let state: Onboarding
    let send: (Onboarding.Event) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(OnboardingViewModel.title, systemImage: "lock.shield").font(.title2)
            Text(OnboardingViewModel.purpose)
            Text(OnboardingViewModel.privacy)
                .foregroundStyle(.secondary)
            Text(OnboardingViewModel.consent)
            Text(OnboardingViewModel.restart).font(.headline)
            Text(OnboardingViewModel.instructions)
            if state.needsRelaunch {
                Text(OnboardingViewModel.relaunchTitle).font(.headline)
                Text(OnboardingViewModel.relaunchReason)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            HStack {
                Button(OnboardingViewModel.limited) { send(.useLimited) }
                Spacer()
                Button(OnboardingViewModel.settings) { send(.openSettings) }
                Button(OnboardingViewModel.relaunch) { send(.relaunch) }.buttonStyle(.borderedProminent)
            }.disabled(state.isRelaunching)
        }.padding(24).frame(width: 560)
        .interactiveDismissDisabled()
    }
}
