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

# Build the separately locked, pinned CLI for the app's Copy Files phase.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$(dirname "$0")/.."
export RUSTUP_TOOLCHAIN=stable
export MACOSX_DEPLOYMENT_TARGET=13.0

inputs=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build --manifest-path tools/applesauce/Cargo.toml --release --locked --target "$target"
    inputs+=("tools/applesauce/target/$target/release/applesauce")
done
mkdir -p apple/build
lipo -create -output apple/build/applesauce.tmp "${inputs[@]}"
codesign --force --sign - --options runtime apple/build/applesauce.tmp
codesign --verify --strict apple/build/applesauce.tmp
mv -f apple/build/applesauce.tmp apple/build/applesauce
