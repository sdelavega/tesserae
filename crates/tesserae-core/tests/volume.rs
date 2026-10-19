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

//! The scanner against a real second volume: a disk image attached with
//! `hdiutil`, which is the one thing an unprivileged test can mount.
//!
//! Three things only a real volume can show:
//!
//! * the totals of a tree whose contents are known to the byte, on a volume
//!   that holds nothing else;
//! * that APFS clones make the tree's allocated total exceed what the volume
//!   actually uses, which is the spec's section 7 claim that clones cannot be
//!   solved by a scanner, observed rather than assumed;
//! * what the walk does when the volume disappears underneath it.
//!
//! Every image is attached through [`DiskImage`], which detaches in `Drop`
//! (a failed assertion included).

use std::fs::{self, File};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tesserae_core::freeze::try_freeze;
use tesserae_core::node::{Snapshot, FLAG_DIR};
use tesserae_core::progress::{walk_with_progress, Progress};
use tesserae_core::walk::{os_errno, Incomplete, WalkOptions};
use tesserae_testutil::{
    allocation_lock, copy_by_read_write, write_dense_file, DiskImage, Filesystem, Fixture,
};

/// APFS allocates in units of this many bytes. Asserted against the
/// filesystem in `scans_a_known_disk_image_to_exact_totals`, not assumed.
const BLOCK: u64 = 4096;

/// Walk `root` with the default options and freeze the result. Panics on any
/// failure: a test that wants to look at a failure walks for itself.
fn scan(root: &Path) -> Snapshot {
    let opts = WalkOptions {
        root: root.to_path_buf(),
        ..WalkOptions::default()
    };
    let (arenas, stats) = walk_with_progress(&opts, &Progress::default()).unwrap();
    assert_eq!(stats.incomplete, None, "the scan must complete");
    try_freeze(arenas, stats).unwrap()
}

/// `(dirs, files)` counted from the frozen nodes themselves, not from the
/// walk's counters.
fn counted(snapshot: &Snapshot) -> (u64, u64) {
    let dirs = snapshot
        .nodes
        .iter()
        .filter(|n| n.flags & FLAG_DIR != 0)
        .count() as u64;
    (dirs, snapshot.nodes.len() as u64 - dirs)
}

/// `fx/mnt` with an image of `size_mib` attached at it. The image is declared
/// after the fixture so it detaches first.
fn mounted(fx: &Fixture, size_mib: u32) -> DiskImage {
    fx.dir("mnt").unwrap();
    let mnt = fx.path().join("mnt");
    let image = DiskImage::attach(&mnt, size_mib).unwrap();
    // `attach` already checked the device; this is what makes a scan of `mnt`
    // a scan of a different volume than the fixture's own.
    assert_ne!(
        fs::metadata(&mnt).unwrap().dev(),
        fs::metadata(fx.path()).unwrap().dev()
    );
    image
}

#[test]
fn scans_a_known_disk_image_to_exact_totals() {
    // Sizes chosen to cover the cases of rounding up to a block: an exact
    // multiple, a size short of a boundary, a size one byte over.
    const FILES: [(&str, u64); 3] = [
        ("a.bin", 1 << 20),
        ("dir/b.bin", 100_000),
        ("dir/deeper/c.bin", BLOCK + 1),
    ];
    let fx = Fixture::new().unwrap();
    let image = mounted(&fx, 64);
    for (rel, len) in FILES {
        fx.file(&format!("mnt/{rel}"), len).unwrap();
    }
    let mnt = image.mountpoint();

    // Preconditions. The image holds exactly what was written and nothing the
    // system added (an index, an event log): a hidden directory would make the
    // counts below fail for a reason that has nothing to do with the scanner.
    let mut top: Vec<_> = fs::read_dir(mnt)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    top.sort();
    assert_eq!(
        top,
        ["a.bin", "dir"],
        "the fresh volume holds something else"
    );
    // What the filesystem says it allocated is the reference, read through
    // `lstat` and so independent of the scanner's `getattrlistbulk`. It is not
    // block arithmetic written out in advance: measured once in about twenty
    // runs with other images busy, APFS gave the 100000-byte file 131072 bytes
    // (two 64 KiB extents) instead of 102400. So each file is only required
    // to be rounded up to a block and no more than one such extent over, and
    // the scanner is held to the filesystem's figure exactly.
    let mut expected_logical = 0;
    let mut expected_allocated = 0;
    for (rel, len) in FILES {
        let md = fs::metadata(mnt.join(rel)).unwrap();
        assert_eq!(md.len(), len);
        let allocated = md.blocks() * 512;
        let rounded = len.div_ceil(BLOCK) * BLOCK;
        assert!(
            (rounded..=rounded + 64 * 1024).contains(&allocated),
            "{rel}: {len} bytes allocated as {allocated}"
        );
        expected_logical += len;
        expected_allocated += allocated;
    }
    // Different numbers, so a scanner that reported one as the other is caught.
    assert_ne!(expected_logical, expected_allocated);

    let snapshot = scan(mnt);

    // The reference is only a reference if it held still: APFS reallocating a
    // file between the `lstat` above and the scan would otherwise surface as
    // a totals mismatch that blames the scanner.
    let allocated_after: u64 = FILES
        .iter()
        .map(|(rel, _)| fs::metadata(mnt.join(rel)).unwrap().blocks() * 512)
        .sum();
    assert_eq!(
        allocated_after, expected_allocated,
        "allocation moved during the test"
    );

    assert_eq!(snapshot.stats.dirs, 3, "the root, dir and dir/deeper");
    assert_eq!(snapshot.stats.files, 3);
    assert_eq!(
        counted(&snapshot),
        (3, 3),
        "the nodes agree with the counters"
    );
    let root = &snapshot.nodes[snapshot.root as usize];
    assert_eq!(root.logical, expected_logical);
    assert_eq!(root.allocated, expected_allocated);
}

/// The parser accepts exactly two fixed-region sizes, measured on APFS (68
/// bytes for a directory, 88 for everything else), and refuses any other as a
/// malformed batch. The packing is the VFS's, so the same two sizes were
/// measured on HFS+, exFAT and FAT32 too; this scans a real volume of each,
/// with APFS as the control, so a filesystem that packed the ten attributes
/// any other way would fail here as `MalformedBatch` rather than on a user's
/// external drive.
///
/// Totals are held to `lstat(2)`, an independent reading of the same
/// metadata, with one measured exception: on FAT32, `getattrlistbulk` returns
/// `ATTR_FILE_ALLOCSIZE` as 0 with its returned bit set, for every file,
/// while `getattrlist(2)` on the path and `lstat` report the real
/// allocation. That is the kernel's bulk path for msdosfs, not a misread (the
/// data length beside it is right), and it is pinned here so that a change
/// in it is noticed.
#[test]
fn every_filesystem_scans_with_only_the_two_measured_layouts() {
    let hdiutil = std::process::Command::new("hdiutil")
        .arg("help")
        .output()
        .unwrap_or_else(|e| panic!("this test needs hdiutil(1) to make disk images: {e}"));
    assert!(hdiutil.status.success(), "hdiutil help failed: {hdiutil:?}");

    // Sizes cover a sub-block file, an exact multiple of 4 KiB, and one byte
    // past a block; every filesystem here supports symlinks.
    const FILES: [(&str, u64); 3] = [
        ("a.bin", 5),
        ("dir/b.bin", 100 * 1024),
        ("dir/deeper/c.bin", BLOCK + 1),
    ];
    for fs in [
        Filesystem::Apfs,
        Filesystem::HfsPlus,
        Filesystem::ExFat,
        Filesystem::Fat32,
    ] {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let image = DiskImage::attach_fs(&mnt, 64, fs)
            .unwrap_or_else(|e| panic!("{fs:?}: making the image: {e}"));
        assert_ne!(
            fs::metadata(&mnt).unwrap().dev(),
            fs::metadata(fx.path()).unwrap().dev(),
            "{fs:?}: the image is a separate volume"
        );
        for (rel, len) in FILES {
            fx.file(&format!("mnt/{rel}"), len).unwrap();
        }
        fx.symlink("a.bin", "mnt/lnk").unwrap();

        // Precondition: the volume holds what was written, plus at most the
        // AppleDouble `._` companions exFAT and FAT32 keep extended
        // attributes in. Those are real entries, which the scanner counts.
        let mut top: Vec<_> = fs::read_dir(&mnt)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| !n.starts_with("._"))
            .collect();
        top.sort();
        assert_eq!(top, ["a.bin", "dir", "lnk"], "{fs:?}: the fresh volume");

        // The reference, from `lstat` over a walk by `std::fs`: independent
        // of `getattrlistbulk` and of the scanner.
        let (dirs, files, logical, allocated) = lstat_totals(&mnt);
        assert!(files >= 4, "{fs:?}: three files and a symlink at least");
        // Different numbers, so one reported as the other is caught.
        assert_ne!(logical, allocated, "{fs:?}");

        let opts = WalkOptions {
            root: mnt.clone(),
            ..WalkOptions::default()
        };
        let (arenas, stats) = walk_with_progress(&opts, &Progress::default()).unwrap();
        assert_eq!(
            stats.incomplete, None,
            "{fs:?}: no MalformedBatch, nothing short"
        );
        assert_eq!((stats.lost_entries, stats.errors), (0, 0), "{fs:?}");
        let snapshot = try_freeze(arenas, stats).unwrap();
        assert_eq!(dirs, 3, "{fs:?}: the root, dir and dir/deeper");
        assert_eq!(
            (snapshot.stats.dirs, snapshot.stats.files),
            (dirs, files),
            "{fs:?}"
        );
        assert_eq!(counted(&snapshot), (dirs, files), "{fs:?}");
        let root = &snapshot.nodes[snapshot.root as usize];
        assert_eq!(root.logical, logical, "{fs:?}: logical");
        if fs == Filesystem::Fat32 {
            assert_ne!(allocated, 0, "precondition: lstat sees FAT32 allocation");
            assert_eq!(root.allocated, 0, "FAT32: the bulk path's measured zero");
        } else {
            assert_eq!(root.allocated, allocated, "{fs:?}: allocated");
        }
        drop(image);
    }
}

/// `(dirs, files, logical, allocated)` under `root`, the root included, read
/// with `lstat` while walking by `std::fs`. Symlinks are not followed.
fn lstat_totals(root: &Path) -> (u64, u64, u64, u64) {
    let (mut dirs, mut files, mut logical, mut allocated) = (1, 0, 0, 0);
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for e in fs::read_dir(&dir).unwrap() {
            let path = e.unwrap().path();
            let md = fs::symlink_metadata(&path).unwrap();
            if md.is_dir() {
                dirs += 1;
                stack.push(path);
            } else {
                files += 1;
                logical += md.len();
                allocated += md.blocks() * 512;
            }
        }
    }
    (dirs, files, logical, allocated)
}

/// What copying one 8 MiB file four times did to a fresh image, seen two ways.
struct CopyMeasurement {
    /// Bytes the image's free space fell by, from before the original was
    /// written to after the last copy.
    volume_delta: u64,
    /// The scanned tree's total allocated size.
    tree_allocated: u64,
    files: u64,
}

const COPY_LEN: u64 = 8 << 20;
const COPIES: u64 = 4;
/// What the free-space reading may differ from the data written by: a few
/// blocks of the image's own metadata, measured at +1 and -1 block.
const SLACK: u64 = 64 * 1024;

/// Write one non-zero 8 MiB file to a fresh image, make four more files from
/// it with `copy`, and compare the volume's free-space delta with the scanned
/// total.
fn measure_copies(copy: impl Fn(&Fixture, &str, &str)) -> CopyMeasurement {
    let fx = Fixture::new().unwrap();
    // 64 MiB holds the original and four real copies (40 MiB) with room.
    let image = mounted(&fx, 64);

    let volume_delta = {
        // Nothing else in this binary may allocate between the readings:
        // `write_dense_file` and `copy_by_read_write` demand the lock, and
        // the reading is only a measurement while it is held.
        let _quiet = allocation_lock();
        let before = image.free_bytes().unwrap();
        write_dense_file(&image.mountpoint().join("orig.bin"), COPY_LEN).unwrap();
        for i in 0..COPIES {
            copy(&fx, "mnt/orig.bin", &format!("mnt/copy{i}.bin"));
        }
        before - image.free_bytes().unwrap()
    };

    let snapshot = scan(image.mountpoint());
    CopyMeasurement {
        volume_delta,
        tree_allocated: snapshot.nodes[snapshot.root as usize].allocated,
        files: snapshot.stats.files,
    }
}

#[test]
fn clones_make_the_tree_sum_exceed_the_volume_delta() {
    let m = measure_copies(|fx, src, dst| {
        fx.clone_of(src, dst).unwrap();
    });

    // Preconditions: the original really was written (the delta is not tiny
    // because nothing happened), and the clones really shared its blocks (it
    // is not two files' worth, let alone five).
    assert!(
        m.volume_delta >= COPY_LEN - SLACK,
        "the volume only used {} bytes: the 8 MiB file was not written",
        m.volume_delta
    );
    assert!(
        m.volume_delta < 2 * COPY_LEN,
        "the volume used {} bytes: the copies were not clones",
        m.volume_delta
    );
    assert_eq!(m.files, 1 + COPIES);

    // The point: every clone reports the full size of its blocks, so the tree
    // adds up to far more than the volume holds.
    assert_eq!(m.tree_allocated, (1 + COPIES) * COPY_LEN);
    assert!(m.tree_allocated > m.volume_delta);
    assert!(
        m.tree_allocated - m.volume_delta >= COPIES * COPY_LEN - SLACK,
        "tree {} over volume {}: the clones were not counted again",
        m.tree_allocated,
        m.volume_delta
    );
}

#[test]
fn real_copies_make_the_tree_sum_match_the_volume_delta() {
    // The control for the test above. The same measurement, with files that
    // do not share blocks: here the tree and the volume agree, so the
    // disagreement in the clone case is the clones and not the measurement.
    let m = measure_copies(|fx, src, dst| {
        copy_by_read_write(&fx.path().join(src), &fx.path().join(dst)).unwrap();
    });

    assert_eq!(m.files, 1 + COPIES);
    assert_eq!(m.tree_allocated, (1 + COPIES) * COPY_LEN);
    // Precondition for "agree": the volume really took five files' worth, so
    // the equality below is not two small numbers matching.
    assert!(
        m.volume_delta >= (1 + COPIES) * COPY_LEN - SLACK,
        "the volume only used {} bytes for five 8 MiB files",
        m.volume_delta
    );
    assert!(
        m.tree_allocated.abs_diff(m.volume_delta) <= SLACK,
        "tree {} and volume {} should agree for unshared copies",
        m.tree_allocated,
        m.volume_delta
    );
}

/// Longest the walk may take to come back once the volume is gone. A walk
/// that outlives this is hung, and the test fails instead of blocking the
/// suite behind it.
const HANG_LIMIT: Duration = Duration::from_secs(60);

/// What the walk thread reported.
#[derive(Debug)]
enum Walked {
    /// `walk_with_progress` returned `Err`.
    Failed { errno: Option<i32>, message: String },
    /// It returned `Ok`; this is what the result says about itself.
    Returned {
        nodes: u64,
        incomplete: Option<Incomplete>,
        errors: u64,
        lost_entries: u64,
        unreadable: usize,
        /// Whether the (possibly partial) result froze into a snapshot.
        froze: bool,
    },
}

#[derive(Debug)]
struct Attempt {
    /// Directories and files on the volume, the root included, counted by an
    /// undisturbed walk before the detach.
    created: u64,
    /// The walk had stored this many directories when the detach was issued,
    /// and had not yet returned: it was running.
    running_at_detach: bool,
    progress_at_detach: tesserae_core::progress::ProgressValues,
    detach_took: Duration,
    /// How long after the detach was *issued* the walk returned. `hdiutil`
    /// returns after the kernel has already unmounted, so this is normally
    /// shorter than `detach_took`.
    walk_returned_after: Duration,
    walked: Walked,
}

impl Walked {
    fn describe(&self) -> String {
        match self {
            Walked::Failed { errno, message } => format!("Err (errno {errno:?}): {message}"),
            Walked::Returned {
                nodes,
                incomplete,
                errors,
                lost_entries,
                unreadable,
                froze,
            } => format!(
                "Ok: {nodes} nodes, incomplete {incomplete:?}, errors {errors}, \
                 lost_entries {lost_entries}, unreadable {unreadable}, froze {froze}"
            ),
        }
    }
}

impl Attempt {
    /// Everything the attempt measured, for the test log and failure messages.
    fn report(&self) -> String {
        format!(
            "{} nodes on the volume; detach issued with {:?} stored and the walk {}running; \
             hdiutil took {:?}; the walk returned {:?} after the detach was issued; {}",
            self.created,
            self.progress_at_detach,
            if self.running_at_detach { "" } else { "not " },
            self.detach_took,
            self.walk_returned_after,
            self.walked.describe()
        )
    }

    /// The volume vanished while the walk was running and the walk had not
    /// already seen everything. Only then does the outcome say anything.
    fn cut_short(&self) -> bool {
        self.running_at_detach
            && match &self.walked {
                Walked::Failed { .. } => true,
                Walked::Returned { nodes, .. } => *nodes < self.created,
            }
    }
}

/// `dirs` directories of `per` empty files each, filled on four threads.
fn fill(root: &Path, dirs: u32, per: u32) {
    std::thread::scope(|s| {
        for first in 0..4 {
            s.spawn(move || {
                for d in (first..dirs).step_by(4) {
                    let dir = root.join(format!("d{d:05}"));
                    fs::create_dir(&dir).unwrap();
                    for f in 0..per {
                        File::create(dir.join(format!("f{f:03}"))).unwrap();
                    }
                }
            });
        }
    });
}

/// Fill a fresh image, walk it on another thread, and force-detach it once the
/// walk is under way.
fn detach_during_walk(dirs: u32, per: u32) -> Attempt {
    let fx = Fixture::new().unwrap();
    // Declared after the fixture: dropped, and so detached, first.
    let mut image = mounted(&fx, 512);
    let mnt = image.mountpoint().to_path_buf();
    fill(&mnt, dirs, per);

    // Precondition: an undisturbed walk sees the whole tree, so a short result
    // below can only be the detach.
    let created = 1 + u64::from(dirs) * (1 + u64::from(per));
    let whole = scan(&mnt);
    assert_eq!(
        whole.nodes.len() as u64,
        created,
        "the tree is not all there"
    );
    drop(whole);

    let opts = WalkOptions {
        root: mnt,
        workers: 4,
        // Short, so that a worker blocked on the dead volume is reported as a
        // stall in seconds. (On this machine nothing blocks; see the test.)
        stall_timeout: Duration::from_secs(2),
        ..WalkOptions::default()
    };
    let progress = Arc::new(Progress::default());
    let (tx, rx) = mpsc::channel();
    let walker = {
        let progress = Arc::clone(&progress);
        std::thread::spawn(move || {
            let result = walk_with_progress(&opts, &progress);
            let returned = Instant::now();
            let walked = match result {
                Err(e) => Walked::Failed {
                    errno: os_errno(&e),
                    message: e.to_string(),
                },
                Ok((arenas, stats)) => {
                    let nodes = stats.dirs + stats.files;
                    let (incomplete, errors, lost_entries, unreadable) = (
                        stats.incomplete,
                        stats.errors,
                        stats.lost_entries,
                        stats.unreadable.len(),
                    );
                    Walked::Returned {
                        nodes,
                        incomplete,
                        errors,
                        lost_entries,
                        unreadable,
                        froze: try_freeze(arenas, stats).is_ok(),
                    }
                }
            };
            let _ = tx.send((returned, walked));
        })
    };

    // Wait for the walk to be demonstrably under way: a handful of
    // directories stored, the walk not yet returned.
    let started_waiting = Instant::now();
    // A walk that returns before it stored five directories has a result
    // already sitting in the channel; take it rather than wait it out.
    let mut early = None;
    while early.is_none() && progress.snapshot().dirs < 5 {
        assert!(
            started_waiting.elapsed() < HANG_LIMIT,
            "the walk stored no directories in {HANG_LIMIT:?}"
        );
        early = rx.try_recv().ok();
        std::thread::sleep(Duration::from_micros(200));
    }
    let progress_at_detach = progress.snapshot();
    let early = early.or_else(|| rx.try_recv().ok());
    let issued = Instant::now();
    image.force_detach().unwrap();
    let detach_took = issued.elapsed();

    let running_at_detach = early.is_none();
    let (returned, walked) = match early {
        Some(done) => done,
        None => match rx.recv_timeout(HANG_LIMIT) {
            Ok(done) => done,
            Err(RecvTimeoutError::Timeout) => {
                panic!("the walk had not returned {HANG_LIMIT:?} after the volume vanished")
            }
            Err(RecvTimeoutError::Disconnected) => {
                // The thread ended without reporting: it panicked.
                let payload = walker.join().unwrap_err();
                panic!("the walk panicked: {payload:?}");
            }
        },
    };
    walker.join().expect("the walk thread must not panic");
    Attempt {
        created,
        running_at_detach,
        progress_at_detach,
        detach_took,
        walk_returned_after: returned.saturating_duration_since(issued),
        walked,
    }
}

/// A volume that vanishes mid-scan must not hang the scan, panic it, or come
/// back looking complete: the walk returns `Ok` with `incomplete ==
/// Some(VolumeLost)`, the errors it met on the way still counted, and a
/// partial result that freezes.
///
/// Measured on macOS 27.2 (see the report): `hdiutil detach -force` takes
/// about 0.3 s and unmounts in the kernel well before it returns. A walker
/// holding descriptors on the volume then gets `ENOTDIR` from
/// `getattrlistbulk` and `openat`, `EBADF` from `fstat` and `ENOTSUP` from
/// `fstatfs`. `ENOTDIR` alone is also what churn on a live volume gives, so
/// the walk answers it by asking the root's descriptor which volume it is on;
/// before that check existed the same detach returned `incomplete == None`
/// with only `errors > 0`, a third of a tree presented as a finished scan.
/// `Err` is not an accepted outcome: the root opened, so the walk returns what
/// it read.
///
/// The detach races the walk, so the test insists on evidence the detach
/// landed mid-walk (the walk had stored directories and had not returned when
/// it was issued, and its tree is short of an undisturbed walk's) and retries
/// with a bigger tree if the walk won, a bounded number of times, rather than
/// pass on a walk the detach never touched.
#[test]
fn reports_incomplete_when_the_image_detaches_mid_scan() {
    // 100k, 200k and 400k files.
    const SIZES: [(u32, u32); 3] = [(1000, 100), (2000, 100), (4000, 100)];
    for (dirs, per) in SIZES {
        let attempt = detach_during_walk(dirs, per);
        eprintln!(
            "detach mid-scan, {dirs} dirs x {per} files: {}",
            attempt.report()
        );
        if !attempt.cut_short() {
            eprintln!("the walk finished before the volume vanished; trying a bigger tree");
            continue;
        }
        match &attempt.walked {
            Walked::Failed { .. } => {
                panic!(
                    "the walk returned Err after it had started: {}",
                    attempt.report()
                )
            }
            Walked::Returned {
                nodes,
                incomplete,
                errors,
                froze,
                ..
            } => {
                assert_eq!(
                    *incomplete,
                    Some(Incomplete::VolumeLost),
                    "{nodes} of {} nodes came back not marked as a lost volume: {}",
                    attempt.created,
                    attempt.report()
                );
                assert!(
                    *errors > 0,
                    "the directories that failed are still counted: {}",
                    attempt.report()
                );
                assert!(
                    froze,
                    "a partial result must still freeze: {}",
                    attempt.report()
                );
            }
        }
        return;
    }
    panic!("at every size tried the walk finished before the volume vanished");
}
