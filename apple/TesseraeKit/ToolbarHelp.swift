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

public struct ToolbarControl: Identifiable {
    public enum ID: String, CaseIterable {
        case location, folder, rescan, reclaim, report, cancel, colour
    }
    public let id: ID
    public let title: String
    public let systemImage: String
    public let help: String
    public let accessibilityLabel: String
    public let shortcutDescription: String?
}

public enum ToolbarHelp {
    public static func controls(startupDiskName: String) -> [ToolbarControl] {
        func control(
            _ id: ToolbarControl.ID, _ title: String, _ image: String, _ help: String,
            _ shortcut: String? = nil
        ) -> ToolbarControl {
            ToolbarControl(
                id: id, title: title, systemImage: image, help: help,
                accessibilityLabel: help, shortcutDescription: shortcut)
        }
        return [
            control(
                .location,
                String(localized: "toolbar.location.title", defaultValue: "Scan another location",
                       bundle: L10n.bundle, comment: "Show the start screen to choose a new scan location."),
                NSImage(systemSymbolName: "externaldrive.badge.plus", accessibilityDescription: nil) == nil
                    ? "plus.circle" : "externaldrive.badge.plus",
                String(localized: "toolbar.location.help", defaultValue: "Scan another location (⌘⇧N)",
                       bundle: L10n.bundle, comment: "Show the start screen and its keyboard shortcut."), "⌘⇧N"),
            control(
                .folder,
                String(
                    localized: "toolbar.folder.title",
                    defaultValue: "Scan Folder…",
                    bundle: L10n.bundle,
                    comment: "L10n: Scan Folder…."
                ), "folder",
                String(
                    localized: "toolbar.folder.help",
                    defaultValue: "Scan a folder (⌘O)",
                    bundle: L10n.bundle,
                    comment: "L10n: Scan a folder (⌘O)."
                ), "⌘O"),
            control(
                .rescan,
                String(
                    localized: "toolbar.rescan.title",
                    defaultValue: "Rescan",
                    bundle: L10n.bundle,
                    comment: "L10n: Rescan."
                ), "arrow.clockwise",
                String(
                    localized: "toolbar.rescan.help",
                    defaultValue: "Rescan this location (⌘R)",
                    bundle: L10n.bundle,
                    comment: "L10n: Rescan this location (⌘R)."
                ), "⌘R"),
            control(
                .reclaim,
                String(
                    localized: "toolbar.reclaim.title",
                    defaultValue: "Reclaim Space",
                    bundle: L10n.bundle,
                    comment: "L10n: Reclaim Space."
                ), "tray",
                String(
                    localized: "toolbar.reclaim.help",
                    defaultValue: "Show or hide Reclaim Space",
                    bundle: L10n.bundle,
                    comment: "L10n: Show or hide Reclaim Space."
                )),
            control(
                .report,
                String(
                    localized: "toolbar.report.title",
                    defaultValue: "Scan report",
                    bundle: L10n.bundle,
                    comment: "L10n: Scan report."
                ), "doc.text.magnifyingglass",
                String(
                    localized: "toolbar.report.help",
                    defaultValue: "Show or hide the scan report",
                    bundle: L10n.bundle,
                    comment: "L10n: Show or hide the scan report."
                )),
            control(
                .cancel,
                String(
                    localized: "toolbar.cancel.title",
                    defaultValue: "Cancel",
                    bundle: L10n.bundle,
                    comment: "L10n: Cancel."
                ), "xmark",
                String(
                    localized: "toolbar.cancel.help",
                    defaultValue: "Cancel the scan (⌘.)",
                    bundle: L10n.bundle,
                    comment: "L10n: Cancel the scan (⌘.)."
                ), "⌘."),
            control(
                .colour,
                String(
                    localized: "toolbar.colour.title",
                    defaultValue: "Colour",
                    bundle: L10n.bundle,
                    comment: "L10n: Colour."
                ), "paintpalette",
                String(
                    localized: "toolbar.colour.help",
                    defaultValue: "Colour by folder, age or file type (⌘1–⌘3)",
                    bundle: L10n.bundle,
                    comment: "L10n: Colour by folder, age or file type (⌘1–⌘3)."
                ), "⌘1–⌘3"),
        ]
    }
}
