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

//! Filesystem fixture builder.
//!
//! The filesystem is the scanner's input, so tests need to manufacture exact
//! state: exact sizes, sparse files, hardlinks, symlinks, unreadable
//! directories and real APFS clones.

use std::ffi::{CString, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use tempfile::TempDir;

extern "C" {
    // Not exposed by the `libc` crate. Creates a copy-on-write APFS clone.
    // `flags` is `uint32_t` in <sys/clonefile.h>.
    fn clonefile(src: *const c_char, dst: *const c_char, flags: u32) -> libc::c_int;
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
    /// # Panics
    ///
    /// Panics if the process runs as root: `chmod(0o000)` is bypassed for
    /// root, so an unreadable-directory fixture would silently be readable
    /// and every test depending on it would pass for the wrong reason.
    /// Enforced here, where the dangerous operation lives, so it holds for
    /// every consumer (unit tests, `tests/`, benches, other crates).
    pub fn new() -> io::Result<Self> {
        // SAFETY: geteuid has no preconditions and cannot fail.
        assert_ne!(
            unsafe { libc::geteuid() },
            0,
            "fixtures must not be built as root: chmod 000 is bypassed and \
             permission tests pass for the wrong reason"
        );
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
        let file = File::create(&path).map_err(at("create", &path))?;
        write_dense(file, len).map_err(at("write", &path))?;
        Ok(self)
    }

    /// File with logical size `logical` and no data blocks (`ftruncate` only).
    pub fn sparse(&self, rel: &str, logical: u64) -> io::Result<&Self> {
        let path = self.resolve(rel)?;
        File::create(&path)
            .and_then(|f| f.set_len(logical))
            .map_err(at("create sparse", &path))?;
        Ok(self)
    }

    /// Real APFS clone via `clonefile(2)`: a new inode sharing `src`'s blocks.
    ///
    /// Fails (with the paths in the message) if the temp dir is not on APFS.
    pub fn clone_of(&self, src: &str, dst: &str) -> io::Result<&Self> {
        let src_path = self.resolve_unchecked(src)?;
        let dst_path = self.resolve(dst)?;
        let c_src = cstring(src_path.as_os_str().as_bytes())?;
        let c_dst = cstring(dst_path.as_os_str().as_bytes())?;
        // SAFETY: both pointers come from live, NUL-terminated CStrings.
        if unsafe { clonefile(c_src.as_ptr(), c_dst.as_ptr(), 0) } != 0 {
            return Err(at2("clonefile", &src_path, &dst_path)(
                io::Error::last_os_error(),
            ));
        }
        Ok(self)
    }

    pub fn hardlink(&self, src: &str, dst: &str) -> io::Result<&Self> {
        let src_path = self.resolve_unchecked(src)?;
        let dst_path = self.resolve(dst)?;
        fs::hard_link(&src_path, &dst_path).map_err(at2("link", &src_path, &dst_path))?;
        Ok(self)
    }

    /// Symlink at `dst` whose target text is stored verbatim (it need not
    /// exist and is not resolved against the fixture root).
    pub fn symlink(&self, target: &str, dst: &str) -> io::Result<&Self> {
        let dst_path = self.resolve(dst)?;
        std::os::unix::fs::symlink(target, &dst_path).map_err(at("symlink", &dst_path))?;
        Ok(self)
    }

    pub fn dir(&self, rel: &str) -> io::Result<&Self> {
        let path = self.resolve_unchecked(rel)?;
        fs::create_dir_all(&path).map_err(at("mkdir", &path))?;
        Ok(self)
    }

    /// Set permission bits. The path is remembered and restored to a
    /// traversable mode on drop.
    ///
    /// Refuses paths that pass through a symlink: `chmod` follows links, and
    /// the lexical path guard cannot see where a fixture symlink points, so
    /// this would otherwise be able to change permissions outside the root.
    pub fn chmod(&self, rel: &str, mode: u32) -> io::Result<&Self> {
        let path = self.resolve_unchecked(rel)?;
        self.refuse_symlinks(&path)?;
        // Record first: if the chmod below succeeds we must be able to undo it.
        self.chmodded
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(path.clone());
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).map_err(at("chmod", &path))?;
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
        let mut path = self.resolve_unchecked(dir)?;
        path.push(OsStr::from_bytes(name));
        // `OpenOptions` hands the OS string's bytes to open(2) unchanged and
        // rejects interior NUL, so no `unsafe` is needed for byte-exactness.
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .open(&path)
            .map_err(at("create", &path))?;
        write_dense(file, len).map_err(at("write", &path))?;
        Ok(self)
    }

    /// Resolve `rel` under the root, creating its parent directories.
    fn resolve(&self, rel: &str) -> io::Result<PathBuf> {
        let path = self.resolve_unchecked(rel)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(at("mkdir", parent))?;
        }
        Ok(path)
    }

    /// Resolve `rel` under the root without touching the filesystem.
    /// Rejects absolute paths and `..` so a fixture can never write outside
    /// its own temp dir.
    fn resolve_unchecked(&self, rel: &str) -> io::Result<PathBuf> {
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

    /// Error if `path` (under the root) or any component of it is a symlink.
    fn refuse_symlinks(&self, path: &Path) -> io::Result<()> {
        let mut cur = self.root.path().to_path_buf();
        let rel = path.strip_prefix(&cur).unwrap_or(path);
        for comp in rel.components() {
            cur.push(comp);
            match fs::symlink_metadata(&cur) {
                Ok(md) if md.file_type().is_symlink() => {
                    return Err(invalid(&format!(
                        "refusing to chmod through symlink {}",
                        cur.display()
                    )));
                }
                Ok(_) => {}
                Err(e) => return Err(at("lstat", &cur)(e)),
            }
        }
        Ok(())
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
            // Never follow a link that appeared after `chmod` validated the path.
            if fs::symlink_metadata(&path).is_ok_and(|md| md.file_type().is_symlink()) {
                continue;
            }
            // Best effort: the path may already be gone.
            let _ = fs::set_permissions(&path, fs::Permissions::from_mode(RESTORE_MODE));
        }
        // `root` drops after this body returns.
    }
}

fn invalid(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
}

/// Adds the operation and path to an I/O error, keeping its `ErrorKind`.
fn at<'a>(op: &'a str, path: &'a Path) -> impl FnOnce(io::Error) -> io::Error + 'a {
    move |e| io::Error::new(e.kind(), format!("{op} {}: {e}", path.display()))
}

fn at2<'a>(op: &'a str, src: &'a Path, dst: &'a Path) -> impl FnOnce(io::Error) -> io::Error + 'a {
    move |e| {
        io::Error::new(
            e.kind(),
            format!("{op} {} -> {}: {e}", src.display(), dst.display()),
        )
    }
}

fn cstring(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes).map_err(|_| invalid("path contains NUL"))
}

/// Serialises everything in this crate that allocates meaningful disk space
/// against any measurement of free space.
///
/// Free space is a shared global resource, and the only observable that tells
/// a real APFS clone from a full copy is the change in a volume's free space
/// (`clone_consumes_no_new_space`; a clone and a copy have identical
/// `st_blocks`). Any allocation that lands inside that measurement window is
/// indistinguishable from the copy it is looking for, and the test's tolerance
/// is the same order as what a disk image allocates, so an overlap is a
/// predictable failure rather than noise. (Accounting is synchronous with
/// `write(2)`, measured, so holding the lock across the write is enough.)
///
/// So: code that writes real data ([`write_dense`], [`crate::DiskImage`]
/// creation) holds this lock while it does, and a test that measures free space
/// holds it across the whole measurement. Cloning, `sparse` (an `ftruncate`,
/// no blocks), links and directories allocate nothing worth guarding and
/// do not take it.
///
/// It only serialises threads of one test binary, which is the only place they
/// can overlap: cargo runs test binaries one after another.
static ALLOCATION: Mutex<()> = Mutex::new(());

thread_local! {
    /// Whether this thread holds [`ALLOCATION`]. Lets an allocating site
    /// *assert* that it is covered, so deleting the lock from it fails
    /// deterministically on a plain single-threaded call instead of depending
    /// on a race or a clock.
    static HELD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Proof that the allocation lock is held; releases it when dropped.
#[must_use = "the lock is released as soon as this is dropped"]
pub struct AllocationGuard {
    _lock: MutexGuard<'static, ()>,
}

/// Hold the allocation lock; see `ALLOCATION`. A panic in another test while
/// holding it must not wedge every later one, so poisoning is ignored.
///
/// Not reentrant: taking it twice on one thread would deadlock, so it panics
/// with a message instead.
pub fn allocation_lock() -> AllocationGuard {
    assert!(
        !HELD.with(|h| h.get()),
        "allocation_lock is not reentrant: this thread already holds it \
         (a measuring test must not call code that takes the lock)"
    );
    let lock = ALLOCATION.lock().unwrap_or_else(|e| e.into_inner());
    HELD.with(|h| h.set(true));
    AllocationGuard { _lock: lock }
}

impl Drop for AllocationGuard {
    fn drop(&mut self) {
        HELD.with(|h| h.set(false));
    }
}

#[cfg(test)]
fn assert_allocation_lock_held_is_false_here() {
    assert!(!HELD.with(|h| h.get()), "the lock must not be held here");
}

/// Panic unless the calling thread holds the allocation lock. Called by every
/// site that writes real data, immediately before it does.
pub fn assert_allocation_lock_held() {
    assert!(
        HELD.with(|h| h.get()),
        "this writes real disk space and must hold `allocation_lock()` so it \
         cannot land inside a free-space measurement"
    );
}

/// Write `len` bytes of non-zero data so every block is really allocated.
fn write_dense(file: File, len: u64) -> io::Result<()> {
    let _alloc = allocation_lock();
    assert_allocation_lock_held();
    fill_dense(file, len)
}

fn fill_dense(mut file: File, len: u64) -> io::Result<()> {
    let chunk = [0xA5u8; 64 * 1024];
    let mut left = len;
    while left > 0 {
        let n = left.min(chunk.len() as u64) as usize;
        file.write_all(&chunk[..n])?;
        left -= n as u64;
    }
    Ok(())
}

/// Create a new file at `path` holding `len` bytes of non-zero data and flush
/// it to the volume.
///
/// For a test that is *measuring* free space and so already holds
/// [`allocation_lock`], which [`Fixture::file`] would try to take a second time
/// and refuse. Panics unless the calling thread holds the lock. `path` is
/// taken as given: unlike a `Fixture` path it is not confined to a fixture
/// root, so the caller owns where it points.
pub fn write_dense_file(path: &Path, len: u64) -> io::Result<()> {
    assert_allocation_lock_held();
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(at("create", path))?;
    let flushed = file.try_clone().map_err(at("dup", path))?;
    fill_dense(file, len).map_err(at("write", path))?;
    flushed.sync_all().map_err(at("fsync", path))
}

/// A real copy of `src` at the new file `dst`: every block read and written
/// again, so it consumes `src`'s size in new space.
///
/// `std::fs::copy` is not that on macOS: it calls `copyfile(3)` with its clone
/// flag and shares blocks, which is the opposite of what a caller using this
/// as the control for a clone wants. Same lock contract as
/// [`write_dense_file`].
pub fn copy_by_read_write(src: &Path, dst: &Path) -> io::Result<()> {
    assert_allocation_lock_held();
    let mut from = File::open(src).map_err(at("open", src))?;
    let mut to = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dst)
        .map_err(at("create", dst))?;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = io::Read::read(&mut from, &mut buf).map_err(at("read", src))?;
        if n == 0 {
            break;
        }
        to.write_all(&buf[..n]).map_err(at("write", dst))?;
    }
    to.sync_all().map_err(at("fsync", dst))
}

/// Bytes available to an unprivileged writer on the volume holding `path`.
///
/// Of an APFS volume this is the free space of its *container*, shared with
/// every other volume in it. That is the machine's own disk for a path on the
/// boot volume, and just the one volume for a [`crate::DiskImage`], whose
/// container is the image: which is why free-space measurements are made on an
/// image.
pub fn free_bytes(path: &Path) -> io::Result<u64> {
    let c = cstring(path.as_os_str().as_bytes())?;
    // SAFETY: an all-zero `statvfs` is a valid value of a plain C struct.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is NUL-terminated and `st` is a live, writable `statvfs`.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return Err(at("statvfs", path)(io::Error::last_os_error()));
    }
    Ok(u64::from(st.f_bavail) * st.f_frsize)
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
        let md = std::fs::metadata(fx.path().join("a.bin")).unwrap();
        assert_eq!(md.len(), 4096);
        // Fully allocated, not sparse. `clone_consumes_no_new_space` relies on
        // this: cloning or copying a sparse file moves ~0 bytes either way.
        assert!(md.blocks() * 512 >= 4096, "allocated {}", md.blocks() * 512);
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
    fn clone_of_makes_distinct_inode() {
        // Size and inode alone cannot tell a clone from a copy (`fs::copy`
        // clones on macOS); `clone_consumes_no_new_space` carries that claim.
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
    fn clone_consumes_no_new_space() {
        // Observable only through volume free space: a real clone shares
        // blocks, a copy would consume `LEN` more bytes. Meaningful only
        // because `file()` is dense (asserted in `file_has_exact_size`).
        const LEN: u64 = 64 << 20;
        let fx = Fixture::new().unwrap();
        fx.file("big.bin", LEN).unwrap();
        // Nothing else in this binary may allocate between the two readings;
        // see `allocation_lock`. `clone_of` does not take it, so no deadlock.
        let _quiet = super::allocation_lock();
        let before = super::free_bytes(fx.path()).unwrap();
        fx.clone_of("big.bin", "clone.bin").unwrap();
        let used = before.saturating_sub(super::free_bytes(fx.path()).unwrap());
        assert!(
            used < LEN / 4,
            "clone consumed {used} bytes; not a real clone"
        );
    }

    #[test]
    fn the_allocation_lock_marks_the_thread_while_held() {
        super::assert_allocation_lock_held_is_false_here();
        let guard = super::allocation_lock();
        super::assert_allocation_lock_held();
        drop(guard);
        super::assert_allocation_lock_held_is_false_here();
    }

    #[test]
    #[should_panic(expected = "not reentrant")]
    fn the_allocation_lock_refuses_to_deadlock_on_reentry() {
        let _outer = super::allocation_lock();
        let _inner = super::allocation_lock();
    }

    #[test]
    #[should_panic(expected = "must hold `allocation_lock()`")]
    fn the_held_assertion_fires_without_the_lock() {
        super::assert_allocation_lock_held();
    }

    #[test]
    #[should_panic(expected = "must hold `allocation_lock()`")]
    fn write_dense_file_refuses_to_write_without_the_lock() {
        let fx = Fixture::new().unwrap();
        let _ = super::write_dense_file(&fx.path().join("x"), 1);
    }

    #[test]
    #[should_panic(expected = "must hold `allocation_lock()`")]
    fn copy_by_read_write_refuses_to_write_without_the_lock() {
        let fx = Fixture::new().unwrap();
        let _ = super::copy_by_read_write(&fx.path().join("a"), &fx.path().join("b"));
    }

    #[test]
    fn raw_name_round_trips_exact_bytes() {
        // Valid UTF-8, so this cannot show that invalid bytes survive (no
        // fixture can: see `raw_name`). It guards against the builder or
        // filesystem normalising the name: precomposed 'e-acute' must not
        // come back decomposed.
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
    fn chmod_refuses_symlinks_and_never_touches_the_target() {
        let outside = Fixture::new().unwrap();
        outside.dir("victim").unwrap();
        let victim = outside.path().join("victim");
        let before = std::fs::metadata(&victim).unwrap().mode();

        let fx = Fixture::new().unwrap();
        fx.symlink(victim.to_str().unwrap(), "link").unwrap();
        // The link itself, and a path through it, are both refused.
        for rel in ["link", "link/inner"] {
            let err = fx.chmod(rel, 0o000).unwrap_err();
            assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput, "{rel}");
        }
        drop(fx);
        assert_eq!(std::fs::metadata(&victim).unwrap().mode(), before);
    }

    #[test]
    fn errors_name_the_operation_and_paths() {
        let fx = Fixture::new().unwrap();
        let err = fx.hardlink("missing.bin", "dst.bin").unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::NotFound);
        let msg = err.to_string();
        assert!(
            msg.contains("link") && msg.contains("missing.bin") && msg.contains("dst.bin"),
            "{msg}"
        );
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
}
