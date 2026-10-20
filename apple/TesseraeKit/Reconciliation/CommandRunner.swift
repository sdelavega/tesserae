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

public enum CommandOutcome: Equatable, Sendable {
    case exited(status: Int32, stdout: Data)
    case timedOut
    case launchFailed
}

public struct CommandRunner: Sendable {
    public let run: @Sendable (_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) -> CommandOutcome

    public init(run: @escaping @Sendable (URL, [String], TimeInterval) -> CommandOutcome) {
        self.run = run
    }

    public static let system = CommandRunner { executable, arguments, timeout in
        guard timeout.isFinite, timeout >= 0 else { return .launchFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        defer {
            try? pipe.fileHandleForWriting.close()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else {
            try? reader.close()
            return .launchFailed
        }
        do { try process.run() } catch {
            try? reader.close()
            return .launchFailed
        }
        try? pipe.fileHandleForWriting.close()

        // Drain while the child runs: waiting for exit first can fill and deadlock the pipe.
        let output = CommandOutput()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? reader.close()
                drained.leave()
            }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while !output.isFinished {
                let count = read(fd, &bytes, bytes.count)
                if count > 0 {
                    output.append(Data(bytes.prefix(count)))
                } else if count == 0 {
                    break
                } else if errno != EAGAIN && errno != EINTR {
                    break
                } else {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    _ = poll(&descriptor, 1, 20)
                }
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            // SIGTERM is cooperative; bound its grace period before forcing termination.
            if exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        // A descendant may keep stdout open after the direct child is reaped.
        _ = drained.wait(timeout: .now() + 1)
        let captured = output.finish()
        return timedOut ? .timedOut : .exited(status: process.terminationStatus, stdout: captured)
    }
}

// Finishing freezes the result and cancels the nonblocking drain. The worker owns
// the read handle and closes it on exit, including when EOF never arrives.
private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func append(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        if !finished { data.append(value) }
    }

    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return data
    }
}
