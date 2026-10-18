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
//! No recursive-size attribute (`ATTR_DIR_ALLOCSIZE`, `ATTR_FILE_TOTALSIZE`)
//! is ever requested: aggregating sizes is this program's job.

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

/// File attributes without the resource-fork allocation.
pub const FILE_MASK_REDUCED: u32 =
    libc::ATTR_FILE_LINKCOUNT | libc::ATTR_FILE_ALLOCSIZE | libc::ATTR_FILE_DATALENGTH;

/// File attributes: link count, allocated size, data length, and resource-fork
/// allocated size. Compressed files (`UF_COMPRESSED`) report almost nothing in
/// the data fork; their real bytes are in the resource fork.
pub const FILE_MASK: u32 = FILE_MASK_REDUCED | libc::ATTR_FILE_RSRCALLOCSIZE;

fn attrlist_with_file_mask(fileattr: u32) -> libc::attrlist {
    libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: COMMON_MASK,
        volattr: 0,
        dirattr: 0,
        fileattr,
        forkattr: 0,
    }
}

/// The full attribute request: all ten attributes.
pub fn scan_attrlist() -> libc::attrlist {
    attrlist_with_file_mask(FILE_MASK)
}

/// The full request minus `ATTR_FILE_RSRCALLOCSIZE`.
pub fn scan_attrlist_reduced() -> libc::attrlist {
    attrlist_with_file_mask(FILE_MASK_REDUCED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn attrlist_requests_returned_attrs_first() {
        assert_ne!(
            scan_attrlist().commonattr & libc::ATTR_CMN_RETURNED_ATTRS,
            0
        );
    }

    #[test]
    fn attrlist_requests_no_recursive_size_attributes() {
        for a in [scan_attrlist(), scan_attrlist_reduced()] {
            assert_eq!(a.dirattr & libc::ATTR_DIR_ALLOCSIZE, 0);
            assert_eq!(a.fileattr & libc::ATTR_FILE_TOTALSIZE, 0);
        }
    }

    #[test]
    fn attrlist_requests_the_ten_attributes() {
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
            libc::ATTR_FILE_RSRCALLOCSIZE,
        ] {
            assert_eq!(a.fileattr & bit, bit, "file bit {bit:#x} missing");
        }
    }

    #[test]
    fn attrlist_requests_exactly_the_ten_attributes_and_no_others() {
        let a = scan_attrlist();
        assert_eq!(
            a.commonattr.count_ones() + a.fileattr.count_ones(),
            10,
            "the mask fixes the buffer layout; an extra bit changes it"
        );
        assert_eq!(a.volattr, 0);
        assert_eq!(a.dirattr, 0);
        assert_eq!(a.forkattr, 0);
    }

    #[test]
    fn attrlist_header_fields_are_well_formed() {
        for a in [scan_attrlist(), scan_attrlist_reduced()] {
            assert_eq!(a.bitmapcount, libc::ATTR_BIT_MAP_COUNT);
            assert_eq!(a.reserved, 0);
        }
    }

    #[test]
    fn reduced_list_differs_from_full_by_exactly_the_rsrc_alloc_bit() {
        let full = scan_attrlist();
        let reduced = scan_attrlist_reduced();
        assert_eq!(reduced.commonattr, full.commonattr);
        assert_eq!(reduced.volattr, full.volattr);
        assert_eq!(reduced.dirattr, full.dirattr);
        assert_eq!(reduced.forkattr, full.forkattr);
        assert_eq!(
            full.fileattr ^ reduced.fileattr,
            libc::ATTR_FILE_RSRCALLOCSIZE
        );
        assert_eq!(
            full.fileattr & libc::ATTR_FILE_RSRCALLOCSIZE,
            libc::ATTR_FILE_RSRCALLOCSIZE
        );
        assert_eq!(reduced.fileattr & libc::ATTR_FILE_RSRCALLOCSIZE, 0);
    }

    #[test]
    fn masks_match_the_lists() {
        assert_eq!(scan_attrlist().commonattr, COMMON_MASK);
        assert_eq!(scan_attrlist().fileattr, FILE_MASK);
        assert_eq!(scan_attrlist_reduced().fileattr, FILE_MASK_REDUCED);
    }

    #[test]
    fn scan_options_set_pack_inval_and_nofollow() {
        assert_eq!(
            SCAN_OPTIONS,
            (libc::FSOPT_PACK_INVAL_ATTRS | libc::FSOPT_NOFOLLOW) as u64
        );
    }
}
