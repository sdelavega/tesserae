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

### Rescan after the parser accepts only measured layouts

Commit `d39d0e3`, the same machine and day, 23:22 to 23:25, load average
about 2: the parser now refuses any fixed-region size other than the two a
census of this volume found (52 bytes for a directory, 72 for everything
else), so a layout it does not know would surface as `MalformedBatch`. The
same sequence as above: the CLI, then `du -sxk`, then the CLI again.

| | CLI run 1 | `du -sxk` | CLI run 2 |
|---|---|---|---|
| started | 23:22:23 | 23:22:44 | 23:24:46 |
| wall time | **20.8 s** (walk 20.0, freeze 0.6) | **121.9 s** | **20.7 s** (walk 20.1, freeze 0.6) |
| CPU | 1.9 s user, 95.1 s sys | 1.8 s user, 57.7 s sys | 2.1 s user, 101.4 s sys |
| exit status | 0 (complete) | 1 (252 unreadable paths) | 0 (complete) |
| allocated in KiB | 748,326,352 | **748,320,641** | 748,324,100 |
| dirs / files | 844,062 / 5,863,764 | | 844,062 / 5,863,768 |
| `MalformedBatch` / `lost_entries` / `errors` | none / 0 / 0 | | none / 0 / 0 |
| unreadable / `hardlink_dups` | 252 / 217,036 | | 252 / 217,036 |

**CLI minus `du`: +5,711 KiB (run 1) and +3,459 KiB (run 2), or 0.0008% and
0.0005%.** The two CLI runs differ by 2,252 KiB. This time `du` does not
fall between them: both runs are above it, by up to two and a half times the
run-to-run movement, on a scan that took `du` two minutes of a live volume.
That is still no counting difference beyond a few MiB, but it is not
bracketed by observed churn the way the first comparison was.

Against the first run above, the tree grew by 1,996,468 KiB (1.9 GiB),
3,938 directories and 88,576 files in an hour and a half. Part of that is
the fix session's own writes to the same volume, made in the half hour
before the rescan: about 0.7 GB in 2,818 build files under the repository's
target directories (counted by logical size, some of them replacing older
files) and 0.4 GB in 4,296 entries of a scratch directory. The rest was not
traced. This is not a regression signal: no entry was refused and nothing
was lost.

## Phase 2: the cost of `ATTR_CMN_MODTIME`

Phase 2 Task 2 added `ATTR_CMN_MODTIME` to the attribute request (16 more
bytes per entry: a file's entry grew from 80 to 96 bytes, a directory's from
56 to 72) and grew `TessNode` and `ScanNode` from 40 to 48 bytes. The
question is what that costs on the real volume.

Same machine as above (Apple M5, 10 cores, 24 GiB), macOS 27.2 (26B5112a),
Rust 1.99.1, release profile, 2026-10-19. Two release binaries of
`tesserae-cli`: **before** is commit `ffff993` (Phase 2 Task 1, the nine
attributes), **after** is the same tree with this change. Each run is
`tesserae-cli scan /System/Volumes/Data --workers 10 --json`, read-only, and
the elapsed figure is the CLI's own (walk plus freeze); user and sys are
`/usr/bin/time -p`. One unrecorded warm-up scan first, then the two binaries
alternate so neither always runs first. Every scan below completed (exit 0,
no `lost_entries`), about 843,300 directories and 5.95 million files.

**Series 3, the comparison of record:** the Phase 1 condition, a load
average below 3 before every run (the script waited for the one-minute load
to fall below 3 before starting each scan). 09:57 to 10:06 local time.
This condition and the 23.98 s pass mark were fixed after series 1 and 2
below and before series 3 was run, because those two had been run back to
back under a load Phase 1 did not have.

| | run 1 | run 2 | run 3 | median | user / sys (s) |
|---|---|---|---|---|---|
| before (`ffff993`) | 21.99 | 22.24 | 21.59 | **21.99** | 2.0 to 2.2 / 105 to 107 |
| after (this change) | 22.53 | 22.10 | 22.42 | **22.42** | 2.1 to 2.3 / 105 to 111 |

**+2.0% against the same-day baseline, +2.8% against Phase 1's 21.8 s**
(the 10-worker median above), inside the 10% budget the task set.

Two earlier series on the same day, recorded because they were run and to
show how much the machine's state moves these numbers:

| series | condition | before median | after median | after vs before |
|---|---|---|---|---|
| 1 | a Time Machine backup in its "finding changes" phase, load 8 to 10; 3 runs each, back to back | 26.23 (25.71, 26.23, 28.85) | 30.10 (30.10, 26.69, 30.21) | +14.8% |
| 2 | backup finished, scans back to back (load 6 to 8, much of it the previous scan's own); 5 runs each, alternating order | 24.35 (22.85, 25.25, 24.33, 24.35, 25.29) | 24.48 (23.68, 24.48, 24.78, 24.30, 26.30) | +0.5% |

Series 1 is dominated by the backup walking the same volume; its before and
after spread (25.7 to 30.2 s) is wider than the difference between them.
Series 2 puts the change at noise level. Read together, the attribute costs
a few percent at most. Where those percent go was not measured; the
likeliest candidate is the 20% larger entries (fewer per 256 KiB
`getattrlistbulk` buffer, so more calls). Not measured: the sparse-image benchmark, or the criterion
`parse` and `freeze` numbers, for this change.

### Criterion, before and after

`cargo bench -p tesserae-core`, same machine and day (10:22 to 10:26, load
average 3.5 to 6, an ordinary desktop session). **Before** is `ffff993`
(nine attributes, 40-byte nodes), run from a detached worktree; **after** is
this change with the fix round's freeze cutoff (ten attributes, 48-byte
nodes, two more freeze working arrays). Two complete runs each, alternating;
the middle of criterion's confidence interval.

| benchmark | before, run 1 | before, run 2 | after, run 1 | after, run 2 |
|---|---|---|---|---|
| `parse/golden_simple` (2 entries) | 8.39 ns | 8.45 ns | 8.68 ns | 8.81 ns |
| `parse/golden_mixed` (8 entries) | 50.4 ns | 51.8 ns | 53.4 ns | 53.1 ns |
| `parse/golden_mixed_xN` (256 KiB) | 19.03 us (x385, 3,080 entries) | 19.00 us | 16.86 us (x324, 2,592 entries) | 16.95 us |
| `freeze/synthetic_100k_nodes_4_arenas` | 3.512 ms | 3.530 ms | 4.011 ms | 4.005 ms |

The 256 KiB row repeats the mixed buffer to fill the walker's read buffer, so
the larger entries fit fewer times (324 against 385): per entry that is
6.17 ns before and 6.52 ns after (+6%), per byte the same or slightly
faster. The freeze is 14% slower per node (34 to 40 ns): the node is 8 bytes
wider, and the rollup now fills and walks two more arrays (the newest time
not after the scan's start, and whether there is one). Neither shows in the
volume scan above, which is kernel-bound: freeze took 0.71 to 0.85 s of
22 to 30 s there, against 0.64 to 0.73 s before.

The before figures are a little slower than Phase 1's own (7.6 ns, 47 ns,
17.7 us, 3.40 ms) on the same machine, as the volume scans were: the machine
is busier today.

## Phase 2: squarified layout

`squarify` (`apple/TesseraeKit/Layout/SquarifiedLayout.swift`) on a real
snapshot, timed by `LayoutTests.test_measure_squarify_on_the_snapshot_root`
and `test_measure_squarify_on_the_largest_directory`. Both skip unless
`TESSERAE_BENCH_ROOT` names a directory to scan, so CI never scans its
runner's disk. Run on 2026-10-19 (same machine as above, Xcode 27.2, load
average about 6) at commit `57f5967` plus this change:

```
TEST_RUNNER_TESSERAE_BENCH_ROOT=/System/Volumes/Data xcodebuild test \
  -project apple/Tesserae.xcodeproj -scheme TesseraeKit SWIFT_OPTIMIZATION_LEVEL=-O \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath apple/build/DerivedData-bench \
  -only-testing:TesseraeKitTests/LayoutTests/test_measure_squarify_on_the_snapshot_root \
  -only-testing:TesseraeKitTests/LayoutTests/test_measure_squarify_on_the_largest_directory
```

The build is the Debug configuration compiled with `-O`: the test bundle
uses Debug-only `Snapshot` hooks, so a Release test build does not compile.
That keeps the Debug-only liveness check (a lock taken on every `Snapshot`
node access), so these figures are an upper bound on the shipped cost.

The snapshot: `/System/Volumes/Data`, 5,322,925 nodes, scanned in 21.2 s by
the test itself. Bounds 1440 x 900 pt, default parameters (subdivide below
24 pt, cull below 16 pt², budget 50,000).

| layout root | children | tiles emitted | aggregates | deepest tile | 50 runs: min / median / max | `measure` (10 runs) average |
|---|---|---|---|---|---|---|
| the volume root | 20 | 7,463 | 822 | depth 18 | 0.282 / 0.286 / 0.346 ms | 1.0 ms (first run 2.1 ms, last 0.7 ms) |
| the directory with the most children (`target/debug/deps` of this repo) | 140,276 | 7,603 | 1 | depth 1 | 0.162 / 0.164 / 0.340 ms | 0.38 ms |

What the numbers say: the layout touches only what it emits. The root lays
out 7,463 tiles out of 5.3 million nodes; the 140,276-entry directory costs
less than the root because its tail (all but 7,601 entries) is found by a
binary search and summed from the rollup, never visited. Both are far below
a 16.7 ms frame, which the zoom animation does not need anyway (it lays out
once per zoom, not per frame; spec §8). The `measure` averages run higher
than the hand-timed loop because XCTest's first iterations include warm-up
(the root's ten values fall from 2.1 ms to 0.7 ms).

## Phase 2: hit testing

`HitTester.tile(at:in:)` (`apple/TesseraeKit/Interaction/HitTester.swift`),
timed by `HitTesterTests.test_hit_test_of_50k_tiles_measured`. Run on
2026-10-19 (same machine, Xcode 27.2, load average about 8) at commit
`26ff07e` plus this change.

The input is the instance budget: 50,000 tiles, a root and 49,999 leaves in
a grid. Each of 100 queries per `measure` block first drops the last-hit
cache (`invalidate()`) and lands in the top rows of the grid, so the
backward scan walks almost the whole list before it hits: the worst case.
A query that stays inside the cached leaf tile costs one rect test.

| build | `measure` (10 blocks of 100 queries) average | per query | last blocks, per query |
|---|---|---|---|
| Debug (`just app-test`, `-Onone`) | 60 ms | 0.60 ms | 0.57 ms |
| Debug compiled with `-O` (`SWIFT_OPTIMIZATION_LEVEL=-O`, as for the layout above) | 8 ms | 0.08 ms | 0.055 ms |

The `-O` run's first block is 15.6 ms and the last 5.5 ms (warm-up), hence
its 37% deviation. A standalone `swiftc -O` build of the same source on the
same input gave 0.048 ms per worst-case query (best of 10 blocks). So at
mouse-event frequency even a full scan of 50,000 rects is well under a
millisecond in an optimized build (spec §8 "Hit testing"); only the
unoptimized test build approaches one.


## Phase 2: real-window frame gate — FAILED, Debug build with -O (Snapshot debug locks on) (2026-10-19)

Task 13 is implemented at `f33dd4a`. This measurement adds `FrameTimer`,
return-to-parent animation and a bounded Diagnostics menu command that drives
the actual window's navigation. **The phase gate did not pass (Debug build with -O (Snapshot debug locks on)).** At 60 Hz,
the frame budget is 16.667 ms; the largest presentation gap was 50.000 ms
(p99 49.999 ms), and the largest interval between draw callbacks was
42.945 ms (p99 40.839 ms). No threshold was changed and no performance tuning
was attempted after this result. Final branch review and PR readiness remain
pending.

The local workload was a **partial** `/System/Volumes/Data` snapshot:
3,220,327 nodes, 279.59 GB allocated, incomplete code 4 (`STALLED`), 334
unreadable directories. This scan's watchdog named the user's Documents
folder; earlier app-shell scans named `/System/Volumes/Data/home`. The banner
reported this in the window. These are the nodes visible to this app without
any new Full Disk Access grant; this is not the earlier 6.7M-node snapshot.
Consequently even a cadence pass here would not establish the full original
workload gate.

Same M5 development machine and Xcode 27.2 as above. The maximized window's
treemap viewport was 1679 × 493.5 pt; the active display mode reported **60 Hz**
through `CGDisplayMode.refreshRate` (not a remembered display specification).
The workload was the five largest allocated, readable **immediate child
directories** of the Data root, each zoomed into and returned from three times.
All 30 transitions have actual draw, GPU-completion and presentation samples;
403 submitted frames each have a matching GPU and presentation record.
No offscreen rendering was substituted.

Build and reproduction:

```sh
xcodebuild build -project apple/Tesserae.xcodeproj -scheme Tesserae \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath apple/build/DerivedData-framegate \
  SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_HARDENED_RUNTIME=NO
```

Launch that local build, scan the Data volume, maximize the window, then
choose **Diagnostics → Run Phase 2 Frame Gate**. It wrote
`apple/build/phase14-frames.json`. (The runner now also works in Release; see
"Running the gate on a Release build" below. This capture's raw JSON is no
longer in the repository; the tables here are its summary.)
The Debug build is optimized but retains Snapshot's Debug liveness locks.
The local-only hardened-runtime override was required because dyld rejected
the ad-hoc framework under library validation; the project's hardened-runtime
settings were not changed. The unsigned universal Release build also succeeds,
but this is not a signed Release performance result.

The sampler adds signpost intervals and records the following separately:

| measurement | samples | maximum ms | p99 ms |
|---|---:|---:|---:|
| raw squarify layout | 30 | 7.180 | 7.180 |
| UI preparation (layout, selection and labels) | 30 | 73.680 | 73.680 |
| CPU draw submission, including buffer/drawable waits | 403 | 0.735 | 0.431 |
| GPU execution (`gpuEndTime - gpuStartTime`) | 403 | 12.854 | 11.042 |
| draw-callback interval within an animation | 373 | 42.945 | 40.839 |
| drawable presentation latency after encode | 403 | 73.889 | 58.210 |
| presentation interval within an animation | 373 | 50.000 | 49.999 |

Raw layout is below 100 ms on every navigation. CPU encoding and GPU execution
are individually within the frame budget, but these do not establish smooth
presentation: the actual display intervals include missed refreshes. The data
alone does not identify the source of those gaps. p99 uses nearest rank
`ceil(0.99 × count)`; transition boundaries are excluded from cadence so time
spent between separate zooms is not counted as a slow animation frame.

Per-directory figures combine the three repetitions. `out` returns to the Data
root, so its target tile count is the root layout's 6,451. Each row's p99 equals
its maximum where fewer than 100 samples were collected.

| directory | direction | frames | tiles | layout max ms | preparation max ms | CPU max / p99 ms | GPU max / p99 ms | presentation gap max / p99 ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Applications | in | 40 | 6692 | 2.509 | 72.239 | 0.439 / 0.439 | 9.992 / 9.992 | 33.333 / 33.333 |
| Applications | out | 40 | 6451 | 6.167 | 72.516 | 0.185 / 0.185 | 8.940 / 8.940 | 33.333 / 33.333 |
| Users | in | 40 | 5460 | 5.297 | 65.161 | 0.735 / 0.735 | 11.733 / 11.733 | 33.333 / 33.333 |
| Users | out | 40 | 6451 | 5.803 | 65.558 | 0.218 / 0.218 | 10.668 / 10.668 | 33.333 / 33.333 |
| System | in | 39 | 1063 | 0.414 | 23.984 | 0.356 / 0.356 | 10.555 / 10.555 | 49.999 / 49.999 |
| System | out | 42 | 6451 | 6.547 | 69.356 | 0.188 / 0.188 | 7.675 / 7.675 | 33.333 / 33.333 |
| Library | in | 40 | 4811 | 1.453 | 60.406 | 0.637 / 0.637 | 12.854 / 12.854 | 50.000 / 50.000 |
| Library | out | 40 | 6451 | 7.108 | 68.533 | 0.160 / 0.160 | 11.065 / 11.065 | 50.000 / 50.000 |
| opt | in | 40 | 4227 | 1.494 | 54.929 | 0.498 / 0.498 | 8.833 / 8.833 | 49.998 / 49.998 |
| opt | out | 42 | 6451 | 7.180 | 73.680 | 0.330 / 0.330 | 9.431 / 9.431 | 33.333 / 33.333 |


### Rerun after macOS prompt approvals — FAILED, Debug build with -O (Snapshot debug locks on) (2026-10-19)

After the user approved the macOS prompts, the same running measurement app
rescanned the Data volume. It now saw **6,139,547 nodes and 717.47 GB**, with
`incomplete = NONE` and **997 unreadable folders**. The scan finished without
stopping for the earlier stall; the unreadable count remains visible in the
banner. This supersedes the earlier 3.22M-node snapshot's workload limitation,
while still recording that some directories could not be read. No new permission
settings were changed by the agent and no additional access is inferred from
the prompt approvals alone.

The code, optimized Debug build, window viewport (1679 × 493.5 pt), 60 Hz
display, thresholds and three-repetition protocol were unchanged. The five
largest readable immediate Data-root directories were now Users, Applications,
System, Library and opt. **The gate still failed (Debug build with -O (Snapshot debug locks on)):** presentation intervals
reached 50.000 ms (p99 50.000 ms), above the unchanged 16.667 ms budget.
Raw relayout remained under 100 ms (maximum 5.991 ms).

| measurement | samples | maximum ms | p99 ms |
|---|---:|---:|---:|
| Raw squarify layout | 30 | 5.991 | 5.991 |
| UI preparation | 30 | 58.664 | 58.664 |
| CPU draw submission | 406 | 0.391 | 0.337 |
| GPU execution | 406 | 13.716 | 12.646 |
| Draw-callback interval | 376 | 45.320 | 42.738 |
| Presentation latency | 404 | 41.610 | 41.564 |
| Presentation interval | 374 | 50.000 | 50.000 |

All 30 transitions have multiple presentation samples and a complete matching
CPU/GPU record: 406 submitted frames and 406 GPU completions. The retained
capture has 404 presentation callbacks, two fewer than submissions; they are
not invented or counted as zero-duration presentations. This is an additional
capture limitation, not evidence of a pass. The already-recorded 50 ms gaps
are sufficient to fail the gate. Presentation cadence excludes boundaries
between separate transitions, as in the first run.

The raw capture is no longer in the repository; the tables here are its
summary. Per-directory figures combine all three repetitions:

| directory | direction | submitted frames | tiles | layout max ms | presentation gap max / p99 ms |
|---|---|---:|---:|---:|---:|
| Users | in | 40 | 3480 | 4.518 | 33.333 / 33.333 |
| Users | out | 40 | 4801 | 5.764 | 33.333 / 33.333 |
| Applications | in | 39 | 6693 | 0.950 | 33.333 / 33.333 |
| Applications | out | 39 | 4801 | 4.475 | 33.333 / 33.333 |
| System | in | 41 | 1063 | 0.223 | 50.000 / 50.000 |
| System | out | 40 | 4801 | 5.244 | 33.333 / 33.333 |
| Library | in | 41 | 4811 | 0.651 | 33.333 / 33.333 |
| Library | out | 43 | 4801 | 5.297 | 50.000 / 50.000 |
| opt | in | 41 | 4227 | 0.697 | 50.000 / 50.000 |
| opt | out | 42 | 4801 | 5.991 | 50.000 / 50.000 |

No code or thresholds were tuned after the failed rerun. PR #2 remains draft;
performance investigation and final whole-branch review remain outstanding.
All three CI jobs passed for implementation commit `0df73ef` before this
documentation-only update.


### Targeted UI and renderer improvements — gate still FAILED, Debug build with -O (Snapshot debug locks on) (2026-10-19)

Following the user's authorization to improve performance, a local Instruments
Game Performance capture was sampled before editing. In its limited sampled
window, app-main inclusive stacks accounted for 47 ms, with 43 ms under
`placeLabels`. Background samples included Snapshot's Debug liveness mutex.
This supports targeting label placement and overlapping table traversal; it is
not a complete attribution for every missed refresh. Instruments traces and
metadata remain local; only the timing captures below are committed.

The first change publishes the new tiles immediately, defers label measurement
and top-K table traversal until the renderer settles, and generation-guards
completion callbacks so an old zoom cannot release a newer navigation's work.
An empty folder settles without a renderer callback. The second change skips
renderer input rebuilding when the snapshot, mode, tiles, palette and appearance
are unchanged, and renders the static destination texture once per zoom. The
moving old layout still renders geometry every frame to preserve device-pixel
borders. Palette, background, tile, point-size, scale, texture-size and transition
changes invalidate the destination cache.

Xcode was updated by the user from `27B5038j` to **27B48** during verification;
its matching Metal component is now available (metal 32023.922). Both optimization
captures below use the **same updated toolchain**, optimized Debug command and
local-only `ENABLE_HARDENED_RUNTIME=NO` override documented above. No project
security settings changed. Comparisons with the earlier approved-access capture
are also affected by that toolchain update, live filesystem churn, and the small
viewport difference. No profiler or compilation ran during these two captures.

| capture | nodes | allocated | unreadable | viewport pt | submitted / GPU / presented frames |
|---|---:|---:|---:|---|---:|
| Deferred UI | 6,148,048 | 721.74 GB | 1,006 | 1659 × 483.5 | 443 / 443 / 443 |
| Deferred UI + renderer caches | 6,150,320 | 721.87 GB | 1,006 | 1679 × 493.5 | 441 / 441 / 441 |

Both scans finished with `incomplete = NONE`; unreadable folders remain flagged
in the window. Both captures use the same 60 Hz display and the unchanged
five-directory, three-repetition, in/out protocol: Users, Applications, System,
Library and opt. All 30 transitions have matching CPU/GPU/presentation samples,
one raw layout, one preparation interval and one deferred-label interval.

| measurement | deferred UI: max / p99 ms | with renderer caches: max / p99 ms |
|---|---:|---:|
| Preparation before animation | 3.501 / 3.501 | 4.750 / 4.750 |
| Raw layout | 3.464 / 3.464 | 4.650 / 4.650 |
| Labels after animation | 64.574 / 64.574 | 67.467 / 67.467 |
| CPU frame submission | 3.244 / 0.593 | 0.938 / 0.543 |
| GPU execution | 13.797 / 11.977 | 11.730 / 9.144 |
| Draw callback interval | 17.719 / 17.667 | 17.678 / 17.655 |
| Presentation latency | 58.209 / 58.029 | 41.319 / 41.166 |
| Presentation interval | 50.000 / 33.333 | 33.333 / 16.667 |

Preparation before motion is now at most **4.750 ms**, versus 58.664 ms in the
older approved-access capture. Labels still take up to 67.467 ms, but run after
motion rather than before its first frame. This does not claim that text shaping
itself became faster. Between the two captures under Xcode 27B48, GPU median
fell from **3.147 ms to 1.839 ms**, and GPU p99 fell from 11.977 to 9.144 ms.
There are exactly **30 renderer-input rebuilds** in the final capture, one per
navigation; hover/zoom-state/label/table changes do not rebuild them.

Presentation p99 improved from 33.333 ms to **16.667 ms** between the two
optimization captures. Intervals spanning multiple refreshes fell from 11/413
to **2/411**; the final capture's two 33.333 ms gaps occurred at `2 in Library`
and `3 in opt`. Counting intervals above 1.5 refresh periods is a diagnostic of
multi-refresh gaps, not a replacement pass criterion. The strict original gate
**still fails** (Debug build with -O (Snapshot debug locks on)): its unchanged budget is 16.667 ms, and the maximum presentation
gap remains 33.333 ms. Relayout remains well below 100 ms. Final branch review
and PR readiness remain pending. No frame-budget threshold was relaxed.

Raw capture: [deferred UI plus renderer caches](benchmarks/2026-10-19-phase2-renderer-caches.json)
(minified). `scripts/frame-gate-summary.py` recomputes the maxima, p99s,
medians and multi-refresh gaps above from it (standard-library Python:
`scripts/frame-gate-summary.py docs/benchmarks/2026-10-19-phase2-renderer-caches.json`,
add `--by-label` for each transition). The deferred-UI capture's JSON is no
longer in the repository; its column above is its summary.

Verification includes the navigation/empty-folder/stale-callback test, input
invalidation tests, byte-exact cached-versus-fresh Metal renders, and the existing
Metal/CoreGraphics and zoom cross-fade pixel oracles. Mutations making labels
eager, removing the generation check, disabling input reuse, disabling texture
reuse, and removing destination invalidation were each caught and restored.

Final local verification for these changes: `just gate` passed (114 Swift tests,
with only the two opt-in benchmarks skipped), and the unsigned universal Release
`just app-build` passed. Test-created disk images were detached.


### Label placement off the main actor (2026-10-19)

The renderer-caches capture above showed label placement as the largest
remaining main-actor cost: up to 67.467 ms right after each zoom settled, in
the window, while the app also rendered. Placement now runs off the main
actor: `LabelStyle.measure` uses Core Text (immutable `CTFont`/`CTLine`,
thread-safe) instead of the AppKit string-drawing additions. A test checks it
matches `NSString.size(withAttributes:)` exactly for Latin, CJK, Hebrew,
Arabic, Thai, Devanagari, Tibetan, Javanese, Hangul, emoji and combining
marks. The result is applied on the main actor only if no relayout happened
meanwhile (the layout-generation guard).

Measured with the opt-in `LayoutTests.test_measure_label_settle_cost_on_the_main_actor`.
It scans `/System/Volumes/Data` read-only (5.34M nodes this time), then runs
the gate's protocol at the gate's viewport (1679 × 493.5 pt): the five largest
readable root directories, in and out, three times, 30 settles. It times the
synchronous `setZoomRunning(false)` call that releases the deferred labels and
table. It is headless (no window or renderer), so it isolates label work from
drawing. **Before** is the same harness with `updateLabels` reverted to
5fedbb4's synchronous AppKit-measured placement.

```sh
TEST_RUNNER_TESSERAE_BENCH_ROOT=/System/Volumes/Data TEST_RUNNER_TESSERAE_FRAME_TIMING=1 \
xcodebuild test -project apple/Tesserae.xcodeproj -scheme TesseraeKit \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath apple/build/DerivedData-bench \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -only-testing:TesseraeKitTests/LayoutTests/test_measure_label_settle_cost_on_the_main_actor
```

| Debug build with -O (Snapshot debug locks on) | main actor per settle: median / max ms | `labels` interval: median / max ms | `labels-apply` (main actor): max ms |
|---|---:|---:|---:|
| before (5fedbb4, on the main actor) | 26.257 / 35.578 | 26.253 / 35.572 (on the main actor) | — |
| after (off the main actor) | 0.007 / 0.012 | 22.818 / 29.651 (off the main actor) | 0.008 |

The headless `labels` figures are lower than the in-window 67.467 ms because
nothing else competes for the main thread here. Labels now appear when
placement finishes, up to ~30 ms after a zoom settles, instead of blocking it.
The window's SwiftUI update for the new labels still runs on the main actor
and is not part of these figures.

### Running the gate on a Release build

The frame gate now runs in any build configuration when
`TESSERAE_FRAME_TIMING=1` (previously Debug always recorded and only Debug
had the gate's menu command). The runner exists only when timing is enabled,
and its capture no longer embeds a source path. To measure the configuration
that ships, unlock the screen (a locked screen never draws: every transition
then times out and the run is rejected) and run:

```sh
xcodebuild build -project apple/Tesserae.xcodeproj -scheme Tesserae -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath apple/build/DerivedData-gate \
  ENABLE_HARDENED_RUNTIME=NO
TESSERAE_FRAME_TIMING=1 TESSERAE_FRAME_GATE_AUTORUN=/System/Volumes/Data \
TESSERAE_FRAME_GATE_OUT="$PWD/apple/build/frame-gate-release.json" \
  apple/build/DerivedData-gate/Build/Products/Release/Tesserae.app/Contents/MacOS/Tesserae
scripts/frame-gate-summary.py apple/build/frame-gate-release.json
```

The app scans the root, sizes its window to the main screen's visible frame,
runs the five-directory × 3 protocol, writes the capture (default:
`tesserae-frame-gate.json` in `NSTemporaryDirectory()`) and quits. Progress
goes to standard error, and the exit status is 0 only for a valid capture. The
capture records `root`, `build` and `settleTimeouts`. A run in which any zoom
did not finish within 3 s is saved but reported as invalid (exit status 1).
`TESSERAE_FRAME_GATE_TIMEOUT` (seconds, default 900) bounds the whole run:
waiting for a visible window, the scan and the protocol. If it passes first,
the app writes nothing, says which stage it was waiting for, and exits with
status 3. A file already at the output path is not removed, so the exit status,
not the file's presence, says whether this run succeeded.
The `ENABLE_HARDENED_RUNTIME=NO` override is the same local-only signing
decision as above; the project's settings are unchanged.
