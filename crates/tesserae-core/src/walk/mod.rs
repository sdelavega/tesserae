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
mod skip;
pub(crate) use skip::SkipSet;
mod walker;

pub(crate) use coordination::{Halt, NodeBudget, Share, WalkerCtx};
pub use errors::{os_errno, with_context, Incomplete};
pub(crate) use lane::Lane;
#[allow(unused_imports)] // linked from the docs above; the tests elsewhere call it
pub(crate) use open::open_beneath;
pub(crate) use open::{open_root, DirOpener, OpenAt};
#[cfg(doc)]
use walker::Frame;
pub(crate) use walker::Walker;

use std::io;
use std::os::fd::{AsFd, AsRawFd, OwnedFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicU64;
use std::time::Duration;

use crate::arena::{Arena, ScanId};
#[cfg(doc)]
use crate::arena::{FLAG_HARDLINK_DUP, FLAG_PERM_DENIED};
use crate::boundary::{volume_of, SkipReason, VolumeId};
use crate::dedup::InodeSet;
use crate::progress::Progress;

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
    /// Absolute directories to record without entering, matched by device and inode.
    pub skip: Vec<PathBuf>,
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
            skip: Vec::new(),
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

/// Cloud-only entries, including files' logical sizes (zero local allocation).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DatalessStats {
    pub files: u64,
    pub directories: u64,
    pub logical_bytes: u64,
}

/// What a walk saw. Counts cover nodes that were actually pushed.
#[derive(Debug)]
pub struct WalkStats {
    pub dataless: DatalessStats,
    /// Cloud-only directories that were not entered (raw report paths).
    pub dataless_paths: Vec<PathBuf>,
    /// At least one scan thread could not disable materialization.
    pub no_materialize_failed: bool,
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
    /// Requested exclusions ("limited scan") and absent requests ("not present").
    pub skipped_by_request: Vec<(PathBuf, &'static str)>,
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
    /// When the walk began, in seconds since the Unix epoch (UTC), read from
    /// the system clock before the root is opened. [`crate::freeze`] uses it
    /// as the cutoff for directory modification times: a time later than
    /// this cannot be a real modification seen by this scan (a file stamped
    /// in the future, or a clock that was wrong when it was written), so it
    /// does not make a directory look newer. [`WalkStats::default`] sets it
    /// to `i64::MAX`, which is no cutoff at all, for stats that did not come
    /// from a walk.
    pub started_at: i64,
    /// Device of the scan root from its admission metadata.
    pub root_device: i32,
}

impl Default for WalkStats {
    fn default() -> Self {
        WalkStats {
            dataless: DatalessStats::default(),
            dataless_paths: Vec::new(),
            no_materialize_failed: false,
            dirs: 0,
            files: 0,
            errors: 0,
            unreadable: Vec::new(),
            skipped_mounts: Vec::new(),
            skipped_by_request: Vec::new(),
            depth_capped: 0,
            lost_entries: 0,
            hardlink_dups: 0,
            stalled_at: None,
            incomplete: None,
            started_at: i64::MAX,
            root_device: 0,
        }
    }
}

/// Now, in whole seconds since the Unix epoch: the [`WalkStats::started_at`]
/// a walk records. A clock set before 1970 gives a negative value, as
/// `time_t` would; one past the range of `i64` seconds cannot occur.
pub(crate) fn now_epoch_secs() -> i64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_secs()).unwrap_or(i64::MAX),
        Err(before) => -i64::try_from(before.duration().as_secs()).unwrap_or(i64::MAX),
    }
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
    let no_materialize_failed = opener.no_materialize().is_err();
    let started_at = now_epoch_secs();
    let skips = SkipSet::resolve(opts)?;
    if let Some((arena, mut stats)) = skips.root_snapshot(opts, started_at, opener)? {
        stats.no_materialize_failed = no_materialize_failed;
        return Ok((arena, stats));
    }
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
        skips: &skips,
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
    let (arena, mut stats) = walker.finish();
    stats.no_materialize_failed = no_materialize_failed;
    stats.started_at = started_at;
    stats.skipped_by_request.extend(skips.missing);
    Ok((arena, stats))
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
mod tests;
