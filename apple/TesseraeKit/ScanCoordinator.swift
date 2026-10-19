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
import TesseraeFFI

/// Counts and a rate, never a percentage: the total is unknown (spec §7).
public struct ScanProgress: Equatable, Sendable {
    public var dirs: UInt64
    public var files: UInt64
    public var bytes: UInt64
    public var errors: UInt64
    public var entriesPerSecond: Double

    public init(
        dirs: UInt64 = 0, files: UInt64 = 0, bytes: UInt64 = 0, errors: UInt64 = 0,
        entriesPerSecond: Double = 0
    ) {
        self.dirs = dirs
        self.files = files
        self.bytes = bytes
        self.errors = errors
        self.entriesPerSecond = entriesPerSecond
    }
}

public enum ScanState: Equatable {
    case idle
    case scanning(ScanProgress)
    case finished
    case failed(errno: Int32)
}

/// Owns one `TessScan*` and enforces the C ABI's threading contract (spec §6):
/// progress, cancel and status may be called from any thread while the scan
/// is live; `finish` consumes the handle and must not race any other call.
///
/// Every call takes `lock` and checks `consumed`. `finish` takes the lock to
/// wait out any call in flight, marks the handle consumed, and drops the lock
/// before the (possibly blocking) Rust call, so a later `progress` or
/// `cancel` finds `consumed` set and never touches the freed handle.
///
/// `@unchecked Sendable` is justified: the only stored state is the raw
/// pointer and `consumed`, and all access to both is serialised by `lock`.
final class ScanHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var scan: OpaquePointer?

    /// nil when `tess_scan_begin` refuses (invalid root, thread spawn failure).
    init?(root: String, options: TessScanOptions) {
        var opts = options
        guard let s = tess_scan_begin(root, &opts) else { return nil }
        scan = s
    }

    func progress() -> TessProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard let scan else { return nil }
        var p = TessProgress()
        tess_scan_progress(scan, &p)
        return p
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if let scan { tess_scan_cancel(scan) }
    }

    /// 0 running, 1 finished, negative errno failed; 1 once consumed.
    func status() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let scan else { return Int32(TESS_STATUS_FINISHED) }
        return tess_scan_status(scan)
    }

    /// Consume the handle. Call at most once, and only after `status()` is no
    /// longer running (or after `cancel()`), so it does not block long.
    func finish() -> Snapshot? {
        lock.lock()
        let s = scan
        scan = nil
        lock.unlock()
        guard let s, let snap = tess_scan_finish(s) else { return nil }
        return Snapshot(handle: snap)
    }
}

/// Drives a scan through the C ABI and publishes progress and the resulting
/// snapshot. Progress is polled at 10 Hz on the main actor; `finish` runs off
/// it, only after `status` has left "running".
@MainActor
public final class ScanCoordinator: ObservableObject {
    @Published public private(set) var state: ScanState = .idle
    @Published public private(set) var snapshot: Snapshot?

    /// Bumped by every start; a scan publishes only while its token is current.
    private var generation: UInt64 = 0
    private var current: ScanHandle?
    /// The latest scan's whole lifecycle, finish included.
    private var inFlight: Task<Void, Never>?

    private static let statusInterval: Duration = .milliseconds(10)
    /// Seconds between progress publications: 10 Hz (spec §7). Overridable
    /// by tests so a modest tree spans several ticks.
    private let progressInterval: Double

    public init() { progressInterval = 0.1 }

    init(progressInterval: Double) { self.progressInterval = progressInterval }

    /// Cancel and wait out any scan in flight, then scan `root`. Nothing from
    /// an earlier scan is published once this has been called.
    public func start(root: URL, options: TessScanOptions = .init()) {
        let previous = inFlight
        current?.cancel()
        current = nil
        generation &+= 1
        let gen = generation
        snapshot = nil
        state = .scanning(ScanProgress())

        // With nothing in flight, begin at once; otherwise begin only after the
        // previous scan has been finished and discarded.
        var handle: ScanHandle?
        if previous == nil {
            handle = beginScan(root: root, options: options)
            guard let h = handle else { return }
            current = h
        }
        inFlight = Task { @MainActor in
            await previous?.value
            if handle == nil {
                // Superseded or cancelled while waiting: never begin.
                guard self.generation == gen else { return }
                handle = self.beginScan(root: root, options: options)
                guard let h = handle else { return }
                self.current = h
            }
            // A begun scan is always run to its finish, even if superseded, so
            // its handle is consumed; `run` publishes nothing once stale.
            await self.run(handle!, generation: gen)
        }
    }

    /// Ask the running scan to stop. It still delivers its partial snapshot
    /// (spec §7); a scan still waiting to begin is abandoned.
    public func cancel() {
        if let current {
            current.cancel()
        } else if case .scanning = state {
            generation &+= 1
            state = .idle
        }
    }

    private func beginScan(root: URL, options: TessScanOptions) -> ScanHandle? {
        guard let h = ScanHandle(root: root.path, options: options) else {
            state = .failed(errno: EINVAL)
            return nil
        }
        return h
    }

    private func run(_ handle: ScanHandle, generation gen: UInt64) async {
        var lastAt = ContinuousClock.now
        var lastEntries: UInt64 = 0
        var status = handle.status()
        while status == Int32(TESS_STATUS_RUNNING) {
            try? await Task.sleep(for: Self.statusInterval)
            status = handle.status()
            let now = ContinuousClock.now
            let elapsed = (now - lastAt).seconds
            guard generation == gen, elapsed >= progressInterval,
                status == Int32(TESS_STATUS_RUNNING), let p = handle.progress()
            else { continue }
            let entries = p.dirs_done + p.files_done
            let rate = Double(entries &- lastEntries) / elapsed
            lastAt = now
            lastEntries = entries
            state = .scanning(
                ScanProgress(
                    dirs: p.dirs_done, files: p.files_done, bytes: p.bytes_seen,
                    errors: p.errors, entriesPerSecond: rate))
        }
        // Off the main actor: finish blocks until the scan thread ends.
        let result = await Task.detached { handle.finish() }.value
        guard generation == gen else { return }
        current = nil
        if status < 0 {
            state = .failed(errno: -status)
        } else if let result {
            snapshot = result
            state = .finished
        } else {
            state = .failed(errno: EIO)
        }
    }
}

private extension Duration {
    var seconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
