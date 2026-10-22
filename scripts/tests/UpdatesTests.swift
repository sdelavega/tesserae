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


import Foundation

@MainActor
private final class FakeUpdater: UpdateChecking {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = false
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

@main
struct UpdatesTests {
    @MainActor
    static func main() {
        let fake = FakeUpdater()
        let updates = Updates(updater: fake)
        precondition(fake.automaticallyChecksForUpdates)
        precondition(updates.automaticallyChecksForUpdates)
        updates.automaticallyChecksForUpdates = false
        precondition(!fake.automaticallyChecksForUpdates)
        precondition(!updates.automaticallyChecksForUpdates)
        updates.automaticallyChecksForUpdates = true
        precondition(fake.automaticallyChecksForUpdates)
        fake.automaticallyChecksForUpdates = false
        precondition(!updates.automaticallyChecksForUpdates, "read the updater, not a cached preference")
        precondition(!updates.canCheckForUpdates)
        updates.checkForUpdates()
        precondition(fake.checks == 0)
        fake.canCheckForUpdates = true
        precondition(updates.canCheckForUpdates)
        updates.checkForUpdates()
        precondition(fake.checks == 1)
        fake.canCheckForUpdates = false
        precondition(!updates.canCheckForUpdates)
        print("Updater seam: toggle round-trip, external preference changes, menu availability and action passed")
    }
}
