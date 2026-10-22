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
HDIUTIL=${HDIUTIL:-hdiutil}
CODESIGN=${CODESIGN:-codesign}
MKTEMP=${MKTEMP:-mktemp}
RM=${RM:-rm}
DITTO=${DITTO:-ditto}
LN=${LN:-ln}
[[ $# == 4 ]] || { echo 'Usage: make-dmg.sh VERSION APP OUTPUT IDENTITY' >&2; exit 1; }
VERSION=$1
APP=$2
OUTPUT=$3
CODE_SIGN_IDENTITY=$4
STAGE=$("$MKTEMP" -d "${TMPDIR:-/tmp}/tesserae-dmg.XXXXXX")
trap '"$RM" -rf "$STAGE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$DITTO" "$APP" "$STAGE/Tesserae.app"
"$LN" -s /Applications "$STAGE/Applications"
# create -srcfolder needs no attachment; there is no mounted volume to leak.
"$HDIUTIL" create -srcfolder "$STAGE" -volname "Tesserae $VERSION" -format UDZO "$OUTPUT"
"$CODESIGN" --timestamp --sign "$CODE_SIGN_IDENTITY" "$OUTPUT"
