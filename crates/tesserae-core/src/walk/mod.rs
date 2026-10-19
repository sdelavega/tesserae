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

//! Single-threaded, fd-relative directory walker.
//!
//! This is the reference implementation, and it stays one: it is what
//! [`crate::pool::walk`] is compared against, so correctness and legibility
//! are the goals here, not speed. The pieces the parallel walker needs — the
//! shared [`NodeBudget`], the shared [`Halt`], the [`Share`] seam and
//! [`Walker`] itself — live here too, so that there is one walk and not
//! two.
//!
//! # Shape of the walk
//!
//! The walk is depth-first over an explicit stack of [`Frame`]s. It never
//! recurses, so a 512-deep tree cannot overflow the thread stack. A directory
//! is handled in two phases:
//!
//! 1. **Enumerate** it completely: call `getattrlistbulk(2)` until it returns
//!    0, turn every entry into an arena node, and remember which entries are
//!    directories worth entering.
//! 2. **Descend** into those directories one at a time with
//!    `openat(parent_fd, name, ...)`, each as a new frame on the stack.
//!
//! Enumerating a directory to exhaustion *before* descending is what lets one
//! read buffer serve the whole walk. Descending mid-batch would need a
//! buffer per level of the stack.
//!
//! # File descriptors are bounded by depth
//!
//! A frame owns its directory's fd as an [`OwnedFd`] (inside a `Dir`, which
//! announces the close on the worker's [`Lane`]), and a frame lives
//! exactly as long as its subtree is being walked, so the open descriptors at
//! any moment are the frames on the stack: one per ancestor of the directory
//! being scanned, plus that directory. The count is therefore bounded by the
//! tree's depth (at most `max_depth + 1`), not by the number of directories
//! visited. Because the fd is owned, it is closed on every exit path: a
//! finished frame is popped, and an early return (budget, out of memory)
//! drops the whole stack.
//!
//! # Sizes are passed through, never repaired
//!
//! A directory's entry carries no file-attribute group (see [`crate::parse`]),
//! so its `logical` and `allocated` are 0. That is the true value on APFS, not
//! a gap, and every node receives exactly what the parser reports. Directory
//! totals come from the bottom-up rollup in the freeze pass.
//!
//! # Errors
//!
//! | condition                          | effect                              |
//! |------------------------------------|-------------------------------------|
//! | `EPERM`, `EACCES`                  | path pushed to `unreadable`, node   |
//! |                                    | flagged [`FLAG_PERM_DENIED`]        |
//! | `ENOENT`, `ENOTDIR` (a race)       | `errors += 1`, the walk continues   |
//! | `EINTR`                            | the call is retried                 |
//! | `EMFILE`, `ENFILE`                 | `incomplete = FdExhausted`; that    |
//! |                                    | subtree is skipped, the walk goes on|
//! | `ENOMEM`                           | `incomplete = OutOfMemory`; likewise|
//! | a malformed batch                  | `incomplete = MalformedBatch`; the  |
//! |                                    | entries lost are added to           |
//! |                                    | `lost_entries`; the walk goes on    |
//! | any other errno (`EIO`, ...)       | `errors += 1`, the walk continues   |
//! | ... and the volume is gone         | `incomplete = VolumeLost`; the walk |
//! |                                    | stops (see below)                   |
//! | a mount boundary (below)           | path pushed to `skipped_mounts`;    |
//! |                                    | not entered, not an error           |
//! | node budget or arena memory out    | the walk stops: [`Incomplete`]      |
//! | the root cannot be opened          | `Err` from [`walk_serial`]          |
//! | the root opens, enumeration fails  | `Ok`; the root is in `unreadable`   |
//! |                                    | (EPERM/EACCES) or counted in `errors`|
//!
//! The split is by what the failure does to the totals. A race (`ENOENT`) or
//! one directory's I/O fault loses one directory at most and says nothing about
//! the rest of the walk, so it is counted. A resource shortfall or a batch the
//! parser rejected makes the result systematically short, so it is flagged in
//! `incomplete` where a caller cannot miss it.
//!
//! A node-budget failure is terminal: `push_name` has already stored the
//! entry's name, so a failed `push_node` leaves orphaned name bytes in the
//! arena, and carrying on would only add more.
//!
//! # A volume that disappears
//!
//! Measured on macOS 27.2 with `hdiutil detach -force` under a running walk:
//! descriptors that were open on the volume stay open but answer `ENOTDIR` to
//! `getattrlistbulk` and to `openat`, `EBADF` to `fstat` and `ENOTSUP` to
//! `fstatfs`; a descriptor on the parent volume is unaffected. `ENOTDIR` is
//! also what a directory replaced by a file mid-walk gives, so the errno alone
//! cannot tell churn from loss, and booking it as churn returned about a third
//! of a tree as a finished scan. So a directory-level failure with one of the
//! errnos a lost volume can produce (`ENOENT`, `ENOTDIR`, `EIO`, `ENXIO`,
//! `ENODEV`, `EBADF`, `ENOTSUP`) is still counted in `errors`, and then the
//! scan root's own descriptor is asked which volume it is on (`fstatfs`, the
//! same call the boundary check uses). If that fails, or names a volume other
//! than the one recorded at the start, the walk stops with
//! [`Incomplete::VolumeLost`]. On a live volume the answer is the recorded
//! volume and the walk goes on, exactly as before. The check runs only after a
//! failure, so a healthy scan pays nothing for it.
//!
//! # Volume boundary
//!
//! A scan stays on the volume it was pointed at. Each child is opened, then its
//! volume is read from the open descriptor (`Walker::admit`) and compared with
//! the root's before a single entry is read. A child on another volume is
//! recorded in `skipped_mounts` and its descriptor dropped; it stays a directory
//! node with no children, so the tree shows the mount point as an empty folder
//! rather than omitting it. The policy and the reasons the check reads the
//! descriptor rather than the entry are in [`crate::boundary`].
//!
//! # Hardlinks
//!
//! A file with more than one link would otherwise be counted once per path.
//! When an entry's `link_count` is above one the walker claims its
//! `(dev, inode)` in an [`InodeSet`] as it pushes the node: the first claimant
//! keeps its sizes, every later one is stored with zero sizes and
//! [`FLAG_HARDLINK_DUP`] and counted in [`WalkStats::hardlink_dups`]. The gate keeps
//! the set nearly empty, and directories (`link_count == 0`) never enter it.
//! The values come from the entry at push time, so the node stores neither.
//! If the set cannot reserve memory for a new inode, that link keeps its bytes
//! (the total errs high) and `incomplete` is set to
//! [`Incomplete::OutOfMemory`], like any other resource shortfall.
//!
//! The set is built per walk and passed by reference, so the parallel walker
//! can hand one instance to every worker. Because "first" is whichever link is
//! reached first, only the *total* is invariant, not which node holds the
//! bytes; see [`crate::dedup`].
//!
//! # The node budget is shared, not per arena
//!
//! [`Arena`] can enforce a ceiling of its own, but the walk does not use it:
//! with one arena per worker a per-arena ceiling would multiply by the worker
//! count, turning a 25M-node limit into 400M nodes and about 16 GB. The limit
//! lives in a [`NodeBudget`], one shared atomic counter every worker draws
//! from, and each arena is created with no ceiling of its own. A serial walk
//! builds a [`NodeBudget`] of its own, which nothing else draws on, so its
//! behaviour is unchanged.
//!
//! The budget is *not* divided evenly between workers: an unbalanced tree is
//! the normal case, so a worker given a sixteenth of the budget would stop
//! while the others still had room.
//!
//! # Any terminal failure stops every worker
//!
//! A failed `push_node` is terminal for the whole walk, not just the worker
//! that saw it, and [`Halt`] is how that is arranged. The reason is
//! [`InodeSet`]: `try_claim` records an inode *before* the node is pushed, so
//! if one worker's push failed while the others carried on against the same
//! set, that inode would be claimed by a node that was never stored and its
//! bytes would be lost. Every other failure path here is arranged to
//! over-count, because the residual is signed and an over-count is
//! representable; bytes that vanish are the one direction nothing downstream
//! can detect.
//!
//! # Sharing work
//!
//! A worker descends depth-first through [`Frame`]s, as the serial walk does,
//! and the directories it does *not* descend immediately are offered to the
//! pool through [`Share`]. Those carry a path *relative to the scan root*,
//! because the descriptor chain that `openat` needs belongs to the frame that
//! built it. Whoever takes one reopens it beneath the root's descriptor, which
//! stays open for the whole walk, with [`open_beneath`]: a symlink in any
//! component of that path fails the open rather than redirecting the walk. A
//! relative path longer than `PATH_MAX` cannot be reopened that way, so such a
//! directory is kept and descended locally instead; nothing is dropped.
//!
//! # The arena is behind a lock that no syscall is made under
//!
//! A worker's arena and stats live in its [`Lane`], not on its stack, so that
//! a parallel walk can return without a worker blocked inside a syscall and
//! still have that worker's nodes. The walker holds the lane's lock only
//! while it changes the slot, and announces every syscall on a directory in
//! the lane while it lasts. [`Lane`] has the protocol and why it cannot
//! deadlock; [`WalkOptions::stall_timeout`] has what it buys.

mod coordination;
mod errors;
mod lane;
mod open;

pub(crate) use coordination::{Halt, NodeBudget, Share, WalkerCtx};
pub use errors::{os_errno, with_context, Incomplete};
pub(crate) use lane::Lane;
#[allow(unused_imports)] // linked from the docs above; the tests elsewhere call it
pub(crate) use open::open_beneath;
pub(crate) use open::{open_root, DirOpener, OpenAt};

use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::raw::c_int;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

#[cfg(test)]
use crate::arena::ArenaError;
#[cfg(doc)]
use crate::arena::FLAG_PERM_DENIED;
use crate::arena::{Arena, ScanId, ScanNode, FLAG_HARDLINK_DUP};
use crate::attrs::{scan_attrlist, SCAN_OPTIONS};
use crate::boundary::{should_descend, volume_of, SkipReason, VolumeId};
use crate::dedup::{InodeSet, ReserveFailed};
use crate::parse::{entries, ObjType, RawEntry};
use crate::progress::Progress;
use coordination::BUDGET_CHUNK;
use lane::{Dir, Held, Slot};
use open::{errno, nul_terminated, with_cstr};

/// The default scan root: the user-visible data volume on modern macOS.
const DEFAULT_ROOT: &str = "/System/Volumes/Data";
const DEFAULT_MAX_DEPTH: u16 = 512;
const DEFAULT_NODE_BUDGET: u64 = 25_000_000;
/// Spec section 11: "a worker making no progress for ~15s".
const DEFAULT_STALL_TIMEOUT: Duration = Duration::from_secs(15);
/// 256 KiB. Measured: no knee between 64 KiB and 1 MiB (27.6 / 27.3 / 27.6 s),
/// so this is the middle of a flat region rather than a tuned value.
const DEFAULT_BUFFER_BYTES: usize = 256 * 1024;
/// Below this a buffer cannot be trusted to hold one entry. Measured: the
/// kernel answers `ERANGE` for 64 bytes and first fits a one-file entry at 80,
/// and an entry is ~72 bytes of fixed fields plus its name, which can run to
/// `PATH_MAX`.
const MIN_BUFFER_BYTES: usize = 2048;
/// Longest string that can be handed to `openat` without allocating: either a
/// single entry name or a whole path. `PATH_MAX` is 1024 including the NUL, so
/// anything longer is already unopenable.
pub(crate) const MAX_PATH_BYTES: usize = 1023;

/// Times `Walker::offer` kept a directory because its relative path was too
/// long to publish. Test-only, so a test can assert the branch it means to
/// cover actually ran. Global, so a test reads the change across its own walk;
/// only a fixture with a path over `MAX_PATH_BYTES` moves it.
#[cfg(test)]
pub(crate) static KEPT_TOO_LONG: AtomicU64 = AtomicU64::new(0);
/// Pushes refused by a test's injected arena failure (see [`Lane::fail_after`]).
/// Test-only and global for the same reason as [`KEPT_TOO_LONG`].
#[cfg(test)]
pub(crate) static OOM_INJECTED: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone)]
pub struct WalkOptions {
    pub root: PathBuf,
    /// The deepest level the walk records. A directory at exactly this depth
    /// is recorded but not entered, so nothing deeper exists. The root is
    /// depth 0.
    pub max_depth: u16,
    /// Most nodes the whole walk may store, however many workers it runs.
    /// Enforced by a shared counter, not by the arenas; see the module note.
    pub node_budget: u64,
    /// Size of the `getattrlistbulk` output buffer.
    pub buffer_bytes: usize,
    /// Whether to descend into network and other non-local mounts. A mount on
    /// another *local* volume is never entered, whatever this says; see
    /// [`crate::boundary`].
    pub include_non_local: bool,
    /// Worker thread count. Read only by [`crate::pool::walk`], which may
    /// reduce it to fit the descriptor limit; the serial walker ignores it.
    pub workers: usize,
    /// How long the whole walk may go without completing a single syscall
    /// before it is declared stalled. Read only by the parallel walk; the
    /// serial walker has no watchdog.
    ///
    /// A hanging local volume blocks `openat` uninterruptibly (spec section
    /// 11). When no worker has finished an open, a read, an `fstatfs` or a
    /// close for this long and one of them is still inside one, the walk
    /// records that directory's path in [`WalkStats::stalled_at`],
    /// sets [`Incomplete::Stalled`], and returns what it has.
    ///
    /// # The blocked thread is abandoned, not stopped
    ///
    /// A thread blocked in an uninterruptible syscall cannot be killed or
    /// woken from userspace. So the walk is abandoned rather than stopped:
    /// the other workers stop and hand back their results, the blocked
    /// worker's arena is taken from it (it is never locked across a syscall,
    /// so it can be), and the call returns. The blocked thread is left
    /// behind and leaks — with its read buffer and the descriptors of the
    /// directories it holds open — until its syscall returns or the process
    /// exits. When the syscall does return, the thread finds its arena gone
    /// and exits without touching anything. This is a deliberate limitation
    /// of the design, stated plainly, not a bug to fix later. The same
    /// abandonment happens after any other reason the walk ends early —
    /// [`crate::progress::Progress::cancel`] above all — so a cancel returns
    /// at once even while a worker is blocked.
    ///
    /// What the result is missing is the blocked worker's whole unfinished
    /// descent, not just the one directory: every directory on its stack has
    /// its own node, but the subdirectories it had enumerated and not yet
    /// entered are recorded as empty directories, and the blocked directory
    /// itself has no children.
    ///
    /// The watchdog watches the walk, not the root: the root is opened on the
    /// calling thread before any worker exists, so a root that hangs in
    /// `open` hangs the call. That is out of scope here.
    ///
    /// Total progress is what is watched, so a slow volume that keeps
    /// completing syscalls never trips it, and one blocked worker is not
    /// declared stalled while the others still have work: it is reported
    /// once everything else is done and the walk is waiting only on it.
    pub stall_timeout: Duration,
}

impl Default for WalkOptions {
    fn default() -> Self {
        WalkOptions {
            root: PathBuf::from(DEFAULT_ROOT),
            max_depth: DEFAULT_MAX_DEPTH,
            node_budget: DEFAULT_NODE_BUDGET,
            buffer_bytes: DEFAULT_BUFFER_BYTES,
            include_non_local: false,
            workers: std::thread::available_parallelism()
                .map_or(4, |n| n.get())
                .clamp(4, 16),
            stall_timeout: DEFAULT_STALL_TIMEOUT,
        }
    }
}

/// What a walk saw. Counts cover nodes that were actually pushed.
#[derive(Debug, Default)]
pub struct WalkStats {
    /// Directory nodes, the root included, whether or not they were entered.
    pub dirs: u64,
    /// Every non-directory node: regular files, symlinks (never followed) and
    /// special files.
    pub files: u64,
    /// Failures that were absorbed and did not stop the walk: races
    /// (`ENOENT`, `ENOTDIR`) and any other errno that is neither a permission
    /// denial nor fatal. (A malformed batch is not counted here: see
    /// [`WalkStats::lost_entries`] and [`Incomplete::MalformedBatch`].)
    pub errors: u64,
    /// Directories that could not be read for lack of permission. Their sizes
    /// are unknowable, so they hold no children and no bytes.
    pub unreadable: Vec<PathBuf>,
    /// Directories not entered because they are a different volume's mount
    /// point or a non-local mount the caller did not opt into. Each is still a
    /// directory node (`dirs` counts it), holding no children and no bytes.
    /// This is policy, not failure: it is not in `errors` and does not set
    /// `incomplete`. The reason says what the user could do about it: an
    /// [`SkipReason::OtherVolume`] is another local disk (scan it separately),
    /// a [`SkipReason::NonLocalMount`] is a network or other non-local mount
    /// (opt in with `include_non_local`).
    pub skipped_mounts: Vec<(PathBuf, SkipReason)>,
    /// Directories recorded at `max_depth` and therefore not entered.
    pub depth_capped: u64,
    /// Entries the kernel returned that the parser rejected or never reached
    /// (those after a bad entry in the same batch). Nonzero means
    /// `incomplete` was set to [`Incomplete::MalformedBatch`], though a
    /// terminal reason may have replaced it since.
    pub lost_entries: u64,
    /// Hardlinks counted as zero because an earlier link to the same inode
    /// already carried the bytes. Each has [`FLAG_HARDLINK_DUP`] set. Also included
    /// in `files`: the entry exists, it just adds nothing to the total.
    pub hardlink_dups: u64,
    /// The directory a worker was blocked inside a syscall on when the
    /// watchdog declared the walk stalled: the scan root as the caller named
    /// it, joined with the path below it. Absolute only if the root was; the
    /// root is not canonicalised. Set only with
    /// [`Incomplete::Stalled`]; see [`WalkOptions::stall_timeout`].
    pub stalled_at: Option<PathBuf>,
    /// `Some` if the result is partial and why.
    pub incomplete: Option<Incomplete>,
}

/// Walk `opts.root` on the calling thread.
///
/// Open file descriptors are bounded by tree depth (at most `max_depth + 1`),
/// so callers walking deep trees should raise `RLIMIT_NOFILE` first, as the
/// parallel walker does; a walk that runs out reports
/// [`Incomplete::FdExhausted`].
///
/// `Err` means nothing could be scanned: bad options, or the root itself could
/// not be opened. Once the root is open every problem is absorbed into the
/// [`WalkStats`] instead, and a walk cut short returns `Ok` with
/// [`WalkStats::incomplete`] set and the nodes gathered so far.
pub fn walk_serial(opts: &WalkOptions) -> io::Result<(Arena, WalkStats)> {
    walk_serial_with(opts, &OpenAt)
}

pub(crate) fn walk_serial_with<O: DirOpener>(
    opts: &WalkOptions,
    opener: &O,
) -> io::Result<(Arena, WalkStats)> {
    // One walker, so a handful of shards is plenty; the type is sharded for
    // the parallel walker's sake, which passes its own shared set instead.
    walk_serial_with_inodes(opts, opener, &InodeSet::new(16))
}

/// [`walk_serial_with`] with the caller's [`InodeSet`], so a test can inspect
/// it afterwards and the parallel walker can share one across threads.
pub(crate) fn walk_serial_with_inodes<O: DirOpener>(
    opts: &WalkOptions,
    opener: &O,
    inodes: &InodeSet,
) -> io::Result<(Arena, WalkStats)> {
    check_options(opts)?;
    let root_fd = open_root(opts)?;
    let root_volume = root_volume_of(opts, &root_fd)?;
    // A budget and a halt for one walker: nothing else draws on the counter,
    // and nothing is ever there to raise the halt. Counters nobody reads, and
    // a lane nobody else locks: see `Lane` on why the serial walk keeps the
    // lock rather than a lock-free twin of the walker.
    let budget = NodeBudget::new(opts.node_budget);
    let halt = Halt::new();
    let progress = Progress::default();
    let lane = Lane::new(Arena::new(0, u64::MAX));
    // Nothing is ever reopened by path in a serial walk, so the root's
    // descriptor belongs to the root frame and closes with it. This duplicate
    // is only ever asked which volume it is on (`Walker::volume_lost`), and
    // outlives the frame's descriptor.
    let root_probe = root_fd
        .try_clone()
        .map_err(|e| with_context(e, format!("dup {}", opts.root.display())))?;
    let ctx = WalkerCtx {
        opener,
        inodes,
        budget: &budget,
        halt: &halt,
        progress: &progress,
        root_volume,
        root_path: &opts.root,
        root_dir: Some(root_probe.as_fd()),
    };
    let mut walker = Walker::new(&ctx, None, opts, &lane)?;
    // `run_root` records the reason in the stats; a serial walk has no other
    // worker to tell.
    let _ = walker.run_root(root_fd);
    Ok(walker.finish())
}

/// Reject options no walk can honour. Separate so the parallel walker fails
/// the same way, before it raises limits or spawns anything.
pub(crate) fn check_options(opts: &WalkOptions) -> io::Result<()> {
    if opts.buffer_bytes < MIN_BUFFER_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "buffer_bytes {} is below the {MIN_BUFFER_BYTES}-byte minimum",
                opts.buffer_bytes
            ),
        ));
    }
    Ok(())
}

/// The volume the scan root is on, with the root's path in the error.
pub(crate) fn root_volume_of(opts: &WalkOptions, root_fd: &OwnedFd) -> io::Result<VolumeId> {
    volume_of(root_fd.as_raw_fd())
        .map_err(|e| with_context(e, format!("fstatfs {}", opts.root.display())))
}

/// One directory being walked.
struct Frame<'a> {
    /// This directory, open. Dropping the frame closes it.
    dir: Dir<'a>,
    depth: u16,
    /// Subdirectories found by enumeration and not yet entered.
    children: Vec<ScanId>,
    /// Index into `children` of the next one to enter.
    next: usize,
}

/// One thread walking. A serial walk has one; the pool has one per worker,
/// each with its own lane (arena and stats) and read buffer.
pub(crate) struct Walker<'a, O> {
    opener: &'a O,
    inodes: &'a InodeSet,
    budget: &'a NodeBudget,
    halt: &'a Halt,
    progress: &'a Progress,
    /// `None` in a serial walk; the pool's handle otherwise.
    share: Option<&'a (dyn Share + 'a)>,
    /// Units drawn from `budget` and not yet spent.
    allowance: u64,
    /// The `getattrlistbulk` output buffer, reused for every directory.
    buf: Vec<u8>,
    attrlist: libc::attrlist,
    max_depth: u16,
    root_volume: VolumeId,
    include_non_local: bool,
    root_path: &'a Path,
    root_dir: Option<BorrowedFd<'a>>,
    /// The node this worker's current task is rooted at, and that directory's
    /// path *relative to the scan root*. A path is rebuilt by climbing the
    /// parent chain only as far as `task_root`, then joining the result onto
    /// `task_rel`, because above the task root the chain may leave this arena.
    /// For the root task `task_root` is the root node itself and `task_rel` is
    /// empty, so the climb stops just below the root.
    task_root: ScanId,
    task_rel: Arc<Path>,
    /// This worker's arena and stats, locked, and its syscall announcements.
    lane: &'a Lane,
}

impl<'a, O: DirOpener> Walker<'a, O> {
    /// A worker filling the arena in `lane`, with its own read buffer. The
    /// arena should have no ceiling of its own: the limit is `ctx.budget`,
    /// shared with every other worker.
    pub(crate) fn new(
        ctx: &WalkerCtx<'a, O>,
        share: Option<&'a (dyn Share + 'a)>,
        opts: &WalkOptions,
        lane: &'a Lane,
    ) -> io::Result<Self> {
        check_options(opts)?;
        let mut buf = Vec::new();
        buf.try_reserve_exact(opts.buffer_bytes)
            .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
        buf.resize(opts.buffer_bytes, 0);
        Ok(Walker {
            opener: ctx.opener,
            inodes: ctx.inodes,
            budget: ctx.budget,
            halt: ctx.halt,
            progress: ctx.progress,
            share,
            allowance: 0,
            buf,
            attrlist: scan_attrlist(),
            max_depth: opts.max_depth,
            root_volume: ctx.root_volume,
            include_non_local: opts.include_non_local,
            root_path: ctx.root_path,
            root_dir: ctx.root_dir,
            task_root: ScanId::NONE,
            task_rel: Arc::from(Path::new("")),
            lane,
        })
    }

    /// The arena and stats of a walk that is over. For a serial walk, and
    /// tests: the pool's supervisor takes each worker's lane itself, because
    /// it cannot wait for a worker that may never come back.
    ///
    /// # Panics
    ///
    /// If the lane was taken already, which only the pool's supervisor does.
    pub(crate) fn finish(self) -> (Arena, WalkStats) {
        let (arena, stats, _) = self
            .lane
            .take()
            .expect("only the pool's supervisor takes a lane");
        (arena, stats)
    }

    /// This worker's slot, locked — unless the walk is over.
    ///
    /// The halt is checked *before* the lock is taken, so a worker coming
    /// back from a syscall after the walk ended does not even contend for its
    /// lane; and a lane already taken by the supervisor is refused, so a
    /// worker it abandoned can never change what the caller was handed. Every
    /// directory boundary and every batch goes through here, which is what
    /// makes them the points a cancel is observed at.
    fn lock(&self) -> Result<Held<'a>, Incomplete> {
        if let Some(why) = self.halt.reason() {
            return Err(why);
        }
        // Taken only after the halt is raised, so the reason is there.
        self.lane
            .lock_raw()
            .ok_or_else(|| self.halt.reason().unwrap_or(Incomplete::Cancelled))
    }

    /// Add what `slot` has stored since it last published to the walk's
    /// counters. Once per batch, not per entry: four atomics every worker
    /// writes would otherwise be the hottest cache line in the walk.
    fn publish(&self, slot: &mut Slot) {
        let now = slot.counts();
        self.progress.add(now.since(slot.published));
        slot.published = now;
    }

    /// Walk the scan root, whose node has not been pushed yet and whose
    /// descriptor is already open. The root node's name is the root path as
    /// the caller gave it.
    pub(crate) fn run_root(&mut self, root_fd: OwnedFd) -> Result<(), Incomplete> {
        self.task_root = ScanId::NONE;
        self.task_rel = Arc::from(Path::new(""));
        let root_name = self.root_path.as_os_str().as_bytes();
        self.guard(|w| {
            let root = {
                let mut slot = w.lock()?;
                let root = w.push(&mut slot, root_name, ScanId::NONE, None)?;
                if w.max_depth == 0 {
                    slot.stats.depth_capped += 1;
                }
                w.publish(&mut slot);
                root
            };
            w.task_root = root;
            // From here the root's descriptor closes like any other.
            let dir = Dir::new(root_fd, root, w.lane);
            if w.max_depth == 0 {
                return Ok(());
            }
            w.subtree(dir, root, 0)
        })
    }

    /// Walk a directory a worker enumerated and published: `node` is already
    /// recorded (in whichever arena pushed it), `rel` is where it lives
    /// relative to the scan root, and `depth` is its absolute depth.
    pub(crate) fn run_dir(
        &mut self,
        rel: Arc<Path>,
        node: ScanId,
        depth: u16,
    ) -> Result<(), Incomplete> {
        self.task_root = node;
        self.task_rel = rel;
        self.guard(|w| {
            let rel = Arc::clone(&w.task_rel);
            match w.reopen(node, &rel) {
                Ok(dir) => {
                    if w.admit(node, &dir)? {
                        w.subtree(dir, node, depth)?;
                    }
                    Ok(())
                }
                Err(e) => w.note_error(node, e),
            }
        })
    }

    /// Run a task, recording a terminal reason in this worker's stats and
    /// telling every other worker to stop.
    ///
    /// Overwriting `incomplete` rather than inserting is deliberate and is
    /// what the serial walk has always done: the field names what *stopped*
    /// the walk, so a terminal reason outranks anything that was flagged and
    /// walked past. A worker whose lane was taken while it was in a syscall
    /// records nothing: the result is no longer its to change.
    fn guard(
        &mut self,
        task: impl FnOnce(&mut Self) -> Result<(), Incomplete>,
    ) -> Result<(), Incomplete> {
        let outcome = task(self);
        if let Err(why) = outcome {
            if let Some(mut slot) = self.lane.lock_raw() {
                slot.stats.incomplete = Some(why);
            }
            self.halt.raise(why);
        }
        outcome
    }

    /// Depth-first over an explicit stack, from `id` (open as `dir`) down.
    fn subtree(&mut self, dir: Dir<'a>, id: ScanId, depth: u16) -> Result<(), Incomplete> {
        let mut stack: Vec<Frame<'a>> = Vec::new();
        self.enter(&mut stack, dir, id, depth)?;

        while let Some(top) = stack.last_mut() {
            let Some(&child) = top.children.get(top.next) else {
                // Subtree finished: popping drops the frame and closes its fd.
                stack.pop();
                continue;
            };
            top.next += 1;
            let (parent_fd, depth) = (top.dir.raw(), top.depth + 1);
            match self.open_child(parent_fd, child)? {
                Ok(dir) => {
                    if self.admit(child, &dir)? {
                        self.enter(&mut stack, dir, child, depth)?;
                    }
                    // Otherwise `dir` drops here, closing the directory the
                    // boundary refused without a single read from it.
                }
                Err(e) => self.note_error(child, e)?,
            }
        }
        Ok(())
    }

    /// Whether to enter `id`, the directory just opened as `dir`, or stay out
    /// because it is across a volume boundary. The one place the boundary
    /// policy meets the walk, and it runs after the open and before any read.
    ///
    /// The volume comes from the descriptor, not from the entry the parent's
    /// `getattrlistbulk` returned: for a mount point that entry carries the
    /// parent's device, not the mounted volume's (see [`crate::boundary`]), so
    /// comparing it could never detect a crossing. The descriptor is also the
    /// directory the walk is about to read, so there is no path to re-resolve
    /// and nothing to swap between the check and the descent.
    ///
    /// # The root's own volume is exempt, deliberately
    ///
    /// A directory on the root's own volume is entered without asking whether
    /// that filesystem is local, even when `include_non_local` is `false` and
    /// the root is, say, an SMB share. This is a decision, not an oversight.
    /// `include_non_local` means "cross *into* non-local mounts encountered
    /// along the way", not "refuse to scan what the caller pointed at": a user
    /// who names a network path as the root has expressed explicit intent, and
    /// returning an empty tree with every subdirectory "skipped" would be
    /// absurd. The hazard the flag guards against is wandering mid-scan into a
    /// remote mount that is dead, where `openat` blocks uninterruptibly. A
    /// root the caller named fails at the very first open, immediately and
    /// visibly, so it needs no such protection. Only a change of volume is a
    /// crossing. (`boundary::should_descend` still refuses a same-volume
    /// non-local directory when asked; the walker simply does not ask.)
    ///
    /// Cost: one `fstatfs` per directory (about 0.4 us against several us for
    /// the `openat` it follows), plus a second only at a crossing.
    ///
    /// Returns `Ok(true)` to enter, `Ok(false)` to skip (recorded in
    /// `skipped_mounts`, or in the error counters if the descriptor cannot be
    /// examined). `Err` is only for the terminal reasons.
    fn admit(&mut self, id: ScanId, dir: &Dir<'_>) -> Result<bool, Incomplete> {
        let raw = dir.raw();
        let volume = match self.lane.during(id, || volume_of(raw)) {
            Ok(volume) => volume,
            Err(e) => {
                self.note_error(id, e.raw_os_error().unwrap_or(libc::EIO))?;
                return Ok(false);
            }
        };
        if volume == self.root_volume {
            return Ok(true);
        }
        let (root_volume, include_non_local) = (self.root_volume, self.include_non_local);
        let Err(reason) = self.lane.during(id, || {
            should_descend(root_volume, volume, raw, include_non_local)
        }) else {
            return Ok(true);
        };
        let mut slot = self.lock()?;
        let path = self.report_path_of(&slot, id)?;
        slot.stats
            .skipped_mounts
            .try_reserve(1)
            .map_err(|_| Incomplete::OutOfMemory)?;
        slot.stats.skipped_mounts.push((path, reason));
        Ok(false)
    }

    /// Enumerate `id`'s directory, offer what the pool wants of it, then push
    /// it as a frame to be descended.
    fn enter(
        &mut self,
        stack: &mut Vec<Frame<'a>>,
        dir: Dir<'a>,
        id: ScanId,
        depth: u16,
    ) -> Result<(), Incomplete> {
        let mut frame = Frame {
            dir,
            depth,
            children: Vec::new(),
            next: 0,
        };
        self.enumerate(&mut frame, id)?;
        self.offer(&mut frame, id)?;
        stack.try_reserve(1).map_err(|_| Incomplete::OutOfMemory)?;
        stack.push(frame);
        Ok(())
    }

    /// Hand this directory's subdirectories beyond the first to the pool,
    /// while it wants more. Breadth is what is shared; the one kept is what
    /// this worker descends next, so its open descriptors stay a chain down
    /// the tree rather than a fan across it.
    ///
    /// Nothing is published before the frame has been enumerated to
    /// exhaustion, and `frame.next` is still 0, so taking children off the
    /// back cannot skip one. A subdirectory whose path relative to the scan
    /// root would exceed `PATH_MAX` is kept: it could not be reopened by that
    /// path, and losing it would lose its bytes.
    ///
    /// The names come from the arena, so the slot is locked for the whole
    /// offer. Publishing makes no syscall, so nothing here can block.
    fn offer(&self, frame: &mut Frame<'_>, dir: ScanId) -> Result<(), Incomplete> {
        debug_assert_eq!(frame.next, 0, "offer runs before any descent");
        let Some(share) = self.share else {
            return Ok(());
        };
        if frame.children.len() < 2 || !share.wants_work() {
            return Ok(());
        }
        let slot = self.lock()?;
        let dir_rel = self.rel_of(&slot, dir)?;
        let depth = frame.depth + 1;
        while frame.children.len() > 1 && share.wants_work() {
            let &id = frame.children.last().expect("len > 1");
            let Some(rel) = self.child_rel(&slot, &dir_rel, id) else {
                // Too long to hand to `openat`: kept, and descended here with
                // a single-name `openat` from this frame's descriptor.
                #[cfg(test)]
                KEPT_TOO_LONG.fetch_add(1, Ordering::Relaxed);
                break;
            };
            frame.children.pop();
            share.publish(rel, id, depth);
        }
        Ok(())
    }

    /// `dir`'s child `id` as a path relative to the scan root, or `None` if it
    /// would not fit in the `PATH_MAX` an `openat` beneath the root accepts.
    /// The limit applies to the relative path, because that is the string the
    /// reopen hands the kernel; the root's own absolute path does not count.
    ///
    /// # The one infallible allocation on the hot path
    ///
    /// Everything else the walk allocates per directory goes through
    /// `try_reserve` and turns a refusal into [`Incomplete::OutOfMemory`].
    /// (crossbeam's deque buffers also allocate infallibly, but once per
    /// worker before the walk starts: a buffer starts at 64 slots and is
    /// regrown only when a push finds it full, and a worker stops publishing
    /// at 32.) This does not: `to_path_buf` and `Arc::from` allocate through
    /// the aborting path, and stable Rust has no fallible way to build an
    /// `Arc`. Under near-total memory exhaustion
    /// this can abort the process. Its small size is no protection — a
    /// 100-byte request can be refused after a megabyte chunk succeeded — so
    /// this is a residual risk, accepted because there is no fallible
    /// alternative, not one argued away.
    fn child_rel(&self, slot: &Slot, dir: &Path, id: ScanId) -> Option<Arc<Path>> {
        let node = slot.arena.get(id)?;
        let name = slot.arena.name_bytes(node.name);
        let dir_len = dir.as_os_str().as_bytes().len();
        let len = if dir_len == 0 { 0 } else { dir_len + 1 } + name.len();
        if len > MAX_PATH_BYTES {
            return None;
        }
        let mut rel = dir.to_path_buf();
        rel.push(OsStr::from_bytes(name));
        Some(Arc::from(rel))
    }

    /// The path of `id` relative to the scan root; empty for the root. `id`
    /// must be the current task's root or a node below it.
    fn rel_of(&self, slot: &Slot, id: ScanId) -> Result<PathBuf, Incomplete> {
        node_path(&slot.arena, id, &self.task_rel, self.task_root)
    }

    /// The path of `id` as a user reads it: the scan root as the caller named
    /// it, joined with [`Walker::rel_of`]. What `unreadable` and
    /// `skipped_mounts` record.
    fn report_path_of(&self, slot: &Slot, id: ScanId) -> Result<PathBuf, Incomplete> {
        let rel = self.rel_of(slot, id)?;
        join_root(self.root_path, rel.as_os_str().as_bytes())
    }

    /// Drain one directory: call `getattrlistbulk` until it reports no more.
    ///
    /// A single call does not drain a directory. It fills the buffer with
    /// whole entries and stops, and the fd's offset carries over to the next
    /// call. Only a return of 0 means the directory is exhausted.
    ///
    /// The call runs with the slot unlocked; each batch it returns is then
    /// pushed, and published to the counters, under one lock.
    fn enumerate(&mut self, frame: &mut Frame<'_>, dir: ScanId) -> Result<(), Incomplete> {
        let lane = self.lane;
        loop {
            let fd = frame.dir.raw();
            let (attrlist, buf) = (&mut self.attrlist, &mut self.buf);
            let n = lane.during(dir, || {
                // SAFETY: `attrlist` and `buf` are live, `buf.len()` is its
                // true size and the fd is open.
                let n = unsafe {
                    libc::getattrlistbulk(
                        fd,
                        (attrlist as *mut libc::attrlist).cast(),
                        buf.as_mut_ptr().cast(),
                        buf.len(),
                        SCAN_OPTIONS,
                    )
                };
                // Read before anything else can overwrite it.
                if n < 0 {
                    Err(errno())
                } else {
                    Ok(n as u32)
                }
            });
            let n = match n {
                Ok(0) => return Ok(()),
                Ok(n) => n,
                Err(libc::EINTR) => continue,
                Err(e) => return self.note_error(dir, e),
            };
            // Move the buffer out for the duration of the batch so entries
            // can borrow it while `self` is mutated.
            let buf = std::mem::take(&mut self.buf);
            let batch = match self.lock() {
                Ok(mut slot) => {
                    let batch = self.consume_batch(&mut slot, frame, dir, &buf, n);
                    self.publish(&mut slot);
                    batch
                }
                Err(why) => Err(why),
            };
            self.buf = buf;
            batch?;
        }
    }

    fn consume_batch(
        &mut self,
        slot: &mut Slot,
        frame: &mut Frame<'_>,
        dir: ScanId,
        buf: &[u8],
        count: u32,
    ) -> Result<(), Incomplete> {
        let mut read = 0u32;
        for entry in entries(buf, count) {
            match entry {
                Ok(e) => {
                    self.add_entry(slot, frame, dir, &e)?;
                    read += 1;
                }
                Err(_) => {
                    // Parsing stops at the first bad entry, so it and
                    // everything after it in this batch (up to a buffer's
                    // worth, thousands of entries) is lost. That is a short
                    // result, not a stray error: count the loss and flag the
                    // walk, then keep draining the directory.
                    slot.stats.lost_entries += u64::from(count - read);
                    slot.stats
                        .incomplete
                        .get_or_insert(Incomplete::MalformedBatch);
                    break;
                }
            }
        }
        Ok(())
    }

    fn add_entry(
        &mut self,
        slot: &mut Slot,
        frame: &mut Frame<'_>,
        dir: ScanId,
        e: &RawEntry<'_>,
    ) -> Result<(), Incomplete> {
        let id = self.push(slot, e.name, dir, Some(e))?;
        if e.obj_type == ObjType::Dir {
            // `frame.depth < max_depth` always holds for a frame on the
            // stack, so `+ 1` cannot overflow.
            if frame.depth + 1 < self.max_depth {
                frame
                    .children
                    .try_reserve(1)
                    .map_err(|_| Incomplete::OutOfMemory)?;
                frame.children.push(id);
            } else {
                slot.stats.depth_capped += 1;
            }
        }
        Ok(())
    }

    /// Store a node and count it. `entry` is `None` for the root, which has no
    /// entry of its own; every other node takes the parser's numbers verbatim.
    fn push(
        &mut self,
        slot: &mut Slot,
        name: &[u8],
        parent: ScanId,
        entry: Option<&RawEntry<'_>>,
    ) -> Result<ScanId, Incomplete> {
        // The one place every worker passes often enough to notice another
        // worker's terminal failure promptly. Without it a worker inside a
        // large subtree would keep claiming inodes against the shared set
        // after the walk had already been stopped.
        if let Some(why) = self.halt.reason() {
            return Err(why);
        }
        let name = slot.arena.push_name(name)?;
        let mut dup = false;
        let node = match entry {
            Some(e) => {
                // The gate: only a multiply-linked entry is worth a set
                // lookup. Directories report 0 and never reach `try_claim`.
                if e.link_count > 1 {
                    match self.inodes.try_claim(e.dev_id, e.file_id) {
                        Ok(first) => dup = !first,
                        // Not recorded, so this link keeps its bytes: the
                        // total errs high, never low. It is still a wrong
                        // total, so say so in the same channel as every other
                        // resource shortfall.
                        Err(ReserveFailed) => {
                            slot.stats.incomplete.get_or_insert(Incomplete::OutOfMemory);
                        }
                    }
                }
                ScanNode {
                    name,
                    parent,
                    obj_type: e.obj_type,
                    flags: if dup { FLAG_HARDLINK_DUP } else { 0 },
                    logical: if dup { 0 } else { e.logical },
                    allocated: if dup { 0 } else { e.allocated },
                }
            }
            None => ScanNode {
                name,
                parent,
                obj_type: ObjType::Dir,
                flags: 0,
                logical: 0,
                allocated: 0,
            },
        };
        let (is_dir, allocated) = (node.obj_type == ObjType::Dir, node.allocated);
        let id = self.push_node(slot, node)?;
        if is_dir {
            slot.stats.dirs += 1;
        } else {
            slot.stats.files += 1;
        }
        if dup {
            slot.stats.hardlink_dups += 1;
        }
        slot.bytes += allocated;
        Ok(id)
    }

    /// Draw one unit from the shared budget, then store the node.
    ///
    /// Taking the unit here rather than before `push_name` keeps a serial
    /// walk's behaviour exactly: a budget failure leaves the name bytes
    /// already stored, which is why it is terminal. The unit is spent only on
    /// a successful push, so an arena failure does not consume budget other
    /// workers could have used.
    fn push_node(&mut self, slot: &mut Slot, node: ScanNode) -> Result<ScanId, Incomplete> {
        if self.allowance == 0 {
            self.allowance = self.budget.take(BUDGET_CHUNK);
            if self.allowance == 0 {
                return Err(Incomplete::NodeBudget);
            }
        }
        // A test's stand-in for the allocator refusing a chunk, converted
        // exactly as the arena's own refusal is.
        #[cfg(test)]
        if slot.arena.len() >= slot.oom_after {
            OOM_INJECTED.fetch_add(1, Ordering::Relaxed);
            return Err(ArenaError::OutOfMemory.into());
        }
        let id = slot.arena.push_node(node)?;
        self.allowance -= 1;
        Ok(id)
    }

    /// Open `child`, a directory in this worker's arena, beneath `parent`.
    /// The outer `Err` is a terminal reason; the inner one is the errno.
    ///
    /// The name is copied out of the arena under the lock and the lock is
    /// released before the `openat`, which is the call that blocks on a hung
    /// volume.
    fn open_child(
        &self,
        parent: RawFd,
        child: ScanId,
    ) -> Result<Result<Dir<'a>, c_int>, Incomplete> {
        let mut z = [0u8; MAX_PATH_BYTES + 1];
        let name = {
            let slot = self.lock()?;
            match slot.arena.get(child) {
                Some(node) => nul_terminated(&mut z, slot.arena.name_bytes(node.name)),
                None => Err(libc::EINVAL),
            }
        };
        Ok(name.and_then(|name| {
            let fd = self
                .lane
                .during(child, || self.opener.open_dir_at(parent, name))?;
            Ok(Dir::new(fd, child, self.lane))
        }))
    }

    /// Reopen a published directory, `rel` beneath the scan root's
    /// descriptor, for a task whose descriptor chain was another frame's.
    ///
    /// Every component of `rel` is resolved afresh, which is the cost of
    /// crossing frames, but none of them may be a symlink: [`open_beneath`]
    /// refuses one anywhere, so an ancestor swapped for a symlink between
    /// enumeration and reopen fails the open (`ELOOP`, counted in `errors`)
    /// rather than redirecting the walk. Nothing is resolved from the process's
    /// working directory, so a relative `opts.root` cannot drift either.
    ///
    /// `node` is the directory's own node, which may be in another worker's
    /// arena: it is what the reopen is announced as, and a watchdog that
    /// finds this worker blocked here climbs from it.
    fn reopen(&self, node: ScanId, rel: &Path) -> Result<Dir<'a>, c_int> {
        let Some(root) = self.root_dir else {
            // Only the pool publishes, and it always provides the root.
            return Err(libc::EBADF);
        };
        let fd = with_cstr(rel.as_os_str().as_bytes(), |c| {
            self.lane
                .during(node, || self.opener.reopen_dir_beneath(root.as_raw_fd(), c))
        })?;
        Ok(Dir::new(fd, node, self.lane))
    }
}

/// `rel` (relative to the scan root, empty for the root itself) as a user
/// reads it: `root`, as the caller named it, joined with `rel`.
pub(crate) fn join_root(root: &Path, rel: &[u8]) -> Result<PathBuf, Incomplete> {
    let root = root.as_os_str().as_bytes();
    let mut bytes: Vec<u8> = Vec::new();
    bytes
        .try_reserve_exact(root.len() + 1 + rel.len())
        .map_err(|_| Incomplete::OutOfMemory)?;
    bytes.extend_from_slice(root);
    if !rel.is_empty() {
        if !bytes.is_empty() && bytes.last() != Some(&b'/') {
            bytes.push(b'/');
        }
        bytes.extend_from_slice(rel);
    }
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
}

/// The path of node `id`: the names from `id` up to but not including `stop`,
/// appended to `base`.
///
/// Every walker passes its task's root as `stop` and that directory's path
/// relative to the scan root as `base`, so the result is relative to the scan
/// root (the root task's root is the root node, with an empty base). Stopping
/// at the task root is deliberate, not a consequence of `Arena::get` failing:
/// a worker that pops back a directory it published itself holds that task's
/// root, and its ancestors, in its *own* arena, so a climb that stopped only
/// where the arena ends would repeat part of the path.
fn node_path(arena: &Arena, id: ScanId, base: &Path, stop: ScanId) -> Result<PathBuf, Incomplete> {
    let mut parts: Vec<&[u8]> = Vec::new();
    let mut cur = id;
    while cur != stop {
        let Some(n) = arena.get(cur) else { break };
        parts.try_reserve(1).map_err(|_| Incomplete::OutOfMemory)?;
        parts.push(arena.name_bytes(n.name));
        cur = n.parent;
    }
    assemble_path(base.as_os_str().as_bytes(), &parts)
}

/// `base` with `leaf_first` appended in reverse, `/`-separated: the names a
/// climb from a node towards the root yields, leaf first, as a path.
///
/// The one place a path is put together from arena names, shared by
/// [`node_path`] and the pool's stalled-directory report. Allocation is
/// fallible, like the rest of the walk's per-directory work.
pub(crate) fn assemble_path<P: AsRef<[u8]>>(
    base: &[u8],
    leaf_first: &[P],
) -> Result<PathBuf, Incomplete> {
    let len = base.len()
        + leaf_first
            .iter()
            .map(|p| p.as_ref().len() + 1)
            .sum::<usize>();
    let mut bytes: Vec<u8> = Vec::new();
    bytes
        .try_reserve_exact(len)
        .map_err(|_| Incomplete::OutOfMemory)?;
    bytes.extend_from_slice(base);
    for part in leaf_first.iter().rev() {
        if !bytes.is_empty() && bytes.last() != Some(&b'/') {
            bytes.push(b'/');
        }
        bytes.extend_from_slice(part.as_ref());
    }
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arena::FLAG_PERM_DENIED;
    use std::ffi::{CStr, CString};
    use std::fs::{self, File};
    use std::path::Path;
    use std::sync::atomic::AtomicU32;
    use tesserae_testutil::{DiskImage, Fixture};

    pub(super) fn opts(root: &Path) -> WalkOptions {
        WalkOptions {
            root: root.to_path_buf(),
            ..WalkOptions::default()
        }
    }

    /// Number of ancestors above `id`: the root is 0.
    fn depth_of(arena: &Arena, id: ScanId) -> u32 {
        let mut depth = 0;
        let mut cur = arena.get(id).expect("id resolves").parent;
        while let Some(n) = arena.get(cur) {
            depth += 1;
            cur = n.parent;
        }
        depth
    }

    /// `(logical, allocated)` summed over every node in the arena.
    fn totals(arena: &Arena) -> (u64, u64) {
        arena
            .iter()
            .fold((0, 0), |(l, a), (_, n)| (l + n.logical, a + n.allocated))
    }

    fn find<'a>(arena: &'a Arena, name: &[u8]) -> Vec<&'a ScanNode> {
        arena
            .iter()
            .map(|(_, n)| n)
            .filter(|n| arena.name_bytes(n.name) == name)
            .collect()
    }

    /// Opens through the real `openat`, but first replaces the directory
    /// `victim` with a regular file or a symlink, exactly once. The kernel then produces
    /// the `ENOTDIR` itself, so this exercises the real syscall rather than a
    /// faked errno.
    /// `DirOpener` is `Sync`, so these counters are atomics rather than
    /// `Cell`s: the same opener has to be shareable with every worker of a
    /// parallel walk, even though these particular openers only ever drive a
    /// serial one.
    struct SwapBeforeOpen {
        victim: std::path::PathBuf,
        /// `None` swaps in a regular file; `Some(target)` swaps in a symlink.
        symlink_to: Option<&'static str>,
        fired: AtomicU32,
    }

    impl DirOpener for SwapBeforeOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" && self.fired.load(Ordering::Relaxed) == 0 {
                fs::remove_dir_all(&self.victim).unwrap();
                match self.symlink_to {
                    None => drop(File::create(&self.victim).unwrap()),
                    Some(t) => std::os::unix::fs::symlink(t, &self.victim).unwrap(),
                }
                self.fired.fetch_add(1, Ordering::Relaxed);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    /// Counts descents without changing them.
    struct CountingOpener {
        opens: AtomicU32,
    }

    impl DirOpener for CountingOpener {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            self.opens.fetch_add(1, Ordering::Relaxed);
            OpenAt.open_dir_at(parent, name)
        }
    }

    /// One `getattrlistbulk` call into a buffer of `buf_len` bytes: the raw
    /// bytes and the entry count the kernel reported.
    fn single_call(dir: &Path, buf_len: usize) -> (Vec<u8>, i32) {
        use std::os::unix::ffi::OsStrExt;
        let c = CString::new(dir.as_os_str().as_bytes()).unwrap();
        // SAFETY: `c` is a live NUL-terminated string.
        let fd = unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY) };
        assert!(fd >= 0, "open {}", dir.display());
        let mut attrlist = scan_attrlist();
        let mut buf = vec![0u8; buf_len];
        // SAFETY: all pointers are live and `buf.len()` is the buffer's size.
        let n = unsafe {
            libc::getattrlistbulk(
                fd,
                (&mut attrlist as *mut libc::attrlist).cast(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                SCAN_OPTIONS,
            )
        };
        // SAFETY: `fd` was opened above and is not used again.
        unsafe { libc::close(fd) };
        assert!(n > 0, "getattrlistbulk returned {n}");
        (buf, n)
    }

    /// Entries a single call returns: the number a walker that called
    /// `getattrlistbulk` only once would see.
    fn single_call_entry_count(dir: &Path, buf_len: usize) -> i32 {
        single_call(dir, buf_len).1
    }

    #[test]
    fn counts_files_and_sums_allocated_size() {
        let fx = Fixture::new().unwrap();
        fx.file("a.bin", 4096).unwrap();
        fx.file("d/b.bin", 1 << 20).unwrap();

        let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();

        assert_eq!(stats.files, 2);
        assert_eq!(stats.dirs, 2, "the root and d");
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.incomplete, None);
        assert_eq!(arena.len(), 4);
        let (logical, allocated) = totals(&arena);
        assert_eq!(logical, (1 << 20) + 4096);
        assert!(allocated >= (1 << 20) + 4096, "allocated {allocated}");
        // A directory's own size is a genuine zero, passed through untouched:
        // the rollup, not the walker, produces directory totals.
        for (_, n) in arena.iter().filter(|(_, n)| n.obj_type == ObjType::Dir) {
            assert_eq!((n.logical, n.allocated), (0, 0));
        }
    }

    #[test]
    fn does_not_follow_symlinks() {
        let fx = Fixture::new().unwrap();
        fx.dir("d").unwrap();
        fx.symlink("..", "d/loop").unwrap();
        fx.symlink("d", "to_d").unwrap();

        let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();

        // Terminating is not enough: the default depth cap of 512 would also
        // end a followed loop. A followed `..` would revisit the root and
        // overshoot every one of these counts.
        assert_eq!(stats.dirs, 2, "the root and d, nothing re-entered");
        assert_eq!(stats.files, 2, "each symlink is one entry");
        assert_eq!(stats.depth_capped, 0);
        assert_eq!(stats.errors, 0);
        assert_eq!(arena.len(), 4);
        let links = find(&arena, b"loop");
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].obj_type, ObjType::Lnk);
        assert_eq!(find(&arena, b"to_d")[0].obj_type, ObjType::Lnk);
    }

    #[test]
    fn records_unreadable_directory_without_failing() {
        let fx = Fixture::new().unwrap();
        fx.file("secret/hidden.bin", 4096).unwrap();
        fx.file("ok/f.bin", 4096).unwrap();
        fx.chmod("secret", 0o000).unwrap();

        let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();

        assert_eq!(stats.unreadable, vec![fx.path().join("secret")]);
        assert_eq!(stats.errors, 0, "EACCES is unreadable, not an error");
        assert_eq!(stats.incomplete, None);
        assert_eq!(stats.files, 1, "only ok/f.bin: hidden.bin is unknowable");
        assert_eq!(stats.dirs, 3, "root, secret and ok; secret is still a node");
        assert_eq!(arena.len(), 4);
        // The node itself carries the fact, so it can render as locked rather
        // than as an empty folder. Nothing else is flagged.
        let secret = find(&arena, b"secret");
        assert_eq!(secret.len(), 1);
        assert_eq!(secret[0].flags & FLAG_PERM_DENIED, FLAG_PERM_DENIED);
        let flagged = arena.iter().filter(|(_, n)| n.flags != 0).count();
        assert_eq!(flagged, 1, "only the unreadable directory is flagged");
    }

    #[test]
    fn survives_directory_replaced_by_file_before_open() {
        // Review Focus 3. The race cannot be produced on demand, so the open
        // seam swaps the directory for a file immediately before the real
        // `openat`, and the kernel returns ENOTDIR on its own.
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();
        let opener = SwapBeforeOpen {
            victim: fx.path().join("victim"),
            symlink_to: None,
            fired: AtomicU32::new(0),
        };

        let (arena, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(
            opener.fired.load(Ordering::Relaxed),
            1,
            "the swap must actually have run"
        );
        assert!(fx.path().join("victim").is_file());
        assert_eq!(stats.errors, 1);
        assert!(stats.unreadable.is_empty());
        assert_eq!(stats.incomplete, None);
        assert_eq!(stats.files, 1, "other/f.bin was still reached");
        assert_eq!(stats.dirs, 3, "victim was enumerated as a directory");
        assert_eq!(arena.len(), 4);
    }

    #[test]
    fn directory_replaced_by_symlink_is_not_followed() {
        // The other half of the race: the replacement is a symlink to a real
        // directory. `O_NOFOLLOW` must refuse it, or the walk would quietly
        // account `other`'s contents a second time under `victim`.
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();
        let opener = SwapBeforeOpen {
            victim: fx.path().join("victim"),
            symlink_to: Some("other"),
            fired: AtomicU32::new(0),
        };

        let (_, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(opener.fired.load(Ordering::Relaxed), 1);
        assert!(fx.path().join("victim").is_symlink());
        assert_eq!(stats.errors, 1);
        assert_eq!(stats.files, 1, "other/f.bin once, not again via victim");
        assert_eq!(stats.incomplete, None);
    }

    #[test]
    fn a_malformed_batch_reports_the_entries_it_lost() {
        // Straight at `consume_batch`: it is a private function over bytes, so
        // no seam is needed. Take a real three-entry batch and zero the
        // second entry's length field, which the parser rejects as BadLength.
        let fx = Fixture::new().unwrap();
        for n in ["a.bin", "b.bin", "c.bin"] {
            fx.file(n, 1).unwrap();
        }
        let (mut buf, count) = single_call(fx.path(), 4096);
        assert_eq!(count, 3);
        let first_len = u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize;
        buf[first_len..first_len + 4].copy_from_slice(&0u32.to_le_bytes());

        let inodes = InodeSet::new(1);
        let budget = NodeBudget::new(u64::MAX);
        let halt = Halt::new();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let ctx = WalkerCtx {
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: VolumeId::new(0, 0),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = Walker::new(&ctx, None, &opts(fx.path()), &lane).unwrap();
        let mut slot = lane.lock_raw().unwrap();
        let root = w.push(&mut slot, b"root", ScanId::NONE, None).unwrap();
        let mut frame = Frame {
            dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
            depth: 0,
            children: Vec::new(),
            next: 0,
        };

        w.consume_batch(&mut slot, &mut frame, root, &buf, 3)
            .unwrap();

        assert_eq!(slot.stats.files, 1, "only the entry before the bad one");
        assert_eq!(
            slot.stats.lost_entries, 2,
            "the bad entry and the one after"
        );
        assert_eq!(slot.stats.incomplete, Some(Incomplete::MalformedBatch));
        assert_eq!(slot.stats.errors, 0, "a short result, not a stray error");

        // And a batch that is bad from its first entry loses all of it.
        buf[..4].copy_from_slice(&0u32.to_le_bytes());
        w.consume_batch(&mut slot, &mut frame, root, &buf, 3)
            .unwrap();
        assert_eq!(slot.stats.lost_entries, 2 + 3);
    }

    /// The volume `p` is on, as the boundary sees it.
    fn volume_at(p: &Path) -> VolumeId {
        volume_of(File::open(p).unwrap().as_raw_fd()).unwrap()
    }

    #[test]
    fn walk_does_not_cross_into_a_mounted_disk_image() {
        let fx = Fixture::new().unwrap();
        fx.file("before.bin", 4096).unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        // Declared after `fx`, so it drops first: the volume is unmounted
        // before the fixture removes its tree, and on a panic too.
        let image = DiskImage::attach(&mnt, 16)
            .expect("this test needs hdiutil to be able to attach a disk image");
        fs::write(mnt.join("on_image.bin"), vec![1u8; 8192]).unwrap();
        fs::create_dir(mnt.join("sub")).unwrap();
        fs::write(mnt.join("sub/deep.bin"), vec![2u8; 8192]).unwrap();

        // Without these the test could pass because the image never mounted and
        // the files simply are not there. The image is a different volume, the
        // files exist on it, and a walk that is *rooted* on it finds them.
        assert_ne!(
            volume_at(&mnt),
            volume_at(fx.path()),
            "the image must be a mount"
        );
        assert!(mnt.join("on_image.bin").is_file());
        let (control, control_stats) = walk_serial(&opts(&mnt)).unwrap();
        assert_eq!(find(&control, b"on_image.bin").len(), 1);
        assert_eq!(find(&control, b"deep.bin").len(), 1);
        assert!(
            control_stats.skipped_mounts.is_empty(),
            "the root is walked"
        );

        // `include_non_local` must not open this: the image is a local volume.
        // This loop proves only that negative. The positive half (the flag
        // does open a non-local mount) is `a_non_local_mount_is_skipped_unless_opted_in`.
        for include_non_local in [false, true] {
            let mut o = opts(fx.path());
            o.include_non_local = include_non_local;

            let (arena, stats) = walk_serial(&o).unwrap();

            let ctx = format!("include_non_local {include_non_local}");
            assert_eq!(
                stats.skipped_mounts,
                vec![(mnt.clone(), SkipReason::OtherVolume)],
                "{ctx}"
            );
            assert!(find(&arena, b"on_image.bin").is_empty(), "{ctx}");
            assert!(find(&arena, b"sub").is_empty(), "{ctx}");
            assert!(find(&arena, b"deep.bin").is_empty(), "{ctx}");
            assert_eq!(find(&arena, b"before.bin").len(), 1, "{ctx}");
            // The mount point is a node, but a childless one.
            assert_eq!(find(&arena, b"mnt").len(), 1, "{ctx}");
            assert_eq!((stats.dirs, stats.files), (2, 1), "{ctx}: root and mnt");
            assert_eq!(arena.len(), 3, "{ctx}");
            assert_eq!(stats.errors, 0, "a skip is policy, not an error ({ctx})");
            assert_eq!(stats.incomplete, None, "{ctx}");
            assert!(stats.unreadable.is_empty(), "{ctx}");
        }
        drop(image);
    }

    /// Hands back a descriptor on the automounter's `/home` (a mount the
    /// kernel reports as non-local) in place of the directory `victim`. The
    /// boundary then sees a real change of volume and a real `MNT_LOCAL` clear.
    struct NonLocalForVictim;

    impl DirOpener for NonLocalForVictim {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return File::open("/System/Volumes/Data/home")
                    .map(OwnedFd::from)
                    .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO));
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn a_non_local_mount_is_skipped_unless_opted_in() {
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();

        let (arena, stats) = walk_serial_with(&opts(fx.path()), &NonLocalForVictim).unwrap();

        assert_eq!(
            stats.skipped_mounts,
            vec![(fx.path().join("victim"), SkipReason::NonLocalMount)]
        );
        assert_eq!(stats.files, 1, "other/f.bin was still reached");
        assert_eq!(stats.dirs, 3, "root, victim and other");
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.incomplete, None);
        assert_eq!(arena.len(), 4);

        // Opted in. This half is partly inferred, and that is an environment
        // limit, not an oversight: the only non-local mount an unprivileged
        // test can open (the automounter's `/home`) is empty, so entering it
        // changes no node count. What is observed is that it is no longer
        // recorded in `skipped_mounts`, and the walk finished cleanly. It does
        // not, on its own, rule out an `admit` that returned `Ok(false)`
        // without recording. The skip half above fails if the policy
        // misclassifies the mount, and `boundary::the_policy_table` and
        // `refuses_non_local_mount_unless_opted_in` cover the opt-in decision
        // itself; only "and then it was actually read" needs a non-local mount
        // with content, which cannot be made without a server.
        let mut o = opts(fx.path());
        o.include_non_local = true;
        let (arena, stats) = walk_serial_with(&o, &NonLocalForVictim).unwrap();

        assert!(
            stats.skipped_mounts.is_empty(),
            "{:?}",
            stats.skipped_mounts
        );
        assert_eq!(stats.files, 1);
        assert_eq!(stats.dirs, 3);
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.incomplete, None);
        assert_eq!(arena.len(), 4);
    }

    #[test]
    fn enumerates_a_directory_larger_than_one_buffer() {
        // Review Focus 4.
        const FILES: u64 = 5000;
        const BUFFER: usize = 4096;
        let fx = Fixture::new().unwrap();
        for i in 0..FILES {
            fx.file(&format!("big/f{i:04}.bin"), 0).unwrap();
        }
        // The precondition that gives the test its teeth: one call into a
        // buffer this size returns only a small fraction of the directory, so
        // a walker that stopped after one call could not reach FILES.
        let first = single_call_entry_count(&fx.path().join("big"), BUFFER);
        assert!(
            (first as u64) * 10 < FILES,
            "a single {BUFFER}-byte call returned {first} of {FILES} entries"
        );

        let mut o = opts(fx.path());
        o.buffer_bytes = BUFFER;
        let (_, stats) = walk_serial(&o).unwrap();

        assert_eq!(stats.files, FILES);
        assert_eq!(stats.dirs, 2);
        assert_eq!(stats.errors, 0);
    }

    #[test]
    fn stops_at_depth_cap() {
        let fx = Fixture::new().unwrap();
        // d0/d1/.../d19, with one file in every directory.
        let mut rel = String::new();
        for i in 0..20 {
            rel.push_str(&format!("d{i}/"));
            fx.file(&format!("{rel}f.bin"), 4096).unwrap();
        }
        let mut o = opts(fx.path());
        o.max_depth = 5;

        let (arena, stats) = walk_serial(&o).unwrap();

        // d0..d4 sit at depths 1..=5. The directory at the cap is recorded
        // but not entered, so the files in d0..d3 (depths 2..=5) are found and
        // d4's is not: 4 of the 20. Without a cap all 20 would be found.
        assert_eq!(stats.depth_capped, 1);
        assert_eq!(stats.dirs, 6, "root and d0..d4");
        assert_eq!(stats.files, 4);
        let deepest = arena.iter().map(|(id, _)| depth_of(&arena, id)).max();
        assert_eq!(deepest, Some(5), "nodes reach the cap and go no deeper");
        assert_eq!(stats.incomplete, None);
    }

    #[test]
    fn returns_incomplete_node_budget_when_budget_is_hit() {
        let fx = Fixture::new().unwrap();
        for i in 0..10 {
            fx.file(&format!("f{i}.bin"), 4096).unwrap();
        }
        let mut o = opts(fx.path());
        o.node_budget = 3;

        let (arena, stats) = walk_serial(&o).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
        assert_eq!(arena.len(), 3, "the root and two files");
        assert_eq!(stats.files, 2, "only pushed nodes are counted");
        assert_eq!(stats.dirs, 1);
    }

    #[test]
    fn node_budget_is_terminal_and_stops_before_descending() {
        // 10 directories with a file each; room for the root and two of them.
        // A walker that carried on after the failed push would go on to open
        // the directories it already holds.
        let fx = Fixture::new().unwrap();
        for i in 0..10 {
            fx.file(&format!("d{i}/f.bin"), 4096).unwrap();
        }
        let mut o = opts(fx.path());
        o.node_budget = 3;
        let opener = CountingOpener {
            opens: AtomicU32::new(0),
        };

        let (arena, stats) = walk_serial_with(&o, &opener).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
        assert_eq!(arena.len(), 3);
        assert_eq!(
            opener.opens.load(Ordering::Relaxed),
            0,
            "the walk stopped, it did not carry on"
        );
    }

    #[test]
    fn rejects_a_buffer_too_small_for_one_entry() {
        let fx = Fixture::new().unwrap();
        fx.file("a.bin", 1).unwrap();
        let mut o = opts(fx.path());
        o.buffer_bytes = 16;
        let err = walk_serial(&o).err().expect("walk must fail");
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    /// A walker with a halt and a budget of its own, for the two tests below.
    fn halted_walker<'a>(
        ctx: &WalkerCtx<'a, OpenAt>,
        opts: &WalkOptions,
        lane: &'a Lane,
    ) -> Walker<'a, OpenAt> {
        Walker::new(ctx, None, opts, lane).unwrap()
    }

    /// Half of "one worker's failure stops the others": a worker that sees the
    /// halt raised stops at its very next push, whatever it was doing.
    ///
    /// Through real threads the timing is a race by definition, so no pool
    /// test bounds how much the other workers store before they notice (see
    /// `pool::tests::one_workers_arena_failure_is_the_whole_walks_failure`
    /// for why). This is the property with the race taken out; with
    /// `a_terminal_failure_raises_the_halt` it is the whole mechanism.
    #[test]
    fn a_raised_halt_stops_a_push_dead() {
        let fx = Fixture::new().unwrap();
        let inodes = InodeSet::new(1);
        let budget = NodeBudget::new(u64::MAX);
        let halt = Halt::new();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let ctx = WalkerCtx {
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: VolumeId::new(0, 0),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = halted_walker(&ctx, &opts(fx.path()), &lane);
        let mut slot = lane.lock_raw().unwrap();

        // Before: a push works and the budget is nowhere near spent.
        w.push(&mut slot, b"before", ScanId::NONE, None)
            .expect("push works");
        assert_eq!(slot.arena.len(), 1);

        // Another worker fails.
        halt.raise(Incomplete::OutOfMemory);

        // After: this worker stops, with the other's reason, and stores
        // nothing — not even the name bytes, since the halt is checked first.
        assert_eq!(
            w.push(&mut slot, b"after", ScanId::NONE, None),
            Err(Incomplete::OutOfMemory)
        );
        assert_eq!(slot.arena.len(), 1, "a node was stored after the halt");
        drop(slot);
        // And the lock refuses it too, before the slot is even touched.
        assert!(matches!(w.lock(), Err(Incomplete::OutOfMemory)));

        // First reason wins, so a later failure cannot rewrite history.
        halt.raise(Incomplete::NodeBudget);
        assert_eq!(halt.reason(), Some(Incomplete::OutOfMemory));
    }

    /// The other half: a terminal failure in this worker raises the halt, so
    /// there is something for every other worker to see.
    #[test]
    fn a_terminal_failure_raises_the_halt() {
        let fx = Fixture::new().unwrap();
        for i in 0..10 {
            fx.file(&format!("f{i}.bin"), 1).unwrap();
        }
        let inodes = InodeSet::new(1);
        // Room for the root and two files, then the walk is over.
        let budget = NodeBudget::new(3);
        let halt = Halt::new();
        let root_fd = open_root(&opts(fx.path())).unwrap();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let ctx = WalkerCtx {
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: root_volume_of(&opts(fx.path()), &root_fd).unwrap(),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = halted_walker(&ctx, &opts(fx.path()), &lane);

        assert_eq!(halt.reason(), None, "nothing has failed yet");
        let outcome = w.run_root(root_fd);

        assert_eq!(outcome, Err(Incomplete::NodeBudget));
        assert_eq!(
            halt.reason(),
            Some(Incomplete::NodeBudget),
            "the failure was not announced, so no other worker would stop"
        );
        let (arena, stats) = w.finish();
        assert_eq!(arena.len(), 3);
        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
    }

    #[test]
    fn empty_root_walks_to_a_single_node() {
        let fx = Fixture::new().unwrap();
        let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();
        assert_eq!((arena.len(), stats.dirs, stats.files), (1, 1, 0));
        assert_eq!(stats.incomplete, None);
    }
}
