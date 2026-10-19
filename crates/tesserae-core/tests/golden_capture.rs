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

//! Golden-corpus capture: record real `getattrlistbulk` buffers to disk.
//!
//! Run with `cargo test -p tesserae-core --test golden_capture -- --ignored`.
//! Ignored by default because it rewrites committed fixtures; the parser's own
//! tests replay them and must not depend on the machine they run on.
//!
//! Two files are written per corpus:
//!
//! * `golden_<name>.bin` — the raw kernel bytes, preceded by a 16-byte header
//!   (`TSRGOLD1`, entry count u32-LE, buffer length u32-LE). **The parser is
//!   not involved**: the attribute bytes are copied verbatim out of the
//!   syscall's output buffer, so a parser bug cannot be baked into the
//!   fixture. This file does read each entry's leading `u32` length, and only
//!   that, to find where the kernel stopped writing — being precise about what
//!   is independent is the whole point of this module.
//!
//! * `golden_<name>.expect` — the same tree's attributes read back through
//!   `lstat(2)`, an independent source of truth. The parser test cross-checks
//!   its output against this, so agreeing with the golden buffer is not enough:
//!   it must also agree with the kernel's other interface to the same metadata.
//!
//! Note on `d_alloc`: a directory's `getattrlistbulk` entry carries no
//! `fileattr` group at all (see `parse.rs`), so the expectation records `0` for
//! directories rather than `lstat`'s `st_blocks`. The `mtime` column is
//! `st_mtime` for every kind, directories included: `ATTR_CMN_MODTIME` is a
//! common attribute, present in every entry. The `flags` column is
//! `st_flags`, likewise for every kind (`ATTR_CMN_FLAGS`).

use std::ffi::CString;
use std::fs;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use tesserae_core::attrs::{scan_attrlist, SCAN_OPTIONS};
use tesserae_testutil::Fixture;

const MAGIC: &[u8; 8] = b"TSRGOLD1";
const BUF_LEN: usize = 64 * 1024;

/// One `getattrlistbulk` call's worth of raw output.
struct Capture {
    count: u32,
    buf: Vec<u8>,
}

/// Call `getattrlistbulk` once on `dir` with the scan's real attrlist and
/// options, returning the untouched output buffer.
///
/// A corpus must fit in a single batch. A second call returning non-zero is an
/// assertion failure rather than discarded data: `count` and the trimmed byte
/// range would stay mutually consistent, so a silently half-captured corpus
/// would let every replay test pass over a fixture missing most of its tree.
/// Silent truncation is the failure class this module exists to prevent.
fn capture(dir: &Path) -> Capture {
    let c_dir = CString::new(dir.as_os_str().as_bytes()).unwrap();
    // SAFETY: `c_dir` is a live NUL-terminated string.
    let fd = unsafe { libc::open(c_dir.as_ptr(), libc::O_RDONLY) };
    assert!(fd >= 0, "open {}: {}", dir.display(), last_error());

    let mut attrlist = scan_attrlist();
    let mut buf = vec![0u8; BUF_LEN];
    let mut call = |b: &mut [u8]| {
        // SAFETY: `attrlist` and `b` are live and `b.len()` is its true size.
        unsafe {
            libc::getattrlistbulk(
                fd,
                (&mut attrlist as *mut libc::attrlist).cast(),
                b.as_mut_ptr().cast(),
                b.len(),
                SCAN_OPTIONS,
            )
        }
    };
    let count = call(&mut buf);
    assert!(count >= 0, "getattrlistbulk: {}", last_error());
    assert!(count > 0, "{} produced no entries", dir.display());

    // The directory fd keeps its own offset, so a second call continues where
    // the first stopped. Zero means the whole directory was captured.
    let mut tail = vec![0u8; BUF_LEN];
    let more = call(&mut tail);
    assert!(more >= 0, "getattrlistbulk (second call): {}", last_error());
    assert_eq!(
        more,
        0,
        "{} needs more than one batch: the first call returned {count} entries and \
         a second returned {more}. The fixture would hold only the first batch, with \
         `count` and the byte range still mutually consistent, so every replay test \
         would pass over a truncated corpus. Shrink the fixture tree or teach this \
         function to concatenate batches.",
        dir.display()
    );

    // SAFETY: `fd` is owned by this function and not used again.
    unsafe { libc::close(fd) };

    // Trim to the bytes the kernel actually wrote so the fixture holds no
    // zero padding that could mask a length bug.
    let used: usize = (0..count)
        .scan(0usize, |pos, _| {
            let len = u32::from_le_bytes(buf[*pos..*pos + 4].try_into().unwrap()) as usize;
            *pos += len;
            Some(*pos)
        })
        .last()
        .unwrap();
    buf.truncate(used);
    Capture {
        count: count as u32,
        buf,
    }
}

fn last_error() -> std::io::Error {
    std::io::Error::last_os_error()
}

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
}

/// Give every entry of `dir` its own modification time, without following
/// symlinks, so that a parser reading one entry's time from another's slot
/// cannot match the sidecar. A fixture built in one go otherwise has the same
/// second everywhere. The last entry in name order gets a time before 1970,
/// which `time_t` represents as negative.
fn stamp_distinct_mtimes(dir: &Path) {
    let mut names: Vec<_> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    names.sort();
    let last = names.len() - 1;
    for (i, name) in names.iter().enumerate() {
        let sec: i64 = if i == last {
            -86_400 * 365
        } else {
            1_600_000_000 + 1_000_003 * i as i64
        };
        let c = CString::new(dir.join(name).as_os_str().as_bytes()).unwrap();
        let times = [
            libc::timespec {
                tv_sec: 0,
                tv_nsec: libc::UTIME_OMIT,
            },
            libc::timespec {
                tv_sec: sec,
                tv_nsec: 0,
            },
        ];
        // SAFETY: `c` is NUL-terminated; `times` holds the two timespecs read.
        let rc = unsafe {
            libc::utimensat(
                libc::AT_FDCWD,
                c.as_ptr(),
                times.as_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        assert_eq!(rc, 0, "utimensat {name:?}: {}", last_error());
    }
}

fn write_corpus(name: &str, dir: &Path) {
    stamp_distinct_mtimes(dir);
    let cap = capture(dir);
    let out = fixtures_dir();
    fs::create_dir_all(&out).unwrap();

    let mut bin = Vec::with_capacity(16 + cap.buf.len());
    bin.extend_from_slice(MAGIC);
    bin.extend_from_slice(&cap.count.to_le_bytes());
    bin.extend_from_slice(&(cap.buf.len() as u32).to_le_bytes());
    bin.extend_from_slice(&cap.buf);
    fs::write(out.join(format!("golden_{name}.bin")), &bin).unwrap();

    // Independent expectation, via lstat(2) on the same tree.
    let mut rows: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| {
            let entry = e.unwrap();
            let path = entry.path();
            let st = lstat(&path);
            let kind = match st.st_mode & libc::S_IFMT {
                libc::S_IFREG => "reg",
                libc::S_IFDIR => "dir",
                libc::S_IFLNK => "lnk",
                _ => "other",
            };
            let is_dir = st.st_mode & libc::S_IFMT == libc::S_IFDIR;
            // A directory entry carries no fileattr group, so these three are
            // absent from the buffer and the parser reports its defaults.
            let (nlink, logical, allocated) = if is_dir {
                (0, 0, 0)
            } else {
                (
                    u64::from(st.st_nlink),
                    st.st_size as u64,
                    st.st_blocks as u64 * 512,
                )
            };
            format!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                hex(entry.file_name().as_bytes()),
                kind,
                st.st_ino,
                st.st_dev,
                nlink,
                logical,
                allocated,
                st.st_mtime,
                st.st_flags,
            )
        })
        .collect();
    rows.sort();

    let mut f = fs::File::create(out.join(format!("golden_{name}.expect"))).unwrap();
    writeln!(
        f,
        "# name_hex\tkind\tino\tdev\tnlink\tlogical\tallocated\tmtime\tflags"
    )
    .unwrap();
    writeln!(
        f,
        "# from lstat(2); nlink/logical/allocated are 0 for dirs; mtime is st_mtime; flags is st_flags"
    )
    .unwrap();
    for row in rows {
        writeln!(f, "{row}").unwrap();
    }
}

fn lstat(path: &Path) -> libc::stat {
    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: `c` is live and NUL-terminated; `st` is a valid out-pointer.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { libc::lstat(c.as_ptr(), &mut st) },
        0,
        "lstat {}: {}",
        path.display(),
        last_error()
    );
    st
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `UF_NODUMP | UF_HIDDEN`, `0x1` and `0x8000` in `sys/stat.h`: two
/// owner-settable bits, far apart, so that `ATTR_CMN_FLAGS` read from any
/// other offset cannot match `st_flags` by accident.
const DENSE_FLAGS: u32 = 0x0000_8001;

/// `chflags(2)` `path` to exactly `flags`.
fn set_flags(path: &Path, flags: u32) {
    assert_eq!(libc::UF_NODUMP, 0x1);
    assert_eq!(libc::UF_HIDDEN, 0x8000);
    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: `c` is a live NUL-terminated string.
    let rc = unsafe { libc::chflags(c.as_ptr(), flags) };
    assert_eq!(rc, 0, "chflags {}: {}", path.display(), last_error());
    assert_eq!(lstat(path).st_flags, flags, "the flags took");
}

/// `golden_simple.bin`: the brief's two-entry tree.
#[test]
#[ignore = "rewrites committed fixtures; run explicitly with --ignored"]
fn capture_golden_simple() {
    let fx = Fixture::new().unwrap();
    fx.file("a.bin", 4096).unwrap();
    fx.dir("d").unwrap();
    write_corpus("simple", fx.path());
}

/// `golden_mixed.bin`: every object shape the scanner has to survive —
/// a symlink, a hardlink pair, an APFS clone, a sparse file whose allocation
/// is far below its logical size, and a multi-byte UTF-8 name.
#[test]
#[ignore = "rewrites committed fixtures; run explicitly with --ignored"]
fn capture_golden_mixed() {
    let fx = Fixture::new().unwrap();
    fx.file("dense.bin", 8192).unwrap();
    fx.sparse("sparse.bin", 1 << 30).unwrap();
    fx.file("link-target.bin", 4096).unwrap();
    fx.hardlink("link-target.bin", "hardlink.bin").unwrap();
    fx.clone_of("dense.bin", "clone.bin").unwrap();
    fx.symlink("../nowhere", "dangling").unwrap();
    fx.dir("subdir").unwrap();
    fx.raw_name(".", b"caf\xc3\xa9 \xe2\x82\xac.bin", 1024)
        .unwrap();
    set_flags(&fx.path().join("dense.bin"), DENSE_FLAGS);
    write_corpus("mixed", fx.path());
}
