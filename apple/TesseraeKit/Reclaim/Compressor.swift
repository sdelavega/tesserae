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

public protocol HelperRunner: Sendable {
    func run(_ exe: URL, _ args: [Data]) async -> Int32
}

public struct ProductionHelperRunner: HelperRunner {
    public init() {}
    public func run(_ exe: URL, _ args: [Data]) async -> Int32 {
        guard exe.path.hasSuffix("/Contents/Helpers/applesauce"),
              args.starts(with: Compressor.compressFlags) || args.starts(with: Compressor.decompressFlags) else { return -EINVAL }
        let flags = args.starts(with: Compressor.compressFlags) ? Compressor.compressFlags : Compressor.decompressFlags
        let paths = args.dropFirst(flags.count)
        guard !paths.isEmpty, paths.allSatisfy({ path in
            guard path.first == 47, !path.contains(0) else { return false }
            var info = Darwin.stat()
            return (path + Data([0])).withUnsafeBytes {
                fstatat(AT_FDCWD, $0.baseAddress!.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0
                    && info.st_mode & S_IFMT == S_IFREG
            }
        }) else { return -EINVAL }
        switch await SpawnRunner().run(exe.path, args) {
        case .exited(let status): return status
        case .signalled(let signal): return -signal
        case .spawnFailed(let code), .captureFailed(let code): return -code
        }
    }
}

public struct CompressionFile: Sendable {
    public let facts: FileFacts
    public let recorded: Recorded
    public let allocated: UInt64
    public init(facts: FileFacts, recorded: Recorded, allocated: UInt64) {
        self.facts = facts; self.recorded = recorded; self.allocated = allocated
    }
}

public protocol CompressionFileSystem: FileStat {
    func inspect(_ path: Data) -> CompressionFile?
    func children(_ path: Data) throws -> [Data]
    func freeSpace(_ path: Data) -> UInt64?
    func canCompress(_ path: Data) -> Bool
}

public struct ProductionCompressionFileSystem: CompressionFileSystem {
    public init() {}
    public func lstat(_ path: Data) -> StatResult { ProductionFileStat().lstat(path) }
    public func volumeUUID(_ path: Data) -> String? { ProductionFileStat().volumeUUID(path) }
    public func inspect(_ path: Data) -> CompressionFile? {
        guard path.first == 47, !path.contains(0), let slash = path.lastIndex(of: 47),
              ancestorsAreSafe(path, stat: ProductionFileStat()) else { return nil }
        return (path + Data([0])).withUnsafeBytes { buffer in
            let p = buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
            var s = Darwin.stat()
            guard fstatat(AT_FDCWD, p, &s, AT_SYMLINK_NOFOLLOW) == 0, s.st_size >= 0, s.st_blocks >= 0 else { return nil }
            var allocated: UInt64 = 0, logical: UInt64 = 0
            let dataless = s.st_flags & UInt32(SF_DATALESS) != 0
            if !dataless {
                guard path.withUnsafeBytes({ tess_measure_allocated($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count, &allocated, &logical) }) else { return nil }
            }
            let kind = s.st_mode & S_IFMT
            let fork = kind == S_IFREG && !dataless ? getxattr(p, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW) : 0
            let hasFork = fork > 0 || (fork < 0 && errno != ENOATTR)
            let parent = slash == path.startIndex ? Data([47]) : Data(path[..<slash])
            let parentWritable = (parent + Data([0])).withUnsafeBytes { access($0.baseAddress!.assumingMemoryBound(to: CChar.self), W_OK) == 0 }
            var after = Darwin.stat()
            guard fstatat(AT_FDCWD, p, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  s.st_dev == after.st_dev, s.st_ino == after.st_ino, s.st_size == after.st_size,
                  s.st_mode == after.st_mode, s.st_flags == after.st_flags, s.st_nlink == after.st_nlink else { return nil }
            return CompressionFile(facts: FileFacts(isRegular: kind == S_IFREG, flags: s.st_flags,
                nlink: UInt64(s.st_nlink), size: UInt64(s.st_size), blocks: UInt64(s.st_blocks), hasResourceFork: hasFork,
                writable: access(p, W_OK) == 0 && parentWritable, key: FileKey(dev: s.st_dev, ino: s.st_ino)),
                recorded: Recorded(fileID: s.st_ino, device: s.st_dev, isDirectory: kind == S_IFDIR), allocated: allocated)
        }
    }
    public func children(_ path: Data) throws -> [Data] {
        guard path.first == 47, !path.contains(0), ancestorsAreSafe(path, stat: ProductionFileStat()) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let fd = (path + Data([0])).withUnsafeBytes { open($0.baseAddress!.assumingMemoryBound(to: CChar.self), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard let dir = fdopendir(fd) else { let code = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        defer { closedir(dir) }
        var result: [Data] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { Data($0.prefix(Int(entry.pointee.d_namlen))) }
            if name == Data(".".utf8) || name == Data("..".utf8) { continue }
            result.append(path + (path == Data([47]) ? Data() : Data([47])) + name)
        }
        return result
    }
    public func freeSpace(_ path: Data) -> UInt64? {
        var s = statfs()
        guard (path + Data([0])).withUnsafeBytes({ statfs($0.baseAddress!.assumingMemoryBound(to: CChar.self), &s) }) == 0 else { return nil }
        let (bytes, overflow) = s.f_bavail.multipliedReportingOverflow(by: UInt64(s.f_bsize))
        return overflow ? nil : bytes
    }
    public func canCompress(_ path: Data) -> Bool {
        var s = statfs()
        guard (path + Data([0])).withUnsafeBytes({ statfs($0.baseAddress!.assumingMemoryBound(to: CChar.self), &s) }) == 0 else { return false }
        let name = withUnsafeBytes(of: &s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return VolumeCapabilities(isLocal: s.f_flags & UInt32(MNT_LOCAL) != 0,
            isWritable: s.f_flags & UInt32(MNT_RDONLY) == 0, fsType: name).canCompress
    }
}

public struct CompressOutcome: Equatable, Sendable {
    public let runID: CompressRunID
    public var compressed = 0
    public var skipped: [SkipReason: Int] = [:]
    public var failed: [Data] = []
    public var bytesBefore: UInt64 = 0
    public var bytesAfter: UInt64 = 0
    public var replaced: [UInt32: UInt64] = [:]
    public var replacedPaths: [Data: UInt64] = [:]
    public var allocatedDeltas: [UInt32: Int64] = [:]
    public var inspected = 0
    public var cancelled = false
    public var isDecompression = false
    public var refusal: String?
    public var requiredFreeBytes: UInt64?
    public var availableFreeBytes: UInt64?
    public var signatureStatus: Int32?
    public var manifestFailed = false
    public var auditFailed = false
    public var inspectedAllProcesses = true
    public var auditEntry: LogEntry?
    public var savings: Int64 { Int64(clamping: bytesBefore) - Int64(clamping: bytesAfter) }
    public var decompressed: Int { compressed }
    public var summary: String { summary(locale: .current) }
    public func summary(locale: Locale) -> String {
        Self.summary(count: compressed, savings: savings, decompression: isDecompression, locale: locale)
    }
    static func summary(count: Int, savings: Int64, decompression: Bool = false, locale: Locale) -> String {
        let change = decompression ? -savings : savings
        let size = (change < 0 ? "-" : "") + displaySize(change.magnitude, locale: locale)
        if decompression {
            return String(localized: "compress.undoResult",
                defaultValue: "Decompressed \(count) files — allocation changed by \(size)", bundle: L10n.bundle,
                locale: L10n.pluralLocale(locale), comment: "Decompression result with signed formatted allocation change.")
        }
        return String(localized: "compress.result", defaultValue: "Compressed \(count) files — saved \(size)",
            bundle: L10n.bundle, locale: L10n.pluralLocale(locale), comment: "Measured compression result with signed formatted savings.")
    }
    public var displayResult: String { displayResult(locale: .current) }
    public func displayResult(locale: Locale) -> String {
        var lines = [summary(locale: locale)]
        if let refusal { lines.append(refusal) }
        if cancelled { lines.append(String(localized: "reclaim.cancelled", defaultValue: "Cancelled between batches.",
            bundle: L10n.bundle, comment: "Cancellation preserves completed compression changes.")) }
        if !failed.isEmpty {
            lines.append(ReclaimCopy.failedFiles(failed.count, locale: locale))
        }
        for reason in skipped.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            let count = skipped[reason]!
            lines.append(String(localized: "reclaim.skippedFiles", defaultValue: "\(count) skipped: \(reason.localizedDescription)",
                bundle: L10n.bundle, comment: "Compression exclusion count and reason."))
        }
        if !inspectedAllProcesses { lines.append(String(localized: "reclaim.processWarning",
            defaultValue: "Processes belonging to other users could not all be inspected.", bundle: L10n.bundle,
            comment: "Best effort open-file inspection limitation.")) }
        if let signatureStatus {
            lines.append(signatureStatus == 0
                ? String(localized: "reclaim.signaturePassed", defaultValue: "App signature check passed.",
                    bundle: L10n.bundle, comment: "Successful app signature verification after compression.")
                : String(localized: "reclaim.signatureFailed", defaultValue: "App signature check failed (exit code \(signatureStatus)).",
                    bundle: L10n.bundle, comment: "Failed app signature verification with the labelled exit code."))
        }
        if manifestFailed { lines.append(String(localized: "reclaim.manifestFailed",
            defaultValue: "The compression manifest could not be written. Some files may be unavailable for Decompress.",
            bundle: L10n.bundle, comment: "Compression manifest failure.")) }
        if auditFailed { lines.append(ReclaimCopy.logFailure) }
        return lines.joined(separator: "\n")
    }
    public func apply(to overlay: inout SizeOverlay, snapshot: Snapshot) {
        for (node, id) in replaced { overlay.replaceIdentity(node: node, newFileID: id) }
        for (node, delta) in allocatedDeltas { overlay.applyDelta(node: node, allocated: delta, logical: 0, in: snapshot) }
    }
}
public struct CompressionReview: Sendable {
    public let files: [(Data, UInt64)]
    public let skipped: [SkipReason: Int]
    public let inspectedAll: Bool
}
public typealias DecompressOutcome = CompressOutcome

// The session holds ReclaimCoordinator's permit through execution AND publication.
// The busy flag also refuses overlapping direct calls across helper suspension.
public actor Compressor {
    public static let compressFlags = ["compress", "--verify", "-c", "lzfse", "-r", "0.95", "--"].map { Data($0.utf8) }
    public static let decompressFlags = ["decompress", "--"].map { Data($0.utf8) }
    private let helper: URL
    private let runner: any HelperRunner
    private let files: any CompressionFileSystem
    private let openFiles: any OpenFilesProbe
    private let log: any AuditSink
    private let manifests: CompressManifest
    private let context: GuardContext
    private let argvLimit: Int
    private var busy = false
    private var runs: [CompressRunID: (ReclaimItem, [Data: UInt32])] = [:]

    public init(helper: URL, runner: any HelperRunner = ProductionHelperRunner(),
                files: any CompressionFileSystem = ProductionCompressionFileSystem(),
                openFiles: any OpenFilesProbe = LibprocOpenFilesProbe(), log: any AuditSink = ReclaimLog(),
                manifests: CompressManifest = CompressManifest(), context: GuardContext, argvLimit: Int = 256 * 1024) {
        self.helper = helper; self.runner = runner; self.files = files; self.openFiles = openFiles
        self.log = log; self.manifests = manifests; self.context = context; self.argvLimit = min(argvLimit, 256 * 1024)
    }
    public static func production(context: GuardContext, log: any AuditSink = ReclaimLog()) async -> Compressor? {
        guard case .success(let helper) = await CompressionHelper.locateAsync(bundle: .main) else { return nil }
        let directory = (log as? ReclaimLog)?.directory ?? ReclaimLog.defaultDirectory
        return Compressor(helper: helper, log: log,
            manifests: CompressManifest(directory: directory.appendingPathComponent("manifests")), context: context)
    }
    public nonisolated static func reviewFiles(_ item: ReclaimItem) -> [(Data, UInt64)] { reviewReport(item).files }
    public nonisolated static func reviewReport(_ item: ReclaimItem, openFiles: (keys: Set<FileKey>, inspectedAll: Bool)? = nil) -> CompressionReview {
        let files = ProductionCompressionFileSystem()
        let sweep = openFiles ?? LibprocOpenFilesProbe().openForWriting()
        let open = sweep.keys
        var skipped: [SkipReason: Int] = [:]
        var pending = [item.path], result: [(Data, UInt64)] = []
        while let path = pending.popLast() {
            if Task.isCancelled { return CompressionReview(files: [], skipped: skipped, inspectedAll: sweep.inspectedAll) }
            guard let file = files.inspect(path), file.recorded.device == item.recorded.device else { continue }
            if file.recorded.isDirectory {
                pending.append(contentsOf: (try? files.children(path)) ?? [])
            } else {
                var evidence: Set<Data> = []
                var probes = [path + Data("-wal".utf8), path + Data("-shm".utf8)]
                let parts = path.split(separator: 47)
                for i in parts.indices where foldedComponents(Data(parts[i])).last?.suffix(4) == Data(".app".utf8) {
                    probes.append(Data([47]) + parts[...i].joined(separator: Data([47])) + Data("/Contents/_MASReceipt/receipt".utf8))
                }
                for probe in probes {
                    switch files.lstat(probe) {
                    case .error(let code) where code == ENOENT || code == ENOTDIR: break
                    default: evidence.insert(probe)
                    }
                }
                if let reason = compressEligibility(path: path, stat: file.facts,
                    context: EligibilityContext(openForWriting: open, existingPaths: evidence)) {
                    skipped[reason, default: 0] += 1
                } else { result.append((path, file.facts.size)) }
            }
        }
        return CompressionReview(files: result, skipped: skipped, inspectedAll: sweep.inspectedAll)
    }
    public nonisolated static func reviewFacts(_ item: ReclaimItem, context: GuardContext, files supplied: [(Data, UInt64)]? = nil) -> ArchiveItemFacts {
        let files = supplied ?? reviewFiles(item)
        var facts = ArchiveItemFacts(largestFileSize: files.map { $0.1 }.max() ?? 0,
            eligibleBytes: files.reduce(0) { sum, file in
                let (total, overflow) = sum.addingReportingOverflow(file.1); return overflow ? UInt64.max : total
            })
        let stat = ProductionFileStat()
        for (path, _) in files {
            if foldedComponents(path).contains(where: { $0.suffix(4) == Data(".app".utf8) }) { facts.containsAppBundle = true }
            var parent = path
            while let slash = parent.lastIndex(of: 47), slash > parent.startIndex {
                parent = Data(parent[..<slash])
                if !pathIsWithin(parent, root: context.volumeRoot) { break }
                switch stat.lstat(parent + Data("/.git".utf8)) {
                case .error(let code) where code == ENOENT || code == ENOTDIR: break
                default: facts.containsGitWorkingTree = true
                }
            }
        }
        return facts
    }
    public func reviewDecompression(run: CompressRunID) -> DecompressConfirmation? {
        guard let rows = try? manifests.read(run), !rows.isEmpty else { return nil }
        var warnings: [Data: [Reason]] = [:]
        for row in rows {
            guard case .ok(let info, _, _) = files.lstat(row.path) else { continue }
            warnings[row.path] = allVerdicts(row.path, info, context).compactMap {
                if case .warn(let reason) = $0 { return reason }; return nil
            }
        }
        return DecompressConfirmation(run: run, rows: rows, warnings: warnings)
    }
    public static func argvBytes(executable: String, args: [Data]) -> Int {
        // Include argv[0], NUL terminators, pointer arrays AND the sole environment entry.
        executable.utf8.count + 1 + args.reduce(0) { $0 + $1.count + 1 }
            + (args.count + 4) * MemoryLayout<UnsafeRawPointer>.size + "PATH=/usr/bin:/bin".utf8.count + 1
    }
    private struct Candidate {
        let path: Data
        let file: CompressionFile
        let node: UInt32?
    }
    private func eligibility(_ path: Data, _ file: CompressionFile, open: Set<FileKey>) -> SkipReason? {
        var evidence: Set<Data> = []
        let parts = path.split(separator: 47)
        var probes = [path + Data("-wal".utf8), path + Data("-shm".utf8)]
        for end in parts.indices where foldedComponents(Data(parts[end])).last?.suffix(4) == Data(".app".utf8) {
            probes.append(Data([47]) + parts[...end].joined(separator: Data([47])) + Data("/Contents/_MASReceipt/receipt".utf8))
        }
        for probe in probes {
            switch files.lstat(probe) {
            case .error(let code) where code == ENOENT || code == ENOTDIR: break
            default: evidence.insert(probe)
            }
        }
        return compressEligibility(path: path, stat: file.facts, context: EligibilityContext(openForWriting: open, existingPaths: evidence))
    }
    private func allowed(_ path: Data, recorded: Recorded, confirmed: Set<Reason>) -> Bool {
        guard verifyIdentity(path, recorded, stat: files) == .same,
              case .ok(let observed, let id, false) = files.lstat(path), id == recorded.fileID,
              observed.device == recorded.device, observed.isDirectory == recorded.isDirectory else { return false }
        return allVerdicts(path, observed, context).allSatisfy {
            switch $0 { case .ok: return true; case .denied: return false; case .warn(let reason): return confirmed.contains(reason) }
        }
    }
    private func ancestorsMatch(_ path: Data, recorded: [Data: Recorded], confirmed: Set<Reason>) -> Bool {
        var parent = path
        while let slash = parent.lastIndex(of: 47) {
            parent = slash == parent.startIndex ? Data([47]) : Data(parent[..<slash])
            if let expected = recorded[parent], expected.isDirectory,
               !allowed(parent, recorded: expected, confirmed: confirmed) { return false }
            if parent == Data([47]) { break }
        }
        return true
    }
    private func inGitWorkingTree(_ path: Data) -> Bool {
        var p = path
        while let slash = p.lastIndex(of: 47), slash > p.startIndex {
            p = Data(p[..<slash])
            if !pathIsWithin(p, root: context.volumeRoot) { break }
            switch files.lstat(p + Data("/.git".utf8)) {
            case .error(let code) where code == ENOENT || code == ENOTDIR: break
            default: return true
            }
        }
        return false
    }
    private func appBundles(_ path: Data) -> [Data] {
        let parts = path.split(separator: 47), folded = foldedComponents(path)
        return parts.indices.filter { folded[$0].suffix(4) == Data(".app".utf8) }.map {
            Data([47]) + parts[...$0].joined(separator: Data([47]))
        }
    }
    private func totalBytes(_ sizes: [UInt64]) -> UInt64 {
        sizes.reduce(0) { sum, size in
            let (total, overflow) = sum.addingReportingOverflow(size)
            return overflow ? UInt64.max : total
        }
    }
    private func requiredSpace(_ largest: UInt64) -> UInt64 {
        let (twice, a) = largest.multipliedReportingOverflow(by: 2)
        let (total, b) = twice.addingReportingOverflow(2 * 1024 * 1024 * 1024)
        return a || b ? UInt64.max : total
    }
    private func refuseSpace(_ path: Data, largest: UInt64, outcome: inout CompressOutcome) -> Bool {
        let required = requiredSpace(largest), available = files.freeSpace(path)
        outcome.requiredFreeBytes = required; outcome.availableFreeBytes = available
        guard let available, available >= required else {
            let needed = displaySize(required), free = displaySize(available ?? 0)
            outcome.refusal = String(localized: "compress.freeSpace", defaultValue: "This operation needs \(needed) free; \(free) are available.",
                bundle: L10n.bundle, comment: "Refusal with formatted required and available free space, in that order.")
            return true
        }
        return false
    }
    private func refusal() -> String {
        String(localized: "compress.refused", defaultValue: "Compression couldn't proceed. Files or permissions changed, or no files could be inspected.",
            bundle: L10n.bundle, comment: "Compression refused after a fresh identity, guard or inspection check.")
    }

    public func compress(_ item: ReclaimItem, confirmedWarnings: Set<Reason> = []) async -> CompressOutcome {
        var result = CompressOutcome(runID: UUID())
        guard !busy else { result.refusal = refusal(); return result }
        busy = true; defer { busy = false }
        guard mutationAncestryIsSafe(item.path, volumeRoot: context.volumeRoot, stat: files) else {
            result.refusal = unsafeMutationFolderReason(); return result
        }
        let start = Date()
        var statuses: [Int32] = []
        var nodes: [Data: UInt32] = [item.path: item.nodeIndex]
        for (index, child) in item.descendants.enumerated() { nodes[child.path] = item.descendants.nodes[index] }
        runs[result.runID] = (item, nodes)
        defer { runs[result.runID] = nil }
        var recordedByPath = Dictionary(uniqueKeysWithValues: item.descendants.map { ($0.path, $0.recorded) })
        recordedByPath[item.path] = item.recorded
        var candidates: [Candidate] = []
        var eligibleSizes: [Data: UInt64] = [:]
        let sweep = openFiles.openForWriting(); result.inspectedAllProcesses = sweep.inspectedAll
        if case .denied = item.verdict { result.refusal = refusal() }
        if !Set(itemWarnings(item)).isSubset(of: confirmedWarnings) { result.refusal = refusal() }
        if !files.canCompress(item.path) || !allowed(item.path, recorded: item.recorded, confirmed: confirmedWarnings) { result.refusal = refusal() }
        if result.refusal == nil {
            var pending = [item.path]
            while let path = pending.popLast() {
                guard pathIsWithin(path, root: item.path), let f = files.inspect(path), f.recorded.device == item.recorded.device else {
                    result.failed.append(path); continue
                }
                if let expected = recordedByPath[path], expected != f.recorded { result.failed.append(path); continue }
                if f.recorded.isDirectory {
                    recordedByPath[path] = f.recorded
                    guard allowed(path, recorded: f.recorded, confirmed: confirmedWarnings) else { result.failed.append(path); continue }
                    do { pending.append(contentsOf: try files.children(path).reversed()) }
                    catch { result.failed.append(path) }
                } else {
                    result.inspected += 1
                    if let skip = eligibility(path, f, open: sweep.keys) { result.skipped[skip, default: 0] += 1; continue }
                    guard allowed(path, recorded: f.recorded, confirmed: confirmedWarnings) else { result.failed.append(path); continue }
                    candidates.append(Candidate(path: path, file: f, node: nodes[path]))
                }
            }
            if result.inspected == 0 { result.refusal = refusal() }
            eligibleSizes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0.file.facts.size) })
            let facts = ArchiveItemFacts(containsGitWorkingTree: candidates.contains { inGitWorkingTree($0.path) },
                largestFileSize: eligibleSizes.values.max() ?? 0, eligibleBytes: totalBytes(Array(eligibleSizes.values)))
            if candidates.contains(where: { !appBundles($0.path).isEmpty }) && !confirmedWarnings.contains(.appBundleCompress) {
                result.refusal = refusal()
            }
            if !Set(actionWarnings(for: item, action: .compress, facts: facts)).isSubset(of: confirmedWarnings) { result.refusal = refusal() }
            if result.refusal == nil && !candidates.isEmpty {
                _ = refuseSpace(item.path, largest: facts.largestFileSize, outcome: &result)
                if result.refusal == nil {
                    do { try manifests.create(result.runID) }
                    catch { result.manifestFailed = true; result.refusal = refusal() }
                }
            }
        }
        if result.refusal == nil {
            for batch in batches(candidates, flags: Self.compressFlags, outcome: &result) {
                if Task.isCancelled { result.cancelled = true; break }
                guard files.canCompress(item.path), allowed(item.path, recorded: item.recorded, confirmed: confirmedWarnings) else { result.refusal = refusal(); break }
                guard batch.allSatisfy({ mutationAncestryIsSafe($0.path, volumeRoot: context.volumeRoot, stat: files) }) else {
                    result.refusal = unsafeMutationFolderReason(); break
                }
                var fresh: [Candidate] = []
                for c in batch {
                    guard ancestorsMatch(c.path, recorded: recordedByPath, confirmed: confirmedWarnings),
                          let f = files.inspect(c.path), f.recorded == c.file.recorded else { result.failed.append(c.path); continue }
                    if let skip = eligibility(c.path, f, open: sweep.keys) { result.skipped[skip, default: 0] += 1; continue }
                    guard allowed(c.path, recorded: f.recorded, confirmed: confirmedWarnings) else { result.failed.append(c.path); continue }
                    if f.facts.size > 4 * 1024 * 1024 * 1024 && !confirmedWarnings.contains(.largeFile) { result.failed.append(c.path); continue }
                    eligibleSizes[c.path] = f.facts.size
                    fresh.append(Candidate(path: c.path, file: f, node: c.node))
                }
                if fresh.isEmpty { continue }
                let facts = ArchiveItemFacts(containsGitWorkingTree: fresh.contains { inGitWorkingTree($0.path) },
                    largestFileSize: eligibleSizes.values.max() ?? 0, eligibleBytes: totalBytes(Array(eligibleSizes.values)))
                if !Set(actionWarnings(for: item, action: .compress, facts: facts)).isSubset(of: confirmedWarnings) {
                    result.refusal = refusal(); break
                }
                if refuseSpace(item.path, largest: fresh.map { $0.file.facts.size }.max()!, outcome: &result) { break }
                statuses.append(await runner.run(helper, Self.compressFlags + fresh.map(\.path)))
                let rows = account(fresh, undo: false, aggregateNode: item.nodeIndex, outcome: &result)
                do { try manifests.append(rows, run: result.runID) }
                catch { result.manifestFailed = true; break }
            }
        }
        if result.compressed > 0 {
            let bundles = Set(candidates.flatMap { appBundles($0.path) })
            for bundle in bundles.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                let status = await SpawnRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--"].map { Data($0.utf8) } + [bundle])
                let code: Int32
                switch status { case .exited(let exit): code = exit; default: code = -1 }
                if result.signatureStatus == nil || result.signatureStatus == 0 { result.signatureStatus = code }
            }
        }
        finish(item: item, action: "compress", start: start, statuses: statuses, outcome: &result)
        return result
    }

    public func decompress(run: CompressRunID, snapshot: Snapshot? = nil, reviewed: DecompressConfirmation? = nil) async -> DecompressOutcome {
        var result = CompressOutcome(runID: run)
        result.isDecompression = true
        guard !busy else { result.refusal = refusal(); return result }
        busy = true; defer { busy = false }
        let start = Date()
        let saved = runs[run]
        let entry = log.compressEntry(run: run)
        guard let rows = try? manifests.read(run), let first = rows.first else { result.refusal = refusal(); return result }
        if let reviewed, reviewed.run != run || reviewed.rows != rows { result.refusal = refusal(); return result }
        // The 0600 manifest remains authoritative if the audit append failed or
        // its entry rotated away. Derive only an audit label; every row still
        // requires its own identity, compressed flag, ancestry and guard checks.
        var common = first.path
        while !rows.allSatisfy({ pathIsWithin($0.path, root: common) }) {
            guard let slash = common.lastIndex(of: 47) else { result.refusal = refusal(); return result }
            common = slash == common.startIndex ? Data([47]) : Data(common[..<slash])
        }
        let fallback = ReclaimItem(nodeIndex: 0, path: common,
            recorded: Recorded(fileID: first.fileID, device: first.device, isDirectory: rows.count > 1),
            recordedSize: nil, verdict: .ok)
        let item = saved?.0 ?? entry.flatMap({ e -> ReclaimItem? in
            guard let path = e.path.map({ Data($0.utf8) }) ?? e.pathB64.flatMap({ Data(base64Encoded: $0) }), let device = e.device else { return nil }
            let node = snapshot.flatMap { s in (0..<UInt32(s.nodes.count)).first { s.rawPath($0) == path } }
            return ReclaimItem(nodeIndex: node ?? snapshot?.root ?? 0, path: path,
                recorded: Recorded(fileID: e.inode, device: device, isDirectory: e.isDirectory ?? false), recordedSize: e.bytes, verdict: .ok)
        }) ?? fallback
        // Snapshot node numbers belong only to that snapshot, including when
        // an engine survives a rescan or the run is outside the visible root.
        var nodes = snapshot == nil ? (saved?.1 ?? [:]) : [:]
        if let snapshot { for node in 0..<UInt32(snapshot.nodes.count) { nodes[snapshot.rawPath(node)] = node } }
        let sweep = openFiles.openForWriting(); result.inspectedAllProcesses = sweep.inspectedAll
        func consent(_ path: Data) -> Set<Reason> {
            guard let reviewed, reviewed.run == run, reviewed.allowedPaths.contains(path) else { return [] }
            return Set(reviewed.warnings[path] ?? [])
        }
        var candidates: [Candidate] = []
        for row in rows {
            if let reviewed, reviewed.run != run || !reviewed.allowedPaths.contains(row.path) { continue }
            result.inspected += 1
            let r = Recorded(fileID: row.fileID, device: row.device, isDirectory: false)
            guard pathIsWithin(row.path, root: item.path), allowed(row.path, recorded: r, confirmed: consent(row.path)),
                  let f = files.inspect(row.path), f.recorded == r, f.facts.flags & UInt32(UF_COMPRESSED) != 0,
                  f.facts.isRegular, f.facts.nlink == 1, !sweep.keys.contains(f.facts.key), f.facts.writable else { result.failed.append(row.path); continue }
            candidates.append(Candidate(path: row.path, file: f, node: nodes[row.path]))
        }
        var statuses: [Int32] = []
        for batch in batches(candidates, flags: Self.decompressFlags, outcome: &result) {
            if Task.isCancelled { result.cancelled = true; break }
            var fresh: [Candidate] = []
            for c in batch {
                guard allowed(c.path, recorded: c.file.recorded, confirmed: consent(c.path)), let f = files.inspect(c.path),
                      f.recorded == c.file.recorded, f.facts.flags & UInt32(UF_COMPRESSED) != 0,
                      f.facts.isRegular, f.facts.nlink == 1, f.facts.writable, !sweep.keys.contains(f.facts.key),
                      allowed(c.path, recorded: f.recorded, confirmed: consent(c.path)), files.canCompress(c.path) else { result.failed.append(c.path); continue }
                fresh.append(Candidate(path: c.path, file: f, node: c.node))
            }
            if fresh.isEmpty { continue }
            if refuseSpace(item.path, largest: fresh.map { $0.file.facts.size }.max()!, outcome: &result) { break }
            statuses.append(await runner.run(helper, Self.decompressFlags + fresh.map(\.path)))
            let aggregate = snapshot == nil || snapshot === saved?.0.descendants.snapshot ? nodes[item.path] : nil
            _ = account(fresh, undo: true, aggregateNode: aggregate, outcome: &result)
        }
        finish(item: item, action: "decompress", start: start, statuses: statuses, outcome: &result)
        return result
    }
    private func batches(_ candidates: [Candidate], flags: [Data], outcome: inout CompressOutcome) -> [[Candidate]] {
        var batches: [[Candidate]] = [], batch: [Candidate] = []
        var bytes = Self.argvBytes(executable: helper.path, args: flags)
        let base = bytes
        for c in candidates {
            let cost = c.path.count + 1 + MemoryLayout<UnsafeRawPointer>.size
            if base + cost >= argvLimit { outcome.failed.append(c.path); continue }
            if bytes + cost >= argvLimit { batches.append(batch); batch = []; bytes = base }
            batch.append(c); bytes += cost
        }
        if !batch.isEmpty { batches.append(batch) }; return batches
    }
    private func account(_ batch: [Candidate], undo: Bool, aggregateNode: UInt32?, outcome: inout CompressOutcome) -> [CompressManifest.Row] {
        var rows: [CompressManifest.Row] = []
        for c in batch {
            outcome.bytesBefore += c.file.allocated
            let observed = files.inspect(c.path)
            outcome.bytesAfter += observed?.allocated ?? c.file.allocated
            guard let after = observed, after.facts.isRegular, ancestorsAreSafe(c.path, stat: files),
                  after.recorded.device == c.file.recorded.device, after.facts.size == c.file.facts.size,
                  (after.facts.flags & UInt32(UF_COMPRESSED) != 0) != undo else {
                outcome.failed.append(c.path); continue
            }
            outcome.compressed += 1
            outcome.replacedPaths[c.path] = after.recorded.fileID
            if let node = c.node { outcome.replaced[node] = after.recorded.fileID }
            if let node = c.node ?? aggregateNode {
                outcome.allocatedDeltas[node, default: 0] += Int64(clamping: after.allocated) - Int64(clamping: c.file.allocated)
            }
            rows.append(CompressManifest.Row(path: c.path, device: after.recorded.device, fileID: after.recorded.fileID))
        }
        return rows
    }
    private func finish(item: ReclaimItem, action: String, start: Date, statuses: [Int32], outcome: inout CompressOutcome) {
        let path = String(data: item.path, encoding: .utf8)
        let details = CompressionAudit(runID: outcome.runID, tool: "applesauce", version: "0.5.30",
            flags: (action == "compress" ? Self.compressFlags : Self.decompressFlags).map { String(decoding: $0, as: UTF8.self) },
            exitStatuses: statuses, duration: Date().timeIntervalSince(start), filesChanged: outcome.compressed,
            skipped: Dictionary(uniqueKeysWithValues: outcome.skipped.map { (String(describing: $0.key), $0.value) }),
            failed: outcome.failed.count, bytesBefore: outcome.bytesBefore, bytesAfter: outcome.bytesAfter,
            signatureStatus: outcome.signatureStatus, manifestFailed: outcome.manifestFailed)
        let interrupted = outcome.refusal != nil || outcome.cancelled || !outcome.failed.isEmpty || outcome.manifestFailed
        let result = outcome.compressed > 0 && interrupted ? "partial" : outcome.refusal != nil ? "refused" : outcome.cancelled ? "cancelled" : interrupted ? "partial" : "ok"
        let e = LogEntry(ts: Date(), action: action, path: path, pathB64: path == nil ? item.path.base64EncodedString() : nil,
            inode: outcome.replacedPaths[item.path] ?? item.recorded.fileID, device: item.recorded.device,
            volumeUUID: files.volumeUUID(item.path), isDirectory: item.recorded.isDirectory,
            bytes: item.recordedSize, trashURL: nil, result: result, compression: details)
        outcome.auditEntry = e; outcome.auditFailed = !log.append(e)
    }
}
