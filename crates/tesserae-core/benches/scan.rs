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

//! Benchmarks for the two pure stages of a scan: parsing a `getattrlistbulk`
//! buffer and freezing the arenas into a snapshot.
//!
//! Reported, not asserted: nothing here gates a build. A CI runner's timings
//! are too variable to fail on, so these exist to be run and recorded (see
//! `docs/benchmarks.md`) and compared by a person.
//!
//! What is measured is chosen to be honest about the input:
//!
//! * `parse` runs over the committed golden buffers, which are real kernel
//!   output. Those are 152 and 696 bytes, so they time the per-call cost and
//!   say little about throughput; `golden_mixed_xN` repeats the larger one
//!   until it fills a real 256 KiB read buffer, which is what the walker hands
//!   the parser per syscall. Entries are self-delimiting, so a repeated buffer
//!   is a valid one with a proportionally larger entry count.
//! * `freeze` runs over a synthetic 100,000-node tree split across four
//!   arenas, as a four-worker walk leaves it. Freezing consumes its arenas, so
//!   each iteration gets a freshly built set and only the freeze is timed.
//!
//! Every input is checked before it is timed: a benchmark over a buffer that
//! parsed to nothing, or an arena that was not the size claimed, would report
//! a fast, meaningless number.

use std::hint::black_box;

use criterion::{criterion_group, criterion_main, BatchSize, Criterion, Throughput};

use tesserae_core::arena::{Arena, ScanId, ScanNode};
use tesserae_core::freeze::freeze;
use tesserae_core::parse::{entries, ObjType};
use tesserae_core::walk::WalkStats;

const GOLDEN_SIMPLE: &[u8] = include_bytes!("../tests/fixtures/golden_simple.bin");
const GOLDEN_MIXED: &[u8] = include_bytes!("../tests/fixtures/golden_mixed.bin");

/// The walker's default read buffer, 256 KiB.
const READ_BUFFER: usize = 256 * 1024;

/// A golden file's buffer and the entry count the kernel returned with it. See
/// `tests/golden_capture.rs` for the format: a 16-byte header (`TSRGOLD1`,
/// entry count, buffer length, both little-endian `u32`) then the raw bytes.
fn golden(file: &[u8]) -> (&[u8], u32) {
    assert_eq!(&file[..8], b"TSRGOLD1", "not a golden file");
    let count = u32::from_le_bytes(file[8..12].try_into().unwrap());
    let len = u32::from_le_bytes(file[12..16].try_into().unwrap()) as usize;
    assert_eq!(file.len(), 16 + len, "golden length header is wrong");
    (&file[16..], count)
}

/// Parse every entry and fold what the walker would read from each one, so
/// that the work cannot be optimised away. Returns the entries seen.
fn parse_all(buf: &[u8], count: u32) -> (u32, u64) {
    let mut seen = 0;
    let mut bytes = 0u64;
    for entry in entries(buf, count) {
        let e = entry.expect("a golden buffer parses without error");
        bytes = bytes.wrapping_add(e.logical ^ e.allocated ^ e.name.len() as u64);
        seen += 1;
    }
    (seen, bytes)
}

fn parse(c: &mut Criterion) {
    let (mixed, mixed_count) = golden(GOLDEN_MIXED);
    let repeats = READ_BUFFER / mixed.len();
    let tiled: Vec<u8> = mixed.repeat(repeats);
    let tiled_count = mixed_count * repeats as u32;

    let tiled_name = format!("golden_mixed_x{repeats}");
    let (simple, simple_count) = golden(GOLDEN_SIMPLE);
    let inputs: [(&str, &[u8], u32); 3] = [
        ("golden_simple", simple, simple_count),
        ("golden_mixed", mixed, mixed_count),
        (&tiled_name, &tiled, tiled_count),
    ];

    let mut group = c.benchmark_group("parse");
    for (name, buf, count) in inputs {
        // The timed loop must walk every entry the buffer holds.
        assert!(count > 0 && parse_all(buf, count).0 == count, "{name}");
        group.throughput(Throughput::Bytes(buf.len() as u64));
        group.bench_function(name, |b| {
            b.iter(|| parse_all(black_box(buf), black_box(count)))
        });
    }
    group.finish();
}

/// Total nodes in the synthetic tree: the root, [`DIRS`] directories and the
/// rest regular files.
const NODES: usize = 100_000;
const DIRS: usize = 1_000;
const ARENAS: usize = 4;

/// The arenas a four-worker walk of a `NODES`-node tree would leave: the root
/// in arena 0, each directory in arena `i % 4` with its files beside it.
/// Sizes come from a fixed generator so every build is identical and the sort
/// has real work to do.
fn synthetic_arenas() -> Vec<Arena> {
    let mut arenas: Vec<Arena> = (0..ARENAS)
        .map(|t| Arena::new(t as u16, u64::MAX))
        .collect();
    let mut push = |arena: usize, parent: ScanId, name: &str, t: ObjType, size: u64| -> ScanId {
        let a = &mut arenas[arena];
        let name = a.push_name(name.as_bytes()).unwrap();
        a.push_node(ScanNode {
            name,
            parent,
            obj_type: t,
            flags: 0,
            logical: size,
            allocated: size.next_multiple_of(4096),
            modified: 0,
        })
        .unwrap()
    };

    let root = push(0, ScanId::NONE, "root", ObjType::Dir, 0);
    let per_dir = (NODES - 1 - DIRS) / DIRS;
    let mut state = 0x9E37_79B9_7F4A_7C15u64;
    let mut files = 0;
    for d in 0..DIRS {
        let arena = d % ARENAS;
        let dir = push(arena, root, &format!("dir{d:04}"), ObjType::Dir, 0);
        // The remainder lands in the first directories so the total is exact.
        let n = per_dir + usize::from(d < (NODES - 1 - DIRS) % DIRS);
        for f in 0..n {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            push(
                arena,
                dir,
                &format!("file{f:05}.dat"),
                ObjType::Reg,
                state >> 44,
            );
            files += 1;
        }
    }
    assert_eq!(1 + DIRS + files, NODES);
    arenas
}

fn freeze_bench(c: &mut Criterion) {
    // Checked once, untimed: the tree is the size it claims and freezes whole.
    let snapshot = freeze(synthetic_arenas(), WalkStats::default());
    assert_eq!(snapshot.nodes.len(), NODES);
    assert!(snapshot.nodes[snapshot.root as usize].allocated > 0);
    drop(snapshot);

    let mut group = c.benchmark_group("freeze");
    group.throughput(Throughput::Elements(NODES as u64));
    group.bench_function("synthetic_100k_nodes_4_arenas", |b| {
        b.iter_batched(
            synthetic_arenas,
            |arenas| freeze(black_box(arenas), WalkStats::default()),
            BatchSize::LargeInput,
        )
    });
    group.finish();
}

criterion_group!(benches, parse, freeze_bench);
criterion_main!(benches);
