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

# Sourced by the other scripts in this directory; not run on its own.
#
# Homebrew's cargo can precede ~/.cargo/bin on PATH, and it ignores
# rust-toolchain.toml, so a bare `cargo` would build with the wrong toolchain
# (and without the pinned components and targets). Putting rustup's own shims
# first makes every script, and so every `just` recipe, use the toolchain the
# repository pins. In CI ~/.cargo/bin is already first, so this changes
# nothing there.
export PATH="$HOME/.cargo/bin:$PATH"
