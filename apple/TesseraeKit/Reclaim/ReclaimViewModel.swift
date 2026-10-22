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
import Darwin
import Foundation

public func reasonText(_ r: Reason) -> String {
    switch r {
    case .appBundleCompress: return String(localized: "reclaimAction.appBundleCompress",
        defaultValue: "Contents are unchanged; Tesserae re-checks the signature afterwards.", bundle: L10n.bundle,
        comment: "Warning before compressing an app bundle.")
    case .gitWorkingTree: return String(localized: "reclaimAction.gitWorkingTree",
        defaultValue: "git status may be slow once.", bundle: L10n.bundle,
        comment: "Warning before compressing a Git working tree.")
    case .largeFile: return String(localized: "reclaimAction.largeFile",
        defaultValue: "This file can't be interrupted mid-file.", bundle: L10n.bundle,
        comment: "Compression warning for a file larger than 4 GiB.")
    case .largeCompressRun: return String(localized: "reclaimAction.largeCompressRun",
        defaultValue: "More than 100 GB is eligible for compression.", bundle: L10n.bundle,
        comment: "Warning for a large compression run.")
    case .containsOtherVolume: return String(localized: "reclaimAction.containsOtherVolume",
        defaultValue: "This item contains another volume's mount point and can't be archived.", bundle: L10n.bundle,
        comment: "Archive denial for a nested volume.")
    case .isArchive: return String(localized: "reclaimAction.isArchive",
        defaultValue: "This item is already an archive in a supported format.", bundle: L10n.bundle,
        comment: "Archive denial for an archive item.")
    case .nonCanonicalPath: return String(
        localized: "reclaimViewModel.this.path.cannot.be.identified.safely",
        defaultValue: "This path cannot be identified safely.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This path cannot be identified safely."
    )
    case .osIntegrity: return String(
        localized: "reclaimViewModel.this.item.is.part.of.macos",
        defaultValue: "This item is part of macOS.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is part of macOS."
    )
    case .systemState: return String(
        localized: "reclaimViewModel.macos.uses.this.item.to.keep.the.system",
        defaultValue: "macOS uses this item to keep the system running.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: macOS uses this item to keep the system running."
    )
    case .appTemporaryFiles: return String(
        localized: "reclaimViewModel.running.apps.use.these.temporary.files",
        defaultValue: "Running apps use these temporary files.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Running apps use these temporary files."
    )
    case .systemManaged: return String(
        localized: "reclaimViewModel.macos.manages.this.item",
        defaultValue: "macOS manages this item.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: macOS manages this item."
    )
    case .timeMachineBackup: return String(
        localized: "reclaimViewModel.time.machine.manages.this.backup",
        defaultValue: "Time Machine manages this backup.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Time Machine manages this backup."
    )
    case .userAccountCore: return String(
        localized: "reclaimViewModel.this.item.is.essential.to.your.user.account",
        defaultValue: "This item is essential to your user account.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is essential to your user account."
    )
    case .volumeRootOrTopLevel: return String(
        localized: "reclaimViewModel.this.item.is.the.volume.root.or.a",
        defaultValue: "This item is the volume root or a top-level folder.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is the volume root or a top-level folder."
    )
    case .otherVolume: return String(
        localized: "reclaimViewModel.this.item.is.on.a.different.volume.from",
        defaultValue: "This item is on a different volume from the scan.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is on a different volume from the scan."
    )
    case .selfOrAncestorOfApp: return String(
        localized: "reclaimViewModel.this.item.contains.the.running.tesserae.app",
        defaultValue: "This item contains the running Tesserae app.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item contains the running Tesserae app."
    )
    case .alreadyInTrash: return String(
        localized: "reclaimViewModel.already.in.the.trash.empty.it.from.finder",
        defaultValue: "Already in the Trash — empty it from Finder.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Already in the Trash — empty it from Finder."
    )
    case .restricted: return String(
        localized: "reclaimViewModel.macos.system.integrity.protection.protects.this.item",
        defaultValue: "macOS System Integrity Protection protects this item.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: macOS System Integrity Protection protects this item."
    )
    case .immutable: return String(
        localized: "reclaimViewModel.this.item.is.locked.against.changes",
        defaultValue: "This item is locked against changes.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is locked against changes."
    )
    case .symlinkInPath: return String(
        localized: "reclaimViewModel.this.path.contains.a.symbolic.link.and.cannot",
        defaultValue: "This path contains a symbolic link and cannot be trashed safely.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This path contains a symbolic link and cannot be trashed safely."
    )
    case .appContainer: return String(
        localized: "reclaimViewModel.removing.an.app.s.container.resets.that.app",
        defaultValue: "Removing an app's container resets that app, including documents of sandboxed apps.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Removing an app's container resets that app, including documents of sandboxed apps."
    )
    case .cloudOnly: return String(
        localized: "reclaimViewModel.cloud.only.trashing.removes.it.from.icloud.on",
        defaultValue: "Cloud-only: trashing removes it from iCloud on all your devices and frees no space on this Mac.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Cloud-only: trashing removes it from iCloud on all your devices and frees no space on this Mac."
    )
    case .otherHardLinks: return String(
        localized: "reclaimViewModel.other.hard.links.point.to.this.file.its",
        defaultValue: "Other hard links point to this file; its space is freed only when every link is gone.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Other hard links point to this file; its space is freed only when every link is gone."
    )
    case .containsUnknownSize: return String(
        localized: "reclaimViewModel.this.folder.contains.unreadable.or.skipped.content.its",
        defaultValue: "This folder contains unreadable or skipped content; its size is only the known part.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This folder contains unreadable or skipped content; its size is only the known part."
    )
    case .containsCloudOnly: return String(
        localized: "reclaimViewModel.this.folder.contains.cloud.only.items.trashing.removes",
        defaultValue: "This folder contains cloud-only items. Trashing removes them from iCloud on all your devices.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This folder contains cloud-only items. Trashing removes them from iCloud on all your devices."
    )
    case .containsHardLinks: return String(
        localized: "reclaimViewModel.this.folder.contains.hard.links.space.is.freed",
        defaultValue: "This folder contains hard links; space is freed only when every link is gone.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This folder contains hard links; space is freed only when every link is gone."
    )
    case .changedSinceReview: return String(
        localized: "reclaimViewModel.this.item.changed.since.review.review.it.again",
        defaultValue: "This item changed since review; review it again before moving to Trash.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item changed since review; review it again before moving to Trash."
    )
    case .changedSinceScan: return String(
        localized: "reclaimViewModel.this.item.changed.since.the.scan.rescan.before",
        defaultValue: "This item changed since the scan; rescan before staging it.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item changed since the scan; rescan before staging it."
    )
    case .noRecordedIdentity: return String(
        localized: "reclaimViewModel.the.scan.could.not.record.this.item.s",
        defaultValue: "The scan could not record this item's identity.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: The scan could not record this item's identity."
    )
    }
}

public func itemWarnings(_ item: ReclaimItem) -> [Reason] {
    var reasons = item.warnings
    if case .warn(let reason) = item.verdict, !reasons.contains(reason) { reasons.insert(reason, at: 0) }
    return reasons
}

public struct WarningRow: Identifiable {
    public let id: UInt32
    public let path: String
    public let texts: [String]
}

public struct TrashConfirmation {
    public let items: [ReclaimItem]
    public var notes: [UInt32: [String]] = [:]
    public var overlayRevision: UInt64? { items.first?.overlayRevision }
    public var sessionID: UUID? { items.first?.sessionID }
    public private(set) var confirmedWarnings: Set<UInt32> = []
    public init(items: [ReclaimItem]) { self.items = items }
    public var warningItems: [ReclaimItem] { items.filter { if case .denied = $0.verdict { return false }; return $0.actionAvailability == .available && !itemWarnings($0).isEmpty } }
    public var groupedForConfirmation: [(ReclaimAction, [ReclaimItem])] { confirmationGroups(items) }
    public var warningRows: [WarningRow] {
        warningItems.map { WarningRow(id: $0.id, path: $0.displayPath,
                                      texts: itemWarnings($0).map(reasonText)) }
    }
    public var deniedItems: [ReclaimItem] { items.filter { if case .denied = $0.verdict { return true }; return $0.actionAvailability != .available } }
    public var movingCount: Int {
        items.filter { item in
            guard item.actionAvailability == .available else { return false }
            switch item.verdict {
            case .ok: return true
            case .warn: return confirmedWarnings.contains(item.id)
            case .denied: return false
            }
        }.count
    }
    public mutating func setConfirmed(_ id: UInt32, _ checked: Bool) {
        guard warningItems.contains(where: { $0.id == id }) else { return }
        if checked { confirmedWarnings.insert(id) } else { confirmedWarnings.remove(id) }
    }
    public func total(locale: Locale = .current) -> String {
        if items.isEmpty {
            return String(localized: "reclaim.nothingStaged", defaultValue: "Nothing staged",
                bundle: L10n.bundle, locale: locale, comment: "Summary when no items are staged for reclaiming space.")
        }
        var known: UInt64 = 0
        var unknown = 0
        for item in items {
            if item.actionAvailability != .available { continue }
            if case .denied = item.verdict { continue }
            if let bytes = item.recordedSize {
                let (sum, overflow) = known.addingReportingOverflow(bytes)
                known = overflow ? UInt64.max : sum
            }
            if item.recordedSize == nil || item.hasUnknownContent { unknown += 1 }
        }
        let size = ReclaimCopy.size(known, upperBound: items.contains { $0.recorded.isDirectory }, locale: locale)
        return unknown > 0
            ? String(
                localized: "reclaim.staged.unknown",
                defaultValue: "\(size) staged · \(unknown) items of unknown size",
                bundle: L10n.bundle,
                locale: L10n.pluralLocale(locale),
                comment: "Staged byte size and count of items with unknown size."
            )
            : String(
                localized: "reclaim.staged.size",
                defaultValue: "\(size) staged",
                bundle: L10n.bundle,
                locale: locale,
                comment: "Total formatted byte size staged for Trash."
            )
    }
}

public func trashSummaryText(_ result: ExecutionResult, locale: Locale = .current) -> String {
    let upperBound = result.outcomes.contains { item, outcome in
        if case .trashed = outcome { return item.recorded.isDirectory }; return false
    }
    let size = ReclaimCopy.size(result.reclaimableBytes, upperBound: upperBound, locale: locale)
    return result.unknownSizeTrashed > 0
        ? String(
            localized: "reclaim.summary.unknown",
            defaultValue: "\(size) moved to Trash — empty Trash to reclaim it (plus \(result.unknownSizeTrashed) items of unknown size)",
            bundle: L10n.bundle,
            locale: L10n.pluralLocale(locale),
            comment: "Trash result: formatted bytes and additional items of unknown size."
        )
        : String(
            localized: "reclaim.summary.size",
            defaultValue: "\(size) moved to Trash — empty Trash to reclaim it",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Trash result: formatted bytes moved, awaiting emptying Trash."
        )
}

public func outcomeText(_ outcome: Outcome) -> String {
    switch outcome {
    case .compressed(let result): return result.displayResult
    case .archived(let run):
        switch run.outcome {
        case .failed(let reason, let discarded):
            if discarded != nil {
                return String(localized: "reclaim.archiveFailedRestorable",
                    defaultValue: "Archive failed: \(reason) The incomplete archive is in the Trash. Use Put Back to restore it.",
                    bundle: L10n.bundle, comment: "Failed archive can be restored with the Put Back button.")
            }
            return String(localized: "reclaim.archiveFailed",
            defaultValue: "Archive failed: \(reason)", bundle: L10n.bundle, comment: "Archive failure and its reason.")
        case .archivedOriginalsKept(_, let reason): return reason
        case .archivedAndTrashed: return String(localized: "archive.created",
            defaultValue: "Archive verified. Originals moved to Trash. Rescan to see the archive in the map.", bundle: L10n.bundle,
            comment: "Successful archive result and explanation that the new archive appears after rescanning.")
        }
    case .trashed: return String(
        localized: "reclaimViewModel.moved.to.trash",
        defaultValue: "Moved to Trash.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Moved to Trash."
    )
    case .skippedUnavailable(let reason): return String(localized: "reclaim.skippedUnavailable",
        defaultValue: "Skipped: \(reason)", bundle: L10n.bundle, comment: "An unavailable staged action was skipped with this reason.")
    case .skipped(let reason): return String(
        localized: "reclaimViewModel.skipped",
        defaultValue: "Skipped: \(reasonText(reason))",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Skipped: {reasonText(reason)}."
    )
    case .notConfirmed(let reason): return String(
        localized: "reclaimViewModel.not.confirmed",
        defaultValue: "Not confirmed: \(reasonText(reason))",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Not confirmed: {reasonText(reason)}."
    )
    case .failed(let code, let message): return String(
        localized: "reclaimViewModel.failed.errno",
        defaultValue: "Failed: \(message) (errno \(code)).",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Failed: {message} (errno {code})."
    )
    case .identityChanged(let identity):
        let text: String
        switch identity {
        case .same: text = String(
            localized: "reclaimViewModel.identity.could.not.be.verified",
            defaultValue: "Identity could not be verified.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: Identity could not be verified."
        )
        case .gone: text = String(
            localized: "reclaimViewModel.this.item.no.longer.exists",
            defaultValue: "This item no longer exists.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This item no longer exists."
        )
        case .inodeChanged: text = String(
            localized: "reclaimViewModel.a.different.item.now.occupies.this.path",
            defaultValue: "A different item now occupies this path.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: A different item now occupies this path."
        )
        case .deviceChanged: text = String(
            localized: "reclaimViewModel.this.item.s.volume.changed",
            defaultValue: "This item's volume changed.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This item's volume changed."
        )
        case .nowSymlink: text = String(
            localized: "reclaimViewModel.this.item.is.now.a.symbolic.link",
            defaultValue: "This item is now a symbolic link.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This item is now a symbolic link."
        )
        case .typeChanged: text = String(
            localized: "reclaimViewModel.this.item.s.file.type.changed",
            defaultValue: "This item's file type changed.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This item's file type changed."
        )
        case .symlinkInPath: text = String(
            localized: "reclaimViewModel.this.path.now.contains.a.symbolic.link",
            defaultValue: "This path now contains a symbolic link.",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This path now contains a symbolic link."
        )
        case .unreadable(let code): text = String(
            localized: "reclaimViewModel.this.item.s.identity.could.not.be.read",
            defaultValue: "This item's identity could not be read (errno \(code)).",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: This item's identity could not be read (errno {code})."
        )
        }
        return String(
            localized: "reclaimViewModel.skipped",
            defaultValue: "Skipped: \(text)",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: Skipped: {text}."
        )
    }
}

public func putBackText(_ result: PutBackResult) -> String {
    switch result {
    case .restored: return String(
        localized: "reclaimViewModel.put.back.in.its.original.location",
        defaultValue: "Put back in its original location.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Put back in its original location."
    )
    case .trashItemGone: return String(
        localized: "reclaimViewModel.this.item.is.no.longer.in.the.trash",
        defaultValue: "This item is no longer in the Trash.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: This item is no longer in the Trash."
    )
    case .trashItemChanged: return String(
        localized: "reclaimViewModel.the.item.in.the.trash.has.changed",
        defaultValue: "The item in the Trash has changed.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: The item in the Trash has changed."
    )
    case .originalOccupied: return String(
        localized: "reclaimViewModel.the.original.location.is.occupied.nothing.was.overwritten",
        defaultValue: "The original location is occupied; nothing was overwritten.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: The original location is occupied; nothing was overwritten."
    )
    case .parentMissing: return String(
        localized: "reclaimViewModel.the.original.parent.folder.is.missing",
        defaultValue: "The original parent folder is missing.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: The original parent folder is missing."
    )
    case .failed(let message): return String(
        localized: "reclaimViewModel.put.back.failed",
        defaultValue: "Put Back failed: \(message)",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Put Back failed: {message}."
    )
    }
}

@MainActor
public func openTrash(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    _ = opener(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
}

public enum ReclaimCopy {
    public static func size(_ bytes: UInt64?, upperBound: Bool, unknownContent: Bool = false,
                            locale: Locale = .current) -> String {
        guard let bytes else {
            return String(
                localized: "reclaim.size.unknown",
                defaultValue: "Unknown size",
                bundle: L10n.bundle,
                comment: "Size is unavailable for this staged item."
            )
        }
        let size = displaySize(bytes, locale: locale)
        switch (upperBound, unknownContent) {
        case (true, true): return String(
            localized: "reclaim.size.upperBound.unknown",
            defaultValue: "Up to \(size) + unknown content",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Upper bound byte size with additional unreadable content."
        )
        case (true, false): return String(
            localized: "reclaim.size.upperBound",
            defaultValue: "Up to \(size)",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Upper bound on the size of a directory. The value is a formatted byte size."
        )
        case (false, true): return String(
            localized: "reclaim.size.known.unknown",
            defaultValue: "\(size) + unknown content",
            bundle: L10n.bundle,
            locale: locale,
            comment: "Known byte size with additional unreadable content."
        )
        case (false, false): return size
        }
    }

    public static let putBackWhileScanning = String(
        localized: "reclaimViewModel.put.back.is.unavailable.while.scanning.try.again",
        defaultValue: "Put Back is unavailable while scanning — try again when the scan finishes, or use Finder",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Put Back is unavailable while scanning — try again when the scan finishes, or use Finder."
    )
    public static let changedSinceScan = String(
        localized: "reclaimViewModel.files.changed.since.this.scan.rescan.to.stage",
        defaultValue: "Files changed since this scan — rescan to stage items",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Files changed since this scan — rescan to stage items."
    )

    public static let unavailable = String(
        localized: "reclaimViewModel.can.t.stage.items.tesserae.couldn.t.identify",
        defaultValue: "Can't stage items: Tesserae couldn't identify this scan's volume. Rescan to try again.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: Can't stage items: Tesserae couldn't identify this scan's volume. Rescan to try again."
    )
    public static let logFailure = String(
        localized: "reclaimViewModel.the.tesserae.log.couldn.t.be.written.trashing",
        defaultValue: "The Tesserae log couldn't be written; trashing still worked.",
        bundle: L10n.bundle,
        comment: "ReclaimViewModel: The Tesserae log couldn't be written; trashing still worked."
    )
    public static func items(_ count: Int, locale: Locale = .current) -> String { String(
        localized: "reclaimViewModel.items",
        defaultValue: "\(count) items",
        bundle: L10n.bundle,
        locale: L10n.pluralLocale(locale),
        comment: "ReclaimViewModel: {count} items."
    ) }
    public static func staged(_ count: Int, locale: Locale = .current) -> String { String(
        localized: "reclaimViewModel.staged.items",
        defaultValue: "\(count) staged items",
        bundle: L10n.bundle,
        locale: L10n.pluralLocale(locale),
        comment: "ReclaimViewModel: {count} staged items."
    ) }
    public static func moving(_ count: Int, locale: Locale = .current) -> String { String(
        localized: "reclaimViewModel.items.will.move",
        defaultValue: "\(count) items will move",
        bundle: L10n.bundle,
        locale: L10n.pluralLocale(locale),
        comment: "ReclaimViewModel: {count} items will move."
    ) }
    public static func failedFiles(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "reclaim.failedFiles", defaultValue: "\(count) files failed.",
            bundle: L10n.bundle, locale: L10n.pluralLocale(locale), comment: "Number of files that did not complete compression.")
    }
    public static func proceeding(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "reclaim.proceeding", defaultValue: "\(count) items will proceed",
            bundle: L10n.bundle, locale: L10n.pluralLocale(locale), comment: "Count of confirmed staged actions that can proceed.")
    }
    public static func processed(_ done: Int, _ total: Int, locale: Locale = .current) -> String { String(
        localized: "reclaimViewModel.of.items.processed",
        defaultValue: "\(done) of \(total) items processed",
        bundle: L10n.bundle,
        locale: L10n.pluralLocale(locale),
        comment: "ReclaimViewModel: {done} of {total} items processed."
    ) }
    public static func rescan(_ count: Int, locale: Locale = .current) -> String { String(
        localized: "reclaimViewModel.sizes.include.trashed.items.rescan.for.exact.figures",
        defaultValue: "Sizes include \(count) trashed items; rescan for exact figures",
        bundle: L10n.bundle,
        locale: L10n.pluralLocale(locale),
        comment: "ReclaimViewModel: Sizes include {count} trashed items; rescan for exact figures."
    ) }
}

@MainActor
final class ReclaimContextMenu: NSObject {
    var stage: (() -> Void)?
    func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: String(
            localized: "reclaimViewModel.add.to.reclaim.space",
            defaultValue: "Add to Reclaim Space",
            bundle: L10n.bundle,
            comment: "ReclaimViewModel: Add to Reclaim Space."
        ), action: #selector(add), keyEquivalent: "\u{8}")
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.isEnabled = stage != nil
        menu.addItem(item)
        return menu
    }
    @objc private func add() { stage?() }
}

public func confirmationGroups(_ items: [ReclaimItem]) -> [(ReclaimAction, [ReclaimItem])] {
    let actions: [ReclaimAction] = [.compress] + ArchiveFormat.allCases.map { .archive($0) } + [.trash]
    return actions.compactMap { action in
        let group = items.filter {
            guard $0.action == action, $0.actionAvailability == .available else { return false }
            if case .denied = $0.verdict { return false }
            return true
        }
        return group.isEmpty ? nil : (action, group)
    }
}

@MainActor
public final class ReclaimViewModel: ObservableObject {
    @Published public private(set) var items: [ReclaimItem]
    @Published public private(set) var preparing = false
    private var originals: [ReclaimItem]
    private var volumes: [UInt32: VolumeCapabilities]
    private var reports: [UInt32: CompressionReview] = [:]
    private var helperAvailability: Availability = .available
    private var choices: [UInt32: ReclaimAction] = [:]
    private var estimates: [UInt32: UInt64] = [:]
    private let defaults: UserDefaults?
    private var generation: UInt64 = 0
    private var preparation: Task<Void, Never>?
    private var estimation: Task<Void, Never>?
    public init(items: [ReclaimItem] = [], volumes: [UInt32: VolumeCapabilities] = [:],
                defaults: UserDefaults? = .standard) {
        self.items = items; self.originals = items; self.volumes = volumes; self.defaults = defaults
        rebuild()
    }
    public var groupedForConfirmation: [(ReclaimAction, [ReclaimItem])] { confirmationGroups(items) }
    public var needsPreparation: Bool { items.contains { volumes[$0.id] == nil } }
    public func volume(for item: ReclaimItem) -> VolumeCapabilities {
        volumes[item.id] ?? VolumeCapabilities(isLocal: false, isWritable: false, fsType: "")
    }
    public func availability(_ action: ReclaimAction, for item: ReclaimItem) -> Availability {
        if case .denied(let reason) = item.verdict { return .unavailable(reasonText(reason)) }
        guard let capabilities = volumes[item.id] else {
            return .unavailable(String(localized: "reclaim.preparingActions", defaultValue: "Preparing actions…",
                bundle: L10n.bundle, comment: "Volume capabilities are being prepared before action selection."))
        }
        guard !capabilities.fsType.isEmpty else { return .unavailable(ReclaimCopy.unavailable) }
        if action == .compress, volume(for: item).canCompress, helperAvailability != .available { return helperAvailability }
        return availableActions(for: item, volume: volume(for: item), verdict: item.verdict)[action]
            ?? .unavailable(ReclaimCopy.unavailable)
    }
    public func archiveAction(for item: ReclaimItem) -> ReclaimAction {
        let selected = ReclaimAction.archive(selectedFormat(for: item))
        if availability(selected, for: item) == .available { return selected }
        return ArchiveFormat.allCases.map { ReclaimAction.archive($0) }
            .first { availability($0, for: item) == .available } ?? selected
    }
    public func previewText(for item: ReclaimItem) -> [String] {
        guard item.action == .compress, let report = reports[item.id] else { return [] }
        var lines = report.skipped.keys.sorted(by: { String(describing: $0) < String(describing: $1) }).map { reason in
            let count = report.skipped[reason]!
            return String(localized: "reclaim.skippedFiles", defaultValue: "\(count) skipped: \(reason.localizedDescription)",
                bundle: L10n.bundle, comment: "Compression exclusion count and reason.")
        }
        if !report.inspectedAll {
            lines.append(String(localized: "reclaim.processWarning",
                defaultValue: "Processes belonging to other users could not all be inspected.", bundle: L10n.bundle,
                comment: "Best effort open-file inspection limitation."))
        }
        return lines
    }
    public func selectedFormat(for item: ReclaimItem) -> ArchiveFormat {
        if case .archive(let format) = item.action { return format }
        let kind = volume(for: item).fsType
        return defaults?.string(forKey: "reclaim.format." + kind).flatMap(ArchiveFormat.init(rawValue:))
            ?? defaultFormat(volumeFSType: kind)
    }
    public func formats(for item: ReclaimItem, advanced: Bool) -> [ArchiveFormat] {
        let kind = volume(for: item).fsType, first = defaultFormat(volumeFSType: kind)
        return ([first] + ArchiveFormat.allCases.filter { $0 != first })
            .filter { isAdvanced($0, volumeFSType: kind) == advanced }
    }
    public func setAction(_ action: ReclaimAction, for id: UInt32) {
        guard let item = items.first(where: { $0.id == id }), item.action != action,
              availability(action, for: item) == .available else { return }
        choices[id] = action; estimates[id] = nil
        if case .archive(let format) = action {
            defaults?.set(format.rawValue, forKey: "reclaim.format." + volume(for: item).fsType)
        }
        rebuild()
        if !volumes.isEmpty { estimateSelected() }
    }
    public func setEstimate(_ bytes: UInt64, for id: UInt32) { estimates[id] = bytes }
    public func estimateText(for item: ReclaimItem, locale: Locale = .current) -> String {
        if item.action == .trash {
            return ReclaimCopy.size(item.recordedSize, upperBound: item.recorded.isDirectory,
                unknownContent: item.hasUnknownContent, locale: locale)
        }
        if case .unavailable(let reason) = item.actionAvailability { return reason }
        guard let bytes = estimates[item.id] else { return ReclaimCopy.preparingEstimate }
        let size = displaySize(bytes, locale: locale)
        if item.action == .compress {
            return String(localized: "reclaim.estimateCompress", defaultValue: "Saves about \(size) (estimated)",
                bundle: L10n.bundle, locale: locale, comment: "Estimated savings for in-place compression.")
        }
        return String(localized: "reclaim.estimateArchive",
            defaultValue: "Saves about \(size) once you empty the Trash (estimated)",
            bundle: L10n.bundle, locale: locale, comment: "Estimated archive savings require emptying the Trash.")
    }
    private func rebuild() {
        items = originals.map { original in
            var item = original
            item.action = choices[item.id] ?? item.action
            let warnings = itemWarnings(item) + actionWarnings(for: item, action: item.action, facts: item.archiveFacts)
            if case .denied = item.verdict {} else if let reason = warnings.first { item.verdict = .warn(reason) }
            return ReclaimItem(nodeIndex: item.nodeIndex, path: item.path, recorded: item.recorded,
                recordedSize: item.recordedSize, verdict: item.verdict, warnings: warnings.reduce(into: [Reason]()) { if !$0.contains($1) { $0.append($1) } },
                hasUnknownContent: item.hasUnknownContent, descendants: item.descendants,
                overlayRevision: item.overlayRevision, sessionID: item.sessionID, action: item.action, actionAvailability: availability(item.action, for: item), archiveFacts: item.archiveFacts)
        }
    }
    public func replace(_ items: [ReclaimItem], volumes: [UInt32: VolumeCapabilities]) {
        generation &+= 1
        preparation?.cancel(); estimation?.cancel()
        preparing = !items.isEmpty && items.contains { volumes[$0.id] == nil }
        self.volumes = volumes
        helperAvailability = .available
        originals = items; estimates = [:]; reports = [:]; rebuild()
    }
    public func prepare(_ items: [ReclaimItem], context: GuardContext?) {
        generation &+= 1
        let token = generation
        preparation?.cancel(); estimation?.cancel()
        originals = items; estimates = [:]; rebuild()
        guard !items.isEmpty else { preparing = false; return }
        preparing = true
        preparation = Task {
            let work = Task.detached(priority: .utility) {
                var openEvidence: (keys: Set<FileKey>, inspectedAll: Bool)?
                return items.map { item -> (ReclaimItem, VolumeCapabilities, CompressionReview?) in
                    var item = item
                    var info = statfs()
                    let ok = archiveCString(item.path) { statfs($0, &info) == 0 }
                    let kind = withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    let volume = VolumeCapabilities(isLocal: ok && info.f_flags & UInt32(MNT_LOCAL) != 0,
                        isWritable: ok && info.f_flags & UInt32(MNT_RDONLY) == 0, fsType: kind)
                    if Task.isCancelled || !ok { return (item, volume, nil) }
                    if case .denied = item.verdict { return (item, volume, nil) }
                    if let inspection = try? ProductionArchiveFileSystem().inspect(item.path) {
                        item.archiveFacts = inspection.facts
                        if inspection.stamps.contains(where: { $0.key != item.path && $0.value.mode & S_IFMT == S_IFREG && $0.value.links > 1 }) {
                            item = ReclaimItem(nodeIndex: item.nodeIndex, path: item.path, recorded: item.recorded,
                                recordedSize: item.recordedSize, verdict: item.verdict,
                                warnings: item.warnings.contains(.containsHardLinks) ? item.warnings : item.warnings + [.containsHardLinks],
                                hasUnknownContent: item.hasUnknownContent, descendants: item.descendants,
                                overlayRevision: item.overlayRevision, sessionID: item.sessionID, action: item.action,
                                actionAvailability: item.actionAvailability, archiveFacts: item.archiveFacts)
                        }
                    }
                    else { item.archiveFacts.containsUnknownContent = true }
                    if volume.canCompress, openEvidence == nil { openEvidence = LibprocOpenFilesProbe().openForWriting() }
                    let report = volume.canCompress ? Compressor.reviewReport(item, openFiles: openEvidence)
                        : CompressionReview(files: [], skipped: [:], inspectedAll: true)
                    if let context {
                        let facts = Compressor.reviewFacts(item, context: context, files: report.files)
                        item.archiveFacts.containsGitWorkingTree = facts.containsGitWorkingTree
                        item.archiveFacts.containsAppBundle = facts.containsAppBundle
                        item.archiveFacts.largestFileSize = facts.largestFileSize
                        item.archiveFacts.eligibleBytes = facts.eligibleBytes
                    }
                    item.archiveFacts.mutationAncestrySafe = mutationAncestryIsSafe(item.path, volumeRoot: context?.volumeRoot)
                    if let parent = try? archiveParts(item.path).parent {
                        item.archiveFacts.parentWritable = archiveCString(parent) { access($0, W_OK) == 0 }
                    }
                    return (item, volume, report)
                }
            }
            let prepared = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, token == generation else { return }
            let helper = if prepared.contains(where: { $0.1.canCompress }) {
                await CompressionHelper.locateAsync(bundle: .main)
            } else { Result<URL, HelperProblem>.failure(.missing) }
            guard !Task.isCancelled, token == generation else { return }
            if case .success = helper { helperAvailability = .available }
            else { helperAvailability = .unavailable(String(localized: "compress.helperUnavailable",
                defaultValue: "The compression helper is missing or damaged. Reinstall Tesserae.", bundle: L10n.bundle,
                comment: "Compression is unavailable when the bundled helper fails validation.")) }
            originals = prepared.map { $0.0 }
            reports = Dictionary(uniqueKeysWithValues: prepared.compactMap { row in row.2.map { (row.0.id, $0) } })
            volumes = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.id, $0.1) })
            rebuild(); preparing = false
            estimateSelected()
        }
    }
    func waitForEstimate() async { await estimation?.value }

    private func estimateSelected() {
        estimation?.cancel()
        preparing = true
        let frozen = items, token = generation, preparedReports = reports
        estimation = Task {
            let work = Task.detached(priority: .utility) {
                frozen.compactMap { item -> (UInt32, UInt64)? in
                    guard item.action != .trash, item.actionAvailability == .available else { return nil }
                    let savings: UInt64
                    if case .archive(let format) = item.action {
                        guard let inspection = try? ProductionArchiveFileSystem().inspect(item.path) else { return nil }
                        let estimatedSaving = SampleEstimate.archive(format, files: inspection.files)
                        let estimatedArchive = inspection.facts.eligibleBytes - min(inspection.facts.eligibleBytes, estimatedSaving)
                        savings = (item.recordedSize ?? 0) - min(item.recordedSize ?? 0, estimatedArchive)
                    } else { savings = SampleEstimate.compress(files: preparedReports[item.id]?.files ?? Compressor.reviewFiles(item)) }
                    return (item.id, savings)
                }
            }
            let values = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, token == generation, items == frozen else { return }
            for (id, bytes) in values { estimates[id] = bytes }
            preparing = false
            objectWillChange.send()
        }
    }
    deinit { preparation?.cancel(); estimation?.cancel() }
}

public struct DecompressConfirmation: Sendable {
    public let run: CompressRunID
    public let rows: [CompressManifest.Row]
    public let warnings: [Data: [Reason]]
    public private(set) var confirmedPaths: Set<Data> = []
    public init(run: CompressRunID, rows: [CompressManifest.Row], warnings: [Data: [Reason]]) {
        self.run = run; self.rows = rows; self.warnings = warnings
    }
    public var fileCount: Int { rows.count }
    public var title: String { title(locale: .current) }
    public func title(locale: Locale) -> String {
        String(localized: "reclaim.decompressConfirm", defaultValue: "Decompress \(fileCount) files?",
            bundle: L10n.bundle, locale: L10n.pluralLocale(locale), comment: "Decompression confirmation names the manifest file count.")
    }
    public var warningRows: [CompressManifest.Row] { rows.filter { !(warnings[$0.path] ?? []).isEmpty } }
    public var allowedPaths: Set<Data> {
        Set(rows.filter { (warnings[$0.path] ?? []).isEmpty || confirmedPaths.contains($0.path) }.map(\.path))
    }
    public mutating func setConfirmed(_ path: Data, _ value: Bool) {
        guard warningRows.contains(where: { $0.path == path }) else { return }
        if value { confirmedPaths.insert(path) } else { confirmedPaths.remove(path) }
    }
}

extension ReclaimCopy {
    public static let preparingEstimate = String(localized: "reclaim.preparingEstimate", defaultValue: "Preparing estimate…",
        bundle: L10n.bundle, comment: "Read-only estimate has not completed.")
    public static let review = String(localized: "reclaim.review", defaultValue: "Review actions…",
        bundle: L10n.bundle, comment: "Open the confirmation for all staged actions.")
    public static let advanced = String(localized: "reclaim.advanced", defaultValue: "Advanced",
        bundle: L10n.bundle, comment: "Collapsed disclosure for advanced archive formats.")
    public static let noCompressedItems = String(localized: "reclaim.noCompressedItems", defaultValue: "No compressed items.",
        bundle: L10n.bundle, comment: "Empty state for the recently compressed history.")
    public static let recentlyCompressed = String(localized: "reclaim.recentlyCompressed", defaultValue: "Recently compressed",
        bundle: L10n.bundle, comment: "Heading for reversible compression runs.")
    public static let decompress = String(localized: "reclaim.decompress", defaultValue: "Decompress…",
        bundle: L10n.bundle, comment: "Review decompression of this run.")
}

extension ReclaimAction {
    public var title: String {
        switch self {
        case .trash: return String(localized: "reclaim.actionTrash", defaultValue: "Move to Trash",
            bundle: L10n.bundle, comment: "Move this staged item to Trash.")
        case .compress: return String(localized: "reclaim.actionCompress", defaultValue: "Compress",
            bundle: L10n.bundle, comment: "Compress this staged item in place.")
        case .archive: return String(localized: "reclaim.actionArchive", defaultValue: "Archive",
            bundle: L10n.bundle, comment: "Archive this staged item beside its original.")
        }
    }
}
extension ArchiveFormat {
    public var title: String {
        switch self {
        case .zip: return String(localized: "reclaim.formatZIP", defaultValue: "ZIP", bundle: L10n.bundle, comment: "ZIP format name.")
        case .tarXZ: return String(localized: "reclaim.formatXZ", defaultValue: "tar.xz", bundle: L10n.bundle, comment: "XZ tar format name.")
        case .tarZst: return String(localized: "reclaim.formatZst", defaultValue: "tar.zst", bundle: L10n.bundle, comment: "Zstandard tar format name.")
        case .appleArchiveFast: return String(localized: "reclaim.formatFast", defaultValue: "Apple Archive, fast (.aar, LZFSE)", bundle: L10n.bundle, comment: "Fast Apple Archive format.")
        case .appleArchiveSmallest: return String(localized: "reclaim.formatSmallest", defaultValue: "Apple Archive, smallest (.aar, LZMA)", bundle: L10n.bundle, comment: "Small Apple Archive format.")
        }
    }
    public var note: String {
        switch self {
        case .zip: return String(localized: "reclaim.noteZIP", defaultValue: "Opens anywhere, including Finder and Windows.", bundle: L10n.bundle, comment: "ZIP compatibility note.")
        case .tarXZ: return String(localized: "reclaim.noteXZ", defaultValue: "Smallest; slow to create. Opens in Finder (Archive Utility).", bundle: L10n.bundle, comment: "XZ compatibility note.")
        case .tarZst: return String(localized: "reclaim.noteZst", defaultValue: "Very fast, with good compression. Finder and macOS's tar can't open it; install zstd (for example with Homebrew) or use an app such as Keka.", bundle: L10n.bundle, comment: "Zstandard compatibility note.")
        case .appleArchiveFast: return String(localized: "reclaim.noteFast", defaultValue: "Very fast; about ZIP's size; keeps all Mac metadata. Opens in Finder on a Mac only.", bundle: L10n.bundle, comment: "Fast Apple Archive compatibility note.")
        case .appleArchiveSmallest: return String(localized: "reclaim.noteSmallest", defaultValue: "Nearly as small as tar.xz and several times faster; keeps all Mac metadata. Opens in Finder on a Mac only.", bundle: L10n.bundle, comment: "Small Apple Archive compatibility note.")
        }
    }
}

extension ExecutionResult {
    public var hasTrashedItems: Bool { outcomes.contains { $0.1.trashDestination != nil } }
    public func summary(locale: Locale = .current) -> String? {
        if outcomes.contains(where: {
            if case .archived(let run) = $0.1, case .archivedAndTrashed = run.outcome { return true }
            return false
        }) {
            let size = ReclaimCopy.size(reclaimableBytes, upperBound: false,
                unknownContent: unknownSizeTrashed > 0, locale: locale)
            return String(localized: "reclaim.savingsHeadline", defaultValue: "Saves about \(size) once you empty the Trash",
                bundle: L10n.bundle, locale: locale, comment: "Archive and Trash savings become available after emptying Trash.")
        }
        if outcomes.contains(where: { if case .trashed = $0.1 { return true }; return false }) {
            return trashSummaryText(self, locale: locale)
        }
        let compressed = outcomes.compactMap { if case .compressed(let result) = $0.1 { return result }; return nil as CompressOutcome? }
        guard !compressed.isEmpty else { return nil }
        return CompressOutcome.summary(count: compressed.reduce(0) { $0 + $1.compressed },
            savings: compressed.reduce(0) { $0 + $1.savings }, locale: locale)
    }
}
extension Outcome {
    public var trashDestination: URL? {
        switch self {
        case .trashed(let url): return url
        case .archived(let run):
            switch run.outcome {
            case .archivedAndTrashed(_, _, let url), .failed(_, let url?): return url
            default: return nil
            }
        default: return nil
        }
    }
}

extension LogEntry {
    public var displayPath: String {
        if let path { return neutralisedPath(Data(path.utf8)) }
        if let pathB64, let bytes = Data(base64Encoded: pathB64) { return neutralisedPath(bytes) }
        return String(localized: "reclaim.pathBytes", defaultValue: "Path bytes: ",
            bundle: L10n.bundle, comment: "Label for a base64-encoded path that is not valid UTF-8.") + (pathB64 ?? "")
    }
}
