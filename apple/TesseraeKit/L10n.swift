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

import Foundation

private final class LocalizationBundle {}

public enum L10n {
    public static let bundle = Bundle(for: LocalizationBundle.self)

    /// Plural rules follow the resolved translation; number formatting keeps the user's region.
    public static func pluralLocale(_ locale: Locale) -> Locale {
        var components = Locale.Components(identifier: bundle.preferredLocalizations.first ?? "en")
        components.region = locale.region
        return Locale(components: components)
    }
}
