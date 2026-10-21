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

//! The freeze pass: scattered per-worker arenas in, one immutable
//! [`Snapshot`] out.
//!
//! # Why the result is shaped the way it is
//!
//! * **Children are contiguous and sorted descending by `allocated`.** The
//!   squarified treemap lays out a directory from exactly that slice, so the
//!   cost of ordering is paid once here and not on every frame.
//! * **A directory's size is a rollup.** The kernel reports no size for a
//!   directory, so its `logical` and `allocated` are `0` in the arena and
//!   become the sum of everything beneath it only here. Nothing in this module
//!   adds, subtracts or estimates anything else: a node starts from its own
//!   figures and gains its children's.
//! * **A directory's modification time is a rollup too**, but of the
//!   maximum rather than the sum: the latest of its own time and every
//!   descendant's, so the treemap's age colouring shows when anything inside
//!   it last changed. Only times at or before the scan's start
//!   ([`WalkStats::started_at`]) count: a file stamped in the future (measured:
//!   170 files dated 2076 on one Data volume) would otherwise make every
//!   ancestor up to the root look newest. A directory with no such time
//!   anywhere in its subtree keeps its own, as read. A file's or symlink's
//!   time is never altered.
//!
//! # Passes
//!
//! 1. **Map.** Give every node, across every arena, one dense index, and
//!    resolve each node's [`ScanId`] parent to such an index. The id's thread
//!    field selects the arena; chunk and slot index within it.
//! 2. **Count and prefix-sum.** Count children per parent, then an exclusive
//!    prefix sum turns the counts into the start of each parent's range in a
//!    child-index array. A parent with no children gets an empty range.
//! 3. **Scatter.** Place every node in its parent's range.
//! 4. **Roll up.** Walk from the root to get an order in which parents precede
//!    children, then sum sizes, and take the latest modification time,
//!    bottom-up along the reverse of it.
//! 5. **Sort.** Order each parent's range descending by rolled-up `allocated`.
//!    This must come *after* the rollup: before it every directory reads zero
//!    and would sort to the end.
//! 6. **Emit.** Walk the sorted tree breadth-first, writing each node's
//!    children out contiguously, which fixes the final index of every node.
//!
//! The order in passes 4 to 6 is a walk from the root, not the arenas' own
//! order, because across arenas a child can come before its parent. Within one
//! arena a parent always precedes its children, but arenas are concatenated in
//! whatever order the caller supplies.
//!
//! # Preconditions
//!
//! The arenas must hold exactly one tree: one node whose parent is
//! [`ScanId::NONE`], every other node's parent present in some arena, no
//! cycles, and no two non-empty arenas sharing a thread tag. A walk produces
//! this by construction (a parent is pushed before its children, and a node
//! can only name a parent that was already issued an id). A violation means a
//! bug in the walker, and is a panic here rather than a quietly wrong tree.
//! See [`try_freeze`] for what each panic is bounded by.

use crate::arena::{Arena, ScanId, ScanNode, CHUNK_NODES};
use crate::node::{Snapshot, TessNode, FLAG_DIR, FLAG_SYMLINK, NODE_NONE};
use crate::parse::ObjType;
use crate::walk::WalkStats;

/// Why [`try_freeze`] produced no snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FreezeError {
    /// The allocator refused one of the freeze's working arrays or the output.
    /// Nothing was built; the arenas were consumed.
    OutOfMemory,
    /// The names add up to more than `u32::MAX` bytes, which
    /// [`TessNode::name_off`] cannot address. Reachable inside the node budget:
    /// the limit binds once the average name exceeds about 172 bytes
    /// (4 GiB / 25M), and 16.8M names of the 255-byte maximum reach it.
    NamesTooLarge,
}

impl std::fmt::Display for FreezeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FreezeError::OutOfMemory => f.write_str("out of memory building the snapshot"),
            FreezeError::NamesTooLarge => {
                f.write_str("the names total more than 4 GiB and cannot be addressed")
            }
        }
    }
}

impl std::error::Error for FreezeError {}

/// The total name bytes as a `usize`, if every offset into it fits 32 bits.
fn checked_name_bytes(total: u64) -> Result<usize, FreezeError> {
    u32::try_from(total)
        .map(|t| t as usize)
        .map_err(|_| FreezeError::NamesTooLarge)
}

/// Allocate room for exactly `n` elements, reporting failure. The only way
/// this module obtains memory: every push after this stays within capacity,
/// so none can reallocate and abort.
fn reserved<T>(n: usize) -> Result<Vec<T>, FreezeError> {
    let mut v = Vec::new();
    v.try_reserve_exact(n)
        .map_err(|_| FreezeError::OutOfMemory)?;
    Ok(v)
}

/// [`reserved`], then `n` copies of `value`.
fn filled<T: Clone>(n: usize, value: T) -> Result<Vec<T>, FreezeError> {
    let mut v = reserved(n)?;
    v.resize(n, value);
    Ok(v)
}

/// Freeze the arenas of one scan into a [`Snapshot`].
///
/// Serial callers pass `vec![arena]`; the parallel walker passes one arena per
/// worker. No arenas, or only empty ones, give a snapshot with no nodes and
/// `root == NODE_NONE`.
///
/// This is [`try_freeze`] for callers with nowhere to report a failure. It
/// panics where `try_freeze` returns a [`FreezeError`], so a host that must
/// survive a pathological volume calls `try_freeze` instead.
///
/// # Panics
///
/// On any [`FreezeError`], and as `try_freeze` documents.
pub fn freeze(arenas: Vec<Arena>, stats: WalkStats) -> Snapshot {
    match try_freeze(arenas, stats) {
        Ok(snapshot) => snapshot,
        Err(FreezeError::OutOfMemory) => panic!("freeze: out of memory building the snapshot"),
        Err(FreezeError::NamesTooLarge) => panic!("freeze: more than 4 GiB of names"),
    }
}

/// [`freeze`], with allocation failure reported instead of fatal.
///
/// Every allocation, including the 48-byte nodes and 8-byte identity side
/// array, goes through `try_reserve_exact`. Working arrays coexist with the
/// arenas until freeze finishes, so peak usage exceeds the final snapshot.
/// `tests/freeze_oom.rs` fails each allocation in turn to hold that to account.
///
/// # Errors
///
/// * [`FreezeError::OutOfMemory`]: an allocation was refused.
/// * [`FreezeError::NamesTooLarge`]: the names total more than `u32::MAX`
///   bytes, because [`TessNode::name_off`] is 32 bits. This is a threshold,
///   not a remote edge: with a 25M-node budget it binds once the average name
///   exceeds about 172 bytes, and 16.8M names at the 255-byte maximum reach
///   it. (A typical ~30-byte average would need ~143M entries, so ordinary
///   volumes trip the node budget first.)
///
/// # Panics
///
/// Malformed input and the representation limits below panic rather than return an
/// error, because they are not conditions of the machine:
///
/// * **Programmer errors a walk does not produce:** no root or more than one,
///   a parent that no supplied arena holds, a parent cycle, or two non-empty
///   arenas sharing a thread tag. A walk pushes a parent before its children
///   and a node can only name an id already issued, so these need a walker
///   bug or a caller who dropped an arena. A tree that rendered anyway would
///   be wrong, which is worse than no tree.
/// * **A directory total above `u64::MAX`** (16 EiB), which no volume holds;
///   a sum is never saturated, since a clamped size would be a silently
///   wrong one.
/// * **`u32::MAX` nodes or more**, because indices are 32 bits. That is about
///   170 times the node budget, which is a ceiling on the whole walk however
///   many arenas it was gathered into (`walk::NodeBudget`), so it is far
///   below.
///
/// The FFI boundary wraps calls in `catch_unwind` (release builds keep
/// `panic = "unwind"`).
pub fn try_freeze(arenas: Vec<Arena>, stats: WalkStats) -> Result<Snapshot, FreezeError> {
    // Pass 1: one dense index per node, across every arena.
    let index = IdIndex::new(&arenas)?;
    let n = index.total;
    if n == 0 {
        return Ok(Snapshot {
            nodes: Vec::new(),
            file_ids: Vec::new(),
            names: Vec::new(),
            root: NODE_NONE,
            stats,
        });
    }
    let mut src: Vec<&ScanNode> = reserved(n)?;
    let mut arena_of: Vec<u16> = reserved(n)?;
    let mut name_bytes = 0u64;
    for (a, arena) in arenas.iter().enumerate() {
        for (node_id, node) in arena.iter() {
            debug_assert_eq!(index.resolve(node_id), Some(src.len()));
            src.push(node);
            // At most 65_536 arenas: distinct non-empty thread tags.
            arena_of.push(u16::try_from(a).expect("more than 65_536 arenas"));
            name_bytes += u64::from(node.name.len);
        }
    }
    let name_bytes = checked_name_bytes(name_bytes)?;
    let name_of = |v: usize| arenas[usize::from(arena_of[v])].name_bytes(src[v].name);

    let mut parent: Vec<u32> = reserved(n)?;
    let mut root = None;
    for (v, node) in src.iter().enumerate() {
        if node.parent == ScanId::NONE {
            assert!(root.is_none(), "freeze needs exactly one root, found two");
            root = Some(v);
            parent.push(NODE_NONE);
        } else {
            let p = index
                .resolve(node.parent)
                .expect("a node names a parent that no arena holds");
            parent.push(p as u32);
        }
    }
    let root = root.expect("freeze needs exactly one root, found none");

    // Pass 2: children per parent, then an exclusive prefix sum. `off[v]..
    // off[v + 1]` is v's range in `kids`; `off` has n + 1 entries so that the
    // last node's range has an end, and a node with no children has an empty
    // range (`off[v] == off[v + 1]`) rather than an invalid one.
    let mut off = filled(n + 1, 0u32)?;
    for &p in &parent {
        if p != NODE_NONE {
            off[p as usize + 1] += 1;
        }
    }
    for v in 0..n {
        off[v + 1] += off[v];
    }
    debug_assert_eq!(off[n] as usize, n - 1, "every node but the root is a child");

    // Pass 3: scatter each node into its parent's range.
    let mut kids = filled(n - 1, 0u32)?;
    let mut next = reserved(n + 1)?;
    next.extend_from_slice(&off);
    for (v, &p) in parent.iter().enumerate() {
        if p != NODE_NONE {
            kids[next[p as usize] as usize] = v as u32;
            next[p as usize] += 1;
        }
    }
    drop(next);
    let range = |v: usize| off[v] as usize..off[v + 1] as usize;

    // Pass 4: roll sizes up. A walk from the root visits parents before their
    // children whatever order the arenas were supplied in, so its reverse
    // visits every child before its parent. A node not reached from the root
    // (an orphaned cycle) shows up as a short order.
    let order = breadth_first(root, &kids, &range, n)?;
    assert_eq!(
        order.len(),
        n,
        "freeze found nodes unreachable from the root (a parent cycle)"
    );
    let mut logical: Vec<u64> = reserved(n)?;
    logical.extend(src.iter().map(|x| x.logical));
    let mut allocated: Vec<u64> = reserved(n)?;
    allocated.extend(src.iter().map(|x| x.allocated));
    // `latest[v]` is the newest time at or before `cutoff` in v's subtree,
    // meaningful only where `dated[v]`; a flag rather than a sentinel value,
    // so that every `i64` stays a time.
    let cutoff = stats.started_at;
    let mut latest: Vec<i64> = reserved(n)?;
    let mut dated: Vec<bool> = reserved(n)?;
    for x in &src {
        let counts = x.modified <= cutoff;
        latest.push(if counts { x.modified } else { 0 });
        dated.push(counts);
    }
    for &v in order.iter().rev() {
        let p = parent[v as usize];
        if p != NODE_NONE {
            // A saturated total would be a silently wrong directory size,
            // so an overflow is loud instead.
            logical[p as usize] = logical[p as usize]
                .checked_add(logical[v as usize])
                .expect("a directory's logical size overflows u64");
            allocated[p as usize] = allocated[p as usize]
                .checked_add(allocated[v as usize])
                .expect("a directory's allocated size overflows u64");
            // Every child is final before its parent is read (reverse
            // breadth-first order), so this is the max over the subtree.
            let (p, v) = (p as usize, v as usize);
            if dated[v] && (!dated[p] || latest[v] > latest[p]) {
                latest[p] = latest[v];
                dated[p] = true;
            }
        }
    }
    drop(order);

    // Pass 5: sort every sibling range, largest first. Sizes are final now,
    // so a directory sorts by what it contains. Ties go to the name and then
    // to the dense index, so equal sizes still give one deterministic order.
    // An unstable sort works in place, so it allocates nothing.
    for v in 0..n {
        kids[range(v)].sort_unstable_by(|&a, &b| {
            let (a, b) = (a as usize, b as usize);
            allocated[b]
                .cmp(&allocated[a])
                .then_with(|| name_of(a).cmp(name_of(b)))
                .then_with(|| a.cmp(&b))
        });
    }

    // Pass 6: lay the sorted tree out breadth-first. Each node's children are
    // appended together, so they are contiguous, and the position at which
    // they were appended is `child_start`.
    let mut layout: Vec<u32> = reserved(n)?;
    let mut child_start: Vec<u32> = reserved(n)?;
    layout.push(root as u32);
    let mut at = 0;
    while at < layout.len() {
        let v = layout[at] as usize;
        let ks = &kids[range(v)];
        child_start.push(if ks.is_empty() {
            0
        } else {
            layout.len() as u32
        });
        layout.extend_from_slice(ks);
        at += 1;
    }
    assert_eq!(layout.len(), n, "layout must place every node exactly once");
    let mut final_of = filled(n, NODE_NONE)?;
    for (i, &v) in layout.iter().enumerate() {
        final_of[v as usize] = i as u32;
    }

    let mut names: Vec<u8> = reserved(name_bytes)?;
    let mut nodes: Vec<TessNode> = reserved(n)?;
    let mut file_ids: Vec<u64> = reserved(n)?;
    for (i, &v) in layout.iter().enumerate() {
        let v = v as usize;
        let name = name_of(v);
        // `names` holds exactly the summed lengths, checked to fit 32 bits.
        let name_off = names.len() as u32;
        names.extend_from_slice(name);
        let mut flags = src[v].flags;
        match src[v].obj_type {
            ObjType::Dir => flags |= FLAG_DIR,
            ObjType::Lnk => flags |= FLAG_SYMLINK,
            ObjType::Reg | ObjType::Other => {}
        }
        file_ids.push(src[v].file_id);
        nodes.push(TessNode {
            name_off,
            // `NameRef::len` is a u16, so this is the same width.
            name_len: name.len() as u16,
            flags,
            parent: match parent[v] {
                NODE_NONE => NODE_NONE,
                p => final_of[p as usize],
            },
            child_start: child_start[i],
            child_count: off[v + 1] - off[v],
            logical: logical[v],
            allocated: allocated[v],
            modified: match src[v].obj_type {
                ObjType::Dir if dated[v] => latest[v],
                // A leaf as read; a directory with nothing dated at or
                // before the cutoff, its own time as read.
                _ => src[v].modified,
            },
        });
    }
    Ok(Snapshot {
        nodes,
        file_ids,
        names,
        root: 0,
        stats,
    })
}

/// Indices from `root` in breadth-first order, over the child lists `kids`
/// with ranges given by `range`. Visits only what is reachable from `root`.
/// Each node sits in at most one range, so `capacity` (the node count) holds
/// the whole order and nothing reallocates.
fn breadth_first(
    root: usize,
    kids: &[u32],
    range: &impl Fn(usize) -> std::ops::Range<usize>,
    capacity: usize,
) -> Result<Vec<u32>, FreezeError> {
    let mut order: Vec<u32> = reserved(capacity)?;
    order.push(root as u32);
    let mut at = 0;
    while at < order.len() {
        let v = order[at] as usize;
        order.extend_from_slice(&kids[range(v)]);
        at += 1;
    }
    Ok(order)
}

/// Where each arena's nodes sit in the dense index.
///
/// Arenas are laid end to end in the order supplied. Within one, node `k` in
/// push order has dense index `base + k`, and its id's `(chunk, slot)` is
/// `(k / CHUNK_NODES, k % CHUNK_NODES)` because the arena only opens a chunk
/// once the previous one is full. That makes the mapping arithmetic, not a
/// table with an entry per node.
struct IdIndex {
    /// One entry per non-empty arena, sorted by thread tag.
    slots: Vec<ArenaSlot>,
    total: usize,
}

struct ArenaSlot {
    thread: u16,
    base: usize,
    len: usize,
}

impl IdIndex {
    fn new(arenas: &[Arena]) -> Result<Self, FreezeError> {
        let mut slots = reserved(arenas.len())?;
        let mut total = 0usize;
        for arena in arenas {
            // The arena's own tag, read off an id it issued: an empty arena
            // issued none, holds nothing, and cannot be named by any parent.
            let Some((first, _)) = arena.iter().next() else {
                continue;
            };
            let len = usize::try_from(arena.len()).expect("arena fits in memory");
            slots.push(ArenaSlot {
                thread: first.thread(),
                base: total,
                len,
            });
            total += len;
        }
        assert!(
            u32::try_from(total).is_ok_and(|t| t < NODE_NONE),
            "too many nodes to index with 32 bits"
        );
        slots.sort_unstable_by_key(|s| s.thread);
        assert!(
            slots.windows(2).all(|w| w[0].thread != w[1].thread),
            "two arenas share thread tag, so their ids are ambiguous"
        );
        Ok(IdIndex { slots, total })
    }

    /// The dense index of the node `id` names, or `None` if no supplied arena
    /// issued it.
    fn resolve(&self, id: ScanId) -> Option<usize> {
        let i = self
            .slots
            .binary_search_by_key(&id.thread(), |s| s.thread)
            .ok()?;
        let slot = &self.slots[i];
        let k = id.chunk() as usize * CHUNK_NODES + id.slot() as usize;
        (k < slot.len).then(|| slot.base + k)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arena::{FLAG_HARDLINK_DUP, FLAG_PERM_DENIED};
    use crate::boundary::SkipReason;
    use crate::node::FLAG_AGGREGATED;
    use proptest::prelude::*;
    use proptest::strategy::ValueTree;
    use proptest::test_runner::{Config, TestRunner};
    use std::collections::{HashMap, HashSet};
    use std::mem::{align_of, offset_of, size_of};
    use std::path::PathBuf;

    // ---------------------------------------------------------------- helpers

    fn push(
        arena: &mut Arena,
        parent: ScanId,
        name: &[u8],
        obj_type: ObjType,
        flags: u16,
        logical: u64,
        allocated: u64,
    ) -> ScanId {
        push_modified(arena, parent, name, obj_type, flags, logical, allocated, 0)
    }

    #[allow(clippy::too_many_arguments)]
    fn push_modified(
        arena: &mut Arena,
        parent: ScanId,
        name: &[u8],
        obj_type: ObjType,
        flags: u16,
        logical: u64,
        allocated: u64,
        modified: i64,
    ) -> ScanId {
        let name = arena.push_name(name).expect("name fits");
        arena
            .push_node(ScanNode {
                name,
                parent,
                obj_type,
                flags,
                logical,
                allocated,
                modified,
                file_id: 0,
            })
            .expect("node fits")
    }

    #[test]
    fn file_ids_survive_freeze_reordering() {
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        let small = file(&mut a, root, b"small", 1, 1);
        let big = file(&mut a, root, b"big", 99, 99);
        for (id, value) in [(root, 101), (small, 202), (big, 303)] {
            a.get_mut(id).unwrap().file_id = value;
        }
        let s = freeze(vec![a], WalkStats::default());
        assert_eq!(s.nodes.len(), 3);
        assert_eq!(name_of(&s, &s.nodes[1]), b"big");
        assert_eq!(name_of(&s, &s.nodes[2]), b"small");
        assert_eq!(s.file_ids, vec![101, 303, 202]);
    }

    fn dir(arena: &mut Arena, parent: ScanId, name: &[u8]) -> ScanId {
        // A directory carries no size of its own, as the kernel reports it.
        push(arena, parent, name, ObjType::Dir, 0, 0, 0)
    }

    fn file(
        arena: &mut Arena,
        parent: ScanId,
        name: &[u8],
        logical: u64,
        allocated: u64,
    ) -> ScanId {
        push(arena, parent, name, ObjType::Reg, 0, logical, allocated)
    }

    fn empty_arena_with_root() -> Arena {
        let mut a = Arena::new(0, u64::MAX);
        dir(&mut a, ScanId::NONE, b"root");
        a
    }

    fn name_of<'a>(s: &'a Snapshot, n: &TessNode) -> &'a [u8] {
        let off = n.name_off as usize;
        &s.names[off..off + usize::from(n.name_len)]
    }

    /// Index of the node called `name`; the tests below keep names unique.
    fn find(s: &Snapshot, name: &[u8]) -> usize {
        let hits: Vec<usize> = (0..s.nodes.len())
            .filter(|&i| name_of(s, &s.nodes[i]) == name)
            .collect();
        assert_eq!(hits.len(), 1, "expected exactly one node named {name:?}");
        hits[0]
    }

    fn children(s: &Snapshot, i: usize) -> &[TessNode] {
        let n = &s.nodes[i];
        let start = n.child_start as usize;
        &s.nodes[start..start + n.child_count as usize]
    }

    fn child_names(s: &Snapshot, i: usize) -> Vec<Vec<u8>> {
        children(s, i)
            .iter()
            .map(|c| name_of(s, c).to_vec())
            .collect()
    }

    // -------------------------------------------------------------- unit tests

    #[test]
    fn tess_node_is_48_bytes_with_modified_last() {
        assert_eq!(size_of::<TessNode>(), 48);
        assert_eq!(align_of::<TessNode>(), 8);
        // Phase 2 reads this across the C ABI, so the offsets are the contract
        // and not just the total.
        assert_eq!(offset_of!(TessNode, name_off), 0);
        assert_eq!(offset_of!(TessNode, name_len), 4);
        assert_eq!(offset_of!(TessNode, flags), 6);
        assert_eq!(offset_of!(TessNode, parent), 8);
        assert_eq!(offset_of!(TessNode, child_start), 12);
        assert_eq!(offset_of!(TessNode, child_count), 16);
        assert_eq!(offset_of!(TessNode, logical), 24);
        assert_eq!(offset_of!(TessNode, allocated), 32);
        assert_eq!(offset_of!(TessNode, modified), 40);
        // Last: nothing follows it, and no padding either.
        assert_eq!(offset_of!(TessNode, modified) + size_of::<i64>(), 48);
        // A signed 64-bit `time_t`, so a pre-1970 time is representable.
        let node = TessNode {
            name_off: 0,
            name_len: 0,
            flags: 0,
            parent: NODE_NONE,
            child_start: 0,
            child_count: 0,
            logical: 0,
            allocated: 0,
            modified: -1,
        };
        let _: i64 = node.modified;
    }

    /// A directory's `modified` is the latest of its own time and every
    /// descendant's that is not after the scan's start, so its tile ages with
    /// its most recently touched content and a future-dated file cannot make
    /// it look newest. A file's is its own, untouched, future or not. Built
    /// across two arenas, with a child pushed before its parent's other
    /// children, so the rollup cannot be relying on arena order; and with a
    /// directory whose own time is the newest, so "max" cannot be "max of
    /// children only".
    #[test]
    fn directory_modified_is_the_max_over_its_subtree() {
        const START: i64 = 10_000;
        let mut a0 = Arena::new(0, u64::MAX);
        let mut a1 = Arena::new(1, u64::MAX);
        let root = push_modified(&mut a0, ScanId::NONE, b"root", ObjType::Dir, 0, 0, 0, 100);
        // deep/ is old itself, but holds the newest past file two levels
        // down, beside a future one.
        let deep = push_modified(&mut a1, root, b"deep", ObjType::Dir, 0, 0, 0, 50);
        let mid = push_modified(&mut a0, deep, b"mid", ObjType::Dir, 0, 0, 0, 60);
        push_modified(&mut a1, mid, b"newest.bin", ObjType::Reg, 0, 1, 1, 9_000);
        push_modified(&mut a0, mid, b"future.bin", ObjType::Reg, 0, 1, 1, 50_000);
        push_modified(&mut a0, deep, b"old.bin", ObjType::Reg, 0, 1, 1, 10);
        // fresh/ was itself touched after anything inside it.
        let fresh = push_modified(&mut a1, root, b"fresh", ObjType::Dir, 0, 0, 0, 5_000);
        push_modified(&mut a0, fresh, b"inner.bin", ObjType::Reg, 0, 1, 1, 20);
        push_modified(&mut a1, fresh, b"link", ObjType::Lnk, 0, 0, 0, 30);
        // Its own time is in the future, so only what is inside counts.
        let stamped = push_modified(&mut a0, root, b"stamped", ObjType::Dir, 0, 0, 0, 20_000);
        push_modified(&mut a1, stamped, b"plain.bin", ObjType::Reg, 0, 1, 1, 40);
        // Nothing dated at or before the start anywhere inside: its own time
        // as read, future or not.
        let all_future = push_modified(&mut a1, root, b"all-future", ObjType::Dir, 0, 0, 0, 30_000);
        push_modified(
            &mut a0,
            all_future,
            b"later.bin",
            ObjType::Reg,
            0,
            1,
            1,
            40_000,
        );
        // Exactly at the start counts: the cutoff is inclusive.
        let edge = push_modified(&mut a0, root, b"edge", ObjType::Dir, 0, 0, 0, 1);
        push_modified(&mut a1, edge, b"at-start.bin", ObjType::Reg, 0, 1, 1, START);
        // Empty: nothing beneath it, so its own time stands.
        push_modified(&mut a0, root, b"empty", ObjType::Dir, 0, 0, 0, 70);
        // Pre-1970: negative times are ordered like any others.
        let ancient = push_modified(&mut a1, root, b"ancient", ObjType::Dir, 0, 0, 0, -500);
        push_modified(&mut a0, ancient, b"older.bin", ObjType::Reg, 0, 1, 1, -900);
        push_modified(&mut a1, ancient, b"newer.bin", ObjType::Reg, 0, 1, 1, -100);

        let stats = WalkStats {
            started_at: START,
            ..WalkStats::default()
        };
        let s = freeze(vec![a0, a1], stats);
        // Preconditions: every node made it, so a missing one cannot pass,
        // and the cutoff reached the snapshot.
        assert_eq!(s.nodes.len(), 19);
        assert_eq!(s.stats.started_at, START);
        let m = |name: &[u8]| s.nodes[find(&s, name)].modified;
        // Leaves keep their own time, a future one included.
        for (name, own) in [
            (&b"newest.bin"[..], 9_000),
            (b"future.bin", 50_000),
            (b"old.bin", 10),
            (b"inner.bin", 20),
            (b"link", 30),
            (b"plain.bin", 40),
            (b"later.bin", 40_000),
            (b"at-start.bin", START),
            (b"older.bin", -900),
            (b"newer.bin", -100),
        ] {
            assert_eq!(m(name), own, "{}", String::from_utf8_lossy(name));
        }
        assert_eq!(
            m(b"mid"),
            9_000,
            "a past file below beats the directory; a future one does not"
        );
        assert_eq!(m(b"deep"), 9_000, "the max reaches up more than one level");
        assert_eq!(m(b"fresh"), 5_000, "the directory's own time counts too");
        assert_eq!(m(b"stamped"), 40, "a future own time does not count");
        assert_eq!(
            m(b"all-future"),
            30_000,
            "nothing dated in time: its own, as read"
        );
        assert_eq!(m(b"edge"), START, "a time equal to the start counts");
        assert_eq!(m(b"empty"), 70);
        assert_eq!(m(b"ancient"), -100);
        assert_eq!(m(b"root"), START, "the newest time not after the start");
    }

    #[test]
    fn empty_root_freezes_to_a_single_childless_node() {
        // Review Focus 5: the prefix sum over a zero-length child list.
        let s = freeze(vec![empty_arena_with_root()], WalkStats::default());
        assert_eq!(s.nodes.len(), 1);
        assert_eq!(s.root, 0);
        assert_eq!(s.nodes[0].child_count, 0);
        assert_eq!(s.nodes[0].child_start, 0);
        assert_eq!(s.nodes[0].parent, NODE_NONE);
        assert_eq!((s.nodes[0].logical, s.nodes[0].allocated), (0, 0));
        assert_eq!(s.nodes[0].flags, FLAG_DIR);
        assert_eq!(name_of(&s, &s.nodes[0]), b"root");
    }

    #[test]
    fn allocation_helpers_report_failure_and_try_freeze_agrees_with_freeze() {
        // usize::MAX elements overflows the layout, so this is a Result, not
        // an abort. The injected-failure sweep is `tests/freeze_oom.rs`.
        assert_eq!(
            reserved::<u64>(usize::MAX).err(),
            Some(FreezeError::OutOfMemory)
        );
        assert_eq!(
            filled::<u8>(usize::MAX, 0).err(),
            Some(FreezeError::OutOfMemory)
        );
        let s = try_freeze(vec![empty_arena_with_root()], WalkStats::default()).unwrap();
        assert_eq!((s.nodes.len(), s.root), (1, 0));
    }

    #[test]
    fn the_names_limit_is_an_error_at_exactly_four_gib() {
        // 4 GiB of real names cannot be built in a test, so the check is
        // exercised directly on the total it is applied to.
        let max = u64::from(u32::MAX);
        assert_eq!(checked_name_bytes(0), Ok(0));
        assert_eq!(checked_name_bytes(max), Ok(u32::MAX as usize));
        assert_eq!(checked_name_bytes(max + 1), Err(FreezeError::NamesTooLarge));
        assert_eq!(
            checked_name_bytes(u64::MAX),
            Err(FreezeError::NamesTooLarge)
        );
    }

    #[test]
    #[should_panic(expected = "allocated size overflows u64")]
    fn a_directory_total_that_overflows_panics_instead_of_saturating() {
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        file(&mut a, root, b"x", 1, u64::MAX);
        file(&mut a, root, b"y", 1, 1);
        freeze(vec![a], WalkStats::default());
    }

    #[test]
    fn freeze_error_has_display_and_is_an_error() {
        let e: &dyn std::error::Error = &FreezeError::OutOfMemory;
        assert!(e.to_string().contains("out of memory"));
        assert!(FreezeError::NamesTooLarge.to_string().contains("4 GiB"));
    }

    #[test]
    fn no_arenas_and_empty_arenas_freeze_to_an_empty_snapshot() {
        for arenas in [vec![], vec![Arena::new(3, u64::MAX)]] {
            let s = freeze(arenas, WalkStats::default());
            assert!(s.nodes.is_empty() && s.names.is_empty());
            assert_eq!(s.root, NODE_NONE);
        }
    }

    #[test]
    fn merges_nodes_from_multiple_worker_arenas() {
        // Two arenas, tagged 0 and 1, each holding part of one tree, with
        // parents and children on both sides of the boundary in both
        // directions:
        //
        //   root(0) -+- a(1) -+- f1(1)=10
        //            |        +- f2(0)=20      child in 0, parent in 1
        //            +- b(0) -+- g(1)=40       child in 1, parent in 0
        //                     +- h(0)=5
        let build = || {
            let mut a0 = Arena::new(0, u64::MAX);
            let mut a1 = Arena::new(1, u64::MAX);
            let root = dir(&mut a0, ScanId::NONE, b"root");
            let a = dir(&mut a1, root, b"a");
            let b = dir(&mut a0, root, b"b");
            file(&mut a1, a, b"f1", 10, 10);
            file(&mut a0, a, b"f2", 20, 20);
            file(&mut a1, b, b"g", 40, 40);
            file(&mut a0, b, b"h", 5, 5);
            (a0, a1)
        };
        for reversed in [false, true] {
            let (a0, a1) = build();
            let s = freeze(
                if reversed { vec![a1, a0] } else { vec![a0, a1] },
                WalkStats::default(),
            );
            assert_eq!(s.nodes.len(), 7, "every node exactly once");
            let names: HashSet<Vec<u8>> = s.nodes.iter().map(|n| name_of(&s, n).to_vec()).collect();
            assert_eq!(names.len(), 7);

            let parent_name = |n: &[u8]| {
                let p = s.nodes[find(&s, n)].parent;
                (p != NODE_NONE).then(|| name_of(&s, &s.nodes[p as usize]).to_vec())
            };
            assert_eq!(parent_name(b"root"), None);
            assert_eq!(parent_name(b"a"), Some(b"root".to_vec()));
            assert_eq!(parent_name(b"b"), Some(b"root".to_vec()));
            assert_eq!(parent_name(b"f1"), Some(b"a".to_vec()));
            assert_eq!(parent_name(b"f2"), Some(b"a".to_vec()));
            assert_eq!(parent_name(b"g"), Some(b"b".to_vec()));
            assert_eq!(parent_name(b"h"), Some(b"b".to_vec()));

            // Sizes crossed the arena boundary too: a = 10 + 20, b = 40 + 5.
            assert_eq!(s.nodes[find(&s, b"a")].allocated, 30);
            assert_eq!(s.nodes[find(&s, b"b")].allocated, 45);
            assert_eq!(s.nodes[s.root as usize].allocated, 75);
        }
    }

    #[test]
    fn arena_order_and_thread_tags_are_independent() {
        // The vec position is not the thread tag: tags 40000 and 3, with the
        // arena holding the children listed first.
        let mut parents = Arena::new(3, u64::MAX);
        let mut kids = Arena::new(40_000, u64::MAX);
        let root = dir(&mut parents, ScanId::NONE, b"root");
        let d = dir(&mut parents, root, b"d");
        file(&mut kids, d, b"x", 7, 8);
        file(&mut kids, root, b"y", 1, 2);
        let s = freeze(vec![kids, parents], WalkStats::default());
        assert_eq!(s.nodes.len(), 4);
        assert_eq!(s.nodes[s.root as usize].allocated, 10);
        assert_eq!(s.nodes[find(&s, b"d")].allocated, 8);
        assert_eq!(child_names(&s, find(&s, b"d")), vec![b"x".to_vec()]);
    }

    #[test]
    fn nodes_beyond_the_first_chunk_map_correctly() {
        // `ScanId` addresses chunk * CHUNK_NODES + slot; a mapping that only
        // looks at the slot would pass every small test. Chunk 1 here holds
        // files whose parents are in chunk 0, and a directory whose own child
        // is in chunk 1 as well.
        const DIRS: usize = 100;
        let extra = 10;
        let total_files = CHUNK_NODES + extra;
        let mut a = Arena::new(2, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        let dirs: Vec<ScanId> = (0..DIRS)
            .map(|i| dir(&mut a, root, format!("d{i}").as_bytes()))
            .collect();
        let mut expected = vec![0u64; DIRS];
        let mut sum = 0u64;
        for j in 0..total_files {
            let size = (j as u64 % 97) + 1;
            file(
                &mut a,
                dirs[j % DIRS],
                format!("f{j}").as_bytes(),
                size,
                size,
            );
            expected[j % DIRS] += size;
            sum += size;
        }
        // Pushed after chunk 0 is full, so both of these live in chunk 1.
        assert!(a.len() > CHUNK_NODES as u64);
        let late = dir(&mut a, root, b"late");
        file(&mut a, late, b"late_child", 1000, 1000);
        sum += 1000;

        let s = freeze(vec![a], WalkStats::default());
        assert_eq!(s.nodes.len(), 1 + DIRS + total_files + 2);
        assert_eq!(s.nodes[s.root as usize].allocated, sum);
        for (i, want) in expected.iter().enumerate() {
            let n = &s.nodes[find(&s, format!("d{i}").as_bytes())];
            assert_eq!(n.allocated, *want, "d{i}");
            assert_eq!(
                n.child_count as usize,
                (0..total_files).filter(|j| j % DIRS == i).count()
            );
        }
        let late_node = &s.nodes[find(&s, b"late")];
        assert_eq!((late_node.allocated, late_node.child_count), (1000, 1));
        // Its child's name sits far into the blob, past what 16 bits address:
        // a `name_off` truncated to u16 would resolve to the wrong bytes.
        let li = find(&s, b"late_child");
        assert!(s.names.len() > usize::from(u16::MAX));
        assert!(s.nodes[li].name_off > u32::from(u16::MAX));
        assert_eq!(
            s.nodes[s.nodes[li].parent as usize].name_off,
            late_node.name_off
        );
        assert_eq!(name_of(&s, &s.nodes[s.nodes[li].parent as usize]), b"late");
    }

    #[test]
    fn siblings_are_contiguous_and_sorted_descending_by_allocated() {
        // Deliberately out of order, with a tie, and with a directory whose
        // rolled-up size (110) beats every file but whose own size is 0: sorting
        // before the rollup would put it last.
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        file(&mut a, root, b"small", 5, 5);
        // The tied pair is pushed against name order, so only the name
        // tie-break (and not push order) can put `mid1` first.
        file(&mut a, root, b"mid2", 100, 100);
        file(&mut a, root, b"zero", 0, 0);
        let d = dir(&mut a, root, b"dir");
        file(&mut a, root, b"mid1", 100, 100);
        file(&mut a, root, b"seven", 7, 7);
        file(&mut a, d, b"in1", 50, 50);
        file(&mut a, d, b"in2", 60, 60);
        let s = freeze(vec![a], WalkStats::default());
        let order = child_names(&s, s.root as usize);
        assert_eq!(
            order,
            vec![
                b"dir".to_vec(),
                b"mid1".to_vec(),
                b"mid2".to_vec(),
                b"seven".to_vec(),
                b"small".to_vec(),
                b"zero".to_vec()
            ],
            "ties break by name, so the order is deterministic"
        );
        // The slice really is contiguous: it starts right after the root's
        // own position and the directory's children follow.
        let r = &s.nodes[s.root as usize];
        assert_eq!((r.child_start, r.child_count), (1, 6));
        assert_eq!(
            child_names(&s, find(&s, b"dir")),
            vec![b"in2".to_vec(), b"in1".to_vec()]
        );
    }

    #[test]
    fn directory_allocated_equals_sum_of_descendants() {
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        let d1 = dir(&mut a, root, b"d1");
        let d2 = dir(&mut a, d1, b"d2");
        let empty = dir(&mut a, root, b"empty");
        let _ = empty;
        file(&mut a, d2, b"deep", 10, 4096);
        file(&mut a, d1, b"mid", 20, 4096);
        file(&mut a, root, b"top", 30, 8192);
        let s = freeze(vec![a], WalkStats::default());
        let get = |n: &[u8]| {
            let x = &s.nodes[find(&s, n)];
            (x.logical, x.allocated)
        };
        assert_eq!(get(b"deep"), (10, 4096));
        assert_eq!(get(b"d2"), (10, 4096));
        assert_eq!(get(b"d1"), (30, 8192));
        assert_eq!(
            get(b"empty"),
            (0, 0),
            "a directory with nothing in it is zero"
        );
        assert_eq!(get(b"root"), (60, 16384));
    }

    #[test]
    fn name_offsets_resolve_to_the_original_bytes() {
        let names: [&[u8]; 6] = [
            b"plain.txt",
            &[0xff, 0xfe, b'a'],    // not UTF-8
            "caf\u{e9}".as_bytes(), // multi-byte UTF-8
            &[b'a', 0, b'b'],       // embedded NUL
            &[b'x'; 255],           // NAME_MAX
            b"",                    // zero-length stays zero-length
        ];
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        for (i, n) in names.iter().enumerate() {
            file(&mut a, root, n, i as u64 + 1, i as u64 + 1);
        }
        let s = freeze(vec![a], WalkStats::default());
        let mut got: Vec<Vec<u8>> = children(&s, s.root as usize)
            .iter()
            .map(|c| name_of(&s, c).to_vec())
            .collect();
        let mut want: Vec<Vec<u8>> = names.iter().map(|n| n.to_vec()).collect();
        got.sort();
        want.sort();
        assert_eq!(got, want);
        // No name bytes are wasted or shared: the blob is exactly the names.
        let total: usize = names.iter().map(|n| n.len()).sum::<usize>() + b"root".len();
        assert_eq!(s.names.len(), total);
    }

    #[test]
    fn flags_are_derived_from_the_type_and_carried_through() {
        let mut a = Arena::new(0, u64::MAX);
        let root = dir(&mut a, ScanId::NONE, b"root");
        push(&mut a, root, b"reg", ObjType::Reg, 0, 1, 1);
        push(&mut a, root, b"lnk", ObjType::Lnk, 0, 1, 1);
        push(&mut a, root, b"other", ObjType::Other, 0, 1, 1);
        push(&mut a, root, b"dup", ObjType::Reg, FLAG_HARDLINK_DUP, 0, 0);
        push(
            &mut a,
            root,
            b"denied",
            ObjType::Dir,
            FLAG_PERM_DENIED,
            0,
            0,
        );
        let s = freeze(vec![a], WalkStats::default());
        let flags = |n: &[u8]| s.nodes[find(&s, n)].flags;
        assert_eq!(flags(b"root"), FLAG_DIR);
        assert_eq!(flags(b"reg"), 0);
        assert_eq!(flags(b"lnk"), FLAG_SYMLINK);
        assert_eq!(flags(b"other"), 0);
        assert_eq!(flags(b"dup"), FLAG_HARDLINK_DUP);
        assert_eq!(flags(b"denied"), FLAG_DIR | FLAG_PERM_DENIED);
        assert!(
            s.nodes.iter().all(|n| n.flags & FLAG_AGGREGATED == 0),
            "aggregated belongs to Phase 2 and is never set here"
        );
        assert_eq!(
            [
                FLAG_DIR,
                FLAG_SYMLINK,
                FLAG_HARDLINK_DUP,
                FLAG_PERM_DENIED,
                FLAG_AGGREGATED
            ],
            [1, 2, 4, 8, 16],
            "the bit positions are binding"
        );
    }

    #[test]
    fn walk_stats_are_carried_through_unchanged() {
        let stats = WalkStats {
            dataless: crate::walk::DatalessStats::default(),
            dataless_paths: vec![PathBuf::from("/cloud")],
            no_materialize_failed: false,
            dirs: 11,
            files: 22,
            errors: 3,
            skipped_by_request: Vec::new(),
            unreadable: vec![PathBuf::from("/locked")],
            skipped_mounts: vec![
                (PathBuf::from("/Volumes/x"), SkipReason::OtherVolume),
                (PathBuf::from("/net"), SkipReason::NonLocalMount),
            ],
            depth_capped: 4,
            lost_entries: 5,
            hardlink_dups: 6,
            stalled_at: Some(PathBuf::from("/stuck")),
            incomplete: Some(crate::walk::Incomplete::MalformedBatch),
            started_at: 1_700_000_000,
            root_device: 42,
        };
        let want = format!("{stats:?}");
        let s = freeze(vec![empty_arena_with_root()], stats);
        assert_eq!(format!("{:?}", s.stats), want);
        assert_eq!(s.stats.skipped_mounts.len(), 2);
        assert_eq!((s.stats.lost_entries, s.stats.hardlink_dups), (5, 6));
    }

    #[test]
    #[should_panic(expected = "parent that no arena holds")]
    fn a_node_whose_parent_is_in_no_arena_is_refused() {
        let mut a0 = Arena::new(0, u64::MAX);
        let mut a1 = Arena::new(1, u64::MAX);
        let root = dir(&mut a0, ScanId::NONE, b"root");
        let orphan_parent = dir(&mut a1, root, b"p");
        file(&mut a0, orphan_parent, b"f", 1, 1);
        // Arena 1, which holds `p`, is not supplied.
        freeze(vec![a0], WalkStats::default());
    }

    #[test]
    #[should_panic(expected = "exactly one root")]
    fn two_roots_are_refused() {
        let mut a0 = Arena::new(0, u64::MAX);
        let mut a1 = Arena::new(1, u64::MAX);
        dir(&mut a0, ScanId::NONE, b"root");
        dir(&mut a1, ScanId::NONE, b"other");
        freeze(vec![a0, a1], WalkStats::default());
    }

    #[test]
    #[should_panic(expected = "share thread tag")]
    fn two_arenas_with_the_same_thread_tag_are_refused() {
        let mut a0 = Arena::new(5, u64::MAX);
        let mut a1 = Arena::new(5, u64::MAX);
        let root = dir(&mut a0, ScanId::NONE, b"root");
        file(&mut a1, root, b"f", 1, 1);
        freeze(vec![a0, a1], WalkStats::default());
    }

    #[test]
    fn a_real_walk_freezes_with_directory_sizes_coming_only_from_the_rollup() {
        use crate::walk::{walk_serial, WalkOptions};
        use tesserae_testutil::Fixture;

        let fx = Fixture::new().unwrap();
        fx.file("a/big.bin", 40_000)
            .unwrap()
            .file("a/c/small.bin", 5_000)
            .unwrap()
            .file("top.bin", 1)
            .unwrap()
            .dir("empty")
            .unwrap()
            .symlink("top.bin", "link")
            .unwrap();
        let opts = WalkOptions {
            root: fx.path().to_path_buf(),
            ..WalkOptions::default()
        };
        let (arena, stats) = walk_serial(&opts).unwrap();

        // What the kernel actually reported, before any freezing.
        let (mut files_l, mut files_a) = (0u64, 0u64);
        for (_, n) in arena.iter() {
            if n.obj_type == ObjType::Dir {
                assert_eq!(
                    (n.logical, n.allocated),
                    (0, 0),
                    "a directory reports no size"
                );
            } else {
                files_l += n.logical;
                files_a += n.allocated;
            }
        }
        assert!(files_a >= 45_001, "the files do occupy disk");
        let dirs = stats.dirs;

        let s = freeze(vec![arena], stats);
        let root = &s.nodes[s.root as usize];
        assert_eq!((root.logical, root.allocated), (files_l, files_a));
        assert_eq!(s.stats.dirs, dirs, "stats pass through");
        let get = |n: &[u8]| &s.nodes[find(&s, n)];
        assert_eq!(
            get(b"a").allocated,
            get(b"big.bin").allocated + get(b"c").allocated
        );
        assert_eq!(get(b"c").allocated, get(b"small.bin").allocated);
        assert_eq!(get(b"empty").allocated, 0);
        assert_ne!(get(b"link").flags & FLAG_SYMLINK, 0);
        // `a` holds the 40 KB file, so it sorts ahead of everything else.
        assert_eq!(child_names(&s, s.root as usize)[0], b"a".to_vec());
    }

    // --------------------------------------------------------- property tests

    /// One node of a randomly generated tree, before it is split across
    /// arenas. Names are unique across the whole tree so that a frozen node
    /// can be matched back to its source by name alone.
    #[derive(Debug, Clone)]
    struct MNode {
        parent: Option<usize>,
        obj_type: ObjType,
        name: Vec<u8>,
        flags: u16,
        logical: u64,
        allocated: u64,
        modified: i64,
        arena: usize,
    }

    #[derive(Debug, Clone)]
    struct Tree {
        nodes: Vec<MNode>,
        /// Thread tag of each arena, by arena number.
        tags: Vec<u16>,
        /// The order the arenas are handed to `freeze`: a permutation of
        /// `0..tags.len()`, so a child's arena can precede its parent's.
        order: Vec<usize>,
        /// The scan's start, handed to `freeze` as `WalkStats::started_at`.
        cutoff: i64,
    }

    impl Tree {
        fn build(&self) -> Vec<Arena> {
            self.build_in(&self.order)
        }

        /// The arenas, handed over in `order`.
        fn build_in(&self, order: &[usize]) -> Vec<Arena> {
            let mut arenas: Vec<Option<Arena>> = self
                .tags
                .iter()
                .map(|&t| Some(Arena::new(t, u64::MAX)))
                .collect();
            let mut ids: Vec<ScanId> = Vec::new();
            for n in &self.nodes {
                let parent = n.parent.map_or(ScanId::NONE, |p| ids[p]);
                let arena = arenas[n.arena].as_mut().expect("arena present");
                ids.push(push_modified(
                    arena,
                    parent,
                    &n.name,
                    n.obj_type,
                    n.flags,
                    n.logical,
                    n.allocated,
                    n.modified,
                ));
            }
            order
                .iter()
                .map(|&i| arenas[i].take().expect("order is a permutation"))
                .collect()
        }

        fn is_dir(&self, i: usize) -> bool {
            self.nodes[i].obj_type == ObjType::Dir
        }

        /// Independent of the freeze: add each node's own size to every
        /// ancestor by walking parent links one node at a time.
        fn expected_totals(&self) -> Vec<(u64, u64)> {
            let mut tot: Vec<(u64, u64)> = self
                .nodes
                .iter()
                .map(|n| (n.logical, n.allocated))
                .collect();
            for n in &self.nodes {
                let mut p = n.parent;
                while let Some(q) = p {
                    tot[q].0 += n.logical;
                    tot[q].1 += n.allocated;
                    p = self.nodes[q].parent;
                }
            }
            tot
        }

        /// Independent of the freeze: offer each node's own time, if it is not
        /// after the cutoff, to itself and every ancestor by walking parent
        /// links one node at a time. A directory takes the best offer, or its
        /// own time if it had none; anything else keeps its own time.
        fn expected_modified(&self) -> Vec<i64> {
            let mut best: Vec<Option<i64>> = vec![None; self.nodes.len()];
            for n in self.nodes.iter().filter(|n| n.modified <= self.cutoff) {
                let mut at = self.nodes.iter().position(|m| std::ptr::eq(m, n));
                while let Some(q) = at {
                    best[q] = Some(best[q].map_or(n.modified, |b| b.max(n.modified)));
                    at = self.nodes[q].parent;
                }
            }
            self.nodes
                .iter()
                .zip(best)
                .map(|(n, b)| match (n.obj_type, b) {
                    (ObjType::Dir, Some(b)) => b,
                    _ => n.modified,
                })
                .collect()
        }

        fn by_name(&self) -> HashMap<Vec<u8>, usize> {
            self.nodes
                .iter()
                .enumerate()
                .map(|(i, n)| (n.name.clone(), i))
                .collect()
        }

        fn child_count(&self, i: usize) -> usize {
            self.nodes.iter().filter(|n| n.parent == Some(i)).count()
        }
    }

    type Entry = (usize, bool, u8, u8, u64, u64, usize, Vec<u8>, i64);

    fn arb_modified() -> impl Strategy<Value = i64> {
        // Few distinct values around zero force ties and negatives; the full
        // range covers the extremes of a signed `time_t`.
        prop_oneof![-3i64..3, any::<i64>()]
    }

    fn arb_size() -> impl Strategy<Value = u64> {
        // Few distinct small values force ties; the rest give spread.
        prop_oneof![0u64..4, 0u64..1_000, any::<u32>().prop_map(u64::from)]
    }

    fn arb_entry() -> impl Strategy<Value = Entry> {
        (
            any::<usize>(),
            any::<bool>(),
            0u8..3,
            0u8..4,
            arb_size(),
            arb_size(),
            any::<usize>(),
            prop::collection::vec(any::<u8>(), 0..6),
            arb_modified(),
        )
    }

    fn arb_tree() -> impl Strategy<Value = Tree> {
        (1usize..=4).prop_flat_map(|k| {
            (
                prop::collection::btree_set(any::<u16>(), k..=k),
                Just((0..k).collect::<Vec<usize>>()).prop_shuffle(),
                prop::collection::vec(arb_entry(), 0..80),
                any::<usize>(),
                arb_modified(),
                // Mostly a cutoff among the times, so some are later than it;
                // sometimes none at all, as for stats not from a walk.
                prop_oneof![3 => arb_modified(), 1 => Just(i64::MAX)],
            )
                .prop_map(
                    move |(tags, order, entries, root_arena, root_modified, cutoff)| {
                        let mut nodes = vec![MNode {
                            parent: None,
                            obj_type: ObjType::Dir,
                            name: b"root".to_vec(),
                            flags: 0,
                            logical: 0,
                            allocated: 0,
                            modified: root_modified,
                            arena: root_arena % k,
                        }];
                        let mut dirs = vec![0usize];
                        for (
                            pick,
                            is_dir,
                            kind,
                            fl,
                            logical,
                            allocated,
                            arena,
                            mut name,
                            modified,
                        ) in entries
                        {
                            let idx = nodes.len();
                            name.extend_from_slice(&(idx as u32).to_le_bytes());
                            let flags = [
                                0,
                                FLAG_HARDLINK_DUP,
                                FLAG_PERM_DENIED,
                                FLAG_HARDLINK_DUP | FLAG_PERM_DENIED,
                            ][usize::from(fl)];
                            let (obj_type, logical, allocated) = if is_dir {
                                // As the kernel reports a directory: no size.
                                (ObjType::Dir, 0, 0)
                            } else {
                                let t =
                                    [ObjType::Reg, ObjType::Lnk, ObjType::Other][usize::from(kind)];
                                (t, logical, allocated)
                            };
                            nodes.push(MNode {
                                parent: Some(dirs[pick % dirs.len()]),
                                obj_type,
                                name,
                                flags,
                                logical,
                                allocated,
                                modified,
                                arena: arena % k,
                            });
                            if is_dir {
                                dirs.push(idx);
                            }
                        }
                        Tree {
                            nodes,
                            tags: tags.into_iter().collect(),
                            order,
                            cutoff,
                        }
                    },
                )
        })
    }

    fn frozen(t: &Tree) -> Snapshot {
        let stats = WalkStats {
            started_at: t.cutoff,
            ..WalkStats::default()
        };
        freeze(t.build(), stats)
    }

    proptest! {
        #![proptest_config(Config::with_cases(512))]

        #[test]
        fn every_child_range_is_in_bounds(t in arb_tree()) {
            let s = frozen(&t);
            let n = s.nodes.len();
            prop_assert_eq!(n, t.nodes.len());
            for (i, node) in s.nodes.iter().enumerate() {
                let start = node.child_start as usize;
                let end = start + node.child_count as usize;
                prop_assert!(end <= n, "node {i}: children {start}..{end} exceed {n}");
                if node.child_count > 0 {
                    // The root is nobody's child, so a range never includes it.
                    prop_assert!(start >= 1, "node {i}: range starts at the root");
                } else {
                    prop_assert_eq!(start, 0, "node {}: a leaf has child_start 0", i);
                }
                prop_assert!(
                    node.parent == NODE_NONE || (node.parent as usize) < n,
                    "node {i}: parent {} out of bounds", node.parent
                );
            }
            prop_assert_eq!(s.root, 0);
        }

        #[test]
        fn parent_and_child_links_agree(t in arb_tree()) {
            let s = frozen(&t);
            // Down: every child's parent is the node whose range holds it.
            for (i, node) in s.nodes.iter().enumerate() {
                let start = node.child_start as usize;
                for c in start..start + node.child_count as usize {
                    prop_assert_eq!(
                        s.nodes[c].parent as usize, i,
                        "node {} is in {}'s range but names parent {}", c, i, s.nodes[c].parent
                    );
                }
            }
            // Up: every non-root node lies inside its parent's range.
            for (j, node) in s.nodes.iter().enumerate() {
                if j == s.root as usize {
                    prop_assert_eq!(node.parent, NODE_NONE);
                    continue;
                }
                prop_assert!(node.parent != NODE_NONE, "node {j} has no parent but is not the root");
                let p = &s.nodes[node.parent as usize];
                let lo = p.child_start as usize;
                prop_assert!(
                    (lo..lo + p.child_count as usize).contains(&j),
                    "node {j} is outside its parent {}'s range", node.parent
                );
            }
        }

        #[test]
        fn no_index_appears_twice_as_a_child(t in arb_tree()) {
            let s = frozen(&t);
            let mut seen = vec![false; s.nodes.len()];
            for node in &s.nodes {
                let start = node.child_start as usize;
                for c in start..start + node.child_count as usize {
                    let Some(slot) = seen.get_mut(c) else {
                        return Err(TestCaseError::fail(format!("child index {c} out of bounds")));
                    };
                    prop_assert!(!*slot, "index {} is a child more than once", c);
                    *slot = true;
                }
            }
            // And every node but the root is a child exactly once, so the
            // ranges tile 1..n with no gaps and no overlaps.
            for (i, was_child) in seen.iter().enumerate() {
                prop_assert_eq!(*was_child, i != s.root as usize, "index {}", i);
            }
        }

        #[test]
        fn modified_rollup_matches_independent_max(t in arb_tree()) {
            let s = frozen(&t);
            let by_name = t.by_name();
            let want = t.expected_modified();
            prop_assert_eq!(s.nodes.len(), t.nodes.len());
            for node in &s.nodes {
                let m = by_name[name_of(&s, node)];
                prop_assert_eq!(node.modified, want[m], "node {:?}", t.nodes[m].name);
            }
        }

        #[test]
        fn rollup_matches_independent_sum(t in arb_tree()) {
            let s = frozen(&t);
            let by_name = t.by_name();
            let want = t.expected_totals();
            for node in &s.nodes {
                let m = by_name[name_of(&s, node)];
                prop_assert_eq!(
                    (node.logical, node.allocated), want[m],
                    "node {:?}", t.nodes[m].name
                );
            }
            // The whole is the sum of the parts that actually carry bytes.
            let (sum_l, sum_a) = t.nodes.iter().fold((0u64, 0u64), |(l, a), n| (l + n.logical, a + n.allocated));
            let root = &s.nodes[s.root as usize];
            prop_assert_eq!((root.logical, root.allocated), (sum_l, sum_a));
        }

        #[test]
        fn siblings_sorted_descending(t in arb_tree()) {
            let s = frozen(&t);
            for (i, node) in s.nodes.iter().enumerate() {
                let start = node.child_start as usize;
                let kids = &s.nodes[start..start + node.child_count as usize];
                for w in kids.windows(2) {
                    prop_assert!(
                        w[0].allocated >= w[1].allocated,
                        "children of {i} out of order: {} before {}", w[0].allocated, w[1].allocated
                    );
                }
            }
        }

        /// Which worker finished first is scheduling, and the parallel
        /// walker hands the arenas over in that order. Equal-size siblings
        /// must not reshuffle between rescans of an unchanged volume, so the
        /// frozen bytes cannot depend on arena order. (The tie-break by name
        /// is what makes this true; without it ties fall to the dense index,
        /// which is arena order.)
        #[test]
        fn frozen_bytes_do_not_depend_on_arena_order(
            t in arb_tree(),
            keys in prop::collection::vec(any::<u32>(), 4),
        ) {
            let k = t.tags.len();
            let mut other: Vec<usize> = (0..k).collect();
            other.sort_by_key(|&i| keys[i]);
            let a = freeze(t.build(), WalkStats::default());
            let b = freeze(t.build_in(&other), WalkStats::default());
            let c = freeze(t.build_in(&t.order.iter().rev().copied().collect::<Vec<_>>()), WalkStats::default());
            prop_assert_eq!(&a.nodes, &b.nodes);
            prop_assert_eq!(&a.names, &b.names);
            prop_assert_eq!(&a.nodes, &c.nodes);
            prop_assert_eq!(&a.names, &c.names);
        }

        /// The five properties above check the snapshot against itself; this
        /// one checks it against the tree it was made from, which is the only
        /// thing that catches a tree that is consistent but wrong (every node
        /// attached to the wrong parent, say).
        #[test]
        fn frozen_tree_is_isomorphic_to_the_input(t in arb_tree()) {
            let s = frozen(&t);
            let by_name = t.by_name();
            prop_assert_eq!(s.nodes.len(), t.nodes.len());
            let mut hit = HashSet::new();
            for (i, node) in s.nodes.iter().enumerate() {
                let m = by_name[name_of(&s, node)];
                prop_assert!(hit.insert(m), "{:?} appears twice", t.nodes[m].name);
                let src = &t.nodes[m];
                let parent_name = (node.parent != NODE_NONE)
                    .then(|| name_of(&s, &s.nodes[node.parent as usize]).to_vec());
                let want_parent = src.parent.map(|p| t.nodes[p].name.clone());
                prop_assert_eq!(parent_name, want_parent, "parent of {:?}", src.name);
                prop_assert_eq!(node.child_count as usize, t.child_count(m));
                let kids: HashSet<Vec<u8>> = child_names(&s, i).into_iter().collect();
                let want_kids: HashSet<Vec<u8>> = t.nodes.iter()
                    .filter(|n| n.parent == Some(m))
                    .map(|n| n.name.clone())
                    .collect();
                prop_assert_eq!(kids, want_kids, "children of {:?}", src.name);
                let mut want_flags = src.flags;
                if t.is_dir(m) { want_flags |= FLAG_DIR; }
                if src.obj_type == ObjType::Lnk { want_flags |= FLAG_SYMLINK; }
                prop_assert_eq!(node.flags, want_flags);
            }
            prop_assert_eq!(hit.len(), t.nodes.len());
        }
    }

    /// The properties are only as good as the trees they see. This pins what
    /// the generator is for, so a change that quietly makes every tree
    /// already-sorted, single-arena or topologically ordered fails here
    /// instead of leaving the properties vacuous.
    #[test]
    fn the_generator_exercises_what_the_properties_claim() {
        let mut runner = TestRunner::deterministic();
        let strat = arb_tree();
        let (mut unsorted, mut multi, mut child_before_parent, mut deep, mut ties) =
            (0, 0, 0, 0, 0);
        let mut cross_arena_ties = 0;
        let samples = 400;
        for _ in 0..samples {
            let t = strat.new_tree(&mut runner).expect("sample").current();
            // Sibling groups in the order they were handed in.
            let mut groups: HashMap<usize, Vec<u64>> = HashMap::new();
            for n in &t.nodes {
                if let Some(p) = n.parent {
                    groups.entry(p).or_default().push(n.allocated);
                }
            }
            if groups.values().any(|g| g.windows(2).any(|w| w[0] < w[1])) {
                unsorted += 1;
            }
            if groups.values().any(|g| {
                let mut s = g.clone();
                s.sort_unstable();
                s.windows(2).any(|w| w[0] == w[1])
            }) {
                ties += 1;
            }
            // The seventh property's precondition: two siblings whose rolled-up
            // sizes are equal (what the sort compares) and which were pushed
            // into different arenas. Ties within one arena keep push order
            // whatever order the arenas arrive in, so only this conjunction
            // makes the tie-break matter.
            let rolled = t.expected_totals();
            let mut kids: HashMap<usize, Vec<usize>> = HashMap::new();
            for (i, n) in t.nodes.iter().enumerate() {
                if let Some(p) = n.parent {
                    kids.entry(p).or_default().push(i);
                }
            }
            if kids.values().any(|g| {
                g.iter().any(|&i| {
                    g.iter().any(|&j| {
                        i < j && rolled[i].1 == rolled[j].1 && t.nodes[i].arena != t.nodes[j].arena
                    })
                })
            }) {
                cross_arena_ties += 1;
            }
            let used: HashSet<usize> = t.nodes.iter().map(|n| n.arena).collect();
            if used.len() > 1 {
                multi += 1;
            }
            let pos: HashMap<usize, usize> =
                t.order.iter().enumerate().map(|(p, &a)| (a, p)).collect();
            if t.nodes.iter().any(|n| {
                n.parent
                    .is_some_and(|p| pos[&n.arena] < pos[&t.nodes[p].arena])
            }) {
                child_before_parent += 1;
            }
            let depth = |mut i: usize| {
                let mut d = 0;
                while let Some(p) = t.nodes[i].parent {
                    d += 1;
                    i = p;
                }
                d
            };
            if (0..t.nodes.len()).any(|i| depth(i) >= 3) {
                deep += 1;
            }
        }
        // Floors sit well under the rates this deterministic run measures, so
        // a partial regression is noticed and ordinary change is not:
        // unsorted 92%, ties 93%, multi-arena 75%, child-arena-first 72%,
        // deep 90%, cross-arena ties 57%.
        let floor = samples / 4;
        assert!(unsorted > floor, "unsorted sibling groups: {unsorted}");
        assert!(ties > samples / 10, "sibling ties: {ties}");
        assert!(multi > samples * 3 / 5, "multi-arena trees: {multi}");
        assert!(
            cross_arena_ties > samples * 2 / 5,
            "cross-arena sibling ties: {cross_arena_ties}"
        );
        assert!(
            child_before_parent > samples / 10,
            "child arena first: {child_before_parent}"
        );
        assert!(deep > floor, "trees at least 3 deep: {deep}");
    }
}
