#!/usr/bin/env python3
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


import hashlib
import json
import pathlib
import plistlib
import sys


def verify(directory, version, commit, root):
    directory = pathlib.Path(directory)
    proof = json.loads((directory / "build.json").read_text())
    if proof != {"version": version, "commit": commit}:
        raise ValueError("Release input version or commit mismatch")
    app = directory / "Tesserae.app"
    if app.is_symlink() or (directory / "sparkle-tools").is_symlink():
        raise ValueError("Release input root symlinks refused")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source = plistlib.loads((root / "apple/Tesserae/Info.plist").read_bytes())
    major, minor, patch = map(int, version.split("."))
    if (info.get("CFBundleShortVersionString") != version
            or info.get("CFBundleVersion") != str(major * 10000 + minor * 100 + patch)
            or info.get("SUPublicEDKey") != source["SUPublicEDKey"]
            or info.get("SUVerifyUpdateBeforeExtraction") is not True
            or info.get("SURequireSignedFeed") is not True):
        raise ValueError("Release input app metadata mismatch")
    # The trusted checkout pins the tools that will receive the Sparkle key;
    # a build artifact cannot replace them with arbitrary executables.
    lines = (root / "scripts/sparkle-tools.sha256").read_text().splitlines()
    if len(lines) != 2:
        raise ValueError("Missing Sparkle tool pins")
    seen = set()
    for line in lines:
        digest, name = line.split()
        if name not in {"generate_appcast", "sign_update"} or name in seen:
            raise ValueError("Invalid Sparkle tool pin")
        seen.add(name)
        path = directory / "sparkle-tools" / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("Release input Sparkle tool mismatch")


if __name__ == "__main__":
    verify(*sys.argv[1:], pathlib.Path(__file__).resolve().parents[1])
