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
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/tesserae-release-test.XXXXXX")
TEMP=$(cd "$TEMP" && pwd -P)
trap 'rm -rf "$TEMP"' EXIT
fail() { echo "FAIL: $*" >&2; if [[ -f ${CASE_ROOT:-}/output ]]; then cat "$CASE_ROOT/output" >&2; tail -8 "$CALLS" >&2; fi; exit 1; }
contains() { grep -F -- "$2" "$1" >/dev/null || fail "missing $2"; }
absent() { if grep -F -- "$2" "$1" >/dev/null; then fail "unexpected $2"; fi; }

fixture() {
    CASE_ROOT="$TEMP/$1 space"
    mkdir -p "$CASE_ROOT/scripts" "$CASE_ROOT/apple/Tesserae.xcodeproj" "$CASE_ROOT/bin"
    cp "$ROOT/scripts/"{release.sh,build-release-input.sh,check-shipped-app.sh,verify-release-input.py,sparkle-tools.sha256,release-tools.sh,make-dmg.sh,bundle-version.sh,appcast-check.sh,appcast-history.py,publish.sh} "$CASE_ROOT/scripts/"
    printf 'MARKETING_VERSION = 0.1.0;\n' > "$CASE_ROOT/apple/Tesserae.xcodeproj/project.pbxproj"
    cat > "$CASE_ROOT/apple/Release.local.xcconfig" <<'CONFIG'
// A shell expression here must remain inert.
IGNORED = $(touch parser-was-sourced)
DEVELOPMENT_TEAM = TESTTEAM // public team
CODE_SIGN_IDENTITY = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
NOTARY_PROFILE = test-profile
CONFIG
    cat > "$CASE_ROOT/bin/fake" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
fake_root=$(python3 -I -c 'import pathlib,sys; print(next(p for p in pathlib.Path(sys.argv[1]).resolve().parents if (p / "fault").is_file()))' "$0")
CALLS="$fake_root/calls"
FAULT=$(cat "$fake_root/fault")
CI=
NOTARY_KEYCHAIN=
if [[ -e $fake_root/ci ]]; then CI=true; NOTARY_KEYCHAIN="$fake_root/ci.keychain-db"; fi
printf '%s' "$name" >> "$CALLS"
printf '\t%s' "$@" >> "$CALLS"
printf '\n' >> "$CALLS"
python3 -I - "$CALLS.env" <<'SAFE_ENV'
import os, pathlib, sys
allowed = {"PATH", "HOME", "TMPDIR", "LANG", "USER", "DEVELOPER_DIR", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"}
assert all(k in allowed or k.startswith("LC_") for k in os.environ), "Unexpected child environment names: " + ", ".join(k for k in os.environ if k not in allowed and not k.startswith("LC_"))
with pathlib.Path(sys.argv[1]).open("a") as log: log.write("SAFE_CHILD_ENV\n")
SAFE_ENV
args=" $* "
# Match named options without losing spaces in paths.
option() { local key=$1; shift; while [[ $# -gt 0 ]]; do if [[ $1 == "$key" ]]; then printf '%s\n' "$2"; return; fi; shift; done; return 1; }
case "$name" in
 generate_appcast)
    [[ $* == *--download-url-prefix* && $* == *--embed-release-notes* ]] || exit 101
    if [[ ${CI:-} == true ]]; then [[ $* == *'--ed-key-file -'* ]] || exit 106; else [[ $* != *--ed-key-file* ]] || exit 107; printf 'LOCAL_KEYCHAIN_OK\n' >> "$CALLS"; fi
    if [[ $* == *--ed-key-file* ]]; then
        [[ ${CI:-} == true && $* == *'--ed-key-file -'* ]] || exit 103
        IFS= read -r fake_ci_input
        [[ $fake_ci_input == fake-ci-stdin ]] || exit 104
        printf 'CI_STDIN_OK\n' >> "$CALLS"
    fi
    for feed_dir in "$@"; do :; done
    [[ $feed_dir != dist && -d $feed_dir ]] || exit 111
    [[ ! -e $feed_dir/Stale.dmg ]] || exit 112
    printf 'ISOLATED_FEED_OK\n' >> "$CALLS"
    python3 -I - "$feed_dir" <<'XML'
from pathlib import Path
import sys
from xml.etree import ElementTree as E
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
rss = E.Element('rss'); item = E.SubElement(E.SubElement(rss, 'channel'), 'item')
for key, value in [('version', '100'), ('shortVersionString', '0.1.0'), ('minimumSystemVersion', '13.0')]: E.SubElement(item, ns + key).text = value
E.SubElement(item, 'description').text = Path('docs/releases/0.1.0.md').read_text()
E.SubElement(item, 'enclosure', {'url':'https://github.com/sdelavega/tesserae/releases/download/v0.1.0/Tesserae-0.1.0.dmg', 'length':str(Path('dist/Tesserae-0.1.0.dmg').stat().st_size), ns+'edSignature':'fake-signature'})
E.ElementTree(rss).write(Path(sys.argv[1]) / 'appcast.xml')
XML
    ;;
 sign_update)
    [[ ! -e dist/MANIFEST ]] || exit 105
    if [[ $1 == --verify ]]; then
        IFS= read -r public_input; [[ -n $public_input ]]
        if [[ $2 == *.xml ]]; then
            python3 -I - "$2" <<'VERIFY_FEED'
import base64, hashlib, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
content = raw.split(b'<!-- sparkle-signatures:')[0]
sig = base64.b64encode(hashlib.sha512(content).digest())
assert raw == content + b'<!-- sparkle-signatures:\nedSignature: ' + sig + b'\nlength: ' + str(len(content)).encode() + b'\n-->\n'
VERIFY_FEED
        else [[ $3 == fake-signature ]] || exit 102; fi
    else
        [[ $1 == --disable-signing-warning ]] || exit 102
        if [[ ${CI:-} == true ]]; then
            [[ $2 == --ed-key-file && $3 == - ]] || exit 106
            IFS= read -r fake_ci_input; [[ $fake_ci_input == fake-ci-stdin ]] || exit 104
            printf 'FEED_CI_STDIN_OK\n' >> "$CALLS"
        fi
        for feed in "$@"; do :; done
        python3 -I - "$feed" "$FAULT" <<'SIGN_FEED'
import base64, hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1]); data = path.read_bytes().split(b'<!-- sparkle-signatures:')[0]
if sys.argv[2] != 'unsigned-feed':
    sig = base64.b64encode(hashlib.sha512(data).digest())
    data += b'<!-- sparkle-signatures:\nedSignature: ' + sig + b'\nlength: ' + str(len(data)).encode() + b'\n-->\n'
if sys.argv[2] == 'tampered-feed':
    import re
    data = data.replace(b'<rss', b'<rss tampered="yes"', 1)
    data = re.sub(rb'length: [0-9]+', b'length: ' + str(len(data.split(b'<!-- sparkle-signatures:')[0])).encode(), data)
path.write_bytes(data)
SIGN_FEED
    fi
    ;;
 git)
    case "$1" in
      status)
        if [[ ${CI:-} == true ]]; then
            early_input=$(cat)
            [[ -z $early_input ]] || exit 110
            printf 'EARLY_STDIN_EOF_OK\n' >> "$CALLS"
        fi
        [[ ${FAULT:-} != dirty ]] || echo ' M tracked' ;;
      branch) if [[ ${FAULT:-} == branch ]]; then echo topic; else echo main; fi ;;
      ls-remote) exit 2 ;;
      fetch) [[ ${FAULT:-} != fetch ]] ;;
      rev-parse) if [[ ${FAULT:-} == stale && $* == *origin/main* ]]; then echo old; else echo abc; fi ;;
      show-ref) [[ ${FAULT:-} == tag ]] ;;
      *) exit 90 ;;
    esac ;;
 security) [[ $* == 'find-identity -v -p codesigning' ]] || exit 91
    [[ ${FAULT:-} == identity ]] || printf '%s\n' ' 1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Test Person (TESTTEAM)"' ' 2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Test Person (TESTTEAM)"' ' 3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Other (WRONGTEAM)"' ;;
 just) [[ ${FAULT:-} != "$1" ]] ;;
 xcodebuild)
    if [[ $args == *' archive '* ]]; then
      [[ $args == *' CURRENT_PROJECT_VERSION=100 '* && $args == *' ARCHS=arm64 x86_64 '* && $args == *' -configuration Release '* && $args == *' CODE_SIGN_IDENTITY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB '* ]] || exit 92
      [[ ${FAULT:-} != archive ]] || exit 1
    else
      [[ ${FAULT:-} != export ]] || exit 1
      dest=$(option -exportPath "$@")
      mkdir -p "$dest/Tesserae.app/Contents/Frameworks/"{TesseraeKit.framework,Sparkle.framework/Versions/B/XPCServices/Downloader.xpc,Sparkle.framework/Versions/B/Updater.app}
      mkdir -p "$dest/Tesserae.app/Contents/Helpers"
      touch "$dest/Tesserae.app/Contents/Helpers/applesauce"
      mkdir -p "$dest/Tesserae.app/Contents/MacOS"
      printf 'shipping app' > "$dest/Tesserae.app/Contents/MacOS/Tesserae"
      printf 'shipping framework' > "$dest/Tesserae.app/Contents/Frameworks/TesseraeKit.framework/TesseraeKit"
      if [[ ${FAULT:-} == test-hooks ]]; then printf 'TESSERAE_FRAME_GATE' >> "$dest/Tesserae.app/Contents/MacOS/Tesserae"; fi
      [[ ${FAULT:-} != missing-framework ]] || rm -rf "$dest/Tesserae.app/Contents/Frameworks/TesseraeKit.framework"
      python3 - "$(option -exportOptionsPlist "$@")" <<'PLIST'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
assert p['method'] == 'developer-id' and p['signingStyle'] == 'manual'
assert p['teamID'] == 'TESTTEAM'
assert p['signingCertificate'] == 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
PLIST
    fi
    # Deliberately hostile fake output: the release logger must redact it.
    printf '%s\n' 'fake-password-unique' 'fake-token-unique' 'fake-key-unique' 'plant-p12-export' ;;
 codesign)
    if [[ $args == *' --sign '* ]]; then
      [[ $args == *' --timestamp '* && $args == *' BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB '* ]] || exit 93
      [[ ${FAULT:-} != dmg-sign || $args != *.dmg* ]] || exit 1
    elif [[ $args == *' --verify '* ]]; then
      [[ ${FAULT:-} != verify ]] || exit 1
    elif [[ $args == *' --entitlements '* ]]; then
      if [[ ${FAULT:-} == sandbox ]]; then
        echo '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>'
      else echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>'; fi
    else
      if [[ ${FAULT:-} == team && $args == *Sparkle.framework* ]]; then echo TeamIdentifier=WRONG; else echo TeamIdentifier=TESTTEAM; fi
      if [[ ${FAULT:-} != runtime && ( ${FAULT:-} != nested-runtime || $args != *Downloader.xpc* ) ]]; then echo 'CodeDirectory v=20500 flags=0x10000(runtime) hashes=1'; fi
      if [[ ${FAULT:-} != nested-timestamp || $args != *Updater.app* ]]; then echo 'Timestamp=Oct 21, 2026 at 12:00:00'; fi
      [[ ${FAULT:-} != unsigned-xpc || $args != *Downloader.xpc* ]] || exit 1
    fi ;;
 hdiutil)
    case "$1" in
      create)
        stage=$(option -srcfolder "$@")
        [[ -d $stage/Tesserae.app && -L $stage/Applications && $(readlink "$stage/Applications") == /Applications ]] || exit 94
        [[ $(option -format "$@") == UDZO && $(option -volname "$@") == 'Tesserae 0.1.0' ]] || exit 95
        [[ ${FAULT:-} != dmg ]] || exit 1
        for last in "$@"; do :; done
        echo 'fake dmg' > "$last" ;;
      attach)
        [[ $args == *' -readonly '* && $args == *' -nobrowse '* ]] || exit 96
        mount=$(option -mountpoint "$@")
        mkdir -p "$mount/Tesserae.app"
        [[ ${FAULT:-} != attach ]] || exit 1 ;;
      detach) [[ ${FAULT:-} != detach ]] ;;
      *) exit 97 ;;
    esac ;;
 xcrun)
    if [[ $1 == notarytool ]]; then
        if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then
            [[ $(option --keychain "$@") == "$NOTARY_KEYCHAIN" ]] || exit 108
            printf 'NOTARY_KEYCHAIN_OK\n' >> "$CALLS"
        else [[ $args != *' --keychain '* ]] || exit 109; fi
    fi
    case "$1 $2" in
      'notarytool history') [[ $args == *' --keychain-profile test-profile '* && ${FAULT:-} != profile ]] ;;
      'notarytool submit')
        [[ $args == *' --keychain-profile test-profile '* && $args == *' --wait '* ]] || exit 98
        [[ ${FAULT:-} != submit ]] || exit 1
        if [[ ${FAULT:-} == rejected ]]; then echo '{"id":"request-id","status":"Rejected"}'; elif [[ ${FAULT:-} == invalid ]]; then echo '{"id":"request-id","status":"Invalid"}'; else echo '{"id":"request-id","status":"Accepted"}'; fi ;;
      'notarytool log') echo '{"logFileUrl":"https://example.invalid/notary-log"}' ;;
      'stapler staple') [[ ${FAULT:-} != staple ]] ;;
      'stapler validate') [[ ${FAULT:-} != validate ]] ;;
      *) exit 99 ;;
    esac ;;
 spctl)
    [[ ${FAULT:-} != spctl ]] || exit 1
    [[ ${FAULT:-} != execute || $args != *' --type execute '* ]] || exit 1 ;;
 *) exit 100 ;;
esac
FAKE
    chmod +x "$CASE_ROOT/bin/fake"
    for tool in git security just xcodebuild codesign hdiutil xcrun spctl; do ln -s fake "$CASE_ROOT/bin/$tool"; done
    mkdir -p "$CASE_ROOT/docs/releases" "$CASE_ROOT/apple/Tesserae" "$CASE_ROOT/apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    printf 'Notes\n' > "$CASE_ROOT/docs/releases/0.1.0.md"
    printf '<?xml version="1.0"?><plist version="1.0"><dict><key>SUPublicEDKey</key><string>AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=</string></dict></plist>' > "$CASE_ROOT/apple/Tesserae/Info.plist"
    for tool in generate_appcast sign_update; do ln -s "$CASE_ROOT/bin/fake" "$CASE_ROOT/apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"; done
    CALLS="$CASE_ROOT/calls"; : > "$CALLS"; : > "$CASE_ROOT/fault"
}
run_release() {
    local expected=$1; shift
    local status=0
    printf '%s' "${FAULT:-}" > "$CASE_ROOT/fault"
    PATH="$CASE_ROOT/bin:$PATH" CALLS="$CALLS" FAULT="${FAULT:-}" \
      XCODEBUILD="$CASE_ROOT/bin/xcodebuild" CODESIGN="$CASE_ROOT/bin/codesign" \
      XCRUN="$CASE_ROOT/bin/xcrun" SPCTL="$CASE_ROOT/bin/spctl" HDIUTIL="$CASE_ROOT/bin/hdiutil" \
      SECURITY="$CASE_ROOT/bin/security" GIT="$CASE_ROOT/bin/git" JUST="$CASE_ROOT/bin/just" \
      DEVELOPER_ID_P12_BASE64='plant-p12-export' ARBITRARY_UNRECOGNIZED_NAME='plant-unknown' PLANTED_PASSWORD='fake-password-unique' PLANTED_TOKEN='fake-token-unique' PLANTED_KEY='fake-key-unique' HOMEBREW_GITHUB_API_TOKEN='plant-brew' OPENROUTER_API_KEY='plant-router' GITHUB_TOKEN='plant-github' GH_TOKEN='plant-gh' CLAUDE_CODE_MESSAGING_TOKEN='plant-claude' OTHER_TOKEN='plant-other-token' OTHER_API_KEY='plant-other-key' MY_SECRET_VALUE='plant-secret' MY_PASSWORD_VALUE='plant-password' \
      bash "$CASE_ROOT/scripts/release.sh" "$@" > "$CASE_ROOT/output" 2>&1 || status=$?
    if [[ $expected == success ]]; then
        [[ $status == 0 ]] || { cat "$CASE_ROOT/output"; fail "happy path exited $status"; }
    elif [[ $expected == feed-failure ]]; then
        [[ $status != 0 ]] || fail "accepted feed failure ${FAULT:-}"
        (cd "$CASE_ROOT/dist" && shasum -a 256 -c SHA256SUMS) || fail 'verified DMG checksum changed'
    else
        [[ $status != 0 ]] || fail "accepted failure ${FAULT:-}"
        [[ ! -e $CASE_ROOT/dist/SHA256SUMS && ! -e $CASE_ROOT/dist/Tesserae-0.1.0.dmg ]] || fail 'unverified artifacts escaped'
    fi
    [[ ! -e $CASE_ROOT/parser-was-sourced ]] || fail 'sourced config'
    absent "$CALLS" push
    absent "$CALLS" publish
    if [[ $expected != success ]]; then [[ ! -e $CASE_ROOT/dist/MANIFEST ]] || fail 'unverified manifest escaped'; fi
}
run_case() {
    local fault=$1 stop=$2
    [[ -z ${ONLY_CASE:-} || $ONLY_CASE == "$fault" ]] || return 0
    fixture "$fault"; FAULT=$fault
    case "$fault" in
      wrong-team) sed -i.bak 's/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/' "$CASE_ROOT/apple/Release.local.xcconfig" ;;
      missing-config) rm "$CASE_ROOT/apple/Release.local.xcconfig" ;;
      version) sed -i.bak 's/0.1.0/0.2.0/' "$CASE_ROOT/apple/Tesserae.xcodeproj/project.pbxproj" ;;
    esac
    if [[ $fault == unsigned-feed || $fault == tampered-feed ]]; then
        run_release feed-failure 0.1.0
    else
        run_release failure 0.1.0
    fi
    absent "$CALLS" "$stop"
    # Each scenario must reach its intended boundary before failing.
    case "$fault" in
      dirty) contains "$CASE_ROOT/output" 'clean tree' ;;
      branch) contains "$CASE_ROOT/output" 'requires main' ;;
      fetch) contains "$CALLS" $'git\tfetch' ;;
      stale) contains "$CASE_ROOT/output" 'match origin/main' ;;
      version) contains "$CASE_ROOT/output" 'MARKETING_VERSION' ;;
      tag) contains "$CASE_ROOT/output" 'tag already exists' ;;
      missing-config) contains "$CASE_ROOT/output" 'Missing apple/Release.local.xcconfig' ;;
      wrong-team) contains "$CASE_ROOT/output" 'team' ;;
      identity) contains "$CASE_ROOT/output" 'identity is unavailable' ;;
      profile) contains "$CALLS" $'xcrun\tnotarytool\thistory' ;;
      gate|ffi) contains "$CALLS" "$(printf 'just\t%s' "$fault")" ;;
      unsigned-feed|tampered-feed) contains "$CALLS" $'sign_update\t--verify\tdist/appcast.xml' ;;
      archive) contains "$CALLS" $'xcodebuild\tarchive' ;;
      export|missing-framework) contains "$CALLS" -exportArchive ;;
      verify|sandbox|runtime|team|unsigned-xpc) contains "$CALLS" $'codesign\t--verify' ;;
      dmg) contains "$CALLS" $'hdiutil\tcreate' ;;
      dmg-sign) contains "$CALLS" $'codesign\t--timestamp' ;;
      submit|invalid|rejected) contains "$CALLS" $'xcrun\tnotarytool\tsubmit' ;;
      staple|validate) contains "$CALLS" "$(printf 'xcrun\tstapler\t%s' "$fault")" ;;
      spctl) contains "$CALLS" $'spctl\t--assess\t--type\topen' ;;
      attach|execute|detach) contains "$CALLS" $'hdiutil\tattach' ;;
    esac
    case "$fault" in
      invalid|rejected) contains "$CALLS" $'xcrun\tnotarytool\tlog'; contains "$CASE_ROOT/output" 'https://example.invalid/notary-log'; contains "$CASE_ROOT/output" 'Notarization log: file://'; [[ -s $CASE_ROOT/dist/notary-0.1.0.json ]] || fail 'missing notary diagnostics' ;;
      execute|attach|detach) contains "$CALLS" $'hdiutil\tdetach' ;;
    esac
    echo "PASS $fault"
}
# Matching project versions ensure rejection comes from policy, not a mismatch.
if [[ -z ${ONLY_CASE:-} || $ONLY_CASE == forbidden-version ]]; then
    fixture forbidden-version; FAULT=
    printf 'MARKETING_VERSION = 0.6.66;\n' > "$CASE_ROOT/apple/Tesserae.xcodeproj/project.pbxproj"
    contains "$CASE_ROOT/apple/Tesserae.xcodeproj/project.pbxproj" '0.6.66'
    run_release failure 0.6.66
    contains "$CASE_ROOT/output" 'Version 0.6.66 is not allowed (contains 666); next allowed: 0.6.67'
    [[ ! -s $CALLS ]] || fail 'forbidden version reached release tools'
    status=0
    /usr/bin/env -i PATH="$CASE_ROOT/bin:$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" bash "$CASE_ROOT/scripts/build-release-input.sh" 0.6.66 > "$CASE_ROOT/output" 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'CI accepted forbidden version'
    contains "$CASE_ROOT/output" 'Version 0.6.66 is not allowed (contains 666); next allowed: 0.6.67'
    [[ ! -s $CALLS ]] || fail 'forbidden version reached CI build tools'
    echo 'PASS forbidden version stops local and CI builds'
fi
# release_refuses_dirty_tree_and_version_mismatch and all ordered failure boundaries.
for fault in dirty branch fetch stale version tag missing-config identity wrong-team profile; do run_case "$fault" $'just\tgate'; done
run_case gate $'just\tffi'
run_case ffi $'xcodebuild\tarchive'
run_case archive -exportArchive
run_case export $'codesign\t--verify'
for fault in test-hooks verify sandbox runtime nested-runtime nested-timestamp team unsigned-xpc missing-framework; do run_case "$fault" $'hdiutil\tcreate'; done
for fault in dmg dmg-sign; do run_case "$fault" $'xcrun\tnotarytool\tsubmit'; done
# release_never_publishes_an_unverified_dmg.
for fault in submit invalid rejected; do run_case "$fault" $'xcrun\tstapler\tstaple'; done
run_case staple $'xcrun\tstapler\tvalidate'
run_case validate $'spctl\t--assess'
run_case spctl $'hdiutil\tattach'
run_case attach $'spctl\t--assess\t--type\texecute'
run_case execute 'SHOULD_NEVER_APPEAR'
run_case detach 'SHOULD_NEVER_APPEAR'
run_case unsigned-feed 'SHOULD_NEVER_APPEAR'
run_case tampered-feed 'SHOULD_NEVER_APPEAR'
if [[ -z ${ONLY_CASE:-} || $ONLY_CASE == happy ]]; then
    fixture happy; FAULT=
    mkdir -p "$CASE_ROOT/dist"
    printf stale > "$CASE_ROOT/dist/Stale.dmg"
    run_release success 0.1.0
    [[ -s $CASE_ROOT/dist/Tesserae-0.1.0.dmg && -s $CASE_ROOT/dist/release-0.1.0.log ]] || fail 'missing artifacts'
    (cd "$CASE_ROOT/dist" && shasum -a 256 -c SHA256SUMS) || fail checksum
    contains "$CALLS" generate_appcast
    contains "$CALLS" LOCAL_KEYCHAIN_OK
    contains "$CALLS" ISOLATED_FEED_OK
    contains "$CALLS" sign_update
    contains "$CALLS" $'just\tgate'
    contains "$CALLS" $'just\tffi'
    contains "$CALLS" $'xcrun\tstapler\tvalidate'
    contains "$CALLS" $'spctl\t--assess\t--type\texecute'
    contains "$CALLS" $'hdiutil\tdetach'
    contains "$CALLS" 'Downloader.xpc'
    python3 - "$CALLS" <<'HELPER_SIGNING'
import pathlib, sys
calls = [line.split("\t") for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
signed = [(i, c) for i, c in enumerate(calls) if c[0] == "codesign" and "--sign" in c]
helpers = [(i, c) for i, c in signed if c[-1].endswith("/Contents/Helpers/applesauce")]
apps = [(i, c) for i, c in signed if c[-1].endswith("/Tesserae.app")]
assert len(helpers) == len(apps) == 1, signed
assert helpers[0][0] < apps[0][0], signed
for _, c in helpers + apps:
    assert "--timestamp" in c and c[c.index("--options") + 1] == "runtime", c
    assert c[c.index("--sign") + 1] == "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", c
HELPER_SIGNING
    # The successful trace also proves all required steps execute in order.
    markers=($'git\tstatus' $'git\tfetch' $'security\tfind-identity' $'xcrun\tnotarytool\thistory' $'just\tgate' $'just\tffi' $'xcodebuild\tarchive' $'xcodebuild\t-exportArchive' $'codesign\t--verify' $'hdiutil\tcreate' $'codesign\t--timestamp' $'xcrun\tnotarytool\tsubmit' $'xcrun\tstapler\tstaple' $'xcrun\tstapler\tvalidate' $'spctl\t--assess\t--type\topen' $'hdiutil\tattach' $'spctl\t--assess\t--type\texecute' $'hdiutil\tdetach')
    next=0
    while IFS= read -r call; do
        if [[ $call == "${markers[$next]}"* ]]; then
            next=$((next + 1))
            [[ $next -lt ${#markers[@]} ]] || break
        fi
    done < "$CALLS"
    [[ $next == ${#markers[@]} ]] || fail 'pipeline steps missing or out of order'
    contains "$CASE_ROOT/dist/release-0.1.0.log" '[REDACTED]'
    [[ -s $CALLS.env ]] || fail 'missing environment records'
    for secret in plant-p12-export plant-unknown plant-brew plant-router plant-github plant-gh plant-claude plant-other-token plant-other-key plant-secret plant-password fake-password-unique fake-token-unique fake-key-unique; do
        absent "$CALLS.env" "$secret"
        if grep -R -F "$secret" "$CASE_ROOT/dist" >/dev/null; then fail 'secret in dist'; fi
    done
    for secret in plant-p12-export fake-password-unique fake-token-unique fake-key-unique; do
        absent "$CASE_ROOT/dist/release-0.1.0.log" "$secret"
        absent "$CASE_ROOT/output" "$secret"
        absent "$CALLS" "$secret"
    done
    python3 -I - "$CASE_ROOT/dist" <<'PROOF'
import datetime, hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
proof = json.loads((root / 'MANIFEST').read_text())
assert proof['version'] == '0.1.0' and proof['commit'] == 'abc'
assert proof['dmg_sha256'] == hashlib.sha256((root / 'Tesserae-0.1.0.dmg').read_bytes()).hexdigest()
assert datetime.datetime.fromisoformat(proof['verified_at'].replace('Z', '+00:00')).tzinfo
PROOF
    echo 'PASS happy + log secrecy'
fi
if [[ -z ${ONLY_CASE:-} || $ONLY_CASE == publish ]]; then
    fixture publish; FAULT=
    status=0
    PATH="$CASE_ROOT/bin:$PATH" CALLS="$CALLS" bash "$CASE_ROOT/scripts/release.sh" 0.1.0 --publish > "$CASE_ROOT/output" 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'publish without tap accepted'
    contains "$CASE_ROOT/output" 'TESSERAE_TAP_DIR'
    contains "$CALLS" generate_appcast
    contains "$CALLS" sign_update
    absent "$CALLS" push
    status=0
    bash "$CASE_ROOT/scripts/release.sh" 0.1.0 --yes > "$CASE_ROOT/output" 2>&1 || status=$?
    [[ $status != 0 ]] || fail '--yes accepted'
    fixture ci-publish; touch "$CASE_ROOT/ci"; FAULT=
    status=0
    printf 'fake-ci-stdin\n' | PATH="$CASE_ROOT/bin:$PATH" CALLS="$CALLS" CI=true NOTARY_KEYCHAIN="$CASE_ROOT/ci.keychain-db" bash "$CASE_ROOT/scripts/release.sh" 0.1.0 --ci-publish > "$CASE_ROOT/output" 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'CI publish without tap accepted'
    contains "$CASE_ROOT/output" 'TESSERAE_TAP_DIR'
    contains "$CALLS" EARLY_STDIN_EOF_OK
    contains "$CALLS" CI_STDIN_OK
    contains "$CALLS" FEED_CI_STDIN_OK
    [[ -s $CALLS.env ]] || fail 'missing CI child environment records'
    absent "$CALLS.env" fake-ci-stdin
    if grep -R -F fake-ci-stdin "$CASE_ROOT/dist" >/dev/null; then fail 'CI key in dist'; fi
    absent "$CASE_ROOT/output" fake-ci-stdin
    python3 -I - "$CALLS" <<'ORDER'
from pathlib import Path
import sys
calls = Path(sys.argv[1]).read_text()
assert calls.index('EARLY_STDIN_EOF_OK') < calls.index('generate_appcast') < calls.index('CI_STDIN_OK')
ORDER
    contains "$CALLS" NOTARY_KEYCHAIN_OK
    contains "$CALLS" $'git\tfetch\torigin\trefs/tags/v0.1.0'
    contains "$CALLS" $'git\tshow-ref\t--verify\t--quiet\trefs/tags/v0.1.0'
    absent "$CALLS" push
    echo 'PASS publish integration + CI stdin + no --yes'
fi

if [[ -z ${ONLY_CASE:-} || $ONLY_CASE == prebuilt ]]; then
    fixture prebuilt; touch "$CASE_ROOT/ci"
    python3 -I - "$CASE_ROOT" <<'PREBUILT'
import hashlib, json, pathlib, plistlib, shutil, sys
root = pathlib.Path(sys.argv[1]); target = root / 'apple/build/release-input'
app = target / 'Tesserae.app/Contents'
for name in ('Frameworks/TesseraeKit.framework', 'Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc', 'Frameworks/Sparkle.framework/Versions/B/Updater.app', 'MacOS', 'Helpers'):
    (app / name).mkdir(parents=True, exist_ok=True)
for name in ('MacOS/Tesserae', 'Helpers/applesauce', 'Frameworks/TesseraeKit.framework/TesseraeKit'):
    (app / name).write_bytes(bytes.fromhex('cffaedfe') + b'fixture binary')
info = dict(CFBundleShortVersionString='0.1.0', CFBundleVersion='100', SUPublicEDKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
(target / 'build.json').write_text(json.dumps(dict(version='0.1.0', commit='abc')))
(target / 'sparkle-tools').mkdir()
pins = []
for name in ('generate_appcast', 'sign_update'):
    path = target / 'sparkle-tools' / name
    shutil.copyfile(root / 'bin/fake', path); path.chmod(0o755)
    pins.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + name)
(root / 'scripts/sparkle-tools.sha256').write_text('\n'.join(pins) + '\n')
PREBUILT
    status=0
    printf 'fake-ci-stdin\n' | PATH="$CASE_ROOT/bin:$PATH" CI=true NOTARY_KEYCHAIN="$CASE_ROOT/ci.keychain-db" bash "$CASE_ROOT/scripts/release.sh" 0.1.0 --ci-publish --prebuilt apple/build/release-input > "$CASE_ROOT/output" 2>&1 || status=$?
    [[ $status != 0 ]] || fail 'publish without tap accepted'
    contains "$CASE_ROOT/output" 'TESSERAE_TAP_DIR'
    [[ -s $CASE_ROOT/dist/MANIFEST ]] || fail 'prebuilt verification never completed'
    absent "$CALLS" $'just\t'
    absent "$CALLS" $'xcodebuild\t'
    contains "$CALLS" $'codesign\t--force'
    contains "$CALLS" FEED_CI_STDIN_OK
    echo 'PASS prebuilt artifact signing without build tools'
fi
