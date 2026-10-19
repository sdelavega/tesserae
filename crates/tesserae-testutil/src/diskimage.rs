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

//! A real mounted volume, for tests that must cross a device boundary.
//!
//! The only way to prove a scanner stops at a volume boundary is to give it
//! one: a second filesystem mounted inside the tree being walked. A disk image
//! attached with `hdiutil` is the one such thing an unprivileged user can make.
//!
//! A mounted image is a side effect on the machine running the tests, not just
//! on the test process, so [`DiskImage`] detaches in `Drop`. `Drop` runs when a
//! test panics, which is the case that matters: a failing assertion must not
//! leave a volume mounted. It cannot run if the process is killed outright
//! (SIGKILL, a power cut); `hdiutil info` shows what is left and
//! `hdiutil detach -force <mountpoint>` clears it.

use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use tempfile::TempDir;

const VOLUME_NAME: &str = "TesseraeTest";

/// Longest any single `hdiutil` call may take. A create or attach of a 16 MiB
/// image takes about a second; a call that outlives this is hung, and
/// `attach` holds the allocation lock across it, so a hang would stall every
/// dense write in the test binary and look like a suite hang rather than a
/// failure.
const HDIUTIL_TIMEOUT: Duration = Duration::from_secs(60);

/// A disk image attached at a chosen mountpoint, detached when dropped.
///
/// Declare it *after* the [`crate::Fixture`] whose directory holds the
/// mountpoint: locals drop in reverse order, so the volume is unmounted before
/// the fixture removes its tree. Otherwise the fixture's cleanup would walk
/// into the mounted image.
#[derive(Debug)]
pub struct DiskImage {
    mountpoint: PathBuf,
    /// Where the `.dmg` lives. Dropped after the detach in [`Drop::drop`].
    _dir: TempDir,
    mounted: bool,
}

impl DiskImage {
    /// Create a `size_mib` MiB APFS image and attach it, hidden from Finder
    /// (`-nobrowse`), at `mountpoint`.
    ///
    /// `mountpoint` must be an existing, absolute directory. On success the
    /// mountpoint is verified to be on a different device from its parent, so
    /// a call that returns `Ok` really did mount a separate filesystem.
    pub fn attach(mountpoint: &Path, size_mib: u32) -> io::Result<Self> {
        Self::attach_using(mountpoint, size_mib, |dmg| hdiutil_attach(mountpoint, dmg))
    }

    /// [`DiskImage::attach`] with the attach step supplied, so a test can make
    /// it fail after the kernel has already mounted the image.
    fn attach_using(
        mountpoint: &Path,
        size_mib: u32,
        attach: impl FnOnce(&Path) -> io::Result<()>,
    ) -> io::Result<Self> {
        if !mountpoint.is_absolute() {
            return Err(invalid("mountpoint must be an absolute path"));
        }
        let parent = mountpoint
            .parent()
            .ok_or_else(|| invalid("mountpoint has no parent"))?;
        let dir = TempDir::new()?;
        let dmg = dir.path().join("image.dmg");
        // Creating the image writes `size_mib` MiB; keep that out of any
        // free-space measurement running in another test. See `allocation_lock`.
        let _alloc = crate::allocation_lock();
        crate::assert_allocation_lock_held();

        run(Command::new("hdiutil")
            .args(["create", "-size", &format!("{size_mib}m")])
            .args(["-fs", "APFS", "-volname", VOLUME_NAME])
            .arg(&dmg))?;
        // `mounted` stays false until `hdiutil attach` succeeds, so a failed
        // attach is not followed by a detach of something that is not there.
        let mut image = DiskImage {
            mountpoint: mountpoint.to_path_buf(),
            _dir: dir,
            mounted: false,
        };
        if let Err(e) = attach(&dmg) {
            // A failure is not proof that nothing was mounted: the timeout
            // kills `hdiutil`, not the kernel's attach, which may already have
            // landed. A volume at the mountpoint is ours, so take it down.
            reclaim(mountpoint, parent);
            return Err(e);
        }
        image.mounted = true;

        let (inside, outside) = (
            std::fs::metadata(mountpoint)?.dev(),
            std::fs::metadata(parent)?.dev(),
        );
        if inside == outside {
            // `image` drops here and detaches.
            return Err(io::Error::other(format!(
                "hdiutil attached the image but {} is on the same device as its parent",
                mountpoint.display()
            )));
        }
        Ok(image)
    }

    pub fn mountpoint(&self) -> &Path {
        &self.mountpoint
    }

    /// Bytes available on the image's own volume. The image is its own APFS
    /// container, so this moves only with writes to the image; hold
    /// [`crate::allocation_lock`] across a measurement all the same, since
    /// creating another image allocates in a shared place and a measuring test
    /// should not have to argue about which allocations reach it.
    pub fn free_bytes(&self) -> io::Result<u64> {
        crate::free_bytes(&self.mountpoint)
    }

    /// Detach now and report the outcome. Idempotent; `Drop` calls this and can
    /// only print a failure, so a test that cares should call it itself.
    pub fn detach(&mut self) -> io::Result<()> {
        if !self.mounted {
            return Ok(());
        }
        let first = run(Command::new("hdiutil").arg("detach").arg(&self.mountpoint));
        // A volume that is still busy (Spotlight, fseventsd) refuses a polite
        // detach. The image is ours and temporary, so forcing is safe.
        match first {
            Ok(()) => {
                self.mounted = false;
                Ok(())
            }
            Err(_) => self.force_detach(),
        }
    }

    /// Detach at once, without waiting for open files to close, as a pulled
    /// cable would: a process still reading the volume has its descriptors
    /// invalidated underneath it. This is how a test takes a volume away in
    /// the middle of a scan. Idempotent.
    pub fn force_detach(&mut self) -> io::Result<()> {
        if !self.mounted {
            return Ok(());
        }
        let result = run(Command::new("hdiutil")
            .args(["detach", "-force"])
            .arg(&self.mountpoint));
        if result.is_ok() {
            self.mounted = false;
        }
        result
    }
}

impl Drop for DiskImage {
    fn drop(&mut self) {
        // Never panic here: a panic during unwinding aborts the process.
        if let Err(e) = self.detach() {
            eprintln!(
                "WARNING: could not detach the test disk image at {}: {e}\n\
                 Clear it with: hdiutil detach -force '{}'",
                self.mountpoint.display(),
                self.mountpoint.display()
            );
        }
    }
}

/// Best effort, after a failed attach: force-detach whatever is mounted at
/// `mountpoint`, which is something only when it is on a different device from
/// its parent. Errors are ignored; the attach error is the one reported.
fn reclaim(mountpoint: &Path, parent: &Path) {
    let dev = |p: &Path| std::fs::metadata(p).map(|m| m.dev());
    if let (Ok(inside), Ok(outside)) = (dev(mountpoint), dev(parent)) {
        if inside != outside {
            let _ = run(Command::new("hdiutil")
                .args(["detach", "-force"])
                .arg(mountpoint));
        }
    }
}

/// Attach `dmg` at `mountpoint`, hidden from Finder.
fn hdiutil_attach(mountpoint: &Path, dmg: &Path) -> io::Result<()> {
    run(Command::new("hdiutil")
        .args(["attach", "-nobrowse", "-noverify", "-noautoopen"])
        .arg("-mountpoint")
        .arg(mountpoint)
        .arg(dmg))
}

/// Run `hdiutil` (or anything) with the standard time limit.
fn run(cmd: &mut Command) -> io::Result<()> {
    run_with_timeout(cmd, HDIUTIL_TIMEOUT)
}

/// Run a command, capturing its output, and turn a failure into an error that
/// carries what it said. A command still running after `timeout` is killed and
/// reported as [`io::ErrorKind::TimedOut`].
fn run_with_timeout(cmd: &mut Command, timeout: Duration) -> io::Result<()> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    // Drain both pipes on threads so a chatty child cannot block on a full
    // pipe while this thread waits on it.
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        })
    };
    let _stdout = drain(child.stdout.take().map(|p| Box::new(p) as _));
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as _));

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            // The drain threads are left to finish on their own: a helper
            // process that inherited the pipes could keep them open.
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "{:?} did not finish within {timeout:?} and was killed",
                    cmd.get_program()
                ),
            ));
        }
        thread::sleep(Duration::from_millis(20));
    };
    if status.success() {
        return Ok(());
    }
    let stderr = stderr.join().unwrap_or_default();
    Err(io::Error::other(format!(
        "{:?} failed ({status}): {}",
        cmd.get_program(),
        String::from_utf8_lossy(&stderr).trim()
    )))
}

fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Fixture;
    use std::panic::{catch_unwind, AssertUnwindSafe};

    /// Whether `mount(8)` lists a filesystem at `mountpoint`. It prints the
    /// canonical path (`/private/var/...`, not the `/var/...` a temp dir is
    /// named by), so the path is canonicalised first.
    fn is_mounted(mountpoint: &Path) -> bool {
        let canonical = std::fs::canonicalize(mountpoint).unwrap();
        let out = Command::new("mount").output().unwrap();
        String::from_utf8_lossy(&out.stdout).contains(&format!(" on {} (", canonical.display()))
    }

    #[test]
    fn attach_mounts_a_separate_volume_and_drop_detaches_it() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let image = DiskImage::attach(&mnt, 16).unwrap();
        assert!(is_mounted(&mnt));
        std::fs::write(mnt.join("f"), b"x").unwrap();

        drop(image);

        assert!(!is_mounted(&mnt));
        assert!(!mnt.join("f").exists(), "the image's contents are gone");
    }

    #[test]
    fn a_panic_while_attached_still_detaches() {
        // The case the `Drop` guard exists for: a failing assertion in a test
        // must not leave a volume mounted on the machine.
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");

        let result = catch_unwind(AssertUnwindSafe(|| {
            let _image = DiskImage::attach(&mnt, 16).unwrap();
            assert!(is_mounted(&mnt), "precondition: it really was mounted");
            panic!("deliberate, to unwind with the image attached");
        }));

        // It must be *our* panic: a failed precondition inside the closure
        // would also be `Err` and would make this test pass for nothing.
        let payload = result.unwrap_err();
        assert_eq!(
            payload.downcast_ref::<&str>().copied(),
            Some("deliberate, to unwind with the image attached")
        );
        assert!(!is_mounted(&mnt), "the guard must detach on unwind");
    }

    #[test]
    fn a_hung_command_is_killed_and_reported_not_waited_for() {
        let started = Instant::now();
        let err = run_with_timeout(Command::new("sleep").arg("30"), Duration::from_millis(200))
            .unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn a_failing_command_reports_what_it_said() {
        let err = run_with_timeout(
            Command::new("sh").args(["-c", "echo boom >&2; exit 3"]),
            Duration::from_secs(10),
        )
        .unwrap_err();
        assert!(err.to_string().contains("boom"), "{err}");
    }

    #[test]
    fn an_attach_that_fails_after_mounting_detaches_what_it_mounted() {
        // `hdiutil attach` killed by the timeout after the kernel attached is
        // the case: the command reports failure, yet a volume is mounted and
        // `mounted` was never set. Simulated deterministically by attaching
        // for real and then reporting a timeout.
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let mut attached = false;

        let err = DiskImage::attach_using(&mnt, 16, |dmg| {
            hdiutil_attach(&mnt, dmg)?;
            attached = is_mounted(&mnt);
            Err(io::Error::new(io::ErrorKind::TimedOut, "simulated kill"))
        })
        .unwrap_err();

        assert!(attached, "precondition: the image really was mounted");
        assert_eq!(
            err.kind(),
            io::ErrorKind::TimedOut,
            "the attach error is kept"
        );
        let leaked = is_mounted(&mnt);
        if leaked {
            // Never leave the machine with a volume attached, even on failure.
            let _ = run(Command::new("hdiutil").args(["detach", "-force"]).arg(&mnt));
        }
        assert!(!leaked, "a failed attach left the image mounted");
    }

    #[test]
    fn detach_is_idempotent() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mut image = DiskImage::attach(&fx.path().join("mnt"), 16).unwrap();
        image.detach().unwrap();
        image.detach().unwrap();
    }

    #[test]
    fn free_bytes_falls_by_what_is_written_and_a_copy_is_not_a_clone() {
        // The image has its own APFS container, so its free space moves only
        // when something is written to it.
        const LEN: u64 = 1 << 20;
        const SLACK: u64 = 64 * 1024;
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let image = DiskImage::attach(&mnt, 16).unwrap();

        let _quiet = crate::allocation_lock();
        let before = image.free_bytes().unwrap();
        crate::write_dense_file(&mnt.join("a"), LEN).unwrap();
        let written = before - image.free_bytes().unwrap();
        // The data blocks plus or minus a few blocks of metadata: measured
        // +1 block for a first file and -1 for a second, as the image's
        // metadata is allocated and reclaimed.
        let near = LEN - SLACK..=LEN + SLACK;
        assert!(near.contains(&written), "{written}");

        let before_copy = image.free_bytes().unwrap();
        crate::copy_by_read_write(&mnt.join("a"), &mnt.join("b")).unwrap();
        let copied = before_copy - image.free_bytes().unwrap();
        assert!(near.contains(&copied), "{copied}");
        assert_eq!(
            std::fs::read(mnt.join("a")).unwrap(),
            std::fs::read(mnt.join("b")).unwrap()
        );

        // The contrast that gives the number meaning: a clone adds nothing.
        let before_clone = image.free_bytes().unwrap();
        fx.clone_of("mnt/a", "mnt/c").unwrap();
        let cloned = before_clone - image.free_bytes().unwrap();
        assert!(cloned < SLACK, "{cloned}");
    }

    #[test]
    fn force_detach_unmounts_at_once_and_is_idempotent() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mnt = fx.path().join("mnt");
        let mut image = DiskImage::attach(&mnt, 16).unwrap();
        // A file held open makes a polite detach refuse; force does not.
        let held = std::fs::File::create(mnt.join("held")).unwrap();
        assert!(is_mounted(&mnt));

        image.force_detach().unwrap();

        assert!(!is_mounted(&mnt));
        image.force_detach().unwrap();
        drop(held);
    }

    #[test]
    fn a_relative_mountpoint_is_rejected() {
        let err = DiskImage::attach(Path::new("relative/mnt"), 16).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }
}
