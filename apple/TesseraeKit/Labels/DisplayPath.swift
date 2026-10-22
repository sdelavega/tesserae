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

import Darwin
import Foundation

/// Display only. Actions and diagnostics retain the original bytes.
public enum DisplayPath {
    struct Configuration: Sendable {
        let startupData: Data
        let firmlinks: [Data]
        let nestedMounts: [Data]
        let verified: Bool

        init(startupData: Data, firmlinks: [Data], mountOn: (Data) -> Data?,
             mounts: () -> [Data]?) {
            self.startupData = startupData
            self.firmlinks = firmlinks
            let table = mounts()
            verified = startupData == StartupDisk.dataRoot && mountOn(startupData) == startupData && table != nil
            // Mount points may use the firmlink spelling (/Users/...) rather
            // than the scan's Data-root spelling. Cache both byte identities.
            nestedMounts = (table ?? []).flatMap { mount -> [Data] in
                var paths = [mount]
                if firmlinks.contains(where: { mount == $0 || mount.starts(with: $0 + Data([47])) }) {
                    paths.append(startupData + mount)
                }
                return paths.filter { $0.starts(with: startupData + Data([47])) }
            }
        }
    }

    // Static initialization publishes only after background verification completes.
    // The first caller waits once; every subsequent display is pure byte matching.
    private final class Loader: @unchecked Sendable {
        var value: Configuration?
        let ready = DispatchSemaphore(value: 0)
        init() {
            DispatchQueue.global(qos: .userInitiated).async {
                let links = (try? Data(contentsOf: URL(fileURLWithPath: "/usr/share/firmlinks")))
                    .map(DisplayPath.parseFirmlinks) ?? []
                self.value = Configuration(startupData: StartupDisk.dataRoot, firmlinks: links,
                                           mountOn: DisplayPath.mountOn, mounts: DisplayPath.mounts)
                self.ready.signal()
            }
            ready.wait()
        }
    }
    private static let configuration = Loader().value!

    public static func text(_ raw: Data, startupData: Data = StartupDisk.dataRoot) -> String {
        guard startupData == configuration.startupData else { return neutralisedPath(raw) }
        return text(raw, configuration: configuration)
    }

    static func text(_ raw: Data, configuration: Configuration) -> String {
        let startupData = configuration.startupData
        guard configuration.verified, !configuration.firmlinks.isEmpty,
              raw == startupData || raw.starts(with: startupData + Data([47])),
              !raw.contains(0) else { return neutralisedPath(raw) }
        let remainder = Data(raw.dropFirst(startupData.count))
        let components = remainder.split(separator: 47)
        guard !components.contains(Data(".".utf8)), !components.contains(Data("..".utf8)),
              !configuration.nestedMounts.contains(where: { raw == $0 || raw.starts(with: $0 + Data([47])) })
        else { return neutralisedPath(raw) }
        if remainder.isEmpty || remainder == Data([47]) { return "/" }
        guard configuration.firmlinks.contains(where: { remainder == $0 || remainder.starts(with: $0 + Data([47])) })
        else { return neutralisedPath(raw) }
        return neutralisedPath(remainder)
    }

    /// One nonblocking mount-table read. A full buffer or failure disables
    /// shortening conservatively rather than accepting an incomplete table.
    static func mounts() -> [Data]? {
        var entries: [statfs] = Array(repeating: statfs(), count: 4096)
        let capacity = entries.count
        let count = entries.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard count >= 0, count < capacity else { return nil }
        return entries.prefix(Int(count)).map { entry in
            var entry = entry
            return withUnsafeBytes(of: &entry.f_mntonname) { Data($0.prefix { $0 != 0 }) }
        }
    }

    /// macOS lists an absolute root path and a Data-relative target, separated by a tab.
    static func parseFirmlinks(_ contents: Data) -> [Data] {
        contents.split(separator: 10).compactMap { line in
            let columns = line.split(separator: 9, omittingEmptySubsequences: false)
            guard columns.count == 2, columns[0].first == 47,
                  columns[0].dropFirst() == columns[1], !columns[1].isEmpty,
                  !columns[1].split(separator: 47).contains(where: { $0 == Data("..".utf8) || $0 == Data(".".utf8) })
            else { return nil }
            return Data(columns[0])
        }
    }

    /// Only the fixed startup root is probed, once during verification.
    static func mountOn(_ raw: Data) -> Data? {
        guard raw.first == 47, !raw.contains(0) else { return nil }
        var info = statfs()
        let result = (raw + Data([0])).withUnsafeBytes { bytes in
            statfs(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), &info)
        }
        guard result == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntonname) { Data($0.prefix { $0 != 0 }) }
    }
}
