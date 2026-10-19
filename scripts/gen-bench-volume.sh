#!/usr/bin/env bash
# Create and attach a disk image holding 500,000 empty files, for timing the
# CLI on a tree of realistic size and shape.
#
# Usage: scripts/gen-bench-volume.sh DIR
#
# Makes DIR/bench.sparseimage (an 8 GB APFS image that occupies only what is
# written to it) and attaches it at DIR/mnt, hidden from Finder. Prints the
# mountpoint as its last line. Detach with
#   hdiutil detach DIR/mnt
# (scripts/bench-volume.sh does that for you).
#
# Not run by the test suite: it writes about half a gigabyte and takes a
# minute. The files are empty on purpose. A zero-byte file on APFS needs no data
# blocks, so the volume stays small and the walk is dominated by what it is
# being timed on, enumerating directories and storing nodes, not by size.
#
# Layout: 20 top directories x 25 middle x 10 leaf, 100 files in each leaf.
# That is 5,000 leaf directories of 100 files each, 5,521 directories in all
# with the root, four levels deep: wide enough that directory enumeration
# dominates, deep enough that the walk has to descend.
set -euo pipefail

dir="${1:?usage: $0 DIR}"
cd "$(dirname "$0")/.."

mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
image="$dir/bench.sparseimage"
mnt="$dir/mnt"

if [ -e "$image" ] || [ -e "$mnt" ]; then
    echo "error: $dir already holds a bench volume; choose an empty directory" >&2
    exit 1
fi
mkdir "$mnt"

hdiutil create -size 8g -type SPARSE -fs APFS -volname TesseraeBench "$dir/bench" >/dev/null
hdiutil attach -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$image" >/dev/null

# From here on any exit but success must not leave the image attached. EXIT,
# not ERR: the validation failures below are plain `exit 1`s, which an ERR trap
# never sees.
trap 'hdiutil detach -force "$mnt" >/dev/null 2>&1 || true' EXIT

# Spotlight would otherwise start indexing 500,000 new files, and `mdutil -i
# off` needs root. This marker is the documented way to opt a volume out; it
# is the one file on the volume that is not one of the 500,000.
touch "$mnt/.metadata_never_index"

# Both lists come from awk and go through `tr` to NUL-separated arguments:
# macOS's bash is 3.2, whose brace expansion does not zero-pad ({00..19}), and
# the count check below is what would catch a layout that quietly came out
# different. `touch` takes thousands of paths per call, eight calls at a time.
paths() {
    awk -v m="$mnt" -v files="$1" 'BEGIN {
        for (t = 0; t < 20; t++) for (u = 0; u < 25; u++) for (l = 0; l < 10; l++) {
            leaf = sprintf("%s/t%02d/m%02d/l%d", m, t, u, l)
            if (!files) print leaf
            else for (f = 0; f < 100; f++) printf "%s/f%03d\n", leaf, f
        }
    }' | tr '\n' '\0'
}
paths 0 | xargs -0 mkdir -p
paths 1 | xargs -0 -n 5000 -P 8 touch

# Check what was made rather than trust it: the count, and that none of the
# files holds data.
count="$(find "$mnt" -type f -name 'f???' | wc -l | tr -d ' ')"
if [ "$count" != 500000 ]; then
    echo "error: made $count files, expected 500000" >&2
    exit 1
fi
nonempty="$(find "$mnt" -type f -name 'f???' -size +0 | head -n 1)"
if [ -n "$nonempty" ]; then
    echo "error: $nonempty is not empty" >&2
    exit 1
fi
trap - EXIT
echo "$count empty files in $(find "$mnt" -type d | wc -l | tr -d ' ') directories"
echo "$mnt"
