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


# Refuse ambient shell state before defining functions or launching tools.
if [[ ${BASH_ENV+x} || -n $(builtin compgen -A function) ]]; then
    builtin printf '%s\n' 'Release requires no inherited shell state; use just release' >&2
    exit 1
fi

set -euo pipefail
source "${BASH_SOURCE[0]%/*}/release-tools.sh"
XCODEBUILD=${XCODEBUILD:-xcodebuild}
CODESIGN=${CODESIGN:-codesign}
XCRUN=${XCRUN:-xcrun}
SPCTL=${SPCTL:-spctl}
HDIUTIL=${HDIUTIL:-hdiutil}
SECURITY=${SECURITY:-security}
GIT=${GIT:-git}
JUST=${JUST:-just}
PYTHON=${PYTHON:-python3}
MKDIR=${MKDIR:-mkdir}
MKTEMP=${MKTEMP:-mktemp}
RM=${RM:-rm}
CP=${CP:-cp}
SHASUM=${SHASUM:-shasum}
BASH_TOOL=${BASH_TOOL:-bash}
DIRNAME=${DIRNAME:-dirname}

fail() { echo "$*" >&2; exit 1; }
[[ $# -ge 1 ]] || fail 'Usage: release.sh VERSION [--publish] [--ci-publish]'
VERSION=$1; shift
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must be x.y.z'
MODE=
PREBUILT=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish|--ci-publish) [[ -z $MODE ]] || fail 'Choose one publishing mode'; MODE=$1 ;;
        --prebuilt) [[ $# -ge 2 && -z $PREBUILT ]] || fail 'One prebuilt input path required'; PREBUILT=$2; shift ;;
        *) fail 'Unknown release option' ;;
    esac
    shift
done
[[ -z $PREBUILT || $MODE == --ci-publish ]] || fail 'Prebuilt input requires CI publishing mode'
# Consume CI's private pipe before any build/preflight tool can read stdin.
# Unset first so even an inherited variable of this name cannot stay exported.
unset SPARKLE_STDIN_KEY
SPARKLE_STDIN_KEY=
if [[ $MODE == --ci-publish ]]; then
    [[ ${CI:-} == true ]] || fail '--ci-publish requires CI=true'
    SPARKLE_STDIN_KEY=$(tool cat)
    exec 0</dev/null
    [[ -n $SPARKLE_STDIN_KEY ]] || fail 'Missing Sparkle key on stdin'
fi
ROOT=$(cd "$(tool "$DIRNAME" "$0")/.." && pwd)
cd "$ROOT"
tool "$MKDIR" -p dist

# Redact secret-bearing environment values before either stdout or the log.
# Tool output must never bypass this filter; do not enable shell tracing.
release() {
    WORK=$(tool "$MKTEMP" -d "$ROOT/dist/.release-$VERSION.XXXXXX")
    MOUNT="$WORK/mount"
    ATTACHED=0
    cleanup() {
        local status=$?
        trap - EXIT
        if [[ $ATTACHED == 1 ]]; then
            if ! tool "$HDIUTIL" detach "$MOUNT"; then
                echo 'Failed to detach release image; retained work directory' >&2
                exit 1
            fi
        fi
        tool "$RM" -rf "$WORK"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    TREE_STATUS=$(tool "$GIT" status --porcelain)
    [[ -z $TREE_STATUS ]] || fail 'Release requires a clean tree'
    if [[ $MODE == --ci-publish ]]; then
        [[ ${CI:-} == true ]] || fail '--ci-publish requires CI=true'
        tool "$GIT" fetch origin "refs/tags/v$VERSION"
        [[ $(tool "$GIT" rev-parse HEAD) == $(tool "$GIT" rev-parse 'FETCH_HEAD^{}') ]] || fail 'HEAD must equal the tag on origin'
    else
        [[ $(tool "$GIT" branch --show-current) == main ]] || fail 'Release requires main'
        tool "$GIT" fetch origin main
        LOCAL_HEAD=$(tool "$GIT" rev-parse HEAD)
        REMOTE_HEAD=$(tool "$GIT" rev-parse origin/main)
        [[ $LOCAL_HEAD == "$REMOTE_HEAD" ]] || fail 'main must match origin/main'
    fi
    tool "$PYTHON" - "$VERSION" <<'VERSION_CHECK'
import pathlib, re, sys
versions = re.findall(r"MARKETING_VERSION\s*=\s*([^;]+);", pathlib.Path("apple/Tesserae.xcodeproj/project.pbxproj").read_text())
if not versions or any(v.strip().strip('"') != sys.argv[1] for v in versions):
    sys.exit("VERSION must equal MARKETING_VERSION")
VERSION_CHECK
    if [[ $MODE != --ci-publish ]]; then
        if tool "$GIT" show-ref --verify --quiet "refs/tags/v$VERSION"; then
            fail 'Release tag already exists'
        else
            [[ $? == 1 ]] || fail 'Cannot check release tag'
        fi
    fi
    [[ -f apple/Release.local.xcconfig ]] || fail 'Missing apple/Release.local.xcconfig'
    tool "$PYTHON" - "$WORK/config" <<'CONFIG'
import pathlib, re, sys
text = pathlib.Path("apple/Release.local.xcconfig").read_text()
text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
values = {}
for line in text.splitlines():
    line = line.split("//", 1)[0].strip()
    match = re.fullmatch(r"([A-Z_]+)\s*=\s*(.*?)\s*;?", line)
    if match and match[1] in {"DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY", "NOTARY_PROFILE"}:
        value = match[2].strip().strip('"')
        if not value or any(ord(c) < 32 for c in value):
            sys.exit("Empty or invalid release setting")
        values[match[1]] = value
keys = ["DEVELOPMENT_TEAM", "CODE_SIGN_IDENTITY", "NOTARY_PROFILE"]
if any(k not in values for k in keys):
    sys.exit("Missing required release setting")
if not re.fullmatch(r"[A-Za-z0-9]+", values[keys[0]]) or not (re.fullmatch(r"[A-Fa-f0-9]{40}", values[keys[1]]) or values[keys[1]].startswith("Developer ID Application:")):
    sys.exit("Release requires a Developer ID Application identity and team")
pathlib.Path(sys.argv[1]).write_text("\n".join(values[k] for k in keys) + "\n")
CONFIG
    { IFS= read -r DEVELOPMENT_TEAM; IFS= read -r CODE_SIGN_IDENTITY; IFS= read -r NOTARY_PROFILE; } < "$WORK/config"
    tool "$SECURITY" find-identity -v -p codesigning > "$WORK/identities"
    CODE_SIGN_IDENTITY=$(tool "$PYTHON" - "$WORK/identities" "$CODE_SIGN_IDENTITY" "$DEVELOPMENT_TEAM" <<'IDENTITY'
import pathlib, re, sys
identities = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"\n]+)"', pathlib.Path(sys.argv[1]).read_text(), re.M)
selected, team = sys.argv[2:]
by_hash = bool(re.fullmatch(r"[A-Fa-f0-9]{40}", selected))
matches = [(sha, name) for sha, name in identities if (sha.lower() == selected.lower() if by_hash else name == selected)]
if len(matches) != 1:
    sys.exit("Signing identity is unavailable or ambiguous; select its SHA-1")
sha, name = matches[0]
if not name.startswith("Developer ID Application:") or not name.endswith(f" ({team})"):
    sys.exit("Signing identity must be Developer ID Application with the configured team")
print(sha.upper())
IDENTITY
)
    local notary_args=(--keychain-profile "$NOTARY_PROFILE")
    if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then notary_args+=(--keychain "$NOTARY_KEYCHAIN"); fi
    tool "$XCRUN" notarytool history "${notary_args[@]}" > /dev/null
    BUILD_VERSION=$(tool "$BASH_TOOL" "$ROOT/scripts/bundle-version.sh" "$VERSION")
    if [[ -n $PREBUILT ]]; then
        tool "$PYTHON" -I scripts/verify-release-input.py "$PREBUILT" "$VERSION" "$(tool "$GIT" rev-parse HEAD)"
        tool /usr/bin/ditto "$PREBUILT/Tesserae.app" "$WORK/export/Tesserae.app"
    else
        tool "$JUST" gate
        tool "$JUST" ffi
        tool "$XCODEBUILD" archive -project apple/Tesserae.xcodeproj -scheme Tesserae \
            -configuration Release -destination 'generic/platform=macOS' \
            -archivePath "$WORK/Tesserae.xcarchive" -derivedDataPath apple/build/DerivedData \
            'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO "CURRENT_PROJECT_VERSION=$BUILD_VERSION" "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY" 'SWIFT_ACTIVE_COMPILATION_CONDITIONS='
        tool "$PYTHON" - "$WORK/ExportOptions.plist" "$DEVELOPMENT_TEAM" "$CODE_SIGN_IDENTITY" <<'EXPORT'
import plistlib, sys
with open(sys.argv[1], "wb") as out:
    plistlib.dump(dict(method="developer-id", signingStyle="manual", teamID=sys.argv[2], signingCertificate=sys.argv[3]), out)
EXPORT
        tool "$XCODEBUILD" -exportArchive -archivePath "$WORK/Tesserae.xcarchive" \
            -exportPath "$WORK/export" -exportOptionsPlist "$WORK/ExportOptions.plist"
    fi
    APP="$WORK/export/Tesserae.app"
    [[ -d $APP/Contents/Frameworks/TesseraeKit.framework && -d $APP/Contents/Frameworks/Sparkle.framework ]] || fail 'Export is missing required frameworks'
    [[ -f $APP/Contents/Helpers/applesauce ]] || fail 'Export is missing applesauce'
    if [[ -n $PREBUILT ]]; then
        tool "$PYTHON" -I - "$APP" > "$WORK/signing-order" <<'ORDER'
import pathlib, sys
app = pathlib.Path(sys.argv[1])
magic = {bytes.fromhex(h) for h in ("cafebabe", "bebafeca", "feedface", "cefaedfe", "feedfacf", "cffaedfe")}
paths = [path for path in app.rglob("*") if not path.is_symlink()]
for path in paths:
    if path.is_file():
        with path.open("rb") as stream:
            if stream.read(4) in magic:
                print(path)
for path in sorted((p for p in paths if p.is_dir() and p.suffix in {".framework", ".xpc", ".app"}), key=lambda p: len(p.parts), reverse=True):
    print(path)
print(app)
ORDER
        while IFS= read -r bundle; do
            tool "$CODESIGN" --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$bundle"
        done < "$WORK/signing-order"
    else
        tool "$CODESIGN" --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$APP/Contents/Helpers/applesauce"
        tool "$CODESIGN" --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$APP"
    fi
    tool "$CODESIGN" --verify --deep --strict "$APP"
    tool "$BASH_TOOL" "$ROOT/scripts/check-shipped-app.sh" "$APP"
    tool "$CODESIGN" -d --entitlements :- "$APP" > "$WORK/entitlements.plist"
    tool "$PYTHON" - "$WORK/entitlements.plist" <<'ENTITLEMENTS'
import pathlib, plistlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
# codesign emits no plist when the signature has no entitlements.
entitlements = plistlib.loads(raw) if raw.strip() else {}
if entitlements.get("com.apple.security.app-sandbox", False):
    sys.exit("Release app must not be sandboxed")
ENTITLEMENTS
    # Verify every nested framework, XPC service and helper app. Export performs
    # inside-out signing; a missing or foreign signature stops this pipeline.
    tool "$PYTHON" - "$APP" > "$WORK/bundles" <<'BUNDLES'
import pathlib, sys
app = pathlib.Path(sys.argv[1])
print(app)
print(app / "Contents/Helpers/applesauce")
for path in sorted(app.rglob("*")):
    if not path.is_symlink() and path.suffix in {".framework", ".xpc", ".app"} and path.is_dir():
        print(path)
BUNDLES
    while IFS= read -r bundle; do
        tool "$CODESIGN" --verify --deep --strict "$bundle"
        tool "$CODESIGN" -d --verbose=4 "$bundle" > "$WORK/signature" 2>&1
        tool "$PYTHON" - "$WORK/signature" "$DEVELOPMENT_TEAM" "$bundle" "$APP" <<'SIGNATURE'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
if not re.search(r"^TeamIdentifier=" + re.escape(sys.argv[2]) + r"$", text, re.M):
    sys.exit("Export signature has the wrong team")
if not re.search(r"flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", text):
    sys.exit("Export signature lacks hardened runtime")
if not re.search(r"^Timestamp=.+$", text, re.M):
    sys.exit("Export signature lacks a secure timestamp")
SIGNATURE
    done < "$WORK/bundles"
    DMG="$WORK/Tesserae-$VERSION.dmg"
    tool "$BASH_TOOL" "$ROOT/scripts/make-dmg.sh" "$VERSION" "$APP" "$DMG" "$CODE_SIGN_IDENTITY"
    # A nonzero submit can still carry an Invalid response and log request ID.
    SUBMIT_STATUS=0
    tool "$XCRUN" notarytool submit "$DMG" "${notary_args[@]}" --wait \
        --output-format json > "$WORK/notary.json" || SUBMIT_STATUS=$?
    tool "$PYTHON" - "$WORK/notary.json" > "$WORK/notary-status" <<'NOTARY'
import json, pathlib, sys
result = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(result.get("status", ""))
print(result.get("id", ""))
NOTARY
    { IFS= read -r NOTARY_STATUS; IFS= read -r REQUEST_ID; } < "$WORK/notary-status"
    if [[ $NOTARY_STATUS == Invalid || $NOTARY_STATUS == Rejected ]]; then
        [[ -n $REQUEST_ID ]] || fail 'Notarization Invalid without a request ID'
        tool "$XCRUN" notarytool log "$REQUEST_ID" "${notary_args[@]}" > "$WORK/notary-log.json"
        # Apple returns JSON diagnostics, which need not contain a remote URL.
        # Keep a redacted local copy and always print its usable file URL.
        tool "$PYTHON" - "$WORK/notary-log.json" "dist/notary-$VERSION.json" 3< <(redactions) <<'NOTARY_LOG'
import os, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
for value in sorted(filter(None, os.fdopen(3).read().split("\0")), key=len, reverse=True):
    text = text.replace(value, "[REDACTED]")
path = pathlib.Path(sys.argv[2])
path.write_text(text)
print(text)
print("Notarization log: " + path.resolve().as_uri())
NOTARY_LOG
        fail "Notarization $NOTARY_STATUS; see the log URL above"
    fi
    [[ $SUBMIT_STATUS == 0 && $NOTARY_STATUS == Accepted ]] || fail 'Notarization was not Accepted'
    tool "$XCRUN" stapler staple "$DMG"
    tool "$XCRUN" stapler validate "$DMG"
    tool "$SPCTL" --assess --type open --context context:primary-signature "$DMG"
    tool "$MKDIR" -p "$MOUNT"
    # Set before attach so cleanup also handles partial attach failures.
    ATTACHED=1
    tool "$HDIUTIL" attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT"
    tool "$SPCTL" --assess --type execute "$MOUNT/Tesserae.app"
    tool "$HDIUTIL" detach "$MOUNT"
    ATTACHED=0
    (cd "$WORK" && tool "$SHASUM" -a 256 "Tesserae-$VERSION.dmg" > SHA256SUMS)
    tool "$CP" "$DMG" "dist/Tesserae-$VERSION.dmg"
    tool "$CP" "$WORK/SHA256SUMS" dist/SHA256SUMS
    local tools="$ROOT/apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [[ -n $PREBUILT ]]; then
        # appcast-check.sh uses the normal resolved-tools location too.
        tool "$MKDIR" -p "$tools"
        tool "$CP" "$PREBUILT/sparkle-tools/generate_appcast" "$tools/generate_appcast"
        tool "$CP" "$PREBUILT/sparkle-tools/sign_update" "$tools/sign_update"
    fi
    [[ -x $tools/generate_appcast && -x $tools/sign_update ]] || fail 'Resolved Sparkle tools are missing; resolve the pinned package first'
    [[ -f docs/releases/$VERSION.md ]] || fail 'Missing release notes'
    tool "$CP" "docs/releases/$VERSION.md" "dist/Tesserae-$VERSION.md"
    tool "$MKDIR" -p "$WORK/feed"
    fetch_appcast "$WORK/published.xml"
    if [[ -s $WORK/published.xml ]]; then tool "$CP" "$WORK/published.xml" "$WORK/feed/appcast.xml"; fi
    tool "$CP" "$DMG" "$WORK/feed/Tesserae-$VERSION.dmg"
    tool "$CP" "docs/releases/$VERSION.md" "$WORK/feed/Tesserae-$VERSION.md"
    local sparkle_args=(--download-url-prefix "https://github.com/sdelavega/tesserae/releases/download/v$VERSION/" --embed-release-notes --maximum-deltas 0 --maximum-versions 0 --disable-signing-warning)
    # CI supplies the key on stdin; the local default uses Sparkle's keychain.
    if [[ $MODE == --ci-publish ]]; then
        sparkle_args+=(--ed-key-file -)
        tool "$tools/generate_appcast" "${sparkle_args[@]}" "$WORK/feed" <<< "$SPARKLE_STDIN_KEY"
    else
        tool "$tools/generate_appcast" "${sparkle_args[@]}" "$WORK/feed"
    fi
    tool "$PYTHON" -I scripts/appcast-history.py merge "$WORK/published.xml" "$WORK/feed/appcast.xml" "$BUILD_VERSION"
    # generate_appcast signs feeds required by SURequireSignedFeed. The byte-
    # preserving history merge changes those bytes, so sign the final feed again.
    if [[ $MODE == --ci-publish ]]; then
        tool "$tools/sign_update" --disable-signing-warning --ed-key-file - "$WORK/feed/appcast.xml" <<< "$SPARKLE_STDIN_KEY"
        unset SPARKLE_STDIN_KEY
    else
        tool "$tools/sign_update" --disable-signing-warning "$WORK/feed/appcast.xml"
    fi
    tool "$CP" "$WORK/feed/appcast.xml" dist/appcast.xml
    tool "$BASH_TOOL" scripts/appcast-check.sh "$VERSION" "$WORK/published.xml"
    local manifest_head
    manifest_head=$(tool "$GIT" rev-parse HEAD)
    tool "$PYTHON" -I - "$VERSION" "$manifest_head" <<'MANIFEST'
import datetime, hashlib, json, pathlib, sys
version, commit = sys.argv[1:]
root = pathlib.Path("dist")
proof = dict(version=version, commit=commit,
             dmg_sha256=hashlib.sha256((root / f"Tesserae-{version}.dmg").read_bytes()).hexdigest(),
             verified_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
(root / "MANIFEST").write_text(json.dumps(proof, indent=2) + "\n")
MANIFEST
    if [[ -n $MODE ]]; then
        source "$ROOT/scripts/publish.sh"
        if [[ $MODE == --ci-publish ]]; then publish "$VERSION" --ci-publish; else publish "$VERSION"; fi
    fi
    echo "Verified dist/Tesserae-$VERSION.dmg and dist/SHA256SUMS"
}
# Run in a subshell so its EXIT trap runs before the logging filter finishes.
(release) 2>&1 | tool "$PYTHON" -c '
import os, re, sys
values = sorted(filter(None, os.fdopen(3).read().split("\0")), key=len, reverse=True)
with open(sys.argv[1], "w") as log:
    for line in sys.stdin:
        for value in values:
            line = line.replace(value, "[REDACTED]")
        log.write(line)
        log.flush()
        sys.stdout.write(line)
        sys.stdout.flush()
' "dist/release-$VERSION.log" 3< <(redactions)
