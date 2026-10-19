#!/usr/bin/env bash
# Time the CLI on a freshly generated volume of 500,000 empty files.
#
# Usage: scripts/bench-volume.sh [RUNS]      (default 5)
#
# Generates the volume (scripts/gen-bench-volume.sh), detaches it and attaches
# it again so the first scan starts with the volume's own caches dropped, then
# scans it RUNS times with the release CLI and reports each run and the median.
# The image is detached and deleted on exit, whether the run succeeded or not.
#
# "Cold" here is the best an unprivileged user can do: re-attaching drops the
# volume's caches, but not the host's cache of the image file, and `purge`
# needs root. Run 1 is therefore "first scan after a re-attach"; runs 2 to N
# are warm. Reported, never asserted.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

runs="${1:-5}"
case "$runs" in
'' | *[!0-9]* | 0)
    echo "error: RUNS must be a positive number, got '$runs'" >&2
    exit 1
    ;;
esac
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
mnt="$work/mnt"
trap 'hdiutil detach -force "$mnt" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

cargo build --release -p tesserae-cli
cli=target/release/tesserae-cli

scripts/gen-bench-volume.sh "$work" >/dev/null
hdiutil detach "$mnt" >/dev/null
hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$work/bench.sparseimage" >/dev/null

echo "machine: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores; macOS $(sw_vers -productVersion)"
times=()
for run in $(seq 1 "$runs"); do
    out="$("$cli" scan "$mnt")"
    secs="$(printf '%s\n' "$out" | awk '/^elapsed:/ { print $2 }')"
    files="$(printf '%s\n' "$out" | awk '/^files:/ { print $2 }')"
    echo "run $run: $secs s ($files files)"
    times+=("$secs")
done
median="$(printf '%s\n' "${times[@]}" | sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')"
echo "median of $runs: $median s"
