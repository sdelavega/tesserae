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

# Build the static library the app links: apple/build/libtesserae.a, universal
# (arm64 + x86_64).
#
# Usage: scripts/build-ffi.sh
#
# Xcode never runs cargo (spec §14): this script, through `just ffi`, builds
# the library out of band, and TesseraeKit's Run Script phase
# (scripts/verify-ffi-fresh.sh) only checks that it is newer than its sources.
#
# Each architecture is built with exactly
#     cargo build -p tesserae-ffi --release --target <triple>
# Building test targets (--all-targets, --tests, `cargo test --release`) would
# unify tesserae-core's fault-injection hooks into the library; see
# scripts/check-shipped-lib.sh, which proves the marker search below can see
# the hooks when they are there. MACOSX_DEPLOYMENT_TARGET matches the Xcode
# project's, so the objects carry the same minimum OS as the app.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

cd "$(dirname "$0")/.."

export MACOSX_DEPLOYMENT_TARGET=13.0
targets=(aarch64-apple-darwin x86_64-apple-darwin)
marker='TESSERAE_TEST_HOOKS_PRESENT'

inputs=()
for target in "${targets[@]}"; do
    cargo build -p tesserae-ffi --release --locked --target "$target"
    inputs+=("target/$target/release/libtesserae_ffi.a")
done

# Write beside the destination and rename, so the library's mtime is always
# this run's (verify-ffi-fresh.sh compares against it) and an interrupted run
# never leaves a half-written archive where Xcode looks.
mkdir -p apple/build
out=apple/build/libtesserae.a
lipo -create -output "$out.tmp" "${inputs[@]}"
mv -f "$out.tmp" "$out"

archs="$(lipo -archs "$out" | tr ' ' '\n' | sort | tr '\n' ' ')"
if [ "$archs" != "arm64 x86_64 " ]; then
    echo "error: $out should hold exactly arm64 and x86_64: $(lipo -info "$out")" >&2
    exit 1
fi
if [ "$(grep -ac "$marker" "$out" || true)" != 0 ]; then
    echo "error: $out contains the test-hooks marker" >&2
    exit 1
fi
lipo -info "$out"
