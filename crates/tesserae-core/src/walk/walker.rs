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

//! The [`Walker`]: one thread walking, with its read buffer, its lane and its
//! share of the walk's coordination handles.

use std::ffi::OsStr;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, OwnedFd, RawFd};
use std::os::raw::c_int;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::coordination::BUDGET_CHUNK;
use super::lane::{Dir, Held, Slot};
use super::open::{errno, nul_terminated, with_cstr};
#[cfg(doc)]
use super::open_beneath;
use super::Halt;
use super::{
    check_options, join_root, node_path, DirOpener, Incomplete, Lane, NodeBudget, Share,
    WalkOptions, WalkStats, WalkerCtx, MAX_PATH_BYTES,
};
#[cfg(test)]
use super::{KEPT_TOO_LONG, OOM_INJECTED};
#[cfg(test)]
use crate::arena::ArenaError;
use crate::arena::{Arena, ScanId, ScanNode, FLAG_HARDLINK_DUP};
use crate::attrs::{scan_attrlist, SCAN_OPTIONS};
use crate::boundary::{should_descend, volume_of, VolumeId};
use crate::dedup::{InodeSet, ReserveFailed};
use crate::parse::{entries, ObjType, RawEntry};
use crate::progress::Progress;
#[cfg(test)]
use std::sync::atomic::Ordering;

/// One directory being walked.
pub(super) struct Frame<'a> {
    /// This directory, open. Dropping the frame closes it.
    pub(super) dir: Dir<'a>,
    pub(super) depth: u16,
    /// Subdirectories found by enumeration and not yet entered.
    pub(super) children: Vec<ScanId>,
    /// Index into `children` of the next one to enter.
    pub(super) next: usize,
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
    pub(super) share: Option<&'a (dyn Share + 'a)>,
    /// Units drawn from `budget` and not yet spent.
    allowance: u64,
    /// The `getattrlistbulk` output buffer, reused for every directory.
    buf: Vec<u8>,
    attrlist: libc::attrlist,
    max_depth: u16,
    pub(super) root_volume: VolumeId,
    include_non_local: bool,
    root_path: &'a Path,
    pub(super) root_dir: Option<BorrowedFd<'a>>,
    /// The node this worker's current task is rooted at, and that directory's
    /// path *relative to the scan root*. A path is rebuilt by climbing the
    /// parent chain only as far as `task_root`, then joining the result onto
    /// `task_rel`, because above the task root the chain may leave this arena.
    /// For the root task `task_root` is the root node itself and `task_rel` is
    /// empty, so the climb stops just below the root.
    task_root: ScanId,
    task_rel: Arc<Path>,
    /// This worker's arena and stats, locked, and its syscall announcements.
    pub(super) lane: &'a Lane,
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
    pub(super) fn lock(&self) -> Result<Held<'a>, Incomplete> {
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
    pub(super) fn publish(&self, slot: &mut Slot) {
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
        // The root has no `getattrlistbulk` entry (nothing enumerated it), so
        // its own modification time comes from the descriptor already open.
        // Every other field is what a directory's entry would give it.
        let root_entry = RawEntry {
            name: root_name,
            obj_type: ObjType::Dir,
            file_id: 0,
            dev_id: 0,
            flags: 0,
            modified: own_mtime(root_fd.as_raw_fd()),
            logical: 0,
            allocated: 0,
            link_count: 0,
        };
        self.guard(|w| {
            let root = {
                let mut slot = w.lock()?;
                let root = w.push(&mut slot, root_name, ScanId::NONE, Some(&root_entry))?;
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
    pub(super) fn report_path_of(&self, slot: &Slot, id: ScanId) -> Result<PathBuf, Incomplete> {
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

    pub(super) fn consume_batch(
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

    /// Store a node and count it. Every node takes the entry's numbers
    /// verbatim; `run_root` builds the root's from `fstat`. `None` stores a
    /// directory with every figure zero, its modification time included.
    pub(super) fn push(
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
                    // A hardlink duplicate keeps its time: it is the same
                    // inode, and only its bytes are counted elsewhere.
                    modified: e.modified,
                }
            }
            None => ScanNode {
                name,
                parent,
                obj_type: ObjType::Dir,
                flags: 0,
                logical: 0,
                allocated: 0,
                modified: 0,
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

/// The modification time, in seconds, of the object open as `fd`, or `0`
/// when `fstat` fails. Zero is "unknown": a directory's time is rolled up as
/// the latest of its own and its descendants', so an unknown root still
/// reports the newest thing beneath it.
fn own_mtime(fd: RawFd) -> i64 {
    let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `st` is a valid out-pointer for one `stat`; `fstat` either
    // fills it and returns 0 or leaves it unread by us.
    if unsafe { libc::fstat(fd, st.as_mut_ptr()) } != 0 {
        return 0;
    }
    // SAFETY: `fstat` returned 0, so it initialised `st`.
    unsafe { st.assume_init() }.st_mtime
}
