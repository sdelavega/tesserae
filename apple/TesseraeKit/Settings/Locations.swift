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

/// Folders the user scans often, and folders every scan leaves out.
@MainActor
public final class LocationSettings: ObservableObject {
    public static let shared = LocationSettings(defaults: .standard)
    nonisolated static let savedKey = "savedLocations"
    nonisolated static let excludedKey = "excludedLocations"

    private let defaults: UserDefaults
    @Published public private(set) var saved: [URL]
    @Published public private(set) var excluded: [URL]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        saved = Self.load(defaults, Self.savedKey)
        excluded = Self.load(defaults, Self.excludedKey)
    }

    nonisolated private static func load(_ defaults: UserDefaults, _ key: String) -> [URL] {
        (defaults.stringArray(forKey: key) ?? []).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    nonisolated private static func normalized(_ url: URL) -> String { url.standardized.path }

    private func store() {
        defaults.set(saved.map { Self.normalized($0) }, forKey: Self.savedKey)
        defaults.set(excluded.map { Self.normalized($0) }, forKey: Self.excludedKey)
    }

    nonisolated private static func adding(_ url: URL, to list: [URL]) -> [URL] {
        let path = normalized(url)
        guard path.hasPrefix("/"), !list.contains(where: { normalized($0) == path }) else { return list }
        return list + [URL(fileURLWithPath: path, isDirectory: true)]
    }

    public func addSaved(_ url: URL) {
        saved = Self.adding(url, to: saved)
        store()
    }

    public func removeSaved(_ url: URL) {
        saved.removeAll { Self.normalized($0) == Self.normalized(url) }
        store()
    }

    public func isSaved(_ url: URL) -> Bool {
        saved.contains { Self.normalized($0) == Self.normalized(url) }
    }

    public func addExcluded(_ url: URL) {
        excluded = Self.adding(url, to: excluded)
        store()
    }

    public func removeExcluded(_ url: URL) {
        excluded.removeAll { Self.normalized($0) == Self.normalized(url) }
        store()
    }
}

public enum ExclusionFilter {
    /// The startup disk's Data volume, where a whole-disk scan starts.
    static let dataRoot = "/System/Volumes/Data"

    static func isWithin(_ path: String, _ root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : path == root || path.hasPrefix(root + "/")
    }

    /// The exclusions that lie strictly inside `root`, as the paths the scan
    /// will meet them by. A scan of the startup disk starts at its Data volume
    /// and reaches `/Users/…` as `/System/Volumes/Data/Users/…`, so an
    /// exclusion outside that volume's path is rewritten under it when the
    /// rewritten path `exists`. Exclusions inside other exclusions, duplicates
    /// and the root itself are dropped, so the scan report lists each once.
    public static func applicable(_ exclusions: [URL], root: URL, exists: (String) -> Bool) -> [URL] {
        let rootPath = root.standardized.path
        var paths: Set<String> = []
        for url in exclusions {
            var path = url.standardized.path
            guard path.hasPrefix("/"), path != "/" else { continue }
            if rootPath == dataRoot, !isWithin(path, dataRoot) {
                let mapped = dataRoot + path
                guard exists(mapped) else { continue }
                path = mapped
            }
            if path != rootPath, isWithin(path, rootPath) { paths.insert(path) }
        }
        return paths.sorted()
            .filter { path in !paths.contains { other in other != path && isWithin(path, other) } }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
