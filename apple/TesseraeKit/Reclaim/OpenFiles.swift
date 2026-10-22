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

public protocol OpenFilesProbe: Sendable {
    func openForWriting() -> (keys: Set<FileKey>, inspectedAll: Bool)
}

// Call once per preparation and share the result with every file's context.
public func prepareOpenFiles(using probe: any OpenFilesProbe) async -> (keys: Set<FileKey>, inspectedAll: Bool) {
    await Task.detached { probe.openForWriting() }.value
}

public struct LibprocOpenFilesProbe: OpenFilesProbe {
    public init() {}
    public func openForWriting() -> (keys: Set<FileKey>, inspectedAll: Bool) {
        // Retry boundedly when the process/FD lists grow between sizing and read.
        guard let pids: [Int32] = list(stride: MemoryLayout<Int32>.stride, fetch: { buffer, bytes in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer, bytes)
        }) else { return ([], false) }
        return Self.sweep(processes: pids.filter { $0 > 0 }) { pid in
            guard let descriptors: [proc_fdinfo] = list(stride: MemoryLayout<proc_fdinfo>.stride, fetch: { buffer, bytes in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, bytes)
            }) else { return ([], false) }
            var keys: Set<FileKey> = []
            var complete = true
            for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
                    complete = false; continue
                }
                // SDK sys/proc_info.h: pfi.fi_openflags, pvip.vip_vi.vi_stat.
                if info.pfi.fi_openflags & UInt32(FWRITE) != 0 {
                    let s = info.pvip.vip_vi.vi_stat
                    keys.insert(FileKey(dev: Int32(bitPattern: s.vst_dev), ino: s.vst_ino))
                }
            }
            return (keys, complete)
        }
    }

    static func sweep(processes: [Int32]?, inspect: (Int32) -> (Set<FileKey>, Bool))
        -> (keys: Set<FileKey>, inspectedAll: Bool) {
        guard let processes, !processes.isEmpty else { return ([], false) }
        var keys: Set<FileKey> = []
        var complete = true
        for pid in processes {
            let result = inspect(pid)
            keys.formUnion(result.0)
            complete = complete && result.1
        }
        return (keys, complete)
    }

    private func list<T>(stride: Int, fetch: (UnsafeMutableRawPointer?, Int32) -> Int32) -> [T]? {
        for attempt in 1...3 {
            let needed = fetch(nil, 0)
            guard needed > 0, needed < Int32.max / 2 else { return nil }
            let capacity = Int(needed) + stride * (256 * attempt)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<T>.alignment)
            defer { buffer.deallocate() }
            let bytes = fetch(buffer, Int32(capacity))
            guard bytes >= 0, Int(bytes) % stride == 0 else { return nil }
            if bytes == 0 { return nil }
            if Int(bytes) < capacity {
                return Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: T.self), count: Int(bytes) / stride))
            }
        }
        return nil
    }
}

public func openFilesInspectionWarning(inspectedAll: Bool) -> String? {
    inspectedAll ? nil : String(localized: "reclaimAction.partialOpenFiles",
        defaultValue: "Some processes couldn't be inspected for files open for writing, including processes owned by other users.",
        bundle: L10n.bundle, comment: "Best-effort open-file inspection warning in compression review.")
}
