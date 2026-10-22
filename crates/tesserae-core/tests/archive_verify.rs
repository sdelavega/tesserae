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

use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::symlink;
use std::path::Path;
use std::process::{Command, Stdio};
use tesserae_core::archive_verify::{verify, zstd_stream, ArchiveError as E};
use tesserae_testutil::Fixture;

const SIDECAR_HEADER: &[u8; 24] = b"\0\x05\x16\x07\0\x02\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0";
fn write_sidecar(path: &Path, body: &[u8]) -> Vec<u8> {
    use std::os::macos::fs::MetadataExt;
    let bytes = [SIDECAR_HEADER.as_slice(), body].concat();
    fs::write(path, &bytes).unwrap();
    let name = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::chflags(name.as_ptr(), libc::UF_HIDDEN) }, 0);
    assert_ne!(fs::metadata(path).unwrap().st_flags() & libc::UF_HIDDEN, 0);
    bytes
}
fn tree() -> Fixture {
    let f = Fixture::new().unwrap();
    f.dir("item/empty").unwrap();
    fs::write(f.path().join("item/data"), b"abcdefabcdef").unwrap();
    symlink("data", f.path().join("item/link")).unwrap();
    f
}
fn archive(f: &Fixture, format: u32) -> std::path::PathBuf {
    archive_options(f, format, true)
}
fn archive_options(f: &Fixture, format: u32, metadata: bool) -> std::path::PathBuf {
    let path = f.path().join(format!("archive-{format}"));
    let mut command = Command::new("/usr/bin/tar");
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .args(["-c", "--one-file-system"]);
    match format {
        0 => {
            command.args(["--format", "zip"]);
        }
        1 => {
            command.arg("-J");
        }
        _ => {}
    }
    if !metadata {
        // Default bsdtar replaces real ._ files with generated sidecars in
        // tar and omits them in ZIP. These fixtures need their actual bytes.
        command.arg("--no-mac-metadata");
    }
    command
        .args(["-f", "-", "-C"])
        .arg(f.path())
        .args(["--", "item"]);
    let out = File::create(&path).unwrap();
    if format == 2 {
        let mut child = command.stdout(Stdio::piped()).spawn().unwrap();
        let input = child.stdout.take().unwrap();
        assert!(zstd_stream(input.as_raw_fd(), out.as_raw_fd(), 3).unwrap() > 0);
        drop(input);
        assert!(child.wait().unwrap().success());
    } else {
        assert!(command.stdout(out).status().unwrap().success());
    }
    assert!(fs::metadata(&path).unwrap().len() > 0);
    path
}
fn verdict(
    a: &Path,
    format: u32,
    f: &Fixture,
) -> Result<tesserae_core::archive_verify::ArchiveReport, tesserae_core::archive_verify::Failure> {
    verify(a, format, &f.path().join("item"))
}
#[test]
fn verifies_zip_tar_xz_tar_zst_of_same_tree() {
    let f = tree();
    for format in 0..3 {
        let a = archive(&f, format);
        let r = verdict(&a, format, &f).unwrap();
        assert_eq!((r.files, r.dirs, r.links, r.bytes), (1, 2, 1, 12));
    }
}
#[test]
fn detects_changed_byte_after_archiving() {
    let f = tree();
    for format in 0..3 {
        fs::write(f.path().join("item/data"), b"abcdefabcdef").unwrap();
        let a = archive(&f, format);
        fs::write(f.path().join("item/data"), b"xbcdefabcdef").unwrap();
        let e = verdict(&a, format, &f).unwrap_err();
        assert_eq!(e.code, E::DigestMismatch);
        assert_eq!(e.path, b"item/data");
    }
}
#[test]
fn detects_missing_and_extra_entries() {
    let f = tree();
    for format in 0..3 {
        let a = archive(&f, format);
        fs::write(f.path().join("item/new"), b"new").unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::MissingEntry);
        fs::remove_file(f.path().join("item/new")).unwrap();
        fs::rename(f.path().join("item/data"), f.path().join("item/new")).unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::ExtraEntry);
        fs::rename(f.path().join("item/new"), f.path().join("item/data")).unwrap();
    }
}
// Build literal members: bsdtar rewrites real ._ names and cannot create
// the hostile orderings this verifier must refuse.
fn crafted_archive(f: &Fixture, format: u32, members: &[(&str, &[u8])]) -> std::path::PathBuf {
    let path = f.path().join(format!("crafted-{format}"));
    let bytes = if format == 0 {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
        for &(name, data) in members {
            if name.ends_with('/') {
                assert!(data.is_empty());
                zip.add_directory(name, zip::write::FileOptions::default())
                    .unwrap();
            } else {
                zip.start_file(name, zip::write::FileOptions::default())
                    .unwrap();
                zip.write_all(data).unwrap();
            }
        }
        let bytes = zip.finish().unwrap().into_inner();
        let mut zip = zip::ZipArchive::new(std::io::Cursor::new(&bytes)).unwrap();
        assert_eq!(zip.len(), members.len());
        for (i, &(name, data)) in members.iter().enumerate() {
            let mut entry = zip.by_index(i).unwrap();
            assert_eq!(entry.name_raw(), name.as_bytes());
            let mut actual = Vec::new();
            entry.read_to_end(&mut actual).unwrap();
            assert_eq!(actual, data);
        }
        bytes
    } else {
        let mut tar = tar::Builder::new(Vec::new());
        for &(name, data) in members {
            let mut header = tar::Header::new_ustar();
            header.set_mode(0o755);
            header.set_size(data.len() as u64);
            header.set_entry_type(if name.ends_with('/') {
                assert!(data.is_empty());
                tar::EntryType::Directory
            } else {
                tar::EntryType::Regular
            });
            assert!(name.len() < 100);
            header.as_mut_bytes()[..name.len()].copy_from_slice(name.as_bytes());
            header.set_cksum();
            tar.append(&header, data).unwrap();
        }
        let bytes = tar.into_inner().unwrap();
        let mut tar = tar::Archive::new(&bytes[..]);
        let mut entries = tar.entries().unwrap();
        for &(name, data) in members {
            let mut entry = entries.next().unwrap().unwrap();
            assert_eq!(entry.path_bytes(), name.as_bytes());
            let mut actual = Vec::new();
            entry.read_to_end(&mut actual).unwrap();
            assert_eq!(actual, data);
        }
        assert!(entries.next().is_none());
        if format == 1 {
            let mut encoder = xz2::write::XzEncoder::new(Vec::new(), 6);
            encoder.write_all(&bytes).unwrap();
            encoder.finish().unwrap()
        } else {
            zstd::stream::encode_all(&bytes[..], 3).unwrap()
        }
    };
    assert!(!bytes.is_empty());
    fs::write(&path, bytes).unwrap();
    path
}
#[test]
fn paired_sidecars_of_unusual_names_are_excluded_byte_exactly() {
    use tesserae_core::archive_verify::{verify_with_flags, SIDECARS_ARE_METADATA};
    let f = Fixture::new().unwrap();
    f.dir("item/nested").unwrap();
    let names = [
        "ordinary".to_owned(),
        "tiny\nname".to_owned(),
        "tab\tname".to_owned(),
        "replacement-\u{fffd}".to_owned(),
        "-leading".to_owned(),
        "l".repeat(240),
    ];
    for name in &names {
        fs::write(f.path().join("item/nested").join(name), b"abc").unwrap();
    }
    let archives: Vec<_> = (0..3).map(|format| archive(&f, format)).collect();
    for name in &names {
        let sidecar = f.path().join("item/nested").join(format!("._{name}"));
        let mut metadata = [0; 4096];
        metadata[..24].copy_from_slice(SIDECAR_HEADER);
        fs::write(&sidecar, metadata).unwrap();
        let path = std::ffi::CString::new(sidecar.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::chflags(path.as_ptr(), libc::UF_HIDDEN) }, 0);
        let st = fs::metadata(sidecar).unwrap();
        assert!(st.is_file());
        assert_eq!(st.len(), 4096);
    }
    for (format, archive) in archives.iter().enumerate() {
        let r = verify_with_flags(
            archive,
            format as u32,
            &f.path().join("item"),
            SIDECARS_ARE_METADATA,
        )
        .unwrap();
        assert_eq!(
            (r.files, r.dirs, r.bytes),
            (names.len() as u64, 2, names.len() as u64 * 3)
        );
        assert!(verify(archive, format as u32, &f.path().join("item")).is_err());
    }
}

fn sidecar_directory_children_are_content(format: u32) {
    use tesserae_core::archive_verify::verify_with_flags;
    let f = Fixture::new().unwrap();
    f.dir("item/._foo/nested").unwrap();
    fs::write(f.path().join("item/foo"), b"sibling").unwrap();
    fs::write(f.path().join("item/._foo/nested/child"), b"child").unwrap();
    assert!(fs::symlink_metadata(f.path().join("item/._foo"))
        .unwrap()
        .is_dir());
    let mut members: Vec<(&str, &[u8])> = vec![
        ("item/", b""),
        ("item/foo", b"sibling"),
        ("item/._foo/", b""),
        ("item/._foo/nested/", b""),
    ];
    for flags in [0, 1] {
        let a = crafted_archive(&f, format, &members);
        let e = verify_with_flags(&a, format, &f.path().join("item"), flags).unwrap_err();
        assert_eq!(e.code, E::MissingEntry);
        assert_eq!(e.path, b"item/._foo/nested/child");
    }
    members.push(("item/._foo/nested/child", b"child"));
    let a = crafted_archive(&f, format, &members);
    for flags in [0, 1] {
        let r = verify_with_flags(&a, format, &f.path().join("item"), flags).unwrap();
        assert_eq!((r.files, r.dirs, r.bytes), (2, 3, 12));
    }
}
fn sidecar_symlinks_are_content(format: u32) {
    use tesserae_core::archive_verify::verify_with_flags;
    let f = Fixture::new().unwrap();
    f.dir("item").unwrap();
    fs::write(f.path().join("item/x"), b"\0\x05\x16\x07target").unwrap();
    symlink("x", f.path().join("item/._x")).unwrap();
    assert!(fs::symlink_metadata(f.path().join("item/._x"))
        .unwrap()
        .file_type()
        .is_symlink());
    let a = archive_options(&f, format, false);
    for flags in [0, 1] {
        let r = verify_with_flags(&a, format, &f.path().join("item"), flags).unwrap();
        assert_eq!((r.files, r.dirs, r.links), (1, 1, 1));
    }
    let a = crafted_archive(
        &f,
        format,
        &[("item/", b""), ("item/x", b"\0\x05\x16\x07target")],
    );
    for flags in [0, 1] {
        let e = verify_with_flags(&a, format, &f.path().join("item"), flags).unwrap_err();
        assert_eq!(e.code, E::MissingEntry);
        assert_eq!(e.path, b"item/._x");
    }
}
fn sidecar_magic_and_size_are_required(format: u32) {
    use std::os::macos::fs::MetadataExt;
    use tesserae_core::archive_verify::verify_with_flags;
    // Captured verbatim from the disposable FAT image used for the T8-R7 probe.
    let measured = include_bytes!("fixtures/macos-fat-appledouble.bin");
    assert_eq!(measured.len(), 4096);
    assert_eq!(&measured[..8], &SIDECAR_HEADER[..8]);
    assert_eq!(&measured[8..24], b"Mac OS X        ");
    let mut cases = vec![
        (b"content!".to_vec(), true, false),
        (vec![0, 5, 22], true, false),
        (b"\0\x05\x16\x07data".to_vec(), true, false),
        (measured.to_vec(), true, true),
    ];
    for header in [SIDECAR_HEADER.as_slice(), &measured[..24]] {
        cases.push((header.to_vec(), false, false));
        cases.push((header.to_vec(), true, true));
        // Every magic, version and filler byte is significant in either spelling.
        for index in 0..24 {
            let mut bytes = header.to_vec();
            bytes[index] ^= 1;
            cases.push((bytes, true, false));
        }
        for size in [16 * 1024 * 1024, 16 * 1024 * 1024 + 1] {
            let mut bytes = vec![0; size];
            bytes[..24].copy_from_slice(header);
            cases.push((bytes, true, size == 16 * 1024 * 1024));
        }
    }
    for (bytes, hidden, excluded) in cases {
        let f = Fixture::new().unwrap();
        f.dir("item").unwrap();
        fs::write(f.path().join("item/x"), b"sibling").unwrap();
        fs::write(f.path().join("item/._x"), &bytes).unwrap();
        let name = std::ffi::CString::new(f.path().join("item/._x").as_os_str().as_encoded_bytes())
            .unwrap();
        assert_eq!(
            unsafe { libc::chflags(name.as_ptr(), if hidden { libc::UF_HIDDEN } else { 0 }) },
            0
        );
        let st = fs::symlink_metadata(f.path().join("item/._x")).unwrap();
        assert_eq!(st.st_flags() & libc::UF_HIDDEN != 0, hidden);
        assert!(st.is_file());
        assert_eq!(st.len(), bytes.len() as u64);
        let a = crafted_archive(&f, format, &[("item/", b""), ("item/x", b"sibling")]);
        for flags in [0, 1, 2] {
            let result = verify_with_flags(&a, format, &f.path().join("item"), flags);
            if excluded && flags == 1 {
                let r = result.unwrap();
                assert_eq!((r.files, r.dirs, r.bytes), (1, 1, 7));
            } else {
                let e = result.unwrap_err();
                assert_eq!(e.code, E::MissingEntry);
                assert_eq!(e.path, b"item/._x");
            }
        }
        let a = crafted_archive(
            &f,
            format,
            &[("item/", b""), ("item/x", b"sibling"), ("item/._x", &bytes)],
        );
        for flags in [0, 1] {
            let r = verify_with_flags(&a, format, &f.path().join("item"), flags).unwrap();
            assert_eq!(r.files, if excluded && flags == 1 { 1 } else { 2 });
        }
    }
}

fn paired_sidecars_are_metadata_only_with_flag(format: u32) {
    use tesserae_core::archive_verify::{verify_with_flags, SIDECARS_ARE_METADATA};
    let f = Fixture::new().unwrap();
    f.dir("item").unwrap();
    fs::write(f.path().join("item/data"), b"original").unwrap();
    let sidecar = write_sidecar(&f.path().join("item/._data"), b"car");
    let item = f.path().join("item");
    let mut members: Vec<(&str, &[u8])> = vec![("item/", b""), ("item/data", b"original")];
    let a = crafted_archive(&f, format, &members);
    assert_eq!(fs::read(item.join("._data")).unwrap(), sidecar);
    assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::MissingEntry);
    let r = verify_with_flags(&a, format, &item, SIDECARS_ARE_METADATA).unwrap();
    assert_eq!((r.files, r.dirs, r.bytes), (1, 1, 8));
    members.push(("item/._data", b"different metadata bytes of another length"));
    let a = crafted_archive(&f, format, &members);
    assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::SizeMismatch);
    let r = verify_with_flags(&a, format, &item, SIDECARS_ARE_METADATA).unwrap();
    assert_eq!((r.files, r.dirs, r.bytes), (1, 1, 8));
    members.push(("./item/._data", b"duplicate"));
    let a = crafted_archive(&f, format, &members);
    let e = verify_with_flags(&a, format, &item, SIDECARS_ARE_METADATA).unwrap_err();
    assert_eq!(e.code, E::DuplicateEntry);
    assert_eq!(e.path, b"item/._data");
}
fn orphan_sidecars_remain_content_with_flag(format: u32) {
    use tesserae_core::archive_verify::{verify_with_flags, SIDECARS_ARE_METADATA};
    let f = Fixture::new().unwrap();
    f.dir("item/elsewhere").unwrap();
    fs::write(f.path().join("item/elsewhere/lost"), b"not a sibling").unwrap();
    let sidecar = write_sidecar(&f.path().join("item/._lost"), b"inal");
    fs::write(f.path().join("item/._"), b"empty suffix").unwrap();
    let item = f.path().join("item");
    assert!(!item.join("lost").exists());
    let mut members: Vec<(&str, &[u8])> = vec![
        ("item/", b""),
        ("item/elsewhere/", b""),
        ("item/elsewhere/lost", b"not a sibling"),
        ("item/._", b"empty suffix"),
    ];
    let a = crafted_archive(&f, format, &members);
    for flags in [0, SIDECARS_ARE_METADATA] {
        let e = verify_with_flags(&a, format, &item, flags).unwrap_err();
        assert_eq!(e.code, E::MissingEntry);
        assert_eq!(e.path, b"item/._lost");
    }
    members.push(("item/._lost", &sidecar));
    let a = crafted_archive(&f, format, &members);
    let r = verify_with_flags(&a, format, &item, SIDECARS_ARE_METADATA).unwrap();
    assert_eq!(
        (r.files, r.dirs, r.bytes),
        (3, 2, 25 + sidecar.len() as u64)
    );
    let mut changed = sidecar.clone();
    *changed.last_mut().unwrap() ^= 1;
    fs::write(item.join("._lost"), changed).unwrap();
    let e = verify_with_flags(&a, format, &item, SIDECARS_ARE_METADATA).unwrap_err();
    assert_eq!(e.code, E::DigestMismatch);
    assert_eq!(e.path, b"item/._lost");
}
fn sidecar_sibling_any_entry_and_root_count(format: u32) {
    use tesserae_core::archive_verify::{verify_with_flags, SIDECARS_ARE_METADATA};
    let f = Fixture::new().unwrap();
    f.dir("item/dir").unwrap();
    write_sidecar(&f.path().join("item/._dir"), b"directory metadata");
    symlink("absent", f.path().join("item/dangling")).unwrap();
    write_sidecar(&f.path().join("item/._dangling"), b"link metadata");
    let a = crafted_archive(&f, format, &[("item/._dir", b"ignored")]);
    let r = verify_with_flags(
        &a,
        format,
        &f.path().join("item/._dir"),
        SIDECARS_ARE_METADATA,
    )
    .unwrap();
    assert_eq!((r.files, r.dirs, r.links, r.bytes), (0, 0, 0, 0));
    let a = crafted_archive(&f, format, &[("item/._dangling", b"ignored")]);
    assert!(fs::symlink_metadata(f.path().join("item/dangling"))
        .unwrap()
        .file_type()
        .is_symlink());
    let r = verify_with_flags(
        &a,
        format,
        &f.path().join("item/._dangling"),
        SIDECARS_ARE_METADATA,
    )
    .unwrap();
    assert_eq!((r.files, r.dirs, r.links, r.bytes), (0, 0, 0, 0));
    let a = crafted_archive(&f, format, &[("item/", b""), ("item/dir/", b"")]);
    let e =
        verify_with_flags(&a, format, &f.path().join("item"), SIDECARS_ARE_METADATA).unwrap_err();
    assert_eq!(e.code, E::MissingEntry);
    assert_eq!(e.path, b"item/dangling");
}
fn flagged_sidecar_collisions_still_fail(format: u32) {
    use tesserae_core::archive_verify::{verify_with_flags, SIDECARS_ARE_METADATA};
    for (real, extra) in [
        ("item/._x", "item/._X"),
        ("item/._café", "item/._cafe\u{301}"),
    ] {
        for paired in [false, true] {
            for extra_first in [false, true] {
                let f = Fixture::new().unwrap();
                f.dir("item").unwrap();
                let sidecar = write_sidecar(&f.path().join(real), b"inal");
                let sibling = real.replace("/._", "/");
                if paired {
                    fs::write(f.path().join(&sibling), b"content").unwrap();
                }
                let actual = fs::read_dir(f.path().join("item"))
                    .unwrap()
                    .map(|e| e.unwrap().file_name())
                    .find(|n| n.as_encoded_bytes().starts_with(b"._"))
                    .unwrap();
                assert_eq!(
                    actual.as_encoded_bytes(),
                    Path::new(real).file_name().unwrap().as_encoded_bytes()
                );
                assert_ne!(real.as_bytes(), extra.as_bytes());
                let mut members: Vec<(&str, &[u8])> = vec![("item/", b"")];
                if paired {
                    members.push((&sibling, b"content"));
                }
                members.push((real, &sidecar));
                let a = crafted_archive(&f, format, &members);
                assert!(verify_with_flags(
                    &a,
                    format,
                    &f.path().join("item"),
                    SIDECARS_ARE_METADATA
                )
                .is_ok());
                if paired {
                    let a = crafted_archive(
                        &f,
                        format,
                        &[("item/", b""), (&sibling, b"content"), (extra, b"hostile")],
                    );
                    for flags in [0, SIDECARS_ARE_METADATA] {
                        let e = verify_with_flags(&a, format, &f.path().join("item"), flags)
                            .unwrap_err();
                        assert_eq!(e.code, E::ExtraEntry);
                        assert_eq!(e.path, extra.as_bytes());
                    }
                }
                members.insert(
                    if extra_first { 1 } else { members.len() },
                    (extra, b"hostile"),
                );
                let a = crafted_archive(&f, format, &members);
                let e =
                    verify_with_flags(&a, format, &f.path().join("item"), SIDECARS_ARE_METADATA)
                        .unwrap_err();
                assert_eq!(e.code, E::ExtraEntry);
                assert_eq!(e.path, extra.as_bytes());
            }
        }
    }
}
fn duplicate_archive_paths_fail(format: u32) {
    for name in [
        "item/._x",
        "item/__MACOSX/inner",
        "item/data",
        "item/",
        "item/._sidecar",
    ] {
        let f = Fixture::new().unwrap();
        f.dir("item").unwrap();
        let mut members: Vec<(&str, &[u8])> = vec![("item/", b"")];
        if name.contains("__MACOSX/") {
            f.dir("item/__MACOSX").unwrap();
            members.push(("item/__MACOSX/", b""));
        }
        if name != "item/" && name != "item/._sidecar" {
            fs::write(f.path().join(name), b"original").unwrap();
            members.push((name, b"original"));
        } else {
            fs::write(f.path().join("item/data"), b"original").unwrap();
            members.push(("item/data", b"original"));
            if name == "item/._sidecar" {
                assert!(!f.path().join(name).exists());
                members.push((name, b"sidecar"));
            }
        }
        let a = crafted_archive(&f, format, &members);
        let r = verdict(&a, format, &f).unwrap();
        assert_eq!((r.files, r.bytes), (1, 8));
        // A directory alias must be caught after path canonicalisation too.
        members.push(if name == "item/" {
            ("./item/", b"")
        } else {
            (name, b"EVILEVIL")
        });
        let a = crafted_archive(&f, format, &members);
        let e = verdict(&a, format, &f).unwrap_err();
        assert_eq!(e.code, E::DuplicateEntry, "{name}");
        assert_eq!(e.path, name.trim_end_matches('/').as_bytes());
    }
}
fn colliding_metadata_manifest_paths_fail(format: u32) {
    for (real, extra) in [
        ("item/._x", "item/._X"),
        ("item/._café", "item/._cafe\u{301}"),
    ] {
        for extra_first in [false, true] {
            let f = Fixture::new().unwrap();
            f.dir("item").unwrap();
            fs::write(f.path().join(real), b"original").unwrap();
            let actual = fs::read_dir(f.path().join("item"))
                .unwrap()
                .next()
                .unwrap()
                .unwrap()
                .file_name();
            assert_eq!(
                actual.as_encoded_bytes(),
                Path::new(real).file_name().unwrap().as_encoded_bytes()
            );
            assert_ne!(real.as_bytes(), extra.as_bytes());
            let a = crafted_archive(&f, format, &[("item/", b""), (real, b"original")]);
            let r = verdict(&a, format, &f).unwrap();
            assert_eq!((r.files, r.dirs, r.bytes), (1, 1, 8));
            let mut members: Vec<(&str, &[u8])> = vec![("item/", b""), (real, b"original")];
            members.insert(if extra_first { 1 } else { 2 }, (extra, b"EVILEVIL"));
            let a = crafted_archive(&f, format, &members);
            let e = verdict(&a, format, &f).unwrap_err();
            assert_eq!(e.code, E::ExtraEntry, "{extra}, first={extra_first}");
            assert_eq!(e.path, extra.as_bytes());
        }
    }
}
fn colliding_metadata_seen_paths_fail(format: u32) {
    for (first, second) in [
        ("item/._x", "item/._X"),
        ("item/._café", "item/._cafe\u{301}"),
    ] {
        for (first, second) in [(first, second), (second, first)] {
            let f = Fixture::new().unwrap();
            f.dir("item").unwrap();
            fs::write(f.path().join("item/data"), b"original").unwrap();
            assert!(!f.path().join(first).exists());
            assert!(!f.path().join(second).exists());
            let mut members: Vec<(&str, &[u8])> = vec![
                ("item/", b""),
                ("item/data", b"original"),
                (first, b"sidecar"),
            ];
            let a = crafted_archive(&f, format, &members);
            let r = verdict(&a, format, &f).unwrap();
            assert_eq!((r.files, r.dirs, r.bytes), (1, 1, 8));
            members.push((second, b"EVILEVIL"));
            let a = crafted_archive(&f, format, &members);
            let e = verdict(&a, format, &f).unwrap_err();
            assert_eq!(e.code, E::ExtraEntry, "{second}");
            assert_eq!(e.path, second.as_bytes());
        }
    }
}
fn real_metadata_names_are_verified(format: u32) {
    let f = tree();
    fs::write(f.path().join("item/._data"), b"original").unwrap();
    f.dir("item/._dir").unwrap();
    fs::write(f.path().join("item/._dir/child"), b"nested").unwrap();
    f.dir("item/__MACOSX").unwrap();
    fs::write(f.path().join("item/__MACOSX/data"), b"original").unwrap();
    symlink("data", f.path().join("item/._link")).unwrap();
    let a = archive_options(&f, format, false);
    let r = verdict(&a, format, &f).unwrap();
    assert_eq!((r.files, r.dirs, r.links, r.bytes), (4, 4, 2, 34));
}
fn changed_real_metadata_file_fails_digest(format: u32) {
    for path in ["item/._data", "item/._dir/child", "item/__MACOSX/data"] {
        let f = tree();
        fs::create_dir_all(f.path().join(path).parent().unwrap()).unwrap();
        fs::write(f.path().join(path), b"original").unwrap();
        let a = archive_options(&f, format, false);
        assert_eq!(fs::read(f.path().join(path)).unwrap(), b"original");
        fs::write(f.path().join(path), b"changed!").unwrap();
        let e = verdict(&a, format, &f).unwrap_err();
        assert_eq!(e.code, E::DigestMismatch, "{path}");
        assert_eq!(e.path, path.as_bytes());
    }
}
fn missing_real_metadata_entries_fail(format: u32) {
    for path in ["item/._data", "item/__MACOSX", "item/._link"] {
        let f = tree();
        let a = archive_options(&f, format, false);
        assert!(!f.path().join(path).exists());
        match path {
            "item/__MACOSX" => fs::create_dir(f.path().join(path)).unwrap(),
            "item/._link" => symlink("data", f.path().join(path)).unwrap(),
            _ => fs::write(f.path().join(path), b"original").unwrap(),
        }
        let e = verdict(&a, format, &f).unwrap_err();
        assert_eq!(e.code, E::MissingEntry, "{path}");
        assert_eq!(e.path, path.as_bytes());
    }
}
fn ignores_genuine_appledouble_members(format: u32) {
    let f = tree();
    for name in ["item/data", "item"] {
        let output = Command::new("/usr/bin/xattr")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .args(["-w", "com.tesserae.test", "metadata"])
            .arg(f.path().join(name))
            .output()
            .unwrap();
        assert!(output.status.success(), "{:?}", output);
        let output = Command::new("/usr/bin/xattr")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .args(["-p", "com.tesserae.test"])
            .arg(f.path().join(name))
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"metadata\n");
    }
    assert!(!f.path().join("item/._data").exists());
    assert!(!f.path().join("._item").exists());
    let a = archive(&f, format);
    // bsdtar's ZIP writer omits xattrs, even with --mac-metadata. Capture
    // its genuine tar sidecar and append those exact bytes to the ZIP.
    let bytes = if format == 1 {
        let mut bytes = Vec::new();
        xz2::read::XzDecoder::new_multi_decoder(File::open(&a).unwrap())
            .read_to_end(&mut bytes)
            .unwrap();
        bytes
    } else {
        let tar = if format == 2 {
            a.clone()
        } else {
            archive(&f, 2)
        };
        zstd::stream::decode_all(File::open(tar).unwrap()).unwrap()
    };
    let mut metadata = std::collections::BTreeMap::new();
    for entry in tar::Archive::new(&bytes[..]).entries().unwrap() {
        let mut entry = entry.unwrap();
        let name = entry.path_bytes().into_owned();
        if name == b"item/._data" || name == b"._item" {
            let mut data = Vec::new();
            entry.read_to_end(&mut data).unwrap();
            assert!(data.starts_with(&[0, 5, 22, 7]), "AppleDouble magic");
            assert!(data.len() > 26, "AppleDouble header and entry table");
            assert!(metadata.insert(name, data).is_none());
        }
    }
    assert_eq!(metadata.len(), 2, "bsdtar must produce both sidecars");
    if format == 0 {
        let file = File::options().read(true).write(true).open(&a).unwrap();
        let mut zip = zip::ZipWriter::new_append(file).unwrap();
        for (name, data) in metadata {
            zip.start_file(
                std::str::from_utf8(&name).unwrap(),
                zip::write::FileOptions::default(),
            )
            .unwrap();
            zip.write_all(&data).unwrap();
        }
        zip.finish().unwrap();
    }
    let r = verdict(&a, format, &f).unwrap();
    assert_eq!((r.files, r.dirs, r.links, r.bytes), (1, 2, 1, 12));
}
fn ignores_extra_macosx_members(format: u32) {
    let f = tree();
    f.dir("item/__MACOSX").unwrap();
    fs::write(f.path().join("item/__MACOSX/extra"), b"metadata").unwrap();
    let a = archive(&f, format);
    fs::remove_file(f.path().join("item/__MACOSX/extra")).unwrap();
    fs::remove_dir(f.path().join("item/__MACOSX")).unwrap();
    let r = verdict(&a, format, &f).unwrap();
    assert_eq!((r.files, r.dirs, r.links, r.bytes), (1, 2, 1, 12));
}
fn extra_non_metadata_entries_fail(format: u32) {
    for path in ["item/extra", "item/._dir/extra"] {
        let f = tree();
        fs::create_dir_all(f.path().join(path).parent().unwrap()).unwrap();
        fs::write(f.path().join(path), b"extra").unwrap();
        let a = archive_options(&f, format, false);
        assert_eq!(fs::read(f.path().join(path)).unwrap(), b"extra");
        fs::remove_file(f.path().join(path)).unwrap();
        let e = verdict(&a, format, &f).unwrap_err();
        assert_eq!(e.code, E::ExtraEntry, "{path}");
        assert_eq!(e.path, path.as_bytes());
    }
}
macro_rules! archive_metadata_tests {
    ($module:ident, $format:expr, $($test:ident),+ $(,)?) => {
        mod $module {
            $(#[test]
            fn $test() {
                super::$test($format);
            })+
        }
    };
}
macro_rules! metadata_format_tests {
    ($module:ident, $format:expr) => {
        archive_metadata_tests!(
            $module,
            $format,
            sidecar_directory_children_are_content,
            sidecar_symlinks_are_content,
            sidecar_magic_and_size_are_required,
            paired_sidecars_are_metadata_only_with_flag,
            orphan_sidecars_remain_content_with_flag,
            sidecar_sibling_any_entry_and_root_count,
            flagged_sidecar_collisions_still_fail,
            duplicate_archive_paths_fail,
            colliding_metadata_manifest_paths_fail,
            colliding_metadata_seen_paths_fail,
            real_metadata_names_are_verified,
            changed_real_metadata_file_fails_digest,
            missing_real_metadata_entries_fail,
            ignores_genuine_appledouble_members,
            ignores_extra_macosx_members,
            extra_non_metadata_entries_fail,
        );
    };
}
metadata_format_tests!(zip_format, 0);
metadata_format_tests!(tar_xz, 1);
metadata_format_tests!(tar_zst, 2);
#[test]
fn symlink_targets_compared_not_followed() {
    let f = tree();
    for format in 0..3 {
        let a = archive(&f, format);
        fs::remove_file(f.path().join("item/link")).unwrap();
        symlink("absent", f.path().join("item/link")).unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::LinkMismatch);
        fs::remove_file(f.path().join("item/link")).unwrap();
        symlink("data", f.path().join("item/link")).unwrap();
    }
}
#[test]
fn truncated_archive_is_corrupt() {
    let f = tree();
    for format in 0..3 {
        let a = archive(&f, format);
        let bytes = fs::read(&a).unwrap();
        // bsdtar pads stdout to 10 KiB, even for ZIP/xz. Remove an
        // actual format byte, rather than merely shortening that padding.
        let end = match format {
            0 => bytes.windows(4).rposition(|w| w == b"PK\x05\x06").unwrap() + 22,
            1 => bytes.windows(2).rposition(|w| w == b"YZ").unwrap() + 2,
            _ => bytes.len(),
        };
        assert!(end > 1 && end <= bytes.len());
        fs::write(&a, &bytes[..end - 1]).unwrap();
        assert_eq!(
            verdict(&a, format, &f).unwrap_err().code,
            E::CorruptArchive,
            "format {format}"
        );
    }
}
#[test]
fn zero_files_tree_is_not_ok() {
    let f = Fixture::new().unwrap();
    f.dir("item").unwrap();
    for format in 0..3 {
        let a = archive(&f, format);
        let r = verdict(&a, format, &f).unwrap();
        assert_eq!((r.files, r.dirs, r.links, r.bytes), (0, 1, 0, 0));
        f.dir("item/missing").unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::MissingEntry);
        fs::remove_dir(f.path().join("item/missing")).unwrap();
    }
}
#[test]
fn zstd_stream_round_trips_and_reports_bytes() {
    let f = Fixture::new().unwrap();
    let input: Vec<u8> = (0..200_000).map(|n| (n % 251) as u8).collect();
    let (mut writer, reader) = std::os::unix::net::UnixStream::pair().unwrap();
    let expected = input.clone();
    let thread = std::thread::spawn(move || writer.write_all(&input).unwrap());
    let file = File::create(f.path().join("out")).unwrap();
    let n = zstd_stream(reader.as_raw_fd(), file.as_raw_fd(), 3).unwrap();
    thread.join().unwrap();
    let encoded = fs::read(f.path().join("out")).unwrap();
    assert_eq!(n, encoded.len() as u64);
    assert_eq!(zstd::stream::decode_all(&encoded[..]).unwrap(), expected);
    assert!(
        file.metadata().is_ok(),
        "descriptor remains owned by caller"
    );
    assert!(reader.take(1).read(&mut [0]).is_ok());
}
#[test]
fn zstd_stream_reports_write_error() {
    let f = Fixture::new().unwrap();
    fs::write(f.path().join("input"), b"hello").unwrap();
    let input = File::open(f.path().join("input")).unwrap();
    assert_eq!(
        zstd_stream(input.as_raw_fd(), -1, 3)
            .unwrap_err()
            .raw_os_error(),
        Some(libc::EBADF)
    );
    assert!(input.metadata().is_ok());
}

#[test]
fn size_type_and_unreadable_original_fail_closed() {
    let f = tree();
    for format in 0..3 {
        let a = archive(&f, format);
        fs::write(f.path().join("item/data"), b"short").unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::SizeMismatch);
        fs::remove_file(f.path().join("item/data")).unwrap();
        fs::create_dir(f.path().join("item/data")).unwrap();
        assert_eq!(verdict(&a, format, &f).unwrap_err().code, E::TypeMismatch);
        fs::remove_dir(f.path().join("item/data")).unwrap();
        fs::write(f.path().join("item/data"), b"abcdefabcdef").unwrap();
        f.chmod("item/data", 0).unwrap();
        assert_eq!(
            verdict(&a, format, &f).unwrap_err().code,
            E::UnreadableOriginal
        );
        f.chmod("item/data", 0o600).unwrap();
    }
}
#[test]
fn hardlinks_verify_and_duplicate_members_fail() {
    let f = tree();
    fs::hard_link(f.path().join("item/data"), f.path().join("item/hard")).unwrap();
    for format in 0..3 {
        let a = archive(&f, format);
        assert_eq!(verdict(&a, format, &f).unwrap().files, 2);
        let path = f.path().join("duplicate");
        let mut command = Command::new("/usr/bin/tar");
        command
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .args(["-c", "-f"])
            .arg(&path);
        if format == 0 {
            command.args(["--format", "zip"]);
        } else {
            command.arg("-J");
        }
        assert!(command
            .arg("-C")
            .arg(f.path())
            .args(["--", "item", "item"])
            .status()
            .unwrap()
            .success());
        assert_eq!(
            verdict(&path, if format == 0 { 0 } else { 1 }, &f)
                .unwrap_err()
                .code,
            E::DuplicateEntry
        );
    }
}
#[test]
fn archive_traversal_paths_are_corrupt() {
    let f = tree();
    let a = archive(&f, 2);
    let bytes = zstd::stream::decode_all(File::open(&a).unwrap()).unwrap();
    for name in [b"/item".as_slice(), b"../item", b"__MACOSX/../item"] {
        let mut modified = bytes.clone();
        // Replace the first header name and recompute its tar checksum, so
        // refusal must come from path validation rather than bad checksum.
        modified[..100].fill(0);
        modified[..name.len()].copy_from_slice(name);
        modified[148..156].fill(b' ');
        let checksum: u32 = modified[..512].iter().map(|&b| u32::from(b)).sum();
        let sum = format!("{checksum:06o}\0 ");
        modified[148..156].copy_from_slice(sum.as_bytes());
        fs::write(&a, zstd::stream::encode_all(&modified[..], 3).unwrap()).unwrap();
        assert_eq!(verdict(&a, 2, &f).unwrap_err().code, E::CorruptArchive);
    }
}
#[test]
fn original_mount_boundary_is_refused() {
    let f = tree();
    f.dir("item/mount").unwrap();
    let a = archive(&f, 0);
    let _image = tesserae_testutil::DiskImage::attach(&f.path().join("item/mount"), 64).unwrap();
    assert_eq!(verdict(&a, 0, &f).unwrap_err().code, E::UnreadableOriginal);
}

fn rewrite_checksum(bytes: &mut [u8]) {
    bytes[148..156].fill(b' ');
    let sum: u32 = bytes[..512].iter().map(|&b| u32::from(b)).sum();
    bytes[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
}
#[test]
fn self_referencing_tar_hardlink_is_corrupt() {
    let f = tree();
    let a = archive(&f, 2);
    let mut bytes = zstd::stream::decode_all(File::open(&a).unwrap()).unwrap();
    let offset = tar::Archive::new(&bytes[..])
        .entries()
        .unwrap()
        .map(Result::unwrap)
        .find(|e| e.path_bytes() == b"item/data".as_slice())
        .unwrap()
        .raw_header_position() as usize;
    assert!(bytes[offset + 156] == b'0' || bytes[offset + 156] == 0);
    bytes[offset + 156] = b'1';
    bytes[offset + 157..offset + 257].fill(0);
    bytes[offset + 157..offset + 166].copy_from_slice(b"item/data");
    rewrite_checksum(&mut bytes[offset..]);
    fs::write(&a, zstd::stream::encode_all(&bytes[..], 3).unwrap()).unwrap();
    assert_eq!(verdict(&a, 2, &f).unwrap_err().code, E::CorruptArchive);
}
#[test]
fn tar_requires_end_markers_and_rejects_hidden_entries() {
    let f = tree();
    let a = archive(&f, 2);
    let bytes = zstd::stream::decode_all(File::open(&a).unwrap()).unwrap();
    let end = tar::Archive::new(&bytes[..])
        .entries()
        .unwrap()
        .map(Result::unwrap)
        .map(|e| (e.raw_file_position() + e.size()).next_multiple_of(512) as usize)
        .max()
        .unwrap();
    assert!(end < bytes.len());
    assert!(bytes[end..].iter().all(|&b| b == 0));
    fs::write(&a, zstd::stream::encode_all(&bytes[..end], 3).unwrap()).unwrap();
    assert_eq!(verdict(&a, 2, &f).unwrap_err().code, E::CorruptArchive);
    let mut hidden = bytes.clone();
    hidden.extend_from_slice(&bytes);
    fs::write(&a, zstd::stream::encode_all(&hidden[..], 3).unwrap()).unwrap();
    assert_eq!(verdict(&a, 2, &f).unwrap_err().code, E::CorruptArchive);
}
