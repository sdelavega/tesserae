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

import AppKit
import Combine
import Foundation

public enum VolumeGroup: Int, CaseIterable, Sendable {
    case thisMac, otherDisks, network
}

public struct VolumeInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let group: VolumeGroup
    public let filesystem: String
    public let total: Int64?
    public let free: Int64?
    public let isStartup: Bool
}

public func classify(_ raw: [RawVolume], startupMount: URL) -> [VolumeInfo] {
    raw.compactMap { volume -> VolumeInfo? in
        let path = volume.url.standardizedFileURL.path
        guard !volume.hidden, volume.browsable, !volume.isDiskImage, !volume.isTimeMachine,
              path != "/System/Volumes", !path.hasPrefix("/System/Volumes/") else { return nil }
        let startup = path == startupMount.standardizedFileURL.path
        return VolumeInfo(id: volume.uuid ?? path, url: volume.url,
                          name: Snapshot.displayName(bytes: Data(volume.name.utf8)),
                          group: startup ? .thisMac : (volume.local ? .otherDisks : .network),
                          filesystem: filesystemDisplayName(volume.typeName), total: volume.total,
                          free: volume.free, isStartup: startup)
    }.sorted {
        if $0.group != $1.group { return $0.group.rawValue < $1.group.rawValue }
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
}

public func filesystemDisplayName(_ type: String) -> String {
    switch type.lowercased() {
    case "apfs": return String(localized: "volume.filesystem.apfs", defaultValue: "APFS",
                               bundle: L10n.bundle, comment: "Display name of the APFS filesystem.")
    case "hfs": return String(localized: "volume.filesystem.hfs", defaultValue: "Mac OS Extended",
                               bundle: L10n.bundle, comment: "Display name of the Mac OS Extended filesystem.")
    case "exfat": return String(localized: "volume.filesystem.exfat", defaultValue: "exFAT",
                               bundle: L10n.bundle, comment: "Display name of the exFAT filesystem.")
    case "msdos": return String(localized: "volume.filesystem.msdos", defaultValue: "MS-DOS (FAT)",
                               bundle: L10n.bundle, comment: "Display name of the MS-DOS (FAT) filesystem.")
    case "ntfs", "ufsd_ntfs": return String(localized: "volume.filesystem.ntfs", defaultValue: "NTFS",
                               bundle: L10n.bundle, comment: "Display name of the NTFS filesystem.")
    case "smbfs": return String(localized: "volume.filesystem.smb", defaultValue: "SMB",
                               bundle: L10n.bundle, comment: "Display name of the SMB filesystem.")
    case "afpfs": return String(localized: "volume.filesystem.afp", defaultValue: "AFP",
                               bundle: L10n.bundle, comment: "Display name of the AFP filesystem.")
    case "nfs": return String(localized: "volume.filesystem.nfs", defaultValue: "NFS",
                               bundle: L10n.bundle, comment: "Display name of the NFS filesystem.")
    default: return type
    }
}

@MainActor
public final class VolumeListModel: ObservableObject {
    @Published public private(set) var volumes: [VolumeInfo] = []
    private let source: any VolumeSource
    private let startupMount: URL
    private let notifications: NotificationCenter
    private var observers: Set<AnyCancellable> = []
    private var active = false
    private var generation: UInt64 = 0
    private var refreshTask: Task<Void, Never>?

    public init(source: any VolumeSource = MountedVolumeSource(),
                startupMount: URL = URL(fileURLWithPath: "/"),
                notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.source = source
        self.startupMount = startupMount
        self.notifications = notifications
    }

    public func start() {
        guard !active else { return }
        active = true
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            notifications.publisher(for: name).sink { [weak self] _ in
                // Workspace notifications can arrive outside the main actor.
                Task { @MainActor [weak self] in self?.requestRefresh() }
            }.store(in: &observers)
        }
        requestRefresh()
    }

    public func stop() {
        active = false
        observers.removeAll()
        generation &+= 1
        refreshTask?.cancel()
    }

    private func requestRefresh() {
        guard active else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let requested = generation
        let source = source
        let work = Task.detached(priority: .utility) { await source.mounted() }
        let raw = await work.value
        guard requested == generation, !Task.isCancelled else { return }
        volumes = classify(raw, startupMount: startupMount)
    }

    func waitForRefresh() async { await refreshTask?.value }
    deinit { refreshTask?.cancel() }
}
