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
    private static let firmlinks = (try? Data(contentsOf: URL(fileURLWithPath: "/usr/share/firmlinks")))
        .map(parseFirmlinks) ?? []

    public static func text(_ raw: Data, startupData: Data = StartupDisk.dataRoot) -> String {
        text(raw, startupData: startupData, firmlinks: firmlinks, mountOn: mountOn)
    }

    /// Injected mount lookup keeps the conservative failure cases testable.
    static func text(_ raw: Data, startupData: Data, firmlinks: [Data],
                     mountOn: (Data) -> Data?) -> String {
        guard startupData == StartupDisk.dataRoot, !firmlinks.isEmpty,
              mountOn(startupData) == startupData,
              raw == startupData || raw.starts(with: startupData + Data([47])),
              !raw.contains(0) else { return neutralisedPath(raw) }
        let remainder = Data(raw.dropFirst(startupData.count))
        let components = remainder.split(separator: 47)
        guard !components.contains(Data(".".utf8)), !components.contains(Data("..".utf8)),
              mountOn(raw) == startupData else { return neutralisedPath(raw) }
        if remainder.isEmpty || remainder == Data([47]) { return "/" }
        guard firmlinks.contains(where: { remainder == $0 || remainder.starts(with: $0 + Data([47])) })
        else { return neutralisedPath(raw) }
        return neutralisedPath(remainder)
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

    /// Snapshots can name files that have disappeared. Verify their closest
    /// existing ancestor; errors other than missing components stay conservative.
    static func mountOn(_ raw: Data) -> Data? {
        guard raw.first == 47, !raw.contains(0) else { return nil }
        var path = raw
        while !path.isEmpty {
            var info = statfs()
            let result = (path + Data([0])).withUnsafeBytes { bytes in
                statfs(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), &info)
            }
            if result == 0 {
                return withUnsafeBytes(of: &info.f_mntonname) { Data($0.prefix { $0 != 0 }) }
            }
            guard errno == ENOENT || errno == ENOTDIR else { return nil }
            guard let slash = path.lastIndex(of: 47), slash > path.startIndex else { return nil }
            path = Data(path[..<slash])
        }
        return nil
    }
}
