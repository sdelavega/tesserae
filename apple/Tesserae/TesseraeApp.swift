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

@main
struct TesseraeApp: App {
    @StateObject private var updates: Updates
    #if TESSERAE_TEST_HOOKS
    private let accessReport: AccessReportConfiguration?

    #endif

    init() {
        #if TESSERAE_TEST_HOOKS
        do {
            accessReport = try AccessReportConfiguration(environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("tesserae access report: \(error)\n".utf8))
            exit(2)
        }
        let startUpdates = accessReport == nil && !FrameTimer.shared.isEnabled
        _updates = StateObject(wrappedValue: Updates(startingUpdater: startUpdates))
        if let configuration = accessReport {
            Task {
                do {
                    let status = try await AccessReportRunner.run(configuration)
                    exit(status)
                } catch {
                    FileHandle.standardError.write(Data("tesserae access report: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
        // A mistyped frame-gate variable must not silently launch an ordinary session.
        if case .failure(let problem) = FrameGateConfiguration.current {
            FileHandle.standardError.write(Data("tesserae frame gate: \(problem)\n".utf8))
            exit(2)
        }
        #else
        _updates = StateObject(wrappedValue: Updates(startingUpdater: true))
        #endif
    }

    var body: some Scene {
        Window(String(
            localized: "tesseraeApp.tesserae",
            defaultValue: "Tesserae",
            comment: "TesseraeApp: Tesserae."
        ), id: "main") {
            #if TESSERAE_TEST_HOOKS
            if accessReport != nil {
                ProgressView(String(
                    localized: "tesseraeApp.writing.access.report",
                    defaultValue: "Writing access report…",
                    comment: "TesseraeApp: Writing access report…."
                )).padding()
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands {
            ReclaimCommands()
            ScanCommands()
            ColourCommands()
            CommandGroup(replacing: .appInfo) {
                Button(String(
                    localized: "tesseraeApp.about.tesserae",
                    defaultValue: "About Tesserae",
                    comment: "TesseraeApp: About Tesserae."
                )) { AppChrome.showAbout() }
                Button(String(
                    localized: "tesseraeApp.check.for.updates",
                    defaultValue: "Check for Updates…",
                    comment: "TesseraeApp: Check for Updates…."
                )) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(after: .help) {
                Button(String(
                    localized: "tesseraeApp.support.tesserae",
                    defaultValue: "Support Tesserae…",
                    comment: "TesseraeApp: Support Tesserae…."
                )) { AppChrome.openSupport() }
            }
        }
        #if DEBUG
        .commands {
            CommandMenu("Diagnostics") {
                #if TESSERAE_TEST_HOOKS
                // Needs TESSERAE_FRAME_TIMING=1 (the runner exists only then).
                Button("Run Phase 2 Frame Gate") {
                    NotificationCenter.default.post(name: .init("TesseraeRunFrameGate"), object: nil)
                }.disabled(!FrameTimer.shared.isEnabled)
                Divider()
                #endif
                Button("Use Light Appearance") { NSApp.appearance = NSAppearance(named: .aqua) }
                Button("Use Dark Appearance") { NSApp.appearance = NSAppearance(named: .darkAqua) }
                Button("Follow System Appearance") { NSApp.appearance = nil }
            }
        }
        #endif
        Settings {
            TabView {
                GeneralSettingsView().tabItem { Text(String(localized: "detail.general", defaultValue: "General",
                    comment: "General settings tab.")) }
                UpdateSettingsView(updates: updates).tabItem { Text(String(localized: "detail.updates", defaultValue: "Updates",
                    comment: "Automatic updates settings tab.")) }
            }.frame(width: 480, height: 210)
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject private var detail = DetailSettings.shared
    var body: some View {
        Form {
            Picker(String(localized: "detail.label", defaultValue: "Detail", comment: "Presentation detail setting."), selection: $detail.current) {
                Text(String(localized: "detail.simple", defaultValue: "Simple", comment: "Plain presentation option.")).tag(DetailLevel.simple)
                Text(String(localized: "detail.detailed", defaultValue: "Detailed", comment: "Full technical presentation option.")).tag(DetailLevel.detailed)
            }.pickerStyle(.segmented)
            Text(String(localized: "detail.explanation", defaultValue: "Simple uses plain summaries; Detailed shows all technical information.",
                comment: "One-line explanation of the presentation setting.")).font(.footnote).foregroundStyle(.secondary)
        }.padding(24)
    }
}
