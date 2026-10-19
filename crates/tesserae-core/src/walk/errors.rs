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

//! How a walk reports what went wrong: the [`Incomplete`] reasons and their
//! precedence, the errno classification in `Walker::note_error`, and the
//! OS-error-preserving context wrapper behind [`os_errno`].

use std::io;
use std::os::fd::AsRawFd;
use std::os::raw::c_int;

use super::{DirOpener, Walker};
#[cfg(doc)]
use super::{Halt, WalkStats};
use crate::arena::{ArenaError, ScanId, FLAG_PERM_DENIED};
use crate::boundary::volume_of;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Incomplete {
    Cancelled,
    NodeBudget,
    OutOfMemory,
    Stalled,
    /// `openat` failed with `EMFILE` or `ENFILE`: the walk ran out of file
    /// descriptors. Unlike the races counted in [`WalkStats::errors`], this
    /// means the result is systematically short, so it is reported here. The
    /// directory that could not be opened is skipped and the walk carries on
    /// (popping frames frees descriptors), but every subtree skipped this way
    /// is missing from the totals.
    FdExhausted,
    /// The parser rejected a `getattrlistbulk` batch, so the entries after the
    /// bad one were never read. [`WalkStats::lost_entries`] says how many.
    MalformedBatch,
    /// The volume being scanned went away mid-walk (a disk image detached, a
    /// drive pulled): the root's descriptor no longer answers `fstatfs`, or
    /// answers with another volume's identity. Terminal: every other directory
    /// the walk had yet to read is gone too, so the walk stops where it is and
    /// the tree is whatever was read before. Raised only after a directory
    /// failed with an errno that can mean "the volume is gone" (`ENOENT`,
    /// `ENOTDIR`, `EIO`, `ENXIO`, `ENODEV`, `EBADF`, `ENOTSUP`) *and* a fresh
    /// `fstatfs` of the root says it is; the same errnos on a live volume stay
    /// ordinary churn in [`WalkStats::errors`].
    VolumeLost,
}

impl From<ArenaError> for Incomplete {
    fn from(e: ArenaError) -> Self {
        match e {
            ArenaError::NodeBudgetExceeded => Incomplete::NodeBudget,
            ArenaError::OutOfMemory => Incomplete::OutOfMemory,
        }
    }
}

impl Incomplete {
    /// A nonzero code for [`Halt`]. The match is exhaustive, so a new variant
    /// is a compile error here rather than a reason that silently stops
    /// travelling between workers.
    pub(super) fn code(self) -> u8 {
        match self {
            Incomplete::Cancelled => 1,
            Incomplete::NodeBudget => 2,
            Incomplete::OutOfMemory => 3,
            Incomplete::Stalled => 4,
            Incomplete::FdExhausted => 5,
            Incomplete::MalformedBatch => 6,
            Incomplete::VolumeLost => 7,
        }
    }

    pub(super) fn from_code(code: u8) -> Option<Incomplete> {
        [
            Incomplete::Cancelled,
            Incomplete::NodeBudget,
            Incomplete::OutOfMemory,
            Incomplete::Stalled,
            Incomplete::FdExhausted,
            Incomplete::MalformedBatch,
            Incomplete::VolumeLost,
        ]
        .into_iter()
        .find(|i| i.code() == code)
    }

    /// How strongly this reason describes what *stopped* the walk.
    ///
    /// [`Incomplete::FdExhausted`] and [`Incomplete::MalformedBatch`] are
    /// noticed and walked past, so a reason that ended the walk outranks them.
    /// This is the precedence a serial walk already has — a terminal reason
    /// overwrites whatever the walk had flagged — expressed so that merging
    /// several workers' stats can follow it too.
    pub(crate) fn rank(self) -> u8 {
        match self {
            Incomplete::FdExhausted | Incomplete::MalformedBatch => 1,
            Incomplete::Cancelled
            | Incomplete::NodeBudget
            | Incomplete::OutOfMemory
            | Incomplete::Stalled
            | Incomplete::VolumeLost => 2,
        }
    }
}

/// An error with a message naming what was being done, wrapped around the OS
/// error that caused it.
///
/// `io::Error::new(kind, msg)` would discard the OS error number, and the
/// number matters: `ErrorKind::PermissionDenied` is both `EACCES` (an ordinary
/// permission) and `EPERM` (on macOS, the privacy layer refusing access to a
/// protected folder), and which one it was decides whether asking the user for
/// Full Disk Access could help. So the original error stays reachable as the
/// source, and [`os_errno`] reads the number back through it. The alternative,
/// returning the original error unwrapped, would have lost the path from the
/// message.
#[derive(Debug)]
struct Context {
    msg: String,
    source: io::Error,
}

impl std::fmt::Display for Context {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.msg, self.source)
    }
}

impl std::error::Error for Context {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

/// `err` with `msg` in front, keeping its kind and its OS error number. Public
/// so that a test elsewhere can build the error this crate builds.
pub fn with_context(err: io::Error, msg: String) -> io::Error {
    io::Error::new(err.kind(), Context { msg, source: err })
}

/// The OS error number behind `err`, if there is one: its own, or that of the
/// error [`with_context`] wrapped. Every error this crate returns for a failed
/// system call keeps its number recoverable this way.
pub fn os_errno(err: &io::Error) -> Option<i32> {
    err.raw_os_error().or_else(|| {
        err.get_ref()
            .and_then(|inner| inner.downcast_ref::<Context>())
            .and_then(|c| c.source.raw_os_error())
    })
}

impl<'a, O: DirOpener> Walker<'a, O> {
    /// Account for a failure on directory `id`.
    pub(super) fn note_error(&mut self, id: ScanId, errno: c_int) -> Result<(), Incomplete> {
        // Asked before the slot is locked: it is a syscall, and none may be
        // made under the lock. Only the errnos a vanished volume can produce
        // pay for it, and only the `_` arm below can act on the answer.
        let lost = may_mean_volume_gone(errno) && self.volume_lost(id);
        let mut slot = self.lock()?;
        match errno {
            libc::EPERM | libc::EACCES => {
                let path = self.report_path_of(&slot, id)?;
                slot.stats
                    .unreadable
                    .try_reserve(1)
                    .map_err(|_| Incomplete::OutOfMemory)?;
                slot.stats.unreadable.push(path);
                // The path list is for the report; the flag is what lets the
                // node itself render as locked instead of as an empty folder.
                if let Some(node) = slot.arena.get_mut(id) {
                    node.flags |= FLAG_PERM_DENIED;
                } else if let Some(share) = self.share {
                    // A stolen directory: its node belongs to the worker that
                    // enumerated the parent, so the flag is recorded and
                    // applied once the workers have finished. If even that one
                    // slot cannot be had, the node will render as an empty
                    // folder rather than a locked one, and the result says so.
                    if !share.flag_foreign(id, FLAG_PERM_DENIED) {
                        slot.stats.incomplete.get_or_insert(Incomplete::OutOfMemory);
                    }
                }
            }
            libc::ENOMEM => {
                // The kernel, not this process's arena, ran out of memory: a
                // shortfall, so flagged like descriptor exhaustion.
                slot.stats.incomplete.get_or_insert(Incomplete::OutOfMemory);
            }
            libc::EMFILE | libc::ENFILE => {
                // Not counted in `errors`: that field holds benign races, and
                // this one makes the totals wrong. The first reason wins; a
                // later terminal reason still overwrites it in `walk_serial_with`.
                slot.stats.incomplete.get_or_insert(Incomplete::FdExhausted);
            }
            _ => slot.stats.errors += 1,
        }
        self.publish(&mut slot);
        if lost {
            // Terminal: `guard` records it and raises the shared halt, so every
            // other worker stops at its next directory or batch.
            return Err(Incomplete::VolumeLost);
        }
        Ok(())
    }

    /// Whether the volume the scan began on is gone: the root's descriptor no
    /// longer answers `fstatfs`, or names a different volume. A walk with no
    /// root descriptor to ask (some unit tests) can never tell, so says no.
    fn volume_lost(&self, on: ScanId) -> bool {
        let Some(root) = self.root_dir else {
            return false;
        };
        match self.lane.during(on, || volume_of(root.as_raw_fd())) {
            Ok(volume) => volume != self.root_volume,
            Err(_) => true,
        }
    }
}

/// Whether a failed directory operation with this errno may be the volume
/// going away rather than something wrong with the one directory: the churn
/// class (`ENOENT`, `ENOTDIR`) and the I/O class (`EIO`, `ENXIO`, `ENODEV`,
/// `EBADF`), plus `ENOTSUP`, which is what `fstatfs` says on a detached image.
fn may_mean_volume_gone(errno: c_int) -> bool {
    matches!(
        errno,
        libc::ENOENT
            | libc::ENOTDIR
            | libc::EIO
            | libc::ENXIO
            | libc::ENODEV
            | libc::EBADF
            | libc::ENOTSUP
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walk::tests::opts;
    use crate::walk::{walk_serial, walk_serial_with, Incomplete, OpenAt};
    use std::ffi::CStr;
    use std::fs::{self, File};
    use std::os::fd::{OwnedFd, RawFd};
    use std::sync::atomic::{AtomicBool, Ordering};
    use tesserae_testutil::{DiskImage, Fixture};

    /// Fails the open of the directory `victim` with a fixed errno.
    struct FailOpen(c_int);

    impl DirOpener for FailOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return Err(self.0);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn descriptor_exhaustion_is_reported_as_incomplete_not_as_an_error() {
        for errno in [libc::EMFILE, libc::ENFILE] {
            let fx = Fixture::new().unwrap();
            fx.file("victim/inner.bin", 4096).unwrap();
            fx.file("other/f.bin", 4096).unwrap();

            let (_, stats) = walk_serial_with(&opts(fx.path()), &FailOpen(errno)).unwrap();

            assert_eq!(
                stats.incomplete,
                Some(Incomplete::FdExhausted),
                "errno {errno}"
            );
            assert_eq!(stats.errors, 0, "not a benign race (errno {errno})");
            assert!(stats.unreadable.is_empty());
            assert_eq!(stats.files, 1, "the walk went on to other/f.bin");
        }
    }

    /// Fails the first directory it is asked to open with `EMFILE`, whichever
    /// that is, and opens every later one for real.
    struct FailFirstOpen {
        failed: AtomicBool,
    }

    impl DirOpener for FailFirstOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if !self.failed.swap(true, Ordering::Relaxed) {
                return Err(libc::EMFILE);
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn a_terminal_reason_overrides_an_earlier_fd_exhaustion() {
        // Two directories with five files each. Whichever is opened first
        // fails with EMFILE; the other is entered, and the budget (the root,
        // both directories and two files) runs out inside it. The field must
        // name what stopped the walk, not the earlier skip.
        let fx = Fixture::new().unwrap();
        for i in 0..5 {
            fx.file(&format!("a/f{i}.bin"), 1).unwrap();
            fx.file(&format!("b/f{i}.bin"), 1).unwrap();
        }
        let mut o = opts(fx.path());
        o.node_budget = 5;
        let opener = FailFirstOpen {
            failed: AtomicBool::new(false),
        };

        let (arena, stats) = walk_serial_with(&o, &opener).unwrap();

        assert!(
            opener.failed.load(Ordering::Relaxed),
            "the EMFILE must actually have fired"
        );
        assert_eq!(arena.len(), 5);
        assert_eq!(stats.incomplete, Some(Incomplete::NodeBudget));
    }

    #[test]
    fn kernel_out_of_memory_is_flagged_not_counted() {
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();

        let (_, stats) = walk_serial_with(&opts(fx.path()), &FailOpen(libc::ENOMEM)).unwrap();

        assert_eq!(stats.incomplete, Some(Incomplete::OutOfMemory));
        assert_eq!(stats.errors, 0);
        assert_eq!(stats.files, 1, "the walk went on to other/f.bin");
    }

    /// Every errno a vanished volume can produce, on a volume that is fine:
    /// the directory is counted as churn and the walk goes on. This is the
    /// half of the volume-lost rule that keeps ordinary churn ordinary.
    #[test]
    fn volume_gone_errnos_on_a_live_volume_are_churn_not_loss() {
        for errno in [
            libc::ENOENT,
            libc::ENOTDIR,
            libc::EIO,
            libc::ENXIO,
            libc::ENODEV,
            libc::EBADF,
            libc::ENOTSUP,
        ] {
            assert!(may_mean_volume_gone(errno), "errno {errno}");
            let fx = Fixture::new().unwrap();
            fx.file("victim/inner.bin", 4096).unwrap();
            fx.file("other/f.bin", 4096).unwrap();

            let (_, stats) = walk_serial_with(&opts(fx.path()), &FailOpen(errno)).unwrap();

            assert_eq!(stats.incomplete, None, "errno {errno}");
            assert_eq!(stats.errors, 1, "errno {errno}");
            assert_eq!(
                stats.files, 1,
                "errno {errno}: the walk went on to other/f.bin"
            );
        }
    }

    /// Detaches its image the first time a directory below the root is
    /// opened, then opens for real, so that open meets a volume that is gone:
    /// the same `ENOTDIR` a detach under a real walk produces, with no race
    /// about when.
    struct DetachOnFirstOpen {
        image: std::sync::Mutex<DiskImage>,
        fired: AtomicBool,
    }

    impl DetachOnFirstOpen {
        fn new(image: DiskImage) -> Self {
            DetachOnFirstOpen {
                image: std::sync::Mutex::new(image),
                fired: AtomicBool::new(false),
            }
        }
    }

    impl DirOpener for DetachOnFirstOpen {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if !self.fired.swap(true, Ordering::SeqCst) {
                self.image.lock().unwrap().force_detach().unwrap();
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn a_volume_lost_mid_walk_stops_the_walk_as_volume_lost() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let image = DiskImage::attach(&mnt, 16).unwrap();
        for d in 0..4 {
            fs::create_dir(mnt.join(format!("d{d}"))).unwrap();
            File::create(mnt.join(format!("d{d}/f"))).unwrap();
        }
        // Precondition: undisturbed, the same walk sees everything and is
        // complete, so what follows is the detach and nothing else.
        let (_, whole) = walk_serial(&opts(&mnt)).unwrap();
        assert_eq!((whole.dirs, whole.files, whole.errors), (5, 4, 0));
        assert_eq!(whole.incomplete, None);

        let opener = DetachOnFirstOpen::new(image);
        let (_, stats) = walk_serial_with(&opts(&mnt), &opener).unwrap();

        assert!(opener.fired.load(Ordering::SeqCst), "the detach never ran");
        assert_eq!(stats.incomplete, Some(Incomplete::VolumeLost));
        assert!(stats.errors >= 1, "the failing directory is still counted");
        assert!(
            stats.files < 4,
            "{} files from a detached volume",
            stats.files
        );
    }

    /// Hands back a regular file's descriptor for the directory `victim`, so
    /// the open succeeds and `getattrlistbulk` is what fails (`ENOTDIR`).
    struct FileForDir(std::path::PathBuf);

    impl DirOpener for FileForDir {
        fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
            if name.to_bytes() == b"victim" {
                return Ok(OwnedFd::from(File::open(&self.0).unwrap()));
            }
            OpenAt.open_dir_at(parent, name)
        }
    }

    #[test]
    fn an_enumeration_failure_is_absorbed_and_the_walk_continues() {
        // The `getattrlistbulk` error branch. `chmod 0o111` cannot reach it:
        // `open(O_RDONLY)` on a directory needs read permission, so that fails
        // at `openat` (EACCES) before enumeration. A descriptor that opens
        // fine but is not a directory fails in the syscall itself.
        let fx = Fixture::new().unwrap();
        fx.file("victim/inner.bin", 4096).unwrap();
        fx.file("other/f.bin", 4096).unwrap();
        fx.file("plain.bin", 1).unwrap();
        let opener = FileForDir(fx.path().join("plain.bin"));

        let (_, stats) = walk_serial_with(&opts(fx.path()), &opener).unwrap();

        assert_eq!(stats.errors, 1, "ENOTDIR from getattrlistbulk");
        assert_eq!(stats.incomplete, None);
        assert!(stats.unreadable.is_empty());
        assert_eq!(stats.files, 2, "other/f.bin and plain.bin");
    }

    #[test]
    fn context_keeps_the_os_error_and_not_only_its_kind() {
        let wrapped = with_context(io::Error::from_raw_os_error(libc::EPERM), "open /x".into());
        assert_eq!(wrapped.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(os_errno(&wrapped), Some(libc::EPERM));
        assert_ne!(os_errno(&wrapped), Some(libc::EACCES));
        assert!(wrapped.to_string().starts_with("open /x: "), "{wrapped}");
        // An unwrapped OS error reports its own number; one with none, none.
        assert_eq!(
            os_errno(&io::Error::from_raw_os_error(libc::EBUSY)),
            Some(libc::EBUSY)
        );
        assert_eq!(
            os_errno(&io::Error::new(io::ErrorKind::InvalidInput, "no errno")),
            None
        );
    }
}
