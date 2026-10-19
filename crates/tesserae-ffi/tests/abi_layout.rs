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

//! The C header and the Rust types describe one layout.
//!
//! Phase 2 reads these structs from Swift through `tesserae.h`, so a field that
//! moves is a memory-safety bug on the other side of the boundary, not a type
//! error. The numbers below are written out once, as literals, and checked two
//! ways: by Rust (`size_of`, `align_of`, `offset_of!`) against the types, and
//! by a C compiler (`_Static_assert` on `sizeof`, `_Alignof`, `offsetof`)
//! against the committed header. Each agreeing with the literals is what makes
//! them agree with each other.
//!
//! Stale-header drift is CI's job: it regenerates the header and fails on a
//! diff. This catches the other half: a regenerated header, or a hand edit,
//! that no longer matches the numbers an app was built against.

use std::fmt::Write as _;
use std::fs;
use std::mem::{align_of, offset_of, size_of, MaybeUninit};
use std::path::Path;
use std::process::Command;
use std::ptr::addr_of;

use tesserae_core::node::TessNode;
use tesserae_ffi::{TessProgress, TessScanOptions, TessScanStats, TessView};

/// One field: its offset and the C type the header must give it. The Rust type
/// is checked in `assert_rust_layout`, from the same table row. The types matter
/// beyond the offsets: a field widened or narrowed at the end of a struct moves
/// no offset and, with padding, not even the size.
struct Field {
    name: &'static str,
    offset: usize,
    c_type: &'static str,
}

struct Layout {
    c_type: &'static str,
    size: usize,
    align: usize,
    fields: &'static [Field],
}

/// The name of the type a pointer points to. Takes a pointer so that naming a
/// field's type never reads, or creates a reference to, uninitialised memory.
fn pointee_type_name<F>(_: *const F) -> &'static str {
    std::any::type_name::<F>()
}

macro_rules! abi {
    ($($ty:ident: $size:literal, $align:literal {
        $($field:ident = $off:literal, $rt:literal, $ct:literal),* $(,)?
    })*) => {
        /// The ABI, as literals.
        const TABLE: &[Layout] = &[$(Layout {
            c_type: stringify!($ty),
            size: $size,
            align: $align,
            fields: &[$(Field {
                name: stringify!($field),
                offset: $off,
                c_type: $ct,
            }),*],
        }),*];

        /// Panic unless Rust lays every type out as the table says.
        fn assert_rust_layout() {
            $(
                assert_eq!(size_of::<$ty>(), $size, "size_of {}", stringify!($ty));
                assert_eq!(align_of::<$ty>(), $align, "align_of {}", stringify!($ty));
                $(
                    assert_eq!(
                        offset_of!($ty, $field),
                        $off,
                        "offset of {}.{}",
                        stringify!($ty),
                        stringify!($field)
                    );
                    let probe = MaybeUninit::<$ty>::uninit();
                    // SAFETY: only the address of the field is taken, which
                    // neither reads it nor makes a reference to it.
                    let field = unsafe { addr_of!((*probe.as_ptr()).$field) };
                    assert_eq!(
                        pointee_type_name(field),
                        $rt,
                        "type of {}.{}",
                        stringify!($ty),
                        stringify!($field)
                    );
                )*
            )*
        }
    };
}

abi! {
    TessNode: 40, 8 {
        name_off = 0, "u32", "uint32_t",
        name_len = 4, "u16", "uint16_t",
        flags = 6, "u16", "uint16_t",
        parent = 8, "u32", "uint32_t",
        child_start = 12, "u32", "uint32_t",
        child_count = 16, "u32", "uint32_t",
        logical = 24, "u64", "uint64_t",
        allocated = 32, "u64", "uint64_t",
    }
    TessView: 40, 8 {
        nodes = 0, "*const tesserae_core::node::TessNode", "const TessNode *",
        count = 8, "u64", "uint64_t",
        names = 16, "*const u8", "const uint8_t *",
        names_len = 24, "u64", "uint64_t",
        root = 32, "u32", "uint32_t",
    }
    TessProgress: 32, 8 {
        dirs_done = 0, "u64", "uint64_t",
        files_done = 8, "u64", "uint64_t",
        bytes_seen = 16, "u64", "uint64_t",
        errors = 24, "u64", "uint64_t",
    }
    TessScanOptions: 32, 8 {
        max_depth = 0, "u16", "uint16_t",
        include_non_local = 2, "bool", "bool",
        workers = 4, "u32", "uint32_t",
        node_budget = 8, "u64", "uint64_t",
        buffer_bytes = 16, "u64", "uint64_t",
        stall_timeout_ms = 24, "u64", "uint64_t",
    }
    TessScanStats: 72, 8 {
        incomplete = 0, "u32", "uint32_t",
        files = 8, "u64", "uint64_t",
        dirs = 16, "u64", "uint64_t",
        errors = 24, "u64", "uint64_t",
        unreadable_count = 32, "u64", "uint64_t",
        skipped_mounts_count = 40, "u64", "uint64_t",
        lost_entries = 48, "u64", "uint64_t",
        hardlink_dups = 56, "u64", "uint64_t",
        depth_capped = 64, "u64", "uint64_t",
    }
}

/// Constants the app reads, with the values the Rust side promises.
const CONSTANTS: &[(&str, &str)] = &[
    ("TESS_ABI_VERSION", "1"),
    ("TESS_FLAG_DIR", "0x1"),
    ("TESS_FLAG_SYMLINK", "0x2"),
    ("TESS_FLAG_HARDLINK_DUP", "0x4"),
    ("TESS_FLAG_PERM_DENIED", "0x8"),
    ("TESS_FLAG_AGGREGATED", "0x10"),
    ("TESS_NODE_NONE", "0xFFFFFFFFu"),
    ("TESS_INCOMPLETE_NONE", "0"),
    ("TESS_INCOMPLETE_CANCELLED", "1"),
    ("TESS_INCOMPLETE_NODE_BUDGET", "2"),
    ("TESS_INCOMPLETE_OUT_OF_MEMORY", "3"),
    ("TESS_INCOMPLETE_STALLED", "4"),
    ("TESS_INCOMPLETE_FD_EXHAUSTED", "5"),
    ("TESS_INCOMPLETE_MALFORMED_BATCH", "6"),
    ("TESS_STATUS_RUNNING", "0"),
    ("TESS_STATUS_FINISHED", "1"),
];

/// The ten functions, as pointers typed with the signatures spec section 6
/// gives (plus `tess_scan_status`, `tess_snapshot_stats` and
/// `tess_snapshot_stalled_at`). Assigning a function to a pointer of a
/// different type is an error under `-Werror`.
const PROTOTYPES: &str = "\
uint32_t (*p_version)(void) = tess_abi_version;
TessScan *(*p_begin)(const char *, const TessScanOptions *) = tess_scan_begin;
void (*p_progress)(TessScan *, TessProgress *) = tess_scan_progress;
void (*p_cancel)(TessScan *) = tess_scan_cancel;
int32_t (*p_status)(const TessScan *) = tess_scan_status;
TessSnapshot *(*p_finish)(TessScan *) = tess_scan_finish;
void (*p_view)(const TessSnapshot *, TessView *) = tess_snapshot_view;
void (*p_stats)(const TessSnapshot *, TessScanStats *) = tess_snapshot_stats;
const uint8_t *(*p_stalled)(const TessSnapshot *, uint64_t *) = tess_snapshot_stalled_at;
void (*p_release)(TessSnapshot *) = tess_snapshot_release;
";

/// How many `_Static_assert`s `c_source` must contain, so that a table that
/// quietly became empty cannot compile "successfully".
fn expected_asserts() -> usize {
    let layouts: usize = TABLE.iter().map(|l| 2 + 2 * l.fields.len()).sum();
    layouts + CONSTANTS.len()
}

fn c_source() -> String {
    let mut c = String::from("#include \"tesserae.h\"\n\n");
    for l in TABLE {
        let t = l.c_type;
        writeln!(
            c,
            "_Static_assert(sizeof({t}) == {}, \"sizeof {t}\");",
            l.size
        )
        .unwrap();
        writeln!(
            c,
            "_Static_assert(_Alignof({t}) == {}, \"alignof {t}\");",
            l.align
        )
        .unwrap();
        for f in l.fields {
            let (name, off, ct) = (f.name, f.offset, f.c_type);
            writeln!(
                c,
                "_Static_assert(offsetof({t}, {name}) == {off}, \"offsetof {t}.{name}\");"
            )
            .unwrap();
            writeln!(
                c,
                "_Static_assert(_Generic((({t} *)0)->{name}, {ct}: 1, default: 0), \"type of {t}.{name}\");"
            )
            .unwrap();
        }
    }
    for (name, value) in CONSTANTS {
        writeln!(c, "_Static_assert({name} == {value}, \"{name}\");").unwrap();
    }
    c.push_str(PROTOTYPES);
    c
}

/// Compile `source` against the committed header with the system C compiler,
/// syntax only. `Err` carries the compiler's diagnostics.
fn compile(source: &str, scratch: &Path) -> Result<(), String> {
    let include = Path::new(env!("CARGO_MANIFEST_DIR")).join("include");
    let file = scratch.join("abi_check.c");
    fs::write(&file, source).unwrap();
    let out = Command::new("xcrun")
        .args([
            "clang",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-fsyntax-only",
        ])
        .arg("-I")
        .arg(&include)
        .arg(&file)
        .output()
        .expect("this test needs xcrun and a C compiler (Xcode command line tools)");
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).into_owned())
    }
}

#[test]
fn rust_types_have_the_layout_in_the_abi_table() {
    assert_rust_layout();
}

#[test]
fn the_header_has_the_layout_constants_and_signatures_in_the_abi_table() {
    let header = Path::new(env!("CARGO_MANIFEST_DIR")).join("include/tesserae.h");
    let text = fs::read_to_string(&header).expect("include/tesserae.h is committed");
    assert!(text.contains("#ifndef TESSERAE_H"), "no include guard");
    assert!(
        text.contains("GNU General Public License"),
        "no licence notice"
    );

    let source = c_source();
    assert_eq!(
        source.matches("_Static_assert(").count(),
        expected_asserts(),
        "the generated C lost checks"
    );
    assert_eq!(
        PROTOTYPES.lines().count(),
        10,
        "all ten functions are checked"
    );
    assert!(
        source.contains("offsetof(TessNode, allocated) == 32"),
        "the generated C does not check what it should"
    );

    let dir = tempfile::tempdir().unwrap();
    if let Err(diagnostics) = compile(&source, dir.path()) {
        panic!("tesserae.h disagrees with the ABI table:\n{diagnostics}");
    }

    // Control: the same compile does reject a false assertion, so a success
    // above is the compiler agreeing and not the compile checking nothing.
    let control = "#include \"tesserae.h\"\n_Static_assert(sizeof(TessNode) == 41, \"control\");\n";
    let rejected = compile(control, dir.path()).expect_err("a false assertion compiled");
    assert!(
        rejected.contains("control"),
        "rejected for the wrong reason:\n{rejected}"
    );
}
