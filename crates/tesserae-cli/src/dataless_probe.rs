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

//! Metadata-only developer probe; production scan policy is unchanged.

use std::ffi::{CString, OsStr};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::ExitCode;
use std::time::Instant;
use tesserae_core::attrs::{scan_attrlist, SCAN_OPTIONS};
use tesserae_core::parse::{entries, ObjType};

use tesserae_core::dataless::{is_dataless, no_materialize as set_no_materialize, SF_DATALESS};

// Names and numbers read from the same SDK's sys/errno.h. Keep unknown
// future errnos numeric too, rather than mislabelling them.
fn errno_name(errno: i32) -> &'static str {
    match errno {
        1 => "EPERM",
        2 => "ENOENT",
        3 => "ESRCH",
        4 => "EINTR",
        5 => "EIO",
        6 => "ENXIO",
        7 => "E2BIG",
        8 => "ENOEXEC",
        9 => "EBADF",
        10 => "ECHILD",
        11 => "EDEADLK",
        12 => "ENOMEM",
        13 => "EACCES",
        14 => "EFAULT",
        15 => "ENOTBLK",
        16 => "EBUSY",
        17 => "EEXIST",
        18 => "EXDEV",
        19 => "ENODEV",
        20 => "ENOTDIR",
        21 => "EISDIR",
        22 => "EINVAL",
        23 => "ENFILE",
        24 => "EMFILE",
        25 => "ENOTTY",
        26 => "ETXTBSY",
        27 => "EFBIG",
        28 => "ENOSPC",
        29 => "ESPIPE",
        30 => "EROFS",
        31 => "EMLINK",
        32 => "EPIPE",
        33 => "EDOM",
        34 => "ERANGE",
        35 => "EAGAIN",
        36 => "EINPROGRESS",
        37 => "EALREADY",
        38 => "ENOTSOCK",
        39 => "EDESTADDRREQ",
        40 => "EMSGSIZE",
        41 => "EPROTOTYPE",
        42 => "ENOPROTOOPT",
        43 => "EPROTONOSUPPORT",
        44 => "ESOCKTNOSUPPORT",
        45 => "ENOTSUP",
        46 => "EPFNOSUPPORT",
        47 => "EAFNOSUPPORT",
        48 => "EADDRINUSE",
        49 => "EADDRNOTAVAIL",
        50 => "ENETDOWN",
        51 => "ENETUNREACH",
        52 => "ENETRESET",
        53 => "ECONNABORTED",
        54 => "ECONNRESET",
        55 => "ENOBUFS",
        56 => "EISCONN",
        57 => "ENOTCONN",
        58 => "ESHUTDOWN",
        59 => "ETOOMANYREFS",
        60 => "ETIMEDOUT",
        61 => "ECONNREFUSED",
        62 => "ELOOP",
        63 => "ENAMETOOLONG",
        64 => "EHOSTDOWN",
        65 => "EHOSTUNREACH",
        66 => "ENOTEMPTY",
        67 => "EPROCLIM",
        68 => "EUSERS",
        69 => "EDQUOT",
        70 => "ESTALE",
        71 => "EREMOTE",
        72 => "EBADRPC",
        73 => "ERPCMISMATCH",
        74 => "EPROGUNAVAIL",
        75 => "EPROGMISMATCH",
        76 => "EPROCUNAVAIL",
        77 => "ENOLCK",
        78 => "ENOSYS",
        79 => "EFTYPE",
        80 => "EAUTH",
        81 => "ENEEDAUTH",
        82 => "EPWROFF",
        83 => "EDEVERR",
        84 => "EOVERFLOW",
        85 => "EBADEXEC",
        86 => "EBADARCH",
        87 => "ESHLIBVERS",
        88 => "EBADMACHO",
        89 => "ECANCELED",
        90 => "EIDRM",
        91 => "ENOMSG",
        92 => "EILSEQ",
        93 => "ENOATTR",
        94 => "EBADMSG",
        95 => "EMULTIHOP",
        96 => "ENODATA",
        97 => "ENOLINK",
        98 => "ENOSR",
        99 => "ENOSTR",
        100 => "EPROTO",
        101 => "ETIME",
        102 => "EOPNOTSUPP",
        103 => "ENOPOLICY",
        104 => "ENOTRECOVERABLE",
        105 => "EOWNERDEAD",
        106 => "EQFULL",
        107 => "ENOTCAPABLE",
        _ => "UNKNOWN_ERRNO",
    }
}

#[derive(Default)]
struct Totals {
    entries: u64,
    directories: u64,
    files: u64,
    other: u64,
    dataless: u64,
    logical: u128,
    allocated: u128,
    errors: u64,
}

fn note_error(rel: &Path, operation: &str, error: io::Error, totals: &mut Totals) {
    totals.errors += 1;
    let errno = error.raw_os_error().unwrap_or(libc::EINVAL);
    println!(
        "directory={rel:?} operation={operation} errno={errno}({}) message={error}",
        errno_name(errno)
    );
}

fn open_dir(parent: RawFd, name: &[u8]) -> io::Result<OwnedFd> {
    let name = CString::new(name).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    // SAFETY: name is NUL-terminated. Only directory descriptors are opened;
    // O_NOFOLLOW prevents descent through a symlink swapped in after enumeration.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    }
    // SAFETY: openat returned a new descriptor, owned only here.
    else {
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

fn visit(dir: OwnedFd, rel: &Path, buf: &mut [u8], totals: &mut Totals) {
    println!("directory={rel:?} operation=open ok");
    let mut request = scan_attrlist();
    let mut children = Vec::new();
    let mut count = 0u64;
    loop {
        // SAFETY: request is the engine's attribute list; buf is writable
        // for its advertised length. No file descriptor here names a file.
        let n = unsafe {
            libc::getattrlistbulk(
                dir.as_raw_fd(),
                (&mut request as *mut libc::attrlist).cast(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                SCAN_OPTIONS,
            )
        };
        if n < 0 {
            let error = io::Error::last_os_error();
            let interrupted = error.raw_os_error() == Some(libc::EINTR);
            note_error(rel, "enumerate", error, totals);
            if interrupted {
                continue;
            }
            break;
        }
        if n == 0 {
            println!("directory={rel:?} operation=enumerate ok entries={count}");
            break;
        }
        for entry in entries(buf, n as u32) {
            let e = match entry {
                Ok(e) => e,
                Err(error) => {
                    totals.errors += 1;
                    println!("directory={rel:?} operation=parse error={error:?}");
                    break;
                }
            };
            let path = rel.join(OsStr::from_bytes(e.name));
            let kind = match e.obj_type {
                ObjType::Dir => {
                    totals.directories += 1;
                    "directory"
                }
                ObjType::Reg => {
                    totals.files += 1;
                    "file"
                }
                ObjType::Lnk => {
                    totals.other += 1;
                    "symlink"
                }
                ObjType::Other => {
                    totals.other += 1;
                    "other"
                }
            };
            let dataless = is_dataless(e.flags);
            println!("entry path={path:?} type={kind} flags={:#010x} dataless={dataless} logical={} allocated={}",
                e.flags, e.logical, e.allocated);
            count += 1;
            totals.entries += 1;
            totals.dataless += u64::from(dataless);
            totals.logical += u128::from(e.logical);
            totals.allocated += u128::from(e.allocated);
            if e.obj_type == ObjType::Dir {
                children.push(e.name.to_vec());
            }
        }
    }
    // Buffer reuse is safe after the parent's batch has been fully consumed.
    // Intentionally attempt dataless directories: Step 1 measures what happens.
    for name in children {
        let child_rel = rel.join(OsStr::from_bytes(&name));
        match open_dir(dir.as_raw_fd(), &name) {
            Ok(fd) => visit(fd, &child_rel, buf, totals),
            Err(error) => note_error(&child_rel, "open", error, totals),
        }
    }
}

pub(super) fn run(path: &Path, no_materialize: bool) -> ExitCode {
    let started = Instant::now();
    let mut totals = Totals::default();
    println!("root={path:?} SF_DATALESS={SF_DATALESS:#010x}");
    if no_materialize {
        if let Err(error) = set_no_materialize() {
            note_error(Path::new("."), "setiopolicy_np", error, &mut totals);
            println!("policy=no-materialize scope=thread success=false");
        } else {
            println!("policy=no-materialize scope=thread success=true");
        }
    } else {
        println!("policy=default unchanged");
    }
    let mut buf = vec![0u8; 256 * 1024];
    match open_dir(libc::AT_FDCWD, path.as_os_str().as_bytes()) {
        Ok(fd) => visit(fd, Path::new("."), &mut buf, &mut totals),
        Err(error) => note_error(Path::new("."), "open", error, &mut totals),
    }
    println!("totals entries={} directories={} files={} other={} dataless={} logical={} allocated={} errors={} wall_secs={:.6} (root excluded; directory sizes are bulk values)",
        totals.entries, totals.directories, totals.files, totals.other, totals.dataless,
        totals.logical, totals.allocated, totals.errors, started.elapsed().as_secs_f64());
    if totals.errors == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tesserae_core::attrs::{COMMON_MASK, FILE_MASK};
    use tesserae_core::parse::entries;

    #[test]
    fn synthetic_bulk_flags_preserve_and_detect_dataless() {
        // The engine's measured file shape: 88 fixed bytes + name + padding.
        let mut buf = vec![0u8; 96];
        buf[0..4].copy_from_slice(&96u32.to_le_bytes());
        buf[4..8].copy_from_slice(&COMMON_MASK.to_le_bytes());
        buf[16..20].copy_from_slice(&FILE_MASK.to_le_bytes());
        buf[24..28].copy_from_slice(&64i32.to_le_bytes());
        buf[28..32].copy_from_slice(&5u32.to_le_bytes());
        buf[36..40].copy_from_slice(&1u32.to_le_bytes()); // VREG, engine layout
        buf[72..80].copy_from_slice(&4096u64.to_le_bytes());
        buf[80..88].copy_from_slice(&1048576u64.to_le_bytes());
        buf[88..93].copy_from_slice(b"file\0");
        for (flags, expected) in [
            (0u32, false),
            (0x8000, false),
            (0x40000000, true),
            (0x40008000, true),
        ] {
            buf[56..60].copy_from_slice(&flags.to_le_bytes());
            let e = entries(&buf, 1)
                .next()
                .expect("precondition: one entry")
                .unwrap();
            assert_eq!(e.name, b"file");
            assert_eq!((e.logical, e.allocated), (1048576, 4096));
            assert_eq!(e.flags, flags);
            assert_eq!(is_dataless(e.flags), expected);
        }
        // A packed invalid flags slot must not become a real dataless flag.
        buf[4..8].copy_from_slice(&(COMMON_MASK & !libc::ATTR_CMN_FLAGS).to_le_bytes());
        let e = entries(&buf, 1).next().unwrap().unwrap();
        assert_eq!(e.flags, 0);
        assert!(!is_dataless(e.flags));
        assert_eq!(SF_DATALESS, 0x40000000);
    }
}
