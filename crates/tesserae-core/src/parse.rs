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

//! Parser for `getattrlistbulk(2)` output buffers.
//!
//! This is the riskiest code in the program. It walks a packed binary buffer
//! using lengths and offsets the kernel supplied, and the failure that matters
//! is not a crash: it is a plausible-looking wrong number. A segfault gets
//! fixed; a file size that is quietly 4% off ships. So [`entries`] is pure
//! over `&[u8]`, never panics on any input, and bounds-checks every offset
//! against both the entry length and the buffer length before using it.
//!
//! # The layout was measured, not assumed
//!
//! Every offset below was derived from captured buffers, not from reasoning
//! about bit values. The method: request one attribute at a time alongside the
//! two `ATTR_BULK_REQUIRED` attributes, identify the single value by comparing
//! it against `lstat(2)` ground truth, then request all nine together and
//! match each slot against the values already known. The golden fixtures in
//! `tests/fixtures/` are the recorded evidence.
//!
//! For the mask in [`crate::attrs`] the measured order happens to be ascending
//! bit order within each group, with `ATTR_CMN_RETURNED_ATTRS` hoisted out of
//! bit position into the entry header, and the whole `commonattr` group ahead
//! of the whole `fileattr` group. That coincidence is not relied on anywhere:
//! the offsets are constants fixed by measurement, and
//! `layout_matches_the_captured_golden_buffer` re-derives them from a real
//! buffer on every test run.
//!
//! ```text
//! off  size  field                                      type
//!   0     4  entry length                               u32
//!   4     4  ATTR_CMN_RETURNED_ATTRS .commonattr        u32
//!   8     4  ATTR_CMN_RETURNED_ATTRS .volattr           u32
//!  12     4  ATTR_CMN_RETURNED_ATTRS .dirattr           u32
//!  16     4  ATTR_CMN_RETURNED_ATTRS .fileattr          u32
//!  20     4  ATTR_CMN_RETURNED_ATTRS .forkattr          u32
//!  24     8  ATTR_CMN_NAME                              attrreference_t
//!  32     4  ATTR_CMN_DEVID                             i32  (dev_t)
//!  36     4  ATTR_CMN_OBJTYPE                           u32  (fsobj_type_t)
//!  40     4  ATTR_CMN_FLAGS                             u32
//!  44     8  ATTR_CMN_FILEID                            u64  (NOT 8-aligned)
//!  52     4  ATTR_FILE_LINKCOUNT                        u32
//!  56     8  ATTR_FILE_ALLOCSIZE                        u64  (off_t)
//!  64     8  ATTR_FILE_DATALENGTH                       u64  (off_t)
//!  72    ..  variable-length region: the name bytes
//! ```
//!
//! Two measured facts drive the whole design, and one of them contradicts the
//! documentation:
//!
//! 1. `ATTR_CMN_FILEID` lands at offset 44, which is 4 modulo 8. The kernel
//!    packs these fields with no alignment padding whatsoever, so every
//!    multi-byte read here must be an unaligned-safe byte copy.
//!
//! 2. **A directory's entry carries no `fileattr` group at all.** A regular
//!    file's entry is 80 bytes with `returned.fileattr == 0x205`, while the
//!    directory beside it is 56 bytes with `returned.fileattr == 0` and the
//!    name starting at offset 52 — the three `fileattr` slots are *absent*,
//!    not zero-filled. 56 is less than the 72 bytes the fixed fields would
//!    need, so this is arithmetic, not interpretation. Measured identically on
//!    APFS, HFS+, exFAT and FAT32, so it is VFS behaviour rather than one
//!    filesystem's quirk, and setting or clearing `FSOPT_PACK_INVAL_ATTRS`
//!    changes nothing — although `getattrlistbulk(2)` documents that option as
//!    meaning "all requested attributes [...] will be returned".
//!    Offsets therefore do **not** stay stable from entry to entry, and a
//!    parser that assumed they did would read a directory's name bytes as its
//!    link count and allocated size. The numbers would look plausible.
//!
//! So a slot's value is used only when two independent gates agree:
//!
//! * **The layout gate.** The name's `attr_dataoffset` marks where the
//!   variable-length region begins, which makes it the kernel's own statement
//!   of where the fixed-field region ends. A slot that does not fit entirely
//!   before it is not a field, and is reported as its default.
//! * **The returned-attributes gate.** `ATTR_CMN_RETURNED_ATTRS` says whether
//!   a present slot holds a real value. A slot whose bit is clear is reported
//!   as its default, which is what `FSOPT_PACK_INVAL_ATTRS` asks a caller to
//!   do with a zero-filled invalid attribute.
//!
//! Field offsets are compile-time constants in either case, so neither gate
//! can shift a later read: a surprise yields a default, never another field's
//! bytes.

#[cfg(not(target_endian = "little"))]
compile_error!(
    "the parser reads the kernel's native-endian integers as little-endian, \
     which holds for aarch64-apple-darwin and x86_64-apple-darwin"
);

/// One directory entry's attributes, borrowed from the kernel's buffer.
///
/// A field whose attribute the kernel did not supply holds its default: `0`,
/// or [`ObjType::Other`]. Nothing here is ever a misaligned read of a
/// neighbouring field.
#[derive(Debug, Clone, PartialEq)]
pub struct RawEntry<'a> {
    /// The entry's name, exactly as the kernel spelled it, with the
    /// terminating NUL removed. Never interpreted as UTF-8: macOS filenames
    /// are bytes, and a lossy conversion here would corrupt names the scanner
    /// has to report back.
    pub name: &'a [u8],
    pub obj_type: ObjType,
    pub file_id: u64,
    pub dev_id: i32,
    pub flags: u32,
    /// `ATTR_FILE_DATALENGTH`: the data fork's logical size.
    pub logical: u64,
    /// `ATTR_FILE_ALLOCSIZE`: bytes on disk across all of the file's forks.
    pub allocated: u64,
    pub link_count: u32,
}

/// The object types the scanner distinguishes.
///
/// The discriminants come from `enum vtype` in
/// `$(xcrun --show-sdk-path)/usr/include/sys/vnode.h`, not from memory;
/// `obj_type_discriminants_match_lstat` re-checks them against `lstat(2)` on a
/// captured buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObjType {
    Reg,
    Dir,
    Lnk,
    /// Any other `fsobj_type_t`, and any entry whose `ATTR_CMN_OBJTYPE` the
    /// kernel did not supply.
    Other,
}

/// Why an entry could not be parsed. Any error ends iteration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    /// The buffer ran out before an entry the kernel promised could be read.
    Truncated,
    /// An entry length that cannot describe an entry: zero, below the fixed
    /// header, or reaching past the end of the buffer.
    BadLength,
    /// The name's `attrreference_t` does not point at a byte range inside its
    /// own entry.
    NameOutOfBounds,
}

/// Iterator over a `getattrlistbulk` buffer. See [`entries`].
#[derive(Debug, Clone)]
pub struct EntryIter<'a> {
    buf: &'a [u8],
    /// Offset of the next entry. Only ever advanced by a length already
    /// validated against `buf.len()`, so it never exceeds it.
    pos: usize,
    /// Entries the kernel still promises. Decremented on every `next`, which
    /// is what bounds iteration: a malformed buffer cannot be walked forever.
    left: u32,
    done: bool,
}

/// Parse `count` entries out of one `getattrlistbulk` output buffer.
///
/// `count` is the syscall's return value. Iteration yields at most that many
/// items and stops at the first error, so no input — a zero entry length
/// included — can make it loop forever. The function is pure over `buf` and
/// panics on no input.
pub fn entries(buf: &[u8], count: u32) -> EntryIter<'_> {
    EntryIter {
        buf,
        pos: 0,
        left: count,
        done: false,
    }
}

impl<'a> Iterator for EntryIter<'a> {
    type Item = Result<RawEntry<'a>, ParseError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.done || self.left == 0 {
            return None;
        }
        // Decrement first: every path below either yields or stops, so the
        // promised count strictly bounds the number of iterations.
        self.left -= 1;
        // `pos <= buf.len()` is an invariant, but take the fallible slice so
        // that a broken invariant could not panic either.
        let rest = self.buf.get(self.pos..).unwrap_or(&[]);
        match parse_entry(rest) {
            Ok((entry, len)) => {
                self.pos += len;
                Some(Ok(entry))
            }
            Err(e) => {
                self.done = true;
                Some(Err(e))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Measured layout
// ---------------------------------------------------------------------------

/// Offset of the leading entry length.
const OFF_LENGTH: usize = 0;
/// `commonattr` word of the returned-attributes set.
const OFF_RETURNED_COMMON: usize = 4;
/// `fileattr` word of the returned-attributes set.
const OFF_RETURNED_FILE: usize = 16;
/// The `ATTR_CMN_NAME` `attrreference_t`: `i32` offset then `u32` length.
const OFF_NAME_REF: usize = 24;
const OFF_DEVID: usize = 32;
const OFF_OBJTYPE: usize = 36;
const OFF_FLAGS: usize = 40;
const OFF_FILEID: usize = 44;
const OFF_LINKCOUNT: usize = 52;
const OFF_ALLOCSIZE: usize = 56;
const OFF_DATALENGTH: usize = 64;

/// An entry must at least hold its length, the returned-attributes set and the
/// name reference. Anything shorter cannot be an entry for this mask.
const MIN_ENTRY_LEN: usize = OFF_NAME_REF + 8;

/// The earliest byte the variable-length region can start at: immediately
/// after the name reference itself. Requiring this also keeps the name slice
/// from ever overlapping the fields parsed above it.
const MIN_NAME_START: usize = OFF_NAME_REF + 8;

/// `fsobj_type_t` values from `enum vtype` in `<sys/vnode.h>`:
/// `VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX`.
const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

/// A bit of the `commonattr` word of `ATTR_CMN_RETURNED_ATTRS`.
///
/// `ATTR_CMN_NAME` and `ATTR_FILE_LINKCOUNT` are both `0x1`, in different
/// groups. These two wrappers make testing a common bit against the file word
/// (or the reverse) a compile error rather than a silent misread.
#[derive(Debug, Clone, Copy)]
struct CommonBit(u32);

/// A bit of the `fileattr` word of `ATTR_CMN_RETURNED_ATTRS`.
#[derive(Debug, Clone, Copy)]
struct FileBit(u32);

const RET_DEVID: CommonBit = CommonBit(libc::ATTR_CMN_DEVID);
const RET_OBJTYPE: CommonBit = CommonBit(libc::ATTR_CMN_OBJTYPE);
const RET_FLAGS: CommonBit = CommonBit(libc::ATTR_CMN_FLAGS);
const RET_FILEID: CommonBit = CommonBit(libc::ATTR_CMN_FILEID);
const RET_LINKCOUNT: FileBit = FileBit(libc::ATTR_FILE_LINKCOUNT);
const RET_ALLOCSIZE: FileBit = FileBit(libc::ATTR_FILE_ALLOCSIZE);
const RET_DATALENGTH: FileBit = FileBit(libc::ATTR_FILE_DATALENGTH);

/// The `ATTR_CMN_RETURNED_ATTRS` words this parser consults.
#[derive(Debug, Clone, Copy)]
struct Returned {
    common: u32,
    file: u32,
}

impl Returned {
    fn has_common(self, bit: CommonBit) -> bool {
        self.common & bit.0 != 0
    }

    fn has_file(self, bit: FileBit) -> bool {
        self.file & bit.0 != 0
    }
}

// ---------------------------------------------------------------------------
// Entry parsing
// ---------------------------------------------------------------------------

/// Parse the entry at the start of `rest`, returning it and its length.
///
/// Every read is bounds-checked; this function cannot panic for any `rest`.
fn parse_entry(rest: &[u8]) -> Result<(RawEntry<'_>, usize), ParseError> {
    // (1) Entry length, checked against the bytes actually available. Zero and
    // anything past the end of the buffer are rejected here, which is what
    // keeps a malformed buffer from being walked forever.
    let len = read_u32(rest, OFF_LENGTH, rest.len()).ok_or(ParseError::Truncated)? as usize;
    if len < MIN_ENTRY_LEN || len > rest.len() {
        return Err(ParseError::BadLength);
    }
    // From here on every offset is checked against `entry`, not `rest`: an
    // entry may not read into its successor.
    let entry = rest.get(..len).ok_or(ParseError::BadLength)?;

    // (2) Returned-attributes set. Guaranteed in range by `MIN_ENTRY_LEN`, but
    // read fallibly so that a future constant change cannot make this panic.
    let returned = Returned {
        common: read_u32(entry, OFF_RETURNED_COMMON, len).ok_or(ParseError::Truncated)?,
        file: read_u32(entry, OFF_RETURNED_FILE, len).ok_or(ParseError::Truncated)?,
    };

    // (3) The name reference. `attr_dataoffset` is relative to the address of
    // the `attrreference_t` itself, which is `OFF_NAME_REF` bytes into the
    // entry -- measured, not inferred: in the minimal mask the offset is
    // exactly 8, placing the name directly after the reference.
    let data_offset = read_i32(entry, OFF_NAME_REF, len).ok_or(ParseError::Truncated)?;
    let name_len = read_u32(entry, OFF_NAME_REF + 4, len).ok_or(ParseError::Truncated)?;
    // Widened to i64 so a negative or huge offset cannot wrap. The widest
    // possible sum is 24 + i32::MAX + u32::MAX, far inside i64.
    let start = OFF_NAME_REF as i64 + i64::from(data_offset);
    let end = start + i64::from(name_len);
    if start < MIN_NAME_START as i64 || end > len as i64 {
        return Err(ParseError::NameOutOfBounds);
    }
    let (name_start, name_end) = (start as usize, end as usize);
    let name_field = entry
        .get(name_start..name_end)
        .ok_or(ParseError::NameOutOfBounds)?;
    // The field is NUL-terminated and padded; a filename cannot contain NUL,
    // so the name is everything before the first one. Kept as bytes
    // throughout: no `str`, no `String`, no lossy conversion.
    let name = match name_field.iter().position(|&b| b == 0) {
        Some(i) => name_field.get(..i).unwrap_or(&[]),
        None => name_field,
    };

    // (4) The fixed-field region ends where the variable-length region
    // begins. This is the kernel's own account of the layout, and it is what
    // tells a directory's entry (no `fileattr` group) from a file's.
    let fixed_end = name_start.min(len);

    let obj_type = match returned
        .has_common(RET_OBJTYPE)
        .then(|| read_u32(entry, OFF_OBJTYPE, fixed_end))
        .flatten()
    {
        Some(VREG) => ObjType::Reg,
        Some(VDIR) => ObjType::Dir,
        Some(VLNK) => ObjType::Lnk,
        _ => ObjType::Other,
    };

    Ok((
        RawEntry {
            name,
            obj_type,
            file_id: gated(returned.has_common(RET_FILEID), || {
                read_u64(entry, OFF_FILEID, fixed_end)
            }),
            dev_id: gated(returned.has_common(RET_DEVID), || {
                read_i32(entry, OFF_DEVID, fixed_end)
            }),
            flags: gated(returned.has_common(RET_FLAGS), || {
                read_u32(entry, OFF_FLAGS, fixed_end)
            }),
            logical: gated(returned.has_file(RET_DATALENGTH), || {
                read_u64(entry, OFF_DATALENGTH, fixed_end)
            }),
            allocated: gated(returned.has_file(RET_ALLOCSIZE), || {
                read_u64(entry, OFF_ALLOCSIZE, fixed_end)
            }),
            link_count: gated(returned.has_file(RET_LINKCOUNT), || {
                read_u32(entry, OFF_LINKCOUNT, fixed_end)
            }),
        },
        len,
    ))
}

/// A field's value, or its default when either gate rejects it: the kernel did
/// not supply the attribute, or the slot does not lie in the fixed region.
fn gated<T: Default>(supplied: bool, read: impl FnOnce() -> Option<T>) -> T {
    if supplied {
        read().unwrap_or_default()
    } else {
        T::default()
    }
}

/// Read `N` bytes at `off`, provided the whole range lies within `limit` and
/// within `buf`. Both checks are kept: `limit` is the end of the fixed-field
/// region, and the slice is what makes a panic impossible.
fn read_bytes<const N: usize>(buf: &[u8], off: usize, limit: usize) -> Option<[u8; N]> {
    let end = off.checked_add(N)?;
    if end > limit {
        return None;
    }
    buf.get(off..end)?.try_into().ok()
}

fn read_u32(buf: &[u8], off: usize, limit: usize) -> Option<u32> {
    read_bytes::<4>(buf, off, limit).map(u32::from_le_bytes)
}

fn read_i32(buf: &[u8], off: usize, limit: usize) -> Option<i32> {
    read_bytes::<4>(buf, off, limit).map(i32::from_le_bytes)
}

/// Note the byte copy: `ATTR_CMN_FILEID` sits at offset 44, so a `u64` here is
/// not 8-byte aligned.
fn read_u64(buf: &[u8], off: usize, limit: usize) -> Option<u64> {
    read_bytes::<8>(buf, off, limit).map(u64::from_le_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attrs::{COMMON_MASK, FILE_MASK};
    use std::path::PathBuf;

    // -- synthetic buffers ------------------------------------------------

    /// Hand-assembles one entry in the measured layout, so a test can create
    /// shapes the filesystem will not produce: a name that is not UTF-8
    /// (macOS rejects those at the syscall boundary -- measured `EILSEQ` on
    /// APFS, `EINVAL` on exFAT), an attribute reported as not supplied, or a
    /// name reference pointing out of bounds.
    #[derive(Debug, Clone)]
    struct Synth {
        returned_common: u32,
        returned_file: u32,
        dev_id: i32,
        obj_type: u32,
        flags: u32,
        file_id: u64,
        link_count: u32,
        allocated: u64,
        logical: u64,
        /// Emit the three `fileattr` slots. The kernel omits them entirely for
        /// a directory.
        file_group: bool,
        name: Vec<u8>,
        /// Override `attrreference_t::attr_dataoffset`.
        name_offset: Option<i32>,
        /// Override `attrreference_t::attr_length`.
        name_length: Option<u32>,
        /// Override the leading entry length.
        entry_length: Option<u32>,
    }

    impl Default for Synth {
        fn default() -> Self {
            Self {
                returned_common: COMMON_MASK,
                returned_file: FILE_MASK,
                dev_id: 0x0100_000F,
                obj_type: VREG,
                flags: 0,
                file_id: 0x0123_4567_89AB_CDEF,
                link_count: 1,
                allocated: 4096,
                logical: 4096,
                file_group: true,
                name: b"synthetic.bin".to_vec(),
                name_offset: None,
                name_length: None,
                entry_length: None,
            }
        }
    }

    impl Synth {
        fn build(&self) -> Vec<u8> {
            let fixed_end = if self.file_group {
                OFF_DATALENGTH + 8
            } else {
                OFF_LINKCOUNT
            };
            let mut e = vec![0u8; fixed_end];
            e[OFF_RETURNED_COMMON..][..4].copy_from_slice(&self.returned_common.to_le_bytes());
            e[OFF_RETURNED_FILE..][..4].copy_from_slice(&self.returned_file.to_le_bytes());
            let data_offset = self
                .name_offset
                .unwrap_or((fixed_end - OFF_NAME_REF) as i32);
            let name_length = self.name_length.unwrap_or(self.name.len() as u32 + 1);
            e[OFF_NAME_REF..][..4].copy_from_slice(&data_offset.to_le_bytes());
            e[OFF_NAME_REF + 4..][..4].copy_from_slice(&name_length.to_le_bytes());
            e[OFF_DEVID..][..4].copy_from_slice(&self.dev_id.to_le_bytes());
            e[OFF_OBJTYPE..][..4].copy_from_slice(&self.obj_type.to_le_bytes());
            e[OFF_FLAGS..][..4].copy_from_slice(&self.flags.to_le_bytes());
            e[OFF_FILEID..][..8].copy_from_slice(&self.file_id.to_le_bytes());
            if self.file_group {
                e[OFF_LINKCOUNT..][..4].copy_from_slice(&self.link_count.to_le_bytes());
                e[OFF_ALLOCSIZE..][..8].copy_from_slice(&self.allocated.to_le_bytes());
                e[OFF_DATALENGTH..][..8].copy_from_slice(&self.logical.to_le_bytes());
            }
            e.extend_from_slice(&self.name);
            e.push(0);
            while e.len() % 8 != 0 {
                e.push(0);
            }
            let len = self.entry_length.unwrap_or(e.len() as u32);
            e[OFF_LENGTH..][..4].copy_from_slice(&len.to_le_bytes());
            e
        }
    }

    fn one(s: &Synth) -> RawEntry<'static> {
        // Leaked so the borrow outlives the buffer the test built; the test
        // process is short-lived and this keeps assertions readable.
        let buf: &'static [u8] = Box::leak(s.build().into_boxed_slice());
        let mut it = entries(buf, 1);
        let entry = it.next().expect("one entry").expect("parses");
        assert!(it.next().is_none(), "count 1 must yield exactly one entry");
        entry
    }

    // -- golden corpus ----------------------------------------------------

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    /// The recorded `getattrlistbulk` bytes and the entry count the syscall
    /// returned. See `tests/golden_capture.rs` for the format.
    fn golden(name: &str) -> (Vec<u8>, u32) {
        let raw = std::fs::read(fixture(&format!("golden_{name}.bin"))).unwrap();
        assert_eq!(&raw[..8], b"TSRGOLD1", "bad golden magic in {name}");
        let count = u32::from_le_bytes(raw[8..12].try_into().unwrap());
        let len = u32::from_le_bytes(raw[12..16].try_into().unwrap()) as usize;
        assert_eq!(raw.len(), 16 + len, "golden_{name}.bin length header wrong");
        (raw[16..].to_vec(), count)
    }

    /// One row of the `lstat(2)`-derived expectation sidecar. Independent of
    /// this parser, so a parser bug cannot be baked into both sides.
    #[derive(Debug, PartialEq)]
    struct Expect {
        name: Vec<u8>,
        kind: String,
        ino: u64,
        dev: i32,
        nlink: u32,
        logical: u64,
        allocated: u64,
    }

    fn expectations(name: &str) -> Vec<Expect> {
        let text = std::fs::read_to_string(fixture(&format!("golden_{name}.expect"))).unwrap();
        let rows: Vec<Expect> = text
            .lines()
            .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
            .map(|l| {
                let f: Vec<&str> = l.split('\t').collect();
                assert_eq!(f.len(), 7, "bad expectation row: {l}");
                Expect {
                    name: (0..f[0].len() / 2)
                        .map(|i| u8::from_str_radix(&f[0][i * 2..i * 2 + 2], 16).unwrap())
                        .collect(),
                    kind: f[1].to_string(),
                    ino: f[2].parse().unwrap(),
                    dev: f[3].parse().unwrap(),
                    nlink: f[4].parse().unwrap(),
                    logical: f[5].parse().unwrap(),
                    allocated: f[6].parse().unwrap(),
                }
            })
            .collect();
        assert!(!rows.is_empty(), "golden_{name}.expect is empty");
        rows
    }

    /// Parse a golden buffer and project it into the sidecar's shape, sorted
    /// so the comparison does not depend on directory order.
    fn parsed_as_expectations(name: &str) -> Vec<Expect> {
        let (buf, count) = golden(name);
        let mut rows: Vec<Expect> = entries(&buf, count)
            .map(|e| {
                let e = e.expect("golden buffer must parse");
                Expect {
                    name: e.name.to_vec(),
                    kind: match e.obj_type {
                        ObjType::Reg => "reg",
                        ObjType::Dir => "dir",
                        ObjType::Lnk => "lnk",
                        ObjType::Other => "other",
                    }
                    .to_string(),
                    ino: e.file_id,
                    dev: e.dev_id,
                    nlink: e.link_count,
                    logical: e.logical,
                    allocated: e.allocated,
                }
            })
            .collect();
        assert_eq!(rows.len(), count as usize, "iterator dropped entries");
        rows.sort_by(|a, b| a.name.cmp(&b.name));
        rows
    }

    // -- the brief's eight tests ------------------------------------------

    #[test]
    fn parses_golden_buffer_into_expected_entries() {
        // golden_simple.bin: file("a.bin", 4096) + dir("d").
        let rows = parsed_as_expectations("simple");

        let names: Vec<&[u8]> = rows.iter().map(|r| r.name.as_slice()).collect();
        assert_eq!(names, vec![&b"a.bin"[..], &b"d"[..]]);
        let kinds: Vec<&str> = rows.iter().map(|r| r.kind.as_str()).collect();
        assert_eq!(kinds, vec!["reg", "dir"]);
        // The file is dense, so one 4 KiB block is really allocated. The
        // directory's entry carries no `fileattr` group at all, so its
        // allocated size is the default -- not a misread of its name bytes.
        assert_eq!(rows[0].allocated, 4096);
        assert_eq!(rows[0].logical, 4096);
        assert_eq!(rows[0].nlink, 1);
        assert_eq!(rows[1].allocated, 0);
        assert_eq!(rows[1].logical, 0);
        assert_eq!(rows[1].nlink, 0);

        // And every field agrees with `lstat(2)` on the same tree.
        assert_eq!(rows, expectations("simple"));
    }

    #[test]
    fn preserves_non_utf8_names_as_bytes() {
        // Synthetic: macOS rejects invalid UTF-8 filenames at the syscall
        // boundary, so no fixture on this platform can produce one.
        const BAD: &[u8] = b"bad\xff\xfename";
        let entry = one(&Synth {
            name: BAD.to_vec(),
            ..Default::default()
        });
        assert_eq!(entry.name, BAD);
        // Asserted on what came out of the parser: these bytes are not UTF-8,
        // so any `str` conversion on the way would have had to be lossy.
        assert!(
            std::str::from_utf8(entry.name).is_err(),
            "the name must still be invalid UTF-8 after parsing"
        );
    }

    #[test]
    fn absent_attribute_yields_default_not_shifted_read() {
        // The slot is present and holds a loud value, but the kernel says the
        // attribute was not supplied. The value must be the default, and
        // every field after it must still be read from its own offset.
        let entry = one(&Synth {
            returned_file: FILE_MASK & !libc::ATTR_FILE_ALLOCSIZE,
            allocated: 0xDEAD_BEEF_DEAD_BEEF,
            logical: 123_456,
            link_count: 7,
            ..Default::default()
        });
        assert_eq!(entry.allocated, 0, "unsupplied attribute must not be read");
        assert_eq!(entry.logical, 123_456, "the next field must not shift");
        assert_eq!(entry.link_count, 7, "the previous field must not shift");
        assert_eq!(entry.name, b"synthetic.bin");
    }

    #[test]
    fn rejects_entry_length_exceeding_buffer() {
        assert_eq!(
            entries(&[0xFF, 0xFF, 0xFF, 0x7F], 1).next(),
            Some(Err(ParseError::BadLength))
        );
    }

    #[test]
    fn rejects_zero_entry_length() {
        let buf = Synth {
            entry_length: Some(0),
            ..Default::default()
        }
        .build();
        // The classic infinite-loop input: advancing by zero would revisit the
        // same bytes forever. Ask for far more entries than the buffer holds
        // and require that iteration ends immediately.
        let mut it = entries(&buf, u32::MAX);
        assert_eq!(it.next(), Some(Err(ParseError::BadLength)));
        for _ in 0..4 {
            assert_eq!(it.next(), None, "iteration must end after an error");
        }
        // Independently: the whole iterator is finite even at u32::MAX.
        assert_eq!(entries(&buf, u32::MAX).count(), 1);
    }

    #[test]
    fn rejects_name_reference_pointing_outside_entry() {
        // Past the end of the entry.
        let past = Synth {
            name_offset: Some(1000),
            ..Default::default()
        }
        .build();
        assert_eq!(
            entries(&past, 1).next(),
            Some(Err(ParseError::NameOutOfBounds))
        );
        // Backwards, out of the entry entirely.
        let before = Synth {
            name_offset: Some(-100),
            ..Default::default()
        }
        .build();
        assert_eq!(
            entries(&before, 1).next(),
            Some(Err(ParseError::NameOutOfBounds))
        );
        // Backwards, into the fields this parser reads: still refused, so the
        // name can never alias the header.
        let aliasing = Synth {
            name_offset: Some(-16),
            ..Default::default()
        }
        .build();
        assert_eq!(
            entries(&aliasing, 1).next(),
            Some(Err(ParseError::NameOutOfBounds))
        );
        // Offset in range but length running off the end.
        let overlong = Synth {
            name_length: Some(u32::MAX),
            ..Default::default()
        }
        .build();
        assert_eq!(
            entries(&overlong, 1).next(),
            Some(Err(ParseError::NameOutOfBounds))
        );
    }

    #[test]
    fn stops_at_count_even_if_buffer_has_more_bytes() {
        let mut buf = Vec::new();
        for n in ["one.bin", "two.bin", "three.bin"] {
            buf.extend_from_slice(
                &Synth {
                    name: n.as_bytes().to_vec(),
                    ..Default::default()
                }
                .build(),
            );
        }
        let got: Vec<Vec<u8>> = entries(&buf, 2).map(|e| e.unwrap().name.to_vec()).collect();
        assert_eq!(got, vec![b"one.bin".to_vec(), b"two.bin".to_vec()]);
    }

    #[test]
    fn empty_buffer_yields_no_entries() {
        assert!(entries(&[], 0).next().is_none());
    }

    // -- further coverage of the measured layout --------------------------

    /// Re-derives the layout from a captured buffer on every run, so the
    /// constants above cannot drift away from the bytes they were measured
    /// from without a test failing.
    #[test]
    fn layout_matches_the_captured_golden_buffer() {
        let (buf, count) = golden("simple");
        assert_eq!(count, 2);

        // Entry 0: the regular file. Full fixed region, name at 72.
        let len0 = u32::from_le_bytes(buf[0..4].try_into().unwrap()) as usize;
        assert_eq!(len0, 80, "a.bin entry length");
        assert_eq!(
            u32::from_le_bytes(buf[OFF_RETURNED_COMMON..][..4].try_into().unwrap()),
            COMMON_MASK
        );
        assert_eq!(
            u32::from_le_bytes(buf[OFF_RETURNED_FILE..][..4].try_into().unwrap()),
            FILE_MASK
        );
        let off0 = i32::from_le_bytes(buf[OFF_NAME_REF..][..4].try_into().unwrap());
        assert_eq!(
            OFF_NAME_REF as i64 + i64::from(off0),
            (OFF_DATALENGTH + 8) as i64,
            "the name reference's own address is the base of its offset"
        );
        assert_eq!(&buf[72..77], b"a.bin");

        // Entry 1: the directory. No `fileattr` group, so the name starts
        // where ATTR_FILE_LINKCOUNT would have been.
        let e1 = &buf[len0..];
        let len1 = u32::from_le_bytes(e1[0..4].try_into().unwrap()) as usize;
        assert_eq!(len1, 56, "directory entry length");
        assert_eq!(
            u32::from_le_bytes(e1[OFF_RETURNED_FILE..][..4].try_into().unwrap()),
            0,
            "a directory reports no fileattr at all"
        );
        let off1 = i32::from_le_bytes(e1[OFF_NAME_REF..][..4].try_into().unwrap());
        assert_eq!(
            OFF_NAME_REF as i64 + i64::from(off1),
            OFF_LINKCOUNT as i64,
            "the directory's fileattr slots are absent, not zero-filled"
        );
        assert_eq!(&e1[OFF_LINKCOUNT..OFF_LINKCOUNT + 1], b"d");
    }

    /// The gate that does the real work for directories: even if the returned
    /// set claimed the `fileattr` attributes were supplied, the slots are not
    /// in the fixed region, so they are never read out of the name bytes.
    #[test]
    fn absent_file_group_is_not_read_from_the_name_bytes() {
        let entry = one(&Synth {
            file_group: false,
            // Deliberately inconsistent: the layout gate must still win.
            returned_file: FILE_MASK,
            obj_type: VDIR,
            name: b"directory-name-long-enough-to-look-like-numbers".to_vec(),
            ..Default::default()
        });
        assert_eq!(entry.obj_type, ObjType::Dir);
        assert_eq!(
            entry.name,
            b"directory-name-long-enough-to-look-like-numbers"
        );
        assert_eq!(
            (entry.link_count, entry.allocated, entry.logical),
            (0, 0, 0)
        );
        // The common fields, which do fit, are still read correctly.
        assert_eq!(entry.file_id, 0x0123_4567_89AB_CDEF);
        assert_eq!(entry.dev_id, 0x0100_000F);
    }

    #[test]
    fn parses_golden_mixed_buffer_into_expected_entries() {
        let rows = parsed_as_expectations("mixed");
        assert_eq!(rows, expectations("mixed"));

        let by_name = |n: &[u8]| rows.iter().find(|r| r.name == n).expect("entry present");

        // A multi-byte UTF-8 name survives byte for byte.
        let cafe = by_name(b"caf\xc3\xa9 \xe2\x82\xac.bin");
        assert_eq!(cafe.kind, "reg");

        // A sparse file: a huge logical size with nothing allocated. Reading
        // either field from the wrong offset would be obvious here.
        let sparse = by_name(b"sparse.bin");
        assert_eq!((sparse.logical, sparse.allocated), (1 << 30, 0));

        // The hardlink pair: one inode, two names, link count 2.
        let a = by_name(b"hardlink.bin");
        let b = by_name(b"link-target.bin");
        assert_eq!(a.ino, b.ino);
        assert_eq!((a.nlink, b.nlink), (2, 2));

        // The clone is a distinct inode that still accounts for its blocks.
        let clone = by_name(b"clone.bin");
        let dense = by_name(b"dense.bin");
        assert_ne!(clone.ino, dense.ino);
        assert_eq!((clone.logical, clone.allocated), (8192, 8192));

        assert_eq!(by_name(b"dangling").kind, "lnk");
        let subdir = by_name(b"subdir");
        assert_eq!(subdir.kind, "dir");
        assert_eq!((subdir.nlink, subdir.logical, subdir.allocated), (0, 0, 0));
    }

    /// `ObjType`'s discriminants are checked against `lstat(2)`, not against
    /// recollection: the sidecar's `kind` column comes from `st_mode`.
    #[test]
    fn obj_type_discriminants_match_lstat() {
        for corpus in ["simple", "mixed"] {
            let parsed = parsed_as_expectations(corpus);
            let expected = expectations(corpus);
            let got: Vec<&str> = parsed.iter().map(|r| r.kind.as_str()).collect();
            let want: Vec<&str> = expected.iter().map(|r| r.kind.as_str()).collect();
            assert_eq!(got, want, "{corpus}");
            assert!(want.contains(&"dir"), "{corpus} must exercise VDIR");
        }
        assert!(expectations("mixed").iter().any(|r| r.kind == "lnk"));
    }

    /// The gate bits are taken from the right `attrlist` group.
    /// `ATTR_CMN_NAME` and `ATTR_FILE_LINKCOUNT` are both `0x1`.
    #[test]
    fn gate_bits_come_from_the_right_attribute_group() {
        assert_eq!(libc::ATTR_CMN_NAME, 0x0000_0001);
        assert_eq!(libc::ATTR_FILE_LINKCOUNT, 0x0000_0001);
        assert_eq!(RET_LINKCOUNT.0, 0x0000_0001);
        assert_eq!(RET_DEVID.0, 0x0000_0002);
        assert_eq!(RET_OBJTYPE.0, 0x0000_0008);
        assert_eq!(RET_FLAGS.0, 0x0004_0000);
        assert_eq!(RET_FILEID.0, 0x0200_0000);
        assert_eq!(RET_ALLOCSIZE.0, 0x0000_0004);
        assert_eq!(RET_DATALENGTH.0, 0x0000_0200);

        // A name whose bytes would decode as a plausible link count if the
        // common and file words were confused.
        let r = Returned {
            common: COMMON_MASK,
            file: 0,
        };
        assert!(r.has_common(RET_DEVID));
        assert!(!r.has_file(RET_LINKCOUNT));
    }

    #[test]
    fn truncated_buffer_reports_truncated() {
        // The kernel promises an entry but fewer than four bytes remain, so
        // there is not even a length field to check.
        for buf in [&[][..], &[0x50], &[0x50, 0, 0]] {
            assert_eq!(
                entries(buf, 1).next(),
                Some(Err(ParseError::Truncated)),
                "{buf:?}"
            );
        }
    }

    #[test]
    fn rejects_entry_shorter_than_the_fixed_header() {
        for len in [1u32, 4, 24, (MIN_ENTRY_LEN - 1) as u32] {
            let mut buf = vec![0u8; 128];
            buf[..4].copy_from_slice(&len.to_le_bytes());
            assert_eq!(
                entries(&buf, 1).next(),
                Some(Err(ParseError::BadLength)),
                "len {len}"
            );
        }
    }

    #[test]
    fn an_entry_never_reads_into_its_successor() {
        // Two entries; the first's name reference points past its own length
        // into the second entry's bytes. It must be refused, not followed.
        let first = Synth {
            name: b"first.bin".to_vec(),
            ..Default::default()
        }
        .build();
        let second = Synth {
            name: b"second.bin".to_vec(),
            ..Default::default()
        }
        .build();
        let overrun = Synth {
            name: b"first.bin".to_vec(),
            name_offset: Some((first.len() - OFF_NAME_REF + 8) as i32),
            ..Default::default()
        }
        .build();
        assert_eq!(overrun.len(), first.len());
        let mut buf = overrun;
        buf.extend_from_slice(&second);
        assert_eq!(
            entries(&buf, 2).next(),
            Some(Err(ParseError::NameOutOfBounds))
        );
    }

    /// Task 5 brings `cargo-fuzz`, ASAN and Miri over this code. This is the
    /// cheap standing version: mutate real kernel bytes every way a single
    /// truncation or byte flip can, and require that nothing panics and that
    /// iteration always terminates.
    #[test]
    fn never_panics_on_mutated_golden_bytes() {
        let (buf, count) = golden("simple");

        let drain = |b: &[u8], n: u32| {
            let mut seen = 0usize;
            for item in entries(b, n) {
                let _ = item;
                seen += 1;
                assert!(seen <= n as usize, "iterator exceeded its count");
            }
        };

        for n in [0u32, 1, 2, 3, count, u32::MAX] {
            for cut in 0..=buf.len() {
                drain(&buf[..cut], n);
            }
            for i in 0..buf.len() {
                for bit in 0..8 {
                    let mut m = buf.clone();
                    m[i] ^= 1 << bit;
                    drain(&m, n);
                }
            }
            // Whole-byte replacements at the length and name-reference words,
            // where the dangerous values live.
            for i in 0..OFF_NAME_REF + 8 {
                for v in [0x00u8, 0x01, 0x7F, 0x80, 0xFF] {
                    let mut m = buf.clone();
                    m[i] = v;
                    drain(&m, n);
                }
            }
        }
    }
}
