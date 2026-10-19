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

//! `tess_snapshot_release` gives the snapshot's memory back.
//!
//! Wrapping the global allocator counts the bytes live at any moment. A scan's
//! snapshot is made, measured, released, and the count must fall back to where
//! it started. A release that leaked would leave the snapshot's nodes and names
//! allocated, which nothing else in the suite would notice.
//!
//! One test only, so no other test allocates beside it.

use std::alloc::{GlobalAlloc, Layout, System};
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use tesserae_core::node::TessNode;
use tesserae_ffi::{
    tess_scan_begin, tess_scan_finish, tess_scan_status, tess_snapshot_release, tess_snapshot_view,
    TessSnapshot, TessView, TESS_STATUS_RUNNING,
};
use tesserae_testutil::Fixture;

/// Bytes currently allocated through the global allocator.
static LIVE: AtomicUsize = AtomicUsize::new(0);

struct Counting;

// SAFETY: every method forwards to `System`, which upholds the `GlobalAlloc`
// contract, and only adjusts a counter around it.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if !p.is_null() {
            LIVE.fetch_add(layout.size(), Ordering::Relaxed);
        }
        p
    }

    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        unsafe { System.dealloc(p, layout) };
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
    }

    unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, layout, new_size) };
        if !q.is_null() {
            LIVE.fetch_add(new_size, Ordering::Relaxed);
            LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        }
        q
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

const FILES: usize = 12_000;

/// Allocator residue the comparison tolerates. Something outside the snapshot
/// keeps a bounded amount alive after a scan: measured over 15 repeated scans
/// it rose to a plateau of ~44 KB and stayed there, so it is a cache, not a
/// leak. The tolerance is three times that, and still a quarter of the ~500 KB
/// of nodes a snapshot that was never freed would leave behind.
const SLACK: usize = 128 * 1024;

/// Scan `root` to completion and return its snapshot.
fn scan(root: &std::ffi::CStr) -> *mut TessSnapshot {
    // SAFETY: `root` is a live NUL-terminated string; null options are allowed.
    let scan = unsafe { tess_scan_begin(root.as_ptr(), ptr::null()) };
    assert!(!scan.is_null());
    let started = Instant::now();
    // SAFETY: `scan` is live until `tess_scan_finish`.
    while unsafe { tess_scan_status(scan) } == TESS_STATUS_RUNNING {
        assert!(started.elapsed() < Duration::from_secs(20), "scan hung");
        std::thread::sleep(Duration::from_millis(5));
    }
    // SAFETY: `scan` is live and not used again.
    let snapshot = unsafe { tess_scan_finish(scan) };
    assert!(!snapshot.is_null());
    snapshot
}

#[test]
fn releasing_a_snapshot_returns_its_memory() {
    let fx = Fixture::new().unwrap();
    for i in 0..FILES {
        fx.file(&format!("d{}/f{i}.bin", i % 10), 1).unwrap();
    }
    let root = std::ffi::CString::new(fx.path().to_str().unwrap()).unwrap();

    // One whole cycle first, so that the residue above is already in place
    // when the baseline is taken and only the snapshot's own bytes move.
    // SAFETY: the snapshot is live and not used again.
    unsafe { tess_snapshot_release(scan(&root)) };
    let baseline = LIVE.load(Ordering::Relaxed);

    let snapshot = scan(&root);
    let mut view = TessView {
        nodes: ptr::null(),
        count: 0,
        names: ptr::null(),
        names_len: 0,
        root: 0,
    };
    // SAFETY: `snapshot` is live and `view` is writable.
    unsafe { tess_snapshot_view(snapshot, &mut view) };
    // The files, 10 directories and the root.
    assert_eq!(view.count as usize, FILES + 10 + 1);
    let held = LIVE.load(Ordering::Relaxed).saturating_sub(baseline);
    let floor = view.count as usize * std::mem::size_of::<TessNode>();
    assert!(
        held >= floor,
        "the snapshot should hold at least its {floor} bytes of nodes, but only {held} are live"
    );

    // SAFETY: `snapshot` is live and not used again.
    unsafe { tess_snapshot_release(snapshot) };
    let after = LIVE.load(Ordering::Relaxed).saturating_sub(baseline);
    assert!(
        after <= SLACK,
        "{after} bytes are still live after release (the snapshot held {held})"
    );
}
