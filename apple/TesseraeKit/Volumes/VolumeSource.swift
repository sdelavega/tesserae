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
import DiskArbitration
import Foundation

public struct RawVolume: Sendable {
    public let url: URL
    public let name: String
    public let uuid: String?
    public let local: Bool
    public let browsable: Bool
    public let hidden: Bool
    public let readOnly: Bool
    public let typeName: String
    public let isDiskImage: Bool
    public let isTimeMachine: Bool
    public let total: Int64?
    public let free: Int64?

    public init(url: URL, name: String, uuid: String? = nil, local: Bool, browsable: Bool,
                hidden: Bool, readOnly: Bool, typeName: String, isDiskImage: Bool,
                isTimeMachine: Bool, total: Int64?, free: Int64?) {
        self.url = url; self.name = name; self.uuid = uuid; self.local = local
        self.browsable = browsable; self.hidden = hidden; self.readOnly = readOnly
        self.typeName = typeName; self.isDiskImage = isDiskImage; self.isTimeMachine = isTimeMachine
        self.total = total; self.free = free
    }
}

public protocol VolumeSource: Sendable {
    func mounted() async -> [RawVolume]
}

func isDiskImage(protocolName: String?, model: String?) -> Bool {
    protocolName == "Disk Image" || model?.trimmingCharacters(in: .whitespaces) == "Disk Image"
}

func isTimeMachineMount(_ url: URL) -> Bool {
    url.pathComponents.contains("Backups.backupdb") || url.pathComponents.contains(".timemachine")
}

public struct MountedVolumeSource: VolumeSource {
    public init() {}

    public func mounted() async -> [RawVolume] {
        let mounts = await Task.detached(priority: .utility) { Self.mounts() }.value
        return await withTaskGroup(of: RawVolume.self) { group in
            for mount in mounts {
                group.addTask {
                    // Metadata can block too. Keep its reply as the capacity fallback
                    // so a slow size query cannot discard the name or exclusion flags.
                    let metadata = await volumeRead(deadline: .seconds(2), fallback: mount) { Self.metadata(mount) }
                    return await volumeRead(deadline: .seconds(2), fallback: metadata) { Self.capacity(metadata) }
                }
            }
            var result: [RawVolume] = []
            for await volume in group { result.append(volume) }
            return result
        }
    }

    private static func mounts() -> [RawVolume] {
        // MNT_NOWAIT reads the kernel's cached table without contacting servers.
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var mounts: [statfs] = .init(repeating: .init(), count: Int(count) + 8)
        let loaded = mounts.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard loaded > 0 else { return [] }
        var cached: [String: RawVolume] = [:]
        for index in 0..<min(Int(loaded), mounts.count) {
            var mount = mounts[index]
            let path = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let type = withUnsafePointer(to: &mount.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
            }
            let url = URL(fileURLWithPath: path)
            cached[path] = RawVolume(url: url, name: url.lastPathComponent,
                local: mount.f_flags & UInt32(MNT_LOCAL) != 0,
                browsable: mount.f_flags & UInt32(MNT_DONTBROWSE) == 0,
                hidden: false, readOnly: mount.f_flags & UInt32(MNT_RDONLY) != 0,
                typeName: type, isDiskImage: false, isTimeMachine: isTimeMachineMount(url), total: nil, free: nil)
        }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                        options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { cached[$0.standardizedFileURL.path] }
    }

    private static func metadata(_ mount: RawVolume) -> RawVolume {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeUUIDStringKey,
            .volumeIsLocalKey, .volumeIsBrowsableKey, .isHiddenKey, .volumeIsReadOnlyKey]
        let values = try? mount.url.resourceValues(forKeys: keys)
        var image = false
        if mount.local, let session = DASessionCreate(nil),
           let disk = DADiskCreateFromVolumePath(nil, session, mount.url as CFURL),
           let description = DADiskCopyDescription(disk) as? [String: Any] {
            image = isDiskImage(protocolName: description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
                                model: description[kDADiskDescriptionDeviceModelKey as String] as? String)
        }
        return RawVolume(url: mount.url, name: values?.volumeLocalizedName ?? mount.name,
            uuid: values?.volumeUUIDString, local: values?.volumeIsLocal ?? mount.local,
            browsable: values?.volumeIsBrowsable ?? mount.browsable, hidden: values?.isHidden ?? mount.hidden,
            readOnly: values?.volumeIsReadOnly ?? mount.readOnly, typeName: mount.typeName,
            isDiskImage: image, isTimeMachine: mount.isTimeMachine, total: nil, free: nil)
    }

    private static func capacity(_ volume: RawVolume) -> RawVolume {
        guard volume.browsable, !volume.hidden, !volume.isDiskImage, !volume.isTimeMachine,
              !volume.url.path.hasPrefix("/System/Volumes/") else { return volume }
        let sizes = try? volume.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return RawVolume(url: volume.url, name: volume.name, uuid: volume.uuid, local: volume.local,
            browsable: volume.browsable, hidden: volume.hidden, readOnly: volume.readOnly,
            typeName: volume.typeName, isDiskImage: volume.isDiskImage, isTimeMachine: volume.isTimeMachine,
            total: sizes?.volumeTotalCapacity.map(Int64.init), free: sizes?.volumeAvailableCapacity.map(Int64.init))
    }
}

// Structured task groups wait for cancelled children. A blocking filesystem call
// cannot cooperate, so race its reply against a dispatch deadline instead.
private final class VolumeReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) {
        lock.lock()
        let reply = continuation
        continuation = nil
        lock.unlock()
        reply?.resume(returning: value)
    }
}

private let volumeDeadlineQueue = DispatchQueue(label: "org.tesserae.volume-deadlines")

func volumeRead<Value: Sendable>(deadline: Duration, fallback: Value,
                                 read: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        let reply = VolumeReply(continuation)
        let parts = deadline.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        volumeDeadlineQueue.asyncAfter(deadline: .now() + seconds) { reply.finish(fallback) }
        DispatchQueue.global(qos: .utility).async { reply.finish(read()) }
    }
}
