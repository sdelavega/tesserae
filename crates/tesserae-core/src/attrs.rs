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

//! Attribute request for `getattrlistbulk(2)`.
//!
//! The masks defined here fix the byte layout of every buffer the kernel
//! returns for a scan, so the parser (and its golden fixtures) depend on them.
//! Changing any bit changes that layout: treat the masks as a format.
//!
//! The kernel packs attributes in its own logical order, which is not
//! guaranteed to follow ascending bit value. The parser must therefore derive
//! the order from captured buffers rather than assume one here.
//!
//! Neither `ATTR_DIR_ALLOCSIZE` nor `ATTR_FILE_TOTALSIZE` is requested. Both
//! name a single object's own size, not a recursive total — `getattrlist(2)`
//! has no recursive-size attribute at all — so the reason is measurement, not
//! cost. `ATTR_FILE_ALLOCSIZE` already covers every fork of a file, and APFS
//! directories allocate no blocks of their own: measured `ATTR_DIR_ALLOCSIZE`
//! of 0 for an empty directory, a 400-entry directory and `/usr/share` alike,
//! with the bit set in `ATTR_CMN_RETURNED_ATTRS`, so the zero is a real value
//! rather than an unsupplied default. Directory sizes come entirely from the
//! bottom-up rollup, and requesting these bits would change the buffer layout
//! that `crate::parse`'s golden fixtures pin to gain a column of zeros.

/// Options passed to `getattrlistbulk`: report invalid attributes explicitly
/// (via `ATTR_CMN_RETURNED_ATTRS`) instead of failing, and do not follow
/// symlinks.
pub const SCAN_OPTIONS: u64 = (libc::FSOPT_PACK_INVAL_ATTRS | libc::FSOPT_NOFOLLOW) as u64;

/// Common attributes: returned-attrs set, name, device, object type, flags,
/// file id.
pub const COMMON_MASK: u32 = libc::ATTR_CMN_RETURNED_ATTRS
    | libc::ATTR_CMN_NAME
    | libc::ATTR_CMN_DEVID
    | libc::ATTR_CMN_OBJTYPE
    | libc::ATTR_CMN_FLAGS
    | libc::ATTR_CMN_FILEID;

/// File attributes: link count, allocated size, data length.
///
/// `ATTR_FILE_ALLOCSIZE` is the bytes on disk used by all of the file's forks,
/// so no resource-fork attribute is requested.
pub const FILE_MASK: u32 =
    libc::ATTR_FILE_LINKCOUNT | libc::ATTR_FILE_ALLOCSIZE | libc::ATTR_FILE_DATALENGTH;

/// The attribute request: the nine attributes in [`COMMON_MASK`] and
/// [`FILE_MASK`].
pub fn scan_attrlist() -> libc::attrlist {
    libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: COMMON_MASK,
        volattr: 0,
        dirattr: 0,
        fileattr: FILE_MASK,
        forkattr: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attrlist_requests_returned_attrs() {
        assert_ne!(
            scan_attrlist().commonattr & libc::ATTR_CMN_RETURNED_ATTRS,
            0
        );
    }

    /// Neither of these is a recursive total — there is no such attribute in
    /// `getattrlist(2)`. They are excluded because they add nothing:
    /// `ATTR_FILE_ALLOCSIZE` already spans every fork of a file, and an APFS
    /// directory's own `ATTR_DIR_ALLOCSIZE` is a measured, genuinely-returned
    /// zero. Requesting either would change the packed buffer layout for no
    /// information.
    #[test]
    fn attrlist_requests_no_directory_or_total_size_attributes() {
        let a = scan_attrlist();
        assert_eq!(a.dirattr & libc::ATTR_DIR_ALLOCSIZE, 0);
        assert_eq!(a.fileattr & libc::ATTR_FILE_TOTALSIZE, 0);
    }

    #[test]
    fn attrlist_requests_the_nine_spec_attributes() {
        let a = scan_attrlist();
        for bit in [
            libc::ATTR_CMN_RETURNED_ATTRS,
            libc::ATTR_CMN_NAME,
            libc::ATTR_CMN_OBJTYPE,
            libc::ATTR_CMN_FILEID,
            libc::ATTR_CMN_DEVID,
            libc::ATTR_CMN_FLAGS,
        ] {
            assert_eq!(a.commonattr & bit, bit, "common bit {bit:#x} missing");
        }
        for bit in [
            libc::ATTR_FILE_DATALENGTH,
            libc::ATTR_FILE_ALLOCSIZE,
            libc::ATTR_FILE_LINKCOUNT,
        ] {
            assert_eq!(a.fileattr & bit, bit, "file bit {bit:#x} missing");
        }
    }

    #[test]
    fn attrlist_requests_exactly_the_nine_attributes_and_no_others() {
        let a = scan_attrlist();
        assert_eq!(
            a.commonattr.count_ones() + a.fileattr.count_ones(),
            9,
            "the mask fixes the buffer layout; an extra bit changes it"
        );
        assert_eq!(a.volattr, 0);
        assert_eq!(a.dirattr, 0);
        assert_eq!(a.forkattr, 0);
    }

    #[test]
    fn attrlist_header_fields_are_well_formed() {
        let a = scan_attrlist();
        assert_eq!(a.bitmapcount, libc::ATTR_BIT_MAP_COUNT);
        assert_eq!(a.reserved, 0);
    }

    /// Pinned as literals, independent of the `libc` crate's constants: a
    /// wrong constant there would otherwise leave every other test passing
    /// while changing the buffer layout that Task 4's golden fixtures capture.
    /// Values hand-checked against `sys/attr.h` in the macOS SDK
    /// (`$(xcrun --show-sdk-path)/usr/include/sys/attr.h`).
    #[test]
    fn masks_are_pinned_to_the_sdk_header_values() {
        assert_eq!(COMMON_MASK, 0x8204_000B);
        assert_eq!(FILE_MASK, 0x0000_0205);
        assert_eq!(scan_attrlist().commonattr, 0x8204_000B);
        assert_eq!(scan_attrlist().fileattr, 0x0000_0205);
    }

    #[test]
    fn scan_options_set_pack_inval_and_nofollow() {
        assert_eq!(
            SCAN_OPTIONS,
            (libc::FSOPT_PACK_INVAL_ATTRS | libc::FSOPT_NOFOLLOW) as u64
        );
    }
}
