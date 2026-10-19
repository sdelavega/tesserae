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

//! The frozen snapshot: the immutable, index-based tree every consumer reads.
//!
//! The walker's arenas are built for fast concurrent insertion, so their nodes
//! sit in whatever order they were discovered. A [`Snapshot`] is the opposite:
//! one flat array in which a directory's children are a contiguous slice
//! already sorted by size, so the treemap layout and the file table read a
//! cache-friendly range with no work. [`crate::freeze::freeze`] builds it.
//!
//! [`TessNode`] is `#[repr(C)]` because Phase 2 reads this array across the C
//! ABI. Its layout is therefore a contract: changing a field's type, order or
//! the struct's size is an ABI break, not a refactor.

use crate::walk::WalkStats;

/// "No node": the root's `parent`. Also a value no real index can take, since
/// [`crate::freeze::freeze`] refuses to build a snapshot that large.
pub const NODE_NONE: u32 = u32::MAX;

/// [`TessNode::flags`] bit 0: the node is a directory. Derived from the
/// entry's object type at freeze time; the walker never sets it.
pub const FLAG_DIR: u16 = 1 << 0;

/// [`TessNode::flags`] bit 1: the node is a symbolic link (never followed).
/// Derived from the object type at freeze time.
pub const FLAG_SYMLINK: u16 = 1 << 1;

// Bit 2 is `arena::FLAG_HARDLINK_DUP` and bit 3 is `arena::FLAG_PERM_DENIED`;
// both are set by the walker and carried through freeze unchanged.

/// [`TessNode::flags`] bit 4: the node stands for several siblings merged by
/// the treemap's tail aggregation. Phase 2 sets it on its own layout output;
/// freeze never does. It is defined here only so that no other flag can claim
/// the bit.
pub const FLAG_AGGREGATED: u16 = 1 << 4;

// The five bits are fixed by the spec and read by Phase 2; two flags sharing a
// bit would silently misreport a node, so the set is checked at compile time.
const _: () = {
    use crate::arena::{FLAG_HARDLINK_DUP, FLAG_PERM_DENIED};
    let all = [
        FLAG_DIR,
        FLAG_SYMLINK,
        FLAG_HARDLINK_DUP,
        FLAG_PERM_DENIED,
        FLAG_AGGREGATED,
    ];
    let mut seen = 0u16;
    let mut i = 0;
    while i < all.len() {
        assert!(all[i].count_ones() == 1 && seen & all[i] == 0);
        seen |= all[i];
        i += 1;
    }
    assert!(seen == 0b1_1111);
};

/// One entry of the frozen tree. 40 bytes, C layout.
///
/// A directory's children are the entries `child_start` up to
/// `child_start + child_count` of the node array, sorted descending by
/// `allocated`. A node with no children has
/// `child_count == 0` and `child_start == 0`. That `0` is not an index and
/// must not be read as one: `child_count == 0` is the guard. It is `0` rather
/// than the next free position (which for the last leaves would equal the
/// array length) so a consumer that checks `child_start < count` never
/// rejects a leaf.
///
/// There are 4 bytes of padding after `child_count`, because the next field is
/// 8-byte aligned. Consumers must not read them.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TessNode {
    /// Byte offset of this node's name in the snapshot's name arena.
    pub name_off: u32,
    pub name_len: u16,
    /// The `TESS_FLAG_*` bits: directory, symlink, hardlink duplicate,
    /// permission denied, aggregated.
    pub flags: u16,
    /// Index of the parent in the node array, or `u32::MAX` for the root.
    pub parent: u32,
    pub child_start: u32,
    pub child_count: u32,
    /// Bytes of content. For a directory, the sum over everything beneath it.
    pub logical: u64,
    /// Bytes of disk the node occupies. For a directory, the sum over
    /// everything beneath it: a directory carries no size of its own, so this
    /// figure exists only because the freeze rolled it up.
    pub allocated: u64,
}

/// The result of a scan: an immutable tree plus what the walk saw.
#[derive(Debug)]
pub struct Snapshot {
    /// Every node, root first. Siblings are contiguous.
    pub nodes: Vec<TessNode>,
    /// All names, concatenated with no separators. Addressed by
    /// [`TessNode::name_off`] and [`TessNode::name_len`]. Arbitrary bytes:
    /// file names on macOS are not guaranteed to be UTF-8.
    pub names: Vec<u8>,
    /// Index of the root in `nodes`. `0` for any scan that found a root;
    /// [`NODE_NONE`] only for a snapshot of no arenas at all.
    pub root: u32,
    /// Carried through from the walk unchanged.
    pub stats: WalkStats,
}
