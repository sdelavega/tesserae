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

public typealias CompressRunID = UUID

public struct CompressManifest: Sendable {
    public struct Row: Equatable, Sendable {
        public let path: Data
        public let device: Int32
        public let fileID: UInt64
        public init(path: Data, device: Int32, fileID: UInt64) {
            self.path = path; self.device = device; self.fileID = fileID
        }
    }
    public let directory: URL
    public init(directory: URL = ReclaimLog.defaultDirectory.appendingPathComponent("manifests")) {
        self.directory = directory
    }
    public func url(_ run: CompressRunID) -> URL {
        directory.appendingPathComponent(run.uuidString.lowercased() + ".tsv")
    }
    // Create before starting the helper; append and sync each completed batch.
    func create(_ run: CompressRunID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw posixError() }
        let fd = open(url(run).path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }; close(fd)
    }
    func append(_ rows: [Row], run: CompressRunID) throws {
        let bytes = Data(rows.map { "\($0.path.base64EncodedString())\t\($0.device)\t\($0.fileID)\n" }.joined().utf8)
        let fd = open(url(run).path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }; defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw posixError() }; offset += n
            }
        }
        guard fsync(fd) == 0 else { throw posixError() }
    }
    public func read(_ run: CompressRunID) throws -> [Row] {
        let fd = open(url(run).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError() }; defer { close(fd) }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw posixError() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw posixError() }; if n == 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard data.isEmpty || data.last == 10 else { throw posixError(EINVAL) }
        var seen: Set<Data> = []
        return try data.split(separator: 10).map { line in
            let fields = line.split(separator: 9, omittingEmptySubsequences: false)
            guard fields.count == 3, let path = Data(base64Encoded: Data(fields[0])),
                  path.first == 47, !path.contains(0), !path.split(separator: 47).contains(where: { $0 == Data("..".utf8) || $0 == Data(".".utf8) }),
                  seen.insert(path).inserted,
                  let device = Int32(String(decoding: fields[1], as: UTF8.self)),
                  let inode = UInt64(String(decoding: fields[2], as: UTF8.self)), inode != 0 else { throw posixError(EINVAL) }
            return Row(path: path, device: device, fileID: inode)
        }
    }
    private func posixError(_ code: Int32 = errno) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}
