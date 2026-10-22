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


class TestHookBuildTests(unittest.TestCase):
    def test_shipping_check_has_real_positive_control(self):
        shipping = ROOT / "apple/build/DerivedData/Build/Products/Release/Tesserae.app"
        hooks = ROOT / "apple/build/DerivedData-testhooks/Build/Products/Release/Tesserae.app"
        for app in (shipping, hooks):
            self.assertTrue((app / "Contents/MacOS/Tesserae").is_file(), "precondition: actual Release builds")
            result = subprocess.run(["bash", "scripts/check-shipped-app.sh", str(app)], cwd=ROOT,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, app == shipping, result.stdout + result.stderr)
        data = (hooks / "Contents/Frameworks/TesseraeKit.framework/TesseraeKit").read_bytes()
        for marker in (b"TESSERAE_ACCESS_REPORT", b"TESSERAE_FRAME_GATE", b"TESSERAE_FRAME_TIMING"):
            self.assertIn(marker, data, "precondition: control contains each hook")


if __name__ == "__main__":
    unittest.main()
