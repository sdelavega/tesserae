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

//! Hardlink dedup: count each inode's bytes once.
//!
//! A hardlinked file is one inode reachable from several paths. A walk sees
//! every path, so without correction it reports the file's bytes once per
//! link and the total exceeds the disk. [`InodeSet`] fixes that: the walker
//! *claims* an inode the first time it meets it, and every later link to the
//! same inode is recorded with zero size and [`FLAG_HARDLINK_DUP`].
//!
//! [`FLAG_HARDLINK_DUP`]: crate::arena::FLAG_HARDLINK_DUP
//!
//! # Insertion is gated on `link_count > 1`
//!
//! The walker only asks the set about entries whose link count is above one.
//! That gate is the design, not an optimisation: claiming every inode would
//! make the set as large as the file count (megabytes) and a contention point
//! for the parallel walker, while hardlinks are rare outside Time Machine
//! volumes. Gated, the set is empty after a typical scan.
//!
//! Directories report `link_count == 0` (their entries carry no file-attribute
//! group at all), so they never pass the gate and never enter the set. That is
//! intended: directories are not deduped. `ATTR_DIR_LINKCOUNT` is deliberately
//! not requested, so hardlinked directories (HFS+ Time Machine only) are not
//! deduped either; the walker's depth cap bounds that case.
//!
//! # The invariant is the total, not which node holds the bytes
//!
//! Dedup is order-dependent: the first link reached keeps the full size and
//! the rest get zero. The *sum* is the same whatever the order, but *which
//! node* holds the bytes is not. The serial walker is deterministic about
//! it; the parallel walker is not, because "first" is a race. Anything that
//! compares walks, or any test, must therefore assert on totals and on the
//! number of flagged nodes, never on a particular path owning the bytes.
//!
//! # Sharing
//!
//! [`InodeSet`] is sharded with interior mutability so one instance can be
//! shared by reference across worker threads without change. A walk builds its
//! own set and passes it down; nothing is global.

use std::collections::HashSet;
use std::sync::Mutex;

/// Memory for a new entry could not be reserved; see [`InodeSet::try_claim`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReserveFailed;

/// A concurrent set of `(device, inode)` pairs that have been seen.
pub struct InodeSet {
    /// Never empty. A key lives in exactly one shard, chosen by [`Self::shard`].
    shards: Vec<Mutex<HashSet<(i32, u64)>>>,
}

impl InodeSet {
    /// A set with `shards` independent locks. `0` is treated as `1`.
    pub fn new(shards: usize) -> Self {
        let n = shards.max(1);
        InodeSet {
            shards: (0..n).map(|_| Mutex::new(HashSet::new())).collect(),
        }
    }

    /// Record `(dev, ino)` and report whether this call was the first to.
    ///
    /// Returns `true` exactly once per distinct key, however many threads
    /// race: the check and the insert happen under the same shard lock.
    ///
    /// If memory for the new entry cannot be reserved the key is *not*
    /// recorded and this returns `true`, so the caller keeps the bytes. The
    /// failure direction is a total that is too high for the affected links,
    /// never one that loses a file. This form hides the shortfall; the walker
    /// uses [`InodeSet::try_claim`] so it can report it.
    pub fn claim(&self, dev: i32, ino: u64) -> bool {
        self.try_claim(dev, ino).unwrap_or(true)
    }

    /// [`InodeSet::claim`], but an out-of-memory shortfall is reported rather
    /// than absorbed. `Err(ReserveFailed)` means the key was *not* recorded;
    /// the caller should treat the entry as a first claim (keep its bytes) and
    /// announce the shortfall, since the total is now too high.
    pub fn try_claim(&self, dev: i32, ino: u64) -> Result<bool, ReserveFailed> {
        let shard = &self.shards[self.shard(dev, ino)];
        // A panic elsewhere cannot leave a `HashSet` half-updated in a way
        // that matters here, so a poisoned lock is still usable.
        let mut set = shard.lock().unwrap_or_else(|e| e.into_inner());
        if set.contains(&(dev, ino)) {
            return Ok(false);
        }
        set.try_reserve(1).map_err(|_| ReserveFailed)?;
        Ok(set.insert((dev, ino)))
    }

    /// Distinct keys claimed so far, summed over shards. Not a consistent
    /// snapshot while other threads are claiming.
    pub fn len(&self) -> usize {
        self.shards
            .iter()
            .map(|s| s.lock().unwrap_or_else(|e| e.into_inner()).len())
            .sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Spread keys over shards. Inode numbers are sequential, so a plain
    /// modulus would be fine, but mixing in the device and a multiplicative
    /// hash keeps neighbouring inodes from sharing a lock.
    fn shard(&self, dev: i32, ino: u64) -> usize {
        let mixed = (ino ^ (u64::from(dev as u32) << 32)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        ((mixed >> 32) as usize) % self.shards.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arena::{Arena, FLAG_HARDLINK_DUP, FLAG_PERM_DENIED};
    use crate::parse::ObjType;
    use crate::walk::{walk_serial_with_inodes, OpenAt, WalkOptions, WalkStats};
    use std::path::Path;
    use std::sync::{Arc, Barrier};
    use tesserae_testutil::Fixture;

    const MIB: u64 = 1 << 20;

    fn opts(root: &Path) -> WalkOptions {
        WalkOptions {
            root: root.to_path_buf(),
            ..WalkOptions::default()
        }
    }

    /// Walk `root` with a fresh set and hand the set back for inspection.
    fn walk(root: &Path) -> (Arena, WalkStats, InodeSet) {
        let set = InodeSet::new(4);
        let (arena, stats) = walk_serial_with_inodes(&opts(root), &OpenAt, &set).unwrap();
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.incomplete, None);
        (arena, stats, set)
    }

    /// `(logical, allocated)` summed over every node.
    fn totals(arena: &Arena) -> (u64, u64) {
        arena
            .iter()
            .fold((0, 0), |(l, a), (_, n)| (l + n.logical, a + n.allocated))
    }

    /// Non-directory nodes that carry the dedup flag.
    fn flagged(arena: &Arena) -> usize {
        arena
            .iter()
            .filter(|(_, n)| n.flags & FLAG_HARDLINK_DUP != 0)
            .count()
    }

    #[test]
    fn first_claim_is_true_and_repeat_is_false() {
        let s = InodeSet::new(4);
        assert!(s.claim(1, 42));
        assert!(!s.claim(1, 42));
        assert_eq!(s.len(), 1);
    }

    #[test]
    fn try_claim_agrees_with_claim_when_memory_is_available() {
        let s = InodeSet::new(2);
        assert_eq!(s.try_claim(3, 9), Ok(true));
        assert_eq!(s.try_claim(3, 9), Ok(false));
        assert!(!s.claim(3, 9));
    }

    #[test]
    fn same_inode_on_different_devices_claims_separately() {
        let s = InodeSet::new(4);
        assert!(s.claim(1, 42));
        assert!(s.claim(2, 42));
        assert!(!s.claim(1, 42));
        assert!(!s.claim(2, 42));
        assert_eq!(s.len(), 2);
    }

    #[test]
    fn zero_shards_is_clamped_not_a_division_by_zero() {
        let s = InodeSet::new(0);
        assert!(s.claim(1, 1));
        assert!(!s.claim(1, 1));
    }

    #[test]
    fn dedup_set_is_exactly_once_under_contention() {
        // Task 11's parallel walker shares one set across threads. Whatever
        // the interleaving, each key must be won by exactly one claimant:
        // that is the whole correctness contract.
        const KEYS: u64 = 2_000;
        const THREADS: usize = 8;
        let set = Arc::new(InodeSet::new(16));
        // Without a common start each thread's ~2000 uncontended lock
        // operations finish in less time than a thread takes to spawn, so the
        // early threads could be done before the late ones begin and nothing
        // would be contended. The barrier releases every thread at once, and
        // all of them walk the same keys in the same order so that they
        // arrive at each key together: that is the window a non-atomic
        // check-then-insert would lose in. (A per-thread rotation of the key
        // order was tried and made the test weaker: it spreads the threads
        // across different keys, so a split check-then-insert was caught 0
        // times in 20 runs against 20 of 20 for this form.)
        let start = Arc::new(Barrier::new(THREADS));
        let wins: Vec<u64> = std::thread::scope(|scope| {
            let handles: Vec<_> = (0..THREADS)
                .map(|_| {
                    let set = Arc::clone(&set);
                    let start = Arc::clone(&start);
                    scope.spawn(move || {
                        start.wait();
                        (0..KEYS).filter(|&k| set.claim(7, k)).count() as u64
                    })
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        assert_eq!(wins.iter().sum::<u64>(), KEYS, "one winner per key");
        assert_eq!(set.len() as u64, KEYS);
    }

    #[test]
    fn dedup_flag_is_bit_two_and_collides_with_nothing() {
        // Spec section 6 order: dir=0, symlink=1, hardlink_dup=2, perm_denied=3.
        assert_eq!(FLAG_HARDLINK_DUP, 1 << 2);
        assert_eq!(FLAG_PERM_DENIED, 1 << 3);
        assert_eq!(FLAG_HARDLINK_DUP & FLAG_PERM_DENIED, 0);
    }

    #[test]
    fn hardlinked_file_is_counted_once_in_a_walk() {
        // The invariant is the TOTAL. Which of the two links holds the bytes
        // is whichever the walk reaches first: deterministic for the serial
        // walker, but not under Task 11's parallel one. So nothing here may
        // name a node as "the" owner.
        let control = Fixture::new().unwrap();
        control.file("a.bin", MIB).unwrap();
        let (control_arena, _, _) = walk(control.path());
        let (control_logical, control_alloc) = totals(&control_arena);
        assert!(control_alloc >= MIB, "control allocated {control_alloc}");

        let fx = Fixture::new().unwrap();
        fx.file("a.bin", MIB).unwrap();
        fx.hardlink("a.bin", "b.bin").unwrap();

        let (arena, stats, set) = walk(fx.path());

        assert_eq!(stats.files, 2, "both links are still entries");
        assert_eq!(
            totals(&arena),
            (control_logical, control_alloc),
            "two links, one file's worth of bytes"
        );
        let files: Vec<_> = arena
            .iter()
            .map(|(_, n)| n)
            .filter(|n| n.obj_type == ObjType::Reg)
            .collect();
        assert_eq!(files.len(), 2);
        let dups: Vec<_> = files
            .iter()
            .filter(|n| n.flags & FLAG_HARDLINK_DUP != 0)
            .collect();
        let owners: Vec<_> = files
            .iter()
            .filter(|n| n.flags & FLAG_HARDLINK_DUP == 0)
            .collect();
        assert_eq!((dups.len(), owners.len()), (1, 1));
        assert_eq!((dups[0].logical, dups[0].allocated), (0, 0));
        assert_eq!(owners[0].logical, MIB);
        assert_eq!(owners[0].allocated, control_alloc);
        assert_eq!(stats.hardlink_dups, 1);
        assert_eq!(set.len(), 1);
    }

    #[test]
    fn many_links_across_directories_still_count_once() {
        let fx = Fixture::new().unwrap();
        fx.file("x/a.bin", MIB).unwrap();
        fx.hardlink("x/a.bin", "x/b.bin").unwrap();
        fx.hardlink("x/a.bin", "y/c.bin").unwrap();
        fx.hardlink("x/a.bin", "y/z/d.bin").unwrap();
        // An unrelated pair, so the set must tell inodes apart.
        fx.file("p.bin", 4096).unwrap();
        fx.hardlink("p.bin", "q.bin").unwrap();

        let (arena, stats, set) = walk(fx.path());

        assert_eq!(stats.files, 6);
        assert_eq!(flagged(&arena), 4, "3 extra links of a.bin + 1 of p.bin");
        assert_eq!(stats.hardlink_dups, 4);
        assert_eq!(set.len(), 2, "one entry per distinct inode");
        let (logical, _) = totals(&arena);
        assert_eq!(logical, MIB + 4096);
    }

    #[test]
    fn directories_never_enter_the_set() {
        // Directories report link_count 0 (no file-attribute group), so the
        // gate keeps them out. That is intended: only files are deduped.
        let fx = Fixture::new().unwrap();
        fx.file("a/b/c/f.bin", 4096).unwrap();
        fx.file("a/g.bin", 4096).unwrap();
        fx.hardlink("a/g.bin", "a/b/h.bin").unwrap();

        let (arena, stats, set) = walk(fx.path());

        assert!(stats.dirs >= 4);
        assert_eq!(set.len(), 1, "only the one hardlinked file");
        assert!(arena
            .iter()
            .filter(|(_, n)| n.obj_type == ObjType::Dir)
            .all(|(_, n)| n.flags & FLAG_HARDLINK_DUP == 0));
    }

    #[test]
    fn set_stays_empty_when_no_file_has_link_count_above_one() {
        let fx = Fixture::new().unwrap();
        for i in 0..100 {
            fx.file(&format!("d{}/f{i}.bin", i % 10), 512).unwrap();
        }

        let (arena, stats, set) = walk(fx.path());

        assert_eq!(stats.files, 100);
        assert_eq!(set.len(), 0, "the link_count gate keeps the set empty");
        assert_eq!(flagged(&arena), 0);
        assert_eq!(stats.hardlink_dups, 0);
    }
}
