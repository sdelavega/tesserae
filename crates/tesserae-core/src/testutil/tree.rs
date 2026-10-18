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

//! Filesystem fixture builder (tests only).
//!
//! The filesystem is the scanner's input, so tests need to manufacture exact
//! state: exact sizes, sparse files, hardlinks, symlinks, unreadable
//! directories and real APFS clones.

use std::ffi::{CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Write};
use std::os::raw::{c_char, c_int};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::FromRawFd;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;

use tempfile::TempDir;

extern "C" {
    // Not exposed by the `libc` crate. Creates a copy-on-write APFS clone.
    fn clonefile(src: *const c_char, dst: *const c_char, flags: c_int) -> c_int;
}

/// Mode restored on every `chmod`-ed path before the temp dir is removed.
const RESTORE_MODE: u32 = 0o755;

/// A temporary directory tree built up with exact, scanner-relevant state.
///
/// Dropping the fixture removes the tree, even if directories were made
/// unreadable with [`Fixture::chmod`].
#[derive(Debug)]
pub struct Fixture {
    root: TempDir,
    /// Every path passed to `chmod`, restored in `Drop` so cleanup can
    /// traverse it.
    chmodded: Mutex<Vec<PathBuf>>,
}

impl Fixture {
    pub fn new() -> io::Result<Self> {
        Ok(Self {
            root: TempDir::new()?,
            chmodded: Mutex::new(Vec::new()),
        })
    }

    pub fn path(&self) -> &Path {
        self.root.path()
    }

    /// Regular file of exactly `len` bytes, fully allocated (not sparse).
    pub fn file(&self, rel: &str, len: u64) -> io::Result<&Self> {
        let path = self.resolve(rel)?;
        write_dense(File::create(path)?, len)?;
        Ok(self)
    }

    /// File with logical size `logical` and no data blocks (`ftruncate` only).
    pub fn sparse(&self, rel: &str, logical: u64) -> io::Result<&Self> {
        let path = self.resolve(rel)?;
        File::create(path)?.set_len(logical)?;
        Ok(self)
    }

    /// Real APFS clone via `clonefile(2)`: a new inode sharing `src`'s blocks.
    pub fn clone_of(&self, src: &str, dst: &str) -> io::Result<&Self> {
        let src = cstring(self.resolve_existing(src)?.as_os_str().as_bytes())?;
        let dst = cstring(self.resolve(dst)?.as_os_str().as_bytes())?;
        // SAFETY: both pointers come from live, NUL-terminated CStrings.
        if unsafe { clonefile(src.as_ptr(), dst.as_ptr(), 0) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(self)
    }

    pub fn hardlink(&self, src: &str, dst: &str) -> io::Result<&Self> {
        let src = self.resolve_existing(src)?;
        let dst = self.resolve(dst)?;
        fs::hard_link(src, dst)?;
        Ok(self)
    }

    /// Symlink at `dst` whose target text is stored verbatim (it need not
    /// exist and is not resolved against the fixture root).
    pub fn symlink(&self, target: &str, dst: &str) -> io::Result<&Self> {
        let dst = self.resolve(dst)?;
        std::os::unix::fs::symlink(target, dst)?;
        Ok(self)
    }

    pub fn dir(&self, rel: &str) -> io::Result<&Self> {
        fs::create_dir_all(self.resolve_existing(rel)?)?;
        Ok(self)
    }

    /// Set permission bits. The path is remembered and restored to a
    /// traversable mode on drop.
    pub fn chmod(&self, rel: &str, mode: u32) -> io::Result<&Self> {
        let path = self.resolve_existing(rel)?;
        // Record first: if the chmod below succeeds we must be able to undo it.
        self.chmodded
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(path.clone());
        fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
        Ok(self)
    }

    /// File named by arbitrary bytes inside `dir`, `len` bytes long. The name
    /// reaches the kernel byte-exact; it never passes through `str`.
    ///
    /// Names that are not valid UTF-8 cannot be created: macOS rejects them at
    /// the syscall boundary (measured: `EILSEQ` on APFS, `EINVAL` on exFAT), so
    /// there is deliberately no fixture for them. Test byte-preservation of
    /// such names with a synthetic buffer instead.
    pub fn raw_name(&self, dir: &str, name: &[u8], len: u64) -> io::Result<&Self> {
        if name.is_empty() || name.contains(&b'/') {
            return Err(invalid("raw name must be non-empty and contain no '/'"));
        }
        let mut bytes = self.resolve_existing(dir)?.as_os_str().as_bytes().to_vec();
        bytes.push(b'/');
        bytes.extend_from_slice(name);
        if bytes.contains(&0) {
            return Err(invalid("raw name must not contain NUL"));
        }
        // SAFETY: `bytes` was just checked to contain no interior NUL;
        // `from_vec_unchecked` appends the terminator.
        let path = unsafe { CString::from_vec_unchecked(bytes) };
        // SAFETY: `path` is a valid NUL-terminated string.
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC,
                0o644 as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `fd` is a freshly opened descriptor we exclusively own.
        write_dense(unsafe { File::from_raw_fd(fd) }, len)?;
        Ok(self)
    }

    /// Resolve `rel` under the root, creating its parent directories.
    fn resolve(&self, rel: &str) -> io::Result<PathBuf> {
        let path = self.resolve_existing(rel)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        Ok(path)
    }

    /// Resolve `rel` under the root without touching the filesystem.
    /// Rejects absolute paths and `..` so a fixture can never write outside
    /// its own temp dir.
    fn resolve_existing(&self, rel: &str) -> io::Result<PathBuf> {
        let rel = Path::new(OsStr::new(rel));
        if rel.components().any(|c| {
            matches!(
                c,
                Component::ParentDir | Component::Prefix(_) | Component::RootDir
            )
        }) {
            return Err(invalid(
                "fixture paths must be relative and stay inside the root",
            ));
        }
        Ok(self.root.path().join(rel))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // `chmod 000` on a directory makes it untraversable, so `TempDir`
        // could not delete what is inside it and would leak the tree. Restore
        // shallow paths first: a locked parent hides its locked children.
        let mut paths = std::mem::take(self.chmodded.get_mut().unwrap_or_else(|e| e.into_inner()));
        paths.sort_by_key(|p| p.components().count());
        for path in paths {
            // Best effort: the path may already be gone.
            let _ = fs::set_permissions(&path, fs::Permissions::from_mode(RESTORE_MODE));
        }
        // `root` drops after this body returns.
    }
}

fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
}

fn cstring(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes).map_err(|_| invalid("path contains NUL"))
}

/// Write `len` bytes of non-zero data so every block is really allocated.
fn write_dense(mut file: File, len: u64) -> io::Result<()> {
    let chunk = [0xA5u8; 64 * 1024];
    let mut left = len;
    while left > 0 {
        let n = left.min(chunk.len() as u64) as usize;
        file.write_all(&chunk[..n])?;
        left -= n as u64;
    }
    file.flush()
}

#[cfg(test)]
mod tests {
    use super::Fixture;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::MetadataExt;
    use std::path::Path;

    #[test]
    fn file_has_exact_size() {
        let fx = Fixture::new().unwrap();
        fx.file("a.bin", 4096).unwrap();
        assert_eq!(
            std::fs::metadata(fx.path().join("a.bin")).unwrap().len(),
            4096
        );
    }

    #[test]
    fn sparse_file_allocates_less_than_logical() {
        let fx = Fixture::new().unwrap();
        fx.sparse("s.bin", 1 << 30).unwrap();
        let md = std::fs::metadata(fx.path().join("s.bin")).unwrap();
        assert_eq!(md.size(), 1 << 30);
        assert!(
            md.blocks() * 512 < 1 << 20,
            "allocated {}",
            md.blocks() * 512
        );
    }

    #[test]
    fn clonefile_shares_blocks() {
        let fx = Fixture::new().unwrap();
        fx.file("b.bin", 1 << 20).unwrap();
        fx.clone_of("b.bin", "copy.bin").unwrap();
        let a = std::fs::metadata(fx.path().join("b.bin")).unwrap();
        let b = std::fs::metadata(fx.path().join("copy.bin")).unwrap();
        assert_eq!(a.size(), 1 << 20);
        assert_eq!(b.size(), 1 << 20);
        assert_ne!(a.ino(), b.ino());
    }

    #[test]
    fn raw_name_round_trips_exact_bytes() {
        // Valid UTF-8 but not ASCII: must come back byte-exact through the
        // raw-byte path (no normalisation, no lossy conversion).
        let name = b"caf\xc3\xa9 \xe2\x82\xac.bin";
        let fx = Fixture::new().unwrap();
        fx.raw_name(".", name, 16).unwrap();
        let entry = std::fs::read_dir(fx.path())
            .unwrap()
            .next()
            .unwrap()
            .unwrap();
        assert_eq!(entry.file_name().as_bytes(), name);
        assert_eq!(entry.metadata().unwrap().len(), 16);
    }

    #[test]
    fn raw_name_rejects_separator_and_nul() {
        let fx = Fixture::new().unwrap();
        for name in [&b"a/b"[..], b"a\0b", b""] {
            let err = fx.raw_name(".", name, 1).unwrap_err();
            assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
        }
    }

    #[test]
    fn clone_consumes_no_new_space() {
        // Observable only through volume free space: a real clone shares
        // blocks, a copy would consume `LEN` more bytes.
        const LEN: u64 = 64 << 20;
        let fx = Fixture::new().unwrap();
        fx.file("big.bin", LEN).unwrap();
        let before = free_bytes(fx.path());
        fx.clone_of("big.bin", "clone.bin").unwrap();
        let used = before.saturating_sub(free_bytes(fx.path()));
        assert!(
            used < LEN / 4,
            "clone consumed {used} bytes; not a real clone"
        );
    }

    #[test]
    fn hardlink_shares_inode_and_symlink_is_verbatim() {
        let fx = Fixture::new().unwrap();
        fx.file("d/a.bin", 8).unwrap();
        fx.hardlink("d/a.bin", "d/b.bin").unwrap();
        fx.symlink("../nowhere", "d/link").unwrap();
        let a = std::fs::metadata(fx.path().join("d/a.bin")).unwrap();
        let b = std::fs::metadata(fx.path().join("d/b.bin")).unwrap();
        assert_eq!((a.ino(), a.nlink()), (b.ino(), 2));
        assert_eq!(
            std::fs::read_link(fx.path().join("d/link")).unwrap(),
            Path::new("../nowhere")
        );
    }

    #[test]
    fn paths_cannot_escape_the_root() {
        let fx = Fixture::new().unwrap();
        for rel in ["../x", "/tmp/x", "a/../../x"] {
            assert_eq!(
                fx.file(rel, 1).unwrap_err().kind(),
                std::io::ErrorKind::InvalidInput,
                "{rel}"
            );
        }
    }

    #[test]
    fn drop_removes_tree_with_unreadable_dirs() {
        let fx = Fixture::new().unwrap();
        fx.file("outer/inner/deep.bin", 8).unwrap();
        fx.file("other/f.bin", 8).unwrap();
        // Nested locks: restoring the child first would fail under a locked parent.
        fx.chmod("outer/inner", 0o000).unwrap();
        fx.chmod("outer", 0o000).unwrap();
        fx.chmod("other", 0o000).unwrap();
        let root = fx.path().to_path_buf();
        drop(fx);
        assert!(!root.exists(), "fixture leaked {}", root.display());
    }

    fn free_bytes(path: &Path) -> u64 {
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        assert_eq!(unsafe { libc::statvfs(c.as_ptr(), &mut st) }, 0);
        st.f_bavail as u64 * st.f_frsize as u64
    }
}
