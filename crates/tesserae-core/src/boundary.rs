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

//! The volume boundary: the policy that keeps a scan on the volume it was
//! pointed at.
//!
//! Without it a scan of one volume wanders into every volume mounted beneath
//! it, every network share, and (scanning `/`) the firmlinked data volume,
//! counting the same bytes twice or counting bytes that are not on this disk.
//!
//! # What identifies a volume, and where it must be read
//!
//! Two measurements on macOS shape this module, and both contradict the
//! obvious design.
//!
//! **The entry's device id is the parent's.** `getattrlistbulk` reports a
//! device (`ATTR_CMN_DEVID`) for every entry, and it is tempting to compare it
//! with the root's. But the entry for a mount point, read from its parent,
//! carries the *covered* directory's device, not the mounted volume's. An
//! entry-level comparison can never see a mount boundary. The mounted volume
//! shows itself only once the directory is opened (`openat` resolves into the
//! mount) and the descriptor is asked.
//!
//! **`st_dev` does not separate the system volume from the data volume.** On a
//! stock macOS, `/` (the sealed system snapshot) and `/System/Volumes/Data`
//! report the same `st_dev`, so a walk of `/` would sail across the firmlinks
//! into the data volume. `fstatfs`'s `f_fsid` does differ, and it also carries
//! the `MNT_LOCAL` flag, so one `fstatfs` on the open descriptor answers both
//! questions. [`volume_of`] returns the first word of `f_fsid`; that is the
//! identity compared against the root's.
//!
//! So the walker opens the child, takes [`volume_of`] from the open descriptor,
//! and passes it as `entry_dev` to [`should_descend`]. Everything is read on the
//! descriptor the walker already holds, never on a path: a path would be
//! resolved a second time, costing a lookup and opening a window in which the
//! directory could be swapped between the check and the descent.
//!
//! # Policy
//!
//! | volume vs root | mount is | `include_non_local` | result                 |
//! |----------------|----------|---------------------|------------------------|
//! | same           | local    | any                 | descend                |
//! | same           | non-local| `true`              | descend                |
//! | same           | non-local| `false`             | [`SkipReason::NonLocalMount`] |
//! | different      | local    | any                 | [`SkipReason::OtherVolume`] |
//! | different      | non-local| `true`              | descend                |
//! | different      | non-local| `false`             | [`SkipReason::NonLocalMount`] |
//! | different      | unknown  | any                 | [`SkipReason::OtherVolume`] |
//!
//! `include_non_local` opts into network and other non-local mounts only. It
//! never lets a scan cross onto another *local* volume (a disk image, an
//! external drive): those are separate disks, and what is on them is not space
//! on the volume being measured. If locality cannot be determined the answer
//! fails closed.

use std::io;
use std::os::raw::c_int;

/// Why a directory was not entered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// A different local volume is mounted here.
    OtherVolume,
    /// A network or other non-local mount, and the caller did not opt in.
    NonLocalMount,
    /// The depth limit. [`should_descend`] never returns this: depth is a
    /// property of the walk's position, not of the directory, so the walker
    /// decides it and counts it in `WalkStats::depth_capped`. It is part of
    /// this enum so one type can name every reason a directory goes unentered.
    DepthCap,
}

/// Whether the filesystem `fd` lives on is a local one (`MNT_LOCAL`).
///
/// Uses `fstatfs` on the descriptor, not `statfs` on a path; see the module
/// documentation.
pub fn is_local_mount(fd: c_int) -> io::Result<bool> {
    Ok(fstatfs(fd)?.f_flags & libc::MNT_LOCAL as u32 != 0)
}

/// The volume the directory open as `fd` lives on: the first word of
/// `f_fsid` from `fstatfs`. Compare it with the root's.
///
/// Read from the open descriptor, because that is the only place a mount
/// point's own volume shows up, and from `f_fsid` rather than `st_dev` because
/// only `f_fsid` tells the sealed system volume from the data volume. See the
/// module documentation.
pub fn volume_of(fd: c_int) -> io::Result<i32> {
    let fsid = fstatfs(fd)?.f_fsid;
    // SAFETY: `fsid_t` is `struct { int32_t val[2]; }` (`<sys/mount.h>`), the
    // same size and layout as `[i32; 2]`; `transmute` checks the sizes agree at
    // compile time. The `libc` crate does not expose the field.
    let [volume, _] = unsafe { std::mem::transmute::<libc::fsid_t, [i32; 2]>(fsid) };
    Ok(volume)
}

fn fstatfs(fd: c_int) -> io::Result<libc::statfs> {
    // SAFETY: `statfs` is plain data for which all-zero is a valid value.
    let mut st: libc::statfs = unsafe { std::mem::zeroed() };
    loop {
        // SAFETY: `st` is a live, writable `statfs`.
        if unsafe { libc::fstatfs(fd, &mut st) } == 0 {
            return Ok(st);
        }
        let err = io::Error::last_os_error();
        if err.raw_os_error() != Some(libc::EINTR) {
            return Err(err);
        }
    }
}

/// Decide whether the directory open as `fd` may be entered.
///
/// `root_dev` is the scan root's volume and `entry_dev` is the volume of `fd`
/// itself, both from [`volume_of`] (not the entry's `ATTR_CMN_DEVID`, which is
/// the parent's for a mount point). See the module documentation for the policy
/// table.
pub fn should_descend(
    root_dev: i32,
    entry_dev: i32,
    fd: c_int,
    include_non_local: bool,
) -> Result<(), SkipReason> {
    decide(root_dev, entry_dev, include_non_local, || {
        is_local_mount(fd)
    })
}

/// [`should_descend`] with the locality question injected, so the whole table
/// can be exercised without needing a mount of each kind.
fn decide(
    root_dev: i32,
    entry_dev: i32,
    include_non_local: bool,
    is_local: impl FnOnce() -> io::Result<bool>,
) -> Result<(), SkipReason> {
    let same_device = root_dev == entry_dev;
    match is_local() {
        Ok(true) if same_device => Ok(()),
        Ok(true) => Err(SkipReason::OtherVolume),
        Ok(false) if include_non_local => Ok(()),
        Ok(false) => Err(SkipReason::NonLocalMount),
        // Unknown. On the same device the root's own filesystem is the one
        // being scanned, so only the opt-in decides. Off it, fail closed:
        // never cross onto an unidentified volume.
        Err(_) if same_device && include_non_local => Ok(()),
        Err(_) if same_device => Err(SkipReason::NonLocalMount),
        Err(_) => Err(SkipReason::OtherVolume),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::os::fd::AsRawFd;

    /// A real directory descriptor on the local volume the tests run on.
    fn local_dir() -> File {
        File::open(std::env::temp_dir()).expect("open the temp dir")
    }

    /// A real descriptor on a mount the kernel does not call local: the
    /// automounter's `/home` on every stock macOS. `MNT_LOCAL` cannot be faked
    /// for a real fd, and an NFS/SMB mount cannot be made without a server, so
    /// this is the one non-local descriptor a test can open. If a machine has
    /// no such mount the premise fails loudly rather than the test passing for
    /// the wrong reason.
    fn non_local_dir() -> File {
        let dir = File::open("/System/Volumes/Data/home")
            .expect("this test needs the stock autofs mount at /System/Volumes/Data/home");
        assert!(
            !is_local_mount(dir.as_raw_fd()).expect("fstatfs the autofs mount"),
            "/System/Volumes/Data/home is expected to be a non-local mount"
        );
        dir
    }

    #[test]
    fn refuses_descent_into_a_different_device() {
        assert_eq!(
            should_descend(1, 2, -1, false),
            Err(SkipReason::OtherVolume)
        );
    }

    #[test]
    fn allows_descent_within_the_same_device() {
        let dir = local_dir();
        assert!(should_descend(1, 1, dir.as_raw_fd(), false).is_ok());
    }

    #[test]
    fn a_real_local_directory_reports_local() {
        assert!(is_local_mount(local_dir().as_raw_fd()).unwrap());
    }

    #[test]
    fn a_bad_descriptor_is_an_error_not_a_verdict() {
        assert!(is_local_mount(-1).is_err());
        assert!(volume_of(-1).is_err());
    }

    #[test]
    fn volume_of_separates_the_sealed_system_volume_from_data() {
        // `/` is the sealed system snapshot and `/System/Volumes/Data` is the
        // data volume. They report the same `st_dev`, which is why `volume_of`
        // reads `f_fsid`; a walk of `/` must see the firmlinks as a crossing.
        let root = File::open("/").unwrap();
        let data = File::open("/System/Volumes/Data").unwrap();
        let users = File::open("/Users").unwrap();
        let (r, d, u) = (
            volume_of(root.as_raw_fd()).unwrap(),
            volume_of(data.as_raw_fd()).unwrap(),
            volume_of(users.as_raw_fd()).unwrap(),
        );
        assert_ne!(r, d);
        assert_eq!(d, u, "/Users is a firmlink into the data volume");
    }

    #[test]
    fn a_directory_and_its_child_share_a_volume() {
        let parent = local_dir();
        let tmp = std::env::temp_dir();
        let child = File::open(tmp.join("..")).unwrap();
        assert_eq!(
            volume_of(parent.as_raw_fd()).unwrap(),
            volume_of(child.as_raw_fd()).unwrap()
        );
    }

    #[test]
    fn the_policy_table() {
        use SkipReason::{NonLocalMount, OtherVolume};
        let local = || Ok(true);
        let remote = || Ok(false);
        let unknown = || Err(io::Error::from_raw_os_error(libc::EBADF));
        // (same device?, locality, include_non_local) -> verdict
        assert_eq!(decide(1, 1, false, local), Ok(()));
        assert_eq!(decide(1, 1, true, local), Ok(()));
        assert_eq!(decide(1, 1, false, remote), Err(NonLocalMount));
        assert_eq!(decide(1, 1, true, remote), Ok(()));
        assert_eq!(decide(1, 2, false, local), Err(OtherVolume));
        // Opting in to network mounts does not open another local volume.
        assert_eq!(decide(1, 2, true, local), Err(OtherVolume));
        assert_eq!(decide(1, 2, false, remote), Err(NonLocalMount));
        assert_eq!(decide(1, 2, true, remote), Ok(()));
        // Locality unknown: never cross onto an unidentified volume.
        assert_eq!(decide(1, 2, false, unknown), Err(OtherVolume));
        assert_eq!(decide(1, 2, true, unknown), Err(OtherVolume));
        assert_eq!(decide(1, 1, false, unknown), Err(NonLocalMount));
        assert_eq!(decide(1, 1, true, unknown), Ok(()));
    }

    #[test]
    fn refuses_non_local_mount_unless_opted_in() {
        let dir = non_local_dir();
        let fd = dir.as_raw_fd();
        assert_eq!(
            should_descend(1, 1, fd, false),
            Err(SkipReason::NonLocalMount)
        );
        assert!(should_descend(1, 1, fd, true).is_ok());
    }
}
