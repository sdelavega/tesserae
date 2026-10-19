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

//! A worker's arena and stats behind a lock ([`Lane`], [`Slot`], [`Held`]),
//! and the directory handle whose close is announced on it ([`Dir`]).

use std::ops::{Deref, DerefMut};
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};

use super::WalkStats;
#[cfg(doc)]
use super::{WalkOptions, Walker};
use crate::arena::{Arena, ScanId};
#[cfg(doc)]
use crate::progress::Progress;
use crate::progress::ProgressValues;

/// A directory the walk holds open, and the lane its close is announced on.
///
/// Closing a directory is a syscall like any other, and on a hung volume one
/// can block, so it is announced on the worker's [`Lane`] exactly as an open
/// is: a worker stuck in `close(2)` is abandoned rather than waited for.
/// Dropping a `Dir` is how the walk closes every directory it opened, on
/// every path out — a finished frame popped, a boundary refusal, an early
/// return that drops the whole stack.
pub(super) struct Dir<'a> {
    /// Always `Some` until the drop takes it.
    fd: Option<OwnedFd>,
    id: ScanId,
    lane: &'a Lane,
}

impl<'a> Dir<'a> {
    pub(super) fn new(fd: OwnedFd, id: ScanId, lane: &'a Lane) -> Self {
        Dir {
            fd: Some(fd),
            id,
            lane,
        }
    }

    pub(super) fn raw(&self) -> RawFd {
        self.fd.as_ref().map_or(-1, AsRawFd::as_raw_fd)
    }
}

impl Drop for Dir<'_> {
    fn drop(&mut self) {
        if let Some(fd) = self.fd.take() {
            self.lane.during(self.id, || drop(fd));
        }
    }
}

/// What a worker builds and the walk's result is made of: its arena, its
/// stats, and how much of them it has published to the shared counters.
pub(crate) struct Slot {
    pub(super) arena: Arena,
    pub(super) stats: WalkStats,
    /// The allocated size of every node pushed, which is what
    /// [`Progress::bytes`] counts. Hardlink duplicates add their stored zero.
    pub(super) bytes: u64,
    /// What has been added to the walk's [`Progress`] so far.
    pub(super) published: ProgressValues,
    /// A test's injected arena failure: pushes are refused once the arena
    /// holds this many nodes. See [`Lane::fail_after`].
    #[cfg(test)]
    pub(super) oom_after: u64,
}

impl Slot {
    pub(super) fn counts(&self) -> ProgressValues {
        ProgressValues {
            dirs: self.stats.dirs,
            files: self.stats.files,
            bytes: self.bytes,
            errors: self.stats.errors,
        }
    }
}

/// `ScanId::NONE`, as a lane's `busy` reads when its worker is not inside a
/// syscall. It can never be a real id.
const IDLE: u64 = ScanId::NONE.to_bits();

/// One worker's [`Slot`] behind a lock, and what the pool's supervisor
/// watches the worker by.
///
/// # Why the arena is locked, and never across a syscall
///
/// A worker can block inside a syscall forever (see
/// [`WalkOptions::stall_timeout`]), and when it does the walk has to return
/// without it — with its arena, because nodes in every other arena may name
/// one of its nodes as their parent, and a forest with a dangling parent
/// cannot be frozen. So the arena cannot live on the worker's stack. It lives
/// here, and the worker holds the lock only while it is changing the slot:
/// pushing a batch, recording a failure, reading names. It releases it across
/// every syscall on a directory — the child `openat`, the reopen beneath the
/// root, `getattrlistbulk`, `fstatfs` and `close` — and announces each one in
/// `busy` for exactly as long as it lasts. A worker that is announced is
/// therefore never holding the lock, and the supervisor can take its slot.
///
/// Taking leaves `None` behind. A worker that comes back from its syscall and
/// finds `None` has been abandoned: it returns without touching anything, and
/// [`Walker::lock`] checks the walk's halt before it even locks.
///
/// # No lock-order cycle
///
/// A worker only ever locks its own lane. The supervisor locks other lanes —
/// to take them, and to climb a stalled directory's path through whichever
/// arenas hold its ancestors — but one at a time, never holding two. So no
/// thread ever waits for a lane while holding another, and there is no cycle
/// to deadlock on.
///
/// # The serial walk keeps the lock
///
/// A serial walk goes through the same [`Walker`] with a lane of its own that
/// nothing else ever locks. The alternative, a lock-free twin behind a
/// generic, would be a second copy of the walk to keep in step with the
/// first, which is the one thing this module exists to avoid. An uncontended
/// lock taken a few times per directory costs nanoseconds against the
/// microseconds of the syscalls between them; the report for this change has
/// the measurement.
///
/// Aligned to 128 bytes, the cache-line size on Apple silicon, so that one
/// worker's announcements do not share a line with its neighbour's.
#[repr(align(128))]
pub(crate) struct Lane {
    slot: Mutex<Option<Slot>>,
    /// The [`ScanId`] bits of the directory this worker is inside a syscall
    /// on, or [`IDLE`].
    busy: AtomicU64,
    /// Syscalls this worker has completed. The watchdog's measure of
    /// progress: unlike the counters it moves even on a run of empty
    /// directories, so a slow volume that is still answering never looks
    /// stalled.
    ticks: AtomicU64,
}

impl Lane {
    pub(crate) fn new(arena: Arena) -> Lane {
        Lane {
            slot: Mutex::new(Some(Slot {
                arena,
                stats: WalkStats::default(),
                bytes: 0,
                published: ProgressValues::ZERO,
                #[cfg(test)]
                oom_after: u64::MAX,
            })),
            busy: AtomicU64::new(IDLE),
            ticks: AtomicU64::new(0),
        }
    }

    /// Make this lane's arena refuse every push once it holds `nodes` nodes,
    /// with [`ArenaError::OutOfMemory`] — the only way to reach that path on
    /// purpose, since a real refusal needs the allocator to fail.
    #[cfg(test)]
    pub(crate) fn fail_after(&self, nodes: u64) {
        if let Some(slot) = self.lock_raw().as_deref_mut() {
            slot.oom_after = nodes;
        }
    }

    /// Run `call`, a syscall on directory `on`, announced. The caller must
    /// not be holding this lane's lock: that is the whole contract, and why
    /// nothing that can block runs inside a [`Held`].
    pub(super) fn during<R>(&self, on: ScanId, call: impl FnOnce() -> R) -> R {
        self.busy.store(on.to_bits(), Ordering::Release);
        let r = call();
        self.busy.store(IDLE, Ordering::Release);
        // Only this worker writes its ticks, so a load and a store suffice;
        // no read-modify-write is needed on a line nobody else writes.
        let ticks = self.ticks.load(Ordering::Relaxed);
        self.ticks.store(ticks.wrapping_add(1), Ordering::Relaxed);
        r
    }

    /// The directory this worker is inside a syscall on, if it is.
    pub(crate) fn busy_on(&self) -> Option<ScanId> {
        match self.busy.load(Ordering::Acquire) {
            IDLE => None,
            bits => Some(ScanId::from_bits(bits)),
        }
    }

    pub(crate) fn ticks(&self) -> u64 {
        self.ticks.load(Ordering::Relaxed)
    }

    /// The slot, locked, unless it has been taken. Poisoning is ignored: a
    /// worker that panicked has its panic resumed on the caller, and the slot
    /// is consistent between any two statements that change it.
    pub(super) fn lock_raw(&self) -> Option<Held<'_>> {
        let guard = self.slot.lock().unwrap_or_else(PoisonError::into_inner);
        guard.is_some().then_some(Held(guard))
    }

    /// Take the slot: its arena, its stats, and the counts not yet published.
    /// `None` if it was taken already. After this the worker can never change
    /// it again.
    pub(crate) fn take(&self) -> Option<(Arena, WalkStats, ProgressValues)> {
        let slot = self
            .slot
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()?;
        let unpublished = slot.counts().since(slot.published);
        Some((slot.arena, slot.stats, unpublished))
    }

    /// Read this lane's arena under its lock. `None` once it has been taken.
    pub(crate) fn read<R>(&self, f: impl FnOnce(&Arena) -> R) -> Option<R> {
        self.lock_raw().map(|held| f(&held.arena))
    }
}

/// A lane's slot, locked and known to be there.
pub(super) struct Held<'a>(MutexGuard<'a, Option<Slot>>);

impl Deref for Held<'_> {
    type Target = Slot;

    fn deref(&self) -> &Slot {
        self.0
            .as_ref()
            .expect("a Held is only made from a slot that is there")
    }
}

impl DerefMut for Held<'_> {
    fn deref_mut(&mut self) -> &mut Slot {
        self.0
            .as_mut()
            .expect("a Held is only made from a slot that is there")
    }
}
