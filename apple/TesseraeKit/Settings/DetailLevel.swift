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

import Combine
import Foundation

public enum DetailLevel: String, CaseIterable, Sendable {
    case simple, detailed
}

/// Shared presentation preference. Consumers observe it without reloading scan or review state.
@MainActor
public final class DetailSettings: ObservableObject {
    public static let shared = DetailSettings()
    private let defaults: UserDefaults
    @Published public var current: DetailLevel {
        didSet { defaults.set(current.rawValue, forKey: "detailLevel") }
    }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.string(forKey: "detailLevel").flatMap(DetailLevel.init(rawValue:)) ?? .simple
    }
}
