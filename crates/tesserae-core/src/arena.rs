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

//! Chunked bump arena for scan nodes and names.
//!
//! The walker stores millions of entries and hands out [`ScanId`]s that must
//! stay valid for the whole scan. The arena guarantees that by construction:
//!
//! * Every chunk is allocated once, at its full capacity, with
//!   `try_reserve_exact`, and is never grown. A chunk that is full is sealed
//!   and a new chunk is started; nothing is ever pushed past `CHUNK_NODES`
//!   (or `NAME_CHUNK_BYTES`), so no chunk buffer can reallocate.
//! * Only the outer list of chunks grows. That moves the chunk `Vec` headers,
//!   not the heap buffers they point to, so a node's address is unchanged.
//!
//! Allocation never goes through an aborting path: a failed `try_reserve`
//! comes back as [`ArenaError::OutOfMemory`], so a pathological volume
//! degrades into a reported partial result rather than a crash.

use crate::parse::ObjType;

/// Nodes per chunk. A slot index therefore needs 16 bits; [`ScanId`] reserves
/// 24 on purpose, which is also what keeps [`ScanId::NONE`] unmintable.
pub const CHUNK_NODES: usize = 65_536;

/// Bytes per name chunk. Comfortably above `u16::MAX`, so a name that fits a
/// [`NameRef`] always fits an empty chunk.
const NAME_CHUNK_BYTES: usize = 1 << 20;

const THREAD_BITS: u32 = 16;
const CHUNK_BITS: u32 = 24;
const SLOT_BITS: u32 = 24;
const CHUNK_MASK: u64 = (1 << CHUNK_BITS) - 1;
const SLOT_MASK: u64 = (1 << SLOT_BITS) - 1;
const _: () = assert!(THREAD_BITS + CHUNK_BITS + SLOT_BITS == 64);
// Strictly below: the all-ones slot in `ScanId::NONE` must never be issued.
const _: () = assert!((CHUNK_NODES as u64) < SLOT_MASK);

/// A node's address: `(thread:16 | chunk:24 | slot:24)`, most significant
/// field first. Any `u64` can be wrapped in one, so [`Arena::get`] validates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScanId(u64);

impl ScanId {
    /// "No node". All ones, so its slot is `0xFF_FFFF`, which is above any
    /// slot the arena can issue (`< CHUNK_NODES`): it cannot equal a real id.
    pub const NONE: ScanId = ScanId(u64::MAX);

    fn pack(thread: u16, chunk: u32, slot: u32) -> ScanId {
        debug_assert!(u64::from(chunk) <= CHUNK_MASK && u64::from(slot) <= SLOT_MASK);
        ScanId(
            (u64::from(thread) << (CHUNK_BITS + SLOT_BITS))
                | ((u64::from(chunk) & CHUNK_MASK) << SLOT_BITS)
                | (u64::from(slot) & SLOT_MASK),
        )
    }

    /// The arena this id was issued by.
    pub fn thread(self) -> u16 {
        (self.0 >> (CHUNK_BITS + SLOT_BITS)) as u16
    }

    pub fn chunk(self) -> u32 {
        ((self.0 >> SLOT_BITS) & CHUNK_MASK) as u32
    }

    pub fn slot(self) -> u32 {
        (self.0 & SLOT_MASK) as u32
    }
}

/// Where a name's bytes live in the arena's name chunks.
#[derive(Debug, Clone, Copy)]
pub struct NameRef {
    pub chunk: u32,
    pub off: u32,
    pub len: u16,
}

/// [`ScanNode::flags`] bit 2 (spec order: dir, symlink, clone, perm_denied,
/// aggregated): this entry's bytes are counted elsewhere. The walker sets it
/// on every hardlink after the first to the same inode, and zeroes the node's
/// sizes. Which link is "first" is whichever the walk reaches first, so only
/// the total is meaningful, not which node carries it. See [`crate::dedup`].
pub const FLAG_CLONE: u16 = 1 << 2;

/// [`ScanNode::flags`] bit: the directory could not be read for lack of
/// permission, so it holds no children and its size is unknown rather than
/// zero. Set by the walker; the UI renders it as locked.
///
/// `flags` is this program's own semantic space, not `st_flags`. Bits follow
/// the spec's order (dir, symlink, clone, perm_denied, aggregated), so this is
/// bit 3; the node's type already says dir and symlink, which is why those two
/// are not set here.
pub const FLAG_PERM_DENIED: u16 = 1 << 3;

#[derive(Debug, Clone, Copy)]
pub struct ScanNode {
    pub name: NameRef,
    pub parent: ScanId,
    pub obj_type: ObjType,
    pub flags: u16,
    pub logical: u64,
    pub allocated: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArenaError {
    /// The allocator refused a chunk (or the request could not be expressed).
    /// Also returned for a name longer than `u16::MAX` bytes, which a
    /// [`NameRef`] cannot describe; `NAME_MAX` (255 bytes) trips first on any
    /// real filesystem, so only a synthetic buffer reaches it.
    OutOfMemory,
    NodeBudgetExceeded,
}

/// Allocate a `Vec` with room for exactly `cap` elements, reporting failure.
///
/// The one place a chunk is created. `try_reserve_exact` guarantees
/// `capacity() >= cap`, and callers never push more than `cap`.
fn alloc_chunk<T>(cap: usize) -> Result<Vec<T>, ArenaError> {
    let mut v = Vec::new();
    v.try_reserve_exact(cap)
        .map_err(|_| ArenaError::OutOfMemory)?;
    Ok(v)
}

/// One thread's arena. Not shared: each walker thread owns its own, and the
/// `thread` in a [`ScanId`] says which.
pub struct Arena {
    thread: u16,
    node_budget: u64,
    count: u64,
    /// Each inner `Vec` is created at full capacity and sealed at
    /// `CHUNK_NODES`; only this outer list ever grows.
    nodes: Vec<Vec<ScanNode>>,
    /// Same discipline, `NAME_CHUNK_BYTES` per chunk.
    names: Vec<Vec<u8>>,
}

impl Arena {
    pub fn new(thread: u16, node_budget: u64) -> Self {
        Arena {
            thread,
            node_budget,
            count: 0,
            nodes: Vec::new(),
            names: Vec::new(),
        }
    }

    /// Copy `bytes` into the name chunks. The bytes are stored verbatim and
    /// never interpreted as text.
    pub fn push_name(&mut self, bytes: &[u8]) -> Result<NameRef, ArenaError> {
        // A `NameRef` stores the length in 16 bits. A longer name maps to
        // `OutOfMemory` because `ArenaError` has no better fit, and a lower
        // limit trips first on any real filesystem: `NAME_MAX` is 255 bytes,
        // so only a synthetic buffer can reach this.
        let len = u16::try_from(bytes.len()).map_err(|_| ArenaError::OutOfMemory)?;
        let fits = self
            .names
            .last()
            .is_some_and(|c| c.len() + bytes.len() <= NAME_CHUNK_BYTES);
        if !fits {
            // Reserve the outer slot first so the push below cannot abort,
            // and allocate the chunk before touching the list so a failure
            // leaves the arena unchanged.
            self.names
                .try_reserve(1)
                .map_err(|_| ArenaError::OutOfMemory)?;
            let chunk = alloc_chunk::<u8>(NAME_CHUNK_BYTES)?;
            self.names.push(chunk);
        }
        let chunk_idx = self.names.len() - 1;
        let chunk = &mut self.names[chunk_idx];
        debug_assert!(chunk.capacity() >= NAME_CHUNK_BYTES);
        // Everything fallible happens before the append, so an `Err` never
        // leaves bytes behind. Within capacity:
        // `len + bytes.len() <= NAME_CHUNK_BYTES <= capacity`.
        //
        // Both conversions are unreachable in practice: a name chunk index
        // past `u32::MAX` would take 4 PiB of names, and `off` is bounded by
        // `NAME_CHUNK_BYTES` (1 MiB).
        let chunk_ref = u32::try_from(chunk_idx).map_err(|_| ArenaError::OutOfMemory)?;
        let off = u32::try_from(chunk.len()).map_err(|_| ArenaError::OutOfMemory)?;
        chunk.extend_from_slice(bytes);
        Ok(NameRef {
            chunk: chunk_ref,
            off,
            len,
        })
    }

    pub fn push_node(&mut self, n: ScanNode) -> Result<ScanId, ArenaError> {
        if self.count >= self.node_budget {
            return Err(ArenaError::NodeBudgetExceeded);
        }
        let open = self.nodes.last().is_some_and(|c| c.len() < CHUNK_NODES);
        if !open {
            // The id packs the chunk index into 24 bits. Running out means
            // about 1.1T nodes (2^24 chunks of 65_536) against a 25M-node
            // budget, a factor of roughly 44,000, so the budget trips long
            // before this does. If it ever did, "too many nodes" is the
            // accurate error, not a mislabel.
            if self.nodes.len() as u64 > CHUNK_MASK {
                return Err(ArenaError::NodeBudgetExceeded);
            }
            self.nodes
                .try_reserve(1)
                .map_err(|_| ArenaError::OutOfMemory)?;
            let chunk = alloc_chunk::<ScanNode>(CHUNK_NODES)?;
            self.nodes.push(chunk);
        }
        let chunk_idx = self.nodes.len() - 1;
        let chunk = &mut self.nodes[chunk_idx];
        // The invariant that makes references stable: this chunk is open
        // (`len < CHUNK_NODES <= capacity`), so the push cannot reallocate.
        debug_assert!(chunk.len() < CHUNK_NODES && chunk.capacity() >= CHUNK_NODES);
        let slot = chunk.len();
        chunk.push(n);
        self.count += 1;
        Ok(ScanId::pack(self.thread, chunk_idx as u32, slot as u32))
    }

    pub fn len(&self) -> u64 {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// The node `id` names, or `None` if `id` was not issued by this arena
    /// or names a slot that holds nothing yet.
    pub fn get(&self, id: ScanId) -> Option<&ScanNode> {
        if id.thread() != self.thread {
            return None;
        }
        self.nodes.get(id.chunk() as usize)?.get(id.slot() as usize)
    }

    /// Every node and its id, in the order the nodes were pushed.
    ///
    /// Within one arena a parent is always pushed before its children, so a
    /// reverse walk visits children first, which is what a bottom-up rollup
    /// wants.
    pub fn iter(&self) -> impl Iterator<Item = (ScanId, &ScanNode)> + '_ {
        self.nodes.iter().enumerate().flat_map(move |(c, chunk)| {
            chunk.iter().enumerate().map(move |(s, n)| {
                // `c` and `s` are bounded by the same checks `push_node` makes
                // before it issues an id, so neither conversion truncates.
                (ScanId::pack(self.thread, c as u32, s as u32), n)
            })
        })
    }

    /// Mutable access to a node already pushed, for facts learned after the
    /// push (a directory turning out to be unreadable). Same validation as
    /// [`Arena::get`]. Chunks never reallocate, so this cannot move a node.
    pub fn get_mut(&mut self, id: ScanId) -> Option<&mut ScanNode> {
        if id.thread() != self.thread {
            return None;
        }
        self.nodes
            .get_mut(id.chunk() as usize)?
            .get_mut(id.slot() as usize)
    }

    /// The bytes behind `r`. A `NameRef` that does not describe stored bytes
    /// (for instance one from another arena) yields an empty slice.
    pub fn name_bytes(&self, r: NameRef) -> &[u8] {
        let off = r.off as usize;
        self.names
            .get(r.chunk as usize)
            .and_then(|c| c.get(off..off + usize::from(r.len)))
            .unwrap_or(&[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(logical: u64) -> ScanNode {
        ScanNode {
            name: NameRef {
                chunk: 0,
                off: 0,
                len: 0,
            },
            parent: ScanId::NONE,
            obj_type: ObjType::Reg,
            flags: 0,
            logical,
            allocated: logical,
        }
    }

    #[test]
    fn iter_yields_every_node_in_push_order_with_resolvable_ids() {
        let mut arena = Arena::new(5, u64::MAX);
        let n = CHUNK_NODES as u64 + 3;
        let pushed: Vec<ScanId> = (0..n).map(|i| arena.push_node(node(i)).unwrap()).collect();
        let seen: Vec<(ScanId, u64)> = arena.iter().map(|(id, nd)| (id, nd.logical)).collect();
        assert_eq!(seen.len() as u64, n);
        for (i, (id, logical)) in seen.iter().enumerate() {
            assert_eq!(*id, pushed[i]);
            assert_eq!(*logical, i as u64);
            assert_eq!(arena.get(*id).unwrap().logical, i as u64);
        }
        assert_eq!(Arena::new(0, 1).iter().count(), 0);
    }

    #[test]
    fn get_mut_edits_in_place_and_validates_like_get() {
        let mut arena = Arena::new(2, u64::MAX);
        let id = arena.push_node(node(7)).unwrap();
        arena.get_mut(id).unwrap().flags |= FLAG_PERM_DENIED;
        assert_eq!(arena.get(id).unwrap().flags, FLAG_PERM_DENIED);
        assert_eq!(arena.get(id).unwrap().logical, 7);
        assert!(arena.get_mut(ScanId::NONE).is_none());
        assert!(
            arena.get_mut(ScanId::pack(3, 0, 0)).is_none(),
            "wrong thread"
        );
        assert!(arena.get_mut(ScanId::pack(2, 0, 1)).is_none(), "empty slot");
    }

    #[test]
    fn scan_id_round_trips_thread_chunk_slot() {
        let id = ScanId::pack(7, 1234, 56789);
        assert_eq!(id.thread(), 7);
        assert_eq!(id.chunk(), 1234);
        assert_eq!(id.slot(), 56789);
    }

    #[test]
    fn push_node_returns_increasing_ids_across_chunk_boundary() {
        let mut arena = Arena::new(3, u64::MAX);
        let mut ids = Vec::new();
        for i in 0..=CHUNK_NODES as u64 {
            ids.push(arena.push_node(node(i)).unwrap());
        }
        let last_in_first = ids[CHUNK_NODES - 1];
        let first_in_second = ids[CHUNK_NODES];
        assert_eq!((last_in_first.chunk(), last_in_first.slot()), (0, 65_535));
        assert_eq!((first_in_second.chunk(), first_in_second.slot()), (1, 0));
        // The chunk index steps exactly once, at the boundary, and nowhere else.
        let steps = ids
            .windows(2)
            .filter(|w| w[1].chunk() != w[0].chunk())
            .count();
        assert_eq!(steps, 1);
        assert!(ids.iter().all(|id| id.thread() == 3));
        assert_eq!(arena.len(), CHUNK_NODES as u64 + 1);
    }

    #[test]
    fn existing_node_references_survive_chunk_growth() {
        let mut arena = Arena::new(0, u64::MAX);
        let id0 = arena.push_node(node(42)).unwrap();
        for i in 0..CHUNK_NODES as u64 {
            arena.push_node(node(i)).unwrap();
        }
        let n = arena.get(id0).expect("id 0 still resolves");
        assert_eq!((n.logical, n.allocated), (42, 42));
    }

    #[test]
    fn node_chunks_never_reallocate() {
        // The invariant itself, not allocator behaviour: every chunk is
        // created at exactly CHUNK_NODES capacity and never exceeds it (a
        // growing push would at least double the capacity), and its buffer
        // pointer never changes while the outer list regrows (it holds 4
        // chunk headers before its first regrowth, then 8; nine chunks
        // forces both).
        let mut arena = Arena::new(0, u64::MAX);
        let id0 = arena.push_node(node(1)).unwrap();
        let addr0 = arena.get(id0).unwrap() as *const ScanNode;
        let mut seen: Vec<*const ScanNode> = Vec::new();
        for i in 0..(9 * CHUNK_NODES as u64) {
            arena.push_node(node(i)).unwrap();
            // Record each chunk's pointer the moment it exists.
            while seen.len() < arena.nodes.len() {
                seen.push(arena.nodes[seen.len()].as_ptr());
            }
            if (i as usize).is_multiple_of(CHUNK_NODES / 4) {
                for (c, p) in arena.nodes.iter().zip(&seen) {
                    assert_eq!(c.as_ptr(), *p);
                }
            }
        }
        assert_eq!(seen.len(), arena.nodes.len());
        assert!(arena.nodes.len() >= 9);
        for (idx, (c, p)) in arena.nodes.iter().zip(&seen).enumerate() {
            assert_eq!(c.capacity(), CHUNK_NODES, "node chunk {idx} capacity");
            assert_eq!(c.as_ptr(), *p, "node chunk {idx} moved");
        }
        // Redundant with the above, but it is the property callers rely on.
        assert_eq!(arena.get(id0).unwrap() as *const ScanNode, addr0);
    }

    #[test]
    fn name_chunks_never_reallocate() {
        let mut arena = Arena::new(0, 10);
        let name = [b'n'; 255];
        let mut seen: Vec<*const u8> = Vec::new();
        for _ in 0..(5 * NAME_CHUNK_BYTES / name.len()) {
            arena.push_name(&name).unwrap();
            while seen.len() < arena.names.len() {
                seen.push(arena.names[seen.len()].as_ptr());
            }
        }
        assert_eq!(seen.len(), arena.names.len());
        assert!(arena.names.len() >= 5);
        for (idx, (c, p)) in arena.names.iter().zip(&seen).enumerate() {
            assert_eq!(c.capacity(), NAME_CHUNK_BYTES, "name chunk {idx} capacity");
            assert_eq!(c.as_ptr(), *p, "name chunk {idx} moved");
            assert!(c.len() <= NAME_CHUNK_BYTES);
        }
    }

    #[test]
    fn name_bytes_round_trip_non_utf8() {
        let mut arena = Arena::new(0, 10);
        let r = arena.push_name(b"bad\xff\xfename").unwrap();
        assert_eq!(arena.name_bytes(r), b"bad\xff\xfename");
    }

    #[test]
    fn names_round_trip_across_name_chunk_boundary() {
        let mut arena = Arena::new(0, 10);
        let name = [b'x'; 255];
        let mut refs = Vec::new();
        // Enough names to spill into a second name chunk several times over.
        for i in 0..(3 * NAME_CHUNK_BYTES / name.len()) {
            let mut n = name;
            n[0] = (i % 251) as u8;
            refs.push((arena.push_name(&n).unwrap(), n));
        }
        assert!(refs.iter().any(|(r, _)| r.chunk > 0));
        for (r, n) in &refs {
            assert_eq!(arena.name_bytes(*r), n);
        }
    }

    #[test]
    fn empty_name_round_trips() {
        let mut arena = Arena::new(0, 10);
        let r = arena.push_name(b"").unwrap();
        assert_eq!(arena.name_bytes(r), b"");
    }

    #[test]
    fn name_bytes_of_a_foreign_ref_is_empty_not_a_panic() {
        let arena = Arena::new(0, 10);
        let bogus = NameRef {
            chunk: 9,
            off: u32::MAX,
            len: u16::MAX,
        };
        assert_eq!(arena.name_bytes(bogus), b"");
    }

    #[test]
    fn push_node_past_budget_returns_node_budget_exceeded() {
        let mut arena = Arena::new(0, 10);
        for i in 0..10 {
            assert!(
                arena.push_node(node(i)).is_ok(),
                "node {i} is within budget"
            );
        }
        assert_eq!(
            arena.push_node(node(10)),
            Err(ArenaError::NodeBudgetExceeded)
        );
        // The refusal stored nothing, and the arena is still usable for reads.
        assert_eq!(arena.len(), 10);
    }

    #[test]
    fn is_empty_tracks_len() {
        let mut arena = Arena::new(0, 10);
        assert!(arena.is_empty());
        arena.push_node(node(1)).unwrap();
        assert!(!arena.is_empty());
        assert_eq!(arena.len(), 1);
    }

    #[test]
    fn zero_budget_refuses_the_first_node() {
        let mut arena = Arena::new(0, 0);
        assert_eq!(
            arena.push_node(node(0)),
            Err(ArenaError::NodeBudgetExceeded)
        );
        assert_eq!(arena.len(), 0);
    }

    #[test]
    fn get_rejects_every_out_of_range_component() {
        let mut arena = Arena::new(5, u64::MAX);
        let id = arena.push_node(node(1)).unwrap();
        assert!(arena.get(id).is_some());
        // Wrong thread: this id belongs to a different arena.
        assert!(arena.get(ScanId::pack(6, 0, 0)).is_none());
        // Chunk that does not exist.
        assert!(arena.get(ScanId::pack(5, 1, 0)).is_none());
        assert!(arena.get(ScanId::pack(5, 0xFF_FFFF, 0)).is_none());
        // Slot one past the last node stored in an existing chunk.
        assert!(arena.get(ScanId::pack(5, 0, 1)).is_none());
        // Slot beyond the chunk capacity entirely, up to the 24-bit maximum.
        assert!(arena.get(ScanId::pack(5, 0, CHUNK_NODES as u32)).is_none());
        assert!(arena.get(ScanId::pack(5, 0, 0xFF_FFFF)).is_none());
    }

    #[test]
    fn get_rejects_the_slot_just_past_a_full_chunk() {
        let mut arena = Arena::new(0, u64::MAX);
        for i in 0..CHUNK_NODES as u64 {
            arena.push_node(node(i)).unwrap();
        }
        assert!(arena
            .get(ScanId::pack(0, 0, CHUNK_NODES as u32 - 1))
            .is_some());
        assert!(arena.get(ScanId::pack(0, 0, CHUNK_NODES as u32)).is_none());
        // The next chunk is not allocated until a node needs it.
        assert!(arena.get(ScanId::pack(0, 1, 0)).is_none());
    }

    #[test]
    fn none_never_resolves_and_cannot_be_a_real_id() {
        // A real slot is below CHUNK_NODES (a const assert pins that below the
        // 24-bit maximum), so NONE (all ones) can never be
        // minted, whichever thread and chunk are used.
        assert_eq!(ScanId::NONE.slot(), 0xFF_FFFF);
        assert_ne!(
            ScanId::NONE,
            ScanId::pack(0xFFFF, 0xFF_FFFF, CHUNK_NODES as u32 - 1)
        );
        let mut arena = Arena::new(0xFFFF, u64::MAX);
        let id = arena.push_node(node(1)).unwrap();
        assert_ne!(id, ScanId::NONE);
        assert!(arena.get(ScanId::NONE).is_none());
    }

    #[test]
    fn scan_node_is_forty_bytes() {
        // The sizing in the design (65_536 nodes is about 2.6 MB) assumes it.
        assert_eq!(std::mem::size_of::<ScanNode>(), 40);
    }

    #[test]
    fn chunk_allocation_failure_is_an_error_not_an_abort() {
        // usize::MAX elements overflows the layout computation; the point is
        // that it comes back as a Result.
        assert_eq!(
            alloc_chunk::<ScanNode>(usize::MAX).err(),
            Some(ArenaError::OutOfMemory)
        );
        assert_eq!(
            alloc_chunk::<u8>(usize::MAX).err(),
            Some(ArenaError::OutOfMemory)
        );
    }
}
