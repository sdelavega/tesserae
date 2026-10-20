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

use super::lane::Dir;
use super::walker::Frame;
use super::*;
use crate::arena::{ScanNode, FLAG_PERM_DENIED};
use crate::attrs::{scan_attrlist, SCAN_OPTIONS};
use crate::parse::ObjType;
use std::ffi::{CStr, CString};
use std::fs::{self, File};
use std::os::fd::RawFd;
use std::os::raw::c_int;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use tesserae_testutil::{DiskImage, Fixture};

pub(super) fn opts(root: &Path) -> WalkOptions {
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
/// `DirOpener` is `Sync`, so these counters are atomics rather than
/// `Cell`s: the same opener has to be shareable with every worker of a
/// parallel walk, even though these particular openers only ever drive a
/// serial one.
struct SwapBeforeOpen {
    victim: std::path::PathBuf,
    /// `None` swaps in a regular file; `Some(target)` swaps in a symlink.
    symlink_to: Option<&'static str>,
    fired: AtomicU32,
}

impl DirOpener for SwapBeforeOpen {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        if name.to_bytes() == b"victim" && self.fired.load(Ordering::Relaxed) == 0 {
            fs::remove_dir_all(&self.victim).unwrap();
            match self.symlink_to {
                None => drop(File::create(&self.victim).unwrap()),
                Some(t) => std::os::unix::fs::symlink(t, &self.victim).unwrap(),
            }
            self.fired.fetch_add(1, Ordering::Relaxed);
        }
        OpenAt.open_dir_at(parent, name)
    }
}

/// Counts descents without changing them.
struct CountingOpener {
    opens: AtomicU32,
}

impl DirOpener for CountingOpener {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        self.opens.fetch_add(1, Ordering::Relaxed);
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

/// Set `rel`'s modification time to `sec` seconds, without following a
/// symlink.
fn set_mtime(root: &Path, rel: &str, sec: i64) {
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(root.join(rel).as_os_str().as_bytes()).unwrap();
    let times = [
        // Access time left alone.
        libc::timespec {
            tv_sec: 0,
            tv_nsec: libc::UTIME_OMIT,
        },
        libc::timespec {
            tv_sec: sec,
            tv_nsec: 0,
        },
    ];
    // SAFETY: `c` is NUL-terminated and `times` holds the two timespecs
    // `utimensat` reads.
    let rc = unsafe {
        libc::utimensat(
            libc::AT_FDCWD,
            c.as_ptr(),
            times.as_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    assert_eq!(
        rc,
        0,
        "utimensat {rel}: {}",
        std::io::Error::last_os_error()
    );
}

/// The walker copies each entry's `ATTR_CMN_MODTIME` into its node, and gives
/// the root (which has no entry of its own) the time `fstat` reports for it.
/// Freezing then rolls the newest time up, so this is the whole path from the
/// kernel's buffer to the snapshot.
#[test]
fn walk_records_each_entrys_modified_time_and_the_roots_own() {
    let fx = Fixture::new().unwrap();
    fx.file("a.bin", 10).unwrap();
    fx.file("d/b.bin", 10).unwrap();
    fx.symlink("a.bin", "lnk").unwrap();
    // Children first: creating an entry updates its directory's time.
    set_mtime(fx.path(), "a.bin", 1_000_000_000);
    set_mtime(fx.path(), "d/b.bin", 1_500_000_000);
    set_mtime(fx.path(), "lnk", 1_200_000_000);
    set_mtime(fx.path(), "d", 1_100_000_000);
    set_mtime(fx.path(), "", 1_300_000_000);

    let before = now_epoch_secs();
    let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();
    let after = now_epoch_secs();
    assert_eq!(stats.incomplete, None);
    assert_eq!((stats.files, stats.dirs), (3, 2), "precondition: the tree");
    // The walk records when it began: freeze's cutoff for directory times.
    assert!(
        (before..=after).contains(&stats.started_at),
        "started_at {} is not within {before}..={after}",
        stats.started_at
    );
    // The parallel walker too, through the merge of its workers' stats.
    let (_, pooled) = crate::pool::walk(&opts(fx.path())).unwrap();
    assert!(
        (before..=now_epoch_secs()).contains(&pooled.started_at),
        "pool started_at {}",
        pooled.started_at
    );
    for (name, want) in [
        (&b"a.bin"[..], 1_000_000_000),
        (b"b.bin", 1_500_000_000),
        (b"lnk", 1_200_000_000),
        (b"d", 1_100_000_000),
    ] {
        let hits = find(&arena, name);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].modified, want, "{}", String::from_utf8_lossy(name));
    }
    let root = arena
        .iter()
        .map(|(_, n)| n)
        .find(|n| n.parent == ScanId::NONE)
        .expect("a root");
    assert_eq!(
        root.modified, 1_300_000_000,
        "the root's own time, from fstat"
    );

    let snap = crate::freeze::freeze(vec![arena], stats);
    let root = &snap.nodes[snap.root as usize];
    assert_eq!(root.modified, 1_500_000_000, "rolled up from d/b.bin");
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
        fired: AtomicU32::new(0),
    };

    let (arena, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

    assert_eq!(
        opener.fired.load(Ordering::Relaxed),
        1,
        "the swap must actually have run"
    );
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
        fired: AtomicU32::new(0),
    };

    let (_, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

    assert_eq!(opener.fired.load(Ordering::Relaxed), 1);
    assert!(fx.path().join("victim").is_symlink());
    assert_eq!(stats.errors, 1);
    assert_eq!(stats.files, 1, "other/f.bin once, not again via victim");
    assert_eq!(stats.incomplete, None);
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

    let inodes = InodeSet::new(1);
    let budget = NodeBudget::new(u64::MAX);
    let halt = Halt::new();
    let progress = Progress::default();
    let lane = Lane::new(Arena::new(0, u64::MAX));
    let ctx = WalkerCtx {
        skips: &super::SkipSet::default(),
        opener: &OpenAt,
        inodes: &inodes,
        budget: &budget,
        halt: &halt,
        progress: &progress,
        root_volume: VolumeId::new(0, 0),
        root_path: fx.path(),
        root_dir: None,
    };
    let mut w = Walker::new(&ctx, None, &opts(fx.path()), &lane).unwrap();
    let mut slot = lane.lock_raw().unwrap();
    let root = w.push(&mut slot, b"root", ScanId::NONE, None).unwrap();
    let mut frame = Frame {
        dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
        depth: 0,
        sizing: crate::boundary::Sizing::Reported,
        children: Vec::new(),
        dataless_skips: Vec::new(),
        next: 0,
    };

    w.consume_batch(&mut slot, &mut frame, root, &buf, 3)
        .unwrap();

    assert_eq!(slot.stats.files, 1, "only the entry before the bad one");
    assert_eq!(
        slot.stats.lost_entries, 2,
        "the bad entry and the one after"
    );
    assert_eq!(slot.stats.incomplete, Some(Incomplete::MalformedBatch));
    assert_eq!(slot.stats.errors, 0, "a short result, not a stray error");

    // And a batch that is bad from its first entry loses all of it.
    buf[..4].copy_from_slice(&0u32.to_le_bytes());
    w.consume_batch(&mut slot, &mut frame, root, &buf, 3)
        .unwrap();
    assert_eq!(slot.stats.lost_entries, 2 + 3);
}

/// The volume `p` is on, as the boundary sees it.
fn volume_at(p: &Path) -> VolumeId {
    volume_of(File::open(p).unwrap().as_raw_fd()).unwrap()
}

#[test]
fn walk_does_not_cross_into_a_mounted_disk_image() {
    let fx = Fixture::new().unwrap();
    fx.file("before.bin", 4096).unwrap();
    fx.dir("mnt").unwrap();
    let mnt = fx.path().join("mnt");
    // Declared after `fx`, so it drops first: the volume is unmounted
    // before the fixture removes its tree, and on a panic too.
    let image = DiskImage::attach(&mnt, 16)
        .expect("this test needs hdiutil to be able to attach a disk image");
    fs::write(mnt.join("on_image.bin"), vec![1u8; 8192]).unwrap();
    fs::create_dir(mnt.join("sub")).unwrap();
    fs::write(mnt.join("sub/deep.bin"), vec![2u8; 8192]).unwrap();

    // Without these the test could pass because the image never mounted and
    // the files simply are not there. The image is a different volume, the
    // files exist on it, and a walk that is *rooted* on it finds them.
    assert_ne!(
        volume_at(&mnt),
        volume_at(fx.path()),
        "the image must be a mount"
    );
    assert!(mnt.join("on_image.bin").is_file());
    let (control, control_stats) = walk_serial(&opts(&mnt)).unwrap();
    assert_eq!(find(&control, b"on_image.bin").len(), 1);
    assert_eq!(find(&control, b"deep.bin").len(), 1);
    assert!(
        control_stats.skipped_mounts.is_empty(),
        "the root is walked"
    );

    // `include_non_local` must not open this: the image is a local volume.
    // This loop proves only that negative. The positive half (the flag
    // does open a non-local mount) is `a_non_local_mount_is_skipped_unless_opted_in`.
    for include_non_local in [false, true] {
        let mut o = opts(fx.path());
        o.include_non_local = include_non_local;

        let (arena, stats) = walk_serial(&o).unwrap();

        let ctx = format!("include_non_local {include_non_local}");
        assert_eq!(
            stats.skipped_mounts,
            vec![(mnt.clone(), SkipReason::OtherVolume)],
            "{ctx}"
        );
        assert!(find(&arena, b"on_image.bin").is_empty(), "{ctx}");
        assert!(find(&arena, b"sub").is_empty(), "{ctx}");
        assert!(find(&arena, b"deep.bin").is_empty(), "{ctx}");
        assert_eq!(find(&arena, b"before.bin").len(), 1, "{ctx}");
        // The mount point is a node, but a childless one.
        assert_eq!(find(&arena, b"mnt").len(), 1, "{ctx}");
        assert_eq!((stats.dirs, stats.files), (2, 1), "{ctx}: root and mnt");
        assert_eq!(arena.len(), 3, "{ctx}");
        assert_eq!(stats.errors, 0, "a skip is policy, not an error ({ctx})");
        assert_eq!(stats.incomplete, None, "{ctx}");
        assert!(stats.unreadable.is_empty(), "{ctx}");
    }
    drop(image);
}

/// Hands back a descriptor on the automounter's `/home` (a mount the
/// kernel reports as non-local) in place of the directory `victim`. The
/// boundary then sees a real change of volume and a real `MNT_LOCAL` clear.
struct NonLocalForVictim;

impl DirOpener for NonLocalForVictim {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        if name.to_bytes() == b"victim" {
            return File::open("/System/Volumes/Data/home")
                .map(OwnedFd::from)
                .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO));
        }
        OpenAt.open_dir_at(parent, name)
    }
}

#[test]
fn a_non_local_mount_is_skipped_unless_opted_in() {
    let fx = Fixture::new().unwrap();
    fx.file("victim/inner.bin", 4096).unwrap();
    fx.file("other/f.bin", 4096).unwrap();

    let (arena, stats) = walk_serial_with(&opts(fx.path()), &NonLocalForVictim).unwrap();

    assert_eq!(
        stats.skipped_mounts,
        vec![(fx.path().join("victim"), SkipReason::NonLocalMount)]
    );
    assert_eq!(stats.files, 1, "other/f.bin was still reached");
    assert_eq!(stats.dirs, 3, "root, victim and other");
    assert_eq!(stats.errors, 0);
    assert_eq!(stats.incomplete, None);
    assert_eq!(arena.len(), 4);

    // Opted in. This half is partly inferred, and that is an environment
    // limit, not an oversight: the only non-local mount an unprivileged
    // test can open (the automounter's `/home`) is empty, so entering it
    // changes no node count. What is observed is that it is no longer
    // recorded in `skipped_mounts`, and the walk finished cleanly. It does
    // not, on its own, rule out an `admit` that returned `Ok(false)`
    // without recording. The skip half above fails if the policy
    // misclassifies the mount, and `boundary::the_policy_table` and
    // `refuses_non_local_mount_unless_opted_in` cover the opt-in decision
    // itself; only "and then it was actually read" needs a non-local mount
    // with content, which cannot be made without a server.
    let mut o = opts(fx.path());
    o.include_non_local = true;
    let (arena, stats) = walk_serial_with(&o, &NonLocalForVictim).unwrap();

    assert!(
        stats.skipped_mounts.is_empty(),
        "{:?}",
        stats.skipped_mounts
    );
    assert_eq!(stats.files, 1);
    assert_eq!(stats.dirs, 3);
    assert_eq!(stats.errors, 0);
    assert_eq!(stats.incomplete, None);
    assert_eq!(arena.len(), 4);
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
        opens: AtomicU32::new(0),
    };

    let (arena, stats) = walk_serial_with(&o, &opener).unwrap();

    assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
    assert_eq!(arena.len(), 3);
    assert_eq!(
        opener.opens.load(Ordering::Relaxed),
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

/// A walker with a halt and a budget of its own, for the two tests below.
fn halted_walker<'a>(
    ctx: &WalkerCtx<'a, OpenAt>,
    opts: &WalkOptions,
    lane: &'a Lane,
) -> Walker<'a, OpenAt> {
    Walker::new(ctx, None, opts, lane).unwrap()
}

/// Half of "one worker's failure stops the others": a worker that sees the
/// halt raised stops at its very next push, whatever it was doing.
///
/// Through real threads the timing is a race by definition, so no pool
/// test bounds how much the other workers store before they notice (see
/// `pool::tests::one_workers_arena_failure_is_the_whole_walks_failure`
/// for why). This is the property with the race taken out; with
/// `a_terminal_failure_raises_the_halt` it is the whole mechanism.
#[test]
fn a_raised_halt_stops_a_push_dead() {
    let fx = Fixture::new().unwrap();
    let inodes = InodeSet::new(1);
    let budget = NodeBudget::new(u64::MAX);
    let halt = Halt::new();
    let progress = Progress::default();
    let lane = Lane::new(Arena::new(0, u64::MAX));
    let ctx = WalkerCtx {
        skips: &super::SkipSet::default(),
        opener: &OpenAt,
        inodes: &inodes,
        budget: &budget,
        halt: &halt,
        progress: &progress,
        root_volume: VolumeId::new(0, 0),
        root_path: fx.path(),
        root_dir: None,
    };
    let mut w = halted_walker(&ctx, &opts(fx.path()), &lane);
    let mut slot = lane.lock_raw().unwrap();

    // Before: a push works and the budget is nowhere near spent.
    w.push(&mut slot, b"before", ScanId::NONE, None)
        .expect("push works");
    assert_eq!(slot.arena.len(), 1);

    // Another worker fails.
    halt.raise(Incomplete::OutOfMemory);

    // After: this worker stops, with the other's reason, and stores
    // nothing — not even the name bytes, since the halt is checked first.
    assert_eq!(
        w.push(&mut slot, b"after", ScanId::NONE, None),
        Err(Incomplete::OutOfMemory)
    );
    assert_eq!(slot.arena.len(), 1, "a node was stored after the halt");
    drop(slot);
    // And the lock refuses it too, before the slot is even touched.
    assert!(matches!(w.lock(), Err(Incomplete::OutOfMemory)));

    // First reason wins, so a later failure cannot rewrite history.
    halt.raise(Incomplete::NodeBudget);
    assert_eq!(halt.reason(), Some(Incomplete::OutOfMemory));
}

/// The other half: a terminal failure in this worker raises the halt, so
/// there is something for every other worker to see.
#[test]
fn a_terminal_failure_raises_the_halt() {
    let fx = Fixture::new().unwrap();
    for i in 0..10 {
        fx.file(&format!("f{i}.bin"), 1).unwrap();
    }
    let inodes = InodeSet::new(1);
    // Room for the root and two files, then the walk is over.
    let budget = NodeBudget::new(3);
    let halt = Halt::new();
    let root_fd = open_root(&opts(fx.path())).unwrap();
    let progress = Progress::default();
    let lane = Lane::new(Arena::new(0, u64::MAX));
    let ctx = WalkerCtx {
        skips: &super::SkipSet::default(),
        opener: &OpenAt,
        inodes: &inodes,
        budget: &budget,
        halt: &halt,
        progress: &progress,
        root_volume: root_volume_of(&opts(fx.path()), &root_fd).unwrap(),
        root_path: fx.path(),
        root_dir: None,
    };
    let mut w = halted_walker(&ctx, &opts(fx.path()), &lane);

    assert_eq!(halt.reason(), None, "nothing has failed yet");
    let outcome = w.run_root(root_fd);

    assert_eq!(outcome, Err(Incomplete::NodeBudget));
    assert_eq!(
        halt.reason(),
        Some(Incomplete::NodeBudget),
        "the failure was not announced, so no other worker would stop"
    );
    let (arena, stats) = w.finish();
    assert_eq!(arena.len(), 3);
    assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
}

#[test]
fn empty_root_walks_to_a_single_node() {
    let fx = Fixture::new().unwrap();
    let (arena, stats) = walk_serial(&opts(fx.path())).unwrap();
    assert_eq!((arena.len(), stats.dirs, stats.files), (1, 1, 0));
    assert_eq!(stats.incomplete, None);
}

/// Any attempt to open the protected child fails the test, including work
/// reopened by a different parallel worker.
struct RefuseRequestedOpen;
impl DirOpener for RefuseRequestedOpen {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        assert_ne!(name.to_bytes(), b"protected", "skipped child was opened");
        OpenAt.open_dir_at(parent, name)
    }
    fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
        assert!(
            !rel.to_bytes()
                .split(|b| *b == b'/')
                .any(|p| p == b"protected"),
            "skipped child was published and reopened"
        );
        OpenAt.reopen_dir_beneath(root, rel)
    }
}

#[test]
fn limited_admission_never_opens_skips_and_matches_symlink_and_parent_aliases() {
    use crate::arena::FLAG_SKIPPED_REQUEST;
    use std::os::unix::fs::{symlink, MetadataExt};
    use std::sync::Arc;
    let fx = Fixture::new().unwrap();
    fx.file("tree/protected/secret", 8192).unwrap();
    fx.file("tree/visible", 7).unwrap();
    symlink("protected", fx.path().join("tree/link")).unwrap();
    symlink("tree", fx.path().join("parent-alias")).unwrap();
    let root = fx.path().join("tree");
    let protected = root.join("protected");
    assert_eq!(
        fs::metadata(&protected).unwrap().ino(),
        fs::metadata(fx.path().join("parent-alias/protected"))
            .unwrap()
            .ino(),
        "precondition: same inode through alias"
    );
    let (full, _) = walk_serial(&opts(&root)).unwrap();
    assert_eq!(
        find(&full, b"secret").len(),
        1,
        "precondition: full scan enters protected"
    );
    let full_total = totals(&full);
    for skip in [
        protected.clone(),
        root.join("link"),
        fx.path().join("parent-alias/protected"),
    ] {
        for parallel in [false, true] {
            let o = WalkOptions {
                skip: vec![skip.clone()],
                workers: 4,
                ..opts(&root)
            };
            let (arenas, stats) = if parallel {
                crate::pool::walk_with(&o, Arc::new(RefuseRequestedOpen), &[], &Progress::default())
                    .unwrap()
            } else {
                let (a, s) = walk_serial_with(&o, &RefuseRequestedOpen).unwrap();
                (vec![a], s)
            };
            assert_eq!(stats.dirs, 2);
            assert!(stats.unreadable.is_empty());
            assert_eq!(
                stats.skipped_by_request,
                vec![(protected.clone(), "limited scan")]
            );
            assert!(stats.incomplete.is_none());
            assert_eq!(stats.errors, 0);
            let mut skipped = 0;
            for a in &arenas {
                assert!(find(a, b"secret").is_empty());
                for (id, node) in a.iter() {
                    if a.name_bytes(node.name) == b"protected" {
                        skipped += 1;
                        assert_eq!(
                            node.flags & (FLAG_SKIPPED_REQUEST | FLAG_PERM_DENIED),
                            FLAG_SKIPPED_REQUEST | FLAG_PERM_DENIED
                        );
                        assert!(!a.iter().any(|(_, child)| child.parent == id));
                    }
                }
            }
            assert_eq!(skipped, 1);
            let limited = arenas
                .iter()
                .map(totals)
                .fold((0, 0), |(l, a), (x, y)| (l + x, a + y));
            assert_eq!(full_total.0 - limited.0, 8192);
            assert!(full_total.1 > limited.1, "excluded allocated bytes");
        }
    }
}

#[test]
fn limited_root_is_recorded_unknown_without_entering_and_missing_is_reported() {
    use crate::arena::FLAG_SKIPPED_REQUEST;
    let fx = Fixture::new().unwrap();
    fx.file("secret", 8192).unwrap();
    let missing = fx.path().join("absent");
    assert!(!missing.exists(), "precondition");
    for parallel in [false, true] {
        let o = WalkOptions {
            skip: vec![fx.path().to_path_buf(), missing.clone()],
            ..opts(fx.path())
        };
        let (arenas, stats) = if parallel {
            crate::pool::walk(&o).unwrap()
        } else {
            let (a, s) = walk_serial(&o).unwrap();
            (vec![a], s)
        };
        assert_eq!(arenas.iter().map(Arena::len).sum::<u64>(), 1);
        let node = arenas[0].iter().next().unwrap().1;
        assert_ne!(node.flags & FLAG_SKIPPED_REQUEST, 0);
        assert_ne!(node.flags & FLAG_PERM_DENIED, 0, "unknown size path reused");
        assert_eq!(stats.dirs, 1);
        assert_eq!(stats.files, 0);
        assert!(stats
            .skipped_by_request
            .contains(&(missing.clone(), "not present")));
        assert!(stats
            .skipped_by_request
            .contains(&(fx.path().to_path_buf(), "limited scan")));
    }
    let o = WalkOptions {
        skip: vec![missing.clone()],
        ..opts(fx.path())
    };
    let (a, stats) = walk_serial(&o).unwrap();
    assert_eq!(
        find(&a, b"secret").len(),
        1,
        "missing request does not hide live content"
    );
    assert_eq!(stats.skipped_by_request, vec![(missing, "not present")]);
}

#[test]
fn limited_admission_uses_bulk_identity_and_falls_back_for_zero_fileid() {
    use std::os::unix::fs::MetadataExt;
    for fallback in [false, true] {
        let fx = Fixture::new().unwrap();
        fx.file("protected/secret", 7).unwrap();
        let protected = fx.path().join("protected");
        let options = WalkOptions {
            skip: vec![protected.clone()],
            ..opts(fx.path())
        };
        let skips = super::SkipSet::resolve(&options).unwrap();
        let (mut buf, count) = single_call(fx.path(), 4096);
        assert_eq!(count, 1, "precondition: just the protected directory");
        let entry = crate::parse::entries(&buf, count as u32)
            .next()
            .unwrap()
            .unwrap();
        assert_eq!(entry.file_id, fs::metadata(&protected).unwrap().ino());
        assert_ne!(entry.file_id, 0, "precondition: bulk has real identity");
        if fallback {
            buf[60..68].copy_from_slice(&0u64.to_le_bytes());
        }
        let inodes = InodeSet::new(1);
        let budget = NodeBudget::new(u64::MAX);
        let halt = Halt::new();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let ctx = WalkerCtx {
            skips: &skips,
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: VolumeId::new(0, 0),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = Walker::new(&ctx, None, &options, &lane).unwrap();
        let mut slot = lane.lock_raw().unwrap();
        let root = w.push(&mut slot, b"", ScanId::NONE, None).unwrap();
        let mut frame = Frame {
            dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
            depth: 0,
            sizing: crate::boundary::Sizing::Reported,
            children: Vec::new(),
            dataless_skips: Vec::new(),
            next: 0,
        };
        w.consume_batch(&mut slot, &mut frame, root, &buf, count as u32)
            .unwrap();
        assert_eq!(frame.children.len(), 1, "precondition: pending child");
        drop(slot);
        // A real bulk identity needs no further lookup. The fallback must
        // resolve the still-present directory with fstatat.
        if !fallback {
            fs::remove_dir_all(&protected).unwrap();
        }
        w.admit_children(&mut frame).unwrap();
        assert!(frame.children.is_empty());
        let (_, stats) = w.finish();
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.skipped_by_request, vec![(protected, "limited scan")]);
    }
}

#[test]
fn dataless_bulk_entries_are_counted_and_directories_never_queued() {
    for directory in [false, true] {
        let fx = Fixture::new().unwrap();
        if directory {
            fx.dir("cloud").unwrap();
        } else {
            fx.file("cloud", 1048576).unwrap();
        }
        let options = opts(fx.path());
        let (mut buf, count) = single_call(fx.path(), 4096);
        assert_eq!(count, 1, "precondition: one entry");
        buf[56..60].copy_from_slice(&0x40000000u32.to_le_bytes());
        if !directory {
            buf[72..80].copy_from_slice(&0u64.to_le_bytes());
        }
        let e = crate::parse::entries(&buf, 1).next().unwrap().unwrap();
        assert_eq!(e.flags, 0x40000000);
        assert_eq!(e.obj_type == ObjType::Dir, directory);
        let inodes = InodeSet::new(1);
        let budget = NodeBudget::new(u64::MAX);
        let halt = Halt::new();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let skips = SkipSet::resolve(&options).unwrap();
        let ctx = WalkerCtx {
            skips: &skips,
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: VolumeId::new(0, 0),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = Walker::new(&ctx, None, &options, &lane).unwrap();
        let mut slot = lane.lock_raw().unwrap();
        let root = w.push(&mut slot, b"", ScanId::NONE, None).unwrap();
        let mut frame = Frame {
            dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
            depth: 0,
            sizing: crate::boundary::Sizing::Reported,
            children: Vec::new(),
            dataless_skips: Vec::new(),
            next: 0,
        };
        w.consume_batch(&mut slot, &mut frame, root, &buf, count as u32)
            .unwrap();

        assert_eq!(
            slot.stats.dataless_paths,
            if directory {
                vec![fx.path().join("cloud")]
            } else {
                vec![]
            }
        );
        assert_eq!(slot.stats.dataless.files, u64::from(!directory));
        assert_eq!(slot.stats.dataless.directories, u64::from(directory));
        assert_eq!(
            slot.stats.dataless.logical_bytes,
            if directory { 0 } else { 1048576 }
        );
        assert_eq!(
            slot.stats.unreadable.len(),
            0,
            "cloud is not permission failure"
        );
        assert_eq!(slot.stats.errors, 0);
        assert_eq!(slot.bytes, 0, "no local allocation");
        assert!(
            frame.children.is_empty(),
            "cloud directory must not be entered or published"
        );
        let node = find(&slot.arena, b"cloud")[0];
        assert_ne!(node.flags & (1 << 6), 0, "dataless flag survives parsing");
        if directory {
            assert_ne!(node.flags & FLAG_PERM_DENIED, 0, "unknown size");
        } else {
            assert_eq!(node.logical, 1048576, "logical size retained");
        }
        drop(slot);
        drop(frame);
        let (arena, stats) = w.finish();
        let snapshot = crate::freeze::freeze(vec![arena], stats);
        assert_eq!(snapshot.nodes.len(), 2, "precondition: no hidden children");
        let frozen = snapshot
            .nodes
            .iter()
            .find(|n| n.flags & crate::arena::FLAG_DATALESS != 0)
            .unwrap();
        assert_eq!(frozen.child_count, 0);
        assert_eq!(frozen.allocated, 0);
        assert_eq!(frozen.flags & FLAG_PERM_DENIED != 0, directory);
    }
}

#[test]
fn every_scan_thread_attempts_policy_before_open_and_failure_is_nonfatal() {
    use std::sync::{Arc, Mutex};
    thread_local! { static ATTEMPTED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }
    struct Policy {
        supervisor: Option<std::thread::ThreadId>,
        threads: Mutex<std::collections::HashSet<std::thread::ThreadId>>,
    }
    impl DirOpener for Policy {
        fn no_materialize(&self) -> io::Result<()> {
            ATTEMPTED.set(true);
            self.threads
                .lock()
                .unwrap()
                .insert(std::thread::current().id());
            if self.supervisor == Some(std::thread::current().id()) {
                Ok(())
            } else {
                Err(io::Error::from_raw_os_error(libc::EPERM))
            }
        }
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            assert!(ATTEMPTED.get(), "policy precedes worker open");
            OpenAt.open_dir_at(parent, name)
        }
        fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
            assert!(ATTEMPTED.get(), "policy precedes worker reopen");
            OpenAt.reopen_dir_beneath(root, rel)
        }
    }
    let fx = Fixture::new().unwrap();
    fx.file("child/file", 17).unwrap();
    for parallel in [false, true] {
        ATTEMPTED.set(false);
        let policy = Arc::new(Policy {
            supervisor: parallel.then(|| std::thread::current().id()),
            threads: Mutex::default(),
        });
        let mut options = opts(fx.path());
        options.workers = 4;
        let (nodes, stats, expected) = if parallel {
            let (arenas, stats) =
                crate::pool::walk_with(&options, Arc::clone(&policy), &[], &Progress::default())
                    .unwrap();
            assert_eq!(arenas.len(), 4, "precondition: genuinely parallel");
            let expected = arenas.len() + 1; // workers and root-opening supervisor
            (arenas.iter().map(Arena::len).sum::<u64>(), stats, expected)
        } else {
            let (arena, stats) = walk_serial_with(&options, &*policy).unwrap();
            (arena.len(), stats, 1)
        };
        assert_eq!(nodes, 3, "failure must not stop scanning");
        assert_eq!(stats.incomplete, None);
        assert!(stats.no_materialize_failed, "failure reaches report");
        assert_eq!(
            policy.threads.lock().unwrap().len(),
            expected,
            "even idle workers attempt policy"
        );
    }
}

#[test]
fn dataless_requested_skip_uses_bulk_identity_and_zero_fileid_fallback() {
    use std::os::unix::fs::MetadataExt;
    for (fallback, matched) in [(false, true), (true, true), (false, false), (true, false)] {
        let fx = Fixture::new().unwrap();
        fx.file("protected/secret", 7).unwrap();
        let protected = fx.path().join("protected");
        let options = WalkOptions {
            skip: vec![if matched {
                protected.clone()
            } else {
                fx.path().to_path_buf()
            }],
            ..opts(fx.path())
        };
        let skips = super::SkipSet::resolve(&options).unwrap();
        let (mut buf, count) = single_call(fx.path(), 4096);
        assert_eq!(count, 1, "precondition: just the protected directory");
        let entry = crate::parse::entries(&buf, count as u32)
            .next()
            .unwrap()
            .unwrap();
        assert_eq!(entry.file_id, fs::metadata(&protected).unwrap().ino());
        assert_ne!(entry.file_id, 0, "precondition: bulk has real identity");
        if fallback {
            buf[60..68].copy_from_slice(&0u64.to_le_bytes());
        }
        buf[56..60].copy_from_slice(&0x40000000u32.to_le_bytes());
        let inodes = InodeSet::new(1);
        let budget = NodeBudget::new(u64::MAX);
        let halt = Halt::new();
        let progress = Progress::default();
        let lane = Lane::new(Arena::new(0, u64::MAX));
        let ctx = WalkerCtx {
            skips: &skips,
            opener: &OpenAt,
            inodes: &inodes,
            budget: &budget,
            halt: &halt,
            progress: &progress,
            root_volume: VolumeId::new(0, 0),
            root_path: fx.path(),
            root_dir: None,
        };
        let mut w = Walker::new(&ctx, None, &options, &lane).unwrap();
        let mut slot = lane.lock_raw().unwrap();
        let root = w.push(&mut slot, b"", ScanId::NONE, None).unwrap();
        let mut frame = Frame {
            dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
            depth: 0,
            sizing: crate::boundary::Sizing::Reported,
            children: Vec::new(),
            dataless_skips: Vec::new(),
            next: 0,
        };
        w.consume_batch(&mut slot, &mut frame, root, &buf, count as u32)
            .unwrap();
        assert!(frame.children.is_empty(), "dataless must never queue");
        let child = find(&slot.arena, b"protected")[0];
        assert_ne!(child.flags & crate::arena::FLAG_DATALESS, 0);
        assert_eq!(
            frame.dataless_skips.len(),
            1,
            "precondition: metadata admission pending"
        );
        drop(slot);
        // A real bulk identity needs no further lookup. The fallback must
        // resolve the still-present directory with fstatat.
        if !fallback {
            fs::remove_dir_all(&protected).unwrap();
        }
        w.admit_children(&mut frame).unwrap();
        assert!(frame.dataless_skips.is_empty());
        let slot = lane.lock_raw().unwrap();
        assert_eq!(
            find(&slot.arena, b"protected")[0].flags & crate::arena::FLAG_SKIPPED_REQUEST != 0,
            matched
        );
        drop(slot);
        assert!(frame.children.is_empty());
        let (_, stats) = w.finish();
        assert_eq!(stats.errors, 0);
        assert_eq!(
            stats.skipped_by_request,
            if matched {
                vec![(protected, "limited scan")]
            } else {
                vec![]
            }
        );
    }
}

#[test]
fn dataless_hardlink_duplicate_does_not_double_count_logical_bytes() {
    let fx = Fixture::new().unwrap();
    fx.file("cloud", 1048576).unwrap();
    let options = opts(fx.path());
    let (mut buf, count) = single_call(fx.path(), 4096);
    assert_eq!(count, 1, "precondition: one entry");
    buf[56..60].copy_from_slice(&0x40000000u32.to_le_bytes());
    buf[72..80].copy_from_slice(&0u64.to_le_bytes());
    buf[68..72].copy_from_slice(&2u32.to_le_bytes());
    let e = crate::parse::entries(&buf, 1).next().unwrap().unwrap();
    assert_eq!(e.flags, 0x40000000);
    assert_eq!(e.obj_type, ObjType::Reg);
    let inodes = InodeSet::new(1);
    let budget = NodeBudget::new(u64::MAX);
    let halt = Halt::new();
    let progress = Progress::default();
    let lane = Lane::new(Arena::new(0, u64::MAX));
    let skips = SkipSet::resolve(&options).unwrap();
    let ctx = WalkerCtx {
        skips: &skips,
        opener: &OpenAt,
        inodes: &inodes,
        budget: &budget,
        halt: &halt,
        progress: &progress,
        root_volume: VolumeId::new(0, 0),
        root_path: fx.path(),
        root_dir: None,
    };
    let mut w = Walker::new(&ctx, None, &options, &lane).unwrap();
    let mut slot = lane.lock_raw().unwrap();
    let root = w.push(&mut slot, b"", ScanId::NONE, None).unwrap();
    let mut frame = Frame {
        dir: Dir::new(OwnedFd::from(File::open(fx.path()).unwrap()), root, &lane),
        depth: 0,
        sizing: crate::boundary::Sizing::Reported,
        children: Vec::new(),
        dataless_skips: Vec::new(),
        next: 0,
    };
    w.consume_batch(&mut slot, &mut frame, root, &buf, count as u32)
        .unwrap();
    w.consume_batch(&mut slot, &mut frame, root, &buf, count as u32)
        .unwrap();
    assert_eq!(slot.stats.hardlink_dups, 1, "precondition: duplicate inode");

    assert_eq!(slot.stats.dataless.files, 2);
    assert_eq!(slot.stats.dataless.directories, 0);
    assert_eq!(slot.stats.dataless.logical_bytes, 1048576);
    assert_eq!(
        slot.stats.unreadable.len(),
        0,
        "cloud is not permission failure"
    );
    assert_eq!(slot.stats.errors, 0);
    assert_eq!(slot.bytes, 0, "no local allocation");
    assert!(
        frame.children.is_empty(),
        "cloud directory must not be entered or published"
    );
    let node = find(&slot.arena, b"cloud")[0];
    assert_ne!(node.flags & (1 << 6), 0, "dataless flag survives parsing");
    assert_eq!(node.logical, 1048576, "logical size retained");
    drop(slot);
    drop(frame);
    let (arena, stats) = w.finish();
    let snapshot = crate::freeze::freeze(vec![arena], stats);
    assert_eq!(snapshot.nodes.len(), 3, "precondition: no hidden children");
    let frozen = snapshot
        .nodes
        .iter()
        .find(|n| n.flags & crate::arena::FLAG_DATALESS != 0)
        .unwrap();
    assert_eq!(frozen.child_count, 0);
    assert_eq!(frozen.allocated, 0);
    assert_eq!(frozen.flags & FLAG_PERM_DENIED, 0);
}

#[test]
fn dataless_root_is_admitted_without_open_in_serial_and_pool_even_if_policy_fails() {
    struct CloudRoot(bool);
    impl DirOpener for CloudRoot {
        fn no_materialize(&self) -> io::Result<()> {
            if self.0 {
                Err(io::Error::from_raw_os_error(libc::EPERM))
            } else {
                Ok(())
            }
        }
        fn root_metadata(&self, _: &Path) -> io::Result<libc::stat> {
            // SAFETY: all-zero stat fields are valid; only mode, flags and time are read.
            let mut st: libc::stat = unsafe { std::mem::zeroed() };
            st.st_mode = libc::S_IFDIR;
            st.st_flags = 0x40000000;
            st.st_mtime = 123;
            Ok(st)
        }
        fn open_dir_at(&self, _: RawFd, _: &CStr) -> Result<OwnedFd, c_int> {
            panic!("dataless root must never enumerate children")
        }
    }
    for failed in [false, true] {
        for pooled in [false, true] {
            // A missing path makes any attempt to open the root fail deterministically.
            let fx = Fixture::new().unwrap();
            let options = opts(&fx.path().join("metadata-only-root"));
            assert!(
                !options.root.exists(),
                "precondition: cannot open injected root"
            );
            let (arenas, stats) = if pooled {
                crate::pool::walk_with(
                    &options,
                    std::sync::Arc::new(CloudRoot(failed)),
                    &[],
                    &Progress::default(),
                )
                .unwrap()
            } else {
                let (arena, stats) = walk_serial_with(&options, &CloudRoot(failed)).unwrap();
                (vec![arena], stats)
            };
            let nodes: Vec<_> = arenas.iter().flat_map(|a| a.iter()).collect();
            assert_eq!(nodes.len(), 1);
            let node = nodes[0].1;
            assert_eq!(
                node.flags & (crate::arena::FLAG_DATALESS | FLAG_PERM_DENIED),
                crate::arena::FLAG_DATALESS | FLAG_PERM_DENIED
            );
            assert_eq!(node.modified, 123);
            assert_eq!((node.logical, node.allocated), (0, 0));
            assert_eq!(
                (stats.dirs, stats.files, stats.dataless.directories),
                (1, 0, 1)
            );
            assert_eq!(stats.dataless_paths, vec![options.root.clone()]);
            assert!(stats.unreadable.is_empty());
            assert_eq!(stats.errors, 0);
            assert_eq!(stats.no_materialize_failed, failed);
            assert!(stats.started_at > 0);
            assert_eq!(stats.incomplete, None);
        }
    }
}
