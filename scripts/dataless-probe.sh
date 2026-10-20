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

# Print only. The coordinator reviews and executes the output after approval.
# Upload readiness uses brctl status, polled with explicit human confirmation:
# its diagnostic output is not a stable machine-readable completion API.
set -euo pipefail
if [[ $# != 1 || "$1" != /* ]]; then
    echo "usage: scripts/dataless-probe.sh <absolute-probe-dir>" >&2
    exit 1
fi
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
printf '#!/usr/bin/env bash\nset -euo pipefail\n\nprobe_dir=%q\n' "$1"
printf 'cd %q\n' "$repo_dir"
cat <<'COMMANDS'
# EXECUTE ONLY AFTER USER APPROVAL. No automatic cleanup is included.
# Refuse an existing path so known-size files cannot overwrite user data.
[[ ! -e "$probe_dir" && ! -L "$probe_dir" ]] || { echo 'Probe directory already exists; stop.' >&2; exit 1; }
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=stable
cargo build --release --locked -p tesserae-cli
mkdir -p "$probe_dir/nested/deeper"
dd if=/dev/zero of="$probe_dir/one-KiB.bin" bs=1024 count=1
dd if=/dev/zero of="$probe_dir/nested/one-MiB.bin" bs=1048576 count=1
dd if=/dev/zero of="$probe_dir/nested/deeper/ten-MiB.bin" bs=1048576 count=10
files=("$probe_dir/one-KiB.bin" "$probe_dir/nested/one-MiB.bin" "$probe_dir/nested/deeper/ten-MiB.bin")
# Poll status every five seconds. Inspect entries for these three paths:
# confirm all uploaded, no pending upload, before typing uploaded.
# Unknown/absent status is not confirmation: wait and inspect iCloud UI.
answer=
while [[ "$answer" != uploaded ]]; do
    /usr/bin/brctl status
    read -r -p 'All three probe files confirmed uploaded? Type uploaded or press Enter to poll: ' answer
    if [[ "$answer" != uploaded ]]; then sleep 5; fi
done
for file in "${files[@]}"; do /usr/bin/brctl evict "$file"; done
# Include directories: record whether any directory becomes SF_DATALESS too.
paths=("$probe_dir" "$probe_dir/nested" "$probe_dir/nested/deeper" "${files[@]}")
stat -f '%N %Xf %z %b' "${paths[@]}"
# Wait if eviction is asynchronous; require 0x40000000 on EACH file's flags.
read -r -p 'Confirm all three files are dataless (SF_DATALESS=0x40000000); press Enter to scan, Ctrl-C to stop: '
./target/release/tesserae-cli dataless-probe "$probe_dir" || echo "Default probe exited $? (partial; see errors above)"
stat -f '%N %Xf %z %b' "${paths[@]}"
/usr/bin/brctl status
# Restore a comparable cloud-only baseline if the default scan materialized anything.
for file in "${files[@]}"; do /usr/bin/brctl evict "$file"; done
stat -f '%N %Xf %z %b' "${paths[@]}"
read -r -p 'Confirm all three files are dataless again; press Enter for no-materialize, Ctrl-C to stop: '
./target/release/tesserae-cli dataless-probe "$probe_dir" --no-materialize || echo "No-materialize probe exited $? (partial; see errors above)"
stat -f '%N %Xf %z %b' "${paths[@]}"
/usr/bin/brctl status
# Record both probe outputs, wall times, errnos and before/after flags/blocks.
# Do not delete the folder until the user separately approves cleanup.
COMMANDS
