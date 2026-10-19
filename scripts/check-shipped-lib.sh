#!/usr/bin/env bash
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega. All rights reserved.
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

# Build the static library the app links and check that it carries no test hook.
#
# Usage: scripts/check-shipped-lib.sh
#
# The shipped library must be built with exactly
#     cargo build -p tesserae-ffi --release
# The tests enable tesserae-core's `test-hooks` feature through a
# dev-dependency, and cargo only keeps that out of a build that builds no test
# targets: --all-targets, --tests or `cargo test --release` would unify the
# hooks into the library. This script builds it the right way and checks.
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
# The second is run against a control first: the same search, on a release
# build of the same archive with the hooks forced on, must find the message, or
# an empty result would only mean the search is looking at the wrong thing. The
# control is the same profile and the same artifact kind as the checked one, so
# it sees the same LTO output. (`nm` cannot do this job: the release profile
# uses LTO, so the archive holds LLVM bitcode that Apple's `nm` is too old to
# read.)
#
# Output is captured and then searched with `grep -c`, never `cmd | grep -q`:
# under `pipefail` the early exit of `grep -q` can SIGPIPE the producer and turn
# a match into a failure, or hide one.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

cd "$(dirname "$0")/.."

marker='test-hooks: injected worker panic'

tree="$(cargo tree -p tesserae-ffi -e features --edges normal)"
if [ "$(printf '%s\n' "$tree" | grep -c 'feature "test-hooks"' || true)" != 0 ]; then
    echo "error: a normal build of tesserae-ffi enables tesserae-core's test-hooks feature" >&2
    exit 1
fi

# Control: the same release archive, built with the hooks on, carries the
# marker. The feature is forced on through the dev-dependency path by building
# the test target of tesserae-ffi in release, which unifies it into the
# library, in a separate target directory so the real build below is untouched.
control_dir="$(mktemp -d)"
trap 'rm -rf "$control_dir"' EXIT
CARGO_TARGET_DIR="$control_dir" cargo build -p tesserae-ffi --release --tests --locked
# With test targets in the build cargo leaves the archive under deps/ with a hash.
control="$(find "$control_dir/release/deps" -maxdepth 1 -name 'libtesserae_ffi-*.a' -print -quit)"
if [ -z "$control" ] || [ "$(grep -ac "$marker" "$control" || true)" = 0 ]; then
    echo "error: control failed: the hooks-on release archive has no '$marker', so this check searches nothing" >&2
    exit 1
fi

cargo build -p tesserae-ffi --release --locked
lib=target/release/libtesserae_ffi.a
if [ ! -f "$lib" ]; then
    echo "error: $lib was not produced" >&2
    exit 1
fi
if [ "$(grep -ac "$marker" "$lib" || true)" != 0 ]; then
    echo "error: $lib contains the test-hooks panic message" >&2
    exit 1
fi
echo "ok: $lib has no test hooks"
