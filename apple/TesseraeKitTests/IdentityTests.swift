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
import XCTest

@testable import TesseraeKit

final class IdentityTests: XCTestCase {
    private let path = Data("/scan/root/parent/file".utf8)
    private let recorded = Recorded(fileID: 42, device: 7, isDirectory: false)

    private struct FakeStat: FileStat {
        var entries: [Data: StatResult] = [:]
        func lstat(_ rawPath: Data) -> StatResult {
            entries[rawPath] ?? .ok(Observed(device: 7, flags: 0, isDirectory: true, linkCount: 1),
                                    fileID: 1, isSymlink: false)
        }
    }

    private func item(device: Int32 = 7, id: UInt64 = 42, directory: Bool = false,
                      symlink: Bool = false) -> StatResult {
        .ok(Observed(device: device, flags: 0, isDirectory: directory, linkCount: 1),
            fileID: id, isSymlink: symlink)
    }

    func test_identity_outcomes_and_priority() {
        let rows: [(StatResult, IdentityResult)] = [
            (item(), .same), (item(id: 43), .inodeChanged),
            (item(device: 8, id: 43, directory: true), .deviceChanged),
            (item(id: 43, directory: true), .inodeChanged),
            (item(directory: true), .typeChanged),
            (item(device: 8, id: 43, directory: true, symlink: true), .nowSymlink)
        ]
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(recorded.fileID, 42)
        XCTAssertEqual(recorded.device, 7)
        XCTAssertFalse(recorded.isDirectory)
        for (observed, expected) in rows {
            XCTAssertEqual(verifyIdentity(path, recorded, stat: FakeStat(entries: [path: observed])), expected)
        }
        let directory = Recorded(fileID: 42, device: 7, isDirectory: true)
        XCTAssertEqual(verifyIdentity(path, directory, stat: FakeStat(entries: [path: item(directory: true)])), .same)
        XCTAssertEqual(verifyIdentity(path, directory, stat: FakeStat(entries: [path: item()])), .typeChanged)
    }

    func test_item_errors_precede_ancestry() {
        let ancestor = Data("/scan".utf8)
        for code in [ENOENT, ENOTDIR, EACCES, EIO, EPERM] {
            let fake = FakeStat(entries: [path: .error(errno: code), ancestor: item(symlink: true)])
            XCTAssertEqual(symlinkedAncestor(path, stat: fake), ancestor)
            XCTAssertEqual(verifyIdentity(path, recorded, stat: fake),
                           code == ENOENT || code == ENOTDIR ? .gone : .unreadable(errno: code))
        }
    }

    func test_every_proper_prefix_and_first_symlink() {
        let prefixes = ["/", "/scan", "/scan/root", "/scan/root/parent"].map { Data($0.utf8) }
        XCTAssertEqual(prefixes.count, 4)
        for prefix in prefixes {
            XCTAssertNotEqual(prefix, path)
            let fake = FakeStat(entries: [path: item(symlink: true), prefix: item(symlink: true)])
            XCTAssertEqual(symlinkedAncestor(path, stat: fake), prefix)
            XCTAssertEqual(verifyIdentity(path, recorded, stat: fake), .symlinkInPath(prefix))
        }
        let fake = FakeStat(entries: Dictionary(uniqueKeysWithValues: prefixes.map { ($0, item(symlink: true)) }))
        XCTAssertEqual(symlinkedAncestor(path, stat: fake), Data("/".utf8))
        XCTAssertNil(symlinkedAncestor(path, stat: FakeStat(entries: [path: item(symlink: true)])))
        XCTAssertNil(symlinkedAncestor(Data("/".utf8), stat: FakeStat(entries: [Data("/".utf8): item(symlink: true)])))
    }

    func test_ancestor_errors_are_not_symlinks() {
        let parent = Data("/scan/root".utf8)
        for code in [EACCES, EIO, ENOENT, ENOTDIR] {
            let fake = FakeStat(entries: [path: item(), parent: .error(errno: code)])
            XCTAssertNil(symlinkedAncestor(path, stat: fake))
            XCTAssertEqual(verifyIdentity(path, recorded, stat: fake),
                           code == ENOENT || code == ENOTDIR ? .gone : .unreadable(errno: code))
        }
    }

    func test_data_mount_and_firmlinks_are_not_symlinks_but_var_is() {
        for spelling in ["/System/Volumes/Data/private/var/file", "/Users/tester/file", "/var/file", "/tmp/file"] {
            let raw = Data(spelling.utf8)
            let fake = FakeStat(entries: [raw: item(), Data("/var".utf8): item(symlink: true),
                                         Data("/tmp".utf8): item(symlink: true)])
            let link = spelling.hasPrefix("/var/") ? Data("/var".utf8)
                : spelling.hasPrefix("/tmp/") ? Data("/tmp".utf8) : nil
            XCTAssertEqual(symlinkedAncestor(raw, stat: fake), link)
            XCTAssertEqual(verifyIdentity(raw, recorded, stat: fake), link.map { .symlinkInPath($0) } ?? .same)
        }
    }

    func test_raw_ancestor_bytes_are_preserved() {
        let parent = Data("/scan/".utf8) + Data([0xff])
        let raw = parent + Data("/file".utf8)
        XCTAssertNil(String(data: raw, encoding: .utf8))
        let fake = FakeStat(entries: [raw: item(), parent: item(symlink: true)])
        XCTAssertEqual(symlinkedAncestor(raw, stat: fake), parent)
        XCTAssertEqual(verifyIdentity(raw, recorded, stat: fake), .symlinkInPath(parent))
    }

    func test_production_stat_reads_raw_tree_without_following_final_symlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tess-stat-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let resolved = try root.withUnsafeFileSystemRepresentation { try XCTUnwrap(realpath($0!, nil)) }
        defer { free(resolved) }
        let rootBytes = Data(bytes: resolved, count: strlen(resolved))
        XCTAssertTrue(rootBytes.starts(with: Data("/".utf8)))
        XCTAssertNil(symlinkedAncestor(rootBytes, stat: ProductionFileStat()))
        // APFS refuses invalid UTF-8 names; the fake above covers those bytes.
        let raw = rootBytes + Data("/é-file".utf8)
        XCTAssertTrue(raw.contains { $0 > 0x7f })
        let terminated = raw + Data([0])
        let fd = terminated.withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_CREAT | O_EXCL | O_WRONLY, 0o600) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = Darwin.stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        let stat = ProductionFileStat()
        let expected = Observed(device: info.st_dev, flags: info.st_flags, isDirectory: false, linkCount: info.st_nlink, owner: info.st_uid, permissions: UInt16(info.st_mode & 0o7777))
        XCTAssertEqual(stat.lstat(raw), .ok(expected, fileID: info.st_ino, isSymlink: false))
        XCTAssertEqual(verifyIdentity(raw, Recorded(fileID: info.st_ino, device: info.st_dev, isDirectory: false), stat: stat), .same)
        guard case .ok(let directory, _, let isLink) = stat.lstat(rootBytes) else {
            return XCTFail("directory stat failed")
        }
        XCTAssertTrue(directory.isDirectory)
        XCTAssertFalse(isLink)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        guard case .ok(let observed, _, let isSymlink) = stat.lstat(Data(link.path.utf8)) else {
            return XCTFail("dangling symlink must be stat-able")
        }
        XCTAssertTrue(isSymlink)
        XCTAssertFalse(observed.isDirectory)
        XCTAssertEqual(stat.lstat(rootBytes + Data("/missing".utf8)), .error(errno: ENOENT))
        XCTAssertEqual(stat.lstat(raw + Data("/child".utf8)), .error(errno: ENOTDIR))
    }
}
