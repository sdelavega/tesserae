#!/usr/bin/env bash
# Regenerate crates/tesserae-ffi/include/tesserae.h from the Rust source.
#
# Usage: scripts/gen-header.sh
#
# The header is committed and CI runs this script and then
# `git diff --exit-code`, so a change to the C ABI that does not carry its
# regenerated header fails the build. cbindgen's output varies between
# versions, so the version is pinned here and in CI, and the script refuses any
# other. To bump it: change CBINDGEN_VERSION here and in
# .github/workflows/ci.yml, regenerate, and commit them together.
#
# Install the pinned version with
#   cargo install cbindgen --version 0.29.4 --locked
set -euo pipefail

# Released 2026-06-09. Licence: MPL-2.0. It is a build tool, run and discarded:
# nothing of it is linked into Tesserae or shipped with it.
CBINDGEN_VERSION=0.29.4

cd "$(dirname "$0")/.."

if ! command -v cbindgen >/dev/null 2>&1; then
    echo "error: cbindgen not found; run: cargo install cbindgen --version $CBINDGEN_VERSION --locked" >&2
    exit 1
fi
found="$(cbindgen --version)"
if [ "$found" != "cbindgen $CBINDGEN_VERSION" ]; then
    echo "error: need cbindgen $CBINDGEN_VERSION, found '$found'" >&2
    echo "       run: cargo install cbindgen --version $CBINDGEN_VERSION --locked --force" >&2
    exit 1
fi

cbindgen \
    --config crates/tesserae-ffi/cbindgen.toml \
    --crate tesserae-ffi \
    --lockfile Cargo.lock \
    --output crates/tesserae-ffi/include/tesserae.h

echo "wrote crates/tesserae-ffi/include/tesserae.h"
