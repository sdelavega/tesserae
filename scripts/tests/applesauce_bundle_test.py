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


import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / "apple/build/DerivedData/Build/Products/Release/Tesserae.app"
TAG = "applesauce-cli-v0.5.30"


class ApplesauceBundleTests(unittest.TestCase):
    def test_bundled_helper(self):
        helper = APP / "Contents/Helpers/applesauce"
        self.assertTrue(helper.is_file(), str(helper))
        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", helper], text=True).split()
        self.assertEqual(set(archs), {"arm64", "x86_64"})
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", helper], check=True)
        help_text = subprocess.check_output([helper, "compress", "--help"], text=True)
        self.assertIn("--verify", help_text)
        licence = (APP / "Contents/Resources/Licenses/applesauce-LICENSE.txt").read_text()
        self.assertIn("applesauce", licence)
        self.assertIn("GPL-3", licence)
        self.assertIn("https://github.com/Dr-Emann/applesauce/releases/tag/" + TAG, licence)


if __name__ == "__main__":
    unittest.main()
