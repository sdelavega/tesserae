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

public struct VolumeFacts: Equatable, Sendable {
    public let capacity: UInt64
    public let used: UInt64
    public let free: UInt64
    public let available: UInt64
    public let purgeable: UInt64?
}

public enum VolumeFactsError: Error {
    case unsupported(errno: Int32)
    case malformed
}

public func readVolumeFacts(at volumeRoot: URL) throws -> VolumeFacts {
    try readVolumeFacts(
        at: volumeRoot, readAttributes: volumeAttributes,
        importantCapacity: { url in
            try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        })
}

public func readSystemVolumeUsed() -> UInt64? {
    try? volumeValues(
        volumeAttributes(at: URL(fileURLWithPath: "/"), mask: UInt32(ATTR_VOL_SPACEUSED)), count: 1)[0]
}

// The seam carries raw replies so tests cover both request masks and packed byte decoding.
internal func readVolumeFacts(
    at volumeRoot: URL,
    readAttributes: (URL, UInt32) throws -> Data,
    importantCapacity: (URL) -> Int64?
) throws -> VolumeFacts {
    // The SDK calls capacity ATTR_VOL_SIZE. SPACEUSED packs out of bit order on APFS;
    // isolate it rather than assuming where the kernel puts it among other attributes.
    let space = try volumeValues(
        readAttributes(volumeRoot, UInt32(ATTR_VOL_SIZE | ATTR_VOL_SPACEFREE | ATTR_VOL_SPACEAVAIL)),
        count: 3)
    let used = try volumeValues(readAttributes(volumeRoot, UInt32(ATTR_VOL_SPACEUSED)), count: 1)[0]
    let purgeable = purgeableEstimate(important: importantCapacity(volumeRoot), available: space[2])
    return VolumeFacts(
        capacity: space[0], used: used, free: space[1], available: space[2], purgeable: purgeable)
}

internal func purgeableEstimate(important: Int64?, available: UInt64) -> UInt64? {
    guard let important, important >= 0 else { return nil }
    let total = UInt64(important)
    // Equal reads give a real zero; a smaller important capacity means the reads raced (unknown).
    guard total >= available else { return nil }
    return total - available
}

private func volumeAttributes(at root: URL, mask: UInt32) throws -> Data {
    guard root.isFileURL else { throw VolumeFactsError.malformed }
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.volattr = UInt32(ATTR_VOL_INFO) | mask
    let count = mask == UInt32(ATTR_VOL_SPACEUSED) ? 1 : 3
    var buffer = Data(count: MemoryLayout<UInt32>.size + count * MemoryLayout<off_t>.size)
    let bufferSize = buffer.count
    try root.withUnsafeFileSystemRepresentation { path in
        guard let path else { throw VolumeFactsError.malformed }
        try buffer.withUnsafeMutableBytes { bytes in
            guard getattrlist(path, &attributes, bytes.baseAddress, bufferSize, 0) == 0 else {
                throw VolumeFactsError.unsupported(errno: errno)
            }
        }
    }
    return buffer
}

private func volumeValues(_ data: Data, count: Int) throws -> [UInt64] {
    let headerSize = MemoryLayout<UInt32>.size
    let valueSize = MemoryLayout<off_t>.size
    guard data.count == headerSize + count * valueSize else { throw VolumeFactsError.malformed }
    var length: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &length) { data.copyBytes(to: $0, from: 0..<headerSize) }
    guard Int(length) == data.count else { throw VolumeFactsError.malformed }
    return try (0..<count).map { index in
        let start = headerSize + index * valueSize
        var value: off_t = 0
        _ = withUnsafeMutableBytes(of: &value) {
            data.copyBytes(to: $0, from: start..<(start + valueSize))
        }
        guard value >= 0 else { throw VolumeFactsError.malformed }
        return UInt64(value)
    }
}
