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

//! Read-only manifest comparison; file contents are hashed in bounded chunks.
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{CStr, CString};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::macos::fs::MetadataExt as _;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum ArchiveError {
    MissingEntry = 1,
    ExtraEntry = 2,
    SizeMismatch = 3,
    DigestMismatch = 4,
    TypeMismatch = 5,
    LinkMismatch = 6,
    UnreadableOriginal = 7,
    CorruptArchive = 8,
    Io = 9,
    DuplicateEntry = 10,
}
#[derive(Debug, Default)]
pub struct ArchiveReport {
    pub files: u64,
    pub dirs: u64,
    pub links: u64,
    pub bytes: u64,
}
#[derive(Debug)]
pub struct Failure {
    pub code: ArchiveError,
    pub path: Vec<u8>,
}
fn failure(code: ArchiveError, path: &[u8]) -> Failure {
    Failure {
        code,
        path: path.to_vec(),
    }
}
#[derive(Debug, PartialEq)]
enum Content {
    File(u64, [u8; 32]),
    Dir,
    Link(Vec<u8>),
}
fn hash(reader: &mut impl Read) -> io::Result<(u64, [u8; 32])> {
    let mut digest = Sha256::new();
    let mut count = 0;
    let mut buffer = [0; 65536];
    loop {
        let n = match reader.read(&mut buffer) {
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            r => r?,
        };
        if n == 0 {
            break;
        }
        digest.update(&buffer[..n]);
        count += n as u64;
    }
    Ok((count, digest.finalize().into()))
}
fn metadata_path(path: &[u8]) -> bool {
    path.rsplit(|&b| b == b'/')
        .next()
        .is_some_and(|c| c.starts_with(b"._"))
        || path.split(|&b| b == b'/').any(|c| c == b"__MACOSX")
}
// Fold only for the metadata collision guard; matching stays byte-exact.
// Preserve invalid UTF-8 bytes rather than conflating them with U+FFFD.
fn collision_key(path: &[u8]) -> Vec<u8> {
    let mut key = Vec::new();
    for chunk in path.utf8_chunks() {
        let normalized: String = chunk.valid().nfd().collect();
        key.extend(normalized.bytes().map(|b| b.to_ascii_lowercase()));
        key.extend_from_slice(chunk.invalid());
    }
    key
}
struct EntryPaths {
    seen: BTreeSet<Vec<u8>>,
    collisions: BTreeSet<Vec<u8>>,
    excluded: BTreeSet<Vec<u8>>,
    excluded_collisions: BTreeSet<Vec<u8>>,
}
impl EntryPaths {
    fn new(manifest: &BTreeMap<Vec<u8>, Content>, excluded: &BTreeSet<Vec<u8>>) -> Self {
        Self {
            seen: BTreeSet::new(),
            excluded: excluded.clone(),
            excluded_collisions: excluded.iter().map(|p| collision_key(p)).collect(),
            // Retain all originals even after compare() consumes them.
            collisions: manifest.keys().map(|p| collision_key(p)).collect(),
        }
    }
    fn check(&mut self, path: &[u8], matched: bool) -> Result<(), Failure> {
        if !self.seen.insert(path.to_vec()) {
            return Err(failure(ArchiveError::DuplicateEntry, path));
        }
        let key = collision_key(path);
        if (!self.excluded.contains(path) && self.excluded_collisions.contains(&key))
            || (!matched && metadata_path(path) && self.collisions.contains(&key))
        {
            return Err(failure(ArchiveError::ExtraEntry, path));
        }
        self.collisions.insert(key);
        Ok(())
    }
}
fn entry_path(raw: &[u8]) -> Result<Vec<u8>, Failure> {
    if raw.starts_with(b"/") || raw.contains(&0) || raw.split(|&b| b == b'/').any(|c| c == b"..") {
        return Err(failure(ArchiveError::CorruptArchive, raw));
    }
    let parts: Vec<_> = raw
        .split(|&b| b == b'/')
        .filter(|c| !c.is_empty() && *c != b".")
        .collect();
    if parts.is_empty() {
        return Err(failure(ArchiveError::CorruptArchive, raw));
    }
    Ok(parts.join(&b'/'))
}
fn open_at(parent: i32, name: &CStr, directory: bool) -> io::Result<File> {
    let flags = libc::O_RDONLY
        | libc::O_CLOEXEC
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | if directory { libc::O_DIRECTORY } else { 0 };
    crate::boundary::retry_eintr(|| {
        // SAFETY: name is NUL-terminated; a successful open transfers ownership.
        let fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    })
}
fn stat_at(parent: i32, name: &CStr) -> io::Result<libc::stat> {
    // SAFETY: the syscall initialises stat on success, and name is live.
    unsafe {
        let mut st = std::mem::zeroed();
        crate::boundary::retry_eintr(|| {
            if libc::fstatat(parent, name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        })?;
        Ok(st)
    }
}
// Slice the original C string, retaining its terminator and every filename byte.
// Filesystem names must never pass through display escaping or lossy UTF-8.
fn sidecar_sibling(name: &CStr) -> Option<&CStr> {
    let bytes = name.to_bytes_with_nul();
    if !bytes.starts_with(b"._") || bytes.len() <= 3 {
        return None;
    }
    CStr::from_bytes_with_nul(&bytes[2..]).ok()
}
struct Sidecars {
    flags: u32,
    excluded: BTreeSet<Vec<u8>>,
}
fn sidecar_stamp_matches(metadata: &std::fs::Metadata, st: &libc::stat) -> bool {
    metadata.dev() == st.st_dev as u64
        && metadata.ino() == st.st_ino
        && metadata.mode() == st.st_mode as u32
        && metadata.len() == st.st_size as u64
        && metadata.nlink() == st.st_nlink as u64
        && metadata.st_flags() == st.st_flags
        && metadata.mtime() == st.st_mtime
        && metadata.mtime_nsec() == st.st_mtime_nsec
        && metadata.ctime() == st.st_ctime
        && metadata.ctime_nsec() == st.st_ctime_nsec
}
fn paired_sidecar(parent: i32, name: &CStr, st: &libc::stat) -> io::Result<bool> {
    if st.st_mode & libc::S_IFMT != libc::S_IFREG
        || !(24..=16 * 1024 * 1024).contains(&st.st_size)
        || st.st_flags & libc::UF_HIDDEN == 0
    {
        return Ok(false);
    }
    let Some(sibling) = sidecar_sibling(name) else {
        return Ok(false);
    };
    match stat_at(parent, sibling) {
        // Sibling existence includes directories and dangling symlinks.
        Ok(_) => {}
        Err(e) if e.raw_os_error() == Some(libc::ENOENT) => return Ok(false),
        Err(e) => return Err(e),
    }
    let mut file = open_at(parent, name, false)?;
    if !sidecar_stamp_matches(&file.metadata()?, st) {
        return Err(io::Error::from_raw_os_error(libc::ESTALE));
    }
    let mut header = [0; 24];
    file.read_exact(&mut header)?;
    let after = file.metadata()?;
    if !sidecar_stamp_matches(&after, st) || !sidecar_stamp_matches(&after, &stat_at(parent, name)?)
    {
        return Err(io::Error::from_raw_os_error(libc::ESTALE));
    }
    // Big-endian magic and version, then the measured macOS or spec filler.
    Ok(header[..8] == *b"\0\x05\x16\x07\0\x02\0\0"
        && (header[8..] == *b"Mac OS X        " || header[8..] == [0; 16]))
}
fn original(
    parent: i32,
    name: &CStr,
    path: Vec<u8>,
    dev: i32,
    depth: usize,
    sidecars: &mut Sidecars,
    manifest: &mut BTreeMap<Vec<u8>, Content>,
) -> Result<(), Failure> {
    use ArchiveError::UnreadableOriginal as Bad;
    let bad = || failure(Bad, &path);
    if depth > 256 {
        return Err(bad());
    }
    let st = stat_at(parent, name).map_err(|_| bad())?;
    if st.st_dev != dev || crate::dataless::is_dataless(st.st_flags) {
        return Err(bad());
    }
    if sidecars.flags & SIDECARS_ARE_METADATA != 0
        && paired_sidecar(parent, name, &st).map_err(|_| bad())?
    {
        sidecars.excluded.insert(path);
        return Ok(());
    }
    let kind = st.st_mode & libc::S_IFMT;
    let content = if kind == libc::S_IFLNK {
        let mut target = vec![0; 65536];
        // SAFETY: output buffer is writable and name is NUL-terminated.
        let n = unsafe {
            libc::readlinkat(
                parent,
                name.as_ptr(),
                target.as_mut_ptr().cast(),
                target.len(),
            )
        };
        if n < 0 || n as usize == target.len() {
            return Err(bad());
        }
        target.truncate(n as usize);
        Content::Link(target)
    } else if kind == libc::S_IFREG || kind == libc::S_IFDIR {
        let mut file = open_at(parent, name, kind == libc::S_IFDIR).map_err(|_| bad())?;
        let before = file.metadata().map_err(|_| bad())?;
        if before.dev() != dev as u64
            || before.ino() != st.st_ino
            || before.mode() & libc::S_IFMT as u32 != kind as u32
        {
            return Err(bad());
        }
        if kind == libc::S_IFDIR {
            // fdopendir owns only the duplicate; the original anchors all child opens.
            struct Directory(*mut libc::DIR);
            impl Drop for Directory {
                fn drop(&mut self) {
                    unsafe {
                        libc::closedir(self.0);
                    }
                }
            }
            let fd = unsafe { libc::dup(file.as_raw_fd()) };
            if fd < 0 {
                return Err(bad());
            }
            let dir = unsafe { libc::fdopendir(fd) };
            if dir.is_null() {
                unsafe { libc::close(fd) };
                return Err(bad());
            }
            let dir = Directory(dir);
            loop {
                // SAFETY: dir is live; errno distinguishes EOF from a failed read.
                unsafe {
                    *libc::__error() = 0;
                }
                let entry = unsafe { libc::readdir(dir.0) };
                if entry.is_null() {
                    if io::Error::last_os_error().raw_os_error() != Some(0) {
                        return Err(bad());
                    }
                    break;
                }
                let child = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_owned();
                if matches!(child.to_bytes(), b"." | b"..") {
                    continue;
                }
                let mut rel = path.clone();
                rel.push(b'/');
                rel.extend_from_slice(child.to_bytes());
                original(
                    file.as_raw_fd(),
                    &child,
                    rel,
                    dev,
                    depth + 1,
                    sidecars,
                    manifest,
                )?;
            }
            Content::Dir
        } else {
            let (size, digest) = hash(&mut file).map_err(|_| bad())?;
            let after = file.metadata().map_err(|_| bad())?;
            if size != before.len()
                || after.len() != before.len()
                || after.mtime() != before.mtime()
                || after.mtime_nsec() != before.mtime_nsec()
                || after.ctime() != before.ctime()
                || after.ctime_nsec() != before.ctime_nsec()
            {
                return Err(bad());
            }
            Content::File(size, digest)
        }
    } else {
        return Err(bad());
    };
    manifest.insert(path, content);
    Ok(())
}
fn compare(
    path: &[u8],
    content: Content,
    manifest: &mut BTreeMap<Vec<u8>, Content>,
) -> Result<(), Failure> {
    let Some(want) = manifest.remove(path) else {
        return Err(failure(ArchiveError::ExtraEntry, path));
    };
    let code = match (&want, &content) {
        (Content::File(a, _), Content::File(b, _)) if a != b => Some(ArchiveError::SizeMismatch),
        (Content::File(..), Content::File(..)) if want != content => {
            Some(ArchiveError::DigestMismatch)
        }
        (Content::Link(a), Content::Link(b)) if a != b => Some(ArchiveError::LinkMismatch),
        _ if std::mem::discriminant(&want) != std::mem::discriminant(&content) => {
            Some(ArchiveError::TypeMismatch)
        }
        _ => None,
    };
    code.map_or(Ok(()), |c| Err(failure(c, path)))
}
fn tar_entries(
    reader: impl Read,
    manifest: &mut BTreeMap<Vec<u8>, Content>,
    excluded: &BTreeSet<Vec<u8>>,
) -> Result<(), Failure> {
    let corrupt = || failure(ArchiveError::CorruptArchive, &[]);
    struct TarReader<R> {
        inner: R,
        zero_tail: usize,
        eof: bool,
    }
    impl<R: Read> Read for TarReader<R> {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let n = self.inner.read(buffer)?;
            if !buffer.is_empty() {
                self.eof = n == 0;
                let zeros = buffer[..n].iter().rev().take_while(|&&b| b == 0).count();
                self.zero_tail = if zeros == n {
                    self.zero_tail.saturating_add(zeros)
                } else {
                    zeros
                };
            }
            Ok(n)
        }
    }
    let mut archive = tar::Archive::new(TarReader {
        inner: reader,
        zero_tail: 0,
        eof: false,
    });
    // A hardlink must name content already verified in this archive. Using
    // the original manifest here would accept links to themselves or cycles.
    let mut files = BTreeMap::new();
    let mut paths = EntryPaths::new(manifest, excluded);
    for entry in archive.entries().map_err(|_| corrupt())? {
        let mut entry = entry.map_err(|_| corrupt())?;
        let path = entry_path(&entry.path_bytes())?;
        let matched = manifest.contains_key(&path);
        paths.check(&path, matched)?;
        if !matched {
            if metadata_path(&path) {
                io::copy(&mut entry, &mut io::sink()).map_err(|_| corrupt())?;
                continue;
            }
            return Err(failure(ArchiveError::ExtraEntry, &path));
        }
        let kind = entry.header().entry_type();
        let content = if kind.is_dir() {
            Content::Dir
        } else if kind.is_symlink() {
            Content::Link(entry.link_name_bytes().ok_or_else(corrupt)?.into_owned())
        } else if kind.is_hard_link() {
            let target = entry_path(&entry.link_name_bytes().ok_or_else(corrupt)?)?;
            let (n, h) = files.get(&target).ok_or_else(corrupt)?;
            Content::File(*n, *h)
        } else if kind.is_file() {
            let (n, h) = hash(&mut entry).map_err(|_| corrupt())?;
            Content::File(n, h)
        } else {
            return Err(failure(ArchiveError::TypeMismatch, &path));
        };
        if let Content::File(n, h) = &content {
            files.insert(path.clone(), (*n, *h));
        }
        compare(&path, content, manifest)?;
    }
    // tar accepts bare EOF and stops after a single zero header. Require
    // both end blocks and only zero padding afterwards, while also consuming
    // the compression footer. A second hidden tar stream must fail closed.
    let mut reader = archive.into_inner();
    if reader.eof || reader.zero_tail < 512 {
        return Err(corrupt());
    }
    let mut buffer = [0; 65536];
    let mut padding = 0u64;
    loop {
        let n = reader.read(&mut buffer).map_err(|_| corrupt())?;
        if n == 0 {
            break;
        }
        if buffer[..n].iter().any(|&b| b != 0) {
            return Err(corrupt());
        }
        padding += n as u64;
    }
    if padding < 512 || !padding.is_multiple_of(512) {
        return Err(corrupt());
    }
    Ok(())
}
fn zip_entries(
    mut reader: impl Read + io::Seek,
    manifest: &mut BTreeMap<Vec<u8>, Content>,
    excluded: &BTreeSet<Vec<u8>>,
) -> Result<(), Failure> {
    let corrupt = || failure(ArchiveError::CorruptArchive, &[]);
    // Check local names as well as central-directory names. ZIP readers use
    // the central directory for matching; a conflicting local name must not
    // conceal traversal or an absolute path in an otherwise valid archive.
    let headers = {
        let mut zip = zip::ZipArchive::new(&mut reader).map_err(|_| corrupt())?;
        let mut headers = Vec::new();
        for i in 0..zip.len() {
            let entry = zip.by_index_raw(i).map_err(|_| corrupt())?;
            headers.push((entry.header_start(), entry.name_raw().to_vec()));
        }
        headers
    };
    for (offset, name) in headers {
        reader
            .seek(io::SeekFrom::Start(offset))
            .map_err(|_| corrupt())?;
        let mut header = [0; 30];
        reader.read_exact(&mut header).map_err(|_| corrupt())?;
        if &header[..4] != b"PK\x03\x04" {
            return Err(corrupt());
        }
        let mut local = vec![0; u16::from_le_bytes([header[26], header[27]]) as usize];
        reader.read_exact(&mut local).map_err(|_| corrupt())?;
        entry_path(&local)?;
        if local != name {
            return Err(corrupt());
        }
    }
    let mut zip = zip::ZipArchive::new(reader).map_err(|_| corrupt())?;
    let mut paths = EntryPaths::new(manifest, excluded);
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|_| corrupt())?;
        let path = entry_path(entry.name_raw())?;
        let matched = manifest.contains_key(&path);
        paths.check(&path, matched)?;
        if !matched {
            if metadata_path(&path) {
                io::copy(&mut entry, &mut io::sink()).map_err(|_| corrupt())?;
                continue;
            }
            return Err(failure(ArchiveError::ExtraEntry, &path));
        }
        let content = if entry.is_dir() {
            Content::Dir
        } else if entry
            .unix_mode()
            .is_some_and(|m| m & libc::S_IFMT as u32 == libc::S_IFLNK as u32)
        {
            let mut bytes = Vec::new();
            (&mut entry)
                .take(65537)
                .read_to_end(&mut bytes)
                .map_err(|_| corrupt())?;
            if bytes.len() > 65536 {
                return Err(corrupt());
            }
            Content::Link(bytes)
        } else {
            if entry.unix_mode().is_some_and(|m| {
                m & libc::S_IFMT as u32 != 0 && m & libc::S_IFMT as u32 != libc::S_IFREG as u32
            }) {
                return Err(failure(ArchiveError::TypeMismatch, &path));
            }
            let (n, h) = hash(&mut entry).map_err(|_| corrupt())?;
            Content::File(n, h)
        };
        compare(&path, content, manifest)?;
    }
    Ok(())
}

/// Treat hidden, paired regular files with the full AppleDouble v2
/// header, up to 16 MiB, as metadata on known non-native-xattr volumes.
pub const SIDECARS_ARE_METADATA: u32 = 1;

pub fn verify_with_flags(
    archive: &Path,
    format: u32,
    item: &Path,
    flags: u32,
) -> Result<ArchiveReport, Failure> {
    let bad = || {
        failure(
            ArchiveError::UnreadableOriginal,
            item.as_os_str().as_bytes(),
        )
    };
    let name = CString::new(item.file_name().ok_or_else(bad)?.as_bytes()).map_err(|_| bad())?;
    let parent = File::open(
        item.parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new(".")),
    )
    .map_err(|_| bad())?;
    let st = stat_at(parent.as_raw_fd(), &name).map_err(|_| bad())?;
    let mut manifest = BTreeMap::new();
    let mut sidecars = Sidecars {
        flags,
        excluded: BTreeSet::new(),
    };
    original(
        parent.as_raw_fd(),
        &name,
        name.to_bytes().to_vec(),
        st.st_dev,
        0,
        &mut sidecars,
        &mut manifest,
    )?;
    let mut report = ArchiveReport::default();
    for content in manifest.values() {
        match content {
            Content::File(n, _) => {
                report.files += 1;
                report.bytes += n;
            }
            Content::Dir => report.dirs += 1,
            Content::Link(_) => report.links += 1,
        }
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(archive)
        .map_err(|_| failure(ArchiveError::Io, archive.as_os_str().as_bytes()))?;
    if !file
        .metadata()
        .map_err(|_| failure(ArchiveError::Io, &[]))?
        .is_file()
    {
        return Err(failure(ArchiveError::Io, &[]));
    }
    let corrupt = || failure(ArchiveError::CorruptArchive, &[]);
    match format {
        0 => zip_entries(file, &mut manifest, &sidecars.excluded)?,
        1 => tar_entries(
            xz2::read::XzDecoder::new_multi_decoder(file),
            &mut manifest,
            &sidecars.excluded,
        )?,
        2 => tar_entries(
            zstd::stream::read::Decoder::new(file).map_err(|_| corrupt())?,
            &mut manifest,
            &sidecars.excluded,
        )?,
        _ => return Err(corrupt()),
    }
    if let Some(path) = manifest.keys().next() {
        return Err(failure(ArchiveError::MissingEntry, path));
    }
    Ok(report)
}
/// Verify every original relative to its parent; only unmatched metadata members are ignored.
pub fn verify(archive: &Path, format: u32, item: &Path) -> Result<ArchiveReport, Failure> {
    verify_with_flags(archive, format, item, 0)
}
/// Encode between borrowed descriptors. Neither descriptor is duplicated or closed.
pub fn zstd_stream(in_fd: i32, out_fd: i32, level: i32) -> io::Result<u64> {
    struct Borrowed(i32);
    impl Read for Borrowed {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            crate::boundary::retry_eintr(|| {
                let n = unsafe { libc::read(self.0, buf.as_mut_ptr().cast(), buf.len()) };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            })
        }
    }
    struct Output {
        fd: i32,
        bytes: u64,
    }
    impl Write for Output {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            let n = crate::boundary::retry_eintr(|| {
                let n = unsafe { libc::write(self.fd, buf.as_ptr().cast(), buf.len()) };
                if n < 0 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(n as usize)
                }
            })?;
            self.bytes += n as u64;
            Ok(n)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut encoder = zstd::stream::write::Encoder::new(
        Output {
            fd: out_fd,
            bytes: 0,
        },
        level,
    )?;
    io::copy(&mut Borrowed(in_fd), &mut encoder)?;
    Ok(encoder.finish()?.bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sidecar_sibling_preserves_raw_unusual_names() {
        let names = [
            b"tiny\nname".to_vec(),
            b"tab\tname".to_vec(),
            b"bad-\xff".to_vec(),
            b"bad-\xfe".to_vec(),
            "bad-\u{fffd}".as_bytes().to_vec(),
            b"-leading".to_vec(),
            vec![b'l'; 240],
        ];
        for name in names {
            let sidecar = CString::new([b"._".as_slice(), &name].concat()).unwrap();
            let sibling = sidecar_sibling(&sidecar).expect("paired spelling");
            assert_eq!(sibling.to_bytes(), name);
            assert_eq!(sibling.to_bytes_with_nul().last(), Some(&0));
            assert_eq!(collision_key(sibling.to_bytes()), name);
        }
        assert!(sidecar_sibling(c"._").is_none());
        assert!(sidecar_sibling(c"plain").is_none());
        assert_ne!(
            sidecar_sibling(c"._bad-\xff"),
            sidecar_sibling(c"._bad-\xfe")
        );
        assert_ne!(
            sidecar_sibling(c"._bad-\xff").unwrap().to_bytes(),
            "bad-\u{fffd}".as_bytes()
        );
    }
    #[test]
    fn matches_non_utf8_names_byte_exact() {
        use std::process::Command;
        let fixture = tesserae_testutil::Fixture::new().unwrap();
        fixture.file("item/name-x", 12).unwrap();
        let output = Command::new("/usr/bin/tar")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .args(["-c", "--format", "zip", "-f", "-", "-C"])
            .arg(fixture.path())
            .args(["--", "item"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let mut bytes = output.stdout;
        let offsets: Vec<_> = bytes
            .windows(11)
            .enumerate()
            .filter_map(|(i, w)| (w == b"item/name-x").then_some(i))
            .collect();
        assert_eq!(offsets.len(), 2, "local and central name precondition");
        for &i in &offsets {
            bytes[i + 10] = 0xff;
        }
        let data = std::fs::read(fixture.path().join("item/name-x")).unwrap();
        let (n, h) = hash(&mut &data[..]).unwrap();
        let make_manifest = || {
            BTreeMap::from([
                (b"item".to_vec(), Content::Dir),
                (b"item/name-\xff".to_vec(), Content::File(n, h)),
            ])
        };
        let mut expected = make_manifest();
        zip_entries(io::Cursor::new(&bytes), &mut expected, &BTreeSet::new()).unwrap();
        assert!(expected.is_empty());
        // Only the local header is now hostile; the central name remains valid.
        bytes[offsets[0]..offsets[0] + 3].copy_from_slice(b"../");
        assert_eq!(
            zip_entries(
                io::Cursor::new(bytes),
                &mut make_manifest(),
                &BTreeSet::new()
            )
            .unwrap_err()
            .code,
            ArchiveError::CorruptArchive
        );
        let path = b"item/name-\xff";
        assert_eq!(entry_path(path).unwrap(), path);
        let mut manifest = BTreeMap::from([(path.to_vec(), Content::Dir)]);
        assert_eq!(
            compare(b"item/name-\xfe", Content::Dir, &mut manifest)
                .unwrap_err()
                .code,
            ArchiveError::ExtraEntry
        );
        assert_eq!(
            compare("item/name-\u{fffd}".as_bytes(), Content::Dir, &mut manifest)
                .unwrap_err()
                .code,
            ArchiveError::ExtraEntry
        );
        compare(path, Content::Dir, &mut manifest).unwrap();
        assert!(manifest.is_empty());
    }
    #[test]
    fn unsafe_archive_paths_are_corrupt_even_when_metadata() {
        for path in [
            b"/item".as_slice(),
            b"item/../other",
            b"__MACOSX/../item",
            b"item\0suffix",
        ] {
            assert_eq!(
                entry_path(path).unwrap_err().code,
                ArchiveError::CorruptArchive
            );
        }
        assert_eq!(entry_path(b"./item/dir/").unwrap(), b"item/dir");
    }
}
