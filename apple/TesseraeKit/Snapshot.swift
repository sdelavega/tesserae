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

import Foundation
import TesseraeFFI

/// The ARC owner of one Rust snapshot (spec §6 "How the borrow is made safe").
///
/// Code rule: `nodes` and `names` borrow Rust memory that lives exactly as
/// long as this instance. Never let them, or a pointer taken from them,
/// outlive the `Snapshot`; never capture them in an escaping closure without
/// capturing the class.
public final class Snapshot {
    public let root: UInt32
    public let stats: TessScanStats
    public let stalledAt: Data?

    private let handle: OpaquePointer
    private let _nodes: UnsafeBufferPointer<TessNode>
    private let _names: UnsafeRawBufferPointer

    #if DEBUG
    private let lock = NSLock()
    private var released = false
    private let bornAt: UInt64
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    /// How many snapshots have been released so far (process-wide).
    static var releasedCount: UInt64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return counter
    }

    /// The process-wide release count when this snapshot was made. Reading it
    /// asserts the snapshot is still live.
    public var generation: UInt64 {
        assertLive()
        return bornAt
    }

    private func assertLive() {
        lock.lock()
        let dead = released
        lock.unlock()
        precondition(!dead, "Snapshot accessed after its Rust memory was released")
    }

    /// Release the Rust memory now, as if the borrow had outlived the owner.
    /// Debug builds only; any later access traps. Exists so the trap can be tested.
    func debugReleaseEarly() {
        releaseOnce()
    }

    private func releaseOnce() {
        lock.lock()
        let already = released
        released = true
        lock.unlock()
        guard !already else { return }
        tess_snapshot_release(handle)
        Snapshot.counterLock.lock()
        Snapshot.counter += 1
        Snapshot.counterLock.unlock()
    }
    #endif

    /// Takes ownership of `handle`, a snapshot from `tess_scan_finish`.
    init(handle: OpaquePointer) {
        self.handle = handle
        var view = TessView()
        tess_snapshot_view(handle, &view)
        _nodes = UnsafeBufferPointer(start: view.nodes, count: Int(view.count))
        _names = UnsafeRawBufferPointer(start: view.names, count: Int(view.names_len))
        root = view.root
        var s = TessScanStats()
        tess_snapshot_stats(handle, &s)
        stats = s
        var len: UInt64 = 0
        if let p = tess_snapshot_stalled_at(handle, &len) {
            stalledAt = Data(bytes: p, count: Int(len))
        } else {
            stalledAt = nil
        }
        #if DEBUG
        Snapshot.counterLock.lock()
        bornAt = Snapshot.counter
        Snapshot.counterLock.unlock()
        #endif
    }

    deinit {
        #if DEBUG
        releaseOnce()
        #else
        tess_snapshot_release(handle)
        #endif
    }

    public var nodes: UnsafeBufferPointer<TessNode> {
        #if DEBUG
        assertLive()
        #endif
        return _nodes
    }

    public var names: UnsafeRawBufferPointer {
        #if DEBUG
        assertLive()
        #endif
        return _names
    }

    /// The raw bytes of node `i`'s name; not necessarily UTF-8.
    public func nameBytes(_ i: UInt32) -> Data {
        let n = nodes[Int(i)]
        guard n.name_len > 0 else { return Data() }
        return Data(names[Int(n.name_off)..<Int(n.name_off) + Int(n.name_len)])
    }

    /// Lossy UTF-8 name with C0 control characters replaced by U+FFFD; never empty.
    public func name(_ i: UInt32) -> String {
        Snapshot.decodeName(nameBytes(i))
    }

    static func decodeName(_ bytes: Data) -> String {
        let decoded = String(decoding: bytes, as: UTF8.self)
        var out = String.UnicodeScalarView()
        for s in decoded.unicodeScalars {
            out.append(s.value < 0x20 ? "\u{FFFD}" : s)
        }
        let result = String(out)
        return result.isEmpty ? "(unnamed)" : result
    }

    /// The children of node `i`, contiguous in `nodes`; empty for a leaf.
    public func children(_ i: UInt32) -> Range<UInt32> {
        let n = nodes[Int(i)]
        guard n.child_count > 0 else { return 0..<0 }
        return n.child_start..<(n.child_start + n.child_count)
    }

    /// The path of node `i`: the root's name (the scan root as given) joined
    /// with each name down to `i`.
    public func path(_ i: UInt32) -> String {
        var parts: [String] = []
        var cur = i
        while true {
            let n = nodes[Int(cur)]
            if n.parent == UInt32.max {
                parts.append(name(cur))
                break
            }
            parts.append(name(cur))
            cur = n.parent
        }
        var result = parts.removeLast()
        for p in parts.reversed() {
            if !result.hasSuffix("/") { result += "/" }
            result += p
        }
        return result
    }

    public func isDirectory(_ i: UInt32) -> Bool {
        nodes[Int(i)].flags & UInt16(TESS_FLAG_DIR) != 0
    }
}

/// Immutable after `init` (the Rust snapshot never mutates), so it may be
/// shared across threads; the debug bookkeeping is lock-protected.
extension Snapshot: @unchecked Sendable {}
