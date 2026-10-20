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
import TesseraeFFI

public enum ScanBanner {
    /// `stalledAt` is shown as names are (`singleLine`): it is made of them.
    public static func text(for stats: TessScanStats, stalledAt: String?, volumePath: String? = nil) -> String? {
        var parts: [String] = []
        if let reason = incompleteReason(for: stats, stalledAt: stalledAt) {
            parts.append(reason + (stats.incomplete == UInt32(TESS_INCOMPLETE_VOLUME_LOST)
                ? volumePath.map { ": " + singleLine($0) } ?? "" : ""))
        }
        if stats.errors > 0 { parts.append("\(stats.errors) errors") }
        if stats.unreadable_count > 0 { parts.append("\(stats.unreadable_count) unreadable folders") }
        guard !parts.isEmpty else { return nil }
        return "Partial result — " + parts.joined(separator: "; ")
    }

    public static func incompleteReason(for stats: TessScanStats, stalledAt: String?) -> String? {
        switch stats.incomplete {
        case UInt32(TESS_INCOMPLETE_NONE): return nil
        case UInt32(TESS_INCOMPLETE_CANCELLED): return "Scan cancelled"
        case UInt32(TESS_INCOMPLETE_NODE_BUDGET): return "Scan reached its node limit"
        case UInt32(TESS_INCOMPLETE_OUT_OF_MEMORY): return "Scan ran out of memory"
        case UInt32(TESS_INCOMPLETE_STALLED):
            return "Scan stalled" + (stalledAt.map { " at " + singleLine($0) } ?? "")
        case UInt32(TESS_INCOMPLETE_FD_EXHAUSTED): return "Scan exhausted file descriptors"
        case UInt32(TESS_INCOMPLETE_MALFORMED_BATCH): return "Scan stopped at a malformed filesystem batch"
        case UInt32(TESS_INCOMPLETE_VOLUME_LOST): return "Scan volume became unavailable"
        default: return "Scan ended with unknown incomplete code \(stats.incomplete)"
        }
    }
}
