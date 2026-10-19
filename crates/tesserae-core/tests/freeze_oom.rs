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

//! `try_freeze` must report every allocation failure as `FreezeError`, never
//! abort.
//!
//! Wrapping the global allocator lets this fail the allocation a test chooses.
//! The run first counts the allocations a freeze makes, then repeats it once
//! per allocation with exactly that one refused. A freeze that reached for
//! memory through an infallible path (`Vec::with_capacity`, `vec![..]`,
//! `clone`, a growing `push`, a stable sort's scratch buffer) hits
//! `handle_alloc_error` and aborts this process, which fails the test; a
//! bounded or missing check would instead return `Ok` where `Err` is due.
//!
//! One test only, and the counter is per thread, so the harness's own threads
//! do not disturb the count.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use tesserae_core::arena::{Arena, ScanId, ScanNode};
use tesserae_core::freeze::{try_freeze, FreezeError};
use tesserae_core::node::NODE_NONE;
use tesserae_core::parse::ObjType;
use tesserae_core::walk::WalkStats;

thread_local! {
    /// Allocations made on this thread since the counter was reset.
    static SEEN: Cell<usize> = const { Cell::new(0) };
    /// The zero-based allocation to refuse, or `usize::MAX` for none.
    static FAIL_AT: Cell<usize> = const { Cell::new(usize::MAX) };
}

struct FailingAlloc;

/// Count this allocation; true if it is the one to refuse.
fn refuse() -> bool {
    // `try_with`: the thread-locals may already be gone during thread exit.
    let n = SEEN.try_with(|s| {
        let n = s.get();
        s.set(n + 1);
        n
    });
    matches!((n, FAIL_AT.try_with(Cell::get)), (Ok(n), Ok(f)) if n == f)
}

// SAFETY: every method either returns null, which `GlobalAlloc` allows as the
// failure signal and which the caller must handle, or forwards its arguments
// unchanged to `System`, whose contract is therefore the one the caller
// already upheld. The bookkeeping uses const-initialised thread-locals with no
// destructor, so it never allocates or re-enters the allocator.
unsafe impl GlobalAlloc for FailingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if refuse() {
            return std::ptr::null_mut();
        }
        System.alloc(layout)
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        if refuse() {
            return std::ptr::null_mut();
        }
        System.alloc_zeroed(layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if refuse() {
            return std::ptr::null_mut();
        }
        System.realloc(ptr, layout, new_size)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}

#[global_allocator]
static ALLOC: FailingAlloc = FailingAlloc;

/// Two arenas, a few levels, several names: enough that every pass has work.
fn arenas() -> Vec<Arena> {
    let mut a0 = Arena::new(0, u64::MAX);
    let mut a1 = Arena::new(9, u64::MAX);
    let push = |arena: &mut Arena, parent: ScanId, name: &[u8], t: ObjType, size: u64| {
        let name = arena.push_name(name).unwrap();
        arena
            .push_node(ScanNode {
                name,
                parent,
                obj_type: t,
                flags: 0,
                logical: size,
                allocated: size,
                modified: 0,
            })
            .unwrap()
    };
    let root = push(&mut a0, ScanId::NONE, b"root", ObjType::Dir, 0);
    let d = push(&mut a1, root, b"d", ObjType::Dir, 0);
    for i in 0..20u64 {
        push(&mut a0, d, format!("f{i}").as_bytes(), ObjType::Reg, i);
        push(
            &mut a1,
            root,
            format!("g{i}").as_bytes(),
            ObjType::Reg,
            100 - i,
        );
    }
    vec![a1, a0]
}

#[test]
fn every_allocation_failure_comes_back_as_an_error() {
    // Count the allocations of a successful run.
    let input = arenas();
    SEEN.with(|s| s.set(0));
    let ok = try_freeze(input, WalkStats::default());
    let total = SEEN.with(Cell::get);
    let snapshot = ok.expect("an unconstrained freeze succeeds");
    assert_eq!(snapshot.nodes.len(), 42);
    assert_eq!(snapshot.nodes[0].parent, NODE_NONE);
    // Fewer than a dozen means the count is not seeing the freeze's arrays.
    assert!(total >= 12, "only {total} allocations counted");

    for k in 0..total {
        let input = arenas();
        SEEN.with(|s| s.set(0));
        FAIL_AT.with(|f| f.set(k));
        let result = try_freeze(input, WalkStats::default());
        FAIL_AT.with(|f| f.set(usize::MAX));
        assert!(
            matches!(result, Err(FreezeError::OutOfMemory)),
            "refusing allocation {k} of {total} did not yield OutOfMemory"
        );
    }
}
