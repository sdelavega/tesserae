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

//! What the workers of one walk share: the [`Halt`], the [`NodeBudget`], the
//! [`Share`] seam to the pool and the [`WalkerCtx`] that bundles them.

use std::os::fd::BorrowedFd;
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;

#[cfg(doc)]
use super::open_beneath;
use super::Incomplete;
use crate::arena::ScanId;
use crate::boundary::VolumeId;
use crate::dedup::InodeSet;
use crate::progress::Progress;

/// Nodes a worker draws from the shared [`NodeBudget`] at a time. One atomic
/// per node would put every worker on the same cache line for the whole scan;
/// one per thousand is invisible. The cost is that a worker can hold up to
/// this many unused units when the budget runs out, which at the 25M default
/// is under a tenth of a percent.
pub(super) const BUDGET_CHUNK: u64 = 1024;

/// The reason the walk is over, or none yet: one terminal failure in any
/// worker ends the whole walk.
///
/// Only the first reason is kept, and a worker that sees one stops where it is
/// and reports it. See the module's note on why a push failure cannot be
/// local.
pub(crate) struct Halt {
    /// `0` for "still walking"; otherwise an [`Incomplete::code`].
    code: AtomicU8,
}

impl Halt {
    pub(crate) fn new() -> Self {
        Halt {
            code: AtomicU8::new(0),
        }
    }

    /// Record `why` unless a reason is already recorded. First writer wins.
    pub(crate) fn raise(&self, why: Incomplete) {
        // Release so that whatever the failing worker had written is visible
        // to a worker that reads the reason; Relaxed on the failure path
        // because the value is then discarded.
        let _ = self
            .code
            .compare_exchange(0, why.code(), Ordering::Release, Ordering::Relaxed);
    }

    pub(crate) fn reason(&self) -> Option<Incomplete> {
        match self.code.load(Ordering::Acquire) {
            0 => None,
            code => Incomplete::from_code(code),
        }
    }
}

/// The whole walk's node ceiling.
///
/// One counter for every worker, so the limit means what it says however many
/// threads are drawing on it. A worker takes [`BUDGET_CHUNK`] units at a time
/// into a local allowance and spends them one node at a time.
pub(crate) struct NodeBudget {
    remaining: AtomicU64,
}

impl NodeBudget {
    pub(crate) fn new(total: u64) -> Self {
        NodeBudget {
            remaining: AtomicU64::new(total),
        }
    }

    /// Hand out up to `want` units and return how many were granted, which is
    /// `0` once the budget is spent. Relaxed throughout: the counter publishes
    /// no data, and its own modification order is all the accounting needs.
    pub(super) fn take(&self, want: u64) -> u64 {
        let mut now = self.remaining.load(Ordering::Relaxed);
        loop {
            let grant = now.min(want);
            if grant == 0 {
                return 0;
            }
            match self.remaining.compare_exchange_weak(
                now,
                now - grant,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => return grant,
                Err(seen) => now = seen,
            }
        }
    }
}

/// How a worker hands directories to the rest of the pool, and how it reports
/// a fact about a node another worker's arena holds.
///
/// A serial walk has none of this and passes `None`.
pub(crate) trait Share {
    /// Whether the pool has room for more stealable directories. A worker that
    /// is told `false` keeps its remaining subdirectories and descends them
    /// itself with `openat`.
    fn wants_work(&self) -> bool;

    /// Offer `node`, the directory at `rel` (relative to the scan root) and at
    /// absolute depth `depth`, to any worker. The implementation must count
    /// the task before it can be seen, or the termination protocol could
    /// observe an empty pool while this directory is still unwalked.
    fn publish(&self, rel: Arc<Path>, node: ScanId, depth: u16);

    /// Set `flags` on `node`, which belongs to another worker's arena and so
    /// cannot be touched until the walk has collected every arena. Returns
    /// `false` if the flag could not be recorded (no memory for it), so the
    /// caller can say the result is short.
    fn flag_foreign(&self, node: ScanId, flags: u16) -> bool;
}

/// What every worker of one walk has in common.
pub(crate) struct WalkerCtx<'a, O> {
    pub opener: &'a O,
    /// Inodes already seen with more than one link. One instance for the whole
    /// walk, however many workers.
    pub inodes: &'a InodeSet,
    pub budget: &'a NodeBudget,
    pub halt: &'a Halt,
    /// The walk's own counters, which every worker publishes into once per
    /// batch. The pool's supervisor copies them into the caller's
    /// [`Progress`]; see [`crate::progress`] for why they are not the same.
    pub progress: &'a Progress,
    /// The volume the scan root lives on. Every directory opened is compared
    /// with it; see `Walker::admit`.
    pub root_volume: VolumeId,
    /// The scan root as the caller named it. Reported paths are this joined
    /// with a path relative to the root; it is never opened again.
    pub root_path: &'a Path,
    /// The scan root, open for the whole walk: every published directory is
    /// reopened relative to it with [`open_beneath`], and it is the descriptor
    /// asked whether the volume is still there. In a serial walk it is a
    /// duplicate that is only ever asked the latter; `None` in unit tests that
    /// build a walker by hand.
    pub root_dir: Option<BorrowedFd<'a>>,
}
