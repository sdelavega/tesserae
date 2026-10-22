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

import AppleArchive
import CryptoKit
import Darwin
import Foundation
import System
import XCTest
@testable import TesseraeKit

final class AppleArchiveTests: XCTestCase, @unchecked Sendable {
    func withTree(_ body: (URL, URL) async throws -> Void) async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let tree = f.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("contents".utf8).write(to: tree.appendingPathComponent("nested/file"))
        try Data().write(to: tree.appendingPathComponent("empty"))
        XCTAssertEqual(symlink("nested/file", tree.appendingPathComponent("link").path), 0)
        try await body(f.root, tree)
    }
    func make(_ tree: URL, _ archive: URL, _ compression: AppleArchiveCompression) throws {
        let fd = open(archive.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        XCTAssertGreaterThan(try ProductionAppleArchiveWriter().write(item: Data(tree.path.utf8), to: fd, compression: compression), 0)
    }
    func verify(_ archive: URL, _ item: URL) throws -> ArchiveVerdict {
        let fd = open(archive.path, O_RDONLY); guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        return verifyAppleArchive(fd: fd, item: Data(item.path.utf8))
    }
    func test_aar_round_trip_keeps_xattrs_acls_flags() async throws {
        try await withTree { root, tree in
            let leaf = tree.appendingPathComponent("nested/file")
            for (key, value) in [("com.tesserae.test", Data("xattr".utf8)), ("com.apple.ResourceFork", Data("fork".utf8)),
                ("com.apple.metadata:_kMDItemUserTags", try PropertyListSerialization.data(fromPropertyList: ["Blue\n4"], format: .binary, options: 0))] {
                XCTAssertEqual(value.withUnsafeBytes { setxattr(leaf.path, key, $0.baseAddress, $0.count, 0, 0) }, 0)
            }
            let chmodResult = await SpawnRunner().run("/bin/chmod", ["+a", "everyone allow read", leaf.path].map { Data($0.utf8) })
            XCTAssertEqual(chmodResult, .exited(0)); XCTAssertEqual(chflags(leaf.path, UInt32(UF_HIDDEN)), 0)
            for mode in [AppleArchiveCompression.lzfse, .lzma] {
                let name = mode == .lzfse ? "fast" : "small", archive = root.appendingPathComponent(name + ".aar")
                try self.make(tree, archive, mode)
                let verdict = try self.verify(archive, tree)
                XCTAssertEqual(verdict.code, 0); XCTAssertEqual(verdict.files, 2); XCTAssertEqual(verdict.links, 1)
                let restored = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: false)
                let status = await SpawnRunner().run("/usr/bin/aa", ["extract", "-i", archive.path, "-d", restored.path].map { Data($0.utf8) })
                XCTAssertEqual(status, .exited(0))
                let target = restored.appendingPathComponent("tree/nested/file")
                XCTAssertEqual(try Data(contentsOf: target), Data("contents".utf8))
                for key in ["com.tesserae.test", "com.apple.ResourceFork", "com.apple.metadata:_kMDItemUserTags"] {
                    XCTAssertEqual(try self.attribute(target, key), try self.attribute(leaf, key))
                }
                var s = Darwin.stat(); XCTAssertEqual(lstat(target.path, &s), 0); XCTAssertNotEqual(s.st_flags & UInt32(UF_HIDDEN), 0)
                let beforeACL = acl_get_file(leaf.path, ACL_TYPE_EXTENDED), afterACL = acl_get_file(target.path, ACL_TYPE_EXTENDED)
                XCTAssertNotNil(beforeACL); XCTAssertNotNil(afterACL)
                if let beforeACL, let afterACL {
                    defer { acl_free(UnsafeMutableRawPointer(beforeACL)); acl_free(UnsafeMutableRawPointer(afterACL)) }
                    let beforeText = try XCTUnwrap(acl_to_text(beforeACL, nil)), afterText = try XCTUnwrap(acl_to_text(afterACL, nil))
                    defer { acl_free(beforeText); acl_free(afterText) }
                    XCTAssertEqual(String(cString: beforeText), String(cString: afterText))
                }
            }
        }
    }
    func attribute(_ url: URL, _ key: String) throws -> Data {
        let count = getxattr(url.path, key, nil, 0, 0, 0)
        guard count >= 0 else { throw archiveError(errno) }
        var bytes = [UInt8](repeating: 0, count: count)
        XCTAssertEqual(getxattr(url.path, key, &bytes, bytes.count, 0, 0), count)
        return Data(bytes)
    }
    func test_default_format_by_volume() {
        for fs in ["apfs", "hfs"] { XCTAssertEqual(defaultFormat(volumeFSType: fs), .appleArchiveFast) }
        for fs in ["exfat", "msdos", "ntfs", "smbfs"] { XCTAssertEqual(defaultFormat(volumeFSType: fs), .zip) }
    }
    func test_advanced_membership_by_volume() {
        XCTAssertEqual(ArchiveFormat.allCases.count, 5)
        for fs in ["apfs", "hfs", "exfat", "msdos", "ntfs", "smbfs"] {
            XCTAssertEqual(Set(ArchiveFormat.allCases.filter { isAdvanced($0, volumeFSType: fs) }),
                fs == "apfs" || fs == "hfs" ? [.appleArchiveSmallest, .tarZst] : [.appleArchiveFast, .appleArchiveSmallest, .tarZst])
        }
    }
    func test_aar_verifier_parity_with_rust() async throws {
        try await withTree { root, tree in
            let zip = root.appendingPathComponent("tree.zip"), aar = root.appendingPathComponent("tree.aar")
            let zipFD = open(zip.path, O_CREAT | O_EXCL | O_WRONLY, 0o644); XCTAssertGreaterThanOrEqual(zipFD, 0)
            let status = await ProductionArchiveRunner().run(item: Data(tree.path.utf8), format: .zip, to: zipFD); close(zipFD)
            XCTAssertEqual(status, 0); try self.make(tree, aar, .lzfse)
            func rust() throws -> ArchiveVerdict {
                let fd = open(zip.path, O_RDONLY); defer { close(fd) }
                return ProductionArchiveVerifier().verify(fd: fd, path: Data(zip.path.utf8), format: .zip, item: Data(tree.path.utf8))
            }
            let original = try rust(); XCTAssertEqual(original.code, 0); XCTAssertEqual(original.files, 2)
            XCTAssertEqual(try self.verify(aar, tree), original)
            try Data("changed!".utf8).write(to: tree.appendingPathComponent("nested/file"))
            let bad = try rust(); XCTAssertEqual(bad.code, 4); XCTAssertEqual(bad.firstBadPath, Data("tree/nested/file".utf8))
            XCTAssertEqual(try self.verify(aar, tree), bad)
        }
    }
    func test_aar_detects_changed_byte() async throws {
        try await withTree { root, tree in
            for mode in [AppleArchiveCompression.lzfse, .lzma] {
                let archive = root.appendingPathComponent(UUID().uuidString + ".aar"), leaf = tree.appendingPathComponent("nested/file")
                try Data("contents".utf8).write(to: leaf); try self.make(tree, archive, mode)
                XCTAssertEqual(try self.verify(archive, tree).code, 0)
                try Data("ContentS".utf8).write(to: leaf)
                XCTAssertEqual(try self.verify(archive, tree).code, 4)
            }
        }
    }
    func test_aar_keeps_real_appledouble_and_detects_omission() async throws {
        try await withTree { root, tree in
            let literal = tree.appendingPathComponent("._data"); try Data("literal".utf8).write(to: literal)
            for mode in [AppleArchiveCompression.lzfse, .lzma] {
                let archive = root.appendingPathComponent(UUID().uuidString + ".aar"); try self.make(tree, archive, mode)
                let good = try self.verify(archive, tree); XCTAssertEqual(good.code, 0); XCTAssertEqual(good.files, 3)
                try Data("changed".utf8).write(to: literal)
                let bad = try self.verify(archive, tree); XCTAssertEqual(bad.code, 4); XCTAssertEqual(bad.firstBadPath, Data("tree/._data".utf8))
                try Data("literal".utf8).write(to: literal)
            }
            let archive = root.appendingPathComponent("before.aar"); try self.make(tree, archive, .lzfse)
            try Data("new".utf8).write(to: tree.appendingPathComponent("._missing"))
            XCTAssertEqual(try self.verify(archive, tree).code, 1)
        }
    }
    // Synthetic archives exercise paths that a real filesystem cannot represent twice.
    func synthetic(_ output: URL, entries: [(String, Data)], omitData: Bool = false, hardlink: UInt64? = nil, clusterKey: String = "HLC", directories: [String] = [], duplicateData: Data? = nil) throws {
        let fd = open(output.path, O_CREAT | O_EXCL | O_WRONLY, 0o644); guard fd >= 0 else { throw archiveError(errno) }; defer { close(fd) }
        try ArchiveByteStream.withFileStream(fd: FileDescriptor(rawValue: fd), automaticClose: false) { file in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { compressed in
                try ArchiveStream.withEncodeStream(writingTo: compressed) { stream in
                    for directory in directories {
                        let h = ArchiveHeader()
                        h.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.directory.rawValue)))
                        h.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: directory))
                        try stream.writeHeader(h)
                    }
                    for (name, data) in entries {
                        let h = ArchiveHeader()
                        h.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
                        h.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: name))
                        if let hardlink { h.append(.uint(key: ArchiveHeader.FieldKey(clusterKey), value: hardlink)) }
                        if !omitData { h.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(data.count))) }
                        if let duplicateData { h.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(duplicateData.count))) }
                        try stream.writeHeader(h)
                        if !omitData { try data.withUnsafeBytes { try stream.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) } }
                        if let duplicateData { try duplicateData.withUnsafeBytes { try stream.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) } }
                    }
                }
            }
        }
    }
    let sidecarHeader = Data([0, 5, 22, 7, 0, 2, 0, 0] + [UInt8](repeating: 0, count: 16))
    func writeSidecar(_ path: URL, body: Data = Data()) throws {
        try (sidecarHeader + body).write(to: path)
        XCTAssertEqual(chflags(path.path, UInt32(UF_HIDDEN)), 0)
        var st = Darwin.stat(); XCTAssertEqual(lstat(path.path, &st), 0)
        XCTAssertNotEqual(st.st_flags & UInt32(UF_HIDDEN), 0)
    }
    func test_sidecar_sibling_and_c_string_preserve_raw_unusual_names() throws {
        let names = [Data("tiny\nname".utf8), Data("tab\tname".utf8), Data([98, 97, 100, 45, 255]),
            Data([98, 97, 100, 45, 254]), Data("bad-\u{fffd}".utf8), Data("-leading".utf8), Data(repeating: 108, count: 240)]
        for name in names {
            let storage = Data([99, 99, 46, 95]) + name
            let slice = storage.dropFirst(2)
            XCTAssertEqual(slice.startIndex, 2, "exercise Data with nonzero indices")
            let sibling = try XCTUnwrap(archiveSidecarSibling(slice))
            XCTAssertEqual(sibling.startIndex, 0); XCTAssertEqual(sibling, name)
            XCTAssertEqual(archiveCString(sibling) { Data(bytes: $0, count: strlen($0)) }, name)
            XCTAssertEqual(archiveCollisionKey(sibling), name)
        }
        XCTAssertNil(archiveSidecarSibling(Data("._".utf8)))
        XCTAssertNil(archiveSidecarSibling(Data("plain".utf8)))
        XCTAssertNotEqual(archiveSidecarSibling(Data([46, 95, 255])), archiveSidecarSibling(Data([46, 95, 254])))
        XCTAssertNotEqual(archiveSidecarSibling(Data([46, 95, 255])), Data("\u{fffd}".utf8))
    }
    func assertSidecarEligibility(_ facts: ArchiveItemFacts, content: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(facts.containsRealAppleDouble, content, file: file, line: line)
        for format in ArchiveFormat.allCases {
            if content && format != .appleArchiveFast && format != .appleArchiveSmallest {
                guard case .unavailable(let reason) = formatSupports(format, itemFacts: facts) else {
                    XCTFail("Literal dot-underscore content must deny this format", file: file, line: line); continue
                }
                XCTAssertFalse(reason.isEmpty, file: file, line: line)
            } else { XCTAssertEqual(formatSupports(format, itemFacts: facts), .available, file: file, line: line) }
        }
    }
    func test_sidecar_directory_children_are_content() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item"), child = item.appendingPathComponent("._foo/nested/child")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("child".utf8).write(to: child); try Data("sibling".utf8).write(to: item.appendingPathComponent("foo"))
        var st = Darwin.stat(); XCTAssertEqual(lstat(item.appendingPathComponent("._foo").path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR)
        let raw = Data(item.path.utf8)
        for included in [false, true] {
            let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
            try synthetic(out, entries: [("item/foo", Data("sibling".utf8))] + (included ? [("item/._foo/nested/child", Data("child".utf8))] : []),
                directories: ["item", "item/._foo", "item/._foo/nested"])
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            for flags: UInt32 in [0, 1] {
                let scan = try ArchiveTree.scan(raw, hashFiles: true, flags: flags)
                XCTAssertEqual(scan.entries.count, 5); assertSidecarEligibility(scan.facts, content: true)
                let verdict = verifyAppleArchive(fd: fd, item: raw, flags: flags)
                if included { XCTAssertEqual(verdict, ArchiveVerdict(files: 2, dirs: 3, bytes: 12)) }
                else { XCTAssertEqual(verdict.code, 1); XCTAssertEqual(verdict.firstBadPath, Data("item/._foo/nested/child".utf8)) }
            }
        }
    }
    func test_sidecar_symlinks_are_content() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item"), data = Data([0, 5, 22, 7, 100, 97, 116, 97])
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try data.write(to: item.appendingPathComponent("x"))
        XCTAssertEqual(symlink("x", item.appendingPathComponent("._x").path), 0)
        var st = Darwin.stat(); XCTAssertEqual(lstat(item.appendingPathComponent("._x").path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK)
        let good = f.root.appendingPathComponent("good.aar"), missing = f.root.appendingPathComponent("missing.aar")
        try make(item, good, .lzfse); try synthetic(missing, entries: [("item/x", data)], directories: ["item"])
        for (out, included) in [(good, true), (missing, false)] {
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            for flags: UInt32 in [0, 1] {
                let scan = try ArchiveTree.scan(Data(item.path.utf8), hashFiles: true, flags: flags)
                XCTAssertEqual(scan.entries[Data("item/._x".utf8)], .link(Data("x".utf8)))
                assertSidecarEligibility(scan.facts, content: true)
                let verdict = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: flags)
                if included { XCTAssertEqual(verdict, ArchiveVerdict(files: 1, dirs: 1, links: 1, bytes: 8)) }
                else { XCTAssertEqual(verdict.code, 1); XCTAssertEqual(verdict.firstBadPath, Data("item/._x".utf8)) }
            }
        }
    }
    func test_sidecar_magic_size_and_sibling_are_required() throws {
        let f = DiskImageFixture(); try f.setUp(size: "256m"); defer { XCTAssertNoThrow(try f.tearDown()) }
        // Shared verbatim capture from the disposable FAT image used for the T8-R7 probe.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("crates/tesserae-core/tests/fixtures/macos-fat-appledouble.bin")
        let measured = try Data(contentsOf: fixture)
        XCTAssertEqual(measured.count, 4096); XCTAssertEqual(measured.prefix(8), sidecarHeader.prefix(8))
        XCTAssertEqual(measured.subdata(in: 8..<24), Data("Mac OS X        ".utf8))
        var cases: [(Data, Bool, Bool, Bool)] = [(Data("content!".utf8), true, true, false),
            (Data([0, 5, 22]), true, true, false), (Data([0, 5, 22, 7]) + Data("data".utf8), true, true, false),
            (measured, true, true, true)]
        for header in [sidecarHeader, Data(measured.prefix(24))] {
            cases += [(header, true, false, false), (header, true, true, true), (header, false, true, false),
                (header + Data(repeating: 0, count: 16 * 1024 * 1024 - 24), true, true, true),
                (header + Data(repeating: 0, count: 16 * 1024 * 1024 - 23), true, true, false)]
            for index in 0..<24 {
                var bytes = header; bytes[index] ^= 1
                cases.append((bytes, true, true, false))
            }
        }
        for (bytes, paired, hidden, excluded) in cases {
            let item = f.root.appendingPathComponent(UUID().uuidString), rawName = item.lastPathComponent
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
            if paired { try Data("sibling".utf8).write(to: item.appendingPathComponent("x")) }
            try bytes.write(to: item.appendingPathComponent("._x"))
            XCTAssertEqual(chflags(item.appendingPathComponent("._x").path, hidden ? UInt32(UF_HIDDEN) : 0), 0)
            var st = Darwin.stat(); XCTAssertEqual(lstat(item.appendingPathComponent("._x").path, &st), 0)
            XCTAssertEqual(st.st_mode & S_IFMT, S_IFREG); XCTAssertEqual(st.st_size, Int64(bytes.count))
            XCTAssertEqual(st.st_flags & UInt32(UF_HIDDEN) != 0, hidden)
            XCTAssertEqual(FileManager.default.fileExists(atPath: item.appendingPathComponent("x").path), paired)
            for included in [false, true] {
                let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
                try synthetic(out, entries: (paired ? [(rawName + "/x", Data("sibling".utf8))] : []) +
                    (included ? [(rawName + "/._x", bytes)] : []), directories: [rawName])
                let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
                for flags: UInt32 in [0, 1, 2] {
                    let ignored = excluded && flags == 1
                    let scan = try ArchiveTree.scan(Data(item.path.utf8), hashFiles: true, flags: flags)
                    assertSidecarEligibility(scan.facts, content: !ignored)
                    let verdict = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: flags)
                    if included || ignored {
                        XCTAssertEqual(verdict, ArchiveVerdict(files: (paired ? 1 : 0) + (ignored ? 0 : 1), dirs: 1,
                            bytes: (paired ? 7 : 0) + (ignored ? 0 : UInt64(bytes.count))))
                    } else { XCTAssertEqual(verdict.code, 1); XCTAssertEqual(verdict.firstBadPath, Data((rawName + "/._x").utf8)) }
                }
            }
        }
    }
    func test_excluded_sidecar_collisions_are_refused_without_exact_member() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        for (real, extra) in [("._x", "._X"), ("._cafe\u{301}", "._café")] {
            let item = f.root.appendingPathComponent(UUID().uuidString), root = item.lastPathComponent
            try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
            try writeSidecar(item.appendingPathComponent(real))
            try Data("sibling".utf8).write(to: item.appendingPathComponent(String(real.dropFirst(2))))
            let actual = try ArchiveTree.scan(Data(item.path.utf8), hashFiles: true).entries.keys.first { archiveMetadataPath($0) }
            XCTAssertEqual(actual, Data((root + "/" + real).utf8)); XCTAssertNotEqual(Data(real.utf8), Data(extra.utf8))
            let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
            try synthetic(out, entries: [(root + "/" + String(real.dropFirst(2)), Data("sibling".utf8)),
                (root + "/" + extra, Data("hostile".utf8))], directories: [root])
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            for flags: UInt32 in [0, 1] {
                let verdict = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: flags)
                XCTAssertEqual(verdict.code, 2); XCTAssertEqual(verdict.firstBadPath, Data((root + "/" + extra).utf8))
            }
        }
    }
    func test_flagged_paired_sidecars_present_or_omitted_and_orphans_verified() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item"), data = Data("content".utf8)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try data.write(to: item.appendingPathComponent("data"))
        try writeSidecar(item.appendingPathComponent("._data"), body: data)
        for included in [false, true] {
            let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
            try synthetic(out, entries: [("item/data", data)] + (included ? [("item/._data", Data("different".utf8))] : []), directories: ["item"])
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            let native = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: 0)
            XCTAssertEqual(native.code, included ? 3 : 1)
            let flagged = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: 1)
            XCTAssertEqual(flagged, ArchiveVerdict(files: 1, dirs: 1, bytes: 7))
        }
        for mode in [AppleArchiveCompression.lzfse, .lzma] {
            let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
            try make(item, out, mode)
            let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            XCTAssertEqual(verifyAppleArchive(fd: fd, item: Data(item.path.utf8)), ArchiveVerdict(files: 2, dirs: 1, bytes: 38))
            XCTAssertEqual(verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: 1), ArchiveVerdict(files: 1, dirs: 1, bytes: 7))
        }
        let orphan = item.appendingPathComponent("._orphan")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.appendingPathComponent("orphan").path))
        try data.write(to: orphan)
        let out = f.root.appendingPathComponent("orphan.aar")
        try synthetic(out, entries: [("item/data", data)], directories: ["item"])
        let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        let missing = verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: 1)
        XCTAssertEqual(missing.code, 1); XCTAssertEqual(missing.firstBadPath, Data("item/._orphan".utf8))
        let kept = f.root.appendingPathComponent("kept.aar")
        try synthetic(kept, entries: [("item/data", data), ("item/._orphan", data)], directories: ["item"])
        let keptFD = open(kept.path, O_RDONLY); XCTAssertGreaterThanOrEqual(keptFD, 0); defer { close(keptFD) }
        XCTAssertEqual(verifyAppleArchive(fd: keptFD, item: Data(item.path.utf8), flags: 1), ArchiveVerdict(files: 2, dirs: 1, bytes: 14))
        try Data("changed".utf8).write(to: orphan)
        XCTAssertEqual(verifyAppleArchive(fd: keptFD, item: Data(item.path.utf8), flags: 1).code, 4)
    }
    func test_archive_verification_flags_use_explicit_allowlist() {
        for known in ["exfat", "msdos", "smbfs", "afpfs", "nfs", "webdav", "ntfs"] {
            XCTAssertEqual(archiveVerificationFlags(volumeFSType: known), 1, known)
        }
        for other in ["apfs", "hfs", "unknown-fs", "", "APFS", "fusefs_unmeasured", "ufsd_NTFS"] {
            XCTAssertEqual(archiveVerificationFlags(volumeFSType: other), 0, other)
        }
    }
    func test_production_verifiers_and_inspection_select_volume_flags() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item"), data = Data("content".utf8)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        try data.write(to: item.appendingPathComponent("data"))
        let raw = Data(item.path.utf8)
        XCTAssertEqual(try archiveVerificationFlags(raw), 0, "disposable APFS volume")
        for native in ["apfs", "hfs", "unknown-fs", "", "APFS", "fusefs_unmeasured"] { XCTAssertEqual(archiveVerificationFlags(volumeFSType: native), 0) }
        for foreign in ["exfat", "msdos", "smbfs", "afpfs", "nfs", "webdav", "ntfs"] { XCTAssertEqual(archiveVerificationFlags(volumeFSType: foreign), 1) }
        // Write each real format before materializing the emulated exFAT sidecar.
        for format in ArchiveFormat.allCases {
            let out = f.root.appendingPathComponent(UUID().uuidString + "." + format.fileExtension)
            let fd = open(out.path, O_CREAT | O_EXCL | O_RDWR, 0o644); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            let result = await ProductionArchiveRunner().run(item: raw, format: format, to: fd)
            XCTAssertEqual(result, 0)
            let sidecar = item.appendingPathComponent("._data")
            try writeSidecar(sidecar, body: data)
            let native = ProductionArchiveVerifier().verify(fd: fd, path: Data(out.path.utf8), format: format, item: raw)
            // The two tar writers emit a generated ._data member even on APFS;
            // it mismatches the later literal sidecar rather than being absent.
            XCTAssertEqual(native.code, format == .tarXZ || format == .tarZst ? 3 : 1)
            let verifier = ProductionArchiveVerifier(verificationFlags: { _ = try archiveParts($0); return archiveVerificationFlags(volumeFSType: "exfat") })
            XCTAssertEqual(verifier.verify(fd: fd, path: Data(out.path.utf8), format: format, item: raw), ArchiveVerdict(files: 1, dirs: 1, bytes: 7))
            let foreign = try ProductionArchiveFileSystem(verificationFlags: { _ in 1 }).inspect(raw)
            XCTAssertFalse(foreign.facts.containsRealAppleDouble); XCTAssertEqual(foreign.files.count, 1)
            XCTAssertTrue(try ProductionArchiveFileSystem().inspect(raw).facts.containsRealAppleDouble)
            // Move test content into a retained fixture folder, never delete it.
            let retained = f.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: sidecar, to: retained)
        }
        let broken = ProductionArchiveVerifier(verificationFlags: { _ in throw archiveError(EIO) })
        XCTAssertEqual(broken.verify(fd: -1, path: Data(), format: .zip, item: raw).code, 7)
        XCTAssertThrowsError(try ProductionArchiveFileSystem(verificationFlags: { _ in throw archiveError(EIO) }).inspect(raw))
    }
    func test_flagged_sidecars_keep_duplicate_and_collision_guards() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item"), data = sidecarHeader + Data("data".utf8)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        for (real, other) in [("._x", "._X"), ("._cafe\u{301}", "._café")] {
            try writeSidecar(item.appendingPathComponent(real), body: Data("data".utf8))
            // Without a sibling, collisions must be caught against the manifest in either order.
            for paired in [false, true] {
                if paired { try data.write(to: item.appendingPathComponent(String(real.dropFirst(2)))) }
                for (names, code) in [([real, real], Int32(10)), ([real, other], 2), ([other, real], 2)] {
                    let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
                    var entries = try ArchiveTree.scan(Data(item.path.utf8), hashFiles: false).entries.keys
                        .filter { $0 != Data("item".utf8) && !$0.split(separator: 47).last!.starts(with: Data("._".utf8)) }
                        .map { (String(decoding: $0, as: UTF8.self), data) }
                    entries += names.map { ("item/" + $0, data) }
                    try synthetic(out, entries: entries, directories: ["item"])
                    let fd = open(out.path, O_RDONLY); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
                    XCTAssertEqual(verifyAppleArchive(fd: fd, item: Data(item.path.utf8), flags: 1).code, code, "\(names) paired=\(paired)")
                }
            }
        }
    }
    func test_flagged_scan_classifies_siblings_for_format_eligibility() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("item")
        try FileManager.default.createDirectory(at: item.appendingPathComponent("directory"), withIntermediateDirectories: true)
        XCTAssertEqual(symlink("missing", item.appendingPathComponent("link").path), 0)
        for name in ["._directory", "._link"] { try writeSidecar(item.appendingPathComponent(name)) }
        let raw = Data(item.path.utf8)
        let native = try ArchiveTree.scan(raw, hashFiles: true)
        XCTAssertTrue(native.facts.containsRealAppleDouble); XCTAssertEqual(native.files.count, 2)
        let flagged = try ArchiveTree.scan(raw, hashFiles: true, flags: 1)
        XCTAssertFalse(flagged.facts.containsRealAppleDouble); XCTAssertTrue(flagged.files.isEmpty)
        XCTAssertEqual(flagged.entries.count, 3); XCTAssertEqual(flagged.stamps.count, 5)
        for format in ArchiveFormat.allCases {
            XCTAssertEqual(formatSupports(format, itemFacts: flagged.facts), .available)
            if format == .zip || format == .tarXZ || format == .tarZst {
                guard case .unavailable(let reason) = formatSupports(format, itemFacts: native.facts) else { return XCTFail("Native ._ content must be protected") }
                XCTAssertFalse(reason.isEmpty)
            }
        }
        try Data("real".utf8).write(to: item.appendingPathComponent("._orphan"))
        let orphan = try ArchiveTree.scan(raw, hashFiles: true, flags: 1)
        XCTAssertTrue(orphan.facts.containsRealAppleDouble); XCTAssertEqual(orphan.files.count, 1)
        for format in ArchiveFormat.allCases {
            if format == .appleArchiveFast || format == .appleArchiveSmallest { XCTAssertEqual(formatSupports(format, itemFacts: orphan.facts), .available) }
            else { guard case .unavailable(let reason) = formatSupports(format, itemFacts: orphan.facts) else { return XCTFail("Orphan must deny this format") }; XCTAssertFalse(reason.isEmpty) }
        }
        let sidecar = Data(item.appendingPathComponent("._directory").path.utf8)
        XCTAssertTrue(try ArchiveTree.scan(sidecar, hashFiles: true, flags: 1).entries.isEmpty)
    }
    func test_lone_sidecar_item_is_denied_archive_with_catalogued_reason() throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let sibling = f.root.appendingPathComponent("x"), sidecar = f.root.appendingPathComponent("._x")
        try Data("sibling".utf8).write(to: sibling); try writeSidecar(sidecar)
        let raw = Data(sidecar.path.utf8)
        for flags: UInt32 in [0, 1, 2] {
            let inspection = try ProductionArchiveFileSystem(verificationFlags: { _ in flags }).inspect(raw)
            XCTAssertEqual(inspection.facts.isSidecar, flags == 1)
            XCTAssertEqual(inspection.files.count, flags == 1 ? 0 : 1)
            let stamp = try XCTUnwrap(inspection.stamps[raw])
            let item = ReclaimItem(nodeIndex: 1, path: raw, recorded: stamp.recorded,
                recordedSize: stamp.size, verdict: .ok, archiveFacts: inspection.facts)
            let actions = availableActions(for: item,
                volume: VolumeCapabilities(isLocal: true, isWritable: true, fsType: "exfat"), verdict: .ok)
            XCTAssertEqual(actions[.trash], .available)
            for format in ArchiveFormat.allCases {
                let support = formatSupports(format, itemFacts: inspection.facts)
                XCTAssertEqual(actions[.archive(format)], support)
                if flags == 1 {
                    XCTAssertEqual(support, .unavailable("This item is a macOS metadata sidecar. Archive its sibling instead."))
                } else if format == .appleArchiveFast || format == .appleArchiveSmallest {
                    XCTAssertEqual(support, .available)
                }
            }
        }
    }
    func test_aar_duplicate_and_metadata_collision_rules() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("._data"), content = Data("literal".utf8); try content.write(to: item)
        for (names, expected) in [(["._data", "._data"], Int32(10)), (["._DATA", "._data"], 2),
                                  (["._data", "._DATA"], 2), (["._data", "__MACOSX/._sidecar"], 0),
                                  (["._data", "extra"], 2), (["._data", "../._sidecar"], 8)] {
            let out = f.root.appendingPathComponent(UUID().uuidString + ".aar")
            try synthetic(out, entries: names.map { ($0, content) })
            XCTAssertEqual(try verify(out, item).code, expected, names.joined(separator: ","))
        }
        let unicode = f.root.appendingPathComponent("._café"); try content.write(to: unicode)
        let out = f.root.appendingPathComponent("unicode.aar")
        let actual = try XCTUnwrap(ArchiveTree.scan(Data(unicode.path.utf8), hashFiles: true).entries.keys.first)
        XCTAssertNotEqual(actual, Data("._café".utf8), "APFS stores the other normalization")
        try synthetic(out, entries: [("._café", content)])
        XCTAssertEqual(try verify(out, unicode).code, 2)
        XCTAssertEqual(archiveCollisionKey(Data([46, 95, 65, 255])), Data([46, 95, 97, 255]))
    }
    func test_aar_rejects_embedded_nul_and_unresolved_hardlink() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("x"); try Data().write(to: item)
        let nul = f.root.appendingPathComponent("nul.aar"), hardlink = f.root.appendingPathComponent("hardlink.aar")
        try synthetic(nul, entries: [("x\0tail", Data())])
        try synthetic(hardlink, entries: [("x", Data())], omitData: true, hardlink: 42)
        XCTAssertEqual(try verify(nul, item).code, 8)
        XCTAssertEqual(try verify(hardlink, item).code, 8)
    }
    func test_regular_file_root_all_formats_verifies() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("file\nname"); try Data("contents".utf8).write(to: item)
        XCTAssertEqual(ArchiveFormat.allCases.count, 5)
        for format in ArchiveFormat.allCases {
            let archive = f.root.appendingPathComponent(format.rawValue + ".archive")
            let fd = open(archive.path, O_CREAT | O_EXCL | O_WRONLY, 0o644); guard fd >= 0 else { throw archiveError(errno) }
            let status = await ProductionArchiveRunner().run(item: Data(item.path.utf8), format: format, to: fd); close(fd)
            XCTAssertEqual(status, 0, format.rawValue)
            let reader = open(archive.path, O_RDONLY); guard reader >= 0 else { throw archiveError(errno) }; defer { close(reader) }
            XCTAssertEqual(ProductionArchiveVerifier().verify(fd: reader, path: Data(archive.path.utf8), format: format, item: Data(item.path.utf8)),
                ArchiveVerdict(files: 1, bytes: 8), format.rawValue)
        }
    }
    func test_aar_cluster_members_must_restore_identical_content() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let tree = f.root.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
        try Data("AA".utf8).write(to: tree.appendingPathComponent("a")); try Data("BB".utf8).write(to: tree.appendingPathComponent("b"))
        let entries = [("tree/a", Data("AA".utf8)), ("tree/b", Data("BB".utf8))]
        let valid = f.root.appendingPathComponent("valid.aar"); try synthetic(valid, entries: entries, directories: ["tree"])
        XCTAssertEqual(try verify(valid, tree), ArchiveVerdict(files: 2, dirs: 1, bytes: 4))
        for key in ["HLC", "CLC", "SLC"] {
            let archive = f.root.appendingPathComponent(key + ".aar")
            try synthetic(archive, entries: entries, hardlink: 42, clusterKey: key, directories: ["tree"])
            XCTAssertEqual(try verify(archive, tree).code, 8, key)
        }
    }
    func test_aar_ignored_metadata_cannot_supply_a_real_cluster() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("data"); try Data("BB".utf8).write(to: item)
        for key in ["HLC", "CLC", "SLC"] {
            let archive = f.root.appendingPathComponent(key + ".aar")
            try synthetic(archive, entries: [("__MACOSX/._unused", Data("AA".utf8)), ("data", Data("BB".utf8))], hardlink: 42, clusterKey: key)
            XCTAssertEqual(try verify(archive, item).code, 2, key)
        }
    }
    func test_aar_duplicate_header_fields_are_corrupt() async throws {
        let f = DiskImageFixture(); try f.setUp(); defer { XCTAssertNoThrow(try f.tearDown()) }
        let item = f.root.appendingPathComponent("x"); try Data("BB".utf8).write(to: item)
        let archive = f.root.appendingPathComponent("duplicate.aar")
        try synthetic(archive, entries: [("x", Data("AA".utf8))], duplicateData: Data("BB".utf8))
        XCTAssertEqual(try verify(archive, item).code, 8)
    }
    func test_aar_truncated_archive_fails() async throws {
        try await withTree { root, tree in
            let archive = root.appendingPathComponent("tree.aar"); try self.make(tree, archive, .lzfse)
            let bytes = try Data(contentsOf: archive); XCTAssertGreaterThan(bytes.count, 50)
            try bytes.prefix(bytes.count / 2).write(to: archive)
            XCTAssertNotEqual(try self.verify(archive, tree).code, 0)
        }
    }
}
