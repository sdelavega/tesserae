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

import Compression
import Darwin
import Foundation

public struct SampleEstimate {
    public static func compress(files: [(Data, UInt64)], read: (Data, Int) -> Data? = readSample) -> UInt64 {
        estimate(files: files, algorithm: COMPRESSION_LZFSE, read: read)
    }

    // Returns estimated savings, like compress; callers subtract from eligible
    // logical bytes when calculating the archive's free-space requirement.
    public static func archive(_ f: ArchiveFormat, files: [(Data, UInt64)], read: (Data, Int) -> Data? = readSample) -> UInt64 {
        estimate(files: files, algorithm: algorithm(for: f), read: read)
    }

    static func algorithm(for format: ArchiveFormat) -> compression_algorithm {
        switch format {
        case .zip: return COMPRESSION_ZLIB
        case .appleArchiveFast: return COMPRESSION_LZFSE
        case .tarXZ, .tarZst, .appleArchiveSmallest: return COMPRESSION_LZMA
        }
    }

    private static func estimate(files: [(Data, UInt64)], algorithm: compression_algorithm,
                                 read: (Data, Int) -> Data?) -> UInt64 {
        var total: Double = 0
        for (_, size) in files { total += Double(size) }
        var sampled: Double = 0, promisingSampled: Double = 0, savings: Double = 0
        for (path, size) in files.sorted(by: { $0.1 > $1.1 }).prefix(200) {
            if Task.isCancelled { return 0 }
            let limit = Int(min(size, 1_048_576))
            guard limit > 0, let input = read(path, limit), !input.isEmpty else { continue }
            let sample = input.prefix(limit)
            var encodedBytes = 0
            for offset in stride(from: 0, to: sample.count, by: 65536) {
                if Task.isCancelled { return 0 }
                let block = Data(sample.dropFirst(offset).prefix(65536))
                var output = [UInt8](repeating: 0, count: block.count + 4096)
                let count = block.withUnsafeBytes { source in
                    compression_encode_buffer(&output, output.count, source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                              block.count, nil, algorithm)
                }
                encodedBytes += count == 0 ? block.count : count
            }
            sampled += Double(sample.count)
            let ratio = Double(encodedBytes) / Double(sample.count)
            if ratio <= 0.95 {
                promisingSampled += Double(sample.count)
                savings += Double(sample.count) - Double(encodedBytes)
            }
        }
        guard promisingSampled > 0 else { return 0 }
        let result = savings + max(0, total - sampled) * savings / promisingSampled
        return result >= Double(UInt64.max) ? UInt64.max : UInt64(max(0, result))
    }

    static func mayRead(mode: UInt16, flags: UInt32) -> Bool {
        mode & UInt16(S_IFMT) == UInt16(S_IFREG) && flags & UInt32(SF_DATALESS) == 0
    }

    public static func readSample(_ path: Data, _ requested: Int) -> Data? {
        guard !path.isEmpty, !path.contains(0), requested > 0 else { return nil }
        return (path + Data([0])).withUnsafeBytes { bytes in
            let pointer = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
            var before = stat()
            guard lstat(pointer, &before) == 0, mayRead(mode: before.st_mode, flags: before.st_flags) else { return nil }
            let fd = open(pointer, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var after = stat()
            guard fstat(fd, &after) == 0, mayRead(mode: after.st_mode, flags: after.st_flags),
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino else { return nil }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            let limit = min(requested, 1_048_576)
            while data.count < limit {
                if Task.isCancelled { return nil }
                let count = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count))
                if count < 0 { if errno == EINTR { continue }; return nil }
                if count == 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }
    }
}
