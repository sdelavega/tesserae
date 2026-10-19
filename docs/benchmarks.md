# Benchmarks

Phase 1 baseline. **Reported, not asserted**: nothing in CI fails on these
numbers, because a CI runner's timings are too variable to gate on. They are
here so a later change can be compared with a measurement taken the same way.

## Machine and method

| | |
|---|---|
| Machine | Apple M5, 10 cores, 24 GiB RAM, internal APFS volume 88% full |
| macOS | 27.2 (26B5112a) |
| Rust | 1.99.1 (rustc 58cf8f9c3, 2026-10-13), release profile (`lto`, `codegen-units = 1`) |
| Commit | `9a5da81` (the code measured; this file was added after) |
| Load | an ordinary desktop session, load average about 2.5 before each run |

Everything below is one machine on one day. The scans are I/O- and
kernel-bound (the CLI spends 1.9 s in user mode of its 21 s on the Data
volume), so they depend on the disk and on what else the machine is doing far
more than the criterion numbers do.

## Criterion: `parse` and `freeze`

`cargo bench -p tesserae-core` (`just bench`); source in
`crates/tesserae-core/benches/scan.rs`. Criterion 0.8.2 defaults: 3 s warm-up,
100 samples over about 5 s. The table is the middle of criterion's confidence
interval, from two complete runs a few minutes apart.

| benchmark | input | run 1 | run 2 |
|---|---|---|---|
| `parse/golden_simple` | 136 bytes, 2 entries (real kernel output) | 7.57 ns | 7.69 ns |
| `parse/golden_mixed` | 680 bytes, 8 entries (real kernel output) | 46.5 ns | 47.8 ns |
| `parse/golden_mixed_x385` | the above repeated to 256 KiB, 3,080 entries | 17.72 us (13.76 GiB/s) | 17.62 us (13.84 GiB/s) |
| `freeze/synthetic_100k_nodes_4_arenas` | 100,000 nodes in 4 arenas, 1,000 directories | 3.414 ms (29.3 Mnodes/s) | 3.401 ms (29.4 Mnodes/s) |

About 5.7 ns per entry to parse, and about 34 ns per node to freeze.

What the inputs are, and are not:

* The golden buffers are the committed fixtures and are tiny, so the first
  two rows time the per-call cost. `golden_mixed_x385` is the realistic one:
  entries are self-delimiting, so repeating a real buffer until it fills the
  walker's 256 KiB read buffer gives a valid buffer of the size the walker
  actually passes the parser per syscall.
* `freeze` consumes its arenas, so each iteration is given a freshly built set
  (`iter_batched`) and only the freeze is timed. The tree is synthetic: sizes
  from a fixed generator, fixed shape (root, 1,000 directories of 99 files).
  A real volume's shape (deep chains, a few huge directories) sorts and rolls
  up differently.
* Each input is checked before it is timed (entry count, node count), and the
  benchmarks were shown to react to a slowdown in the code they claim to time:
  with a busy-loop injected into `parse`, `golden_simple` rose from 7.6 ns to
  931 ns; with one injected into `freeze`, 3.4 ms rose to 48 ms.

## CLI on a 500,000-file volume

`scripts/bench-volume.sh` (`just bench-volume`) builds the volume with
`scripts/gen-bench-volume.sh`, detaches it and attaches it again, then scans
it with the release CLI. The volume is an 8 GB APFS sparse image holding
500,000 **empty** files in a fixed layout: 20 x 25 x 10 = 5,000 leaf
directories of 100 files, 5,521 directories with the root, four levels deep,
plus one `.metadata_never_index` marker file (Spotlight cannot be turned off
for a volume without root). Empty files need no data blocks on APFS, so
this times enumeration and node storage, not file size.

Both scans report 500,001 files and 5,521 directories, as built.

"Cold" is the best an unprivileged user can do. Re-attaching drops the
volume's own caches but not the host's cache of the image file, and `purge`
needs root. Run 1 of a series is therefore "first scan after a re-attach".

Default options (10 workers), seven scans after a re-attach, elapsed time as
the CLI prints it (walk plus freeze):

| run | 1 (first after re-attach) | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|
| seconds | 5.578 | 5.483 | 4.149 | 5.432 | 4.328 | 5.456 | 4.386 |

**Median 5.43 s** (about 92,000 nodes per second). This is the slow regime
of the volume: every scan here followed a re-attach, and the sweep below shows
the same image scanning in 2.2 to 2.7 s at the default 10 workers when it is
scanned right after being built, without the re-attach. The re-attach, not
the image, is the difference between the two numbers. An earlier series of
three after a re-attach gave 5.92, 4.40 and 5.29 s. The runs fall in two
groups, about 4.2 and about 5.4 s; I do not know why.

Worker count, one volume, three scans each, in seconds (`--workers N`):

| workers | 1 | 2 | 4 | 8 | 10 (default) | 16 |
|---|---|---|---|---|---|---|
| right after the image was built | 2.36 to 2.39 | 1.47 to 1.95 | 1.64 to 1.94 | 2.06 to 2.26 | 2.24 to 2.66 | 1.99 to 2.41 |
| after a re-attach | 3.11 to 3.14 | 2.37 to 2.48 | 3.27 to 3.45 | | 4.44 to 5.42 | |

The scan is not CPU-bound (user time 0.03 s, system 0.7 to 1.1 s of 2 to 5 s
elapsed) and extra workers made it slower, not faster, past two to four. This
is one sparse disk image through the image helper; it need not hold on the
internal SSD, and the sweep on the real volume below shows it does not.

The same sweep on the real volume, `/System/Volumes/Data` (read-only, warm: one
unrecorded scan first, then three rounds of 2, 4 and default workers in turn;
the default here is 10), commit `9a5da81` plus the volume-lost check, which
runs only after a failed directory. Elapsed seconds, 6.62 million nodes each,
every scan complete:

| workers | run 1 | run 2 | run 3 | median |
|---|---|---|---|---|
| 2 | 50.23 | 50.04 | 50.27 | **50.23** |
| 4 | 29.39 | 29.15 | 30.20 | **29.39** |
| default (10) | 21.40 | 21.75 | 22.61 | **21.75** |

Here the scan scales with workers, close to inversely from 2 to 4 and still
improving to 10, the opposite of the sparse image. So the sparse-image result
is a property of that image, not of the engine, and **it is no evidence
against the default** `clamp(cores, 4, 16)`: on the volume the app will
actually scan, 10 workers on 10 cores is the best of the three points
measured. Recommendation: keep the default. Not measured: 16 workers on this
machine, or any other core count.

For scale, the unit tests' UDIF images scanned 100,000 files in 0.33 to 0.36 s
in a debug build with 1 to 4 workers (about 290,000 nodes per second),
three times faster per node than the sparse image above. Image type matters.

## Phase exit: `/System/Volumes/Data`

The phase-exit criterion is that `tesserae-cli scan /System/Volumes/Data`
completes and its totals reconcile with `du -sxk` within clone-explained
variance. Run read-only from a terminal with Full Disk Access, one after the
other so they do not compete: the CLI, then `du -sxk`, then the CLI again, to
see how far the live volume moves on its own.

| | CLI run 1 | `du -sxk` | CLI run 2 |
|---|---|---|---|
| started | 21:49:06 | 21:49:27 | 21:51:27 |
| wall time | **21.1 s** (walk 20.5, freeze 0.6) | **120.4 s** | **20.6 s** (walk 19.9, freeze 0.6) |
| CPU | 1.9 s user, 94.6 s sys | 1.8 s user, 56.6 s sys | 1.9 s user, 96.0 s sys |
| exit status | 0 (complete) | 1 (252 unreadable paths) | 0 (complete) |
| allocated | 764,241,801,216 B | | 764,240,191,488 B |
| allocated in KiB | 746,329,884 | **746,329,817** | 746,328,312 |
| dirs / files | 840,124 / 5,775,188 | | 840,124 / 5,775,193 |
| logical | 3,911,834,662,784 B | | 3,911,831,689,418 B |

**Difference, CLI run 1 minus `du`: +67 KiB, or 0.00001%.** Run 2 minus `du`:
-1,505 KiB, or 0.0002%. The two CLI runs differ from each other by 1,572 KiB
and `du`, which ran between them, falls between them. The +67 KiB is well
inside that observed churn (1,572 KiB run to run, on a machine in use), so
these runs show no counting difference larger than the churn, though a
smaller one cannot be excluded. `du` is a different program reading `st_blocks` through
`lstat`; the CLI reads `ATTR_FILE_ALLOCSIZE` through `getattrlistbulk`.

What the two have in common, which is why they agree:

* **Unreadable directories.** The CLI reports 252 (`unreadable`). `du` printed
  252 errors: 195 "Permission denied" and 57 "Operation not permitted". Same
  count; both skip the contents. These are system-protected paths (`/.fseventsd`,
  `/.DocumentRevisions-V100`, `private/var/spool/postfix/*`, `AssetsV2/*`,
  among others) that the terminal's Full Disk Access does not open.
* **Hardlinks.** 204,349 links were counted as zero by the CLI
  (`hardlink_dups`), as `du` counts an inode once.
* **Clones.** Both count each clone's full allocated size, because `st_blocks`
  and `ATTR_FILE_ALLOCSIZE` are per file and say nothing of sharing. This is
  the spec's section 7 point, and `tests/volume.rs` observes it on an image
  (a file and four clones: tree 40 MiB, volume 8 MiB). It does not show up in
  CLI against `du`, only against what the volume reports.
* **Volume boundary.** Both stay on the Data volume. The CLI listed nine
  mount points it did not enter (`/Users/sdelavega/Library/Developer/CoreDevice/DeviceFS`,
  the Recovery volume and two other volumes under `/Volumes`, four
  simulator and toolchain cryptexes, and the non-local `/home` automount);
  `du -x` skips other devices too, and the totals agree.
* **Firmlinks.** `/System/Volumes/Data` is scanned directly, so the firmlinked
  `/Users`, `/Library` and `/private` are reached once, as paths under the
  root, and not twice through `/`.

Against the volume's own figures the tree does not reconcile, and this was not
explained to the byte:

| | |
|---|---|
| tree allocated (CLI, run 1) | 764.2 GB |
| `df -k` used, Data volume | 821.1 GB (840.8 GB "Capacity Consumed" in `diskutil apfs list`) |
| gap | 57 to 77 GB, depending on the figure |

Candidates, each real on this machine but not measured individually: nine
local Time Machine snapshots on the volume (blocks they alone hold are
consumed but in no live file), the 252 unreadable paths, APFS metadata, and
purgeable space. Clones go the other way: they make the tree larger than the
blocks used, so the gap is net of an unmeasured clone over-count. Logical
bytes (3.91 TB) are five times the allocated figure, probably mostly sparse
files (virtual-machine and similar images, which `ATTR_FILE_DATALENGTH`
reports at their full length); clones and compressed files also make logical
exceed allocated, and nothing here separates the three.

The CLI is five and a half times faster than `du` here (21 s against 120 s),
and walks 6.6 million nodes against a budget of 25 million.
