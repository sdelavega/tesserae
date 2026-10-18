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

use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use tempfile::TempDir;

const VOLUME_NAME: &str = "TesseraeTest";

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
        if !mountpoint.is_absolute() {
            return Err(invalid("mountpoint must be an absolute path"));
        }
        let parent = mountpoint
            .parent()
            .ok_or_else(|| invalid("mountpoint has no parent"))?;
        let dir = TempDir::new()?;
        let dmg = dir.path().join("image.dmg");

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
        run(Command::new("hdiutil")
            .args(["attach", "-nobrowse", "-noverify", "-noautoopen"])
            .arg("-mountpoint")
            .arg(mountpoint)
            .arg(&dmg))?;
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

    /// Detach now and report the outcome. Idempotent; `Drop` calls this and can
    /// only print a failure, so a test that cares should call it itself.
    pub fn detach(&mut self) -> io::Result<()> {
        if !self.mounted {
            return Ok(());
        }
        let first = run(Command::new("hdiutil").arg("detach").arg(&self.mountpoint));
        // A volume that is still busy (Spotlight, fseventsd) refuses a polite
        // detach. The image is ours and temporary, so forcing is safe.
        let result = first.or_else(|_| {
            run(Command::new("hdiutil")
                .args(["detach", "-force"])
                .arg(&self.mountpoint))
        });
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

/// Run a command, capturing its output, and turn a failure into an error that
/// carries what `hdiutil` said.
fn run(cmd: &mut Command) -> io::Result<()> {
    let out = cmd.output()?;
    if out.status.success() {
        return Ok(());
    }
    Err(io::Error::other(format!(
        "{:?} failed ({}): {}",
        cmd.get_program(),
        out.status,
        String::from_utf8_lossy(&out.stderr).trim()
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
    fn detach_is_idempotent() {
        let fx = Fixture::new().unwrap();
        fx.dir("mnt").unwrap();
        let mut image = DiskImage::attach(&fx.path().join("mnt"), 16).unwrap();
        image.detach().unwrap();
        image.detach().unwrap();
    }

    #[test]
    fn a_relative_mountpoint_is_rejected() {
        let err = DiskImage::attach(Path::new("relative/mnt"), 16).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }
}
