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

//! Requested exclusions are identities, resolved without opening a directory.

use std::collections::HashSet;
use std::ffi::CStr;
use std::io;
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

use super::open::with_cstr;
use super::{WalkOptions, WalkStats};
use crate::arena::{Arena, ScanId, ScanNode, FLAG_PERM_DENIED, FLAG_SKIPPED_REQUEST};
use crate::parse::ObjType;

type Identity = (u64, u64);

#[derive(Default)]
pub(crate) struct SkipSet {
    ids: HashSet<Identity>,
    pub(crate) root_is_volume_root: bool,
    pub(crate) missing: Vec<(PathBuf, &'static str)>,
}

/// Metadata only: NOFOLLOW examines the named object itself; a listed
/// symlink is then followed for its target identity, without opening it.
pub(super) fn metadata_at(parent: RawFd, path: &CStr, flags: i32) -> io::Result<libc::stat> {
    loop {
        let mut st = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: path is NUL-terminated and st is a valid stat out-pointer.
        if unsafe { libc::fstatat(parent, path.as_ptr(), st.as_mut_ptr(), flags) } == 0 {
            // SAFETY: the successful call initialized st.
            return Ok(unsafe { st.assume_init() });
        }
        let e = io::Error::last_os_error();
        if e.raw_os_error() != Some(libc::EINTR) {
            return Err(e);
        }
    }
}

impl SkipSet {
    pub(crate) fn resolve(opts: &WalkOptions) -> io::Result<Self> {
        let mut set = Self::default();
        for path in &opts.skip {
            if !path.is_absolute() {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "skip paths must be absolute",
                ));
            }
            let result = with_cstr(path.as_os_str().as_bytes(), |c| {
                let mut st = metadata_at(libc::AT_FDCWD, c, libc::AT_SYMLINK_NOFOLLOW)
                    .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO))?;
                if st.st_mode & libc::S_IFMT == libc::S_IFLNK {
                    st = metadata_at(libc::AT_FDCWD, c, 0)
                        .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO))?;
                }
                Ok(st)
            });
            match result {
                Ok(st) if st.st_mode & libc::S_IFMT == libc::S_IFDIR => {
                    set.ids.insert((st.st_dev as u64, st.st_ino));
                }
                Ok(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "skip path is not a directory",
                    ))
                }
                Err(libc::ENOENT | libc::ENOTDIR) => {
                    set.missing.push((path.clone(), "not present"))
                }
                Err(e) => {
                    return Err(super::with_context(
                        io::Error::from_raw_os_error(e),
                        format!("resolve skip {}", path.display()),
                    ))
                }
            }
        }
        Ok(set)
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    pub(crate) fn matches_identity(&self, identity: Identity) -> bool {
        self.ids.contains(&identity)
    }

    pub(crate) fn matches_at(&self, parent: RawFd, name: &CStr, follow: bool) -> io::Result<bool> {
        if self.is_empty() {
            return Ok(false);
        }
        let st = metadata_at(
            parent,
            name,
            if follow { 0 } else { libc::AT_SYMLINK_NOFOLLOW },
        )?;
        Ok(st.st_mode & libc::S_IFMT == libc::S_IFDIR
            && self.ids.contains(&(st.st_dev as u64, st.st_ino)))
    }

    /// The root must be admitted before open_root too.
    pub(crate) fn root_snapshot(
        &self,
        opts: &WalkOptions,
        started_at: i64,
        opener: &impl super::open::DirOpener,
    ) -> io::Result<Option<(Arena, WalkStats)>> {
        let metadata = opener
            .root_metadata(&opts.root)
            .map_err(|e| super::with_context(e, format!("stat {}", opts.root.display())))?;
        let dataless = metadata.st_mode & libc::S_IFMT == libc::S_IFDIR
            && crate::dataless::is_dataless(metadata.st_flags);
        let matched = with_cstr(opts.root.as_os_str().as_bytes(), |c| {
            self.matches_at(libc::AT_FDCWD, c, true)
                .map_err(|e| e.raw_os_error().unwrap_or(libc::EIO))
        })
        .map_err(io::Error::from_raw_os_error)?;
        if !matched && !dataless {
            return Ok(None);
        }
        let mut arena = Arena::new(0, u64::MAX);
        let mut stats = WalkStats {
            started_at,
            root_device: metadata.st_dev,
            skipped_by_request: self.missing.clone(),
            ..WalkStats::default()
        };
        if opts.node_budget == 0 {
            stats.incomplete = Some(super::Incomplete::NodeBudget);
        } else {
            let name = arena
                .push_name(opts.root.as_os_str().as_bytes())
                .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
            arena
                .push_node(ScanNode {
                    name,
                    parent: ScanId::NONE,
                    obj_type: ObjType::Dir,
                    flags: FLAG_PERM_DENIED
                        | if matched { FLAG_SKIPPED_REQUEST } else { 0 }
                        | if dataless {
                            crate::arena::FLAG_DATALESS
                        } else {
                            0
                        },
                    logical: 0,
                    allocated: 0,
                    modified: metadata.st_mtime,
                    file_id: metadata.st_ino,
                })
                .map_err(|_| io::Error::from(io::ErrorKind::OutOfMemory))?;
            stats.dirs = 1;
            if dataless {
                stats.dataless.directories = 1;
                stats.dataless_paths.push(opts.root.clone());
            }
            if matched {
                stats
                    .skipped_by_request
                    .push((opts.root.clone(), "limited scan"));
            }
        }
        Ok(Some((arena, stats)))
    }
}
