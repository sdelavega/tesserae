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

@main
struct AppChromeTests {
    @MainActor
    static func main() throws {
        try test_menu_titles()
        let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = try require(Bundle(url: appURL), "App bundle missing")
        let en = Locale(identifier: "en_US")
        let englishURL = try require(bundle.url(forResource: "en", withExtension: "lproj"), "App English catalog missing")
        let english = try require(Bundle(url: englishURL), "App English bundle missing")
        precondition(english.localizedString(forKey: "confirmTrashSheet.cancel", value: nil, table: nil) == "Cancel")
        for (folders, files, expected) in [(UInt64(1), UInt64(2), "1 folder · 2 files"),
                                           (UInt64(2), UInt64(1), "2 folders · 1 file"),
                                           (UInt64(0), UInt64(0), "0 folders · 0 files")] {
            let text = String(localized: "scan.progress.counts", defaultValue: "\(folders) folders · \(files) files",
                              bundle: bundle, locale: en, comment: "Independent progress counts")
            precondition(text == expected, "Each progress count must select its own plural")
        }
        precondition(bundle.preferredLocalizations.first == "en", "Probe must load the shipped English app catalog")
        for (identifier, count, expected) in [("ru_RU", UInt64(21), "21 folders · 21 files"),
                                              ("fr_FR", UInt64(0), "0 folders · 0 files"),
                                              ("pl_PL", UInt64(2), "2 folders · 2 files"),
                                              ("en_US", UInt64(1), "1 folder · 1 file"),
                                              ("en_US", UInt64(2), "2 folders · 2 files")] {
            let locale = Locale(identifier: identifier)
            let resolved = L10n.pluralLocale(locale)
            precondition(resolved.language.languageCode?.identifier == "en")
            precondition(resolved.region == locale.region)
            let text = String(localized: "scan.progress.counts", defaultValue: "\(count) folders · \(count) files",
                              bundle: bundle, locale: L10n.pluralLocale(locale), comment: "Independent progress counts")
            precondition(text == expected, "App plural rules must follow resolved English for \(identifier): \(text)")
        }
        let grouped: UInt64 = 1_234
        let groupedText = String(localized: "scan.progress.counts", defaultValue: "\(grouped) folders · \(grouped) files",
                                 bundle: bundle, locale: L10n.pluralLocale(Locale(identifier: "ru_RU")),
                                 comment: "Independent progress counts")
        precondition(groupedText == "1\u{00a0}234 folders · 1\u{00a0}234 files", "Keep the user's region for grouping")
        let expectedDisclosure = "Tesserae checks for updates once a day; the request includes the app and macOS version. You can turn this off."
        precondition(AppChrome.updateDisclosure == expectedDisclosure)
        let credits = AppChrome.credits(bundle: bundle)
        precondition(credits.string.contains(expectedDisclosure))
        let version = try require(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                  "Marketing version missing")
        let build = try require(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                "Build number missing")
        precondition(!version.isEmpty && !build.isEmpty)
        precondition(credits.string.contains("Version \(version) (\(build))"))
        precondition(credits.string.contains("GNU General Public License, version 3 or later (GPL-3)"))
        precondition(credits.string.contains("NO WARRANTY"))
        precondition(credits.string.contains("Licenses\n"))
        let directory = try require(bundle.resourceURL, "Resources missing")
            .appendingPathComponent("Licenses", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        precondition(!files.isEmpty && files.contains { $0.lastPathComponent == "GPL-3.txt" })
        precondition(files.contains { $0.lastPathComponent == "Sparkle-LICENSE.txt" })
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let link = value as? URL { links.append(link) }
        }
        precondition(Set(links) == Set(files), "Every bundled licence must have a file link")
        precondition(links.allSatisfy { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) })
        precondition(AppChrome.supportURL.absoluteString == "https://github.com/sponsors/sdelavega")
        print("About credits: version, GPL-3, exact update disclosure and every bundled licence link including Sparkle passed")
    }

    static func test_menu_titles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("apple")
        var values: [String] = []
        func collect(_ object: Any) {
            if let dictionary = object as? [String: Any] {
                if let value = dictionary["value"] as? String { values.append(value) }
                for value in dictionary.values { collect(value) }
            } else if let array = object as? [Any] {
                for value in array { collect(value) }
            }
        }
        for folder in ["Tesserae", "TesseraeKit"] {
            let file = root.appendingPathComponent(folder).appendingPathComponent("Localizable.xcstrings")
            let catalog = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
                                      "Catalog missing")
            let entries = try require(catalog["strings"] as? [String: [String: Any]], "Catalog entries missing")
            precondition(!entries.isEmpty, "Naming check must inspect both production catalogs")
            let previous = values.count
            for entry in entries.values {
                let localizations = try require(entry["localizations"] as? [String: Any], "Localizations missing")
                collect(try require(localizations["en"], "English catalog values missing"))
            }
            precondition(values.count > previous, "Every catalog must contain English values")
        }
        for name in ["\u{4a}etsam", "\u{4a}ettison"] {
            precondition(values.allSatisfy { !$0.localizedCaseInsensitiveContains(name) },
                         "English catalogs must use current feature naming")
        }
        precondition(values.contains("Add to Reclaim Space"), "Staging command must be present")
        print("English catalogs: both bundles use Reclaim Space")
    }

    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }
}
