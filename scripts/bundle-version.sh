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


set -euo pipefail
if [[ $# != 1 || ! $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo 'Usage: bundle-version.sh <x.y.z> (each component 0–99)' >&2
    exit 1
fi
parts=()
for part in "${BASH_REMATCH[@]:1}"; do
    # Strip leading zeroes before arithmetic, including arbitrarily long input.
    while [[ ${#part} -gt 1 && $part == 0* ]]; do part=${part#0}; done
    if [[ ${#part} -gt 2 ]]; then
        echo 'Version components must each be less than 100' >&2
        exit 1
    fi
    parts+=("$((10#$part))")
done
printf '%d\n' "$((parts[0] * 10000 + parts[1] * 100 + parts[2]))"
