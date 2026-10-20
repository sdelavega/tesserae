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

# Fail the Xcode build when apple/build/libtesserae.a is missing or older than
# the Rust sources it is built from. Verify only: it never builds (spec §14).
#
# Usage: scripts/verify-ffi-fresh.sh
#
# Two checks: no input is newer than the library (mtimes, so even a touched
# file counts), and the input listing with content hashes that
# scripts/build-ffi.sh recorded in apple/build/libtesserae.inputs equals
# today's (see ffi_inputs in lib.sh), which catches deleted and renamed
# sources and toolchain or header changes.
#
# Run by TesseraeKit's "Verify Rust library is fresh" Run Script phase, which
# runs on every build (not "based on dependency analysis": editing a file deep
# in crates/ changes no mtime Xcode's own analysis would see). The phase
# declares this script, lib.sh, crates/, Cargo.toml, Cargo.lock,
# rust-toolchain.toml, the library and its input stamp as its inputs and a
# stamp in DERIVED_FILE_DIR as its output, which it writes; that is all it
# touches. Under ENABLE_USER_SCRIPT_SANDBOXING (as measured with Xcode 27.2:
# the generated profile denies reads under SRCROOT, apple/, and the build
# directories, except declared paths, and allows metadata reads) the script
# stats the library, reads the declared input stamp, and reads files outside
# SRCROOT, so it needs no more than it declares.
#
# Also safe to run by hand from anywhere.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

root="$(cd "$(dirname "$0")/.." && pwd)"
lib="$root/apple/build/libtesserae.a"
stamp="$root/apple/build/libtesserae.inputs"

if [ ! -f "$lib" ]; then
    echo "error: Rust library apple/build/libtesserae.a is missing: run \`just ffi\`" >&2
    exit 1
fi

# Each `find` is its own assignment, whose status is the command
# substitution's, so under `set -e` a find that cannot read (the script
# sandbox denying a path that was not declared as an input, say) fails the
# script instead of yielding an empty list that reads as "nothing is newer".
# (Xcode runs this with macOS's bash 3.2, which has no inherit_errexit.)
#
# Precondition: the walk sees the sources at all, so that an empty result
# below means "none is newer" and not "looked in the wrong place".
sources="$(find "$root/crates" -name '*.rs' -print)"
if [ -z "$sources" ]; then
    echo "error: found no Rust sources under $root/crates; cannot check the library" >&2
    exit 1
fi

# Every Rust source, manifest and the lockfile; there is no target/ under
# crates/ (the workspace's is at the root), so nothing needs pruning.
newer_crates="$(find "$root/crates" \( -name '*.rs' -o -name Cargo.toml \) -newer "$lib" -print)"
newer_root="$(find "$root/Cargo.toml" "$root/Cargo.lock" -newer "$lib" -print)"
newer="$(printf '%s\n%s\n' "$newer_crates" "$newer_root" | sed '/^$/d')"
if [ -n "$newer" ]; then
    echo "error: Rust library is older than its sources: run \`just ffi\`" >&2
    echo "newer than apple/build/libtesserae.a:" >&2
    printf '%s\n' "$newer" | sed "s|^$root/|  |" | head -n 10 >&2
    exit 1
fi

# Contents: the inputs recorded when the library was built must be exactly
# today's. This is what catches a deleted or renamed source, and a change to
# rust-toolchain.toml or the header, none of which leaves a newer mtime.
if [ ! -f "$stamp" ]; then
    echo "error: Rust library is older than its sources: run \`just ffi\`" >&2
    echo "apple/build/libtesserae.inputs is missing (the library predates the input stamp)" >&2
    exit 1
fi
recorded="$(cat "$stamp")"
current="$(ffi_inputs "$root")"
if [ "$recorded" != "$current" ]; then
    echo "error: Rust library is older than its sources: run \`just ffi\`" >&2
    echo "inputs changed since apple/build/libtesserae.a was built (< then, > now):" >&2
    diff <(printf '%s\n' "$recorded") <(printf '%s\n' "$current") | grep '^[<>]' | head -n 10 >&2 || true
    exit 1
fi

if [ -n "${DERIVED_FILE_DIR:-}" ]; then
    mkdir -p "$DERIVED_FILE_DIR"
    touch "$DERIVED_FILE_DIR/verify-ffi-fresh.stamp"
fi
