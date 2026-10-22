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
import pathlib
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "apple/Tesserae/Assets.xcassets"
SIZES = {16, 32, 64, 128, 256, 512, 1024}


class IconTests(unittest.TestCase):
    def test_sizes_and_slots(self):
        icon = CATALOG / "AppIcon.appiconset"
        contents = json.loads((icon / "Contents.json").read_text())
        slots = contents["images"]
        self.assertEqual(len(slots), 10)
        self.assertEqual({(s["size"], s["scale"], s["idiom"]) for s in slots},
                         {(f"{s}x{s}", f"{scale}x", "mac")
                          for s in [16, 32, 128, 256, 512] for scale in [1, 2]})
        self.assertEqual({p.name for p in icon.glob("*.png")},
                         {f"icon-{s}.png" for s in SIZES})
        for slot in slots:
            size = int(slot["size"].split("x")[0]) * int(slot["scale"][0])
            data = (icon / slot["filename"]).read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (size, size))

    def test_regeneration_is_byte_identical(self):
        committed = {p.relative_to(CATALOG): p.read_bytes()
                     for p in CATALOG.rglob("*") if p.is_file()}
        self.assertEqual(len(committed), 9, "seven PNGs and two manifests required")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "Assets.xcassets"
            subprocess.run(["xcrun", "swift", "scripts/make-icon.swift", str(output)],
                           cwd=ROOT, check=True, capture_output=True)
            regenerated = {p.relative_to(output): p.read_bytes()
                           for p in output.rglob("*") if p.is_file()}
            self.assertEqual(committed.keys(), regenerated.keys())
            for path in committed:
                self.assertEqual(committed[path], regenerated[path], str(path))

    def test_full_bleed_layout_and_pixels(self):
        # Exercise the generator's geometry and actual raster, without app imports.
        source = (ROOT / "scripts/make-icon.swift").read_text().split(
            "precondition(CommandLine.arguments.count")[0]
        harness = r"""
for size in sizes {
    let n = CGFloat(size), margin = (n * shapeMargin).rounded()
    let shape = CGRect(x: margin, y: margin, width: n - 2 * margin, height: n - 2 * margin)
    let (rects, indices) = mosaicLayout(in: shape, small: size <= 32)
    precondition(rects.count == (size <= 32 ? 5 : 9))
    precondition(indices.filter { $0 == 5 }.count == 1)
    for point in [CGPoint(x: shape.minX, y: shape.minY),
                  CGPoint(x: shape.maxX, y: shape.minY),
                  CGPoint(x: shape.minX, y: shape.maxY),
                  CGPoint(x: shape.maxX, y: shape.maxY)] {
        let corners = rects.filter { $0.insetBy(dx: -0.01, dy: -0.01).contains(point) }
        precondition(corners.count == 1)
        precondition(corners[0].width >= shape.width * 0.22 && corners[0].height >= shape.width * 0.22)
    }
    let amber = rects[indices.firstIndex(of: 5)!]
    precondition(amber.midX > shape.midX && amber.midY > shape.midY)
    precondition(amber.minX > shape.minX)
    if size > 32 { precondition(amber.maxX < shape.maxX) }
    precondition(amber.minY > shape.minY && amber.maxY < shape.maxY)
    precondition(abs(rects.reduce(0) { $0 + $1.width * $1.height } - shape.width * shape.height) < 0.01)
    let image = render(size)
    let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let i = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + i, count: 4))
    }
    // Edge samples used to be the white frame. All now belong to blue tiles.
    if size >= 64 {
    for (x, y) in [(Int(margin), Int(margin + shape.height * 0.23)),
                   (size - Int(margin) - 1, Int(margin + shape.height * 0.23)),
                   (size / 2, Int(margin)), (size / 2, size - Int(margin) - 1)] {
        let p = pixel(x, y)
        precondition(p[3] == 255 && Int(p[2]) > Int(p[0]) + 20)
    }
    }
    precondition(pixel(0, 0)[3] == 0)
    let sharedEdge = pixel(Int((shape.minX + shape.width * 0.40).rounded()),
                           Int(shape.minY + shape.height * 0.25))
    precondition(Array(sharedEdge.prefix(3)) == [244, 247, 251] && sharedEdge[3] == 255)
    if size == 1024 {
        let left = Int(shape.minX + shape.width * 0.20)
        // A single tile's interior has a restrained, visibly measurable gradient.
        let a = pixel(left, Int(shape.minY + shape.height * 0.10))
        let b = pixel(left, Int(shape.minY + shape.height * 0.40))
        precondition(a != b)
        precondition(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 16 })
        let grout = pixel(Int(shape.minX + shape.width * 0.40), Int(shape.midY))
        precondition(Array(grout.prefix(3)) == [244, 247, 251] && grout[3] == 255)
    }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "check.swift"
            script.write_text(source + harness)
            result = subprocess.run(["xcrun", "swift", str(script)], cwd=ROOT,
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_built_bundle_has_icon(self):
        app = ROOT / "apple/build/DerivedData/Build/Products/Release/Tesserae.app/Contents"
        with (app / "Info.plist").open("rb") as file:
            info = plistlib.load(file)
        self.assertEqual(info.get("CFBundleIconName"), "AppIcon")
        self.assertGreater((app / "Resources/Assets.car").stat().st_size, 0)
        self.assertTrue((app / "Resources" / (info["CFBundleIconFile"] + ".icns")).is_file())


if __name__ == "__main__":
    unittest.main()
