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
import Security

public enum SpawnResult: Equatable, Sendable {
    case exited(Int32), signalled(Int32), spawnFailed(errno: Int32), captureFailed(errno: Int32)
}

public struct SpawnRunner: Sendable {
    private let captureRead: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    public init() { captureRead = { Darwin.read($0, $1, $2) } }
    init(captureRead: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int) { self.captureRead = captureRead }

    public func run(_ executable: String, _ args: [Data], stdoutFD: Int32? = nil) async -> SpawnResult {
        await Task.detached {
            switch Self.spawn(executable, args, stdoutFD: stdoutFD, stderrFD: nil) {
            case .success(let pid): return Self.wait(pid)
            case .failure(let error): return .spawnFailed(errno: error.code)
            }
        }.value
    }

    public func runCapturing(_ executable: String, _ args: [Data]) async
        -> (SpawnResult, stdout: Data, stderr: Data) {
        await Task.detached {
            var out: [Int32] = [0, 0]
            var err: [Int32] = [0, 0]
            guard pipe(&out) == 0 else { return (.spawnFailed(errno: errno), Data(), Data()) }
            guard pipe(&err) == 0 else {
                let code = errno
                close(out[0]); close(out[1])
                return (.spawnFailed(errno: code), Data(), Data())
            }
            let child = Self.spawn(executable, args, stdoutFD: out[1], stderrFD: err[1])
            close(out[1]); close(err[1])
            var closed = [false, false]
            defer { if !closed[0] { close(out[0]) }; if !closed[1] { close(err[0]) } }
            guard case .success(let pid) = child else {
                if case .failure(let error) = child {
                    return (.spawnFailed(errno: error.code), Data(), Data())
                }
                preconditionFailure("Unreachable spawn result")
            }
            // Drain both pipes together before waiting: either stream can fill a pipe.
            var streams = [Data(), Data()]
            var descriptors = [pollfd(fd: out[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: err[0], events: Int16(POLLIN), revents: 0)]
            var buffer = [UInt8](repeating: 0, count: 65536)
            var captureError: Int32?
            while descriptors.contains(where: { $0.fd >= 0 }) {
                let ready = poll(&descriptors, nfds_t(descriptors.count), -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    captureError = errno
                    for i in descriptors.indices where descriptors[i].fd >= 0 {
                        close(descriptors[i].fd); closed[i] = true; descriptors[i].fd = -1
                    }
                    break
                }
                for i in descriptors.indices where descriptors[i].fd >= 0 && descriptors[i].revents != 0 {
                    let count = buffer.withUnsafeMutableBytes { captureRead(descriptors[i].fd, $0.baseAddress!, $0.count) }
                    if count > 0 { streams[i].append(contentsOf: buffer.prefix(count)) }
                    else if count == 0 { descriptors[i].fd = -1 }
                    else if errno != EINTR {
                        captureError = captureError ?? errno
                        close(descriptors[i].fd); closed[i] = true; descriptors[i].fd = -1
                    }
                }
            }
            let status = Self.wait(pid)
            return (captureError.map { .captureFailed(errno: $0) } ?? status, streams[0], streams[1])
        }.value
    }

    private struct SpawnError: Error { let code: Int32 }

    private static func spawn(_ executable: String, _ args: [Data], stdoutFD: Int32?, stderrFD: Int32?)
        -> Result<pid_t, SpawnError> {
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              !args.contains(where: { $0.contains(0) }) else { return .failure(SpawnError(code: EINVAL)) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var code = posix_spawn_file_actions_init(&actions)
        guard code == 0 else { return .failure(SpawnError(code: code)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else { return .failure(SpawnError(code: code)) }
        defer { posix_spawnattr_destroy(&attributes) }
        code = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard code == 0 else { return .failure(SpawnError(code: code)) }
        for (destination, source) in [(STDIN_FILENO, nil), (STDOUT_FILENO, stdoutFD), (STDERR_FILENO, stderrFD)] {
            if let source {
                code = posix_spawn_file_actions_adddup2(&actions, source, destination)
            } else {
                code = posix_spawn_file_actions_addopen(&actions, destination, "/dev/null",
                                                        destination == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            }
            guard code == 0 else { return .failure(SpawnError(code: code)) }
        }
        let allocations = ([Data(executable.utf8)] + args + [Data("PATH=/usr/bin:/bin".utf8)]).map { bytes in
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
            for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
            pointer[bytes.count] = 0
            return pointer
        }
        defer { allocations.forEach { $0.deallocate() } }
        var argv: [UnsafeMutablePointer<CChar>?] = allocations.dropLast().map { $0 } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [allocations.last!, nil]
        var pid: pid_t = 0
        code = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        return code == 0 ? .success(pid) : .failure(SpawnError(code: code))
    }

    private static func wait(_ pid: pid_t) -> SpawnResult {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return .spawnFailed(errno: errno) }
        }
        // sys/wait.h: WSTATUS = status & 0177; WEXITSTATUS = (status >> 8) & 0xff.
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
    }
}

public enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip, tarXZ = "tar.xz", tarZst = "tar.zst", appleArchiveFast, appleArchiveSmallest
    public var fileExtension: String {
        switch self {
        case .appleArchiveFast, .appleArchiveSmallest: return "aar"
        default: return rawValue
        }
    }
}

public func defaultFormat(volumeFSType: String) -> ArchiveFormat {
    volumeFSType == "apfs" || volumeFSType == "hfs" ? .appleArchiveFast : .zip
}

public func isAdvanced(_ f: ArchiveFormat, volumeFSType: String) -> Bool {
    f == .tarZst || f == .appleArchiveSmallest
        || (f == .appleArchiveFast && volumeFSType != "apfs" && volumeFSType != "hfs")
}

public func tarArguments(_ f: ArchiveFormat, parent: Data, name: Data) -> [Data]? {
    let flags: [String]
    switch f {
    case .zip: flags = ["-c", "--format", "zip"]
    case .tarXZ: flags = ["-c", "-J", "--options", "xz:threads=0"]
    case .tarZst: flags = ["-c"]
    case .appleArchiveFast, .appleArchiveSmallest: return nil
    }
    return (flags + ["--one-file-system"] + (f == .zip ? [] : ["--no-read-sparse"]) + ["-f", "-", "-C"]).map { Data($0.utf8) }
        + [parent, Data("--".utf8), name]
}

public enum HelperProblem: Error { case missing, unsigned, noVerifyFlag }

public struct CompressionHelper {
    public static func locateAsync(bundle: Bundle) async -> Result<URL, HelperProblem> {
        let validated = await Task.detached { validatedHelper(bundle: bundle) }.value
        guard case .success(let url) = validated else { return validated }
        guard await supportsVerifyAsync(url) else { return .failure(.noVerifyFlag) }
        return .success(url)
    }
    public static func supportsVerifyAsync(_ url: URL) async -> Bool {
        let capture = await SpawnRunner().runCapturing(url.path, [Data("compress".utf8), Data("--help".utf8)])
        return capture.0 == .exited(0) && capture.stdout.range(of: Data("--verify".utf8)) != nil
    }

    private static func validatedHelper(bundle: Bundle) -> Result<URL, HelperProblem> {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/applesauce")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return .failure(.missing) }
        guard let helper = signature(url) else { return .failure(.unsigned) }
        let team = signature(bundle.bundleURL)?[kSecCodeInfoTeamIdentifier] as? String
        let helperTeam = helper[kSecCodeInfoTeamIdentifier] as? String
        if let team {
            guard helperTeam == team else { return .failure(.unsigned) }
        } else {
            let flags = (helper[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
            guard helperTeam == nil, flags & 0x0002 /* CSCommon.h: kSecCodeSignatureAdhoc */ != 0 else { return .failure(.unsigned) }
        }
        return .success(url)
    }

    private static func signature(_ url: URL) -> [CFString: Any]? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [CFString: Any]
    }
}
