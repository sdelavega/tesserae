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
//! So an entry must first have one of the two measured shapes, and a slot's
//! value is then used only when two independent gates agree:
//!
//! * **The shape gate.** The name's `attr_dataoffset` marks where the
//!   variable-length region begins, which makes it the kernel's own statement
//!   of where the fixed-field region ends. Over a full scan of a Data volume
//!   (6.7 million entries: directories, regular files, symlinks, sockets and
//!   fifos) and on HFS+, exFAT and FAT32 images, that end was only ever 52
//!   with the `fileattr` word zero (every directory) or 72 with it non-zero
//!   (everything else). Any other size, or a size that disagrees with the
//!   `fileattr` word, is [`ParseError::UnexpectedLayout`]: a kernel that
//!   packed this mask differently would put a neighbour's bytes under the
//!   constant offsets, so the entry is refused rather than read.
//! * **The layout gate.** A slot that does not fit entirely before the end of
//!   the fixed region is not a field, and is reported as its default.
//! * **The returned-attributes gate.** `ATTR_CMN_RETURNED_ATTRS` says whether
//!   a present slot holds a real value. A slot whose bit is clear is reported
//!   as its default, which is what `FSOPT_PACK_INVAL_ATTRS` asks a caller to
//!   do with a zero-filled invalid attribute.
//!
//! Field offsets are compile-time constants in either shape, so no gate can
//! shift a later read: a surprise yields a default or a refused entry, never
//! another field's bytes.
//!
//! The name reference is the one slot that cannot be handled that way, because
//! its own value is what locates the fixed region's end and therefore gates
//! everything else. It has no safe default, so its returned bit is checked
//! *before* it is read and a clear bit ends the entry with
//! [`ParseError::NameOutOfBounds`] rather than yielding a shifted layout. The
//! doctrine holds for all eight slots with no silent exception.

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
    /// `ATTR_CMN_FLAGS` (`st_flags`). Unread in Phase 1; see
    /// [`crate::attrs::COMMON_MASK`] for why it is requested.
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
    /// The name's `attrreference_t` was not supplied, or does not point at a
    /// byte range inside its own entry. Either way the entry's layout cannot
    /// be established, so no field is reported rather than some being read
    /// from a shifted offset.
    NameOutOfBounds,
    /// The fixed-field region is not one of the two layouts measured for this
    /// mask: 52 bytes with no `fileattr` attribute returned (a directory), or
    /// 72 bytes with at least one (everything else). The constant offsets
    /// describe only those two, so no field is read from any other.
    UnexpectedLayout,
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

/// Where the fixed-field region ends, and so the name begins, in the two
/// measured layouts: without the `fileattr` group (a directory) and with it.
/// No other region size has been observed for this mask -- not over a full
/// scan of a 6.7-million-entry Data volume, nor on HFS+, exFAT or FAT32 -- and
/// the parser accepts no other.
const DIR_FIXED_END: usize = OFF_LINKCOUNT;
const FILE_FIXED_END: usize = OFF_DATALENGTH + 8;

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

const RET_NAME: CommonBit = CommonBit(libc::ATTR_CMN_NAME);
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

    // (3) The name reference, which is the one slot that must be gated before
    // it is read rather than after. Every other offset in the entry is derived
    // from its `attr_dataoffset`, so if the slot were absent the whole layout
    // would shift by 8 and this parser would read `OBJTYPE | FLAGS` as the
    // reference and the low half of `FILEID` as `DEVID` -- the silent misread,
    // arriving through the one slot otherwise trusted unconditionally.
    //
    // A conforming kernel cannot get here: `ATTR_CMN_NAME` is
    // `ATTR_BULK_REQUIRED`, `getattrlistbulk` rejects a mask without it, and
    // the bit is set on every entry of every captured fixture. The check costs
    // one comparison, no fuzzer can reach the bug it prevents (clearing a bit
    // in a fixed-layout buffer yields neither a crash nor a value wrong
    // relative to that buffer), and "unreachable from a conforming kernel" is
    // the class of assumption that produced this module's hardest surprise.
    if !returned.has_common(RET_NAME) {
        return Err(ParseError::NameOutOfBounds);
    }
    // `attr_dataoffset` is relative to the address of the `attrreference_t`
    // itself, which is `OFF_NAME_REF` bytes into the entry -- measured, not
    // inferred: in the minimal mask the offset is exactly 8, placing the name
    // directly after the reference.
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
    // tells a directory's entry (no `fileattr` group) from a file's. Only the
    // two measured shapes are accepted: a region of any other size, or one
    // whose size disagrees with the returned `fileattr` word, is a packing
    // these offsets do not describe, and reading it would be the plausible
    // wrong number this module exists to prevent.
    let fixed_end = match (name_start, returned.file) {
        (DIR_FIXED_END, 0) => DIR_FIXED_END,
        (FILE_FIXED_END, file) if file != 0 => FILE_FIXED_END,
        _ => return Err(ParseError::UnexpectedLayout),
    };

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

    // -- synthetic buffers ------------------------------------------------
    //
    // Shared builders. Everything in `synthetic` is pure over bytes it
    // assembles itself -- no filesystem, no syscall -- which is what lets Miri
    // run it. See `scripts/parser-sanitizers.sh`.

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
        /// Override where the fixed-field region ends and the name begins.
        /// Slots past it are cut off; bytes added before it are 0xA5. Builds
        /// the region sizes no measured kernel produces.
        fixed_end: Option<usize>,
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
                fixed_end: None,
            }
        }
    }

    impl Synth {
        fn build(&self) -> Vec<u8> {
            let fixed_end = self.fixed_end.unwrap_or(if self.file_group {
                FILE_FIXED_END
            } else {
                DIR_FIXED_END
            });
            let mut e = vec![0u8; fixed_end.max(FILE_FIXED_END)];
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
            // Cut back to the region, or pad it out to an overridden length.
            e.resize(FILE_FIXED_END.min(fixed_end), 0);
            e.resize(fixed_end, 0xA5);
            e.extend_from_slice(&self.name);
            e.push(0);
            while !e.len().is_multiple_of(8) {
                e.push(0);
            }
            let len = self.entry_length.unwrap_or(e.len() as u32);
            e[OFF_LENGTH..][..4].copy_from_slice(&len.to_le_bytes());
            e
        }
    }

    /// Parse a buffer holding exactly one entry. The caller owns the buffer, so
    /// nothing is leaked: Miri's leak check stays on for the whole module.
    fn one(buf: &[u8]) -> RawEntry<'_> {
        let mut it = entries(buf, 1);
        let entry = it.next().expect("one entry").expect("parses");
        assert!(it.next().is_none(), "count 1 must yield exactly one entry");
        entry
    }

    /// Walk `entries(b, n)` to exhaustion and require it never yields more
    /// than `n` items. Reaching the end at all is the termination check: a
    /// zero-length entry that was followed forever would hang here.
    fn drain(b: &[u8], n: u32) {
        let mut seen = 0usize;
        for item in entries(b, n) {
            let _ = item;
            seen += 1;
            assert!(seen <= n as usize, "iterator exceeded its count");
        }
    }

    /// Every single truncation and every single bit flip of `buf`, plus whole-
    /// byte replacements at the length and name-reference words (where the
    /// dangerous values live), each walked under several promised counts
    /// including `u32::MAX`.
    fn mutate_and_drain(buf: &[u8], count: u32) {
        // Miri is ~1000x slower, so it walks only to completion (`u32::MAX`
        // never stops early: the buffer's own end or an error does); the
        // native run also covers the early-stop counts.
        let counts: &[u32] = if cfg!(miri) {
            &[u32::MAX]
        } else {
            &[0, 1, 2, 3, count, u32::MAX]
        };
        for &n in counts {
            for cut in 0..=buf.len() {
                drain(&buf[..cut], n);
            }
            for i in 0..buf.len() {
                for bit in 0..8 {
                    let mut m = buf.to_vec();
                    m[i] ^= 1 << bit;
                    drain(&m, n);
                }
            }
            for i in 0..OFF_NAME_REF + 8 {
                for v in [0x00u8, 0x01, 0x7F, 0x80, 0xFF] {
                    let mut m = buf.to_vec();
                    m[i] = v;
                    drain(&m, n);
                }
            }
        }
    }

    /// Tests that need nothing but bytes built in memory. **Miri runs exactly
    /// this module** (`parse::tests::synthetic`), so nothing here may touch the
    /// filesystem, the clock or a syscall.
    mod synthetic {
        use super::*;

        #[test]
        fn preserves_non_utf8_names_as_bytes() {
            // Synthetic: macOS rejects invalid UTF-8 filenames at the syscall
            // boundary, so no fixture on this platform can produce one.
            const BAD: &[u8] = b"bad\xff\xfename";
            let buf = Synth {
                name: BAD.to_vec(),
                ..Default::default()
            }
            .build();
            let entry = one(&buf);
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
            let buf = Synth {
                returned_file: FILE_MASK & !libc::ATTR_FILE_ALLOCSIZE,
                allocated: 0xDEAD_BEEF_DEAD_BEEF,
                logical: 123_456,
                link_count: 7,
                ..Default::default()
            }
            .build();
            let entry = one(&buf);
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

        /// The layout a directory's entry has: no `fileattr` group, and the
        /// returned set agreeing that none was supplied. Its file fields are
        /// defaults, never read out of the name bytes.
        #[test]
        fn absent_file_group_is_not_read_from_the_name_bytes() {
            let buf = Synth {
                file_group: false,
                returned_file: 0,
                obj_type: VDIR,
                name: b"directory-name-long-enough-to-look-like-numbers".to_vec(),
                ..Default::default()
            }
            .build();
            let entry = one(&buf);
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

        /// The two fixed-region sizes measured over a full scan of a Data volume
        /// and on HFS+, exFAT and FAT32 images are 52 (directories) and 72
        /// (everything else). Any other size is a layout this parser has never
        /// seen, where the constant offsets could land on a neighbour's bytes,
        /// so the entry is refused instead of read.
        #[test]
        fn rejects_fixed_regions_of_unmeasured_size() {
            // Controls: the builder's override makes entries the parser takes
            // at exactly the two measured sizes, so a rejection below is the
            // size and nothing else about the entry.
            for (fixed_end, file_group, returned_file) in
                [(DIR_FIXED_END, false, 0), (FILE_FIXED_END, true, FILE_MASK)]
            {
                let buf = Synth {
                    fixed_end: Some(fixed_end),
                    file_group,
                    returned_file,
                    ..Default::default()
                }
                .build();
                assert_eq!(one(&buf).name, b"synthetic.bin", "control {fixed_end}");
            }
            for fixed_end in [32, 40, 44, 48, 56, 60, 64, 68, 76, 80, 88, 128] {
                for (file_group, returned_file) in [(true, FILE_MASK), (false, 0)] {
                    let buf = Synth {
                        fixed_end: Some(fixed_end),
                        file_group,
                        returned_file,
                        ..Default::default()
                    }
                    .build();
                    assert_eq!(
                        entries(&buf, 1).next(),
                        Some(Err(ParseError::UnexpectedLayout)),
                        "fixed region of {fixed_end} bytes, returned.file {returned_file:#x}"
                    );
                }
            }
        }

        /// The size alone is not the layout: a 52-byte region that claims any
        /// `fileattr` attribute would report that attribute as zero (its slot
        /// cannot fit), and a 72-byte region claiming none is a shape no
        /// measured kernel produced. Both are refused.
        #[test]
        fn rejects_a_region_size_that_disagrees_with_the_returned_file_word() {
            for bit in [
                libc::ATTR_FILE_LINKCOUNT,
                libc::ATTR_FILE_ALLOCSIZE,
                libc::ATTR_FILE_DATALENGTH,
                FILE_MASK,
            ] {
                let dir = Synth {
                    file_group: false,
                    returned_file: bit,
                    obj_type: VDIR,
                    ..Default::default()
                }
                .build();
                assert_eq!(
                    entries(&dir, 1).next(),
                    Some(Err(ParseError::UnexpectedLayout)),
                    "52-byte region claiming file bit {bit:#x}"
                );
            }
            let file = Synth {
                returned_file: 0,
                ..Default::default()
            }
            .build();
            assert_eq!(
                entries(&file, 1).next(),
                Some(Err(ParseError::UnexpectedLayout)),
                "72-byte region claiming no file attribute"
            );
            // A partial word at 72 is the returned-attributes gate's business,
            // not the layout's: `absent_attribute_yields_default_not_shifted_read`.
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

        /// The other side of the same boundary, and the only entry shape that can
        /// be exactly `MIN_ENTRY_LEN` long: the name must then start at 32 with
        /// `attr_length == 0`. Its length and name reference are well formed,
        /// but a 32-byte fixed region is not a measured layout, so it is
        /// refused rather than parsed as an entry with every field defaulted.
        #[test]
        fn rejects_the_shortest_possible_entry_as_an_unmeasured_layout() {
            let mut buf = vec![0u8; MIN_ENTRY_LEN];
            buf[OFF_LENGTH..][..4].copy_from_slice(&(MIN_ENTRY_LEN as u32).to_le_bytes());
            buf[OFF_RETURNED_COMMON..][..4].copy_from_slice(&COMMON_MASK.to_le_bytes());
            buf[OFF_RETURNED_FILE..][..4].copy_from_slice(&FILE_MASK.to_le_bytes());
            // attr_dataoffset 8 puts the name immediately after the reference;
            // attr_length 0 leaves it empty.
            buf[OFF_NAME_REF..][..4].copy_from_slice(&8i32.to_le_bytes());
            buf[OFF_NAME_REF + 4..][..4].copy_from_slice(&0u32.to_le_bytes());

            let mut it = entries(&buf, 1);
            assert_eq!(it.next(), Some(Err(ParseError::UnexpectedLayout)));
            assert!(it.next().is_none());
        }

        /// The name reference is the one slot whose absence would shift every
        /// other offset, so it is gated before it is read. Unreachable from a
        /// conforming kernel -- `ATTR_CMN_NAME` is `ATTR_BULK_REQUIRED` -- and no
        /// fuzzer can reach it, because clearing the bit in a fixed-layout buffer
        /// produces neither a crash nor a value wrong relative to that buffer.
        #[test]
        fn rejects_an_unsupplied_name_reference() {
            let buf = Synth {
                returned_common: COMMON_MASK & !libc::ATTR_CMN_NAME,
                ..Default::default()
            }
            .build();
            assert_eq!(
                entries(&buf, 1).next(),
                Some(Err(ParseError::NameOutOfBounds)),
                "an absent name reference must end the entry, not shift the layout"
            );
            // Clearing any other common bit is a value gate, not a layout gate, so
            // those entries still parse -- the name slot is genuinely special.
            for bit in [
                libc::ATTR_CMN_DEVID,
                libc::ATTR_CMN_OBJTYPE,
                libc::ATTR_CMN_FLAGS,
                libc::ATTR_CMN_FILEID,
            ] {
                let buf = Synth {
                    returned_common: COMMON_MASK & !bit,
                    ..Default::default()
                }
                .build();
                let entry = entries(&buf, 1)
                    .next()
                    .expect("one entry")
                    .unwrap_or_else(|e| panic!("bit {bit:#x} must still parse, got {e:?}"));
                assert_eq!(entry.name, b"synthetic.bin");
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

        /// `never_panics_on_mutated_golden_bytes` over buffers built in memory,
        /// so Miri gets an adversarial walk too: it cannot read the fixtures.
        /// Covers a file, then a directory with no `fileattr` group that is
        /// not the first entry.
        #[test]
        fn never_panics_on_mutated_synthetic_buffers() {
            let mut buf = Vec::new();
            for s in [
                Synth::default(),
                Synth {
                    file_group: false,
                    returned_file: 0,
                    obj_type: VDIR,
                    name: b"dir".to_vec(),
                    ..Default::default()
                },
            ] {
                buf.extend_from_slice(&s.build());
            }
            // Precondition: unmutated, both entries parse, so the walk below
            // starts from a valid file and a valid directory.
            assert_eq!(entries(&buf, 2).filter(Result::is_ok).count(), 2);
            mutate_and_drain(&buf, 2);
        }
    }

    /// Tests that replay the committed golden fixtures from disk. Excluded under
    /// Miri, which cannot do the file I/O they need; everything they establish
    /// about the *layout* is re-checked by `synthetic` on bytes built in memory.
    #[cfg(not(miri))]
    mod golden {
        use super::*;
        use std::path::PathBuf;

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

        /// One entry of a golden buffer, split by hand so this test's decoding is
        /// independent of `parse_entry`.
        struct RawSlice<'a> {
            bytes: &'a [u8],
            len: usize,
            returned_common: u32,
            returned_file: u32,
            /// Where the name begins, relative to the entry: the kernel's own
            /// account of where the fixed-field region ends.
            name_start: usize,
            name: Vec<u8>,
        }

        /// Walk a golden buffer into its entries by length alone, decoding each by
        /// hand. Deliberately duplicates the layout knowledge rather than calling
        /// the parser: this is what keeps the layout test non-circular.
        fn raw_entries(buf: &[u8]) -> Vec<RawSlice<'_>> {
            let le32 = |b: &[u8], o: usize| u32::from_le_bytes(b[o..o + 4].try_into().unwrap());
            let mut out = Vec::new();
            let mut pos = 0usize;
            while pos < buf.len() {
                let e = &buf[pos..];
                let len = le32(e, OFF_LENGTH) as usize;
                let name_start = (OFF_NAME_REF as i64
                    + i64::from(i32::from_le_bytes(
                        e[OFF_NAME_REF..OFF_NAME_REF + 4].try_into().unwrap(),
                    ))) as usize;
                let name_len = le32(e, OFF_NAME_REF + 4) as usize;
                let field = &e[name_start..name_start + name_len];
                out.push(RawSlice {
                    bytes: &e[..len],
                    len,
                    returned_common: le32(e, OFF_RETURNED_COMMON),
                    returned_file: le32(e, OFF_RETURNED_FILE),
                    name_start,
                    name: field[..field.len() - 1].to_vec(),
                });
                pos += len;
            }
            out
        }

        /// Re-derives the layout from a captured buffer on every run, so the
        /// constants above cannot drift away from the bytes they were measured
        /// from without a test failing.
        ///
        /// Entries are found by name, not by position: `readdir` order is not
        /// guaranteed, and a recapture in a different order must not make the
        /// project's most important non-circular test fail spuriously.
        #[test]
        fn layout_matches_the_captured_golden_buffer() {
            let (buf, count) = golden("simple");
            assert_eq!(count, 2);
            let raw = raw_entries(&buf);
            assert_eq!(raw.len(), count as usize, "length walk lost an entry");
            let find = |n: &[u8]| {
                raw.iter()
                    .find(|r| r.name == n)
                    .unwrap_or_else(|| panic!("no entry named {}", String::from_utf8_lossy(n)))
            };

            // The regular file: full fixed region, name directly after it.
            let file = find(b"a.bin");
            assert_eq!(file.len, 80, "a.bin entry length");
            assert_eq!(file.returned_common, COMMON_MASK);
            assert_eq!(file.returned_file, FILE_MASK);
            assert_eq!(
                file.name_start,
                OFF_DATALENGTH + 8,
                "the name reference's own address is the base of its offset"
            );

            // The directory: no `fileattr` group, so the name starts where
            // ATTR_FILE_LINKCOUNT would have been.
            let dir = find(b"d");
            assert_eq!(dir.len, 56, "directory entry length");
            assert_eq!(
                dir.returned_file, 0,
                "a directory reports no fileattr at all"
            );
            assert_eq!(
                dir.name_start, OFF_LINKCOUNT,
                "the directory's fileattr slots are absent, not zero-filled"
            );
            // The decisive arithmetic: the fixed fields need 72 bytes and the
            // entry is 56, so the three slots cannot be present at any offset.
            assert!(dir.len < OFF_DATALENGTH + 8);
            assert_eq!(dir.bytes.len(), 56);

            // ATTR_CMN_NAME is set on every entry, which is why the unconditional
            // read it guards is unreachable from a conforming kernel.
            for r in &raw {
                assert_ne!(r.returned_common & libc::ATTR_CMN_NAME, 0);
            }
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

        /// The standing, cheap version of what `cargo-fuzz` does: mutate real
        /// kernel bytes every way a single truncation or byte flip can, and
        /// require that nothing panics and that iteration always terminates.
        /// Neither this nor the fuzzer can see a wrong-but-plausible value; the
        /// explicit gates and the golden comparisons above own that.
        #[test]
        fn never_panics_on_mutated_golden_bytes() {
            // Both corpora: `mixed` is the one with eight entries, so it exercises
            // multi-entry walking and a `fileattr`-less entry that is not first.
            for corpus in ["simple", "mixed"] {
                let (buf, count) = golden(corpus);
                mutate_and_drain(&buf, count);
            }
        }

        /// `fuzz/corpus/parse_entries/` seeds the fuzzer with the golden
        /// buffers, in the fuzz target's input layout: one count byte, then the
        /// buffer. A recapture of the fixtures would otherwise leave the seeds
        /// stale and the fuzzer quietly starting from old shapes.
        #[test]
        fn fuzz_seeds_are_the_golden_fixtures() {
            let seeds =
                PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fuzz/corpus/parse_entries");
            for corpus in ["simple", "mixed"] {
                let (buf, count) = golden(corpus);
                let seed = std::fs::read(seeds.join(format!("golden_{corpus}.bin")))
                    .unwrap_or_else(|e| panic!("fuzz seed for {corpus} missing: {e}"));
                let count = u8::try_from(count).expect("the fuzz target's count is one byte");
                assert_eq!(seed[0], count, "seed {corpus}: count byte");
                assert_eq!(&seed[1..], &buf[..], "seed {corpus}: buffer bytes");
            }
        }
    }
}
