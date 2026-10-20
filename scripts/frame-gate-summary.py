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

"""Recompute the frame-gate summary from a capture written by PhaseGateRunner.

Usage: scripts/frame-gate-summary.py CAPTURE.json [--by-label]

Prints, per sample kind, the count, maximum, p99 (nearest rank,
ceil(0.99 * n)) and median in milliseconds, and how many presentation
intervals spanned more than 1.5 refresh periods. --by-label adds the same
figures per transition label ("1 in Users", ...). Standard library only.
"""

import json
import math
import statistics
import sys


def p99(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.99) - 1)]


def table(samples, title):
    kinds = {}
    for s in samples:
        kinds.setdefault(s["kind"], []).append(s["seconds"] * 1000)
    print(title)
    print(f"  {'kind':<18} {'count':>6} {'max ms':>9} {'p99 ms':>9} {'median ms':>10}")
    for kind in sorted(kinds):
        v = kinds[kind]
        print(f"  {kind:<18} {len(v):>6} {max(v):>9.3f} {p99(v):>9.3f} {statistics.median(v):>10.3f}")


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 2
    with open(argv[1], encoding="utf-8") as f:
        capture = json.load(f)
    samples = capture["samples"]
    for key in ("root", "build", "nodes", "incomplete", "unreadable", "refreshHz", "refreshSource", "viewport"):
        if key in capture:
            print(f"{key}: {capture[key]}")
    print("directories: " + ", ".join(capture.get("directories", [])))
    table(samples, "all transitions")
    hz = capture.get("refreshHz") or 0
    if hz > 0:
        period = 1000 / hz
        gaps = [s for s in samples if s["kind"] == "present-cadence" and s["seconds"] * 1000 > 1.5 * period]
        total = sum(1 for s in samples if s["kind"] == "present-cadence")
        print(f"presentation intervals over 1.5 refresh periods ({1.5 * period:.3f} ms): {len(gaps)}/{total}")
        for s in gaps:
            print(f"  {s['label']}: {s['seconds'] * 1000:.3f} ms")
    if "--by-label" in argv[2:]:
        labels = []
        for s in samples:
            if s["label"] not in labels:
                labels.append(s["label"])
        for label in labels:
            table([s for s in samples if s["label"] == label], f"label {label!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
