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

# Run the buffer parser's tests under Miri or AddressSanitizer, and fail if the
# run did not actually execute the tests it was meant to.
#
# Usage: scripts/parser-sanitizers.sh miri|asan
#
# Both modes need the pinned nightly toolchain named in scripts/nightly-toolchain
# (Miri also needs the `miri` and `rust-src` components). It is requested with
# an explicit `+toolchain` because rust-toolchain.toml pins stable. To use a
# locally installed floating nightly instead: TESSERAE_NIGHTLY=nightly.
#
# Why the count check exists: a test filter that matches nothing makes
# `cargo test` and `cargo miri test` exit 0 with "0 passed". Without the floor
# below, a renamed module would turn these jobs into a green tick over no
# verification at all. The floors are lower bounds; adding tests is fine,
# losing them is not.
#
# Every check here must fail closed. Note that `exit` inside `$(...)` leaves
# only the subshell, so values are assigned on their own line (where `set -e`
# sees the status) and validated as numbers before they are compared.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

mode="${1:-}"
cd "$(dirname "$0")/.."

# Forced colour puts escape codes inside "Running" and breaks the parsing below.
export CARGO_TERM_COLOR=never

nightly="${TESSERAE_NIGHTLY:-$(cat scripts/nightly-toolchain)}"

# Floors, as of Task 5: 15 tests in parse::tests::synthetic, 21 in parse::.
MIRI_MIN_TESTS=15
ASAN_MIN_TESTS=21

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Print the number of tests in the "test result: ok. N passed" line, or fail.
passed_count() {
    local n
    n="$(sed -n 's/^test result: ok\. \([0-9][0-9]*\) passed.*/\1/p' "$log" | head -n 1)"
    if [ -z "$n" ]; then
        echo "error: no 'test result: ok' line in the output; the run did not pass" >&2
        return 1
    fi
    echo "$n"
}

require_at_least() {
    local what="$1" got="$2" min="$3"
    case "$got" in
    '' | *[!0-9]*)
        echo "error: $what: test count '$got' is not a number" >&2
        exit 1
        ;;
    esac
    echo "$what: $got tests passed (floor $min)"
    if [ "$got" -lt "$min" ]; then
        echo "error: $what ran $got tests, expected at least $min." >&2
        echo "       The filter probably stopped matching; fix it rather than lowering the floor." >&2
        exit 1
    fi
}

case "$mode" in
miri)
    # `--lib` keeps Miri off the integration tests, which do file I/O it
    # cannot do. `parse::tests::synthetic` is the pure-bytes module; the
    # golden-fixture tests are cfg(not(miri)) as well.
    cargo "+$nightly" miri test -p tesserae-core --lib --locked parse::tests::synthetic 2>&1 | tee "$log"
    n="$(passed_count)"
    require_at_least "miri" "$n" "$MIRI_MIN_TESTS"
    ;;
asan)
    # An explicit --target keeps -Zsanitizer off build scripts and proc macros.
    host="$(rustc "+$nightly" -vV | sed -n 's/^host: //p')"
    RUSTFLAGS="-Zsanitizer=address" \
        cargo "+$nightly" test -p tesserae-core --lib --locked --target "$host" parse:: 2>&1 | tee "$log"
    n="$(passed_count)"
    require_at_least "asan" "$n" "$ASAN_MIN_TESTS"

    # Prove the sanitizer is really in the binary. A RUSTFLAGS that was
    # dropped or overridden would still print "test result: ok".
    bin="$(sed -n 's/^ *Running unittests .*(\(.*\))$/\1/p' "$log" | head -n 1)"
    if [ -z "$bin" ]; then
        echo "error: could not find the test binary path in cargo's output" >&2
        exit 1
    fi
    # Captured first: under pipefail, `otool | grep -q` can report failure when
    # grep exits early and otool takes SIGPIPE.
    linked="$(otool -L "$bin")"
    if ! grep -q 'asan' <<<"$linked"; then
        echo "error: the test binary is not linked against the AddressSanitizer runtime" >&2
        exit 1
    fi
    echo "asan: $bin links the AddressSanitizer runtime"
    ;;
*)
    echo "usage: $0 miri|asan" >&2
    exit 2
    ;;
esac
