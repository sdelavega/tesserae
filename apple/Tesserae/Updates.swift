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


import Sparkle
import SwiftUI

@MainActor
protocol UpdateChecking: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

extension SPUUpdater: UpdateChecking {}

@MainActor
final class Updates: ObservableObject {
    private let updater: any UpdateChecking
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    init(updater: any UpdateChecking) {
        self.updater = updater
    }

    convenience init(startingUpdater: Bool) {
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        self.init(updater: controller.updater)
        self.controller = controller
        observations = [
            controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        ]
        if startingUpdater { controller.startUpdater() }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: Updates

    var body: some View {
        Form {
            Toggle(String(
                localized: "updates.check.for.updates.automatically",
                defaultValue: "Check for updates automatically",
                comment: "Updates: Check for updates automatically."
            ), isOn: $updates.automaticallyChecksForUpdates)
            Text(AppChrome.updateDisclosure).font(.footnote).foregroundStyle(.secondary)
        }.padding(24).frame(width: 440)
    }
}
