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
        guard !ExclusionFilter.isVolumeRoot(url) else { return }
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

    /// Canonical spelling shared by exclusions and scan history. Preserve raw
    /// path bytes for history; no filename decoding or symlink traversal.
    public static func normalized(_ path: Data) -> Data {
        let prefix = Data(dataRoot.utf8)
        if path == prefix { return Data("/".utf8) }
        if path.starts(with: prefix + Data([0x2f])) { return Data(path.dropFirst(prefix.count)) }
        return path
    }

    public static func normalized(_ url: URL) -> String {
        String(decoding: normalized(Data(url.standardized.path.utf8)), as: UTF8.self)
    }

    static func isVolumeRoot(_ url: URL) -> Bool {
        let path = normalized(url)
        if path == "/" { return true }
        // Also reject unmounted /Volumes entries retained in Settings.
        if url.standardized.path.hasPrefix("/Volumes/"), url.standardized.path.split(separator: "/").count == 2 { return true }
        guard let volume = try? volumeRoot(of: Data(url.standardized.path.utf8)) else { return false }
        return normalized(volume) == Data(path.utf8)
    }

    public static func refuses(_ root: URL, exclusions: [URL]) -> Bool {
        exclusions.contains { !isVolumeRoot($0) && isWithin(normalized(root), normalized($0)) }
    }

    /// Return only outermost descendants, mapped to the spelling used by the walker.
    public static func applicable(_ exclusions: [URL], root: URL, exists: (String) -> Bool) -> [URL] {
        let rootPath = normalized(root)
        let usesData = isWithin(root.standardized.path, dataRoot)
        let paths = Set(exclusions.filter { !isVolumeRoot($0) }.map { normalized($0) }.filter {
            $0 != rootPath && isWithin($0, rootPath)
        })
        return paths.sorted()
            .filter { path in !paths.contains { other in other != path && isWithin(path, other) } }
            .compactMap { path in
                let mapped = usesData ? dataRoot + (path == "/" ? "" : path) : path
                guard !usesData || exists(mapped) else { return nil }
                return URL(fileURLWithPath: mapped, isDirectory: true)
            }
    }
}
