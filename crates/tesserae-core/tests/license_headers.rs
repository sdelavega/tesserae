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

//! Every Rust source file in the workspace carries the full GPL-3.0 header.
//!
//! Nothing else in the repo checks this, and a truncated header (cut off
//! before the closing "along with this program" lines) passes every other gate.

use std::fs;
use std::path::{Path, PathBuf};

const HEADER: &str = "\
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
";

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            if path.file_name().is_some_and(|n| n != "target") {
                collect(&path, out);
            }
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn all_sources_carry_the_full_gpl_header() {
    // `crates/` holds every workspace member, so new crates are covered
    // automatically.
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    collect(crates, &mut files);
    assert!(
        files.len() >= 3,
        "found only {} .rs files under {}; is the walk broken?",
        files.len(),
        crates.display()
    );
    let bad: Vec<_> = files
        .iter()
        .filter(|f| !fs::read_to_string(f).unwrap().starts_with(HEADER))
        .map(|f| f.display().to_string())
        .collect();
    assert!(bad.is_empty(), "missing or truncated GPL header: {bad:#?}");
}
