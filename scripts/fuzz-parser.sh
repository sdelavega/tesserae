#!/usr/bin/env bash
# Fuzz `parse::entries` for a bounded time and fail unless the fuzzer really ran.
#
# Usage: scripts/fuzz-parser.sh SECONDS
#
# Needs a nightly toolchain and cargo-fuzz (`cargo install cargo-fuzz`).
# `+nightly` is explicit because rust-toolchain.toml pins stable.
#
# A fuzz run that loaded no seeds or executed nothing still exits 0, the same
# trap as a test filter that matches nothing, so the log is checked for both.
# This does not make fuzzing capable of finding wrong-but-plausible values;
# see the module comment in fuzz/fuzz_targets/parse_entries.rs.
set -euo pipefail

seconds="${1:?usage: $0 SECONDS}"
cd "$(dirname "$0")/.."

seeds="$(find fuzz/corpus/parse_entries -name 'golden_*.bin' | wc -l | tr -d ' ')"
if [ "$seeds" -lt 2 ]; then
    echo "error: expected the committed golden seeds in fuzz/corpus/parse_entries, found $seeds" >&2
    exit 1
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

cargo +nightly fuzz run parse_entries -- "-max_total_time=$seconds" 2>&1 | tee "$log"

# libFuzzer prints "INFO: seed corpus: files: N ..." before it starts.
loaded="$(sed -n 's/^INFO: seed corpus: files: \([0-9][0-9]*\).*/\1/p' "$log" | head -n 1)"
if [ -z "$loaded" ] || [ "$loaded" -lt "$seeds" ]; then
    echo "error: fuzzer loaded ${loaded:-no} seed files, expected at least $seeds" >&2
    exit 1
fi

# And "Done N runs in S second(s)" when the time budget is spent.
runs="$(sed -n 's/^Done \([0-9][0-9]*\) runs.*/\1/p' "$log" | tail -n 1)"
if [ -z "$runs" ] || [ "$runs" -lt 1 ]; then
    echo "error: the fuzzer reported no completed runs" >&2
    exit 1
fi
echo "fuzz: $loaded seed files loaded, $runs executions"
