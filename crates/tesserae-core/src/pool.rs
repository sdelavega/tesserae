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

//! The work-stealing pool: the same walk as [`crate::walk::walk_serial`], on
//! every core.
//!
//! [`walk_serial`] stays as the reference implementation. This module is
//! validated against it: the totals must agree, and on a tree with no
//! hardlinks the frozen snapshot must be byte-identical.
//!
//! [`walk_serial`]: crate::walk::walk_serial
//!
//! # Shape
//!
//! Each worker owns a LIFO [`Worker`] deque, an [`Arena`] tagged with its
//! index, its own [`WalkStats`] and its own read buffer. An [`Injector`] holds
//! the one task the walk starts with, the scan root. Every other task is a
//! directory some worker enumerated and chose not to descend immediately.
//!
//! **Depth-first within a worker, breadth-shared across workers.** A worker
//! descends with `openat` from the descriptor it already holds, so its open
//! descriptors are a chain down the tree — one per level, bounded by depth,
//! not by the number of directories it has seen. What it hands to the pool is
//! breadth: the siblings it is not about to enter. Those cannot carry a
//! descriptor, because the chain that reached them belongs to this thread, so
//! they carry an `Arc<Path>` and the worker that takes one reopens it.
//!
//! # Termination
//!
//! `crossbeam-deque` gives out the work and does the stealing. It does not say
//! when the walk is over, and "every deque looked empty just now" is not the
//! same fact: another worker may be about to publish a directory it has only
//! this moment enumerated. Getting that wrong gives either a hang or — worse,
//! because it is silent — a short scan.
//!
//! So the pool counts tasks rather than idle workers. [`Pool::pending`] is the
//! number of tasks that have been *created and not yet completed*:
//!
//! * it is incremented **before** the task is pushed, so a task is never
//!   visible to a stealer without having been counted ([`Hand::publish`] and
//!   the seeding of the root);
//! * it is decremented **after** the task is fully walked, which is after
//!   every subdirectory that task published has itself been counted.
//!
//! The invariant is therefore: *if any task exists anywhere — queued,
//! in-flight, or in the middle of being published — `pending` is at least
//! one.* A worker exits only when it has looked everywhere and found nothing
//! **and** reads `pending == 0`. By the invariant, zero means no task exists;
//! and since a new task can only be created while walking an existing one, no
//! task can ever exist again. Exiting is safe.
//!
//! Liveness is the other half: `pending > 0` means some task exists, and every
//! task is either in-flight (so the worker holding it will decrement) or
//! queued (so it is `pop`-able by its owner and `steal`-able by anyone). A
//! worker that finds nothing yet sees `pending > 0` is looking at work that
//! belongs to a busy worker's local deque, and that worker will reach it. No
//! worker ever blocks, so there is nothing to deadlock; an idle worker yields
//! and looks again.
//!
//! Relaxed ordering is enough for the counter itself: a single atomic has a
//! total modification order, so reading zero means every increment so far has
//! been matched, and the argument above rules out a later one. The release on
//! the decrement and the acquire on the read are what publish each worker's
//! arena writes to whoever reads the counter afterwards.
//!
//! A panic is the one way out of a task that does not decrement, so
//! [`HaltOnPanic`] raises the halt on an unwind. Otherwise the remaining
//! workers would spin on a task that will never complete, and the join would
//! hang instead of reporting the panic.
//!
//! # Descriptors
//!
//! `RLIMIT_NOFILE` is raised to [`NOFILE_TARGET`] at entry. If it cannot be,
//! the worker count is reduced to fit the limit that is in force rather than
//! failing the scan; see [`worker_count`].

use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use crossbeam_deque::{Injector, Stealer, Worker};

use crate::arena::{Arena, ScanId};
use crate::dedup::InodeSet;
use crate::walk::{
    check_options, open_root, root_volume_of, Halt, Incomplete, NodeBudget, OpenAt, Share,
    WalkOptions, WalkStats, Walker, WalkerCtx,
};
use std::os::fd::OwnedFd;

/// Soft `RLIMIT_NOFILE` the walk asks for.
const NOFILE_TARGET: u64 = 4096;
/// Descriptors left to everything that is not the walk when the limit has to
/// be divided up.
const NOFILE_RESERVE: u64 = 32;
/// Most workers a caller can ask for. The default is `available_parallelism()`
/// clamped to 4..=16 in [`WalkOptions::default`]; this is only a guard on an
/// absurd explicit value.
const MAX_WORKERS: usize = 64;
/// Stealable tasks a worker tries to keep queued. Below this it publishes the
/// siblings it is not descending; at or above it keeps them and descends them
/// with `openat`, which is both cheaper and bounds how many `Arc<Path>`s are
/// alive at once.
const PUBLISH_TARGET: usize = 32;
/// Failed searches before an idle worker stops spinning and sleeps. Short,
/// because the usual reason to find nothing is that another worker is a few
/// microseconds from publishing.
const SPINS_BEFORE_SLEEP: u32 = 64;
/// Shards in the walk's hardlink set, per worker.
const INODE_SHARDS_PER_WORKER: usize = 8;

/// One directory to walk.
enum Task {
    /// The scan root. Its node has not been pushed yet, and its descriptor is
    /// already open because the volume had to be read off it.
    Root(OwnedFd),
    /// A directory already recorded as `node` in some worker's arena, at
    /// absolute depth `depth`.
    Dir {
        path: Arc<Path>,
        node: ScanId,
        depth: u16,
    },
}

/// What the workers share: the queues, the task count that decides when the
/// walk is over, the halt, and the flags that belong to another arena.
struct Pool<'a> {
    /// Tasks created and not yet completed. See the module's termination note:
    /// this, not an idle count, is what says the walk is finished.
    pending: AtomicUsize,
    injector: Injector<Task>,
    stealers: Vec<Stealer<Task>>,
    halt: &'a Halt,
    /// `(node, flags)` for nodes a worker learned something about but does not
    /// own. Applied once the workers have joined; taken only on a permission
    /// denial on a stolen directory, so essentially never.
    foreign: Mutex<Vec<(ScanId, u16)>>,
}

impl Pool<'_> {
    /// A task to walk, or `None` if nothing could be found this time round.
    ///
    /// Own deque first (LIFO, so the most recently published sibling, whose
    /// parent is still warm), then the injector, then everyone else.
    fn find(&self, local: &Worker<Task>) -> Option<Task> {
        local.pop().or_else(|| {
            std::iter::repeat_with(|| {
                self.injector
                    .steal_batch_and_pop(local)
                    .or_else(|| self.stealers.iter().map(Stealer::steal).collect())
            })
            // A retry means a race, not an empty pool, so look again.
            .find(|s| !s.is_retry())
            .and_then(|s| s.success())
        })
    }
}

/// One worker's end of the pool: what [`Walker`] publishes through.
struct Hand<'a> {
    pool: &'a Pool<'a>,
    local: &'a Worker<Task>,
}

impl Share for Hand<'_> {
    fn wants_work(&self) -> bool {
        self.local.len() < PUBLISH_TARGET
    }

    fn publish(&self, path: Arc<Path>, node: ScanId, depth: u16) {
        // Counted before it is pushed. The other order would let a worker see
        // every deque empty and `pending == 0` while this directory was
        // unwalked, and the scan would come back short.
        self.pool.pending.fetch_add(1, Ordering::Relaxed);
        self.local.push(Task::Dir { path, node, depth });
    }

    fn flag_foreign(&self, node: ScanId, flags: u16) {
        let mut queue = self.pool.foreign.lock().unwrap_or_else(|e| e.into_inner());
        // Dropped if the one slot cannot be reserved. That costs a directory
        // its "locked" rendering and nothing else: the walk could not read it
        // either way, so no bytes go missing and there is nothing to report.
        if queue.try_reserve(1).is_ok() {
            queue.push((node, flags));
        }
    }
}

/// Stops every other worker if this one unwinds. Without it a panic would
/// leave `pending` above zero for a task nothing will ever complete, and the
/// other workers would spin until the join deadlocked — hiding the panic
/// behind a hang.
struct HaltOnPanic<'a>(&'a Halt);

impl Drop for HaltOnPanic<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() {
            // Which reason does not matter: the panic is resumed on the
            // calling thread and these stats never reach a caller. Raising
            // anything at all is what lets the other workers stop.
            self.0.raise(Incomplete::Cancelled);
        }
    }
}

/// Walk `opts.root` with `opts.workers` threads.
///
/// Returns one [`Arena`] per worker, ready for [`crate::freeze::freeze`], and
/// the workers' [`WalkStats`] merged. The result is the same walk
/// [`walk_serial`] performs: the same nodes, the same totals, the same
/// policies. What is not the same is *which* link of a hardlinked file carries
/// its bytes, because "first" is a race; only the total is invariant. See
/// [`crate::dedup`].
///
/// `Err` means nothing could be scanned: bad options, or the root itself could
/// not be opened. Everything after that is absorbed into the stats, as in a
/// serial walk, and a walk cut short returns `Ok` with
/// [`WalkStats::incomplete`] set.
///
/// [`walk_serial`]: crate::walk::walk_serial
///
/// # Panics
///
/// Resumes a worker thread's panic on the calling thread.
pub fn walk(opts: &WalkOptions) -> io::Result<(Vec<Arena>, WalkStats)> {
    walk_with(opts, &OpenAt, &[])
}

/// [`walk`] with the caller's opener, and a per-worker arena ceiling.
///
/// `arena_caps` is empty in production: the walk's limit is the shared
/// [`NodeBudget`], and a per-arena ceiling would multiply by the worker count.
/// `arena_caps[i]` caps worker `i`'s arena and anything past the end is
/// uncapped, which is how a test makes *one* worker's push fail while every
/// other worker and the shared budget still have room — the only way to reach
/// the "one worker failed" path on purpose.
pub(crate) fn walk_with<O: crate::walk::DirOpener>(
    opts: &WalkOptions,
    opener: &O,
    arena_caps: &[u64],
) -> io::Result<(Vec<Arena>, WalkStats)> {
    check_options(opts)?;
    let workers = worker_count(opts.workers, opts.max_depth, raise_nofile(NOFILE_TARGET));

    // Before anything is spawned: if the root cannot be opened or its volume
    // cannot be read, there is no walk to parallelise.
    let root_fd = open_root(opts)?;
    let root_volume = root_volume_of(opts, &root_fd)?;

    let inodes = InodeSet::new(workers * INODE_SHARDS_PER_WORKER);
    let budget = NodeBudget::new(opts.node_budget);
    let halt = Halt::new();
    let ctx = WalkerCtx {
        opener,
        inodes: &inodes,
        budget: &budget,
        halt: &halt,
        root_volume,
    };

    let deques: Vec<Worker<Task>> = (0..workers).map(|_| Worker::new_lifo()).collect();
    let pool = Pool {
        // The root task, counted before it is pushed.
        pending: AtomicUsize::new(1),
        injector: Injector::new(),
        stealers: deques.iter().map(Worker::stealer).collect(),
        halt: &halt,
        foreign: Mutex::new(Vec::new()),
    };
    pool.injector.push(Task::Root(root_fd));

    let results = std::thread::scope(|scope| {
        let threads: Vec<_> = deques
            .into_iter()
            .enumerate()
            .map(|(i, local)| {
                let (pool, ctx) = (&pool, &ctx);
                scope.spawn(move || {
                    // `i < workers <= MAX_WORKERS`, well inside a tag.
                    let cap = arena_caps.get(i).copied().unwrap_or(u64::MAX);
                    run_worker(pool, local, ctx, opts, i as u16, cap)
                })
            })
            .collect();
        threads
            .into_iter()
            .map(|t| t.join().unwrap_or_else(|e| std::panic::resume_unwind(e)))
            .collect::<Vec<_>>()
    });

    let mut arenas: Vec<Arena> = Vec::new();
    arenas
        .try_reserve_exact(results.len())
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    let mut stats = WalkStats::default();
    for result in results {
        let (arena, worker_stats) = result?;
        merge(&mut stats, worker_stats)?;
        arenas.push(arena);
    }
    apply_foreign(
        &mut arenas,
        pool.foreign.into_inner().unwrap_or_else(|e| e.into_inner()),
    );
    Ok((arenas, stats))
}

/// One worker: take tasks until the walk is over, then hand back its arena
/// and what it saw.
fn run_worker<O: crate::walk::DirOpener>(
    pool: &Pool<'_>,
    local: Worker<Task>,
    ctx: &WalkerCtx<'_, O>,
    opts: &WalkOptions,
    thread: u16,
    arena_cap: u64,
) -> io::Result<(Arena, WalkStats)> {
    let _halt_on_panic = HaltOnPanic(pool.halt);
    let hand = Hand {
        pool,
        local: &local,
    };
    let mut walker = match Walker::with_arena_cap(ctx, Some(&hand), opts, thread, arena_cap) {
        Ok(walker) => walker,
        Err(e) => {
            // This worker cannot walk at all, so the caller gets an `Err`
            // and no partial result. Stop the others rather than let them
            // finish a scan that is going to be thrown away; the reason is
            // only a signal, since `e` is what the caller sees.
            pool.halt.raise(Incomplete::OutOfMemory);
            return Err(e);
        }
    };
    let mut idle = 0u32;
    loop {
        if pool.halt.reason().is_some() {
            break;
        }
        match pool.find(&local) {
            Some(task) => {
                idle = 0;
                let outcome = match task {
                    Task::Root(fd) => walker.run_root(&opts.root, fd),
                    Task::Dir { path, node, depth } => walker.run_dir(path, node, depth),
                };
                // After the task is finished, and so after every directory it
                // published was counted. This is the half of the protocol that
                // makes `pending == 0` mean what it says.
                pool.pending.fetch_sub(1, Ordering::Release);
                if outcome.is_err() {
                    // `run_root` / `run_dir` have already raised the halt.
                    break;
                }
            }
            None => {
                if pool.pending.load(Ordering::Acquire) == 0 {
                    break;
                }
                idle = idle.saturating_add(1);
                if idle < SPINS_BEFORE_SLEEP {
                    std::thread::yield_now();
                } else {
                    std::thread::sleep(std::time::Duration::from_micros(50));
                }
            }
        }
    }
    Ok(walker.finish())
}

/// Fold one worker's stats into the running total.
///
/// The destructuring is the point: a field added to [`WalkStats`] later stops
/// this compiling instead of being silently dropped from every parallel scan.
fn merge(into: &mut WalkStats, from: WalkStats) -> io::Result<()> {
    let WalkStats {
        dirs,
        files,
        errors,
        unreadable,
        skipped_mounts,
        depth_capped,
        lost_entries,
        hardlink_dups,
        stalled_at,
        incomplete,
    } = from;
    into.dirs += dirs;
    into.files += files;
    into.errors += errors;
    into.depth_capped += depth_capped;
    into.lost_entries += lost_entries;
    into.hardlink_dups += hardlink_dups;
    concat(&mut into.unreadable, unreadable)?;
    concat(&mut into.skipped_mounts, skipped_mounts)?;
    into.stalled_at = into.stalled_at.take().or(stalled_at);
    // A terminal reason names what stopped the walk and outranks a reason the
    // walk noticed and carried on past, exactly as in a serial walk. Equal
    // rank keeps what is already there, and workers are merged in index order,
    // so the choice does not depend on which thread happened to finish first.
    if into
        .incomplete
        .is_none_or(|have| incomplete.is_some_and(|new| new.rank() > have.rank()))
    {
        into.incomplete = incomplete;
    }
    Ok(())
}

fn concat<T>(into: &mut Vec<T>, from: Vec<T>) -> io::Result<()> {
    into.try_reserve(from.len())
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    into.extend(from);
    Ok(())
}

/// Set flags a worker learned about nodes it did not own. Arena `i` carries
/// thread tag `i`, and `Arena::get_mut` rejects an id from another arena, so a
/// mismatch cannot write to the wrong node.
fn apply_foreign(arenas: &mut [Arena], flags: Vec<(ScanId, u16)>) {
    for (id, bits) in flags {
        if let Some(node) = arenas
            .get_mut(usize::from(id.thread()))
            .and_then(|arena| arena.get_mut(id))
        {
            node.flags |= bits;
        }
    }
}

/// Raise the soft `RLIMIT_NOFILE` towards `want` and report the soft limit in
/// force afterwards.
///
/// Never fails the scan. A limit that cannot be raised — a low hard limit, or
/// a kernel `maxfilesperproc` below the request — bounds the worker count
/// instead; see [`worker_count`].
fn raise_nofile(want: u64) -> u64 {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `limit` is a live, correctly sized `rlimit`.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        // Nothing is known about the limit, so assume the worst and let
        // `worker_count` fall back to one worker.
        return 0;
    }
    if limit.rlim_cur >= want {
        return limit.rlim_cur;
    }
    let target = if limit.rlim_max == libc::RLIM_INFINITY {
        want
    } else {
        want.min(limit.rlim_max)
    };
    let raised = libc::rlimit {
        rlim_cur: target,
        rlim_max: limit.rlim_max,
    };
    // SAFETY: `raised` is a live, correctly sized `rlimit`.
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } == 0 {
        target
    } else {
        limit.rlim_cur
    }
}

/// How many workers to run under the descriptor limit `soft_nofile`.
///
/// A worker holds at most `max_depth + 1` descriptors — one per level of its
/// local chain — so the walk's worst case is `workers * (max_depth + 1)`.
///
/// With the target limit in force the requested count stands even though that
/// product can exceed it (16 by 513 is about 8200): `max_depth` is a cap of
/// 512, real trees are a few dozen deep, and throttling every scan for a depth
/// that does not occur would cost far more than it saves.
/// [`Incomplete::FdExhausted`] is the safety net for the tree that really is
/// that deep — it reports a short result rather than producing a wrong one.
///
/// Below the target the limit is real and possibly tiny, so the count is cut
/// to what fits. One worker is always allowed: a scan with none is no scan.
fn worker_count(requested: usize, max_depth: u16, soft_nofile: u64) -> usize {
    let requested = requested.clamp(1, MAX_WORKERS);
    if soft_nofile >= NOFILE_TARGET {
        return requested;
    }
    let per_worker = u64::from(max_depth) + 1;
    let fits = (soft_nofile.saturating_sub(NOFILE_RESERVE) / per_worker).max(1);
    requested.min(usize::try_from(fits).unwrap_or(usize::MAX))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::freeze::freeze;
    use crate::node::Snapshot;
    use crate::walk::walk_serial;
    use std::ffi::CStr;
    use std::os::fd::RawFd;
    use std::os::raw::c_int;
    use tesserae_testutil::Fixture;

    fn opts(root: &Path) -> WalkOptions {
        WalkOptions {
            root: root.to_path_buf(),
            ..WalkOptions::default()
        }
    }

    /// 3000 files across 50 directories, three levels below the root.
    ///
    /// Wide and deep enough that one worker cannot plausibly hold all of it:
    /// the root alone yields ten subdirectories, nine of which are published
    /// the moment it has been enumerated. `walk_shares_the_tree_between_workers`
    /// asserts that sharing really happened, so the comparisons below are not
    /// quietly testing a serial walk twice.
    fn wide_fixture() -> Fixture {
        let fx = Fixture::new().unwrap();
        for i in 0..10 {
            for j in 0..5 {
                for k in 0..60 {
                    fx.file(&format!("t{i}/u{j}/f{k:02}.bin"), 1 + (k % 3) * 64)
                        .unwrap();
                }
            }
        }
        fx
    }

    /// `(nodes, logical, allocated)` summed over every arena.
    fn totals(arenas: &[Arena]) -> (u64, u64, u64) {
        arenas.iter().fold((0, 0, 0), |acc, arena| {
            arena.iter().fold(acc, |(n, l, a), (_, node)| {
                (n + 1, l + node.logical, a + node.allocated)
            })
        })
    }

    fn snapshot(arenas: Vec<Arena>, stats: WalkStats) -> Snapshot {
        freeze(arenas, stats)
    }

    /// The parity test for a tree *with* hardlinks, where only totals are
    /// invariant: dedup gives the bytes to whichever link is reached first,
    /// and in a parallel walk "first" is a race. The sum is the same however
    /// the race goes; which node holds it is not, so this asserts counts and
    /// sums and nothing per-node.
    #[test]
    fn parallel_walk_matches_serial_walk_totals() {
        let fx = wide_fixture();
        // Four inodes linked across every top-level directory, so that
        // several workers really do race for the same key: the dedup order
        // is what makes a per-node comparison invalid here, and a fixture
        // with one or two links would not exercise the race at all.
        let mut links = 0;
        for target in 0..4 {
            for i in 0..10 {
                for j in 0..3 {
                    fx.hardlink(
                        &format!("t{target}/u0/f00.bin"),
                        &format!("t{i}/u{j}/link{target}.bin"),
                    )
                    .unwrap();
                    links += 1;
                }
            }
        }

        let (serial, s) = walk_serial(&opts(fx.path())).unwrap();
        let (parallel, p) = walk(&opts(fx.path())).unwrap();

        // Each inode has links + 1 paths, and all but one of each are dups.
        assert_eq!(links, 120);
        assert_eq!(s.hardlink_dups, 120, "the fixture must exercise dedup");
        assert_eq!(
            (p.files, p.dirs, p.hardlink_dups),
            (s.files, s.dirs, s.hardlink_dups)
        );
        assert_eq!(totals(std::slice::from_ref(&serial)), totals(&parallel));
        assert_eq!((p.errors, p.lost_entries), (0, 0));
        assert_eq!((p.incomplete, p.depth_capped), (None, 0));
        assert!(p.unreadable.is_empty() && p.skipped_mounts.is_empty());
    }

    /// The fixture is big enough to be stolen from, and the pool really does
    /// steal from it. Without this, every comparison here could pass on a
    /// walk that ran entirely on one worker.
    #[test]
    fn walk_shares_the_tree_between_workers() {
        let fx = wide_fixture();

        let (arenas, stats) = walk(&opts(fx.path())).unwrap();

        let busy = arenas.iter().filter(|a| !a.is_empty()).count();
        assert!(
            busy > 1,
            "all {} nodes landed in one of {} arenas: nothing was shared",
            stats.dirs + stats.files,
            arenas.len()
        );
        assert!(stats.dirs > 50 && stats.files == 3000);
    }

    /// The stronger parity comparison, available because this tree has no
    /// hardlinks: with nothing order-dependent left, the frozen arrays must
    /// match the serial walk's byte for byte. Freeze sorts each sibling range
    /// by size and then by name, and siblings have distinct names, so the
    /// order is fixed by the tree's content and not by which arena a node
    /// landed in.
    #[test]
    fn parallel_frozen_bytes_match_serial_on_a_hardlink_free_tree() {
        let fx = wide_fixture();

        let (serial, s) = walk_serial(&opts(fx.path())).unwrap();
        let (parallel, p) = walk(&opts(fx.path())).unwrap();
        assert_eq!(s.hardlink_dups, 0, "this comparison needs no hardlinks");

        let serial = snapshot(vec![serial], s);
        let parallel = snapshot(parallel, p);

        assert_eq!(serial.nodes, parallel.nodes);
        assert_eq!(serial.names, parallel.names);
        assert_eq!(serial.root, parallel.root);
    }

    #[test]
    fn parallel_walk_is_deterministic_after_freeze() {
        let fx = wide_fixture();

        let (first, first_stats) = walk(&opts(fx.path())).unwrap();
        let (second, second_stats) = walk(&opts(fx.path())).unwrap();
        let first = snapshot(first, first_stats);
        let second = snapshot(second, second_stats);

        assert_eq!(first.nodes, second.nodes);
        assert_eq!(first.names, second.names);
    }

    #[test]
    fn node_budget_is_shared_across_workers_not_per_arena() {
        const BUDGET: u64 = 200;
        let fx = wide_fixture();
        let mut o = opts(fx.path());
        o.node_budget = BUDGET;
        o.workers = 8;

        let (arenas, stats) = walk(&o).unwrap();

        let (nodes, _, _) = totals(&arenas);
        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
        // A per-arena budget would allow `workers * BUDGET` (1600) here, and
        // the fixture holds over 3000 entries, so it would not stop early.
        assert!(
            nodes <= BUDGET,
            "{nodes} nodes stored under a shared budget of {BUDGET}"
        );
        assert!(nodes > 0);
        assert_eq!(
            stats.dirs + stats.files,
            nodes,
            "counts match what is stored"
        );
    }

    /// One worker's arena failure is the whole walk's failure.
    ///
    /// `InodeSet::try_claim` records an inode *before* the node is pushed, so a
    /// walk that carried on after one worker's push failed could leave an
    /// inode claimed by a node that was never stored — bytes lost rather than
    /// double-counted, and nothing downstream can tell. Exactly one worker is
    /// capped, so the shared budget and every other worker still have room:
    /// nothing but the halt can stop them.
    ///
    /// # What this does and does not pin
    ///
    /// It pins that the failure becomes the whole walk's: it reaches the
    /// merged `incomplete`, and the result comes back short rather than
    /// complete-but-flagged.
    ///
    /// It deliberately does **not** assert a bound on how much the other
    /// workers stored, which is tempting and wrong. That figure is the size of
    /// the window between worker 0 getting a task and failing, and the
    /// scheduler sets it, not the code: measured in isolation it was 1 to 103
    /// of the fixture's 3050 entries, but under a full `cargo test --workspace`
    /// — ten test threads on eight cores — worker 0 was descheduled long
    /// enough for 1240 and 1737, and a bound of 1000 failed two runs in ten.
    /// Raising the bound until it stopped failing would have left a test that
    /// asserts nothing in particular.
    ///
    /// The window itself is pinned without a race, in two halves, by
    /// `walk::tests::a_terminal_failure_raises_the_halt` (a failure raises the
    /// shared halt) and `walk::tests::a_raised_halt_stops_a_push_dead` (a
    /// worker whose halt is raised refuses its very next push and stores
    /// nothing). Those two compose to the property; this test is what shows
    /// the pool really does give every worker the same halt.
    #[test]
    fn one_workers_arena_failure_is_the_whole_walks_failure() {
        const CAP: u64 = 1;
        let fx = wide_fixture();
        let mut o = opts(fx.path());
        o.workers = 8;
        let (_, serial) = walk_serial(&o).unwrap();

        // Which worker gets which task is a race by design, and a walk where
        // worker 0 was never handed one has no failure to propagate and would
        // assert nothing. So the walk is driven until it has. Measured: it had
        // on the first attempt in 200 isolated runs out of 200, and in 24 out
        // of 25 runs of the whole suite, where ten test threads compete for
        // eight cores.
        let mut attempts = 0;
        let (arenas, stats) = loop {
            attempts += 1;
            let (arenas, stats) = walk_with(&o, &OpenAt, &[CAP]).unwrap();
            if arenas[0].len() == CAP {
                break (arenas, stats);
            }
            assert_eq!(arenas[0].len(), 0, "a capped arena holds 0 or {CAP}");
            assert!(
                attempts < 20,
                "worker 0 was given no task in {attempts} walks, so its arena \
                 never failed and there was nothing to propagate"
            );
        };

        let (nodes, _, _) = totals(&arenas);
        assert_eq!(
            stats.incomplete,
            Some(Incomplete::NodeBudget),
            "one worker's failure did not become the walk's"
        );
        assert!(
            nodes < serial.dirs + serial.files,
            "{nodes} nodes stored of the {} a complete walk finds, although a \
             worker failed: the walk was not cut short at all",
            serial.dirs + serial.files
        );
        assert_eq!(stats.dirs + stats.files, nodes);
    }

    /// Fails every `openat` with `EMFILE`, whoever asks.
    struct FailEveryOpen;

    impl crate::walk::DirOpener for FailEveryOpen {
        fn open_dir_at(&self, _parent: RawFd, _name: &CStr) -> Result<OwnedFd, c_int> {
            Err(libc::EMFILE)
        }
    }

    /// Descriptor exhaustion is not terminal, so the walk finishes and the
    /// flag survives the merge. This is the half of the precedence rule that a
    /// budget failure would otherwise hide.
    #[test]
    fn descriptor_exhaustion_survives_the_merge() {
        let fx = wide_fixture();

        let (_, stats) = walk_with(&opts(fx.path()), &FailEveryOpen, &[]).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::FdExhausted));
        assert_eq!(stats.errors, 0, "not filed with the benign races");
        assert_eq!(stats.dirs, 11, "the root and its ten subdirectories");
    }

    #[test]
    fn unreadable_directories_are_reported_whichever_worker_meets_them() {
        let fx = wide_fixture();
        for i in [1, 4, 7] {
            fx.chmod(&format!("t{i}/u0"), 0o000).unwrap();
        }

        let (arenas, stats) = walk(&opts(fx.path())).unwrap();

        let mut found = stats.unreadable.clone();
        found.sort();
        let mut want: Vec<_> = [1, 4, 7]
            .iter()
            .map(|i| fx.path().join(format!("t{i}/u0")))
            .collect();
        want.sort();
        assert_eq!(found, want);
        // The flag is what renders the directory as locked, and it has to
        // reach the node even when another worker owns the arena it lives in.
        let flagged = arenas
            .iter()
            .flat_map(Arena::iter)
            .filter(|(_, n)| n.flags & crate::arena::FLAG_PERM_DENIED != 0)
            .count();
        assert_eq!(flagged, 3);
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.incomplete, None);
    }

    #[test]
    fn an_empty_root_walks_to_a_single_node() {
        let fx = Fixture::new().unwrap();
        let (arenas, stats) = walk(&opts(fx.path())).unwrap();
        let (nodes, _, _) = totals(&arenas);
        assert_eq!((nodes, stats.dirs, stats.files), (1, 1, 0));
        assert_eq!(stats.incomplete, None);
        // Every worker but one came back with an empty arena, which freeze has
        // to skip rather than trip over: an empty arena issued no id and so
        // has no thread tag to collide with.
        assert!(arenas.iter().filter(|a| a.is_empty()).count() >= arenas.len() - 1);
        let snapshot = snapshot(arenas, stats);
        assert_eq!(snapshot.nodes.len(), 1);
        assert_eq!(snapshot.root, 0);
    }

    /// The precedence rule the merge has to carry: a reason that *stopped* a
    /// worker outranks one another worker noticed and walked past, and the
    /// result does not depend on which thread finished first.
    #[test]
    fn merging_prefers_the_reason_that_stopped_the_walk() {
        let flagged = |why: Option<Incomplete>| WalkStats {
            incomplete: why,
            ..WalkStats::default()
        };
        let merged = |a, b| {
            let mut into = flagged(a);
            merge(&mut into, flagged(b)).unwrap();
            into.incomplete
        };
        use Incomplete::{FdExhausted, MalformedBatch, NodeBudget, OutOfMemory};

        // A terminal reason wins from either side, so the answer is the same
        // whichever worker is merged first.
        for terminal in [NodeBudget, OutOfMemory, Incomplete::Cancelled] {
            for noticed in [FdExhausted, MalformedBatch] {
                assert_eq!(merged(Some(noticed), Some(terminal)), Some(terminal));
                assert_eq!(merged(Some(terminal), Some(noticed)), Some(terminal));
            }
        }
        // Nothing overwrites a reason with no reason, and equal rank keeps
        // what is already there.
        assert_eq!(merged(Some(FdExhausted), None), Some(FdExhausted));
        assert_eq!(merged(None, Some(FdExhausted)), Some(FdExhausted));
        assert_eq!(
            merged(Some(FdExhausted), Some(MalformedBatch)),
            Some(FdExhausted)
        );
        assert_eq!(merged(None, None), None);
    }

    /// Every counter and list is carried across, and the destructuring in
    /// `merge` makes a field added later a compile error rather than a silent
    /// omission. This pins the arithmetic the destructuring cannot.
    #[test]
    fn merging_carries_every_field() {
        let mut into = WalkStats {
            dirs: 1,
            files: 2,
            errors: 3,
            unreadable: vec![Path::new("/a").to_path_buf()],
            skipped_mounts: vec![(
                Path::new("/m").to_path_buf(),
                crate::boundary::SkipReason::OtherVolume,
            )],
            depth_capped: 4,
            lost_entries: 5,
            hardlink_dups: 6,
            stalled_at: None,
            incomplete: None,
        };
        merge(
            &mut into,
            WalkStats {
                dirs: 10,
                files: 20,
                errors: 30,
                unreadable: vec![Path::new("/b").to_path_buf()],
                skipped_mounts: vec![(
                    Path::new("/n").to_path_buf(),
                    crate::boundary::SkipReason::NonLocalMount,
                )],
                depth_capped: 40,
                lost_entries: 50,
                hardlink_dups: 60,
                stalled_at: Some(Path::new("/s").to_path_buf()),
                incomplete: Some(Incomplete::FdExhausted),
            },
        )
        .unwrap();

        assert_eq!((into.dirs, into.files, into.errors), (11, 22, 33));
        assert_eq!(
            (into.depth_capped, into.lost_entries, into.hardlink_dups),
            (44, 55, 66)
        );
        assert_eq!(
            into.unreadable,
            vec![Path::new("/a").to_path_buf(), Path::new("/b").to_path_buf()]
        );
        assert_eq!(
            into.skipped_mounts
                .iter()
                .map(|(p, _)| p)
                .collect::<Vec<_>>(),
            vec![Path::new("/m"), Path::new("/n")]
        );
        assert_eq!(into.stalled_at.as_deref(), Some(Path::new("/s")));
        assert_eq!(into.incomplete, Some(Incomplete::FdExhausted));
    }

    #[test]
    fn a_depth_cap_of_zero_records_the_root_and_stops() {
        let fx = wide_fixture();
        let mut o = opts(fx.path());
        o.max_depth = 0;
        let (arenas, stats) = walk(&o).unwrap();
        assert_eq!(totals(&arenas).0, 1);
        assert_eq!((stats.dirs, stats.files, stats.depth_capped), (1, 0, 1));
    }

    /// A chain of directories whose absolute path runs past `PATH_MAX`, built
    /// with `mkdirat` because `std::fs` cannot address one. Removes itself,
    /// so the fixture's own cleanup never has to look at a path it could not
    /// name.
    struct DeepChain {
        /// One descriptor per level, outermost first.
        levels: Vec<OwnedFd>,
        name: std::ffi::CString,
        /// Length of the deepest directory's absolute path.
        path_len: usize,
    }

    impl DeepChain {
        fn build(at: &Path, levels: usize, name_len: usize) -> DeepChain {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = std::ffi::CString::new("d".repeat(name_len)).unwrap();
            let mut chain = DeepChain {
                levels: vec![OwnedFd::from(std::fs::File::open(at).unwrap())],
                name,
                path_len: at.as_os_str().len(),
            };
            for level in 0..levels {
                let parent = chain.levels.last().unwrap().as_raw_fd();
                // SAFETY: `parent` is an open directory and `name` is a live
                // NUL-terminated string.
                assert_eq!(
                    unsafe { libc::mkdirat(parent, chain.name.as_ptr(), 0o755) },
                    0,
                    "mkdirat at level {level}"
                );
                // SAFETY: same, and the directory was just created.
                let fd = unsafe {
                    libc::openat(
                        parent,
                        chain.name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
                    )
                };
                assert!(fd >= 0, "openat at level {level}");
                // SAFETY: `openat` just returned this descriptor.
                chain.levels.push(unsafe { OwnedFd::from_raw_fd(fd) });
                chain.path_len += 1 + name_len;
            }
            chain
        }

        /// Put a file at the bottom, so there is something to lose.
        fn add_file(&self, name: &str, bytes: usize) {
            use std::os::fd::AsRawFd;
            let c = std::ffi::CString::new(name).unwrap();
            // SAFETY: the parent is an open directory and `c` is live.
            let fd = unsafe {
                libc::openat(
                    self.levels.last().unwrap().as_raw_fd(),
                    c.as_ptr(),
                    libc::O_CREAT | libc::O_WRONLY | libc::O_CLOEXEC,
                    0o644 as libc::c_uint,
                )
            };
            assert!(fd >= 0, "openat O_CREAT {name}");
            let data = vec![7u8; bytes];
            // SAFETY: `fd` is an open writable file and `data` is live.
            assert_eq!(
                unsafe { libc::write(fd, data.as_ptr().cast(), data.len()) },
                data.len() as isize
            );
            // SAFETY: `fd` was opened above and is not used again.
            unsafe { libc::close(fd) };
        }
    }

    impl Drop for DeepChain {
        fn drop(&mut self) {
            use std::os::fd::AsRawFd;
            // Bottom up, each removal relative to its parent's descriptor.
            let bottom = std::ffi::CString::new("bottom.bin").unwrap();
            if let Some(deepest) = self.levels.last() {
                // SAFETY: an open directory and a live name.
                unsafe { libc::unlinkat(deepest.as_raw_fd(), bottom.as_ptr(), 0) };
            }
            while self.levels.len() > 1 {
                self.levels.pop();
                let parent = self.levels.last().unwrap().as_raw_fd();
                // SAFETY: an open directory, a live name, and the directory
                // below it is now empty.
                unsafe { libc::unlinkat(parent, self.name.as_ptr(), libc::AT_REMOVEDIR) };
            }
        }
    }

    /// A directory too deep to name in `PATH_MAX` cannot be republished for
    /// another worker, because a stolen task is reopened by absolute path.
    /// `Walker::offer` keeps such a directory and descends it with `openat`
    /// instead, so it is walked by whoever enumerated its parent — not
    /// dropped, and not charged to `errors`. Losing it would lose its bytes,
    /// which is the one failure direction nothing downstream can detect.
    #[test]
    fn a_directory_too_deep_to_name_is_kept_rather_than_lost() {
        let fx = wide_fixture();
        // 20 levels of 100-byte names: over 2000 bytes, twice `PATH_MAX`.
        let chain = DeepChain::build(&fx.path().join("t0"), 20, 100);
        chain.add_file("bottom.bin", 4096);
        assert!(
            chain.path_len > MAX_PATH_BYTES_FOR_TEST,
            "the chain is only {} bytes deep, so nothing is being tested",
            chain.path_len
        );

        let (serial, s) = walk_serial(&opts(fx.path())).unwrap();
        let (parallel, p) = walk(&opts(fx.path())).unwrap();

        assert_eq!(s.files, 3001, "the fixture plus the buried file");
        assert_eq!((p.dirs, p.files), (s.dirs, s.files));
        assert_eq!((p.errors, p.incomplete), (0, None));
        assert_eq!(totals(std::slice::from_ref(&serial)), totals(&parallel));
    }

    /// `walk::MAX_PATH_BYTES` is private; this is the same figure, and the
    /// assertion above only needs a floor.
    const MAX_PATH_BYTES_FOR_TEST: usize = 1023;

    #[test]
    fn a_depth_cap_matches_the_serial_walk() {
        let fx = wide_fixture();
        for depth in 1..=4 {
            let mut o = opts(fx.path());
            o.max_depth = depth;
            let (serial, s) = walk_serial(&o).unwrap();
            let (parallel, p) = walk(&o).unwrap();
            assert_eq!(
                (p.dirs, p.files, p.depth_capped),
                (s.dirs, s.files, s.depth_capped),
                "max_depth {depth}"
            );
            assert_eq!(
                totals(std::slice::from_ref(&serial)),
                totals(&parallel),
                "max_depth {depth}"
            );
        }
    }

    #[test]
    fn rejects_a_buffer_too_small_for_one_entry() {
        let fx = Fixture::new().unwrap();
        fx.file("a.bin", 1).unwrap();
        let mut o = opts(fx.path());
        o.buffer_bytes = 16;
        let err = walk(&o).err().expect("walk must fail");
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn unreadable_root_is_an_error_not_a_partial_result() {
        let fx = Fixture::new().unwrap();
        fx.dir("locked").unwrap();
        fx.chmod("locked", 0o000).unwrap();
        let err = walk(&opts(&fx.path().join("locked")))
            .err()
            .expect("walk must fail");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn worker_count_fits_the_descriptor_limit() {
        // The limit was raised: the requested count stands, and the product
        // with the depth cap is allowed to exceed it (see `worker_count`).
        assert_eq!(worker_count(16, 512, NOFILE_TARGET), 16);
        assert_eq!(worker_count(16, 512, 65_536), 16);
        assert_eq!(worker_count(4, 512, NOFILE_TARGET), 4);

        // It was not: divide what is left of the limit by what a worker needs.
        assert_eq!(worker_count(16, 512, 64), 1, "(64 - 32) / 513 rounds to 0");
        assert_eq!(worker_count(16, 20, 1024), 16, "(1024 - 32) / 21 is 47");
        assert_eq!(worker_count(16, 100, 1024), 9, "(1024 - 32) / 101 is 9");
        assert_eq!(
            worker_count(16, 512, 0),
            1,
            "a limit that could not be read"
        );
        assert_eq!(worker_count(16, 0, 64), 16, "depth 0 needs one each");

        // A caller's own figure is honoured, within reason.
        assert_eq!(worker_count(0, 512, NOFILE_TARGET), 1);
        assert_eq!(worker_count(1_000_000, 512, NOFILE_TARGET), MAX_WORKERS);
    }

    /// Lowers the process's `RLIMIT_NOFILE`, hard limit included, so that the
    /// raise at entry cannot succeed.
    ///
    /// `#[ignore]`: `setrlimit` is process-wide and cargo runs a binary's tests
    /// as threads in one process, so this would corrupt every test running
    /// beside it. The hard limit cannot be put back, either. CI runs it in its
    /// own step, on its own: see `.github/workflows/ci.yml`.
    #[test]
    #[ignore = "setrlimit is process-wide and the hard limit cannot be restored"]
    fn raises_nofile_limit_and_falls_back_to_fewer_workers() {
        let fx = Fixture::new().unwrap();
        for i in 0..4 {
            fx.file(&format!("d{i}/f.bin"), 64).unwrap();
        }

        // The raise at entry asks for 4096. A hard limit of 64 refuses it, and
        // `worker_count` then has to fit 16 workers into what is left.
        let mut limit = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        // SAFETY: `limit` is a live, correctly sized `rlimit`.
        assert_eq!(
            unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) },
            0
        );
        let squeezed = libc::rlimit {
            rlim_cur: 64,
            rlim_max: 64,
        };
        // SAFETY: `squeezed` is a live, correctly sized `rlimit`.
        assert_eq!(
            unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &squeezed) },
            0,
            "the test cannot run without lowering the limit"
        );
        assert_eq!(
            raise_nofile(NOFILE_TARGET),
            64,
            "the raise must have failed, or this proves nothing"
        );

        let mut o = opts(fx.path());
        o.workers = 16;
        let outcome = walk(&o);

        // Restore the soft limit before asserting. The hard limit stays where
        // it is: a process cannot raise its own.
        let back = libc::rlimit {
            rlim_cur: 64,
            rlim_max: 64,
        };
        // SAFETY: `back` is a live, correctly sized `rlimit`.
        unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &back) };

        let (arenas, stats) = outcome.expect("the walk must succeed, not fail");
        assert_eq!(
            arenas.len(),
            1,
            "16 workers were asked for and {} ran",
            arenas.len()
        );
        assert_eq!((stats.dirs, stats.files), (5, 4));
        assert_eq!(stats.incomplete, None);
        assert_eq!(stats.errors, 0);
    }
}
