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

public enum ScanMode: Equatable, Sendable { case full, limited }

/// Pure permission flow. Commands are returned only by the tap that caused them.
public struct Onboarding: Equatable, Sendable {
    public enum Choice: String, Sendable { case none, limited }
    public enum Command: Equatable, Sendable { case openSettings, relaunch }
    public enum Event: Sendable {
        case activated(AccessState), openSettings, useLimited, reopen, relaunch, dismissed
        case relaunchFailed(String), settingsFailed(String)
    }

    public private(set) var access: AccessState
    public private(set) var choice: Choice
    public private(set) var hasProbed = false
    public private(set) var needsRelaunch = false
    public private(set) var isRelaunching = false
    public private(set) var error: String?
    private var visitedSettings = false
    private var reopened = false

    public init(access: AccessState = .unknown, choice: Choice = .none) {
        self.access = access
        self.choice = choice
    }

    public var isPresented: Bool { hasProbed && access != .granted && (choice == .none || reopened || needsRelaunch) }
    public var canScan: Bool { hasProbed && (access == .granted || choice == .limited) }
    public var scanMode: ScanMode { access == .granted ? .full : .limited }
    public var showsLimitedAffordance: Bool { access != .granted && choice == .limited }

    public mutating func send(_ event: Event) -> Command? {
        switch event {
        case .activated(let state):
            hasProbed = true
            access = state
            if state == .granted {
                needsRelaunch = false
                reopened = false
                visitedSettings = false
            } else if visitedSettings {
                needsRelaunch = true
                visitedSettings = false
            }
        case .openSettings:
            error = nil
            visitedSettings = true
            return .openSettings
        case .settingsFailed(let message):
            visitedSettings = false
            error = message
        case .dismissed:
            isRelaunching = false
        case .useLimited:
            isRelaunching = false
            choice = .limited
            reopened = false
            needsRelaunch = false
            visitedSettings = false
            error = nil
        case .reopen:
            reopened = true
        case .relaunch:
            guard !isRelaunching else { return nil }
            isRelaunching = true
            error = nil
            return .relaunch
        case .relaunchFailed(let message):
            isRelaunching = false
            error = message
        }
        return nil
    }
}

/// UserDefaults stays outside the reducer and can be isolated by suite in tests.
public final class OnboardingStore {
    static let key = "onboarding.scanChoice"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var choice: Onboarding.Choice {
        get { Onboarding.Choice(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

public enum FullDiskAccessSettings {
    public static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
