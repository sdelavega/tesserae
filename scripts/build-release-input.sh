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

# Runs only in the job with no signing credentials.
set -euo pipefail
cd "${BASH_SOURCE[0]%/*}/.."
version=${1:?VERSION required}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
build_version=$(scripts/bundle-version.sh "$version")
just gate
input=apple/build/release-input
rm -rf "$input" apple/build/release-input.xcarchive
mkdir -p "$input/sparkle-tools"
xcodebuild archive -project apple/Tesserae.xcodeproj -scheme Tesserae \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath apple/build/release-input.xcarchive -derivedDataPath apple/build/DerivedData \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=' "CURRENT_PROJECT_VERSION=$build_version"
ditto apple/build/release-input.xcarchive/Products/Applications/Tesserae.app "$input/Tesserae.app"
for name in generate_appcast sign_update; do
    cp "apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/$name" "$input/sparkle-tools/$name"
done
scripts/check-shipped-app.sh "$input/Tesserae.app"
commit=$(git rev-parse HEAD)
python3 -I - "$input" "$version" "$commit" <<'MANIFEST'
import json, pathlib, sys
pathlib.Path(sys.argv[1], "build.json").write_text(json.dumps(dict(version=sys.argv[2], commit=sys.argv[3])))
MANIFEST
python3 -I scripts/verify-release-input.py "$input" "$version" "$commit"
rm -f apple/build/release-input.zip
ditto -c -k --keepParent "$input" apple/build/release-input.zip
