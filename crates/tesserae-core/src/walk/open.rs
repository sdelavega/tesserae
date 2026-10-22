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

//! Opening directories: the scan root by path, every other directory
//! relative to a descriptor, and the seam ([`DirOpener`]) tests use to reach
//! the window between enumerating a directory and opening it.

use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::os::raw::c_int;
use std::os::unix::ffi::OsStrExt;

#[cfg(doc)]
use super::WalkStats;
use super::{with_context, WalkOptions, MAX_PATH_BYTES};
use crate::boundary::retry_eintr;

/// How the walker opens a child directory. The one seam in the descent path.
///
/// Production uses [`OpenAt`]. Tests substitute an opener that mutates the
/// tree immediately before delegating to the real one, which is the only
/// deterministic way to reach the window between a directory being enumerated
/// and being opened.
///
/// `Sync` is a supertrait so that one opener can be handed to every worker of
/// the parallel walk. That is the whole reason this is a trait rather than a
/// `cfg(test)` thread-local: a thread-local seam would be invisible to the
/// worker threads.
pub(crate) trait DirOpener: Sync {
    /// Set thread-scoped metadata policy before any scan syscall.
    fn no_materialize(&self) -> io::Result<()> {
        crate::dataless::no_materialize()
    }

    /// Metadata-only admission of the selected root, following caller-named aliases.
    fn root_metadata(&self, path: &std::path::Path) -> io::Result<libc::stat> {
        with_cstr(path.as_os_str().as_bytes(), |c| {
            super::skip::metadata_at(libc::AT_FDCWD, c, 0)
                .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO))
        })
        .map_err(io::Error::from_raw_os_error)
    }

    fn is_volume_root(&self, fd: RawFd) -> io::Result<bool> {
        crate::boundary::is_volume_root(fd)
    }

    /// Open the directory `name`, a single entry name, relative to the
    /// directory open as `parent`. Returns the errno on failure.
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int>;

    /// Reopen a directory the parallel walker published: `rel` is a path of
    /// one or more components relative to `root`, the scan root's descriptor.
    ///
    /// The default is [`open_beneath`], which refuses a symlink in *any*
    /// component. A test opener that intercepts only [`open_dir_at`] gets the
    /// real reopen; one that wants to reach this window overrides this too.
    ///
    /// [`open_dir_at`]: DirOpener::open_dir_at
    fn reopen_dir_beneath(&self, root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
        open_beneath(root, rel)
    }
}

/// Flags for every directory the walk opens below the root.
const DIR_FLAGS: c_int = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;

/// `openat(2)` with `EINTR` retried and the descriptor owned.
fn openat_retrying(parent: RawFd, name: &CStr, flags: c_int) -> Result<OwnedFd, c_int> {
    retry_eintr(|| {
        // SAFETY: `name` is a live NUL-terminated string.
        let fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
        if fd >= 0 {
            // SAFETY: `openat` just returned this descriptor and nothing else
            // owns it.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        } else {
            Err(io::Error::last_os_error())
        }
    })
    .map_err(|err| err.raw_os_error().unwrap_or(libc::EIO))
}

/// Open the directory at `rel` beneath `root` without following a symlink in
/// any component of `rel`.
///
/// # The guarantee, as measured
///
/// `O_NOFOLLOW` covers only the final component, so a reopen by path with it
/// alone could be redirected by an ancestor swapped for a symlink between
/// enumeration and reopen — exactly the race the serial walker's
/// descriptor-relative descent exists to close. `O_NOFOLLOW_ANY` (macOS 11+;
/// the deployment target is 13.0) refuses a symlink anywhere in `rel`.
/// Probed on this machine (macOS 27.2), relative to a directory descriptor:
///
/// * no symlink in `rel`: opens;
/// * an intermediate component is a symlink, including an ancestor swapped
///   for one after the root was opened: fails with `ELOOP` where plain
///   `O_NOFOLLOW` follows it and opens the redirect target;
/// * the final component is a symlink: `ELOOP` (plain `O_NOFOLLOW` with
///   `O_DIRECTORY` gives `ENOTDIR`);
/// * symlinks in the path that was used to open `root` itself (fixtures live
///   under `/var`, a symlink to `private/var`) do not matter: `root` is a
///   descriptor, so nothing above it is resolved again;
/// * `..` is still permitted. `rel` is built only from names the kernel
///   returned for directory entries, which are never `.`, `..` or contain a
///   `/`, so it cannot climb out of the root.
///
/// Either errno lands in [`WalkStats::errors`], as every other open failure
/// that is neither a denial nor a resource shortfall does: the directory is
/// recorded but not entered.
pub(crate) fn open_beneath(root: RawFd, rel: &CStr) -> Result<OwnedFd, c_int> {
    openat_retrying(root, rel, DIR_FLAGS | libc::O_NOFOLLOW_ANY)
}

/// The real thing: `openat(2)` that refuses to follow a symlink and refuses
/// anything that is not a directory.
pub(crate) struct OpenAt;

impl DirOpener for OpenAt {
    fn open_dir_at(&self, parent: RawFd, name: &CStr) -> Result<OwnedFd, c_int> {
        openat_retrying(parent, name, DIR_FLAGS | libc::O_NOFOLLOW)
    }
}

pub(super) fn errno() -> c_int {
    io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(libc::EIO)
}

/// Open the root by path. Unlike every other directory this one may be reached
/// through a symlink: the caller named it, so resolving it is what they meant.
pub(crate) fn open_root(opts: &WalkOptions) -> io::Result<OwnedFd> {
    let path = CString::new(opts.root.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "root path contains NUL"))?;
    retry_eintr(|| {
        // SAFETY: `path` is a live NUL-terminated string.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd >= 0 {
            // SAFETY: `open` just returned this descriptor.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        } else {
            Err(io::Error::last_os_error())
        }
    })
    .map_err(|err| with_context(err, format!("open {}", opts.root.display())))
}

/// `bytes`, NUL-terminated in `z`.
///
/// A heap-allocated `CString` per directory would be an allocation on the
/// walk's hot path that can fail. Anything longer than `MAX_PATH_BYTES` could
/// not be opened anyway, so it is `ENAMETOOLONG` here rather than in the
/// kernel.
pub(super) fn nul_terminated<'z>(
    z: &'z mut [u8; MAX_PATH_BYTES + 1],
    bytes: &[u8],
) -> Result<&'z CStr, c_int> {
    if bytes.len() > MAX_PATH_BYTES {
        return Err(libc::ENAMETOOLONG);
    }
    z[..bytes.len()].copy_from_slice(bytes);
    z[bytes.len()] = 0;
    CStr::from_bytes_with_nul(&z[..=bytes.len()]).map_err(|_| libc::EINVAL)
}

/// Call `f` with `bytes` NUL-terminated on the stack; see [`nul_terminated`].
pub(super) fn with_cstr<R>(
    bytes: &[u8],
    f: impl FnOnce(&CStr) -> Result<R, c_int>,
) -> Result<R, c_int> {
    let mut z = [0u8; MAX_PATH_BYTES + 1];
    f(nul_terminated(&mut z, bytes)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walk::tests::opts;
    use crate::walk::{os_errno, walk_serial};
    use tesserae_testutil::Fixture;

    #[test]
    fn unreadable_root_is_an_error_not_a_partial_result() {
        let fx = Fixture::new().unwrap();
        fx.dir("locked").unwrap();
        fx.chmod("locked", 0o000).unwrap();
        let err = walk_serial(&opts(&fx.path().join("locked")))
            .err()
            .expect("walk must fail");
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn an_unreadable_root_keeps_its_errno() {
        let fx = Fixture::new().unwrap();
        fx.dir("locked").unwrap();
        fx.chmod("locked", 0o000).unwrap();
        let err = walk_serial(&opts(&fx.path().join("locked")))
            .err()
            .expect("walk must fail");
        // The number, not the kind: both EACCES and EPERM are PermissionDenied.
        assert_eq!(os_errno(&err), Some(libc::EACCES));
        assert!(
            err.to_string().contains("locked"),
            "the path is still in the message: {err}"
        );
    }
}
