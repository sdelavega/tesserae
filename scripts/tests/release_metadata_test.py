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


import json
import shutil
import tempfile
import pathlib
import plistlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / "apple/Tesserae.xcodeproj/project.pbxproj"
APP = ROOT / "apple/build/DerivedData/Build/Products/Release/Tesserae.app"


class ReleaseMetadataTests(unittest.TestCase):
    def version(self, *args):
        return subprocess.run([str(ROOT / "scripts/bundle-version.sh"), *args],
                              capture_output=True, text=True)

    def test_version_derivation(self):
        for value, expected in [("0.1.0", "100"), ("1.2.3", "10203"),
                                ("99.99.99", "999999"), ("00.08.09", "809"),
                                ("0.0.0", "0")]:
            result = self.version(value)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected + "\n")

    def test_invalid_versions(self):
        for args in [[], ["1.2.3", "extra"], ["1.2"], ["1.2.3.4"], ["-1.2.3"],
                     ["1.100.0"], ["100.0.0"], ["0.0.100"], ["1.2.x"],
                     [" 1.2.3"], ["1.2.3\n"], ["1..3"], ["1.2.+3"]]:
            result = self.version(*args)
            self.assertNotEqual(result.returncode, 0, repr(args))
            self.assertEqual(result.stdout, "")

    def test_committed_versions(self):
        source = PROJECT.read_text()
        versions = re.findall(r"MARKETING_VERSION = ([^;]+);", source)
        self.assertTrue(versions)
        self.assertEqual(len(set(versions)), 1)
        expected = self.version(versions[0]).stdout.strip()
        self.assertTrue(expected)
        app_versions = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", source)
        self.assertTrue(app_versions)
        self.assertEqual(set(app_versions), {expected})
        self.assertIn("CURRENT_PROJECT_VERSION = " + expected, (ROOT / "apple/Release.xcconfig").read_text())

    def test_release_signing(self):
        # A copied project ensures tests never read or overwrite a real local config.
        with tempfile.TemporaryDirectory(dir=ROOT / "apple/build") as temporary:
            fixture = pathlib.Path(temporary)
            shutil.copytree(ROOT / "apple/Tesserae.xcodeproj", fixture / "Tesserae.xcodeproj",
                            ignore=shutil.ignore_patterns("xcuserdata", "project.xcworkspace"))
            shutil.copy(ROOT / "apple/Release.xcconfig", fixture)

            def settings(configuration):
                result = subprocess.run(["xcodebuild", "-showBuildSettings", "-json", "-project",
                                         str(fixture / "Tesserae.xcodeproj"), "-alltargets",
                                         "-configuration", configuration], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                return {target["target"]: target["buildSettings"] for target in json.loads(result.stdout)}

            version = re.search(r"MARKETING_VERSION = ([^;]+);", PROJECT.read_text())[1]
            expected_build = self.version(version).stdout.strip()
            self.assertTrue(expected_build)
            default = settings("Release")
            for target in ["Tesserae", "TesseraeKit"]:
                self.assertIn(target, list(default))
                self.assertEqual(default[target]["CODE_SIGN_IDENTITY"], "-")
                self.assertEqual(default[target]["CODE_SIGN_STYLE"], "Manual")
                self.assertEqual(default[target]["ENABLE_HARDENED_RUNTIME"], "YES")
                self.assertIn("--timestamp", default[target]["OTHER_CODE_SIGN_FLAGS"].split())
                self.assertEqual(default[target]["CURRENT_PROJECT_VERSION"],
                                 expected_build)
            debug = settings("Debug")
            (fixture / "Release.local.xcconfig").write_text(
                "DEVELOPMENT_TEAM = TESTTEAM\n"
                "CODE_SIGN_IDENTITY = Developer ID Application: PLACEHOLDER (TESTTEAM)\n"
                "NOTARY_PROFILE = TEST_PROFILE\n")
            local = settings("Release")
            for target in ["Tesserae", "TesseraeKit"]:
                self.assertEqual(local[target]["DEVELOPMENT_TEAM"], "TESTTEAM")
                self.assertEqual(local[target]["CODE_SIGN_IDENTITY"],
                                 "Developer ID Application: PLACEHOLDER (TESTTEAM)")
                self.assertEqual(local[target]["NOTARY_PROFILE"], "TEST_PROFILE")
            debug_local = settings("Debug")
            for target in ["Tesserae", "TesseraeKit", "TesseraeKitTests"]:
                for key in ["CODE_SIGN_IDENTITY", "CODE_SIGN_STYLE", "DEVELOPMENT_TEAM"]:
                    self.assertEqual(debug_local[target].get(key), debug[target].get(key))

    def test_support_is_menu_only(self):
        source = (ROOT / "apple/Tesserae/TesseraeApp.swift").read_text()
        def localized_button(key, title):
            return (r'Button\(String\(\s*localized:\s*"' + re.escape(key)
                    + r'",\s*defaultValue:\s*"' + re.escape(title)
                    + r'",\s*comment:\s*"[^"\n]+"\s*\)\)\s*')
        self.assertRegex(source, r'CommandGroup\(after: \.help\)\s*\{\s*'
                         + localized_button("tesseraeApp.support.tesserae", "Support Tesserae…")
                         + r'\{\s*AppChrome.openSupport\(\)')
        self.assertRegex(source, r'CommandGroup\(replacing: \.appInfo\)\s*\{\s*'
                         + localized_button("tesseraeApp.about.tesserae", "About Tesserae")
                         + r'\{\s*AppChrome.showAbout\(\)')
        self.assertEqual(source.count("AppChrome.openSupport()"), 1)
        self.assertEqual(source.count("AppChrome.showAbout()"), 1)
        launch = source.split("var body: some Scene")[0]
        self.assertNotRegex(launch, r"AppChrome|[Ss]ponsor|[Dd]onat|[Ss]upport|[Aa]boutPanel")
        swift_files = list((ROOT / "apple/Tesserae").glob("*.swift"))
        self.assertTrue(swift_files)
        for path in swift_files:
            if path.name not in ("TesseraeApp.swift", "AppChrome.swift"):
                self.assertNotRegex(path.read_text(), r"github.com/sponsors|Support Tesserae|[Dd]onat")
        chrome = (ROOT / "apple/Tesserae/AppChrome.swift").read_text()
        self.assertIn('NSWorkspace.shared.open(supportURL)', chrome)
        self.assertIn('https://github.com/sponsors/sdelavega', chrome)
        self.assertIn('github: sdelavega', (ROOT / ".github/FUNDING.yml").read_text())

    def test_built_bundle(self):
        self.assertTrue(APP.is_dir(), "Build Release app first")
        with (APP / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        version = re.search(r"MARKETING_VERSION = ([^;]+);", PROJECT.read_text())[1]
        self.assertEqual(info["CFBundleShortVersionString"], version)
        self.assertEqual(info["CFBundleVersion"], self.version(version).stdout.strip())
        for key in ["CFBundleIdentifier", "NSHumanReadableCopyright", "NSDesktopFolderUsageDescription",
                    "NSDocumentsFolderUsageDescription", "NSDownloadsFolderUsageDescription",
                    "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription"]:
            self.assertTrue(info[key], key)
        self.assertEqual((APP / "Contents/Resources/Licenses/GPL-3.txt").read_bytes(),
                         (ROOT / "LICENSE").read_bytes())


if __name__ == "__main__":
    unittest.main()
