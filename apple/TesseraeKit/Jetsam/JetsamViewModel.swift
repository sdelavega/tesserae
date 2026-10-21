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
import Foundation

public func reasonText(_ r: Reason) -> String {
    switch r {
    case .nonCanonicalPath: return "This path cannot be identified safely."
    case .osIntegrity: return "This item is part of macOS."
    case .systemState: return "macOS uses this item to keep the system running."
    case .appTemporaryFiles: return "Running apps use these temporary files."
    case .systemManaged: return "macOS manages this item."
    case .timeMachineBackup: return "Time Machine manages this backup."
    case .userAccountCore: return "This item is essential to your user account."
    case .volumeRootOrTopLevel: return "This item is the volume root or a top-level folder."
    case .otherVolume: return "This item is on a different volume from the scan."
    case .selfOrAncestorOfApp: return "This item contains the running Tesserae app."
    case .alreadyInTrash: return "Already in the Trash — empty it from Finder."
    case .restricted: return "macOS System Integrity Protection protects this item."
    case .immutable: return "This item is locked against changes."
    case .symlinkInPath: return "This path contains a symbolic link and cannot be trashed safely."
    case .appContainer: return "Removing an app's container resets that app, including documents of sandboxed apps."
    case .cloudOnly: return "Cloud-only: trashing removes it from iCloud on all your devices and frees no space on this Mac."
    case .otherHardLinks: return "Other hard links point to this file; its space is freed only when every link is gone."
    case .containsUnknownSize: return "This folder contains unreadable or skipped content; its size is only the known part."
    case .containsCloudOnly: return "This folder contains cloud-only items. Trashing removes them from iCloud on all your devices."
    case .containsHardLinks: return "This folder contains hard links; space is freed only when every link is gone."
    case .changedSinceReview: return "This item changed since review; review it again before moving to Trash."
    case .changedSinceScan: return "This item changed since the scan; rescan before staging it."
    case .noRecordedIdentity: return "The scan could not record this item's identity."
    }
}

public func itemWarnings(_ item: JetsamItem) -> [Reason] {
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
    public let items: [JetsamItem]
    public var overlayRevision: UInt64? { items.first?.overlayRevision }
    public var sessionID: UUID? { items.first?.sessionID }
    public private(set) var confirmedWarnings: Set<UInt32> = []
    public init(items: [JetsamItem]) { self.items = items }
    public var warningItems: [JetsamItem] { items.filter { if case .warn = $0.verdict { return true }; return false } }
    public var warningRows: [WarningRow] {
        warningItems.map { WarningRow(id: $0.id, path: String(decoding: $0.path, as: UTF8.self),
                                      texts: itemWarnings($0).map(reasonText)) }
    }
    public var deniedItems: [JetsamItem] { items.filter { if case .denied = $0.verdict { return true }; return false } }
    public var movingCount: Int {
        items.filter { item in
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
        var known: UInt64 = 0
        var unknown = 0
        for item in items {
            if case .denied = item.verdict { continue }
            if let bytes = item.recordedSize {
                let (sum, overflow) = known.addingReportingOverflow(bytes)
                known = overflow ? UInt64.max : sum
            }
            if item.recordedSize == nil || item.hasUnknownContent { unknown += 1 }
        }
        return (items.contains { $0.recorded.isDirectory } ? "Up to " : "") + displaySize(known, locale: locale) + " staged" + (unknown > 0 ? " · \(JetsamCopy.items(unknown)) of unknown size" : "")
    }
}

public func trashSummaryText(_ result: ExecutionResult, locale: Locale = .current) -> String {
    (result.outcomes.contains { item, outcome in
        if case .trashed = outcome { return item.recorded.isDirectory }; return false
    } ? "Up to " : "") + displaySize(result.reclaimableBytes, locale: locale) + " moved to Trash — empty Trash to reclaim it"
        + (result.unknownSizeTrashed > 0 ? " (plus \(JetsamCopy.items(result.unknownSizeTrashed)) of unknown size)" : "")
}

public func outcomeText(_ outcome: Outcome) -> String {
    switch outcome {
    case .trashed: return "Moved to Trash."
    case .skipped(let reason): return "Skipped: " + reasonText(reason)
    case .notConfirmed(let reason): return "Not confirmed: " + reasonText(reason)
    case .failed(let code, let message): return "Failed: \(message) (errno \(code))."
    case .identityChanged(let identity):
        let text: String
        switch identity {
        case .same: text = "Identity could not be verified."
        case .gone: text = "This item no longer exists."
        case .inodeChanged: text = "A different item now occupies this path."
        case .deviceChanged: text = "This item's volume changed."
        case .nowSymlink: text = "This item is now a symbolic link."
        case .typeChanged: text = "This item's file type changed."
        case .symlinkInPath: text = "This path now contains a symbolic link."
        case .unreadable(let code): text = "This item's identity could not be read (errno \(code))."
        }
        return "Skipped: " + text
    }
}

public func putBackText(_ result: PutBackResult) -> String {
    switch result {
    case .restored: return "Put back in its original location."
    case .trashItemGone: return "This item is no longer in the Trash."
    case .trashItemChanged: return "The item in the Trash has changed."
    case .originalOccupied: return "The original location is occupied; nothing was overwritten."
    case .parentMissing: return "The original parent folder is missing."
    case .failed(let message): return "Put Back failed: " + message
    }
}

@MainActor
public func openTrash(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
    _ = opener(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
}

public enum JetsamCopy {
    public static let putBackWhileScanning = "Put Back is unavailable while scanning — try again when the scan finishes, or use Finder"
    public static let changedSinceScan = "Files changed since this scan — rescan to stage items"

    public static let unavailable = "Can't stage items: Tesserae couldn't identify this scan's volume. Rescan to try again."
    public static let logFailure = "The Tesserae log couldn't be written; trashing still worked."
    public static func items(_ count: Int) -> String { "\(count) " + (count == 1 ? "item" : "items") }
    public static func staged(_ count: Int) -> String { "\(count) staged " + (count == 1 ? "item" : "items") }
    public static func moving(_ count: Int) -> String { items(count) + " will move" }
    public static func processed(_ done: Int, _ total: Int) -> String { "\(done) of " + items(total) + " processed" }
    public static func rescan(_ count: Int) -> String { "Sizes include \(count) trashed " + (count == 1 ? "item" : "items") + "; rescan for exact figures" }
}

@MainActor
final class JetsamContextMenu: NSObject {
    var stage: (() -> Void)?
    func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: "Add to Jetsam", action: #selector(add), keyEquivalent: "\u{8}")
        item.keyEquivalentModifierMask = .command
        item.target = self
        item.isEnabled = stage != nil
        menu.addItem(item)
        return menu
    }
    @objc private func add() { stage?() }
}
