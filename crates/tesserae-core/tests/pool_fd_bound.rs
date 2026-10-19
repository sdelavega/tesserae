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

//! The parallel walk's open descriptors are bounded by
//! `workers * (max_depth + 1)`, not by the number of directories visited.
//!
//! The serial walker's equivalent is `tests/walk_fd_bound.rs`, which lowers
//! `RLIMIT_NOFILE` and lets the kernel do the measuring. That cannot be
//! repeated here: the whole point of this bound is that it holds for several
//! workers at once, and a limit low enough to prove it is low enough to break
//! every test running beside it. This test watches the real count instead, so
//! it is its own binary and holds a single `#[test]` — cargo runs test
//! binaries one after another, so nothing else in the process is opening
//! descriptors while the sampling runs.
//!
//! The measuring instrument is the gap between the depth cap and the tree's
//! width. A thousand directories live two levels down under a cap of four, so
//! a walker that held a descriptor per directory it had visited would show
//! hundreds open; the bound it is allowed is a few dozen.

use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use tesserae_core::pool::walk;
use tesserae_core::walk::WalkOptions;
use tesserae_testutil::Fixture;

/// Descriptors open in this process. The `read_dir` itself holds one, so this
/// over-reports by exactly one, consistently.
fn open_fds() -> usize {
    fs::read_dir("/dev/fd").expect("/dev/fd").count()
}

#[test]
fn parallel_open_descriptors_are_bounded_by_workers_times_depth() {
    const WIDE: usize = 1000;
    const MAX_DEPTH: u16 = 4;
    /// Descriptors the harness, the fixture and the sampler may add on top.
    const MARGIN: usize = 16;

    let fx = Fixture::new().unwrap();
    for i in 0..WIDE {
        fx.file(&format!("w{:01}/d{i:04}/f.bin", i % 4), 1).unwrap();
    }

    let opts = WalkOptions {
        root: fx.path().to_path_buf(),
        max_depth: MAX_DEPTH,
        ..WalkOptions::default()
    };
    let workers = opts.workers;
    let allowed = workers * (usize::from(MAX_DEPTH) + 1);

    let done = AtomicBool::new(false);
    let peak = AtomicUsize::new(0);
    let baseline = open_fds();

    let outcome = std::thread::scope(|scope| {
        scope.spawn(|| {
            // No sleep: the peak is brief and the walk is short.
            while !done.load(Ordering::Relaxed) {
                peak.fetch_max(open_fds(), Ordering::Relaxed);
            }
        });
        let outcome = walk(&opts);
        done.store(true, Ordering::Relaxed);
        outcome
    });

    let (arenas, stats) = outcome.unwrap();
    assert_eq!(
        arenas.len(),
        workers,
        "the descriptor limit was not raised, so the bound under test is the wrong one"
    );
    assert_eq!(stats.errors, 0);
    assert_eq!(
        stats.incomplete, None,
        "descriptors ran out: they did not stay bounded"
    );
    assert_eq!(stats.files, WIDE as u64);
    assert_eq!(stats.dirs, 1 + 4 + WIDE as u64, "root, w0..w3, and WIDE");

    let peak = peak.load(Ordering::Relaxed);
    assert!(
        peak > baseline,
        "sampled no descriptor the walk held (peak {peak}, baseline {baseline}): \
         the measurement, not the walker, is what failed"
    );
    assert!(
        peak - baseline <= allowed + MARGIN,
        "{} descriptors open at the peak above a baseline of {baseline}, over the \
         {allowed} that {workers} workers may each hold {} levels of, plus {MARGIN}: \
         descriptors scale with directories visited, not with depth",
        peak - baseline,
        usize::from(MAX_DEPTH) + 1
    );
    // Sanity on the instrument itself: the bound only means something because
    // it is far below what a descriptor per directory would need.
    assert!(allowed + MARGIN < WIDE, "the fixture is not wide enough");
    assert!(Path::new("/dev/fd").is_dir());
}
