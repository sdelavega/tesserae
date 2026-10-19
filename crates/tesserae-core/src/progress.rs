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

//! Live progress and cancellation for a parallel walk.
//!
//! A caller hands [`walk_with_progress`] a [`Progress`], reads it from any
//! thread while the walk runs, and calls [`Progress::cancel`] to stop it. The
//! walk returns what it gathered either way: a cancelled walk is a partial
//! result flagged [`Incomplete::Cancelled`], not an error.
//!
//! # What the counters count
//!
//! The counters describe the nodes the walk has stored, in the same units as
//! the result: `dirs` and `files` are [`WalkStats::dirs`] and
//! [`WalkStats::files`], `errors` is [`WalkStats::errors`], and `bytes` is the
//! sum of every stored node's *allocated* size — the figure freeze rolls up
//! into the root's total, with a hardlink duplicate counted as the zero it is
//! stored as. Allocated rather than logical because allocated space is this
//! program's unit (see [`crate::freeze`]).
//!
//! Once the walk has returned they equal the result exactly, however it
//! ended: a worker's counts are published from the same locked slot its arena
//! lives in, and whatever it had not yet published is added when the slot is
//! taken. During the walk they lag by at most one directory batch per worker
//! plus one supervisor tick: each worker publishes once per
//! `getattrlistbulk` batch, not once per entry, and the supervisor copies the
//! walk's own counters into the caller's every [`TICK`].
//!
//! [`TICK`]: crate::pool::TICK
//!
//! # How a cancel reaches the workers
//!
//! The workers never read the caller's [`Progress`]: it is borrowed for the
//! length of the call, and a worker abandoned in a blocked syscall can outlive
//! the call (see [`WalkOptions::stall_timeout`]). The supervisor — the calling
//! thread, which would otherwise only be waiting — reads the flag every
//! [`TICK`] and raises the walk's shared halt as [`Incomplete::Cancelled`].
//! Every worker checks that halt before every node it stores and every time it
//! takes its arena's lock, which is at every directory and every batch
//! boundary.
//!
//! A [`Progress`] that is already cancelled when the walk starts cancels it at
//! the first tick.
//!
//! Use one [`Progress`] per walk. A cancel is never undone, so a cancelled
//! [`Progress`] cancels every walk handed it from then on; and the counters
//! are overwritten, not added to, so walks running at once would overwrite
//! each other's numbers.

use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

use crate::arena::Arena;
use crate::walk::{OpenAt, WalkOptions, WalkStats};

#[cfg(doc)]
use crate::walk::Incomplete;

/// Counters a walk publishes while it runs, and the flag that cancels it.
///
/// Counters are `Relaxed`: each is a number for a display, published nothing
/// else, and is exact once the walk has returned. The cancel flag is
/// `Release`/`Acquire`.
#[derive(Debug, Default)]
pub struct Progress {
    pub dirs: AtomicU64,
    pub files: AtomicU64,
    pub bytes: AtomicU64,
    pub errors: AtomicU64,
    cancelled: AtomicBool,
}

impl Progress {
    /// The four counters, each read once. They are read separately, so a
    /// snapshot taken mid-walk can pair one batch's `files` with the previous
    /// batch's `bytes`; one taken after the walk returns is exact.
    pub fn snapshot(&self) -> ProgressValues {
        ProgressValues {
            dirs: self.dirs.load(Ordering::Relaxed),
            files: self.files.load(Ordering::Relaxed),
            bytes: self.bytes.load(Ordering::Relaxed),
            errors: self.errors.load(Ordering::Relaxed),
        }
    }

    /// Ask the walk to stop. It returns what it has gathered, flagged
    /// [`Incomplete::Cancelled`], within a supervisor tick of the next
    /// directory or batch boundary — or at once, abandoning a worker that is
    /// blocked inside a syscall.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    /// Add `delta` to the counters. How a worker publishes a batch.
    pub(crate) fn add(&self, delta: ProgressValues) {
        for (counter, n) in [
            (&self.dirs, delta.dirs),
            (&self.files, delta.files),
            (&self.bytes, delta.bytes),
            (&self.errors, delta.errors),
        ] {
            // A batch rarely changes all four, and a skipped RMW is a cache
            // line every other worker is not fighting over.
            if n != 0 {
                counter.fetch_add(n, Ordering::Relaxed);
            }
        }
    }

    /// Overwrite the counters with `v`. How the supervisor copies the walk's
    /// own counters into the caller's.
    pub(crate) fn set(&self, v: ProgressValues) {
        self.dirs.store(v.dirs, Ordering::Relaxed);
        self.files.store(v.files, Ordering::Relaxed);
        self.bytes.store(v.bytes, Ordering::Relaxed);
        self.errors.store(v.errors, Ordering::Relaxed);
    }
}

/// The counters of a [`Progress`] at one moment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProgressValues {
    pub dirs: u64,
    pub files: u64,
    pub bytes: u64,
    pub errors: u64,
}

impl ProgressValues {
    pub(crate) const ZERO: ProgressValues = ProgressValues {
        dirs: 0,
        files: 0,
        bytes: 0,
        errors: 0,
    };

    /// `self - earlier`, field by field. Every counter only grows, so
    /// `earlier` is never larger.
    pub(crate) fn since(self, earlier: ProgressValues) -> ProgressValues {
        ProgressValues {
            dirs: self.dirs - earlier.dirs,
            files: self.files - earlier.files,
            bytes: self.bytes - earlier.bytes,
            errors: self.errors - earlier.errors,
        }
    }
}

/// [`crate::pool::walk`], publishing into `p` as it goes and stopping when
/// `p` is cancelled.
///
/// Returns as [`crate::pool::walk`] does. A cancel, a stall (see
/// [`WalkOptions::stall_timeout`]) or an arena running out of memory are all
/// `Ok` with [`WalkStats::incomplete`] set and the nodes gathered so far,
/// which freeze like any other result; `Err` still means only that nothing
/// could be scanned.
///
/// # Panics
///
/// Resumes a worker thread's panic on the calling thread.
pub fn walk_with_progress(opts: &WalkOptions, p: &Progress) -> io::Result<(Vec<Arena>, WalkStats)> {
    crate::pool::walk_with(opts, Arc::new(OpenAt), &[], p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arena::Arena;
    use crate::freeze::try_freeze;
    use crate::pool::{walk_with, ArenaLimit};
    use crate::walk::{DirOpener, Incomplete, OpenAt, WalkOptions, WalkStats};
    use std::collections::HashMap;
    use std::ffi::CStr;
    use std::os::fd::{OwnedFd, RawFd};
    use std::os::raw::c_int;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};
    use tesserae_testutil::Fixture;

    fn opts(root: &Path) -> WalkOptions {
        WalkOptions {
            root: root.to_path_buf(),
            ..WalkOptions::default()
        }
    }

    /// The pool index of the calling thread, from the name the pool gives
    /// its workers.
    fn worker_index() -> Option<usize> {
        std::thread::current()
            .name()?
            .strip_prefix("tesserae-walk-")?
            .parse()
            .ok()
    }

    /// `(nodes, allocated)` over every arena.
    fn totals(arenas: &[Arena]) -> (u64, u64) {
        arenas
            .iter()
            .flat_map(Arena::iter)
            .fold((0, 0), |(n, a), (_, node)| (n + 1, a + node.allocated))
    }

    /// The counters must describe exactly what the walk handed back: every
    /// node pushed, by kind, and the allocated bytes freeze rolls up.
    /// `(nodes, allocated)` is [`totals`] of the arenas, taken before freeze
    /// consumed them.
    fn assert_progress_is_the_result(
        p: &Progress,
        (nodes, allocated): (u64, u64),
        stats: &WalkStats,
    ) {
        assert_eq!(
            stats.dirs + stats.files,
            nodes,
            "stats disagree with arenas"
        );
        assert_eq!(
            p.snapshot(),
            ProgressValues {
                dirs: stats.dirs,
                files: stats.files,
                bytes: allocated,
                errors: stats.errors,
            },
            "the counters a caller reads afterwards are not the result it holds"
        );
    }

    /// Whether some node in an arena other than `stuck` names a parent that
    /// `stuck` holds. If it does, a result without `stuck`'s arena has a
    /// dangling parent and cannot freeze — which is what makes the freeze in
    /// each abandonment test evidence that the stuck arena was taken rather
    /// than dropped. Those tests freeze before their other assertions, so a
    /// dangling parent is the failure they report.
    fn depends_on(arenas: &[Arena], stuck: usize) -> bool {
        arenas.iter().enumerate().any(|(i, arena)| {
            i != stuck
                && arena
                    .iter()
                    .any(|(_, n)| usize::from(n.parent.thread()) == stuck)
        })
    }

    /// Sleeps `each` before every directory open, by either path.
    struct Delay {
        each: Duration,
        opens: AtomicU32,
    }

    impl Delay {
        fn new(each: Duration) -> Arc<Delay> {
            Arc::new(Delay {
                each,
                opens: AtomicU32::new(0),
            })
        }

        fn wait(&self) {
            self.opens.fetch_add(1, Ordering::Relaxed);
            std::thread::sleep(self.each);
        }
    }

    impl DirOpener for Delay {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            self.wait();
            OpenAt.open_dir_at(parent, name)
        }

        fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
            self.wait();
            crate::walk::open_beneath(root, rel)
        }
    }

    /// What [`BlockFirst`] recorded about the open it blocked.
    #[derive(Debug, Clone)]
    struct Blocked {
        /// The name or relative path the open was asked for.
        what: Vec<u8>,
        /// The pool index of the worker that blocked.
        worker: usize,
        began: Instant,
    }

    /// Blocks the first fd-relative open of a name starting with `slow` for
    /// `sleep`, standing in for an `openat` stuck on a hung volume. Every
    /// other open goes straight to the real one.
    ///
    /// Only `open_dir_at` blocks, never a reopen, and that is what pins
    /// *which* worker blocks: in [`stall_fixture`] the `slow` directories are
    /// the children of `p`, and only the worker that enumerated `p` holds
    /// `p`'s descriptor, so the first fd-relative open of one is that
    /// worker's descent into the child it kept. Every other `slowK` is
    /// published, and whoever takes one reopens it by path. So the stuck
    /// worker's arena holds `p`'s children, and every other worker's nodes
    /// hang off them.
    struct BlockFirst {
        sleep: Duration,
        fired: AtomicU32,
        blocked: Mutex<Option<Blocked>>,
        /// Set when the sleep ends: false at the walk's return means the walk
        /// returned while the open was still blocked.
        woke: AtomicBool,
    }

    impl BlockFirst {
        fn new(sleep: Duration) -> Arc<BlockFirst> {
            Arc::new(BlockFirst {
                sleep,
                fired: AtomicU32::new(0),
                blocked: Mutex::new(None),
                woke: AtomicBool::new(false),
            })
        }

        fn blocked(&self) -> Blocked {
            self.blocked
                .lock()
                .unwrap()
                .clone()
                .expect("the hook never blocked an open, so nothing was tested")
        }
    }

    impl DirOpener for BlockFirst {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes().starts_with(b"slow")
                && self.fired.fetch_add(1, Ordering::SeqCst) == 0
            {
                *self.blocked.lock().unwrap() = Some(Blocked {
                    what: name.to_bytes().to_vec(),
                    worker: worker_index().expect("opened on a pool worker"),
                    began: Instant::now(),
                });
                std::thread::sleep(self.sleep);
                self.woke.store(true, Ordering::SeqCst);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    /// `p/slow0..slow9`, each holding 20 files, under a root whose only
    /// subdirectory is `p`. See [`BlockFirst`] for why this shape.
    fn stall_fixture() -> Fixture {
        let fx = Fixture::new().unwrap();
        for k in 0..10 {
            for f in 0..20 {
                fx.file(&format!("p/slow{k}/f{f:02}.bin"), 1 + f * 64)
                    .unwrap();
            }
        }
        fx.file("top.bin", 4096).unwrap();
        fx
    }

    #[test]
    fn progress_counters_advance_during_a_walk() {
        let fx = Fixture::new().unwrap();
        for d in 0..20 {
            for f in 0..50 {
                fx.file(&format!("d{d:02}/f{f:02}.bin"), 1 + f * 100)
                    .unwrap();
            }
        }
        // Slowed and narrowed so the walk lasts long enough to be watched:
        // twenty opens of 20 ms over two workers is about 200 ms.
        let opener = Delay::new(Duration::from_millis(20));
        let mut o = opts(fx.path());
        o.workers = 2;
        let p = Progress::default();
        let done = AtomicBool::new(false);

        let (seen, outcome) = std::thread::scope(|scope| {
            let poller = scope.spawn(|| {
                let mut seen = Vec::new();
                while !done.load(Ordering::Acquire) {
                    seen.push(p.snapshot().files);
                    std::thread::sleep(Duration::from_millis(1));
                }
                seen
            });
            let outcome = walk_with(&o, Arc::clone(&opener), &[], &p);
            done.store(true, Ordering::Release);
            (poller.join().unwrap(), outcome)
        });
        let (arenas, stats) = outcome.unwrap();

        // Preconditions: the delay really slowed every directory, and the
        // poller really sampled while the walk ran.
        assert_eq!(opener.opens.load(Ordering::Relaxed), 20);
        assert!(seen.len() > 20, "only {} samples taken", seen.len());
        assert_eq!((stats.files, stats.incomplete), (1000, None));

        assert!(
            seen.iter().any(|&f| f > 0 && f < stats.files),
            "no sample saw a count strictly between 0 and {}: the counters did \
             not advance during the walk",
            stats.files
        );
        assert!(
            seen.windows(2).all(|w| w[0] <= w[1]),
            "a count went backwards"
        );
        assert_progress_is_the_result(&p, totals(&arenas), &stats);
    }

    #[test]
    fn cancellation_returns_a_partial_snapshot_flagged_cancelled() {
        const DIRS: u64 = 100;
        const FILES: u64 = 30;
        let fx = Fixture::new().unwrap();
        for d in 0..DIRS {
            for f in 0..FILES {
                fx.file(&format!("d{d:03}/f{f:02}.bin"), 512).unwrap();
            }
        }
        let whole = 1 + DIRS + DIRS * FILES;
        // A hundred opens of 10 ms over four workers: about 250 ms, so a
        // cancel at a hundred files lands early in the walk.
        let opener = Delay::new(Duration::from_millis(10));
        let mut o = opts(fx.path());
        o.workers = 4;
        let p = Progress::default();

        let (at_cancel, outcome) = std::thread::scope(|scope| {
            let canceller = scope.spawn(|| loop {
                let files = p.snapshot().files;
                if files >= 100 {
                    p.cancel();
                    return files;
                }
                std::thread::sleep(Duration::from_millis(1));
            });
            let outcome = walk_with(&o, Arc::clone(&opener), &[], &p);
            (canceller.join().unwrap(), outcome)
        });
        let (arenas, stats) = outcome.unwrap();
        let sums = totals(&arenas);
        let nodes = sums.0;

        // Preconditions: the cancel was issued, and issued mid-walk.
        assert!(p.is_cancelled());
        assert!(
            (100..DIRS * FILES).contains(&at_cancel),
            "cancelled at {at_cancel} files"
        );

        let snapshot = try_freeze(arenas, stats).expect("a cancelled walk still freezes");
        let stats = &snapshot.stats;
        assert_eq!(stats.incomplete, Some(Incomplete::Cancelled));
        assert!(
            nodes < whole,
            "{nodes} of {whole} nodes: the walk was not cut short"
        );
        assert!(
            stats.files >= at_cancel,
            "files counted before the cancel ({at_cancel}) are missing from \
             the result ({})",
            stats.files
        );
        assert_eq!(stats.stalled_at, None);
        assert_progress_is_the_result(&p, sums, stats);
    }

    #[test]
    fn arena_out_of_memory_surfaces_as_incomplete_not_a_panic() {
        const AFTER: u64 = 5;
        let fx = Fixture::new().unwrap();
        for i in 0..10 {
            for f in 0..20 {
                fx.file(&format!("t{i}/f{f:02}.bin"), 100).unwrap();
            }
        }
        let mut o = opts(fx.path());
        o.workers = 4;
        // Every worker's arena refuses its sixth node as if the allocator had
        // refused a chunk, so whichever worker walks first hits it.
        let limits = [ArenaLimit::OutOfMemoryAfter(AFTER); 4];
        let p = Progress::default();

        let injected_before = crate::walk::OOM_INJECTED.load(Ordering::Relaxed);
        let (arenas, stats) = walk_with(&o, Arc::new(OpenAt), &limits, &p)
            .expect("an arena failure is a partial result, not an Err");
        let injected = crate::walk::OOM_INJECTED.load(Ordering::Relaxed) - injected_before;

        assert!(injected >= 1, "no push was refused, so nothing was tested");
        let sums = totals(&arenas);
        let snapshot = try_freeze(arenas, stats).expect("an out-of-memory walk still freezes");
        let stats = &snapshot.stats;
        assert_eq!(stats.incomplete, Some(Incomplete::OutOfMemory));
        // Deterministic: the root's worker pushes the root and four of its
        // ten entries, is refused the sixth node before it publishes
        // anything, and the halt stops the walk with no other task created.
        assert_eq!(sums.0, AFTER, "the nodes stored before the refusal");
        assert_eq!(snapshot.nodes.len() as u64, AFTER);
        assert_progress_is_the_result(&p, sums, stats);
    }

    #[test]
    fn watchdog_reports_the_path_a_worker_stalled_on() {
        let fx = stall_fixture();
        let opener = BlockFirst::new(Duration::from_secs(3));
        let mut o = opts(fx.path());
        o.stall_timeout = Duration::from_secs(1);
        let p = Progress::default();

        let start = Instant::now();
        let (arenas, stats) = walk_with(&o, Arc::clone(&opener), &[], &p).unwrap();
        let elapsed = start.elapsed();

        // First, because it is the property: the walk came back while the
        // open was still blocked (3 s), rather than waiting for it.
        assert!(
            elapsed < Duration::from_millis(2500),
            "the walk took {elapsed:?}: it waited for the blocked open (3 s) \
             instead of abandoning it"
        );
        // Preconditions: one open really blocked, it was still blocked when
        // the walk returned, and the other workers really did walk the
        // directories the stuck one published, so their nodes hang off its.
        let blocked = opener.blocked();
        assert_eq!(opener.fired.load(Ordering::SeqCst), 1);
        assert!(
            !opener.woke.load(Ordering::SeqCst),
            "the blocked open finished before the walk returned"
        );
        let depends = depends_on(&arenas, blocked.worker);
        let sums = totals(&arenas);

        let snapshot = try_freeze(arenas, stats).expect("an abandoned walk still freezes");
        let stats = &snapshot.stats;
        assert!(
            depends,
            "no other worker's node hangs off the stuck worker's arena"
        );
        assert!(
            elapsed >= o.stall_timeout,
            "the watchdog fired after {elapsed:?}, before the timeout"
        );
        assert_eq!(stats.incomplete, Some(Incomplete::Stalled));
        let want = fx
            .path()
            .join("p")
            .join(std::str::from_utf8(&blocked.what).unwrap());
        assert_eq!(stats.stalled_at.as_deref(), Some(want.as_path()));
        assert_progress_is_the_result(&p, sums, stats);
    }

    #[test]
    fn watchdog_does_not_fire_on_a_merely_slow_but_progressing_walk() {
        const LEVELS: usize = 5;
        const DELAY: Duration = Duration::from_millis(300);
        // A chain, so the delays cannot overlap: 2000 files over five
        // levels, each level opened after a 300 ms wait, 1.5 s in all.
        let fx = Fixture::new().unwrap();
        let mut dir = PathBuf::new();
        for level in 0..LEVELS {
            dir.push(format!("d{level}"));
            for f in 0..2000 / LEVELS {
                fx.file(&format!("{}/f{f:03}.bin", dir.display()), 64)
                    .unwrap();
            }
        }
        let opener = Delay::new(DELAY);
        let mut o = opts(fx.path());
        o.stall_timeout = Duration::from_secs(1);
        let p = Progress::default();

        let start = Instant::now();
        let (arenas, stats) = walk_with(&o, Arc::clone(&opener), &[], &p).unwrap();
        let elapsed = start.elapsed();

        assert_eq!(stats.stalled_at, None, "the watchdog fired");
        assert_eq!(stats.incomplete, None);
        // Precondition: the walk outlasted the timeout, so a watchdog that
        // measured anything but a lack of progress would have fired.
        assert_eq!(opener.opens.load(Ordering::Relaxed), LEVELS as u32);
        assert!(
            elapsed > o.stall_timeout + Duration::from_millis(250),
            "the walk took {elapsed:?}, not long enough to test the watchdog"
        );
        assert_eq!(stats.files, 2000);
        assert_progress_is_the_result(&p, totals(&arenas), &stats);
    }

    #[test]
    fn cancel_returns_promptly_while_a_worker_is_blocked() {
        let fx = stall_fixture();
        let opener = BlockFirst::new(Duration::from_secs(5));
        // The default timeout, so only the cancel can end this walk early.
        let o = opts(fx.path());
        assert!(o.stall_timeout >= Duration::from_secs(5));
        let p = Progress::default();

        let start = Instant::now();
        let (cancelled_at, outcome) = std::thread::scope(|scope| {
            let canceller = scope.spawn(|| {
                std::thread::sleep(Duration::from_millis(200));
                p.cancel();
                Instant::now()
            });
            let outcome = walk_with(&o, Arc::clone(&opener), &[], &p);
            (canceller.join().unwrap(), outcome)
        });
        let elapsed = start.elapsed();
        let (arenas, stats) = outcome.unwrap();

        assert!(
            elapsed < Duration::from_secs(2),
            "cancel took {elapsed:?} to return with a worker blocked (5 s)"
        );
        // Preconditions: the open blocked before the cancel and was still
        // blocked when the walk returned.
        let blocked = opener.blocked();
        assert!(blocked.began < cancelled_at, "the cancel came first");
        assert!(!opener.woke.load(Ordering::SeqCst));
        let depends = depends_on(&arenas, blocked.worker);
        let sums = totals(&arenas);

        let snapshot =
            try_freeze(arenas, stats).expect("a walk cancelled around a blocked worker freezes");
        let stats = &snapshot.stats;
        assert!(
            depends,
            "no other worker's node hangs off the stuck worker's arena"
        );
        assert_eq!(stats.incomplete, Some(Incomplete::Cancelled));
        assert_eq!(stats.stalled_at, None);
        assert_progress_is_the_result(&p, sums, stats);
    }

    /// Blocks the first *reopen* of a directory three levels down whose
    /// parent was reopened by a worker other than the one that enumerated
    /// `p`. Such a directory's node is in one arena and its parent's in
    /// another, so naming it means climbing across arenas.
    struct BlockCrossArenaReopen {
        sleep: Duration,
        /// The worker that opened `p`, and so pushed every `slowK` node.
        p_owner: Mutex<Option<usize>>,
        /// Which worker reopened each `p/slowK`, and so pushed its children.
        reopened_by: Mutex<HashMap<Vec<u8>, usize>>,
        fired: AtomicU32,
        blocked: Mutex<Option<Vec<u8>>>,
        woke: AtomicBool,
    }

    impl DirOpener for BlockCrossArenaReopen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"p" {
                *self.p_owner.lock().unwrap() = worker_index();
            }
            OpenAt.open_dir_at(parent, name)
        }

        fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
            let rel_b = rel.to_bytes();
            let parts: Vec<&[u8]> = rel_b.split(|&b| b == b'/').collect();
            if parts.len() == 2 {
                if let Some(w) = worker_index() {
                    self.reopened_by.lock().unwrap().insert(rel_b.to_vec(), w);
                }
            } else if parts.len() == 3 {
                let parent = rel_b[..rel_b.len() - parts[2].len() - 1].to_vec();
                let parent_by = self.reopened_by.lock().unwrap().get(&parent).copied();
                let p_owner = *self.p_owner.lock().unwrap();
                if parent_by.is_some()
                    && parent_by != p_owner
                    && self.fired.fetch_add(1, Ordering::SeqCst) == 0
                {
                    *self.blocked.lock().unwrap() = Some(rel_b.to_vec());
                    std::thread::sleep(self.sleep);
                    self.woke.store(true, Ordering::SeqCst);
                }
            }
            crate::walk::open_beneath(root, rel)
        }
    }

    /// The watchdog names a directory that was blocked in a *reopen*, by its
    /// full path, when the climb from it to the root crosses arenas: the
    /// blocked directory's node, its parent's and the root's are held by
    /// different workers, so every one of them has to be read.
    #[test]
    fn watchdog_names_a_blocked_reopen_across_arenas() {
        let fx = Fixture::new().unwrap();
        for k in 0..10 {
            for sub in ["a", "b"] {
                for f in 0..5 {
                    fx.file(&format!("p/slow{k}/{sub}/f{f}.bin"), 64).unwrap();
                }
            }
        }
        let opener = Arc::new(BlockCrossArenaReopen {
            sleep: Duration::from_secs(3),
            p_owner: Mutex::new(None),
            reopened_by: Mutex::new(HashMap::new()),
            fired: AtomicU32::new(0),
            blocked: Mutex::new(None),
            woke: AtomicBool::new(false),
        });
        let mut o = opts(fx.path());
        o.workers = 8;
        o.stall_timeout = Duration::from_secs(1);
        let p = Progress::default();

        let start = Instant::now();
        let (arenas, stats) = walk_with(&o, Arc::clone(&opener), &[], &p).unwrap();
        let elapsed = start.elapsed();

        assert!(
            elapsed < Duration::from_millis(2500),
            "took {elapsed:?}: waited for the blocked reopen (3 s)"
        );
        let blocked = opener
            .blocked
            .lock()
            .unwrap()
            .clone()
            .expect("no reopen qualified, so nothing was tested");
        assert!(!opener.woke.load(Ordering::SeqCst));

        // Precondition: the blocked directory's node and its parent's really
        // are in different arenas.
        let leaf = blocked.rsplit(|&b| b == b'/').next().unwrap();
        let slow = blocked.split(|&b| b == b'/').nth(1).unwrap();
        let node_of = |name: &[u8], parent_name: &[u8]| {
            arenas
                .iter()
                .flat_map(|a| a.iter().map(move |(id, n)| (a, id, n)))
                .find(|(a, _, n)| {
                    a.name_bytes(n.name) == name
                        && arenas.iter().any(|pa| {
                            pa.get(n.parent)
                                .is_some_and(|pn| pa.name_bytes(pn.name) == parent_name)
                        })
                })
                .map(|(_, id, n)| (id, n.parent))
        };
        let found = node_of(leaf, slow);
        let sums = totals(&arenas);

        let snapshot = try_freeze(arenas, stats).expect("an abandoned walk still freezes");
        let stats = &snapshot.stats;
        let (id, parent) = found.expect("the blocked directory is in the result");
        assert_ne!(
            id.thread(),
            parent.thread(),
            "the climb never left one arena"
        );
        assert_eq!(stats.incomplete, Some(Incomplete::Stalled));
        let want = fx.path().join(std::str::from_utf8(&blocked).unwrap());
        assert_eq!(stats.stalled_at.as_deref(), Some(want.as_path()));
        assert_progress_is_the_result(&p, sums, stats);
    }
}
