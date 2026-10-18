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

//! Golden-corpus capture: record real `getattrlistbulk` buffers to disk.
//!
//! Run with `cargo test -p tesserae-core --test golden_capture -- --ignored`.
//! Ignored by default because it rewrites committed fixtures; the parser's own
//! tests replay them and must not depend on the machine they run on.
//!
//! Two files are written per corpus:
//!
//! * `golden_<name>.bin` — the raw kernel bytes, preceded by a 16-byte header
//!   (`TSRGOLD1`, entry count u32-LE, buffer length u32-LE). Nothing in this
//!   file is parsed on the way in: the bytes are copied verbatim out of the
//!   syscall's output buffer, so a parser bug cannot be baked into it.
//!
//! * `golden_<name>.expect` — the same tree's attributes read back through
//!   `lstat(2)`, an independent source of truth. The parser test cross-checks
//!   its output against this, so agreeing with the golden buffer is not enough:
//!   it must also agree with the kernel's other interface to the same metadata.
//!
//! Note on `d_alloc`: a directory's `getattrlistbulk` entry carries no
//! `fileattr` group at all (see `parse.rs`), so the expectation records `0` for
//! directories rather than `lstat`'s `st_blocks`.

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
fn capture(dir: &Path) -> Capture {
    let c_dir = CString::new(dir.as_os_str().as_bytes()).unwrap();
    // SAFETY: `c_dir` is a live NUL-terminated string.
    let fd = unsafe { libc::open(c_dir.as_ptr(), libc::O_RDONLY) };
    assert!(fd >= 0, "open {}: {}", dir.display(), last_error());

    let mut attrlist = scan_attrlist();
    let mut buf = vec![0u8; BUF_LEN];
    // SAFETY: `attrlist` and `buf` are live and `buf.len()` is its true size.
    let count = unsafe {
        libc::getattrlistbulk(
            fd,
            (&mut attrlist as *mut libc::attrlist).cast(),
            buf.as_mut_ptr().cast(),
            buf.len(),
            SCAN_OPTIONS,
        )
    };
    // SAFETY: `fd` is owned by this function and not used again.
    unsafe { libc::close(fd) };
    assert!(count >= 0, "getattrlistbulk: {}", last_error());
    assert!(count > 0, "{} produced no entries", dir.display());

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

fn write_corpus(name: &str, dir: &Path) {
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
                "{}\t{}\t{}\t{}\t{}\t{}\t{}",
                hex(entry.file_name().as_bytes()),
                kind,
                st.st_ino,
                st.st_dev,
                nlink,
                logical,
                allocated,
            )
        })
        .collect();
    rows.sort();

    let mut f = fs::File::create(out.join(format!("golden_{name}.expect"))).unwrap();
    writeln!(f, "# name_hex\tkind\tino\tdev\tnlink\tlogical\tallocated").unwrap();
    writeln!(f, "# from lstat(2); nlink/logical/allocated are 0 for dirs").unwrap();
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
    write_corpus("mixed", fx.path());
}
