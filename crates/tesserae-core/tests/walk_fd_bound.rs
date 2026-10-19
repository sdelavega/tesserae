// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega
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

//! The walker's open-descriptor count is bounded by tree depth, not by the
//! number of directories visited.
//!
//! This is its own test binary because it lowers `RLIMIT_NOFILE` for the whole
//! process, which would corrupt any test running beside it. It holds a single
//! `#[test]` for the same reason.
//!
//! The limit is the measuring instrument. If the walker kept a descriptor per
//! directory it visited, a walk of a thousand directories could not fit under
//! a limit of a few dozen; and if it needs one per level, a tree deeper than
//! the limit must fail. Both are asserted.

use std::fs;

use tesserae_core::walk::{walk_serial, Incomplete, WalkOptions};
use tesserae_testutil::Fixture;

/// Highest descriptor number currently open in this process.
fn highest_open_fd() -> u64 {
    fs::read_dir("/dev/fd")
        .unwrap()
        .filter_map(|e| e.unwrap().file_name().to_str()?.parse::<u64>().ok())
        .max()
        .unwrap()
}

fn set_soft_nofile(soft: u64) -> libc::rlimit {
    let mut old = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `old` is a live, correctly sized `rlimit`.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut old) }, 0);
    let new = libc::rlimit {
        rlim_cur: soft,
        rlim_max: old.rlim_max,
    };
    // SAFETY: `new` is a live, correctly sized `rlimit`.
    assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &new) }, 0);
    old
}

#[test]
fn open_descriptors_scale_with_depth_not_with_directories_visited() {
    const WIDE: u64 = 1000;
    const DEPTH: usize = 30;

    let fx = Fixture::new().unwrap();
    for i in 0..WIDE {
        fx.file(&format!("wide/d{i:04}/f.bin"), 1).unwrap();
    }
    let chain = (0..DEPTH)
        .map(|i| format!("c{i}"))
        .collect::<Vec<_>>()
        .join("/");
    fx.file(&format!("deep/{chain}/bottom.bin"), 1).unwrap();

    let opts = |root: std::path::PathBuf| WalkOptions {
        root,
        ..WalkOptions::default()
    };

    // Room for about 200 more descriptors than are open now. A thousand
    // directories cannot fit if each holds one; the 32 a thirty-deep chain
    // needs fit easily. (The margin is generous on purpose: the kernel does
    // not honour small soft limits exactly, so this test must not depend on
    // the last few descriptors.)
    let original = set_soft_nofile(highest_open_fd() + 1 + 200);
    let wide_and_deep = walk_serial(&opts(fx.path().to_path_buf()));
    // Restore before asserting so a failure cannot leave the limit lowered.
    set_soft_nofile(original.rlim_cur);
    let (_, stats) = wide_and_deep.unwrap();

    assert_eq!(stats.errors, 0);
    assert_eq!(
        stats.incomplete, None,
        "no descriptor exhaustion: descriptors did not pile up"
    );
    assert_eq!(stats.files, WIDE + 1);
    // root, wide, WIDE directories, deep, DEPTH chain directories.
    assert_eq!(stats.dirs, 1 + 1 + WIDE + 1 + DEPTH as u64);

    // Now give it fewer descriptors than the chain is deep. The depth is what
    // costs descriptors, so this must run out: the walk still returns a
    // result, flagged as incomplete for lack of descriptors.
    let original = set_soft_nofile(highest_open_fd() + 1 + 10);
    let too_deep = walk_serial(&opts(fx.path().join("deep")));
    set_soft_nofile(original.rlim_cur);
    let (_, stats) = too_deep.unwrap();

    assert_eq!(
        stats.incomplete,
        Some(Incomplete::FdExhausted),
        "a {DEPTH}-deep chain fitted in 10 descriptors: depth is not what bounds them"
    );
    assert_eq!(
        stats.errors, 0,
        "exhaustion is not filed with the benign races"
    );
}
