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

# Sourced by the other scripts in this directory; not run on its own.
#
# Homebrew's cargo can precede ~/.cargo/bin on PATH, and it ignores
# rust-toolchain.toml, so a bare `cargo` would build with the wrong toolchain
# (and without the pinned components and targets). Putting rustup's own shims
# first makes every script, and so every `just` recipe, use the toolchain the
# repository pins. In CI ~/.cargo/bin is already first, so this changes
# nothing there.
export PATH="$HOME/.cargo/bin:$PATH"

# The inputs of apple/build/libtesserae.a, one "sha256  path" line each,
# paths relative to the repository root, sorted bytewise: every .rs file and
# Cargo.toml under crates/, the root Cargo.toml, Cargo.lock,
# rust-toolchain.toml and the C header the Swift side compiles against.
# scripts/build-ffi.sh writes this next to the library (libtesserae.inputs)
# and scripts/verify-ffi-fresh.sh recomputes it, so a deleted, renamed or
# edited input, or a toolchain change, shows as a difference; an mtime
# comparison alone sees none of the first two.
#
# Usage: ffi_inputs <repository root>. Fails (under pipefail) if any listed
# file cannot be read.
ffi_inputs() {
    (
        cd "$1"
        {
            find crates \( -name '*.rs' -o -name Cargo.toml \) -print0
            printf '%s\0' Cargo.toml Cargo.lock rust-toolchain.toml \
                crates/tesserae-ffi/include/tesserae.h
        } | LC_ALL=C sort -z -u | xargs -0 shasum -a 256
    )
}
