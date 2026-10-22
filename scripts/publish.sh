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

publish() (
    set -euo pipefail
    [[ $# -le 2 ]] || { echo 'Too many publishing arguments' >&2; exit 1; }
    version=${1:-} mode=${2:-} root= tag= dmg= notes= sha= work= pages= cask= pushed=0 tap_temp=
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Usage: publish.sh VERSION [--ci-publish|--resume]' >&2; exit 1; }
    case "$mode" in ''|--ci-publish|--resume) ;; *) echo 'Unknown publishing option' >&2; exit 1 ;; esac
    root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
    cd "$root"
    git_tool=${GIT:-git} gh_tool=${GH:-gh} curl_tool=${CURL:-curl}
    GH=$gh_tool
    tag="v$version"
    dmg="dist/Tesserae-$version.dmg"
    notes="docs/releases/$version.md"
    # Bind every entry point to the verified bytes and the current commit.
    [[ -f dist/MANIFEST ]] || { echo 'Missing dist/MANIFEST' >&2; exit 1; }
    head= tag_commit=
    head=$(tool "$git_tool" rev-parse HEAD)
    if tool "$git_tool" show-ref --verify --quiet "refs/tags/$tag"; then
        tag_commit=$(tool "$git_tool" rev-parse "$tag^{}")
    else
        [[ $? == 1 ]] || exit 1
    fi
    tool python3 -I - "$version" "$head" "$tag_commit" "$dmg" <<'MANIFEST'
import hashlib, json, pathlib, sys
version, head, tag, dmg = sys.argv[1:]
proof = json.loads(pathlib.Path("dist/MANIFEST").read_text())
if proof.get("version") != version:
    sys.exit("MANIFEST version mismatch")
if proof.get("commit") != head or (tag and tag != head):
    sys.exit("MANIFEST commit must equal HEAD and the tag commit")
if proof.get("dmg_sha256") != hashlib.sha256(pathlib.Path(dmg).read_bytes()).hexdigest():
    sys.exit("MANIFEST DMG checksum mismatch")
if not proof.get("verified_at"):
    sys.exit("MANIFEST verification timestamp missing")
MANIFEST
    tool "${XCRUN:-xcrun}" stapler validate "$dmg"
    tool "${SPCTL:-spctl}" --assess --type open --context context:primary-signature "$dmg"
    [[ -f $notes ]] || { echo 'Missing release notes' >&2; exit 1; }
    [[ -n ${TESSERAE_TAP_DIR:-} ]] || { echo 'TESSERAE_TAP_DIR must name the local tap clone' >&2; exit 1; }
    tap=
    tap=$(cd "$TESSERAE_TAP_DIR" && pwd)
    [[ $(tool "$git_tool" -C "$tap" rev-parse --show-toplevel) == "$tap" ]] || { echo 'Tap must be a git repository root' >&2; exit 1; }
    origin=
    origin=$(cd "$tap" && tool "$git_tool" remote get-url origin)
    case "$origin" in https://github.com/sdelavega/homebrew-tap|https://github.com/sdelavega/homebrew-tap.git|git@github.com:sdelavega/homebrew-tap.git|ssh://git@github.com/sdelavega/homebrew-tap.git) ;; *) echo 'Tap origin must be sdelavega/homebrew-tap' >&2; exit 1 ;; esac
    (cd dist && tool shasum -a 256 -c SHA256SUMS)
    sha=$(tool shasum -a 256 "$dmg"); sha=${sha%% *}
    work=$(tool mktemp -d "$root/dist/.publish-$version.XXXXXX")
    pages="$work/pages"
    cask="$work/tesserae.rb"
    cleanup_publish() {
        local status=$?
        trap - EXIT
        if [[ $status != 0 && $pushed == 1 ]]; then
            echo "Resume: scripts/publish.sh $version --resume" >&2
        fi
        if [[ -d $pages ]]; then tool "$git_tool" worktree remove --force "$pages" || true; fi
        if [[ -n $tap_temp ]]; then tool rm -f "$tap_temp"; fi
        tool rm -rf "$work"
        exit "$status"
    }
    trap cleanup_publish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Render and verify the complete candidate before touching the tap.
    tool python3 -I - "$version" "$sha" "$cask" <<'CASK'
import pathlib, re, sys
version, sha, destination = sys.argv[1:]
text = pathlib.Path("packaging/tesserae.rb.template").read_text().replace("@VERSION@", version).replace("@SHA256@", sha)
if not re.fullmatch(r"[0-9a-f]{64}", sha) or f'version "{version}"' not in text or f'sha256 "{sha}"' not in text or "@VERSION@" in text or "@SHA256@" in text:
    sys.exit("Invalid cask render")
pathlib.Path(destination).write_text(text)
CASK
    tap_status=
    tap_status=$(tool "$git_tool" -C "$tap" status --porcelain --untracked-files=all)
    if [[ -n $tap_status ]]; then
        # A failed tap commit can leave our complete candidate staged. Resume
        # only that exact file; never absorb unrelated local changes.
        [[ $mode == --resume && $tap_status != *$'\n'* && ${tap_status:3} == Casks/tesserae.rb ]] || { echo 'Tap must be clean' >&2; exit 1; }
        tool cmp "$cask" "$tap/Casks/tesserae.rb" || { echo 'Tap changes do not match the release cask' >&2; exit 1; }
    fi
    echo "Tag: $tag"
    echo "DMG SHA-256: $sha"
    old_feed="$work/old-appcast.xml" old_cask="$tap/Casks/tesserae.rb" diff_status=
    fetch_appcast "$old_feed"
    tool bash scripts/appcast-check.sh "$version" "$old_feed"
    echo 'Appcast diff:'
    diff_status=0; tool diff -u "$old_feed" dist/appcast.xml || diff_status=$?
    [[ $diff_status -le 1 ]]
    echo 'Cask diff:'
    [[ -f $old_cask ]] || old_cask=/dev/null
    diff_status=0; tool diff -u "$old_cask" "$cask" || diff_status=$?
    [[ $diff_status -le 1 ]]
    echo 'Skipping brew style/audit: an offline, network-free audit cannot be guaranteed'
    if [[ $mode == --ci-publish || $mode == --resume ]]; then
        [[ $mode != --ci-publish || ${CI:-} == true ]] || { echo '--ci-publish requires CI=true' >&2; exit 1; }
        tool "$git_tool" fetch origin "refs/tags/$tag"
        [[ $(tool "$git_tool" rev-parse HEAD) == $(tool "$git_tool" rev-parse 'FETCH_HEAD^{}') ]] || { echo 'HEAD must equal the tag on origin' >&2; exit 1; }
        pushed=1
    fi
    if [[ $mode != --ci-publish ]]; then
        answer=
        printf 'Type %s to publish: ' "$version"
        IFS= read -r answer || { echo 'Confirmation required' >&2; exit 1; }
        [[ $answer == "$version" ]] || { echo 'Confirmation must match VERSION exactly' >&2; exit 1; }
    fi
    if [[ $pushed == 0 ]]; then
        signing_key=
        signing_key=$(tool "$git_tool" config --get user.signingkey || true)
        if [[ -n $signing_key ]]; then
            tool "$git_tool" tag -s "$tag" -m "Tesserae $version"
        else
            tool "$git_tool" tag -a "$tag" -m "Tesserae $version"
        fi
        tool "$git_tool" push origin "refs/tags/$tag"
        pushed=1
    fi
    # Resume validates the existing release and assets by uploading our checked
    # files again. Never silently accept an existing release on a fresh run.
    if [[ $mode == --resume ]] && PUBLISH_GH_AUTH=1 tool "$gh_tool" release view "$tag" --repo sdelavega/tesserae >/dev/null 2>&1; then
        PUBLISH_GH_AUTH=1 tool "$gh_tool" release upload "$tag" "$dmg" dist/SHA256SUMS --clobber --repo sdelavega/tesserae
    else
        PUBLISH_GH_AUTH=1 tool "$gh_tool" release create "$tag" "$dmg" dist/SHA256SUMS --verify-tag --notes-file "$notes" --title "Tesserae $version" --repo sdelavega/tesserae
    fi
    if tool "$git_tool" ls-remote --exit-code origin refs/heads/gh-pages >/dev/null; then
        tool "$git_tool" fetch origin gh-pages
        tool "$git_tool" show FETCH_HEAD:appcast.xml > "$old_feed"
        tool bash scripts/appcast-check.sh "$version" "$old_feed"
        tool "$git_tool" worktree add --detach "$pages" FETCH_HEAD
    else
        remote_status=$?
        [[ $remote_status == 2 ]] || exit "$remote_status"
        tool "$git_tool" worktree add --detach "$pages" HEAD
        # Seed a root commit directly, keeping HEAD detached throughout.
        tool "$git_tool" -C "$pages" rm -rf .
        empty_tree= pages_root=
        empty_tree=$(tool "$git_tool" -C "$pages" write-tree)
        pages_root=$(tool "$git_tool" -C "$pages" -c commit.gpgsign=false commit-tree "$empty_tree" -m 'Initialize release feed')
        tool "$git_tool" -C "$pages" update-ref --no-deref HEAD "$pages_root"
    fi
    tool cp dist/appcast.xml "$pages/appcast.xml"
    tool "$git_tool" -C "$pages" add appcast.xml
    if ! tool "$git_tool" -C "$pages" diff --cached --quiet; then
        tool "$git_tool" -C "$pages" -c commit.gpgsign=false commit -m "Release $tag appcast"
    fi
    tool "$git_tool" -C "$pages" push origin HEAD:refs/heads/gh-pages
    # The final copy is staged on the tap filesystem, then renamed atomically.
    tool mkdir -p "$tap/Casks"
    tap_temp=$(tool mktemp "$tap/Casks/.tesserae.XXXXXX")
    tool cp "$cask" "$tap_temp"
    tool cmp "$cask" "$tap_temp"
    tool mv "$tap_temp" "$tap/Casks/tesserae.rb"
    tool "$git_tool" -C "$tap" add Casks/tesserae.rb
    if ! tool "$git_tool" -C "$tap" diff --cached --quiet; then
        tool "$git_tool" -C "$tap" -c commit.gpgsign=false commit -m "Tesserae $version"
    fi
    tool "$git_tool" -C "$tap" push origin HEAD
    # Allow Pages deployment/edge-cache propagation for less than ten minutes:
    # 25 requests capped at 5 seconds, with 5/10/20-second capped backoff.
    pages_ready=0 delay=5
    for ((attempt=1; attempt<=25; attempt++)); do
        if tool "$curl_tool" --fail --location --max-time 5 --output "$work/appcast.xml" https://sdelavega.github.io/tesserae/appcast.xml &&
            tool cmp -s dist/appcast.xml "$work/appcast.xml"; then
            pages_ready=1
            break
        fi
        if [[ $attempt -lt 25 ]]; then
            tool sleep "$delay"
            if [[ $delay -lt 20 ]]; then delay=$((delay * 2)); fi
        fi
    done
    [[ $pages_ready == 1 ]] || { echo 'Pages feed did not converge within ten minutes' >&2; exit 1; }
    tool "$curl_tool" --fail --location --output "$work/release.dmg" "https://github.com/sdelavega/tesserae/releases/download/$tag/Tesserae-$version.dmg"
    expected= actual= file=
    for file in appcast.xml release.dmg; do
        if [[ $file == appcast.xml ]]; then expected=$(tool shasum -a 256 dist/appcast.xml); else expected=$(tool shasum -a 256 "$dmg"); fi
        actual=$(tool shasum -a 256 "$work/$file")
        [[ ${expected%% *} == "${actual%% *}" ]] || { echo "Published checksum mismatch: $file" >&2; exit 1; }
    done
    if command -v brew >/dev/null; then
        tool brew tap sdelavega/tap
        tool brew fetch --cask sdelavega/tap/tesserae
    else
        echo 'Skipping brew fetch: brew is unavailable'
    fi
    echo 'Post-publish checks passed'
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# == 2 && ( $2 == --resume || $2 == --ci-publish ) ]] || {
        echo 'Standalone use requires VERSION and --resume or --ci-publish' >&2
        exit 1
    }
    # The standalone resume entry point applies the same output redaction.
    (publish "$@") 2>&1 | tool python3 -I -c '
import os, sys
values = sorted(filter(None, os.fdopen(3).read().split("\0")), key=len, reverse=True)
for line in sys.stdin:
    for value in values:
        line = line.replace(value, "[REDACTED]")
    sys.stdout.write(line)
' 3< <(redactions)
fi
