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

// Measured 2026-10-21 on a temporary HFS+ and APFS .dmgs, attached with hdiutil:
// kDADiskDescriptionDeviceProtocolKey (DADeviceProtocol) = "Virtual Interface";
// kDADiskDescriptionDeviceModelKey (DADeviceModel) = "Disk Image".
// diskutil info displays Protocol: Disk Image. Both DA keys are checked.
// SDK: DADisk.h declares both keys as CFString; NSURL.h declares
// NSURLVolumeIsBrowsableKey (GUI visibility, macOS 10.7+). Neither header
// declares a Time Machine volume key; NSURLIsExcludedFromBackupKey concerns
// backup exclusion of a resource, not whether a volume is a backup destination.
// Time Machine filtering therefore also uses Backups.backupdb/.timemachine paths.

import XCTest
import AppKit
@testable import TesseraeKit

final class VolumeListTests: XCTestCase {
    private let startup = URL(fileURLWithPath: "/")
    private func raw(_ path: String, name: String = "Disk", local: Bool = true,
                     browsable: Bool = true, hidden: Bool = false,
                     image: Bool = false, backup: Bool = false,
                     total: Int64? = 100, free: Int64? = 40) -> RawVolume {
        RawVolume(url: URL(fileURLWithPath: path), name: name, local: local,
                  browsable: browsable, hidden: hidden, readOnly: false, typeName: "apfs",
                  isDiskImage: image, isTimeMachine: backup, total: total, free: free)
    }
    func test_startup_disk_is_this_mac_and_first() throws {
        let result = classify([raw("/Volumes/Alpha"), raw("/", name: "Studio SSD")], startupMount: startup)
        XCTAssertEqual(result.count, 2)
        let first = try XCTUnwrap(result.first)
        XCTAssertEqual(first.name, "Studio SSD")
        XCTAssertTrue(first.isStartup)
        XCTAssertEqual(first.group, .thisMac)
        XCTAssertEqual(result[1].group, .otherDisks)
    }
    func test_excludes_hidden_system_volumes_disk_images_time_machine_and_unbrowsable() {
        let inputs = [raw("/"), raw("/System/Volumes/Data"), raw("/System/Volumes/Preboot"),
                      raw("/Volumes/Hidden", hidden: true), raw("/Volumes/Image", image: true),
                      raw("/Volumes/Backup", backup: true), raw("/Volumes/Invisible", browsable: false)]
        XCTAssertEqual(inputs.count, 7)
        XCTAssertEqual(classify(inputs, startupMount: startup).map(\.url.path), ["/"])
    }
    func test_network_volumes_group_last() {
        let result = classify([raw("/Volumes/A network", local: false), raw("/Volumes/Z local"), raw("/")], startupMount: startup)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.group), [.thisMac, .otherDisks, .network])
    }
    func test_capacity_failure_keeps_volume_with_nil_sizes() throws {
        let result = classify([raw("/Volumes/Offline", local: false, total: nil, free: nil)], startupMount: startup)
        XCTAssertEqual(result.count, 1)
        let volume = try XCTUnwrap(result.first)
        XCTAssertNil(volume.total)
        XCTAssertNil(volume.free)
    }
    func test_filesystem_display_names() {
        let types = ["apfs", "hfs", "exfat", "msdos", "ntfs", "ufsd_NTFS", "smbfs", "afpfs", "nfs", "futurefs"]
        XCTAssertEqual(types.map(filesystemDisplayName),
                       ["APFS", "Mac OS Extended", "exFAT", "MS-DOS (FAT)", "NTFS", "NTFS", "SMB", "AFP", "NFS", "futurefs"])
    }
    func test_measured_image_keys_and_backup_conventions() {
        XCTAssertTrue(isDiskImage(protocolName: "Virtual Interface", model: "Disk Image"))
        XCTAssertTrue(isDiskImage(protocolName: "Disk Image", model: nil))
        XCTAssertFalse(isDiskImage(protocolName: "USB", model: "External SSD"))
        for path in ["/Volumes/Backups.backupdb", "/Volumes/.timemachine/host/backup", "/Volumes/Backup/Backups.backupdb"] {
            XCTAssertTrue(isTimeMachineMount(URL(fileURLWithPath: path)))
        }
        XCTAssertFalse(isTimeMachineMount(URL(fileURLWithPath: "/Volumes/My backup")))
    }
    @MainActor
    func test_stale_refresh_is_dropped() async {
        let source = ControlledVolumes()
        let model = VolumeListModel(source: source, startupMount: startup)
        let old = Task { await model.refresh() }
        await source.waitForRequests(1)
        let newer = Task { await model.refresh() }
        await source.waitForRequests(2)
        await source.complete(1, with: [raw("/Volumes/New")])
        await newer.value
        XCTAssertEqual(model.volumes.map(\.url.path), ["/Volumes/New"])
        await source.complete(0, with: [raw("/Volumes/Old")])
        await old.value
        XCTAssertEqual(model.volumes.map(\.url.path), ["/Volumes/New"])
    }
    @MainActor
    func test_cancelled_refresh_does_not_invalidate_current_refresh() async {
        let source = ControlledVolumes(laterReply: [])
        let model = VolumeListModel(source: source, startupMount: startup)
        let current = Task { await model.refresh() }
        await source.waitForRequests(1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refresh()
        }
        await cancelled.value
        await source.complete(0, with: [raw("/Volumes/Current")])
        await current.value
        XCTAssertEqual(model.volumes.map(\.url.path), ["/Volumes/Current"])
    }
    @MainActor
    func test_stop_invalidates_pending_refresh_and_notifications_restart() async {
        let source = ControlledVolumes()
        let center = NotificationCenter()
        let model = VolumeListModel(source: source, startupMount: startup, notifications: center)
        model.start()
        await source.waitForRequests(1)
        model.stop()
        await source.complete(0, with: [raw("/Volumes/Stale")])
        await model.waitForRefresh()
        XCTAssertTrue(model.volumes.isEmpty)
        model.start()
        await source.waitForRequests(2)
        await source.complete(1, with: [raw("/Volumes/First")])
        await model.waitForRefresh()
        XCTAssertEqual(model.volumes.count, 1)
        for (index, event) in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification].enumerated() {
            center.post(name: event, object: nil)
            await source.waitForRequests(index + 3)
            await source.complete(index + 2, with: [raw("/Volumes/Changed\(index)")])
            await model.waitForRefresh()
            XCTAssertEqual(model.volumes.first?.url.path, "/Volumes/Changed\(index)")
        }
        model.stop()
    }
    @MainActor
    func test_capacity_deadline_returns_without_waiting_for_blocked_reader() async {
        let blocked = DispatchSemaphore(value: 0)
        let entered = expectation(description: "reader entered")
        let finished = expectation(description: "reader released")
        // Rescue a deliberately broken deadline during mutation verification.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { blocked.signal() }
        let start = ContinuousClock.now
        let result: Int? = await volumeRead(deadline: .milliseconds(50), fallback: nil) {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            blocked.wait()
            finished.fulfill()
            return 99
        }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        blocked.signal()
        await fulfillment(of: [entered, finished], timeout: 2)
        let success: Int? = await volumeRead(deadline: .seconds(2), fallback: nil) { 42 }
        XCTAssertEqual(success, 42)
    }
}

private actor ControlledVolumes: VolumeSource {
    private var pending: [CheckedContinuation<[RawVolume], Never>] = []
    private let laterReply: [RawVolume]?
    init(laterReply: [RawVolume]? = nil) { self.laterReply = laterReply }
    func mounted() async -> [RawVolume] {
        if !pending.isEmpty, let laterReply { return laterReply }
        return await withCheckedContinuation { pending.append($0) }
    }
    func waitForRequests(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while pending.count < count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThanOrEqual(pending.count, count, "refresh request must arrive")
    }
    func complete(_ index: Int, with volumes: [RawVolume]) {
        guard pending.indices.contains(index) else { XCTFail("missing refresh request"); return }
        pending[index].resume(returning: volumes)
    }
}
