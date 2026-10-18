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

//! Single-threaded, fd-relative directory walker.
//!
//! This is the reference implementation. The parallel walker that follows it
//! must produce the same totals, so correctness and legibility are the goals
//! here, not speed.
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
//! A frame owns its directory's fd as an [`OwnedFd`], and a frame lives
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
//! # Per-arena budget
//!
//! The node budget belongs to the [`Arena`], so it is per thread. That is
//! harmless here with one arena, and it is the parallel walker's job to turn
//! it into a global limit.

use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::raw::c_int;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;

use crate::arena::{Arena, ArenaError, ScanId, ScanNode, FLAG_PERM_DENIED};
use crate::attrs::{scan_attrlist, SCAN_OPTIONS};
use crate::parse::{entries, ObjType, RawEntry};

/// The default scan root: the user-visible data volume on modern macOS.
const DEFAULT_ROOT: &str = "/System/Volumes/Data";
const DEFAULT_MAX_DEPTH: u16 = 512;
const DEFAULT_NODE_BUDGET: u64 = 25_000_000;
/// 256 KiB. Measured: no knee between 64 KiB and 1 MiB (27.6 / 27.3 / 27.6 s),
/// so this is the middle of a flat region rather than a tuned value.
const DEFAULT_BUFFER_BYTES: usize = 256 * 1024;
/// Below this a buffer cannot be trusted to hold one entry. Measured: the
/// kernel answers `ERANGE` for 64 bytes and first fits a one-file entry at 80,
/// and an entry is ~72 bytes of fixed fields plus its name, which can run to
/// `PATH_MAX`.
const MIN_BUFFER_BYTES: usize = 2048;
/// Longest name that can be handed to `openat` without allocating. A name
/// this long is already invalid (`PATH_MAX` is 1024 including the NUL).
const MAX_NAME_BYTES: usize = 1023;

#[derive(Debug, Clone)]
pub struct WalkOptions {
    pub root: PathBuf,
    /// The deepest level the walk records. A directory at exactly this depth
    /// is recorded but not entered, so nothing deeper exists. The root is
    /// depth 0.
    pub max_depth: u16,
    /// Most nodes the arena will hold. Per arena, so per walker thread.
    pub node_budget: u64,
    /// Size of the `getattrlistbulk` output buffer.
    pub buffer_bytes: usize,
    /// Whether to descend into network and other non-local mounts. Read by
    /// the boundary policy added with the volume-boundary work; the serial
    /// walker does not consult it yet.
    pub include_non_local: bool,
    /// Worker thread count. Read only by the parallel walker; the serial
    /// walker ignores it.
    pub workers: usize,
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
    /// (`ENOENT`, `ENOTDIR`), malformed batches and any other errno that is
    /// neither a permission denial nor fatal.
    pub errors: u64,
    /// Directories that could not be read for lack of permission. Their sizes
    /// are unknowable, so they hold no children and no bytes.
    pub unreadable: Vec<PathBuf>,
    pub skipped_mounts: Vec<PathBuf>,
    /// Directories recorded at `max_depth` and therefore not entered.
    pub depth_capped: u64,
    /// Entries the kernel returned that the parser rejected or never reached
    /// (those after a bad entry in the same batch). Nonzero means
    /// `incomplete` was set to [`Incomplete::MalformedBatch`], though a
    /// terminal reason may have replaced it since.
    pub lost_entries: u64,
    pub stalled_at: Option<PathBuf>,
    /// `Some` if the result is partial and why.
    pub incomplete: Option<Incomplete>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Incomplete {
    Cancelled,
    NodeBudget,
    OutOfMemory,
    Stalled,
    /// `openat` failed with `EMFILE` or `ENFILE`: the walk ran out of file
    /// descriptors. Unlike the races counted in [`WalkStats::errors`], this
    /// means the result is systematically short, so it is reported here. The
    /// directory that could not be opened is skipped and the walk carries on
    /// (popping frames frees descriptors), but every subtree skipped this way
    /// is missing from the totals.
    FdExhausted,
    /// The parser rejected a `getattrlistbulk` batch, so the entries after the
    /// bad one were never read. [`WalkStats::lost_entries`] says how many.
    MalformedBatch,
}

impl From<ArenaError> for Incomplete {
    fn from(e: ArenaError) -> Self {
        match e {
            ArenaError::NodeBudgetExceeded => Incomplete::NodeBudget,
            ArenaError::OutOfMemory => Incomplete::OutOfMemory,
        }
    }
}

/// How the walker opens a child directory. The one seam in the descent path.
///
/// Production uses [`OpenAt`]. Tests substitute an opener that mutates the
/// tree immediately before delegating to the real one, which is the only
/// deterministic way to reach the window between a directory being enumerated
/// and being opened.
pub(crate) trait DirOpener {
    /// Open the directory `name` relative to the directory open as `parent`.
    /// Returns the errno on failure.
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int>;
}

/// The real thing: `openat(2)` that refuses to follow a symlink and refuses
/// anything that is not a directory.
pub(crate) struct OpenAt;

impl DirOpener for OpenAt {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        loop {
            // SAFETY: `name` is a live NUL-terminated string.
            let fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
            if fd >= 0 {
                // SAFETY: `openat` just returned this descriptor and nothing
                // else owns it.
                return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
            }
            match errno() {
                libc::EINTR => continue,
                e => return Err(e),
            }
        }
    }
}

fn errno() -> c_int {
    io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
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
    if opts.buffer_bytes < MIN_BUFFER_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "buffer_bytes {} is below the {MIN_BUFFER_BYTES}-byte minimum",
                opts.buffer_bytes
            ),
        ));
    }
    let root_fd = open_root(opts)?;
    let mut buf = Vec::new();
    buf.try_reserve_exact(opts.buffer_bytes)
        .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
    buf.resize(opts.buffer_bytes, 0);

    let mut walker = Walker {
        opener,
        buf,
        attrlist: scan_attrlist(),
        max_depth: opts.max_depth,
        arena: Arena::new(0, opts.node_budget),
        stats: WalkStats::default(),
    };
    if let Err(why) = walker.run(&opts.root, root_fd) {
        walker.stats.incomplete = Some(why);
    }
    Ok((walker.arena, walker.stats))
}

/// Open the root by path. Unlike every other directory this one may be reached
/// through a symlink: the caller named it, so resolving it is what they meant.
fn open_root(opts: &WalkOptions) -> io::Result<OwnedFd> {
    let path = CString::new(opts.root.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "root path contains NUL"))?;
    loop {
        // SAFETY: `path` is a live NUL-terminated string.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd >= 0 {
            // SAFETY: `open` just returned this descriptor.
            return Ok(unsafe { OwnedFd::from_raw_fd(fd) });
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() != Some(libc::EINTR) {
            return Err(io::Error::new(
                err.kind(),
                format!("open {}: {err}", opts.root.display()),
            ));
        }
    }
}

/// One directory being walked.
struct Frame {
    /// This directory, open. Dropping the frame closes it.
    fd: OwnedFd,
    depth: u16,
    /// Subdirectories found by enumeration and not yet entered.
    children: Vec<ScanId>,
    /// Index into `children` of the next one to enter.
    next: usize,
}

struct Walker<'a, O> {
    opener: &'a O,
    /// The `getattrlistbulk` output buffer, reused for every directory.
    buf: Vec<u8>,
    attrlist: libc::attrlist,
    max_depth: u16,
    arena: Arena,
    stats: WalkStats,
}

impl<O: DirOpener> Walker<'_, O> {
    fn run(&mut self, root_path: &std::path::Path, root_fd: OwnedFd) -> Result<(), Incomplete> {
        let root = self.push(root_path.as_os_str().as_bytes(), ScanId::NONE, None)?;
        if self.max_depth == 0 {
            self.stats.depth_capped += 1;
            return Ok(());
        }
        let mut stack: Vec<Frame> = Vec::new();
        self.enter(&mut stack, root_fd, root, 0)?;

        while let Some(top) = stack.last_mut() {
            let Some(&child) = top.children.get(top.next) else {
                // Subtree finished: popping drops the frame and closes its fd.
                stack.pop();
                continue;
            };
            top.next += 1;
            let (parent_fd, depth) = (top.fd.as_raw_fd(), top.depth + 1);
            match self.open_child(parent_fd, child) {
                Ok(fd) => self.enter(&mut stack, fd, child, depth)?,
                Err(e) => self.note_error(child, e)?,
            }
        }
        Ok(())
    }

    /// Enumerate `id`'s directory, then push it as a frame to be descended.
    fn enter(
        &mut self,
        stack: &mut Vec<Frame>,
        fd: OwnedFd,
        id: ScanId,
        depth: u16,
    ) -> Result<(), Incomplete> {
        let mut frame = Frame {
            fd,
            depth,
            children: Vec::new(),
            next: 0,
        };
        self.enumerate(&mut frame, id)?;
        stack.try_reserve(1).map_err(|_| Incomplete::OutOfMemory)?;
        stack.push(frame);
        Ok(())
    }

    /// Drain one directory: call `getattrlistbulk` until it reports no more.
    ///
    /// A single call does not drain a directory. It fills the buffer with
    /// whole entries and stops, and the fd's offset carries over to the next
    /// call. Only a return of 0 means the directory is exhausted.
    fn enumerate(&mut self, frame: &mut Frame, dir: ScanId) -> Result<(), Incomplete> {
        loop {
            // SAFETY: `attrlist` and `buf` are live, `buf.len()` is its true
            // size and the fd is open.
            let n = unsafe {
                libc::getattrlistbulk(
                    frame.fd.as_raw_fd(),
                    (&mut self.attrlist as *mut libc::attrlist).cast(),
                    self.buf.as_mut_ptr().cast(),
                    self.buf.len(),
                    SCAN_OPTIONS,
                )
            };
            if n < 0 {
                match errno() {
                    libc::EINTR => continue,
                    e => return self.note_error(dir, e),
                }
            }
            if n == 0 {
                return Ok(());
            }
            // Move the buffer out for the duration of the batch so entries
            // can borrow it while `self` is mutated.
            let buf = std::mem::take(&mut self.buf);
            let batch = self.consume_batch(frame, dir, &buf, n as u32);
            self.buf = buf;
            batch?;
        }
    }

    fn consume_batch(
        &mut self,
        frame: &mut Frame,
        dir: ScanId,
        buf: &[u8],
        count: u32,
    ) -> Result<(), Incomplete> {
        let mut read = 0u32;
        for entry in entries(buf, count) {
            match entry {
                Ok(e) => {
                    self.add_entry(frame, dir, &e)?;
                    read += 1;
                }
                Err(_) => {
                    // Parsing stops at the first bad entry, so it and
                    // everything after it in this batch (up to a buffer's
                    // worth, thousands of entries) is lost. That is a short
                    // result, not a stray error: count the loss and flag the
                    // walk, then keep draining the directory.
                    self.stats.lost_entries += u64::from(count - read);
                    self.stats
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
        frame: &mut Frame,
        dir: ScanId,
        e: &RawEntry<'_>,
    ) -> Result<(), Incomplete> {
        let id = self.push(e.name, dir, Some(e))?;
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
                self.stats.depth_capped += 1;
            }
        }
        Ok(())
    }

    /// Store a node and count it. `entry` is `None` for the root, which has no
    /// entry of its own; every other node takes the parser's numbers verbatim.
    fn push(
        &mut self,
        name: &[u8],
        parent: ScanId,
        entry: Option<&RawEntry<'_>>,
    ) -> Result<ScanId, Incomplete> {
        let name = self.arena.push_name(name)?;
        let node = match entry {
            Some(e) => ScanNode {
                name,
                parent,
                obj_type: e.obj_type,
                flags: 0,
                logical: e.logical,
                allocated: e.allocated,
            },
            None => ScanNode {
                name,
                parent,
                obj_type: ObjType::Dir,
                flags: 0,
                logical: 0,
                allocated: 0,
            },
        };
        let is_dir = node.obj_type == ObjType::Dir;
        let id = self.arena.push_node(node)?;
        if is_dir {
            self.stats.dirs += 1;
        } else {
            self.stats.files += 1;
        }
        Ok(id)
    }

    fn open_child(&self, parent_fd: RawFd, child: ScanId) -> Result<OwnedFd, c_int> {
        let node = self.arena.get(child).ok_or(libc::EINVAL)?;
        let name = self.arena.name_bytes(node.name);
        // Copy the name onto the stack to NUL-terminate it: a heap-allocated
        // `CString` per directory would be an allocation on the walk's hot
        // path that can fail.
        let mut z = [0u8; MAX_NAME_BYTES + 1];
        if name.len() > MAX_NAME_BYTES {
            return Err(libc::ENAMETOOLONG);
        }
        z[..name.len()].copy_from_slice(name);
        let c = CStr::from_bytes_with_nul(&z[..=name.len()]).map_err(|_| libc::EINVAL)?;
        self.opener.open_dir_at(parent_fd, c)
    }

    /// Account for a failure on directory `id`.
    fn note_error(&mut self, id: ScanId, errno: c_int) -> Result<(), Incomplete> {
        match errno {
            libc::EPERM | libc::EACCES => {
                let path = node_path(&self.arena, id)?;
                self.stats
                    .unreadable
                    .try_reserve(1)
                    .map_err(|_| Incomplete::OutOfMemory)?;
                self.stats.unreadable.push(path);
                // The path list is for the report; the flag is what lets the
                // node itself render as locked instead of as an empty folder.
                if let Some(node) = self.arena.get_mut(id) {
                    node.flags |= FLAG_PERM_DENIED;
                }
            }
            libc::ENOMEM => {
                // The kernel, not this process's arena, ran out of memory: a
                // shortfall, so flagged like descriptor exhaustion.
                self.stats.incomplete.get_or_insert(Incomplete::OutOfMemory);
            }
            libc::EMFILE | libc::ENFILE => {
                // Not counted in `errors`: that field holds benign races, and
                // this one makes the totals wrong. The first reason wins; a
                // later terminal reason still overwrites it in `walk_serial_with`.
                self.stats.incomplete.get_or_insert(Incomplete::FdExhausted);
            }
            _ => self.stats.errors += 1,
        }
        Ok(())
    }
}

/// The full path of node `id`, rebuilt from the names up the parent chain. The
/// root's stored name is the whole root path.
fn node_path(arena: &Arena, id: ScanId) -> Result<PathBuf, Incomplete> {
    let mut parts: Vec<&[u8]> = Vec::new();
    let mut cur = id;
    while let Some(n) = arena.get(cur) {
        parts.try_reserve(1).map_err(|_| Incomplete::OutOfMemory)?;
        parts.push(arena.name_bytes(n.name));
        cur = n.parent;
    }
    let len = parts.iter().map(|p| p.len() + 1).sum::<usize>();
    let mut bytes: Vec<u8> = Vec::new();
    bytes
        .try_reserve_exact(len)
        .map_err(|_| Incomplete::OutOfMemory)?;
    for part in parts.iter().rev() {
        if !bytes.is_empty() && bytes.last() != Some(&b'/') {
            bytes.push(b'/');
        }
        bytes.extend_from_slice(part);
    }
    Ok(PathBuf::from(std::ffi::OsString::from_vec(bytes)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::fs::{self, File};
    use std::path::Path;
    use tesserae_testutil::Fixture;

    fn opts(root: &Path) -> WalkOptions {
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
    struct SwapBeforeOpen {
        victim: std::path::PathBuf,
        /// `None` swaps in a regular file; `Some(target)` swaps in a symlink.
        symlink_to: Option<&'static str>,
        fired: Cell<u32>,
    }

    impl DirOpener for SwapBeforeOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" && self.fired.get() == 0 {
                fs::remove_dir_all(&self.victim).unwrap();
                match self.symlink_to {
                    None => drop(File::create(&self.victim).unwrap()),
                    Some(t) => std::os::unix::fs::symlink(t, &self.victim).unwrap(),
                }
                self.fired.set(self.fired.get() + 1);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    /// Counts descents without changing them.
    struct CountingOpener {
        opens: Cell<u32>,
    }

    impl DirOpener for CountingOpener {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            self.opens.set(self.opens.get() + 1);
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
            fired: Cell::new(0),
        };

        let (arena, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(opener.fired.get(), 1, "the swap must actually have run");
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
            fired: Cell::new(0),
        };

        let (_, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(opener.fired.get(), 1);
        assert!(fx.path().join("victim").is_symlink());
        assert_eq!(stats.errors, 1);
        assert_eq!(stats.files, 1, "other/f.bin once, not again via victim");
        assert_eq!(stats.incomplete, None);
    }

    /// Fails the open of the directory `victim` with a fixed errno.
    struct FailOpen(c_int);

    impl DirOpener for FailOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return Err(self.0);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn descriptor_exhaustion_is_reported_as_incomplete_not_as_an_error() {
        for errno in [libc::EMFILE, libc::ENFILE] {
            let fx = Fixture::new().unwrap();
            fx.file("victim/inner.bin", 4096).unwrap();
            fx.file("other/f.bin", 4096).unwrap();

            let (_, stats) = walk_serial_with(&opts(fx.path()), &FailOpen(errno)).unwrap();

            assert_eq!(
                stats.incomplete,
                Some(Incomplete::FdExhausted),
                "errno {errno}"
            );
            assert_eq!(stats.errors, 0, "not a benign race (errno {errno})");
            assert!(stats.unreadable.is_empty());
            assert_eq!(stats.files, 1, "the walk went on to other/f.bin");
        }
    }

    /// Fails the first directory it is asked to open with `EMFILE`, whichever
    /// that is, and opens every later one for real.
    struct FailFirstOpen {
        failed: Cell<bool>,
    }

    impl DirOpener for FailFirstOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if !self.failed.replace(true) {
                return Err(libc::EMFILE);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn a_terminal_reason_overrides_an_earlier_fd_exhaustion() {
        // Two directories with five files each. Whichever is opened first
        // fails with EMFILE; the other is entered, and the budget (the root,
        // both directories and two files) runs out inside it. The field must
        // name what stopped the walk, not the earlier skip.
        let fx = Fixture::new().unwrap();
        for i in 0..5 {
            fx.file(&format!("a/f{i}.bin"), 1).unwrap();
            fx.file(&format!("b/f{i}.bin"), 1).unwrap();
        }
        let mut o = opts(fx.path());
        o.node_budget = 5;
        let opener = FailFirstOpen {
            failed: Cell::new(false),
        };

        let (arena, stats) = walk_serial_with(&o, &opener).unwrap();

        assert!(opener.failed.get(), "the EMFILE must actually have fired");
        assert_eq!(arena.len(), 5);
        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
    }

    #[test]
    fn kernel_out_of_memory_is_flagged_not_counted() {
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();

        let (_, stats) = walk_serial_with(&opts(fx.path()), &FailOpen(libc::ENOMEM)).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::OutOfMemory));
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.files, 1, "the walk went on to other/f.bin");
    }

    /// Hands back a regular file's descriptor for the directory `victim`, so
    /// the open succeeds and `getattrlistbulk` is what fails (`ENOTDIR`).
    struct FileForDir(std::path::PathBuf);

    impl DirOpener for FileForDir {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return Ok(OwnedFd::from(File::open(&self.0).unwrap()));
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn an_enumeration_failure_is_absorbed_and_the_walk_continues() {
        // The `getattrlistbulk` error branch. `chmod 0o111` cannot reach it:
        // `open(O_RDONLY)` on a directory needs read permission, so that fails
        // at `openat` (EACCES) before enumeration. A descriptor that opens
        // fine but is not a directory fails in the syscall itself.
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();
        fx.file("plain.bin", 1).unwrap();
        let opener = FileForDir(fx.path().join("plain.bin"));

        let (_, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(stats.errors, 1, "ENOTDIR from getattrlistbulk");
        assert_eq!(stats.incomplete, None);
        assert!(stats.unreadable.is_empty());
        assert_eq!(stats.files, 2, "other/f.bin and plain.bin");
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

        let mut w = Walker {
            opener: &OpenAt,
            buf: Vec::new(),
            attrlist: scan_attrlist(),
            max_depth: 512,
            arena: Arena::new(0, u64::MAX),
            stats: WalkStats::default(),
        };
        let root = w.push(b"root", ScanId::NONE, None).unwrap();
        let mut frame = Frame {
            fd: OwnedFd::from(File::open(fx.path()).unwrap()),
            depth: 0,
            children: Vec::new(),
            next: 0,
        };

        w.consume_batch(&mut frame, root, &buf, 3).unwrap();

        assert_eq!(w.stats.files, 1, "only the entry before the bad one");
        assert_eq!(w.stats.lost_entries, 2, "the bad entry and the one after");
        assert_eq!(w.stats.incomplete, Some(Incomplete::MalformedBatch));
        assert_eq!(w.stats.errors, 0, "a short result, not a stray error");

        // And a batch that is bad from its first entry loses all of it.
        buf[..4].copy_from_slice(&0u32.to_le_bytes());
        w.consume_batch(&mut frame, root, &buf, 3).unwrap();
        assert_eq!(w.stats.lost_entries, 2 + 3);
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
            opens: Cell::new(0),
        };

        let (arena, stats) = walk_serial_with(&o, &opener).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
        assert_eq!(arena.len(), 3);
        assert_eq!(
            opener.opens.get(),
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

    #[test]
    fn unreadable_root_is_an_error_not_a_partial_result() {
        let fx = Fixture::new().unwrap();
        fx.dir("locked").unwrap();
        fx.chmod("locked", 0o000).unwrap();
        let err = walk_serial(&opts(&fx.path().join("locked")))
            .err()
            .expect("walk must fail");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn empty_root_walks_to_a_single_node() {
        let fx = Fixture::new().unwrap();
        let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();
        assert_eq!((arena.len(), stats.dirs, stats.files), (1, 1, 0));
        assert_eq!(stats.incomplete, None);
    }
}
