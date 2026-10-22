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

import XCTest
import TesseraeFFI

@testable import TesseraeKit

final class ToolbarHelpTests: XCTestCase {
    func test_every_toolbar_control_has_help_and_label() {
        let controls = ToolbarHelp.controls(startupDiskName: "Macintosh HD")
        XCTAssertEqual(
            controls.map(\.id), [.location, .folder, .rescan, .reclaim, .report, .cancel, .colour])
        XCTAssertEqual(Set(controls.map(\.id)).count, 7)
        XCTAssertEqual(controls.first?.title, "Scan another location")
        XCTAssertEqual(controls.first?.shortcutDescription, "⌘⇧N")
        XCTAssertTrue(["externaldrive.badge.plus", "plus.circle"].contains(controls.first?.systemImage ?? ""))
        XCTAssertEqual(controls.first?.help, "Scan another location (⌘⇧N)")
        XCTAssertEqual(ToolbarHelp.controls(startupDiskName: "Disque").first?.help, "Scan another location (⌘⇧N)")
        let expected = [
            "Scan another location (⌘⇧N)", "Scan a folder (⌘O)", "Rescan this location (⌘R)",
            "Show or hide Reclaim Space", "Show or hide the scan report", "Cancel the scan (⌘.)",
            "Colour by folder, age or file type (⌘1–⌘3)",
        ]
        for (control, help) in zip(controls, expected) {
            XCTAssertFalse(control.title.isEmpty)
            XCTAssertFalse(control.systemImage.isEmpty)
            XCTAssertEqual(control.help, help)
            XCTAssertEqual(control.accessibilityLabel, help)
        }
        XCTAssertEqual(controls.first { $0.id == .cancel }?.shortcutDescription, "⌘.")
    }
    func test_catalog_bundle_and_plural_counts() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(
            TesseraeKit.L10n.bundle.localizedString(forKey: "toolbar.rescan.help", value: nil, table: nil),
            "Rescan this location (⌘R)")
        for count in [0, 1, 2, 12_345] {
            let number = count.formatted(.number.locale(en))
            let noun = count == 1 ? "item" : "items"
            XCTAssertEqual(ReclaimCopy.items(count, locale: en), "\(number) \(noun)")
            XCTAssertEqual(ReclaimCopy.staged(count, locale: en), "\(number) staged \(noun)")
            XCTAssertEqual(ReclaimCopy.processed(0, count, locale: en), "0 of \(number) \(noun) processed")
            XCTAssertEqual(
                InspectorInfo.aggregateParts(count: UInt32(count), bytes: 0, locale: en).words,
                "\(number) smaller \(noun)")
        }
    }

    func test_plural_rules_follow_resolved_language() {
        XCTAssertEqual(TesseraeKit.L10n.bundle.preferredLocalizations.first, "en")
        for (identifier, count, expected) in [
            ("ru_RU", 21, "21 items will move"),
            ("fr_FR", 0, "0 items will move"),
            ("pl_PL", 2, "2 items will move"),
            ("en_US", 1, "1 item will move"),
            ("en_US", 2, "2 items will move"),
        ] {
            let locale = Locale(identifier: identifier)
            let resolved = TesseraeKit.L10n.pluralLocale(locale)
            XCTAssertEqual(resolved.language.languageCode?.identifier, "en")
            XCTAssertEqual(resolved.region, locale.region)
            XCTAssertEqual(ReclaimCopy.moving(count, locale: locale), expected)
            if identifier == "ru_RU" {
                XCTAssertEqual(InspectorInfo.unreadableWords(count: UInt32(count), locale: locale),
                               "21 unreadable folders")
            }
        }
        let russian = Locale(identifier: "ru_RU")
        XCTAssertEqual(ReclaimCopy.moving(1_234, locale: russian), "1\u{00a0}234 items will move")
        var stats = TessScanStats()
        stats.unreadable_count = 21
        stats.errors = 21
        XCTAssertEqual(ScanBanner.text(for: stats, stalledAt: nil, locale: russian),
                       "Partial result — 21 errors; 21 unreadable folders")
    }

}
