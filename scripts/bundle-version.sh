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
next_allowed=0
if [[ ${1:-} == --next-allowed ]]; then
    next_allowed=1
    shift
fi
if [[ $# != 1 || ! $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo 'Usage: bundle-version.sh [--next-allowed] <x.y.z> (each component 0–99)' >&2
    exit 1
fi
version=$1
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
build=$((parts[0] * 10000 + parts[1] * 100 + parts[2]))
if [[ $next_allowed == 0 && $version != *666* && $build != *666* ]]; then
    printf '%d\n' "$build"
    exit 0
fi

# Carry at the existing 0–99 component limit so every candidate is valid.
while :; do
    parts[2]=$((parts[2] + 1))
    if [[ ${parts[2]} == 100 ]]; then
        parts[2]=0
        parts[1]=$((parts[1] + 1))
    fi
    if [[ ${parts[1]} == 100 ]]; then
        parts[1]=0
        parts[0]=$((parts[0] + 1))
    fi
    if [[ ${parts[0]} == 100 ]]; then
        echo 'No next allowed version within the 0–99 component range' >&2
        exit 1
    fi
    candidate="${parts[0]}.${parts[1]}.${parts[2]}"
    build=$((parts[0] * 10000 + parts[1] * 100 + parts[2]))
    [[ $candidate == *666* || $build == *666* ]] || break
done
if [[ $next_allowed == 1 ]]; then
    printf '%s\n' "$candidate"
else
    printf 'Version %s is not allowed (contains 666); next allowed: %s\n' "$version" "$candidate" >&2
    exit 1
fi
