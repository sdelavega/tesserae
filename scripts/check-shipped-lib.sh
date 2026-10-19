#!/usr/bin/env bash
# Build the static library the app links and check that it carries no test hook.
#
# Usage: scripts/check-shipped-lib.sh
#
# tesserae-core has a `test-hooks` cargo feature that lets a test make a worker
# panic or stall. tesserae-ffi enables it in [dev-dependencies] only, so a
# normal build must not see it. Two independent checks, because each can fail
# on its own:
#
#   1. cargo's own feature resolution for a normal (non-dev) build of
#      tesserae-ffi does not include the feature;
#   2. the release archive does not contain the hook's panic message.
#
# The second is run against a control first: the same search must find the
# message in a core build that does enable the feature, or an empty result
# would only mean the search is looking in the wrong place. (`nm` cannot do this
# job: the release profile uses LTO, so the archive holds LLVM bitcode that
# Apple's `nm` is too old to read.)
set -euo pipefail

cd "$(dirname "$0")/.."

marker='test-hooks: injected worker panic'

if cargo tree -p tesserae-ffi -e features --edges normal | grep -q 'feature "test-hooks"'; then
    echo "error: a normal build of tesserae-ffi enables tesserae-core's test-hooks feature" >&2
    exit 1
fi

# Control: a build that does enable it carries the marker.
cargo build -p tesserae-core --features test-hooks
control="$(find target/debug -maxdepth 1 -name 'libtesserae_core.rlib')"
if ! grep -aq "$marker" "$control"; then
    echo "error: control failed: $control has no '$marker', so this check searches nothing" >&2
    exit 1
fi

cargo build -p tesserae-ffi --release
lib=target/release/libtesserae_ffi.a
if [ ! -f "$lib" ]; then
    echo "error: $lib was not produced" >&2
    exit 1
fi
if grep -aq "$marker" "$lib"; then
    echo "error: $lib contains the test-hooks panic message" >&2
    exit 1
fi
echo "ok: $lib has no test hooks"
