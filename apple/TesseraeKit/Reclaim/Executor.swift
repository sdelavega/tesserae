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

public protocol Trasher: Sendable {
    func trash(_ url: URL) throws -> URL
}

public struct ProductionTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let resulting else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                          userInfo: [NSLocalizedDescriptionKey: String(
                              localized: "executor.trash.returned.no.destination.url",
                              defaultValue: "Trash returned no destination URL",
                              bundle: L10n.bundle,
                              comment: "Executor: Trash returned no destination URL."
                          )])
        }
        return resulting as URL
    }
}

public enum Outcome: Equatable, Sendable {
    case skippedUnavailable(String)
    case compressed(CompressOutcome)
    case archived(ArchiveRun)
    case trashed(trashURL: URL), skipped(Reason), notConfirmed(Reason)
    case identityChanged(IdentityResult), failed(errno: Int32, message: String)
}

public struct ExecutionResult: Sendable {
    public let outcomes: [(ReclaimItem, Outcome)]
    public let reclaimableBytes: UInt64
    public let unknownSizeTrashed: Int
    public var auditEntries: [LogEntry] = []
}

public actor Executor {
    private let trasher: any Trasher
    private let stat: any FileStat
    private let log: any AuditSink
    private let context: GuardContext
    private let compressor: Compressor?
    private let archiver: Archiver?
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !active { active = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active = false } else { waiters.removeFirst().resume() }
    }

    public init(trasher: any Trasher, stat: any FileStat, log: any AuditSink, context: GuardContext, compressor: Compressor? = nil, archiver: Archiver? = nil) {
        self.trasher = trasher
        self.stat = stat
        self.log = log
        self.context = context
        self.compressor = compressor
        self.archiver = archiver
    }

    // Keep concurrent callers sequential across compression helper suspensions.
    public func run(_ items: [ReclaimItem], confirmedWarnings: Set<UInt32>,
                    progress: (@Sendable (Int, Int) -> Void)? = nil,
                    reviewedVerdicts: [UInt32: Verdict]? = nil, reviewedWarnings: [UInt32: Set<Reason>]? = nil,
                    currentRevision: UInt64? = nil, currentSessionID: UUID? = nil) async -> ExecutionResult {
        await acquire()
        defer { release() }
        var outcomes: [(ReclaimItem, Outcome)] = []
        var reclaimable: UInt64 = 0
        var unknown = 0
        var auditEntries: [LogEntry] = []
        let batchCompressor = if let compressor { compressor } else if items.contains(where: { $0.action == .compress }) {
            await Compressor.production(context: context, log: log)
        } else { nil as Compressor? }
        for item in items {
            if Task.isCancelled { break }
            let volumeUUID = stat.volumeUUID(item.path)
            var reclaimableSize: UInt64?
            let outcome: Outcome
            let observed: Observed?
            if (currentRevision.map { $0 != item.overlayRevision } ?? false)
                || (currentSessionID.map { $0 != item.sessionID } ?? false) {
                outcome = .skipped(.changedSinceReview)
                observed = nil
            } else if case .unavailable(let reason) = item.actionAvailability {
                outcome = .skippedUnavailable(reason)
                observed = nil
            } else if let refusal = reviewRefusal(item, confirmedWarnings: confirmedWarnings, reviewedVerdicts: reviewedVerdicts) {
                outcome = refusal
                observed = nil
            } else if item.action == .compress {
                let engine = batchCompressor
                if let engine {
                    let reviewed = reviewedWarnings?[item.id] ?? Set(itemWarnings(item))
                    let confirmed: Set<Reason> = confirmedWarnings.contains(item.id) ? reviewed : []
                    outcome = .compressed(await engine.compress(item, confirmedWarnings: confirmed))
                } else {
                    outcome = .failed(errno: ENOENT, message: String(localized: "compress.helperUnavailable",
                        defaultValue: "The compression helper is missing or damaged. Reinstall Tesserae.", bundle: L10n.bundle,
                        comment: "Compression is unavailable when the bundled helper fails validation."))
                }
                observed = nil
            } else if case .archive(let format) = item.action {
                let engine = archiver ?? Archiver(trasher: trasher, log: log, context: context)
                let reviewed = reviewedWarnings?[item.id] ?? Set(itemWarnings(item))
                let confirmed: Set<Reason> = confirmedWarnings.contains(item.id) ? reviewed : []
                let archive = await engine.perform(item, format: format, confirmedWarnings: confirmed) { validate in
                    await self.trashArchivedOriginal(item, confirmedWarnings: confirmedWarnings, reviewedWarnings: reviewedWarnings, validate: validate)
                }
                outcome = .archived(archive)
                observed = nil
            } else if item.action != .trash {
                outcome = .failed(errno: ENOTSUP, message: String(localized: "compress.actionUnavailable",
                    defaultValue: "This action is unavailable.", bundle: L10n.bundle,
                    comment: "Refuse an executor action that has no implementation yet."))
                observed = nil
            } else {
                (outcome, observed, reclaimableSize) = execute(item, confirmedWarnings: confirmedWarnings, reviewedWarnings: reviewedWarnings)
            }
            outcomes.append((item, outcome))
            if case .archived(let archive) = outcome {
                if let entry = archive.auditEntry { auditEntries.append(entry) }
                if case .archivedAndTrashed = archive.outcome {
                    let savings = (item.recordedSize ?? 0) - min(item.recordedSize ?? 0, archive.allocatedBytes)
                    let (sum, overflow) = reclaimable.addingReportingOverflow(itemWarnings(item).contains(.containsHardLinks) || itemWarnings(item).contains(.otherHardLinks) ? 0 : savings)
                    reclaimable = overflow ? UInt64.max : sum
                }
                progress?(outcomes.count, items.count)
                continue
            }
            if case .compressed(let compression) = outcome {
                if let entry = compression.auditEntry { auditEntries.append(entry) }
                progress?(outcomes.count, items.count)
                continue
            }
            var trashURL: String?
            let result: String
            switch outcome {
            case .compressed, .archived: preconditionFailure("Compression audit was handled above")
            case .trashed(let url):
                trashURL = url.absoluteString
                result = "ok"
                if item.recordedSize == nil || item.hasUnknownContent || (observed?.flags ?? 0) & UInt32(SF_DATALESS) != 0 { unknown += 1 }
                if let observed, observed.flags & UInt32(SF_DATALESS) == 0,
                   observed.isDirectory || observed.linkCount <= 1,
                   let size = item.recordedSize {
                    let eligible = min(size, reclaimableSize ?? 0)
                    let (sum, overflow) = reclaimable.addingReportingOverflow(eligible)
                    reclaimable = overflow ? UInt64.max : sum
                }
            case .skippedUnavailable: result = "skipped:unavailable"
            case .skipped(let reason): result = "skipped:\(reason)"
            case .notConfirmed(let reason): result = "notConfirmed:\(reason)"
            case .identityChanged(let identity): result = "identityChanged:\(identity)"
            case .failed(let code, _): result = "failed:\(code)"
            }
            let path = String(data: item.path, encoding: .utf8)
            let entry = LogEntry(ts: Date(), action: item.action == .trash ? "trash" : item.action == .compress ? "compress" : "archive", path: path,
                pathB64: path == nil ? item.path.base64EncodedString() : nil,
                inode: item.recorded.fileID, device: item.recorded.device, volumeUUID: volumeUUID,
                isDirectory: item.recorded.isDirectory, hasUnknownContent: item.hasUnknownContent, bytes: item.recordedSize, trashURL: trashURL, result: result)
            auditEntries.append(entry)
            _ = log.append(entry)
            progress?(outcomes.count, items.count)
        }
        return ExecutionResult(outcomes: outcomes, reclaimableBytes: reclaimable, unknownSizeTrashed: unknown, auditEntries: auditEntries)
    }

    private func trashArchivedOriginal(_ item: ReclaimItem, confirmedWarnings: Set<UInt32>, reviewedWarnings: [UInt32: Set<Reason>]?, validate: @Sendable () -> Bool) -> Outcome {
        guard validate() else { return .identityChanged(.inodeChanged) }
        return execute(item, confirmedWarnings: confirmedWarnings, reviewedWarnings: reviewedWarnings, verifiedArchive: true).0
    }

    // A cleared guard cannot grant consent the user withheld in the sheet.
    private func reviewRefusal(_ item: ReclaimItem, confirmedWarnings: Set<UInt32>,
                               reviewedVerdicts: [UInt32: Verdict]?) -> Outcome? {
        guard let reviewedVerdicts else { return nil }
        switch reviewedVerdicts[item.id] {
        case .denied(let reason)?: return .skipped(reason)
        case .warn(let reason)? where !confirmedWarnings.contains(item.id): return .notConfirmed(reason)
        case nil: return .failed(errno: EPERM, message: String(
            localized: "executor.this.item.was.not.included.in.the.confirmation",
            defaultValue: "This item was not included in the confirmation.",
            bundle: L10n.bundle,
            comment: "Executor: This item was not included in the confirmation."
        ))
        case .ok?, .warn?: return nil
        }
    }

    private func execute(_ item: ReclaimItem, confirmedWarnings: Set<UInt32>, reviewedWarnings: [UInt32: Set<Reason>]?, verifiedArchive: Bool = false) -> (Outcome, Observed?, UInt64?) {
        let identity = verifyIdentity(item.path, item.recorded, stat: stat)
        guard identity == .same else { return (.identityChanged(identity), nil, nil) }
        let observed: Observed
        switch stat.lstat(item.path) {
        case .error(let code):
            return (.failed(errno: code, message: NSError(domain: NSPOSIXErrorDomain,
                                                          code: Int(code)).localizedDescription), nil, nil)
        case .ok(let info, let id, let symlink):
            // A second stat can itself witness replacement; fail closed before the guard.
            if symlink { return (.identityChanged(.nowSymlink), nil, nil) }
            if info.device != item.recorded.device { return (.identityChanged(.deviceChanged), nil, nil) }
            if id != item.recorded.fileID { return (.identityChanged(.inodeChanged), nil, nil) }
            if info.isDirectory != item.recorded.isDirectory { return (.identityChanged(.typeChanged), nil, nil) }
            observed = info
        }
        let verdicts = allVerdicts(item.path, observed, context)
        for verdict in verdicts {
            if case .denied(let reason) = verdict { return (.skipped(reason), observed, nil) }
        }
        var warnings = verdicts.compactMap { if case .warn(let reason) = $0 { return reason }; return nil }
        var reclaim = item.recordedSize ?? 0
        for child in item.descendants {
            var excluded = child.unknown
            switch stat.lstat(child.path) {
            case .ok(let info, let id, let symlink):
                excluded = excluded || symlink || id != child.recorded.fileID || info.device != child.recorded.device
                    || info.isDirectory != child.recorded.isDirectory || info.flags & UInt32(SF_DATALESS) != 0 || info.linkCount > 1
                // Only the verified archive handoff may accept an expected link.
                // Its closure rechecks every stamp and raw link target before this walk.
                if (symlink && !(verifiedArchive && child.isSymlink)) || symlink != child.isSymlink
                    || info.device != child.recorded.device || id != child.recorded.fileID || info.isDirectory != child.recorded.isDirectory {
                    warnings.append(.containsUnknownSize)
                }
                if !info.isDirectory && !symlink && info.linkCount > 1 { warnings.append(.containsHardLinks) }
                if info.flags & UInt32(SF_DATALESS) != 0 { warnings.append(.containsCloudOnly); warnings.append(.containsUnknownSize) }
            case .error: warnings.append(.containsUnknownSize); excluded = true
            }
            if !child.recorded.isDirectory && excluded { reclaim -= min(reclaim, child.bytes) }
        }
        let reviewed = reviewedWarnings?[item.id] ?? (reviewedWarnings == nil ? Set(itemWarnings(item)) : [])
        for reason in warnings {
            if !confirmedWarnings.contains(item.id) || !reviewed.contains(reason) {
                return (.notConfirmed(reason), observed, nil)
            }
        }
        do {
            let terminated = item.path + Data([0])
            let url = terminated.withUnsafeBytes {
                URL(fileURLWithFileSystemRepresentation: $0.baseAddress!.assumingMemoryBound(to: CChar.self),
                    isDirectory: observed.isDirectory, relativeTo: nil)
            }
            let represented = url.withUnsafeFileSystemRepresentation {
                $0.map { Data(bytes: $0, count: strlen($0)) }
            }
            guard represented == item.path else {
                return (.failed(errno: EILSEQ, message: String(
                    localized: "executor.file.url.changed.the.raw.path.bytes",
                    defaultValue: "File URL changed the raw path bytes",
                    bundle: L10n.bundle,
                    comment: "Executor: File URL changed the raw path bytes."
                )), observed, nil)
            }
            return (.trashed(trashURL: try trasher.trash(url)), observed, reclaim)
        } catch {
            let error = error as NSError
            let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = posix?.domain == NSPOSIXErrorDomain ? Int32(clamping: posix!.code) : EIO
            return (.failed(errno: code, message: error.localizedDescription), observed, nil)
        }
    }
}
