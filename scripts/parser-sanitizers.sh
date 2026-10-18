#!/usr/bin/env bash
# Run the buffer parser's tests under Miri or AddressSanitizer, and fail if the
# run did not actually execute the tests it was meant to.
#
# Usage: scripts/parser-sanitizers.sh miri|asan
#
# Both modes need a nightly toolchain (`rustup toolchain install nightly`;
# Miri also needs the `miri` and `rust-src` components). Nightly is requested
# with an explicit `+nightly` because rust-toolchain.toml pins stable.
#
# Why the count check exists: a test filter that matches nothing makes
# `cargo test` and `cargo miri test` exit 0 with "0 passed". Without the floor
# below, a renamed module would turn these jobs into a green tick over no
# verification at all. The floors are lower bounds; adding tests is fine,
# losing them is not.
set -euo pipefail

mode="${1:-}"
cd "$(dirname "$0")/.."

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
        exit 1
    fi
    echo "$n"
}

require_at_least() {
    local what="$1" got="$2" min="$3"
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
    cargo +nightly miri test -p tesserae-core --lib parse::tests::synthetic 2>&1 | tee "$log"
    require_at_least "miri" "$(passed_count)" "$MIRI_MIN_TESTS"
    ;;
asan)
    # An explicit --target keeps -Zsanitizer off build scripts and proc macros.
    host="$(rustc +nightly -vV | sed -n 's/^host: //p')"
    RUSTFLAGS="-Zsanitizer=address" \
        cargo +nightly test -p tesserae-core --lib --target "$host" parse:: 2>&1 | tee "$log"
    require_at_least "asan" "$(passed_count)" "$ASAN_MIN_TESTS"

    # Prove the sanitizer is really in the binary. A RUSTFLAGS that was
    # dropped or overridden would still print "test result: ok".
    bin="$(sed -n 's/^ *Running unittests .*(\(.*\))$/\1/p' "$log" | head -n 1)"
    if [ -z "$bin" ] || ! otool -L "$bin" | grep -q 'asan'; then
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
