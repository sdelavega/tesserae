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

//! Fuzz target for `tesserae_core::parse::entries`.
//!
//! Input layout: byte 0 is the entry count the "syscall" returned, the rest is
//! the `getattrlistbulk` buffer. The committed seeds in
//! `corpus/parse_entries/` are the golden fixtures in exactly that layout.
//!
//! # What this can and cannot find
//!
//! It finds crashes, hangs and sanitizer reports: an out-of-bounds read, an
//! arithmetic overflow, a loop that does not terminate. The parser has no
//! `unsafe`, so the realistic catch is a future edit that adds an indexing
//! operator or a `checked_add` that became a bare `+`.
//!
//! It cannot find the defect class that matters most. A wrong-but-plausible
//! number, such as an attribute read although the kernel's returned-attributes
//! word says it was not supplied, is neither a crash nor wrong *relative to
//! the fuzzed buffer*, because the buffer is the only ground truth the fuzzer
//! has. Those are caught by the explicit gates in `parse.rs` and the golden
//! tests, not here.

#![no_main]

use libfuzzer_sys::fuzz_target;
use tesserae_core::parse;

fuzz_target!(|data: &[u8]| {
    if data.len() < 4 {
        return;
    }
    let count = u32::from(data[0]);
    let buf = &data[1..];
    let span = buf.as_ptr_range();

    let mut yielded = 0u32;
    for entry in parse::entries(buf, count) {
        yielded += 1;
        // The only liveness bound the parser gives: never more than `count`.
        assert!(yielded <= count, "iterator exceeded its count");
        if let Ok(e) = entry {
            // Borrowed, never copied: a name that points outside the input
            // buffer would be a read the bounds checks missed.
            let name = e.name.as_ptr_range();
            assert!(
                span.start <= name.start && name.end <= span.end,
                "name escaped the input buffer"
            );
            let _ = (e.name.len(), e.allocated);
        }
    }
});
