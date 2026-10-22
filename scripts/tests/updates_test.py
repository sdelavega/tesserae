# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.


import base64
import pathlib
import plistlib
import re
import unittest
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parents[2]
APPLE = ROOT / "apple"
APP = APPLE / "build/DerivedData/Build/Products/Release/Tesserae.app"


class UpdatesTests(unittest.TestCase):
    def test_only_sparkle_touches_the_network(self):
        sources = [p for p in APPLE.rglob("*")
                   if p.relative_to(APPLE).parts[0] != "build" and not {"SourcePackages", "DerivedData"}.intersection(p.relative_to(APPLE).parts)
                   and p.suffix in {".swift", ".h", ".c", ".m", ".mm", ".metal"} and p.is_file()]
        self.assertGreater(len(sources), 50, "precondition: scan actual app and framework sources")
        self.assertIn(APPLE / "Tesserae/TesseraeApp.swift", sources)
        self.assertIn(APPLE / "TesseraeKit/Reconciliation/CommandRunner.swift", sources)
        pattern = r"\bURLSession\b|\bNSURLConnection\b|\bimport\s+Network\b|\bCFSocket\w*\b|\bsocket\s*\("
        violations = [str(p.relative_to(ROOT)) for p in sources if re.search(pattern, p.read_text())]
        self.assertEqual(violations, [], "Sparkle must remain the only network client")

    def test_update_metadata(self):
        for path in [APPLE / "Tesserae/Info.plist", APP / "Contents/Info.plist"]:
            self.assertTrue(path.is_file(), "precondition: source and built bundle exist")
            info = plistlib.loads(path.read_bytes())
            self.assertIn("SUPublicEDKey", info)
            self.assertEqual(len(base64.b64decode(info["SUPublicEDKey"], validate=True)), 32)
            self.assertEqual(info["SUPublicEDKey"], "JmdB15uy9xCZWWUsHHSeWzC7p7BehSvODXvK1EYi1Ig=")
            self.assertEqual(urlparse(info["SUFeedURL"]).scheme, "https")
            self.assertEqual(info["SUFeedURL"], "https://sdelavega.github.io/tesserae/appcast.xml")
            self.assertIs(info.get("SUVerifyUpdateBeforeExtraction"), True)
            self.assertIs(info.get("SURequireSignedFeed"), True)
            self.assertIs(info["SUEnableAutomaticChecks"], True)
            self.assertEqual(info["SUScheduledCheckInterval"], 86400)
            self.assertIs(info["SUEnableSystemProfiling"], False)

    def test_sparkle_license_ships(self):
        resolved = APPLE / "build/DerivedData/SourcePackages/checkouts/Sparkle/LICENSE"
        self.assertTrue(resolved.is_file(), "precondition: resolved Sparkle package")
        original = resolved.read_bytes()
        self.assertIn(b"Permission is hereby granted", original)
        for path in [APPLE / "Tesserae/Licenses/Sparkle-LICENSE.txt",
                     APP / "Contents/Resources/Licenses/Sparkle-LICENSE.txt"]:
            self.assertEqual(path.read_bytes(), original)

    def test_update_controls_are_wired(self):
        app = (APPLE / "Tesserae/TesseraeApp.swift").read_text()
        self.assertIn('@StateObject private var updates: Updates', app)
        self.assertRegex(app, r'Button\(String\(\s*localized: "tesseraeApp.check.for.updates",\s*'
                         r'defaultValue: "Check for Updates…",\s*comment: "[^"\n]+"\s*\)\)\s*'
                         r'\{ updates.checkForUpdates\(\) \}\s*\.disabled\(!updates.canCheckForUpdates\)')
        self.assertRegex(app, r'Settings\s*\{\s*UpdateSettingsView\(updates: updates\)')
        model = (APPLE / "Tesserae/Updates.swift").read_text()
        self.assertRegex(model, r'Toggle\(String\(\s*localized: "updates.check.for.updates.automatically",\s*'
                         r'defaultValue: "Check for updates automatically",\s*comment: "[^"\n]+"\s*\),\s*'
                         r'isOn: \$updates.automaticallyChecksForUpdates\)')
        content = (APPLE / "Tesserae/ContentView.swift").read_text()
        self.assertIn('Text(AppChrome.updateDisclosure)', content)


if __name__ == "__main__":
    unittest.main()
