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
    static let title = String(
        localized: "onboardingView.full.disk.access",
        defaultValue: "Full Disk Access",
        comment: "OnboardingView: Full Disk Access."
    )
    static let purpose = String(
        localized: "onboardingView.tesserae.needs.full.disk.access.to.measure.files",
        defaultValue: "Tesserae needs Full Disk Access to measure files in protected folders and explain where your disk space goes.",
        comment: "OnboardingView: Tesserae needs Full Disk Access to measure files in protected folders and explain where your disk space goes."
    )
    static let privacy = String(
        localized: "onboardingView.no.telemetry.the.only.network.traffic.is.the",
        defaultValue: "No telemetry. The only network traffic is the update check.",
        comment: "OnboardingView: No telemetry. The only network traffic is the update check."
    )
    static let consent = String(
        localized: "onboardingView.without.full.disk.access.scans.can.wait.for",
        defaultValue: "Without Full Disk Access, scans can wait for macOS privacy consent prompts. You can choose a Limited scan instead.",
        comment: "OnboardingView: Without Full Disk Access, scans can wait for macOS privacy consent prompts. You can choose a Limited scan instead."
    )
    static let restart = String(
        localized: "onboardingView.grant.access.then.tesserae.will.restart",
        defaultValue: "Grant access, then Tesserae will restart",
        comment: "OnboardingView: Grant access, then Tesserae will restart."
    )
    static let instructions = String(
        localized: "onboardingView.in.system.settings.enable.tesserae.under.privacy.security",
        defaultValue: "In System Settings, enable Tesserae under Privacy & Security → Full Disk Access, then click Relaunch Tesserae. Access changes apply only after relaunch.",
        comment: "OnboardingView: In System Settings, enable Tesserae under Privacy & Security → Full Disk Access, then click Relaunch Tesserae. Access changes apply only after relaunch."
    )
    static let relaunchTitle = String(
        localized: "onboardingView.full.disk.access.granted.relaunch.to.apply",
        defaultValue: "Full Disk Access granted — relaunch to apply",
        comment: "OnboardingView: Full Disk Access granted — relaunch to apply."
    )
    static let relaunchReason = String(
        localized: "onboardingView.if.you.enabled.access.in.settings.relaunch.to",
        defaultValue: "If you enabled access in Settings, relaunch to apply it. Tesserae cannot confirm the grant in this running process.",
        comment: "OnboardingView: If you enabled access in Settings, relaunch to apply it. Tesserae cannot confirm the grant in this running process."
    )
    static let limited = String(
        localized: "onboardingView.use.limited.scan",
        defaultValue: "Use Limited Scan",
        comment: "OnboardingView: Use Limited Scan."
    )
    static let settings = String(
        localized: "onboardingView.open.settings",
        defaultValue: "Open Settings",
        comment: "OnboardingView: Open Settings."
    )
    static let relaunch = String(
        localized: "onboardingView.relaunch.tesserae",
        defaultValue: "Relaunch Tesserae",
        comment: "OnboardingView: Relaunch Tesserae."
    )
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

struct ScanCommandsValue {
    let startupDiskTitle: String
    let enabled: Bool
    let scanStartupDisk: () -> Void
    let chooseFolder: () -> Void
    let canRescan: Bool
    let rescan: () -> Void
    var showStartScreen: () -> Void = {}
    var rescanEnabled: Bool { enabled && canRescan }
    func rescanIfEnabled() { if rescanEnabled { rescan() } }
}
private struct ScanCommandsKey: FocusedValueKey { typealias Value = ScanCommandsValue }
extension FocusedValues {
    var scanCommands: ScanCommandsValue? {
        get { self[ScanCommandsKey.self] }
        set { self[ScanCommandsKey.self] = newValue }
    }
}
struct ScanCommands: Commands {
    @FocusedValue(\.scanCommands) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "start.anotherLocation", defaultValue: "Scan Another Location…",
                          comment: "Show mounted volumes and the folder chooser without discarding the session.")) { actions?.showStartScreen() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.enabled != true)
            Button(actions?.startupDiskTitle ?? String(
                localized: "onboardingView.scan.macintosh.hd",
                defaultValue: "Scan Macintosh HD",
                comment: "OnboardingView: Scan Macintosh HD."
            )) { actions?.scanStartupDisk() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions?.enabled != true)
            Button(String(
                localized: "onboardingView.rescan",
                defaultValue: "Rescan",
                comment: "OnboardingView: Rescan."
            )) { actions?.rescanIfEnabled() }
                .keyboardShortcut("r")
                .disabled(actions?.rescanEnabled != true)
            Button(String(localized: "start.chooseFolder", defaultValue: "Choose a Folder…",
                          comment: "Open a folder chooser to scan a folder.")) { actions?.chooseFolder() }
                .keyboardShortcut("o")
                .disabled(actions?.enabled != true)
        }
    }
}


enum ColourMenuMode: Int, CaseIterable {
    case folder, age, typeFocus
    var title: String { [String(
        localized: "onboardingView.folder",
        defaultValue: "Folder",
        comment: "Treemap colour mode: group tiles by top-level folder."
    ), String(
        localized: "onboardingView.age",
        defaultValue: "Age",
        comment: "OnboardingView: Age."
    ), String(
        localized: "onboardingView.type.focus",
        defaultValue: "Type focus",
        comment: "OnboardingView: Type focus."
    )][rawValue] }
    var shortcut: KeyEquivalent { ["1", "2", "3"][rawValue] }
}

struct ColourCommandsValue {
    let choice: Binding<Int>
    func selection(for mode: ColourMenuMode) -> Binding<Bool> {
        Binding(get: { choice.wrappedValue == mode.rawValue },
                set: { if $0 { choice.wrappedValue = mode.rawValue } })
    }
}
private struct ColourCommandsKey: FocusedValueKey { typealias Value = ColourCommandsValue }
extension FocusedValues {
    var colourCommands: ColourCommandsValue? {
        get { self[ColourCommandsKey.self] }
        set { self[ColourCommandsKey.self] = newValue }
    }
}

struct ColourCommands: Commands {
    @AppStorage("showFolderNames") private var showFolderNames = true
    @FocusedValue(\.colourCommands) private var actions
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle(String(localized: "view.show.folder.names", defaultValue: "Show Folder Names",
                comment: "View menu toggle for reserved folder name strips."), isOn: $showFolderNames)
            ForEach(ColourMenuMode.allCases, id: \.rawValue) { mode in
                Toggle(mode.title, isOn: actions?.selection(for: mode) ?? .constant(false))
                    .keyboardShortcut(mode.shortcut, modifiers: .command)
                    .disabled(actions == nil)
            }
        }
    }
}
