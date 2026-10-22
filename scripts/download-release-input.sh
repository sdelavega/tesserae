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

# No action code or tool installation executes on the signing runner.
set -euo pipefail
source "${BASH_SOURCE[0]%/*}/release-tools.sh"
id=${1:?artifact id required} digest=${2:?artifact digest required}
[[ $id =~ ^[0-9]+$ && $digest =~ ^[0-9a-f]{64}$ ]] || exit 1
archive="$RUNNER_TEMP/release-artifact.zip"
printf 'header = "Authorization: Bearer %s"\n' "$GH_TOKEN" | tool /usr/bin/curl \
    --config - --fail --location --proto '=https' --proto-redir '=https' \
    --output "$archive" "https://api.github.com/repos/sdelavega/tesserae/actions/artifacts/$id/zip"
tool python3 -I - "$archive" "$digest" <<'VERIFY'
import hashlib, pathlib, sys, zipfile
path = pathlib.Path(sys.argv[1])
if hashlib.sha256(path.read_bytes()).hexdigest() != sys.argv[2]:
    sys.exit("Release artifact digest mismatch")
with zipfile.ZipFile(path) as archive:
    if archive.namelist() != ["release-input.zip"]:
        sys.exit("Unexpected release artifact contents")
VERIFY
tool /usr/bin/ditto -x -k "$archive" "$RUNNER_TEMP/release-download"
tool python3 -I - "$RUNNER_TEMP/release-download/release-input.zip" <<'CONTENTS'
import pathlib, posixpath, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    for entry in archive.infolist():
        name = entry.filename.rstrip("/")
        if not name.startswith("release-input/") or posixpath.normpath(name) != name:
            if name == "release-input": continue
            sys.exit("Unsafe release archive path")
        if stat.S_ISLNK(entry.external_attr >> 16):
            target = archive.read(entry).decode("utf-8")
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            if not resolved.startswith("release-input/") or target.startswith("/"):
                sys.exit("Unsafe release archive symlink")
CONTENTS
tool /usr/bin/ditto -x -k "$RUNNER_TEMP/release-download/release-input.zip" apple/build
