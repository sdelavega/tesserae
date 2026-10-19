// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pub mod arena;
pub mod attrs;
pub mod boundary;
pub mod dedup;
pub mod freeze;
pub mod node;
pub mod parse;
pub mod pool;
pub mod progress;
pub mod walk;

#[cfg(test)]
mod tests {
    #[test]
    fn suite_does_not_run_as_root() {
        assert_ne!(
            unsafe { libc::geteuid() },
            0,
            "tests must not run as root: chmod 000 is bypassed and \
             permission tests pass for the wrong reason"
        );
    }
}
