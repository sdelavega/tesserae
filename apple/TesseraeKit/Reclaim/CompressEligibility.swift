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

public struct FileKey: Hashable, Sendable {
    public let dev: Int32
    public let ino: UInt64
    public init(dev: Int32, ino: UInt64) { self.dev = dev; self.ino = ino }
}

public struct FileFacts: Sendable {
    public let isRegular: Bool
    public let flags: UInt32
    public let nlink: UInt64
    public let size, blocks: UInt64
    public let hasResourceFork, writable: Bool
    public let key: FileKey

    public init(isRegular: Bool = true, flags: UInt32 = 0, nlink: UInt64 = 1,
                size: UInt64 = 512, blocks: UInt64 = 1, hasResourceFork: Bool = false,
                writable: Bool = true, key: FileKey = FileKey(dev: 0, ino: 0)) {
        self.isRegular = isRegular; self.flags = flags; self.nlink = nlink
        self.size = size; self.blocks = blocks; self.hasResourceFork = hasResourceFork
        self.writable = writable; self.key = key
    }
}

// The preparation/execution walker supplies fresh sidecar and receipt evidence.
// No filesystem reads occur while evaluating this policy.
public struct EligibilityContext: Sendable {
    public let openForWriting: Set<FileKey>
    public let existingPaths: Set<Data>
    public init(openForWriting: Set<FileKey> = [], existingPaths: Set<Data> = []) {
        self.openForWriting = openForWriting; self.existingPaths = existingPaths
    }
}

public enum SkipReason: CaseIterable, Sendable {
    case notRegular, alreadyCompressed, hardLinked, sparse, cloudOnly, resourceFork, empty,
         wontShrink, liveDatabase, vmImage, cloudSync, storeOrAdobeApp, openForWriting, notWritable
}

func foldedComponents(_ path: Data) -> [Data] {
    path.split(separator: 47).map { Data($0.map { (65...90).contains($0) ? $0 + 32 : $0 }) }
}

private func fileExtension(_ component: Data) -> Data {
    guard let dot = component.lastIndex(of: 46) else { return Data() }
    return Data(component.suffix(from: component.index(after: dot)))
}

public func compressEligibility(path: Data, stat: FileFacts, context: EligibilityContext) -> SkipReason? {
    if !stat.isRegular { return .notRegular }
    if stat.flags & UInt32(UF_COMPRESSED) != 0 { return .alreadyCompressed }
    if stat.nlink > 1 { return .hardLinked }
    // Compare without multiplying a potentially overflowing block count.
    if stat.blocks < stat.size / 512 + (stat.size % 512 == 0 ? 0 : 1) { return .sparse }
    if stat.flags & UInt32(SF_DATALESS) != 0 { return .cloudOnly }
    if stat.hasResourceFork { return .resourceFork }
    if stat.size == 0 { return .empty }
    let parts = foldedComponents(path)
    let ext = fileExtension(parts.last ?? Data())
    let noShrink = "jpg jpeg png heic gif webp mp4 mov m4v mkv avi mp3 m4a aac flac zip gz bz2 xz 7z rar zst icns pdf"
        .split(separator: " ").map { Data($0.utf8) }
    if noShrink.contains(ext) { return .wontShrink }
    if ext == Data("realm".utf8) || (["sqlite", "sqlite3", "sqlitedb", "db"].map { Data($0.utf8) }.contains(ext)
        && ["-wal", "-shm"].contains(where: { context.existingPaths.contains(path + Data($0.utf8)) })) { return .liveDatabase }
    let vm = "vmdk qcow2 utm pvm vbox vdi hds vmwarevm sparsebundle dmg".split(separator: " ").map { Data($0.utf8) }
    if parts.contains(where: { vm.contains(fileExtension($0)) }) { return .vmImage }
    let syncNames = ["dropbox", "google drive", "my drive", "onedrive"].map { Data($0.utf8) }
    if parts.contains(where: { syncNames.contains($0) }) || zip(parts, parts.dropFirst()).contains(where: {
        $0.0 == Data("library".utf8) && [Data("mobile documents".utf8), Data("cloudstorage".utf8)].contains($0.1)
    }) { return .cloudSync }
    let raw = path.split(separator: 47).map { Data($0) }
    for index in parts.indices where fileExtension(parts[index]) == Data("app".utf8) {
        let name = parts[index].dropLast(4)
        let bundle = Data([47]) + raw[...index].joined(separator: Data([47]))
        if name.range(of: Data("adobe".utf8)) != nil || name == Data("creative cloud".utf8)
            || context.existingPaths.contains(bundle + Data("/Contents/_MASReceipt/receipt".utf8)) { return .storeOrAdobeApp }
    }
    if context.openForWriting.contains(stat.key) { return .openForWriting }
    if !stat.writable { return .notWritable }
    return nil
}

public extension SkipReason {
    var localizedDescription: String {
        switch self {
        case .notRegular: return String(localized: "compressSkip.notRegular", defaultValue: "Not a regular file.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: notRegular.")
        case .alreadyCompressed: return String(localized: "compressSkip.alreadyCompressed", defaultValue: "Already compressed.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: alreadyCompressed.")
        case .hardLinked: return String(localized: "compressSkip.hardLinked", defaultValue: "Hard-linked file.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: hardLinked.")
        case .sparse: return String(localized: "compressSkip.sparse", defaultValue: "Sparse file; compression would materialise it.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: sparse.")
        case .cloudOnly: return String(localized: "compressSkip.cloudOnly", defaultValue: "Cloud-only file; reading would download it.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: cloudOnly.")
        case .resourceFork: return String(localized: "compressSkip.resourceFork", defaultValue: "Has a non-empty resource fork.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: resourceFork.")
        case .empty: return String(localized: "compressSkip.empty", defaultValue: "Empty file.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: empty.")
        case .wontShrink: return String(localized: "compressSkip.wontShrink", defaultValue: "This file type is unlikely to shrink.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: wontShrink.")
        case .liveDatabase: return String(localized: "compressSkip.liveDatabase", defaultValue: "Live database or database with a journal sidecar.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: liveDatabase.")
        case .vmImage: return String(localized: "compressSkip.vmImage", defaultValue: "Virtual machine or disk image.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: vmImage.")
        case .cloudSync: return String(localized: "compressSkip.cloudSync", defaultValue: "Inside a cloud-sync folder.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: cloudSync.")
        case .storeOrAdobeApp: return String(localized: "compressSkip.storeOrAdobeApp", defaultValue: "Inside a Store or Adobe app.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: storeOrAdobeApp.")
        case .openForWriting: return String(localized: "compressSkip.openForWriting", defaultValue: "Open for writing.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: openForWriting.")
        case .notWritable: return String(localized: "compressSkip.notWritable", defaultValue: "The file or its directory isn't writable.",
            bundle: L10n.bundle, comment: "Why a file is excluded from in-place compression: notWritable.")
        }
    }
}
