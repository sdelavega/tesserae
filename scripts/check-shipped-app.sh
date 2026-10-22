#!/usr/bin/env bash
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

# Inspect both Swift binaries: the launch hooks and their framework implementation.
set -euo pipefail
app=${1:-apple/build/DerivedData/Build/Products/Release/Tesserae.app}
python3 -I - "$app" <<'CHECK'
import pathlib, sys
app = pathlib.Path(sys.argv[1])
for path in (app / "Contents/MacOS/Tesserae",
             app / "Contents/Frameworks/TesseraeKit.framework/TesseraeKit"):
    if not path.is_file() or path.stat().st_size == 0:
        sys.exit("Missing shipping executable: " + str(path))
    data = path.read_bytes()
    for marker in (b"TESSERAE_ACCESS_REPORT", b"TESSERAE_FRAME_GATE", b"TESSERAE_FRAME_TIMING"):
        if marker in data:
            sys.exit("Shipping executable contains test hook: " + marker.decode())
print("ok: shipped app and framework have no test hooks")
CHECK
