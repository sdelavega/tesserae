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

@MainActor
enum AppChrome {
    static let updateDisclosure = String(
        localized: "appChrome.tesserae.checks.for.updates.once.a.day.the",
        defaultValue: "Tesserae checks for updates once a day; the request includes the app and macOS version. You can turn this off.",
        comment: "AppChrome: Tesserae checks for updates once a day; the request includes the app and macOS version. You can turn this off."
    )
    static let supportURL = URL(string: "https://github.com/sponsors/sdelavega")!

    static func openSupport() {
        NSWorkspace.shared.open(supportURL)
    }

    static func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(bundle: .main)])
    }

    static func credits(bundle: Bundle) -> NSAttributedString {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let credits = NSMutableAttributedString(string: String(
            localized: "appChrome.version.n.n",
            defaultValue: "Version \(version) (\(build))\n\n",
            comment: "AppChrome: Version {version} ({build})."
        )
            + String(
                localized: "appChrome.tesserae.is.free.software.under.the.gnu.general",
                defaultValue: "Tesserae is free software under the GNU General Public License, version 3 or later (GPL-3).\n",
                comment: "AppChrome: Tesserae is free software under the GNU General Public License, version 3 or later (GPL-3)."
            )
            + String(
                localized: "appChrome.this.program.comes.with.absolutely.no.warranty.n",
                defaultValue: "This program comes with ABSOLUTELY NO WARRANTY.\n\n",
                comment: "AppChrome: This program comes with ABSOLUTELY NO WARRANTY."
            ) + updateDisclosure + String(
                localized: "appChrome.n.nlicenses.n",
                defaultValue: "\n\nLicenses\n",
                comment: "AppChrome: Licenses."
            ))
        if let directory = bundle.resourceURL?.appendingPathComponent("Licenses", isDirectory: true),
           let files = try? FileManager.default.contentsOfDirectory(
               at: directory, includingPropertiesForKeys: nil
           ) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                credits.append(NSAttributedString(string: file.lastPathComponent, attributes: [.link: file]))
                credits.append(NSAttributedString(string: "\n"))
            }
        }
        return credits
    }
}

enum L10n {
    static let bundle = Bundle.main

    /// Plural rules follow the resolved translation; number formatting keeps the user's region.
    static func pluralLocale(_ locale: Locale) -> Locale {
        var components = Locale.Components(identifier: bundle.preferredLocalizations.first ?? "en")
        components.region = locale.region
        return Locale(components: components)
    }
}
