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

import XCTest
import SwiftUI
@testable import TesseraeKit

final class OnboardingTests: XCTestCase {
    @MainActor
    func test_colour_menu_shares_toolbar_state_and_keeps_one_checkmark() async {
        let app = AppModel(coordinator: ScanCoordinator(factory: { _, _ in nil }), accessLoader: { .unknown })
        await app.waitForAccess()
        let commands = ColourCommandsValue(choice: Binding(get: { app.colourChoice }, set: { app.colourChoice = $0 }))
        XCTAssertEqual(ColourMenuMode.allCases.map(\.title), ["Folder", "Age", "Type focus"])
        XCTAssertEqual(ColourMenuMode.allCases.map { $0.shortcut.character }, ["1", "2", "3"])
        XCTAssertEqual(app.colourChoice, 0)
        for mode in ColourMenuMode.allCases {
            commands.selection(for: mode).wrappedValue = true
            XCTAssertEqual(app.colourChoice, mode.rawValue, "menu updates the toolbar's model")
            XCTAssertEqual(ColourMenuMode.allCases.filter { commands.selection(for: $0).wrappedValue }, [mode])
            commands.selection(for: mode).wrappedValue = false
            XCTAssertEqual(app.colourChoice, mode.rawValue, "cannot turn off the current colour mode")
        }
        app.colourChoice = 1
        XCTAssertTrue(commands.selection(for: .age).wrappedValue, "toolbar updates menu checkmark")
        XCTAssertFalse(commands.selection(for: .typeFocus).wrappedValue)
    }

    func test_rescan_command_requires_model_availability_and_enabled_scene() {
        for enabled in [false, true] {
            for canRescan in [false, true] {
                var calls = 0
                let commands = ScanCommandsValue(startupDiskTitle: "Scan disk", enabled: enabled,
                    scanStartupDisk: {}, chooseFolder: {}, canRescan: canRescan, rescan: { calls += 1 })
                XCTAssertEqual(commands.rescanEnabled, enabled && canRescan)
                commands.rescanIfEnabled()
                XCTAssertEqual(calls, enabled && canRescan ? 1 : 0)
            }
        }
    }

    let states: [AccessState] = [.granted, .denied(evidence: "EPERM"), .unknown]

    @MainActor
    func test_startup_disk_picker_mapping_reaches_existing_scan_factory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tesserae-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("Boot Volume")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/"))
        XCTAssertEqual(alias.resolvingSymlinksInPath().path, "/", "precondition: boot-volume alias resolves to root")
        for selected in [URL(fileURLWithPath: "/"), alias, URL(fileURLWithPath: "/System/Volumes/Data"), URL(fileURLWithPath: "/fixture/subfolder")] {
            let name = "Tesserae.StartupDiskTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let probe = StartupScanProbe()
            let coordinator = ScanCoordinator(factory: { root, _ in probe.record(root); return nil })
            let app = AppModel(coordinator: coordinator, accessLoader: { .unknown }, onboardingStore: OnboardingStore(defaults: defaults))
            app.scan(selected)
            await app.waitForAccess()
            XCTAssertNil(probe.root, "precondition: onboarding gates the scan")
            app.sendOnboarding(.useLimited)
            for _ in 0..<1000 {
                if probe.root != nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let expected = selected.path == "/fixture/subfolder" ? selected.path : "/System/Volumes/Data"
            XCTAssertEqual(probe.root?.path, expected, selected.path)
            app.cancel()
        }
    }

    @MainActor
    func test_primary_startup_disk_action_uses_data_root_and_localized_window_title() async throws {
        let name = "Tesserae.PrimaryStartupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let probe = StartupScanProbe()
        let coordinator = ScanCoordinator(factory: { root, _ in probe.record(root); return nil })
        let app = AppModel(coordinator: coordinator, accessLoader: { .granted },
            onboardingStore: OnboardingStore(defaults: defaults), startupDiskName: "Studio SSD",
            contextLoader: { _ in nil }, factsLoader: { _, scan in
                ReconciliationViewModel(wholeVolume: true, reconciliation: nil, scan: scan,
                    locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
            })
        app.refreshAccess()
        await app.waitForAccess()
        XCTAssertTrue(app.onboarding.canScan, "precondition: no privacy gate remains")
        XCTAssertEqual(app.windowTitle, "Tesserae")
        XCTAssertEqual(app.startupDiskScanTitle, "Scan Studio SSD")
        app.scanStartupDisk()
        for _ in 0..<1000 {
            if probe.root != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(probe.root?.path, "/System/Volumes/Data")
        app.cancel()
        let tree = TestSnapshot(.dir("/System/Volumes/Data", [.dir("Users", [.file("file", 5)])]))
        app.prepareSnapshot(tree.snapshot)
        await app.waitForFacts()
        let session = try XCTUnwrap(app.session)
        XCTAssertEqual(app.windowTitle, "Studio SSD")
        XCTAssertEqual(session.navigator.breadcrumbItems.map(\.title), ["Studio SSD"])
        session.navigator.descend(into: tree["Users"])
        XCTAssertEqual(session.navigator.breadcrumbItems.map(\.title), ["Studio SSD", "Users"])
        XCTAssertEqual(tree.snapshot.rawPath(tree.snapshot.root), Data("/System/Volumes/Data".utf8))
    }

    @MainActor
    func test_startup_disk_breadcrumb_uses_boot_volume_localized_name() throws {
        var requested: URL?
        let renamed = StartupDisk.loadDisplayName { url in requested = url; return "Studio SSD" }
        XCTAssertEqual(requested?.path, "/", "query the boot volume rather than the Data volume")
        XCTAssertEqual(renamed, "Studio SSD")
        XCTAssertEqual(StartupDisk.loadDisplayName { _ in nil }, "Macintosh HD")
        let boot = URL(fileURLWithPath: "/")
        let name = try XCTUnwrap(boot.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
        XCTAssertFalse(name.isEmpty, "precondition: boot volume supplies a localized name")
        let tree = TestSnapshot(.dir("/System/Volumes/Data", [.dir("Users", [.file("file", 5)])]))
        let navigator = Navigator(snapshot: tree.snapshot)
        XCTAssertEqual(tree.snapshot.rawPath(tree.snapshot.root), Data("/System/Volumes/Data".utf8))
        XCTAssertEqual(navigator.breadcrumbItems.map(\.title), [name])
        navigator.descend(into: tree["Users"])
        XCTAssertEqual(navigator.breadcrumbItems.map(\.title), [name, "Users"])
        let folder = TestSnapshot(.dir("/fixture", [.file("file", 5)]))
        XCTAssertEqual(Navigator(snapshot: folder.snapshot).breadcrumbItems.map(\.title), ["/fixture"])
    }

    func test_access_choice_activation_matrix() {
        for access in states {
            for choice in [Onboarding.Choice.none, .limited] {
                for activated in states {
                    var state = Onboarding(access: access, choice: choice)
                    XCTAssertFalse(state.isPresented)
                    XCTAssertEqual(state.scanMode, access == .granted ? .full : .limited)
                    XCTAssertFalse(state.canScan)
                    XCTAssertNil(state.send(.activated(activated)))
                    XCTAssertEqual(state.isPresented, activated != .granted && choice == .none)
                    XCTAssertEqual(state.showsLimitedAffordance, activated != .granted && choice == .limited)
                    XCTAssertEqual(state.send(.openSettings), .openSettings)
                    XCTAssertNil(state.send(.activated(activated)))
                    XCTAssertEqual(state.isPresented, activated != .granted)
                    XCTAssertEqual(state.needsRelaunch, activated != .granted)
                    XCTAssertNil(state.send(.activated(.granted)))
                    XCTAssertFalse(state.isPresented)
                    XCTAssertFalse(state.needsRelaunch)
                    XCTAssertTrue(state.canScan)
                    XCTAssertEqual(state.scanMode, .full)
                }
            }
        }
    }

    func test_limited_dismisses_until_explicitly_reopened() {
        var state = Onboarding(access: .unknown)
        XCTAssertNil(state.send(.activated(.unknown)))
        XCTAssertTrue(state.isPresented, "precondition")
        XCTAssertNil(state.send(.useLimited))
        XCTAssertEqual(state.choice, .limited)
        XCTAssertFalse(state.isPresented)
        XCTAssertTrue(state.canScan)
        XCTAssertTrue(state.showsLimitedAffordance)
        XCTAssertNil(state.send(.activated(.denied(evidence: "EPERM"))))
        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.send(.reopen))
        XCTAssertTrue(state.isPresented)
        XCTAssertNil(state.send(.useLimited))
        XCTAssertFalse(state.isPresented)
    }

    func test_relaunch_is_one_command_per_tap_never_from_activation() {
        var state = Onboarding(access: .unknown)
        XCTAssertEqual(state.send(.openSettings), .openSettings)
        XCTAssertNil(state.send(.activated(.unknown)))
        XCTAssertTrue(state.needsRelaunch, "precondition: returned from Settings")
        XCTAssertEqual(state.send(.relaunch), .relaunch)
        XCTAssertTrue(state.isRelaunching)
        XCTAssertNil(state.send(.activated(.unknown)))
        XCTAssertNil(state.send(.relaunch), "coalesce taps while launch is pending")
        XCTAssertNil(state.send(.relaunchFailed("Launch failed")))
        XCTAssertEqual(state.error, "Launch failed")
        XCTAssertFalse(state.isRelaunching)
        XCTAssertEqual(state.send(.relaunch), .relaunch, "a fresh tap can retry")
        XCTAssertNil(state.error)
    }

    func test_limited_choice_round_trips_through_injected_defaults() throws {
        let name = "Tesserae.OnboardingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(defaults.object(forKey: OnboardingStore.key), "precondition: isolated store")
        let store = OnboardingStore(defaults: defaults)
        XCTAssertEqual(store.choice, .none)
        store.choice = .limited
        XCTAssertEqual(OnboardingStore(defaults: defaults).choice, .limited)
        defaults.set("invalid", forKey: OnboardingStore.key)
        XCTAssertEqual(store.choice, .none, "unknown stored values must require onboarding")
    }
    @MainActor
    func test_scan_waits_for_choice_and_persists_limited_without_granting_access() async throws {
        let name = "Tesserae.ScanGateTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OnboardingStore(defaults: defaults)
        let coordinator = ScanCoordinator(factory: { _, _ in nil })
        let app = AppModel(coordinator: coordinator, accessLoader: { .unknown }, onboardingStore: store)
        app.scan(URL(fileURLWithPath: "/fixture"))
        await app.waitForAccess()
        XCTAssertEqual(coordinator.state, .idle, "must not even invoke the engine before a choice")
        XCTAssertTrue(app.onboarding.isPresented)
        app.sendOnboarding(.useLimited)
        XCTAssertEqual(app.scanMode, .limited)
        XCTAssertEqual(app.onboarding.access, .unknown)
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertEqual(store.choice, .limited)
        XCTAssertTrue(app.isScanning, "pending request is queued for the operation permit")
        for _ in 0..<1000 {
            if coordinator.state != .idle { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotEqual(coordinator.state, .idle, "pending request starts once a choice is made")
        let relaunched = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown }, onboardingStore: store)
        await relaunched.waitForAccess()
        XCTAssertFalse(relaunched.onboarding.isPresented)
        XCTAssertEqual(relaunched.scanMode, .limited)
    }

    @MainActor
    func test_model_relaunch_waits_for_success_and_keeps_running_on_failure() async throws {
        let name = "Tesserae.RelaunchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var opens = 0, terminations = 0
        var completion: CheckedContinuation<Void, Error>?
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown },
            onboardingStore: OnboardingStore(defaults: defaults), relaunch: {
                opens += 1
                try await withCheckedThrowingContinuation { completion = $0 }
            }, terminate: { terminations += 1 })
        await app.waitForAccess()
        app.sendOnboarding(.relaunch)
        for _ in 0..<1000 {
            if !(completion == nil) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(opens, 1, "precondition: launch pending")
        XCTAssertEqual(terminations, 0, "never terminate before success")
        app.sendOnboarding(.relaunch)
        XCTAssertTrue(app.onboarding.isRelaunching)
        completion?.resume(throwing: NSError(domain: "fixture", code: 1))
        completion = nil
        for _ in 0..<1000 {
            if !(app.onboarding.isRelaunching) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(terminations, 0)
        XCTAssertTrue(try XCTUnwrap(app.onboarding.error).contains("Couldn’t relaunch Tesserae"))
        XCTAssertTrue(app.onboarding.isPresented)
        app.sendOnboarding(.relaunch)
        for _ in 0..<1000 {
            if !(completion == nil) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(opens, 2, "one new open for retry tap")
        completion?.resume()
        for _ in 0..<1000 {
            if !(terminations == 0) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(terminations, 1)
        XCTAssertNil(app.onboarding.error)
    }

    @MainActor
    func test_model_settings_uses_activation_reprobe_and_dismisses_when_granted() async throws {
        let name = "Tesserae.SettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var opens = 0
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown },
            onboardingStore: OnboardingStore(defaults: defaults), openSettings: { opens += 1; return true })
        await app.waitForAccess()
        XCTAssertFalse(app.onboarding.needsRelaunch)
        app.sendOnboarding(.openSettings)
        XCTAssertEqual(opens, 1)
        app.refreshAccess()
        await app.waitForAccess()
        XCTAssertTrue(app.onboarding.needsRelaunch)
        app.sendOnboarding(.activated(.granted))
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertEqual(app.scanMode, .full)
        XCTAssertEqual(FullDiskAccessSettings.url.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func test_settings_failure_reports_error_without_claiming_a_settings_visit() {
        var state = Onboarding(access: .unknown)
        XCTAssertEqual(state.send(.openSettings), .openSettings)
        XCTAssertNil(state.send(.settingsFailed("Settings unavailable")))
        XCTAssertEqual(state.error, "Settings unavailable")
        XCTAssertNil(state.send(.activated(.unknown)))
        XCTAssertFalse(state.needsRelaunch)
        XCTAssertTrue(state.isPresented)
    }

    func test_first_probe_gates_presentation_and_scan() {
        for choice in [Onboarding.Choice.none, .limited] {
            var state = Onboarding(choice: choice)
            XCTAssertFalse(state.isPresented)
            XCTAssertFalse(state.canScan)
            state.send(.activated(.granted))
            XCTAssertFalse(state.isPresented)
            XCTAssertTrue(state.canScan)
        }
        var state = Onboarding()
        state.send(.activated(.unknown))
        XCTAssertTrue(state.isPresented)
    }

    @MainActor
    func test_sheet_dismissal_reestablishes_required_presentation() async throws {
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown })
        await app.waitForAccess()
        app.sendOnboarding(.reopen)
        XCTAssertTrue(app.onboardingPresented, "precondition")
        app.setOnboardingPresented(false)
        for _ in 0..<100 {
            if app.onboardingPresented { break }
            await Task.yield()
        }
        XCTAssertTrue(app.onboarding.isPresented)
        XCTAssertTrue(app.onboardingPresented)
    }

    @MainActor
    func test_limited_or_sheet_dismissal_cancels_pending_relaunch() async throws {
        for limited in [true, false] {
            var completion: CheckedContinuation<Void, Error>?
            var terminations = 0
            let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown },
                relaunch: { try await withCheckedThrowingContinuation { completion = $0 } },
                terminate: { terminations += 1 })
            await app.waitForAccess()
            app.sendOnboarding(.reopen)
            app.sendOnboarding(.relaunch)
            for _ in 0..<1000 {
                if completion != nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            let pending = try XCTUnwrap(completion, "precondition: launch awaiting success")
            XCTAssertTrue(app.onboarding.isRelaunching)
            if limited { app.sendOnboarding(.useLimited) }
            else { app.setOnboardingPresented(false) }
            XCTAssertFalse(app.onboarding.isRelaunching)
            pending.resume()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(terminations, 0)
        }
    }

    @MainActor
    func test_granted_during_pending_relaunch_still_terminates_after_success() async throws {
        var completion: CheckedContinuation<Void, Error>?
        var terminations = 0
        let app = AppModel(coordinator: ScanCoordinator(), accessLoader: { .unknown },
            relaunch: { try await withCheckedThrowingContinuation { completion = $0 } },
            terminate: { terminations += 1 })
        await app.waitForAccess()
        app.sendOnboarding(.relaunch)
        for _ in 0..<1000 {
            if completion != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let pending = try XCTUnwrap(completion, "precondition: launch awaiting success")
        XCTAssertTrue(app.onboarding.isRelaunching)
        app.sendOnboarding(.activated(.granted))
        XCTAssertEqual(app.onboarding.access, .granted)
        XCTAssertFalse(app.onboarding.isPresented)
        XCTAssertTrue(app.onboarding.isRelaunching)
        XCTAssertEqual(terminations, 0)
        pending.resume()
        for _ in 0..<1000 {
            if terminations != 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(terminations, 1)
    }

}

private final class StartupScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRoot: URL?
    var root: URL? { lock.lock(); defer { lock.unlock() }; return recordedRoot }
    func record(_ root: URL) { lock.lock(); recordedRoot = root; lock.unlock() }
}
