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
source "${BASH_SOURCE[0]%/*}/release-tools.sh"
ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
cd "$ROOT"
[[ ( $# == 1 || $# == 2 ) && $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Usage: appcast-check.sh VERSION' >&2; exit 1; }
VERSION=$1
TOOLS="$ROOT/apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
BUILD_VERSION=$(tool bash scripts/bundle-version.sh "$VERSION")
BASELINE=${2:-}
if [[ -z $BASELINE ]]; then
    BASELINE=$(tool mktemp "${TMPDIR:-/tmp}/tesserae-feed.XXXXXX")
    trap 'tool rm -f "$BASELINE"' EXIT
    fetch_appcast "$BASELINE"
fi
tool python3 -I scripts/appcast-history.py check "$BASELINE" dist/appcast.xml "$BUILD_VERSION"
# Sparkle 2.10.0 accepts the old 96-byte format: 64 private bytes + 32 public.
# Verification uses only the public bytes. The zero prefix is inert, public
# padding, never a signing key; this avoids any keychain access for verification.
VERIFY_KEY=$(tool python3 -I - "$VERSION" "$BUILD_VERSION" <<'CHECK'
import base64, pathlib, plistlib, sys, xml.etree.ElementTree as ET
version, build = sys.argv[1:]
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
notes = pathlib.Path(f"docs/releases/{version}.md").read_text()
items = ET.parse("dist/appcast.xml").findall("./channel/item")
def item_version(item):
    enclosure = item.find("enclosure")
    return item.findtext(ns + "version") or (enclosure.get(ns + "version") if enclosure is not None else None)
if not items:
    sys.exit("Appcast has no items")
item, = [entry for entry in items if item_version(entry) == build]
enclosure = item.find("enclosure")
if enclosure is None:
    sys.exit("Appcast item has no enclosure")
def require(ok, field):
    if not ok:
        sys.exit("Appcast mismatch: " + field)
require(item_version(item) == build, "version")
require((item.findtext(ns + "shortVersionString") or enclosure.get(ns + "shortVersionString")) == version, "shortVersionString")
require(enclosure.get("url") == f"https://github.com/sdelavega/tesserae/releases/download/v{version}/Tesserae-{version}.dmg", "url")
require(enclosure.get("length") == str(pathlib.Path(f"dist/Tesserae-{version}.dmg").stat().st_size), "length")
require(item.findtext(ns + "minimumSystemVersion") == "13.0", "minimumSystemVersion")
# Sparkle embeds Markdown verbatim in CDATA with sparkle:format="markdown".
# Compare parsed text exactly so links, punctuation and code stay intact.
staged = pathlib.Path(f"dist/Tesserae-{version}.md")
if staged.exists():
    require(staged.read_text() == notes, "release notes source")
require(bool(notes.strip()) and item.findtext("description", "").strip() == notes.strip(), "release notes")
signature = enclosure.get(ns + "edSignature", "")
require(bool(signature) and not any(c.isspace() for c in signature), "signature")
public = base64.b64decode(plistlib.load(open("apple/Tesserae/Info.plist", "rb"))["SUPublicEDKey"], validate=True)
require(len(public) == 32, "SUPublicEDKey")
print(base64.b64encode(bytes(64) + public).decode())
print(signature)
CHECK
)
{ IFS= read -r PUBLIC_VERIFY_INPUT; IFS= read -r SIGNATURE; } <<< "$VERIFY_KEY"
printf '%s\n' "$PUBLIC_VERIFY_INPUT" | tool "$TOOLS/sign_update" --verify "dist/Tesserae-$VERSION.dmg" "$SIGNATURE" --ed-key-file -
printf '%s\n' "$PUBLIC_VERIFY_INPUT" | tool "$TOOLS/sign_update" --verify dist/appcast.xml --ed-key-file -
echo 'Appcast matches the DMG, release notes and committed public key'
