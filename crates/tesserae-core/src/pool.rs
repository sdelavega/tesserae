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
//! Each worker owns a LIFO [`Worker`] deque, a [`Lane`] holding an [`Arena`]
//! tagged with its index and its own [`WalkStats`], and its own read buffer.
//! An [`Injector`] holds the one task the walk starts with, the scan root.
//! Every other task is a directory some worker enumerated and chose not to
//! descend immediately.
//!
//! **Depth-first within a worker, breadth-shared across workers.** A worker
//! descends with `openat` from the descriptor it already holds, so its open
//! descriptors are a chain down the tree — one per level, bounded by depth,
//! not by the number of directories it has seen. What it hands to the pool is
//! breadth: the siblings it is not about to enter. Those cannot carry a
//! descriptor, because the chain that reached them belongs to this thread, so
//! they carry an `Arc<Path>` relative to the scan root, and the worker that
//! takes one reopens it beneath the root's descriptor with
//! `walk::open_beneath`, which refuses a symlink in any component. The root
//! stays open for the whole walk for exactly that purpose.
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
//! worker ever blocks on another, so there is nothing to deadlock; an idle
//! worker yields and looks again. (A worker blocked in the *kernel* holds its
//! task forever, and `pending` never reaches zero: that is the stall, and the
//! watchdog below is what ends it.)
//!
//! Relaxed ordering is enough for the counter itself: a single atomic has a
//! total modification order, so reading zero means every increment so far has
//! been matched, and the argument above rules out a later one. The arenas are
//! published by their lanes' locks, which the supervisor takes to collect them.
//!
//! A panic is the one way out of a task that does not decrement, so
//! [`HaltOnPanic`] raises the halt on an unwind. Otherwise the remaining
//! workers would spin on a task that will never complete, and the supervisor
//! would wait for them instead of reporting the panic.
//!
//! # The supervisor, and abandonment
//!
//! The workers are not scoped threads, and the walk does not join them all.
//! Spec section 11 requires that a worker blocked in an uninterruptible
//! syscall — an `openat` on a hung volume — leaks while the walk returns its
//! partial result, and a scope that joins every thread before it returns
//! cannot do that. So everything a worker can touch is owned by one [`Shared`]
//! behind an `Arc` (the opener, the hardlink set, the budget, the halt, the
//! counters, the root's descriptor and the lanes), which a worker left behind
//! keeps alive for as long as it needs it.
//!
//! The calling thread supervises; [`supervise`] has the loop. Every [`TICK`]
//! it copies the walk's counters into the caller's [`Progress`], turns a
//! cancel into the halt, and runs the watchdog: if no worker has completed a
//! syscall for `stall_timeout` while one is inside one, that directory's path
//! is recorded and the halt is raised as [`Incomplete::Stalled`].
//!
//! The walk is over when every worker has finished, or — once the halt is up
//! — when every worker has either finished or is inside a syscall. Those are
//! abandoned. Their threads are detached and their lanes taken anyway: a
//! worker never holds its lane's lock across a syscall (see [`Lane`]), so the
//! lock is free, and taking the arena rather than dropping it is what keeps
//! every other arena's references to it from dangling at freeze. An
//! abandoned worker that comes back finds its lane empty and exits without
//! touching anything. Abandoning a worker only because it happened to be in a
//! quick syscall when the halt went up costs nothing: the walk was ending
//! anyway, and the thread exits a moment later.
//!
//! # Descriptors
//!
//! `RLIMIT_NOFILE` is raised to [`NOFILE_TARGET`] at entry. If it cannot be,
//! the worker count is reduced to fit the limit that is in force rather than
//! failing the scan; see [`worker_count`].

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{JoinHandle, Thread};
use std::time::{Duration, Instant};

use crossbeam_deque::{Injector, Stealer, Worker};

use crate::arena::{Arena, ScanId};
use crate::boundary::VolumeId;
use crate::dedup::InodeSet;
use crate::progress::Progress;
use crate::walk::{
    assemble_path, check_options, join_root, open_root, root_volume_of, with_context, DirOpener,
    Halt, Incomplete, Lane, NodeBudget, OpenAt, Share, WalkOptions, WalkStats, Walker, WalkerCtx,
};
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;

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
/// How often the supervisor wakes when nothing wakes it sooner: the latency
/// of a cancel, of the caller's counters, and of the watchdog. Finer than the
/// one-second poll the watchdog strictly needs, because the same tick carries
/// the cancel, and 100 wake-ups a second of a thread that only reads a few
/// dozen atomics cost nothing measurable. A finishing worker wakes the
/// supervisor at once, so a walk that ends on its own does not wait for it.
pub(crate) const TICK: Duration = Duration::from_millis(10);

/// One directory to walk.
enum Task {
    /// The scan root. Its node has not been pushed yet, and this is a
    /// duplicate of the root's descriptor for the root frame to own and close.
    Root(OwnedFd),
    /// A directory already recorded as `node` in some worker's arena, at
    /// `rel` beneath the scan root and at absolute depth `depth`.
    Dir {
        rel: Arc<Path>,
        node: ScanId,
        depth: u16,
    },
}

/// The queues, the task count that decides when the walk is over, and the
/// flags that belong to another arena.
struct Pool {
    /// Tasks created and not yet completed. See the module's termination note:
    /// this, not an idle count, is what says the walk is finished.
    pending: AtomicUsize,
    injector: Injector<Task>,
    stealers: Vec<Stealer<Task>>,
    /// `(node, flags)` for nodes a worker learned something about but does not
    /// own. Applied once the lanes are taken; taken only on a permission
    /// denial on a stolen directory, so essentially never. A worker pushes
    /// here only while holding its own lane, so once every lane is taken
    /// nothing more can arrive.
    foreign: Mutex<Vec<(ScanId, u16)>>,
}

impl Pool {
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
    pool: &'a Pool,
    local: &'a Worker<Task>,
}

impl Share for Hand<'_> {
    fn wants_work(&self) -> bool {
        self.local.len() < PUBLISH_TARGET
    }

    fn publish(&self, rel: Arc<Path>, node: ScanId, depth: u16) {
        // Counted before it is pushed. The other order would let a worker see
        // every deque empty and `pending == 0` while this directory was
        // unwalked, and the scan would come back short.
        self.pool.pending.fetch_add(1, Ordering::Relaxed);
        self.local.push(Task::Dir { rel, node, depth });
    }

    fn flag_foreign(&self, node: ScanId, flags: u16) -> bool {
        let mut queue = self
            .pool
            .foreign
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        // If the one slot cannot be reserved the flag is lost and the caller
        // records `OutOfMemory`, as every other reserve failure in the walk
        // does: the directory would otherwise render as an empty folder
        // rather than a locked one, with nothing to say so.
        if queue.try_reserve(1).is_err() {
            return false;
        }
        queue.push((node, flags));
        true
    }
}

/// Stops every other worker if this one unwinds. Without it a panic would
/// leave `pending` above zero for a task nothing will ever complete, and the
/// other workers would spin while the supervisor waited for them — hiding the
/// panic behind a hang.
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

/// What a test can make one worker's arena do. Production passes none, so
/// outside tests nothing constructs one.
#[derive(Debug, Clone, Copy)]
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) enum ArenaLimit {
    /// The arena's own ceiling of this many nodes: [`Arena::push_node`]
    /// refuses the next with `NodeBudgetExceeded`.
    Cap(u64),
    /// Refuse every push once the arena holds this many nodes, as if the
    /// allocator had refused a chunk: `OutOfMemory`.
    #[cfg(test)]
    OutOfMemoryAfter(u64),
}

/// One worker as the supervisor sees it.
struct Seat {
    lane: Lane,
    /// Set as the worker's thread finishes, however it finishes; the last
    /// thing it does. Never set for a worker blocked in a syscall.
    done: AtomicBool,
}

/// Marks a worker finished as its thread's last act — returning, failing or
/// unwinding — and wakes the supervisor to look.
struct Finished<'a> {
    seat: &'a Seat,
    supervisor: &'a Thread,
}

impl Drop for Finished<'_> {
    fn drop(&mut self) {
        self.seat.done.store(true, Ordering::Release);
        self.supervisor.unpark();
    }
}

/// Everything the workers share, owned, behind one `Arc`: a worker abandoned
/// in a blocked syscall outlives the call that started it, so nothing it can
/// still reach may be borrowed from that call. See the module note.
struct Shared<O> {
    opener: Arc<O>,
    inodes: InodeSet,
    budget: NodeBudget,
    halt: Halt,
    /// The walk's own counters. Not the caller's [`Progress`], which is only
    /// borrowed: the supervisor copies these into it.
    counters: Progress,
    root_volume: VolumeId,
    /// The scan root, open for the whole walk and for as long as any worker
    /// abandoned in it lives: every published directory is reopened beneath
    /// it.
    root_fd: OwnedFd,
    opts: WalkOptions,
    pool: Pool,
    seats: Vec<Seat>,
    /// The calling thread, which the workers wake as they finish.
    supervisor: Thread,
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
/// [`WalkStats::incomplete`] set — including one cut short by a stall, which
/// may leave a worker thread behind; see [`WalkOptions::stall_timeout`]. For
/// live counters and cancellation, see
/// [`crate::progress::walk_with_progress`].
///
/// [`walk_serial`]: crate::walk::walk_serial
///
/// # Panics
///
/// Resumes a worker thread's panic on the calling thread. A worker abandoned
/// in a syscall that panics after the walk has returned panics alone.
pub fn walk(opts: &WalkOptions) -> io::Result<(Vec<Arena>, WalkStats)> {
    walk_with(opts, Arc::new(OpenAt), &[], &Progress::default())
}

/// [`walk`] with the caller's opener and counters, and per-worker arena
/// limits.
///
/// `limits` is empty in production: the walk's limit is the shared
/// [`NodeBudget`], and a per-arena ceiling would multiply by the worker count.
/// `limits[i]` applies to worker `i`'s arena and anything past the end is
/// unlimited, which is how a test makes *one* worker's push fail while every
/// other worker and the shared budget still have room — the only way to reach
/// the "one worker failed" path on purpose.
///
/// The opener is shared by `Arc` because a worker can outlive this call, and
/// a test keeps its own handle to inspect afterwards.
pub(crate) fn walk_with<O: DirOpener + Send + Sync + 'static>(
    opts: &WalkOptions,
    opener: Arc<O>,
    limits: &[ArenaLimit],
    progress: &Progress,
) -> io::Result<(Vec<Arena>, WalkStats)> {
    check_options(opts)?;
    let workers = worker_count(opts.workers, opts.max_depth, raise_nofile(NOFILE_TARGET));

    // Before anything is spawned: if the root cannot be opened or its volume
    // cannot be read, there is no walk to parallelise.
    let root_fd = open_root(opts)?;
    let root_volume = root_volume_of(opts, &root_fd)?;
    // The root stays open for the whole walk: every published directory is
    // reopened beneath it with `open_beneath`, so nothing above it is ever
    // resolved again and nothing depends on the working directory. The root
    // frame gets a duplicate it can own and close. The two share a file
    // offset, which only the root frame's `getattrlistbulk` moves; `openat`
    // relative to a directory descriptor does not read it.
    let root_task_fd = root_fd
        .try_clone()
        .map_err(|e| with_context(e, format!("dup {}", opts.root.display())))?;

    let deques: Vec<Worker<Task>> = (0..workers).map(|_| Worker::new_lifo()).collect();
    let seats = (0..workers)
        .map(|i| {
            let limit = limits.get(i).copied();
            let cap = match limit {
                Some(ArenaLimit::Cap(cap)) => cap,
                _ => u64::MAX,
            };
            // `i < workers <= MAX_WORKERS`, well inside a tag.
            let lane = Lane::new(Arena::new(i as u16, cap));
            #[cfg(test)]
            if let Some(ArenaLimit::OutOfMemoryAfter(nodes)) = limit {
                lane.fail_after(nodes);
            }
            Seat {
                lane,
                done: AtomicBool::new(false),
            }
        })
        .collect();
    let shared = Arc::new(Shared {
        opener,
        inodes: InodeSet::new(workers * INODE_SHARDS_PER_WORKER),
        budget: NodeBudget::new(opts.node_budget),
        halt: Halt::new(),
        counters: Progress::default(),
        root_volume,
        root_fd,
        opts: opts.clone(),
        pool: Pool {
            // The root task, counted before it is pushed.
            pending: AtomicUsize::new(1),
            injector: Injector::new(),
            stealers: deques.iter().map(Worker::stealer).collect(),
            foreign: Mutex::new(Vec::new()),
        },
        seats,
        supervisor: std::thread::current(),
    });
    shared.pool.injector.push(Task::Root(root_task_fd));

    let mut threads: Vec<Option<JoinHandle<io::Result<()>>>> = Vec::new();
    let mut spawn_failed = None;
    for (i, local) in deques.into_iter().enumerate() {
        if spawn_failed.is_some() {
            // Never started, so there is nothing to wait for.
            shared.seats[i].done.store(true, Ordering::Release);
            continue;
        }
        let worker = Arc::clone(&shared);
        let spawned = std::thread::Builder::new()
            .name(format!("tesserae-walk-{i}"))
            .spawn(move || run_worker(&worker, i, local));
        match spawned {
            Ok(thread) => threads.push(Some(thread)),
            Err(e) => {
                // Stop the workers already running: the caller gets this
                // error, not a scan done by fewer threads than it was told.
                shared.halt.raise(Incomplete::Cancelled);
                shared.seats[i].done.store(true, Ordering::Release);
                threads.push(None);
                spawn_failed = Some(e);
            }
        }
    }

    let stalled_at = supervise(&shared, progress);

    // Join the workers that finished, in index order, so that the first
    // failure is the one reported; leave the abandoned ones behind. Dropping
    // a handle detaches its thread.
    let mut failure = spawn_failed;
    for (seat, thread) in shared.seats.iter().zip(threads) {
        let Some(thread) = thread else { continue };
        if seat.done.load(Ordering::Acquire) {
            match thread.join() {
                Ok(Ok(())) => {}
                Ok(Err(e)) => {
                    failure.get_or_insert(e);
                }
                Err(panic) => std::panic::resume_unwind(panic),
            }
        }
    }
    if let Some(e) = failure {
        return Err(e);
    }

    let mut arenas: Vec<Arena> = Vec::new();
    arenas
        .try_reserve_exact(workers)
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    let mut stats = WalkStats::default();
    for seat in &shared.seats {
        // Taken in index order, so arena `i` still carries thread tag `i`,
        // which is what `apply_foreign` and freeze rely on. A lane is taken
        // only here, so each is still there.
        let (arena, worker_stats, unpublished) = seat
            .lane
            .take()
            .expect("only the supervisor takes a lane, once");
        // What the worker had stored but not yet published, so that the
        // counters end equal to the result whatever stopped the walk.
        shared.counters.add(unpublished);
        merge(&mut stats, worker_stats)?;
        arenas.push(arena);
    }
    let foreign = std::mem::take(
        &mut *shared
            .pool
            .foreign
            .lock()
            .unwrap_or_else(PoisonError::into_inner),
    );
    apply_foreign(&mut arenas, foreign);
    // The halt names what stopped the walk. The workers that saw it recorded
    // it themselves, but a cancel or a stall is raised here, and an abandoned
    // worker records nothing.
    if let Some(why) = shared.halt.reason() {
        stats.incomplete = Some(why);
    }
    if stalled_at.is_some() {
        stats.stalled_at = stalled_at;
    }
    progress.set(shared.counters.snapshot());
    Ok((arenas, stats))
}

/// The calling thread's part: wait for the walk to end, and end it early when
/// it should. Returns the stalled directory's path if the watchdog fired.
///
/// Every [`TICK`], or sooner when a finishing worker wakes it:
///
/// 1. copy the walk's counters into the caller's `progress`;
/// 2. if the caller cancelled, raise the halt as [`Incomplete::Cancelled`];
/// 3. stop waiting when every worker has finished, or — once the halt is up —
///    when every worker has finished or is inside a syscall (abandoned);
/// 4. otherwise, the watchdog: total syscalls completed is the measure of
///    progress, and when it has not moved for `stall_timeout` and some
///    worker is inside a syscall, that worker's directory is the stall.
///
/// More than one worker can be blocked at once (a dead volume blocks every
/// worker that reaches it); the lowest-indexed is reported, since any of them
/// is a true answer to "stalled at what".
fn supervise<O>(shared: &Shared<O>, progress: &Progress) -> Option<PathBuf> {
    let total_ticks = || {
        shared
            .seats
            .iter()
            .fold(0u64, |sum, seat| sum.wrapping_add(seat.lane.ticks()))
    };
    let mut ticks = total_ticks();
    let mut moved = Instant::now();
    let mut stalled_at = None;
    loop {
        progress.set(shared.counters.snapshot());
        if progress.is_cancelled() {
            shared.halt.raise(Incomplete::Cancelled);
        }
        let halted = shared.halt.reason().is_some();
        let done = |seat: &Seat| seat.done.load(Ordering::Acquire);
        if shared.seats.iter().all(done) {
            break;
        }
        if halted
            && shared
                .seats
                .iter()
                .all(|seat| done(seat) || seat.lane.busy_on().is_some())
        {
            break;
        }
        if !halted {
            let now = total_ticks();
            if now != ticks {
                ticks = now;
                moved = Instant::now();
            } else if moved.elapsed() >= shared.opts.stall_timeout {
                if let Some(id) = shared.seats.iter().find_map(|seat| seat.lane.busy_on()) {
                    let path = stalled_path(shared, id);
                    shared.halt.raise(Incomplete::Stalled);
                    // Only if the stall is what stopped the walk: a reason
                    // raised a moment earlier wins, and then nothing stalled.
                    if shared.halt.reason() == Some(Incomplete::Stalled) {
                        stalled_at = path;
                    }
                }
            }
        }
        std::thread::park_timeout(TICK);
    }
    stalled_at
}

/// The path of `id` (the scan root as given, joined with the names below it),
/// by climbing from it to the root through
/// whichever arenas hold its ancestors: a stolen directory's node is in the
/// arena of the worker that enumerated its parent, not the one walking it.
///
/// Each lane is locked only for the one node read from it, and never while
/// another is held (see [`Lane`] on lock order). The climb is bounded by the
/// depth cap, so a malformed chain ends in `None` rather than a loop. `None`
/// also if a name cannot be copied for want of memory: the walk still stops
/// as stalled, it just cannot say where.
fn stalled_path<O>(shared: &Shared<O>, id: ScanId) -> Option<PathBuf> {
    let mut names: Vec<Vec<u8>> = Vec::new();
    let mut cur = id;
    for _ in 0..=usize::from(shared.opts.max_depth) {
        let seat = shared.seats.get(usize::from(cur.thread()))?;
        let (name, parent) = seat.lane.read(|arena| {
            let node = arena.get(cur)?;
            let bytes = arena.name_bytes(node.name);
            let mut name = Vec::new();
            name.try_reserve_exact(bytes.len()).ok()?;
            name.extend_from_slice(bytes);
            Some((name, node.parent))
        })??;
        if parent == ScanId::NONE {
            // `name` is the root's, which is the scan root's path as the
            // caller gave it: `join_root` supplies that.
            let rel = assemble_path(b"", &names).ok()?;
            return join_root(&shared.opts.root, rel.as_os_str().as_bytes()).ok();
        }
        names.try_reserve(1).ok()?;
        names.push(name);
        cur = parent;
    }
    None
}

/// One worker: take tasks until the walk is over. Its arena and stats stay
/// in its lane, where the supervisor takes them.
fn run_worker<O: DirOpener>(
    shared: &Shared<O>,
    index: usize,
    local: Worker<Task>,
) -> io::Result<()> {
    let seat = &shared.seats[index];
    // Declared first so it is dropped last: `done` is set only once
    // everything else this worker holds, its open directories included, has
    // been released.
    let _finished = Finished {
        seat,
        supervisor: &shared.supervisor,
    };
    let _halt_on_panic = HaltOnPanic(&shared.halt);
    let ctx = WalkerCtx {
        opener: &*shared.opener,
        inodes: &shared.inodes,
        budget: &shared.budget,
        halt: &shared.halt,
        progress: &shared.counters,
        root_volume: shared.root_volume,
        root_path: &shared.opts.root,
        root_dir: Some(shared.root_fd.as_fd()),
    };
    let hand = Hand {
        pool: &shared.pool,
        local: &local,
    };
    let mut walker = match Walker::new(&ctx, Some(&hand), &shared.opts, &seat.lane) {
        Ok(walker) => walker,
        Err(e) => {
            // This worker cannot walk at all, so the caller gets an `Err`
            // and no partial result. Stop the others rather than let them
            // finish a scan that is going to be thrown away; the reason is
            // only a signal, since `e` is what the caller sees.
            shared.halt.raise(Incomplete::OutOfMemory);
            return Err(e);
        }
    };
    let mut idle = 0u32;
    loop {
        if shared.halt.reason().is_some() {
            break;
        }
        match shared.pool.find(&local) {
            Some(task) => {
                idle = 0;
                #[cfg(feature = "test-hooks")]
                crate::test_hooks::before_task(&shared.opts.root);
                let outcome = match task {
                    Task::Root(fd) => walker.run_root(fd),
                    Task::Dir { rel, node, depth } => walker.run_dir(rel, node, depth),
                };
                // After the task is finished, and so after every directory it
                // published was counted. This is the half of the protocol that
                // makes `pending == 0` mean what it says.
                shared.pool.pending.fetch_sub(1, Ordering::Release);
                if outcome.is_err() {
                    // `run_root` / `run_dir` have already raised the halt.
                    break;
                }
            }
            None => {
                if shared.pool.pending.load(Ordering::Acquire) == 0 {
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
    Ok(())
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
    use tesserae_testutil::{DiskImage, Fixture};

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

    /// Wide *and* deep, with no hardlinks: eight top-level directories, each
    /// fanning out to 3 and then 3 again, each of those carrying a `c/d`
    /// chain. Files at three levels, 249 directories, 1320 files, six levels
    /// deep. Every directory that has siblings is a candidate for stealing,
    /// and most stolen directories have children of their own, so a child
    /// attached under the wrong parent has somewhere visible to go.
    fn deep_fixture() -> Fixture {
        let fx = Fixture::new().unwrap();
        for i in 0..8 {
            for j in 0..3 {
                for f in 0..10 {
                    fx.file(&format!("t{i}/a{j}/f{f}.bin"), 1 + f * 512)
                        .unwrap();
                }
                for k in 0..3 {
                    for f in 0..10 {
                        fx.file(&format!("t{i}/a{j}/b{k}/g{f}.bin"), 1 + f * 256)
                            .unwrap();
                    }
                    for f in 0..5 {
                        fx.file(&format!("t{i}/a{j}/b{k}/c/d/h{f}.bin"), 1 + f * 128)
                            .unwrap();
                    }
                }
            }
        }
        fx
    }

    /// Workers that stored anything. More than one means the tree really was
    /// shared, so a comparison against the serial walk is not testing a
    /// serial walk twice.
    fn busy(arenas: &[Arena]) -> usize {
        arenas.iter().filter(|a| !a.is_empty()).count()
    }

    /// The structural parity check, available because this tree has no
    /// hardlinks: with nothing order-dependent left, the frozen arrays must
    /// match the serial walk's byte for byte.
    ///
    /// This is what the totals test cannot see. A stolen directory whose
    /// children were attached under the wrong parent `ScanId` still has every
    /// node counted and every byte summed, so counts and totals agree while
    /// the tree is wrong. Freeze lays nodes out by parent, so a misattached
    /// child moves in `nodes` and changes `parent`, `child_start`,
    /// `child_count` and the rolled-up sizes.
    ///
    /// Byte-identity holds whatever the schedule because freeze orders each
    /// sibling range by size, then by name, and siblings have distinct names:
    /// the arena-dependent tiebreak never fires (see
    /// `freeze::tests::frozen_bytes_do_not_depend_on_arena_order`). Several
    /// walks, sixteen workers each, so several schedules are compared.
    #[test]
    fn parallel_frozen_bytes_match_serial_on_a_hardlink_free_tree() {
        let fx = deep_fixture();
        let mut o = opts(fx.path());
        o.workers = 16;

        let (serial, s) = walk_serial(&o).unwrap();
        assert_eq!(s.hardlink_dups, 0, "this comparison needs no hardlinks");
        assert_eq!((s.dirs, s.files), (249, 1320));
        let serial = snapshot(vec![serial], s);

        for round in 0..5 {
            let (parallel, p) = walk(&o).unwrap();
            assert!(
                busy(&parallel) > 1,
                "round {round}: one worker did everything, so nothing was stolen"
            );
            assert_eq!((p.errors, p.incomplete), (0, None), "round {round}");
            let parallel = snapshot(parallel, p);

            assert_eq!(serial.root, parallel.root, "round {round}");
            assert_eq!(serial.names, parallel.names, "round {round}");
            assert!(
                serial.nodes == parallel.nodes,
                "round {round}: frozen nodes differ (first at index {:?})",
                serial
                    .nodes
                    .iter()
                    .zip(&parallel.nodes)
                    .position(|(a, b)| a != b)
            );
        }
    }

    /// Fails the open of the directory `victim` with a fixed errno.
    struct FailVictim(c_int);

    impl DirOpener for FailVictim {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return Err(self.0);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    /// The parallel half of `volume_gone_errnos_on_a_live_volume_are_churn_not_loss`
    /// in `walk`: on a live volume these stay a counted error with several
    /// workers too.
    #[test]
    fn volume_gone_errnos_on_a_live_volume_are_churn_not_loss() {
        for errno in [
            libc::ENOENT,
            libc::ENOTDIR,
            libc::EIO,
            libc::ENXIO,
            libc::ENODEV,
            libc::EBADF,
            libc::ENOTSUP,
        ] {
            let fx = Fixture::new().unwrap();
            fx.file("victim/inner.bin", 4096).unwrap();
            for d in 0..8 {
                fx.file(&format!("other{d}/f.bin"), 4096).unwrap();
            }
            let mut o = opts(fx.path());
            o.workers = 4;

            let (_, stats) =
                walk_with(&o, Arc::new(FailVictim(errno)), &[], &Progress::default()).unwrap();

            assert_eq!(stats.incomplete, None, "errno {errno}");
            assert_eq!(stats.errors, 1, "errno {errno}");
            assert_eq!(stats.files, 8, "errno {errno}");
        }
    }

    /// Detaches its image the first time a directory below the root is opened,
    /// then opens for real. See the serial twin in `walk`.
    struct DetachOnFirstOpen {
        image: std::sync::Mutex<DiskImage>,
        fired: std::sync::atomic::AtomicBool,
    }

    impl DirOpener for DetachOnFirstOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if !self.fired.swap(true, Ordering::SeqCst) {
                self.image.lock().unwrap().force_detach().unwrap();
            }
            OpenAt.open_dir_at(parent, name)
        }

        fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
            crate::walk::open_beneath(root, rel)
        }
    }

    #[test]
    fn a_volume_lost_mid_walk_stops_every_worker_as_volume_lost() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let image = DiskImage::attach(&mnt, 16).unwrap();
        for d in 0..40 {
            std::fs::create_dir(mnt.join(format!("d{d:02}"))).unwrap();
            std::fs::File::create(mnt.join(format!("d{d:02}/f"))).unwrap();
        }
        let mut o = opts(&mnt);
        o.workers = 4;
        // Precondition: undisturbed, the walk sees everything and is complete.
        let (_, whole) = walk(&o).unwrap();
        assert_eq!((whole.dirs, whole.files, whole.errors), (41, 40, 0));
        assert_eq!(whole.incomplete, None);

        let opener = Arc::new(DetachOnFirstOpen {
            image: std::sync::Mutex::new(image),
            fired: std::sync::atomic::AtomicBool::new(false),
        });
        let (_, stats) = walk_with(&o, Arc::clone(&opener), &[], &Progress::default()).unwrap();

        assert!(opener.fired.load(Ordering::SeqCst), "the detach never ran");
        assert_eq!(stats.incomplete, Some(Incomplete::VolumeLost));
        assert!(stats.errors >= 1);
        assert!(
            stats.files < 40,
            "{} files from a detached volume",
            stats.files
        );
    }

    /// The paths a user reads ("12 locations unreadable") are rebuilt
    /// separately from the node structure: by climbing the parent chain as far
    /// as the task's root and joining onto that task's own path. A climb
    /// that ran past the task root — which it would if it stopped only where
    /// `Arena::get` fails, since a worker that pops back a directory it
    /// published itself holds the task root in its own arena — would repeat
    /// part of the path.
    ///
    /// So: locked directories three and four levels down, sixteen workers,
    /// several walks, and the recorded set must equal the expected set
    /// exactly every time, whichever worker met which directory.
    #[test]
    fn unreadable_paths_are_exact_deep_in_stolen_subtrees() {
        let fx = deep_fixture();
        let mut locked: Vec<String> = (0..8).map(|i| format!("t{i}/a0/b2/c")).collect();
        locked.extend([0, 2, 4, 6].iter().map(|i| format!("t{i}/a1/b1")));
        for rel in &locked {
            fx.chmod(rel, 0o000).unwrap();
        }
        let mut want: Vec<_> = locked.iter().map(|rel| fx.path().join(rel)).collect();
        want.sort();
        let mut o = opts(fx.path());
        o.workers = 16;

        let (_, s) = walk_serial(&o).unwrap();
        let mut serial = s.unreadable.clone();
        serial.sort();
        assert_eq!(serial, want, "the serial oracle itself");

        for round in 0..5 {
            let (arenas, p) = walk(&o).unwrap();
            assert!(
                busy(&arenas) > 1,
                "round {round}: one worker did everything, so nothing was stolen"
            );
            let mut got = p.unreadable.clone();
            got.sort();
            assert_eq!(got, want, "round {round}");
            let flagged = arenas
                .iter()
                .flat_map(Arena::iter)
                .filter(|(_, n)| n.flags & crate::arena::FLAG_PERM_DENIED != 0)
                .count();
            assert_eq!(flagged, want.len(), "round {round}");
            assert_eq!((p.errors, p.incomplete), (0, None), "round {round}");
            assert_eq!((p.dirs, p.files), (s.dirs, s.files), "round {round}");
        }
    }

    #[test]
    fn parallel_walk_is_deterministic_after_freeze() {
        let fx = wide_fixture();

        let (first, first_stats) = walk(&opts(fx.path())).unwrap();
        let (second, second_stats) = walk(&opts(fx.path())).unwrap();
        // Both walks must really have been shared, or "deterministic" would
        // only mean that one worker walks the same way twice.
        assert!(busy(&first) > 1, "first walk: nothing was stolen");
        assert!(busy(&second) > 1, "second walk: nothing was stolen");
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
    /// nothing). Those two compose to the property.
    ///
    /// Nor does this test show that every worker shares one halt: if each had
    /// its own, worker 0's stats would still carry `NodeBudget` and the walk
    /// would still come back short, so both assertions here would pass. That
    /// the halt is shared is structural — `walk_with` builds one `Halt` and
    /// hands every worker the same `WalkerCtx` — and is checked by reading,
    /// not by this test.
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
            let (arenas, stats) = walk_with(
                &o,
                Arc::new(OpenAt),
                &[ArenaLimit::Cap(CAP)],
                &Progress::default(),
            )
            .unwrap();
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

        fn reopen_dir_beneath(&self, _root: RawFd, _rel: &CStr) -> Result<OwnedFd, c_int> {
            Err(libc::EMFILE)
        }
    }

    /// Descriptor exhaustion is not terminal, so the walk finishes and the
    /// flag survives the merge. This is the half of the precedence rule that a
    /// budget failure would otherwise hide.
    #[test]
    fn descriptor_exhaustion_survives_the_merge() {
        let fx = wide_fixture();

        let (_, stats) = walk_with(
            &opts(fx.path()),
            Arc::new(FailEveryOpen),
            &[],
            &Progress::default(),
        )
        .unwrap();

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

    /// Before the first reopen of anything below `victim/`, replaces `victim`
    /// — an *ancestor* of the directory being reopened, below the root — with
    /// a symlink to `decoy`, a different subtree on the same volume. The real
    /// `victim` is moved out of the walked tree entirely.
    ///
    /// Only reopens are intercepted, so the swap can only fire on the path
    /// that resolves more than one component; `fd`-relative child opens go
    /// straight to the real `openat`.
    struct SwapAncestorBeforeReopen {
        root: std::path::PathBuf,
        stash: std::path::PathBuf,
        fired: std::sync::atomic::AtomicU32,
        /// Reopens of a path under `victim/`, the swapping one included.
        reopened_under_victim: std::sync::atomic::AtomicU32,
        gate: Mutex<()>,
    }

    impl crate::walk::DirOpener for SwapAncestorBeforeReopen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            OpenAt.open_dir_at(parent, name)
        }

        fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
            if rel.to_bytes().starts_with(b"victim/") {
                self.reopened_under_victim.fetch_add(1, Ordering::Relaxed);
                let _one_at_a_time = self.gate.lock().unwrap();
                if self.fired.load(Ordering::Relaxed) == 0 {
                    std::fs::rename(self.root.join("victim"), &self.stash).unwrap();
                    // Relative, and its target is inside the fixture root.
                    std::os::unix::fs::symlink("decoy", self.root.join("victim")).unwrap();
                    self.fired.fetch_add(1, Ordering::Relaxed);
                }
            }
            crate::walk::open_beneath(root, rel)
        }
    }

    /// A published directory is reopened by path, so every component of that
    /// path is resolved again — and an ancestor swapped for a symlink between
    /// enumeration and reopen must not redirect the walk into another subtree.
    /// The serial walker never resolves more than one name at a time; this is
    /// the pool's equivalent of `walk::tests::directory_replaced_by_symlink_is_not_followed`,
    /// one level up.
    ///
    /// Each reopen through the swapped ancestor must fail (`ELOOP`, filed in
    /// `errors` per the walker's taxonomy) and `decoy`'s files must be counted
    /// exactly once, under `decoy`. With only `O_NOFOLLOW` the kernel follows
    /// the symlinked ancestor and walks `decoy/sN` again as `victim/sN`.
    /// Three rounds, each on a fresh tree, sixteen workers.
    #[test]
    fn a_swapped_ancestor_does_not_redirect_a_reopened_directory() {
        const SUBDIRS: usize = 6;
        const FILES: usize = 5;
        for round in 0..3 {
            let fx = Fixture::new().unwrap();
            let elsewhere = Fixture::new().unwrap();
            for k in 0..SUBDIRS {
                for f in 0..FILES {
                    fx.file(&format!("victim/s{k}/real{f}.bin"), 64).unwrap();
                    fx.file(&format!("decoy/s{k}/decoy{f}.bin"), 64).unwrap();
                }
            }
            let opener = Arc::new(SwapAncestorBeforeReopen {
                root: fx.path().to_path_buf(),
                stash: elsewhere.path().join("victim"),
                fired: std::sync::atomic::AtomicU32::new(0),
                reopened_under_victim: std::sync::atomic::AtomicU32::new(0),
                gate: Mutex::new(()),
            });
            let mut o = opts(fx.path());
            o.workers = 16;

            let (arenas, stats) =
                walk_with(&o, Arc::clone(&opener), &[], &Progress::default()).unwrap();

            // The precondition: the swap really fired, and it fired inside a
            // reopen-by-path, which is the only place this opener swaps.
            let reopened = opener.reopened_under_victim.load(Ordering::Relaxed);
            assert_eq!(
                opener.fired.load(Ordering::Relaxed),
                1,
                "round {round}: no swap"
            );
            assert!(
                reopened >= 1,
                "round {round}: nothing under victim/ was reopened"
            );
            assert!(fx.path().join("victim").is_symlink());

            let named = |prefix: &[u8]| {
                arenas
                    .iter()
                    .flat_map(|a| a.iter().map(move |(_, n)| a.name_bytes(n.name)))
                    .filter(|name| name.starts_with(prefix))
                    .count()
            };
            assert_eq!(
                named(b"decoy"),
                1 + SUBDIRS * FILES,
                "round {round}: decoy's contents were counted again under the \
                 swapped ancestor"
            );
            // Every reopen through the symlinked ancestor failed and was filed
            // as an ordinary error: nothing else in this tree can fail.
            assert_eq!(
                stats.errors,
                u64::from(reopened),
                "round {round}: {reopened} reopens went through the swapped ancestor"
            );
            assert_eq!(stats.incomplete, None, "round {round}");
            assert!(stats.unreadable.is_empty() && stats.skipped_mounts.is_empty());
            drop(elsewhere);
        }
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
        use Incomplete::{FdExhausted, MalformedBatch, NodeBudget, OutOfMemory, VolumeLost};

        // A terminal reason wins from either side, so the answer is the same
        // whichever worker is merged first.
        for terminal in [NodeBudget, OutOfMemory, Incomplete::Cancelled, VolumeLost] {
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

    /// A chain of directories built with `mkdirat` (because `std::fs` cannot
    /// address a path past `PATH_MAX`), with sibling leaf directories at the
    /// bottom, each holding one file. Removes itself, so the fixture's own
    /// cleanup never has to look at a path it could not name.
    struct DeepChain {
        /// One descriptor per level, outermost first: `levels[0]` is where
        /// the chain was built.
        levels: Vec<OwnedFd>,
        name: std::ffi::CString,
        /// Length of the deepest chain directory's path relative to `at`.
        rel_len: usize,
        /// Leaf directories under the deepest level, each holding `f.bin`.
        leaves: Vec<std::ffi::CString>,
    }

    const LEAF_FILE: &str = "f.bin";

    impl DeepChain {
        fn build(at: &Path, levels: usize, name_len: usize) -> DeepChain {
            use std::os::fd::{AsRawFd, FromRawFd};
            let name = std::ffi::CString::new("d".repeat(name_len)).unwrap();
            let mut chain = DeepChain {
                levels: vec![OwnedFd::from(std::fs::File::open(at).unwrap())],
                name,
                rel_len: 0,
                leaves: Vec::new(),
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
                chain.rel_len += if level == 0 { name_len } else { 1 + name_len };
            }
            chain
        }

        /// A leaf directory `leaf` under the deepest level, holding one file of
        /// exactly `bytes` bytes. Returns the leaf's path length relative to
        /// where the chain was built.
        fn add_leaf(&mut self, leaf: &str, bytes: usize) -> usize {
            use std::os::fd::{AsRawFd, FromRawFd};
            let deepest = self.levels.last().unwrap().as_raw_fd();
            let c = std::ffi::CString::new(leaf).unwrap();
            // SAFETY: an open directory and a live name.
            assert_eq!(unsafe { libc::mkdirat(deepest, c.as_ptr(), 0o755) }, 0);
            // SAFETY: same, and the directory was just created.
            let dir =
                unsafe { libc::openat(deepest, c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
            assert!(dir >= 0, "openat {leaf}");
            // SAFETY: `openat` just returned it.
            let dir = unsafe { OwnedFd::from_raw_fd(dir) };
            let f = std::ffi::CString::new(LEAF_FILE).unwrap();
            // SAFETY: an open directory and a live name.
            let fd = unsafe {
                libc::openat(
                    dir.as_raw_fd(),
                    f.as_ptr(),
                    libc::O_CREAT | libc::O_WRONLY | libc::O_CLOEXEC,
                    0o644 as libc::c_uint,
                )
            };
            assert!(fd >= 0, "create {leaf}/{LEAF_FILE}");
            let data = vec![7u8; bytes];
            // SAFETY: `fd` is an open writable file and `data` is live.
            assert_eq!(
                unsafe { libc::write(fd, data.as_ptr().cast(), data.len()) },
                data.len() as isize
            );
            // SAFETY: `fd` was opened above and is not used again.
            unsafe { libc::close(fd) };
            self.leaves.push(c);
            self.rel_len + 1 + leaf.len()
        }
    }

    impl Drop for DeepChain {
        fn drop(&mut self) {
            use std::os::fd::{AsRawFd, FromRawFd};
            // Bottom up, each removal relative to its parent's descriptor.
            let file = std::ffi::CString::new(LEAF_FILE).unwrap();
            if let Some(deepest) = self.levels.last() {
                let deepest = deepest.as_raw_fd();
                for leaf in &self.leaves {
                    // SAFETY: an open directory and live names throughout.
                    unsafe {
                        let dir = libc::openat(deepest, leaf.as_ptr(), libc::O_RDONLY);
                        if dir >= 0 {
                            let dir = OwnedFd::from_raw_fd(dir);
                            libc::unlinkat(dir.as_raw_fd(), file.as_ptr(), 0);
                        }
                        libc::unlinkat(deepest, leaf.as_ptr(), libc::AT_REMOVEDIR);
                    }
                }
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

    /// A directory whose path *relative to the scan root* exceeds what `openat`
    /// accepts cannot be published, because a published directory is reopened
    /// beneath the root by that relative path. `Walker::offer` keeps it and
    /// descends it locally with a single-name `openat` from its parent's
    /// descriptor instead — not dropped, and not charged to `errors`. Losing
    /// it would lose its bytes, the one failure direction nothing downstream
    /// can detect.
    ///
    /// The over-limit level has **two** sibling directories, because `offer`
    /// publishes nothing from a directory with fewer than two subdirectories;
    /// a one-child chain would never reach the branch under test. That the
    /// branch ran is asserted through `walk::KEPT_TOO_LONG`.
    #[test]
    fn a_directory_too_deep_to_name_is_kept_rather_than_lost() {
        const LEFT: usize = 4096;
        const RIGHT: usize = 8192;
        let fx = Fixture::new().unwrap();
        // 11 levels of 100-byte names: 1110 bytes relative to the root, so
        // each leaf below is past the 1023 an `openat` path may be.
        let mut chain = DeepChain::build(fx.path(), 11, 100);
        let left = chain.add_leaf("s0", LEFT);
        let right = chain.add_leaf("s1", RIGHT);
        assert!(
            left > crate::walk::MAX_PATH_BYTES && right > crate::walk::MAX_PATH_BYTES,
            "the leaves are {left} and {right} bytes below the root, which fits: \
             nothing is being tested"
        );
        let mut o = opts(fx.path());
        o.workers = 8;

        let (serial, s) = walk_serial(&o).unwrap();
        let kept_before = crate::walk::KEPT_TOO_LONG.load(Ordering::Relaxed);
        let (parallel, p) = walk(&o).unwrap();
        let kept = crate::walk::KEPT_TOO_LONG.load(Ordering::Relaxed) - kept_before;

        // Completeness first, so a regression reports what it lost.
        let want_logical = (LEFT + RIGHT) as u64;
        assert_eq!(s.files, 2);
        assert_eq!(totals(std::slice::from_ref(&serial)).1, want_logical);
        assert_eq!((p.errors, p.incomplete), (0, None), "a leaf was lost");
        assert_eq!((p.dirs, p.files), (s.dirs, s.files));
        assert_eq!(
            totals(&parallel).1,
            want_logical,
            "a leaf's bytes are missing"
        );
        assert_eq!(totals(std::slice::from_ref(&serial)), totals(&parallel));
        // Then the precondition: the keep branch is what made it complete.
        assert!(
            kept >= 1,
            "`offer` never declined a too-long directory, so this test did not \
             exercise the branch it is named for"
        );
        drop(chain);
    }

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
    fn unreadable_root_keeps_its_errno_through_the_pool() {
        let fx = Fixture::new().unwrap();
        fx.dir("locked").unwrap();
        fx.chmod("locked", 0o000).unwrap();
        let err = walk(&opts(&fx.path().join("locked")))
            .err()
            .expect("walk must fail");
        assert_eq!(crate::walk::os_errno(&err), Some(libc::EACCES));
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
        let mut original = libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        // SAFETY: `original` is a live, correctly sized `rlimit`.
        assert_eq!(
            unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut original) },
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

        // Put back the limits captured before the test changed them, before
        // asserting. This cannot fully succeed and is not asserted: an
        // unprivileged process may lower its hard limit but never raise it, so
        // restoring the original is refused (measured: `EPERM`), and so is
        // raising only the soft limit above the new hard one (`EINVAL`). The
        // process is left at 64/64, which is why this test is `#[ignore]`d and
        // runs in a process of its own.
        // SAFETY: `original` is a live, correctly sized `rlimit`.
        let _ = unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &original) };

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
