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

public struct SnapshotFacts: Equatable, Sendable {
    public let count: Int?
    public let oldest: Date?
    public let aggregateBytes: UInt64?
}

public func readSnapshotFacts(volumeRoot: URL, runner: CommandRunner = .system) -> SnapshotFacts {
    let unknown = SnapshotFacts(count: nil, oldest: nil, aggregateBytes: nil)
    guard case let .exited(status: 0, stdout: data) = runner.run(
        URL(fileURLWithPath: "/usr/bin/tmutil"), ["listlocalsnapshots", volumeRoot.path], 5),
        let text = String(data: data, encoding: .utf8)
    else { return unknown }
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard let header = lines.first,
        header == "Snapshots for disk \(volumeRoot.path):"
            || header == "Snapshots for volume group containing disk \(volumeRoot.path):"
    else { return unknown }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    formatter.isLenient = false
    var dates: [Date] = []
    var hasUndatedSnapshot = false
    for name in lines.dropFirst() {
        if name.range(of: #"^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.local$"#,
                      options: .regularExpression) != nil {
            let stamp = String(name.dropFirst("com.apple.TimeMachine.".count).dropLast(".local".count))
            guard let date = formatter.date(from: stamp), formatter.string(from: date) == stamp else {
                return unknown
            }
            dates.append(date)
        } else if name.range(of: #"^com\.apple\.os\.update-[A-Za-z0-9-]+$"#,
                             options: .regularExpression) != nil {
            hasUndatedSnapshot = true
        } else {
            // A partial or changed listing format cannot establish even a known zero.
            return unknown
        }
    }
    // Update snapshots have no date in tmutil's names, so the oldest overall is unknown.
    return SnapshotFacts(count: lines.count - 1, oldest: hasUndatedSnapshot ? nil : dates.min(),
                         aggregateBytes: nil)
}
