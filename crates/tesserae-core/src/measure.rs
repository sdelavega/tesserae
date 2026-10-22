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

//! One-path size measurement through the scanner's attribute parser and sizing rule.
use std::os::unix::ffi::OsStrExt;
use std::{ffi::CString, io, path::Path};

/// Returns (allocated, logical), without following the selected symlink.
pub fn measure_allocated(path: &Path) -> io::Result<(u64, u64)> {
    let name = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let mut attrs = crate::attrs::scan_attrlist();
    let mut buffer = [0u8; 8192];
    crate::boundary::retry_eintr(|| {
        // SAFETY: the request and output buffer are live for the syscall.
        if unsafe {
            libc::getattrlist(
                name.as_ptr(),
                (&mut attrs as *mut libc::attrlist).cast(),
                buffer.as_mut_ptr().cast(),
                buffer.len(),
                crate::attrs::SCAN_OPTIONS as u32,
            )
        } == 0
        {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    })?;
    let e = crate::parse::entries(&buffer, 1)
        .next()
        .ok_or_else(|| io::Error::from_raw_os_error(libc::EIO))?
        .map_err(|_| io::Error::from_raw_os_error(libc::EIO))?;
    // O_SYMLINK opens the link itself so volume lookup cannot follow its target.
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_SYMLINK | libc::O_NONBLOCK)
        .open(path)?;
    let sizing = crate::boundary::volume_info(file.as_raw_fd())?.sizing;
    Ok((
        sizing.allocated(e.obj_type, e.logical, e.allocated),
        e.logical,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::macos::fs::MetadataExt as DarwinMetadataExt;
    use std::os::unix::fs::MetadataExt;
    use std::process::Command;
    use tesserae_testutil::Fixture;
    #[test]
    fn measure_matches_scan_engine_for_compressed_and_plain_files() {
        let f = Fixture::new().unwrap();
        fs::write(f.path().join("source"), vec![b'a'; 1000]).unwrap();
        f.dir("empty").unwrap();
        std::os::unix::fs::symlink("absent", f.path().join("link")).unwrap();
        let compressed = f.path().join("compressed");
        assert!(Command::new("/usr/bin/ditto")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .arg("--hfsCompression")
            .arg(f.path().join("source"))
            .arg(&compressed)
            .status()
            .unwrap()
            .success());
        let flags = fs::symlink_metadata(&compressed).unwrap().st_flags();
        eprintln!("ditto flags={flags:#x}");
        if flags & libc::UF_COMPRESSED == 0 {
            assert!(Command::new(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../apple/build/applesauce"
            ))
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .args(["compress", "--verify", "-c", "lzfse", "--"])
            .arg(&compressed)
            .status()
            .unwrap()
            .success());
        }
        let meta = fs::symlink_metadata(&compressed).unwrap();
        eprintln!(
            "compressed flags={:#x} blocks={} logical={}",
            meta.st_flags(),
            meta.blocks(),
            meta.len()
        );
        assert_ne!(
            meta.st_flags() & libc::UF_COMPRESSED,
            0,
            "compression precondition"
        );
        assert_eq!(meta.blocks(), 0, "inline decmpfs precondition");
        let (arena, stats) = crate::walk::walk_serial(&crate::walk::WalkOptions {
            root: f.path().to_owned(),
            ..Default::default()
        })
        .unwrap();
        assert_eq!(stats.errors, 0);
        for name in [b"source".as_slice(), b"compressed", b"empty", b"link"] {
            let node = arena
                .iter()
                .map(|(_, n)| n)
                .find(|n| arena.name_bytes(n.name) == name)
                .unwrap();
            let measured =
                measure_allocated(&f.path().join(std::ffi::OsStr::from_bytes(name))).unwrap();
            assert_eq!(measured, (node.allocated, node.logical));
            assert!(name != b"compressed" || measured.0 < measured.1);
        }
    }
    use std::os::unix::ffi::OsStrExt;
}
