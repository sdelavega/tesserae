# Tesserae Phase 2: Treemap, File Table, Navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Mac app that scans a folder or the Data volume with the Phase 1 engine and shows the result as a fluid, zoomable squarified treemap beside a sortable file table, with selection shared between them.

**Architecture:** Rust stays the engine behind the C ABI; it gains a per-node modification time. A Swift framework, `TesseraeKit`, owns everything testable — the snapshot wrapper, scan coordinator, layout, colour, Metal and CoreGraphics renderers, hit testing, labels, the table model — and a thin SwiftUI app target, `Tesserae`, hosts it. The Rust static library is built out of band by a script and linked as a prebuilt universal `.a` (spec §14).

**Tech Stack:** Rust 1.99.1 (existing workspace); Swift 6.4 / Xcode 27.2; SwiftUI + AppKit (`NSTableView`, `MTKView` via `NSViewRepresentable`); Metal; CoreGraphics; XCTest. No third-party Swift dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md` — §5 (architecture), §6 (node and FFI contract), §8 (layout, rendering, interaction), §11 Rendering, §12 Swift and Lifetime/visual/accessibility tests, §14 (Rust inside Xcode, entitlements, CI, repo layout). Deferred Phase 1 work: `docs/phase-2-backlog.md`.

**Status (2026-10-19): Phase 2 complete.** All fourteen tasks are implemented and reviewed, and the frame gate (Task 14) passed on a Release build (`docs/benchmarks.md`). This plan has since been amended in place to describe what was built: where a ruling changed a task, an **As built** note says what and why, citing the ruling (`P1`–`P3` below, `T1-1`, `T4-1`, `T6-1`…, `G-1`) from the execution ledger kept beside the plan's working files (local, not committed). The original task text stands where it still holds.

## Global Constraints

- Deployment target **macOS 13.0**, universal binary (arm64 + x86_64); the app, the framework and the Rust library all target 13.0. The `TesseraeKitTests` bundle alone targets **macOS 14.0**, where XCTest itself starts (at 13.0 it linked with a warning); it never ships. Only APIs available on macOS 13: use `ObservableObject`/`@Published`, not `@Observable`; no `.inspector` modifier; `NavigationSplitView` is fine.
- **No App Sandbox**; hardened runtime on. Info.plist carries the five usage-description keys of spec §14 (`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`).
- The Rust library the app links is built with exactly `cargo build -p tesserae-ffi --release` per target (never `--all-targets` or `cargo test --release`), with `MACOSX_DEPLOYMENT_TARGET=13.0`, then `lipo`'d (spec §14). Xcode never runs cargo; a Run Script phase only *verifies* the `.a` is newer than the Rust sources.
- Every new `.swift`, `.metal`, `.h` and `.modulemap` file carries the project's GPL-3 notice in that language's comment form, with the copyright line `Copyright (C) 2026 Stephen de la Vega` (no "All rights reserved"); extend `crates/tesserae-core/tests/license_headers.rs` to walk `apple/` and check these extensions.
- `TesseraeKit` is a framework target; all logic lives there and is tested with XCTest. The app target holds only SwiftUI chrome.
- Snapshot memory is borrowed: an `UnsafeBufferPointer` into Rust memory never outlives the `Snapshot` instance that owns it (spec §6 "code rule").
- Colours are exactly the spec §8 values (and this plan's Age ramp below); text uses ink tokens `#0b0b0b` (light) / `#f0efec` (dark), never a tile's colour. Status colour `#fab219` is reserved for permission-denied tiles and always paired with a lock badge and a label.
- Layout constants from spec §8: subdivide threshold **24 px** minimum dimension, cull threshold **16 px²**, instance budget **50,000** tiles, zoom animation **~250 ms ease-out**. Permission-denied directories (0 bytes) get fixed 4 pt placeholder squares, not an area (Task 6, rulings T6-2/T6-3).
- Performance numbers are reported in `docs/benchmarks.md`, never asserted in CI (spec §12).
- Same discipline as Phase 1: TDD, assert preconditions so no test passes vacuously, mutation-verify new tests, and never rely on recalled macOS constants — read the SDK header or probe.

## Review Focus

1. **Empty or zero-size subtrees** (an empty folder as the scan root; a directory whose allocated size is 0 because every file is dataless or a hardlink duplicate). Expected: no NaN rects, no divide-by-zero, an empty-state message instead of a blank canvas. Tests: Task 6 `zero_size_root_yields_no_tiles_and_no_nan`, Task 13 `empty_scan_shows_empty_state`.
2. **A single directory with hundreds of thousands of children** (a mail store, a node_modules cache). Expected: tail aggregation and the 50k budget keep layout bounded; the aggregate tile reports the right count and size. Test: Task 6 `huge_flat_directory_is_bounded_and_aggregate_is_exact`.
3. **Names that are not UTF-8, very long, or contain newlines/control characters** in labels, the table, the breadcrumb and the inspector. Expected: shown lossily and on one line, never a crash or an empty cell. Tests: Task 4 `names_decode_lossily_and_never_empty`, Task 11 `labels_truncate_long_and_control_character_names`.
4. **A window resized to (near) zero, or resized mid-animation.** Expected: layout skipped below 1×1 point, animation completes or cancels cleanly, no NaN reaches the GPU. Tests: Task 9 `tiny_and_zero_sizes_emit_no_nan` (layout and both renderers at 0×0, 0.5×0.5 and 1×1, no animation) and Task 10 `resize_to_zero_mid_animation_emits_no_nan` (Ruling P3).
5. **Rescanning while the previous snapshot is on screen** (table rows, hover, a running zoom animation all hold indices into it). Expected: the UI swaps to the new snapshot atomically; nothing indexes the old one after release. Tests: Task 4 `buffers_survive_while_snapshot_is_retained`, Task 13 `rescan_swaps_snapshot_atomically`.

---

## Pre-flight rulings

A cross-task scan before Task 1 found three places where the plan's tasks did not fit together. They were settled before execution, and the tasks below are written as ruled:

- **P1 — Task 2 also touches `crates/tesserae-core/src/walk/`.** The walker copies each `RawEntry` field into the arena node, so `modified` cannot reach the node otherwise; the Task 2 file list under-listed it. (`walk/walker.rs`, `walk/mod.rs`, `pool.rs` and `boundary.rs` all changed in Task 2.)
- **P2 — Task 8 handles a missing Metal device with a plain placeholder; Task 9 replaces it with the CoreGraphics fallback** (spec §11). Task 8 referenced a renderer Task 9 creates later; the placeholder keeps each task buildable in order.
- **P3 — the tiny-size test is split between Tasks 9 and 10.** Task 9's Review-Focus-4 test (`tiny_and_zero_sizes_emit_no_nan`) covers layout and both renderers at 0×0, 0.5×0.5 and 1×1 without animation; Task 10 adds `resize_to_zero_mid_animation_emits_no_nan` once `ZoomAnimation` exists.

---

## File Structure

```
crates/tesserae-core/src/walk/            Task 1: walk.rs split as a pure move (+ T1-1)
  mod.rs  lane.rs  coordination.rs  open.rs  errors.rs  walker.rs  tests.rs
crates/tesserae-core/src/{attrs,parse,arena,freeze,node,boundary,pool}.rs, walk/   Task 2: modification time, FAT sizing
crates/tesserae-ffi/src/lib.rs, include/tesserae.h            Task 2: TessNode.modified
scripts/build-ffi.sh                       Task 3: both targets + lipo -> apple/build/libtesserae.a, plus libtesserae.inputs (the content stamp)
scripts/verify-ffi-fresh.sh                Task 3: Xcode Run Script (verify only: mtimes and the stamp)
apple/
  Tesserae.xcodeproj                       Task 3 (generated once by XcodeGen, then committed)
  Tesserae/                                app target: TesseraeApp.swift, ContentView.swift, Info.plist, Tesserae.entitlements
  TesseraeKit/
    FFI/module.modulemap                   C module `TesseraeFFI` over crates/tesserae-ffi/include/tesserae.h
    Snapshot.swift                         Task 4
    ScanCoordinator.swift                  Task 5
    Layout/TreeSource.swift, SquarifiedLayout.swift, Tile.swift      Task 6
    Colour/Palette.swift, ColourMode.swift, FileKind.swift            Task 7
    Render/TreemapRenderer.swift, Shaders.metal, TreemapView.swift    Task 8
    Render/CGTreemapRenderer.swift                                     Task 9
    Navigation/Navigator.swift, ZoomAnimation.swift                    Task 10
    Interaction/HitTester.swift, Inspector.swift, TreemapInteraction.swift   Task 10
    Labels/LabelPlacer.swift, LabelsOverlay.swift                      Task 11
    Table/FileTableModel.swift, FileTableView.swift, TopK.swift, Selection.swift   Task 12
    AppModel.swift, ScanBanner.swift                                   Task 13
    Diagnostics/FrameTimer.swift                                       Task 14
  TesseraeKitTests/                        one test file per source area; Support/ (SyntheticTree, SplitMix64, TestSnapshot); SnapshotTests/ reference PNGs
scripts/frame-gate-summary.py              Task 14: recomputes max/p99 from a capture
docs/benchmarks.md, docs/benchmarks/       Tasks 2, 6, 10 and 14 append; two minified captures
```

---

### Task 1: Split `walk.rs` as a pure move

The final Phase 1 review asked for this before Phase 2 builds on the engine (backlog "Do first"). Behaviour must not change.

**Files:**
- Create: `crates/tesserae-core/src/walk/{mod.rs,lane.rs,coordination.rs,open.rs,errors.rs,walker.rs,tests.rs}` (the last two are Ruling T1-1, below)
- Delete: `crates/tesserae-core/src/walk.rs`
- Modify: `crates/tesserae-core/src/pool.rs` (imports only), `crates/tesserae-core/src/lib.rs`

**Interfaces:**
- Produces: the unchanged public API `tesserae_core::walk::{walk_serial, WalkOptions, WalkStats, Incomplete, os_errno, with_context}`. Module split: `lane` (Lane, Slot, Held, Dir), `coordination` (Halt, NodeBudget, Share), `open` (open_root, openat_retrying, DirOpener and its impls), `errors` (note_error's classification, `may_mean_volume_gone`, `Incomplete::rank`), `walker` (the Walker type), `tests` (the module's unit tests), `mod` (the public entry points, module docs, re-exports).

**As built (Ruling T1-1).** After the five-way split `mod.rs` was still 1,818 lines, over the step 3 bound of 900; that bound exists so later tasks do not land on a giant file, so two more pure moves were allowed (tests into `walk/tests.rs`, the `Walker` into `walk/walker.rs`). Every file is now under 900 lines (largest: `walker.rs`, 758). The two folds became `boundary::retry_eintr` (used by `open_root`, `openat_retrying` and `boundary::fstatfs`) and `walk::assemble_path` (used by `node_path` and `pool::stalled_path`). The workspace test list is identical before and after (224 tests) once module paths are normalised: seven tests now live under `walk::errors::tests` and two under `walk::open::tests`.

- [ ] **Step 1: Record the baseline**

Run: `cargo test --workspace --locked 2>&1 | grep -E '^test ' | sort > /tmp/before.txt; wc -l /tmp/before.txt`
Expected: the list of every test name and its result.

- [ ] **Step 2: Move code into the five files**

Move items verbatim; change only `use` lines and visibility (`pub(crate)`/`pub(super)`) needed to compile. Fold the duplicated helpers named in the backlog: one EINTR-retry helper used by `open_root`, `openat_retrying` and `boundary::fstatfs`; one path-assembly function used by `node_path` and `pool::stalled_path`. No other edits.

- [ ] **Step 3: Verify nothing changed**

Run: `cargo test --workspace --locked 2>&1 | grep -E '^test ' | sort > /tmp/after.txt; diff /tmp/before.txt /tmp/after.txt && just gate`
Expected: no diff (same tests, same results); gate passes. `wc -l` of each new file under 900.

- [ ] **Step 4: Commit**

```bash
git add -A crates/tesserae-core/src
git commit -m "refactor: split walk.rs into lane, coordination, open and errors modules"
```

---

### Task 2: Modification time in the engine

The user approved growing `TessNode` from 40 to 48 bytes so Age mode and the inspector have a date. ABI 1 has not shipped, so `TESS_ABI_VERSION` stays 1.

**Files:**
- Modify: `crates/tesserae-core/src/attrs.rs`, `parse.rs`, `arena.rs`, `freeze.rs`, `node.rs`, and (Ruling P1) `walk/` (the walker copies `modified` from `RawEntry` into the arena), `pool.rs`, `boundary.rs` (FAT sizing, below); `crates/tesserae-core/tests/volume.rs`, `crates/tesserae-testutil/src/diskimage.rs`; `crates/tesserae-ffi/src/lib.rs`, `tests/abi_layout.rs`, `include/tesserae.h` (regenerated); `crates/tesserae-core/tests/fixtures/golden_*` (recaptured); `crates/tesserae-cli/src/main.rs` (inspector-style output of the root's `modified`); spec §6 and §7; `docs/benchmarks.md`

**Interfaces:**
- Produces: `TessNode.modified: i64` — seconds since the Unix epoch (UTC), appended after `allocated`, making the node **48 bytes**. For a file or symlink: its `ATTR_CMN_MODTIME` seconds. For a directory: the maximum of its own modification time and every descendant's (rolled up at freeze, like sizes), so a directory tile's age is its most recently touched content. `RawEntry` gains `modified: i64`.
  **As built (Ruling R2-2):** the rollup ignores contributions later than the scan's start. A census found 170 files dated 2076 on the Data volume, which without a cutoff made the volume root, and every directory above them, read 2076 and Age mode show the whole disk as recent. The cutoff is `WalkStats::started_at` (the walk's own reading of the clock when it began); a file's or symlink's own value stays as read, and the scan root takes its own time from `fstat` on its open descriptor. Two tests that encoded the future-date rollup (one a time bomb in 2033) were rewritten to take their dates from the clock.

- [ ] **Step 1: Read the attribute from the SDK, then write the failing tests**

Read `ATTR_CMN_MODTIME`'s value and its packing position from `$(xcrun --show-sdk-path)/usr/include/sys/attr.h`; do not recall it. Tests:

```rust
#[test] fn attrlist_requests_exactly_the_ten_attributes_and_no_others() // nine + ATTR_CMN_MODTIME
#[test] fn modtime_is_parsed_for_files_dirs_and_symlinks()               // synthetic buffers
#[test] fn directory_modified_is_the_max_over_its_subtree()               // freeze rollup
#[test] fn tess_node_is_48_bytes_with_modified_last()                     // size_of, offset_of(modified) == 40
```
and in `abi_layout.rs` the table row `TessNode` → size 48, `modified` at offset 40, type `int64_t`.

- [ ] **Step 2: Run them**

Run: `cargo test --workspace --locked`
Expected: the four new tests and the layout test FAIL.

- [ ] **Step 3: Re-measure the two fixed-region layouts**

Adding a common attribute shifts every later common field and grows both fixed regions. Run the same census as the final Phase 1 fix (temporarily behind the `test-hooks` feature, not committed otherwise): count fixed-region sizes and object types over a full read-only scan of `/System/Volumes/Data`. Record the table in the commit message. Expected: exactly two sizes again, one for directories and one for everything else. **As built:** 68 bytes for directories and 88 for everything else, over 6.78 million entries of the Data volume. The fixed-region layouts were first measured on APFS only, so a fix round (Ruling R2-1) measured **HFS+, exFAT and FAT32** too, each on a disposable disk image: all three give the same 68 / 88, and `tests/volume.rs` scans an image of each filesystem.

- [ ] **Step 4: Implement**

Request the attribute; parse it at its measured offset (byte copies, no `repr(C)` cast, as for FILEID); accept only the two newly measured region sizes; add the field through arena, freeze (max rollup) and node; recapture the golden buffers with `tests/golden_capture.rs` and update `.expect` files; regenerate the header with `scripts/gen-header.sh`; show the root's modified time in the CLI.

- [ ] **Step 5: Verify, then measure the cost**

Run: `just gate`, `scripts/parser-sanitizers.sh asan`, `scripts/parser-sanitizers.sh miri`, `scripts/fuzz-parser.sh 120`.
Expected: all pass. Then `tesserae-cli scan /System/Volumes/Data --workers 10` three times warm, median, vs the 21.8 s Phase 1 median: record both in `docs/benchmarks.md`. If the median slows by more than 10 %, stop and report rather than commit. **As built:** +2.0 % against a same-day baseline (22.42 s against 21.99 s; +2.8 % against 21.8 s), inside the budget; the criterion benchmarks and the freeze cost are in `docs/benchmarks.md`.

- [ ] **Step 5b (added, Ruling R2-3): FAT volumes.** Measuring FAT32 for R2-1 found a Phase 1 defect: `getattrlistbulk` returns `ATTR_FILE_ALLOCSIZE` as 0 on msdos volumes, so a FAT32 USB stick scanned as nearly empty (spec §1 criterion 3). FAT has no sparse files or compression, so allocation is the data length rounded up to the cluster. Decided per volume from the `fstatfs` the walker already makes (`f_fstypename` `msdos`; the cluster is `f_bsize`, checked against `diskutil info` on five images and against `lstat`'s `st_blocks * 512`); a symlink on msdos (an "XSym" file) records 1,536 bytes rounded up to the cluster. exFAT already reports a real figure. `tests/volume.rs` holds a FAT32 and a FAT16 image's scanned total to `lstat`'s sum exactly (spec §7, Size semantics).

- [ ] **Step 6: Amend spec §6 (node struct, 48 bytes, memory figures 48–144 MB per 1–3M files) and §7 (ten attributes, the new layout sizes), then commit**

```bash
git commit -am "feat: per-node modification time (TessNode grows to 48 bytes)"
```

---

### Task 3: Xcode project and the first real link

Backlog "Do first": no Xcode/Swift link of the static library has been done; the archive embeds LLVM 23 bitcode that Apple's `nm` cannot read.

**Files:**
- Create: `scripts/build-ffi.sh`, `scripts/verify-ffi-fresh.sh`, `apple/Tesserae.xcodeproj`, `apple/Tesserae/{TesseraeApp.swift,ContentView.swift,Info.plist,Tesserae.entitlements}`, `apple/TesseraeKit/{TesseraeKit.h,FFI/module.modulemap,Version.swift}`, `apple/TesseraeKitTests/LinkTests.swift`
- Modify: `justfile` (recipes `ffi`, `app-test`, `app-build`; `gate` gains `app-test`), `.gitignore` (`apple/build/`, `xcuserdata/`), `.github/workflows/ci.yml` (a job running `just ffi && just app-test && just app-build`, the last an unsigned universal Release build, per spec §14), `crates/tesserae-core/tests/license_headers.rs`, `scripts/lib.sh` (the `ffi_inputs` stamp function)

**As built.**
- **Freshness is content-stamped, not just mtimes.** `build-ffi.sh` writes `apple/build/libtesserae.inputs`, a sorted listing with SHA-256 hashes of every `crates/**/*.rs` and `Cargo.toml`, plus `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml` and `tesserae.h`; `verify-ffi-fresh.sh` fails if any input is newer than the library **or** the listing differs from today's. The mtime check alone misses a deleted or renamed source and a toolchain change (review finding P3-1). The Run Script phase declares its inputs and stamp output so it works under `ENABLE_USER_SCRIPT_SANDBOXING`.
- **CI** (`apple` job): `macos-26` with **Xcode 26.6** selected explicitly through `DEVELOPER_DIR`, behind a step that fails readably (listing the installed Xcodes) if the image drops it; a cargo cache; a **Metal toolchain** step (since Xcode 26 the Metal compiler is a separate component: if a trivial shader will not compile, `xcodebuild -downloadComponent MetalToolchain`); the `.xcresult` uploaded on failure. The `rust` and `fuzz` jobs moved to `macos-26` too (the nightly workflow is still `macos-14`). The project is written for Xcode 26.6 (objectVersion 77, `SWIFT_VERSION` 6.0); local development uses Xcode 27.2.
- **Deployment targets:** 13.0 everywhere except the `TesseraeKitTests` bundle, which is 14.0 (see Global Constraints).
- **The link worked first time:** Xcode 27.2's and 26.6's `ld` both accept the archive's LLVM 23 bitcode (only Apple's `nm` cannot read it), so none of the step 4 fallbacks was needed.

**Interfaces:**
- Produces: `scripts/build-ffi.sh` → `apple/build/libtesserae.a` (universal; `lipo -info` lists `x86_64 arm64`). Swift module `TesseraeFFI` exposing the C header. `TesseraeKit.abiVersion: UInt32` (calls `tess_abi_version()`). Schemes: `Tesserae` (app), `TesseraeKit` (framework + `TesseraeKitTests`).

- [ ] **Step 1: Write the failing test**

```swift
final class LinkTests: XCTestCase {
    func test_links_the_rust_library_and_reads_abi_version() {
        XCTAssertEqual(TesseraeKit.abiVersion, 1)
    }
    func test_node_layout_matches_the_header() {
        XCTAssertEqual(MemoryLayout<TessNode>.size, 48)
        XCTAssertEqual(MemoryLayout<TessNode>.offset(of: \TessNode.modified), 40)
    }
}
```

- [ ] **Step 2: Generate the project once, then keep the generated project**

Write a temporary `project.yml` (targets: `Tesserae` app, `TesseraeKit` framework, `TesseraeKitTests`; deployment 13.0; `ARCHS = arm64 x86_64` for Release; `LIBRARY_SEARCH_PATHS = $(SRCROOT)/build`; `OTHER_LDFLAGS = -ltesserae`; `SWIFT_INCLUDE_PATHS` to the modulemap; hardened runtime; no sandbox; the entitlements and Info.plist above), run `xcodegen generate` in `apple/`, then **delete `project.yml`** — the committed `.xcodeproj` is the source of truth from here on (user decision).

- [ ] **Step 3: Add the verify-only Run Script phase**

`scripts/verify-ffi-fresh.sh` fails with "Rust library is older than its sources: run `just ffi`" when any `crates/**/*.rs`, `Cargo.toml` or `Cargo.lock` is newer than `apple/build/libtesserae.a`, when the content stamp differs (see **As built**), or when the `.a` is missing. Declare its input/output files so it works under `ENABLE_USER_SCRIPT_SANDBOXING`; it never builds.

- [ ] **Step 4: Run it**

Run: `just ffi && just app-test`
Expected: PASS. If the link fails on the embedded bitcode, stop and report the exact linker output before trying any workaround (candidates to report on, not to apply silently: `xcrun bitcode_strip -r` on the archive; a non-LTO release profile for the staticlib).

- [ ] **Step 5: Verify the stale-library guard, then commit**

Touch a Rust source and run `just app-build`. Expected: the build fails with the message above. Then `just ffi && just app-build` succeeds.

```bash
git add apple scripts justfile .gitignore .github crates/tesserae-core/tests/license_headers.rs
git commit -m "build: Xcode project linking the universal Rust library"
```

---

### Task 4: `Snapshot` — the ARC owner of Rust memory

**Files:**
- Create: `apple/TesseraeKit/Snapshot.swift`, `apple/TesseraeKitTests/SnapshotTests.swift`

**Interfaces:**
- Consumes: `TesseraeFFI` (Task 3).
- Produces:
  ```swift
  public final class Snapshot {
      public let root: UInt32
      public var nodes: UnsafeBufferPointer<TessNode> { get }   // computed: Debug builds assert liveness on every access
      public var names: UnsafeRawBufferPointer { get }
      public let stats: TessScanStats
      public let stalledAt: Data?                 // raw path bytes, nil if absent
      init(handle: OpaquePointer)                  // takes ownership; deinit calls tess_snapshot_release
      public func name(_ i: UInt32) -> String      // lossy UTF-8, control characters replaced, never ""
      public func nameBytes(_ i: UInt32) -> Data
      public func children(_ i: UInt32) -> Range<UInt32>
      public func path(_ i: UInt32) -> String      // root name is the scan root as given (spec §6)
      public func isDirectory(_ i: UInt32) -> Bool
      public func allocated(_ i: UInt32) -> UInt64    // added with Task 6's TreeSource conformance
      #if DEBUG
      public var generation: UInt64 { get }        // a birth tag; detection is a lock-guarded `released` flag, asserted on access
      #endif
  }
  ```
  **As built (Ruling T4-1).** `node(i)`, `name`, `children` and `path` check their index and offset ranges with `precondition`, which stays in `-O` builds: indices come from hit-testing and UI state, a bad one is a bug, and trapping is memory-safe where a silent fallback would not be. The Debug liveness check (an `NSLock`-guarded `released` flag asserted by every `nodes`/`names` access; `generation` is only a birth tag) is compiled out of Release. An internal test seam, `init(testingNodes:names:root:)`, builds a handle-less snapshot over caller-owned buffers so the range checks can be tested with malformed nodes.

- [ ] **Step 1: Write the failing tests** (scan a temporary directory through the C ABI directly to obtain a real handle)

```swift
func test_counts_and_root_match_the_view()
func test_children_are_contiguous_and_sorted_by_allocated_descending()
func test_names_decode_lossily_and_never_empty()          // a non-UTF-8 name built with open(2) on bytes
func test_path_joins_from_the_root_as_given()
func test_buffers_survive_while_snapshot_is_retained()    // spec §12: a background task holds the Snapshot, the local ref is dropped, reads succeed
func test_access_after_release_traps_in_debug()           // spec §12: run in a child process (XCTest + posix_spawn of the test binary with a filter) and assert it crashed
func test_node_index_out_of_range_traps()                 // T4-1: also name-range and children-range traps, in every build
```
(The suite as built has 16 tests; the crash test spawns an `xcrun xctest` child, with a control run that must not crash.)

- [ ] **Step 2: Run — expect failures (type not defined).** `just app-test`

- [ ] **Step 3: Implement.** Read `TessView` once in `init`; build the two buffer pointers from it; `deinit` releases. Decode names with `String(decoding:as: UTF8.self)` and replace C0 control characters with U+FFFD; an empty result becomes "(unnamed)".

- [ ] **Step 4: Run — expect PASS. Mutation-verify** (e.g. release in `init`; drop the control-character replacement).

- [ ] **Step 5: Commit** — `git commit -m "feat(kit): Snapshot owns the Rust snapshot through ARC"`

---

### Task 5: `ScanCoordinator`

**Files:**
- Create: `apple/TesseraeKit/ScanCoordinator.swift`, `apple/TesseraeKitTests/ScanCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Snapshot` (Task 4).
- Produces:
  ```swift
  public enum ScanState: Equatable { case idle, scanning(ScanProgress), finished, failed(errno: Int32) }
  public struct ScanProgress: Equatable { public var dirs, files, bytes, errors: UInt64; public var entriesPerSecond: Double }
  @MainActor public final class ScanCoordinator: ObservableObject {
      @Published public private(set) var state: ScanState
      @Published public private(set) var snapshot: Snapshot?
      public func start(root: URL, options: TessScanOptions = .init())
      public func cancel()
  }
  ```
  **As built.** The scan handle sits behind an internal protocol, `ScanDriving` (progress, cancel, status, finish), and the coordinator takes a `ScanFactory`, so tests drive progress and restart with **fake scans** whose progress and completion they control. This replaced a real 40,000-file scan that raced a 5 ms progress tick and failed once on CI (`test_progress_is_published_while_scanning` found no publication on `macos-26`); only the cancel test still runs a real scan (cancelling takes microseconds against tens of milliseconds of work). The scan task holds `self` weakly, `deinit` cancels the scan through a nonisolated handle box, and `inFlight` is cleared when its task completes.
  Progress is polled with `tess_scan_progress` at 10 Hz on the main actor; `tess_scan_finish` is called off the main actor only after `tess_scan_status` reports finished (it consumes the handle; nothing else touches the handle after that call). A new `start` cancels and waits out any scan in flight before beginning. A cancelled scan still delivers its partial snapshot (spec §7). Progress shows counts and a rate, never a percentage (spec §7).

- [ ] **Step 1: Failing tests**

```swift
func test_scan_of_a_temp_tree_finishes_with_matching_totals()
func test_progress_is_published_while_scanning()          // a tree big enough that at least one progress update arrives; assert it did
func test_cancel_returns_a_partial_snapshot_flagged_cancelled()
func test_missing_root_fails_with_enoent()
func test_restart_cancels_the_previous_scan_and_never_mixes_snapshots()
func test_releasing_the_coordinator_cancels_its_scan()
func test_a_second_scan_after_the_first_finished_begins_at_once()
```
(The progress, restart and release tests run on fake scans; the totals, missing-root, cancel and second-scan tests run real scans.)

- [ ] **Step 2–4:** run (fail), implement, run (pass), mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): ScanCoordinator drives scans and publishes progress"`

---

### Task 6: Squarified layout with level-of-detail

**Files:**
- Create: `apple/TesseraeKit/Layout/{TreeSource.swift,SquarifiedLayout.swift,Tile.swift}`, `apple/TesseraeKitTests/LayoutTests.swift`, `apple/TesseraeKitTests/Support/{SyntheticTree.swift,SplitMix64.swift}`

**Interfaces:**
- Produces:
  ```swift
  public protocol TreeSource {
      var rootIndex: UInt32 { get }
      func children(_ i: UInt32) -> Range<UInt32>     // contiguous, sorted by allocated descending
      func allocated(_ i: UInt32) -> UInt64
      func isDirectory(_ i: UInt32) -> Bool
      func isPermissionDenied(_ i: UInt32) -> Bool    // TESS_FLAG_PERM_DENIED: 0 bytes, no children (Ruling T6-2)
  }
  extension Snapshot: TreeSource {}
  public struct Tile: Equatable {
      public var rect: CGRect           // points
      public var node: UInt32           // TESS_NODE_NONE for an aggregate
      public var depth: UInt8
      public var flags: UInt8           // bit 0 selected, 1 staged, 2 permDenied, 3 aggregated (spec §8)
      public var aggregateCount: UInt32 // number of collapsed siblings (or unreadable folders), 0 otherwise
      public var aggregateBytes: UInt64
      public var parent: UInt32         // the directory this tile was laid out in; Tile.noNode for the layout root (Ruling T11-1)
  }
  public struct LayoutParameters { public var subdivideMin: CGFloat = 24; public var cullArea: CGFloat = 16; public var budget = 50_000 }
  public func squarify(_ src: some TreeSource, root: UInt32, in bounds: CGRect, _ p: LayoutParameters = .init()) -> [Tile]
  ```
  Bruls–Huizing–van Wijk over the pre-sorted children (no sorting at layout time). A child whose minimum dimension is below `subdivideMin` is a terminal tile (not recursed). The first child that would fall below `cullArea` starts the tail: `children[k...]` collapses into one aggregate tile ("N smaller items — X"), found by binary search over the sorted run and emitted even when its own area is below `cullArea`, so siblings plus aggregate cover the parent. Stop emitting at `budget`. A zero-size subtree emits nothing, except unreadable directories (below).

  **As built.**
  - **Order and budget.** Output is paint order, **breadth-first**: every parent precedes its children, but a subtree is *not* contiguous in the array (binding on the renderer and hit tester). Directories are subdivided breadth-first, so the budget cuts the deepest levels first, and a parent is never left half covered.
  - **Permission-denied placeholders (Rulings T6-2, T6-3).** An unreadable directory has 0 bytes and would get no tile, leaving the reserved `#fab219` nothing to paint. Each gets a placeholder: a square of side √`cullArea` (4 pt), flagged `permDenied`; more than 16 siblings collapse into one square flagged `permDenied | aggregated` ("N unreadable folders"). They are not squarified with the sized children (a 16 pt² item in a row can come out a fraction of a pixel thick — the first version did, 0.27 px); they fill a strip along the parent's shorter side, packed from the leading corner, painted after the sized siblings, never more than half the parent. The sized children share the rect that remains. The strip is a whole band, so the cells its squares leave empty belong to no tile and the parent's tile shows through. An unreadable layout root is one placeholder filling the view.
  - **The aspect property (Ruling T6-1, a plan defect).** "Worst aspect ratio ≤ 20" cannot hold for arbitrary sizes (siblings of 97.7 % and 2.3 % in a square force a strip of ratio ~44). It is asserted strictly (≤ 20, every tile of area ≥ `subdivideMin²`) on trees whose siblings differ by at most 10×; on heavy-tailed trees the row-building step is checked **exactly** against the greedy rule with an oracle over 16,501 rows (each row laid along the shorter side, no worse than its first item alone, and adding the next item would worsen it), and the heavy-tailed worst ratio is reported, not gated.
  - **Properties adjusted for placeholders.** Coverage is tiles plus the strip's empty cells; area proportionality excludes placeholders and is measured over the rect the strip leaves; placeholders count toward disjointness and the budget.
  - `Tile.parent` (Ruling T11-1) lets Task 11 find subdivided directories in one pass. `aggregateBytes` is the parent's size minus the kept children (the freeze guarantees a directory equals the sum of its children), so the tail is never visited. Hand-built tiles must set `parent`.

- [ ] **Step 1: Failing property tests** over `SyntheticTree` trees generated from a seeded `SplitMix64` (500 seeds each; print the seed on failure):

```swift
func test_rects_are_disjoint_among_siblings()
func test_rects_plus_aggregate_cover_the_parent_within_epsilon()     // epsilon 1e-6 of parent area; placeholder strips' empty cells counted (T6-2)
func test_area_is_proportional_to_size_within_tolerance()           // relative error ≤ 1e-3; excludes placeholders; row step also checked down to 1e-15 of the parent
func test_aspect_ratios_are_bounded()                               // T6-1: ≤ 20 strictly on balanced trees (area ≥ subdivideMin²) + the exact greedy-row oracle
func test_tail_aggregate_is_a_contiguous_suffix()
func test_budget_is_respected()
func test_zero_size_root_yields_no_tiles_and_no_nan()
func test_huge_flat_directory_is_bounded_and_aggregate_is_exact()    // 500_000 children
func test_no_rect_is_nan_or_negative()
func test_permission_denied_directories_get_placeholder_tiles()     // T6-2/T6-3
func test_placeholders_are_visible_squares()                        // 4 pt squares in a strip, never a sliver
func test_tile_parent_is_the_node_it_was_laid_out_in()              // T11-1
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify (e.g. sort removed from a synthetic generator must not be needed; drop the cull check → budget/aggregate tests fail).

- [ ] **Step 5: Measure, then commit.** `XCTest measure` of `squarify` on the Data-volume snapshot root and on the largest directory, recorded (not asserted) in `docs/benchmarks.md`. `git commit -m "feat(kit): squarified layout with level-of-detail"`

---

### Task 7: Colour modes

**Files:**
- Create: `apple/TesseraeKit/Colour/{Palette.swift,ColourMode.swift,FileKind.swift}`, `apple/TesseraeKitTests/ColourTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ColourMode: Equatable { case depth, age(now: Date), typeFocus([FileKind]) }  // typeFocus holds 1...3 kinds
  public enum FileKind: CaseIterable { case video, images, audio, archives, documents }
  public struct Palette { public static func colours(_ m: ColourMode, dark: Bool) -> [SIMD4<Float>] }   // the palette buffer
  public func colourIndex(_ node: UInt32, depth: UInt8, in src: Snapshot, mode: ColourMode) -> UInt16
  public func colourIndex(for tile: Tile, in src: Snapshot, mode: ColourMode) -> UInt16   // aggregates and placeholders, which are no single node
  ```
  **As built — the palette buffer layout** (the same for every mode, and what the shader and the CoreGraphics renderer index): `[0]` neutral, `[1]` status (`#fab219`), `[2…]` the mode's ramp (depth 5 steps, age 7 buckets recent first, type focus 3 slots). So a ramp colour's index is `Palette.firstColourIndex + step`. The `SIMD4<Float>` values are sRGB-encoded (hex / 255), not linear. `colourIndex(for: Tile…)` gives a permission-denied tile (including the collapsed "unreadable folders" square) the status colour in every mode, and any other aggregate its depth colour in depth mode and neutral in age and type-focus modes, having no single age or kind. A year is taken as 365 days; the age subtraction is overflow-safe, and a `modified` of 0 (never read) lands in the oldest bucket.
  Exact values (spec §8 and the reference blue ramp):
  - Depth (ordinal, depth modulo 5): light `#86b6ef #5598e7 #2a78d6 #1c5cab #104281`; dark `#184f95 #256abf #3987e5 #6da7ec #9ec5f4`.
  - Age (sequential, 7 buckets by `now - modified`: ≤ 7 days, ≤ 30 days, ≤ 90 days, ≤ 1 year, ≤ 2 years, ≤ 5 years, older): light, recent→stale `#cde2fb #9ec5f4 #6da7ec #3987e5 #256abf #184f95 #0d366b`; dark is the same list reversed (recent = `#0d366b`). A future `modified` counts as ≤ 7 days.
  - Type focus: slots light `#2a78d6 #eb6834 #1baf7a`, dark `#3987e5 #d95926 #199e70`; everything else neutral — light `#d6d5cf`, dark `#3a3a37`; directories in type-focus mode are neutral.
  - Status: permission-denied `#fab219` in every mode. Surfaces: light `#fcfcfb`, dark `#1a1a19`.
  - FileKind by lowercased extension: video `mp4 mov m4v mkv avi webm mts`; images `jpg jpeg png heic heif gif tif tiff webp raw cr2 cr3 nef arw dng psd`; audio `mp3 m4a aac wav aiff aif flac ogg opus`; archives `zip dmg iso tar gz tgz xz bz2 7z rar pkg xip`; documents `pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md epub`.

- [ ] **Step 1: Failing tests**

```swift
func test_palette_values_are_exactly_the_spec_values()      // every hex above, both modes: nudging any colour fails CI (spec §12's durability goal)
func test_light_mode_aqua_contrast_is_the_documented_2_74()  // WCAG contrast of #1baf7a on #fcfcfb rounds to 2.74
func test_depth_cycles_every_five_levels()
func test_age_buckets_boundaries()                           // exactly 7 d, 7 d + 1 s, …, and a future date
func test_type_focus_takes_at_most_three_kinds()
func test_kind_matching_is_case_insensitive_and_ignores_dotfiles()   // ".mp4" alone is not a video
func test_permission_denied_overrides_every_mode()
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): depth, age and type-focus colour modes"`

Note: spec §12 asks for the palette validator in CI. The validator is not part of this repository; pinning the validated values in a test meets the same goal (a nudge fails CI). Recorded in spec §12 as a Phase 2 decision; wiring the validator itself remains open.

---

### Task 8: Metal renderer

**Files:**
- Create: `apple/TesseraeKit/Render/{TreemapRenderer.swift,Shaders.metal,TreemapView.swift}`, `apple/TesseraeKitTests/MetalRendererTests.swift`

**Interfaces:**
- Consumes: `Tile` (Task 6), `Palette` (Task 7).
- Produces:
  ```swift
  public struct TileInstance { var rect: SIMD4<Float>; var colorIdx: UInt16; var depth: UInt8; var flags: UInt8 }  // spec §8; 20 bytes of payload, 32-byte stride, matched by Shaders.metal
  public final class TreemapRenderer {                       // owns device, pipeline, 3 instance buffers + DispatchSemaphore(value: 3), storageModeShared
      public init?(device: MTLDevice)
      public func update(tiles: [Tile], colourOf: (Tile) -> UInt16, palette: [SIMD4<Float>])
      public func draw(in view: MTKView, alpha: Float = 1)
      public func renderOffscreen(size: CGSize, scale: CGFloat) -> CGImage   // for tests
      public private(set) var droppedTileCount: Int                 // tiles past the (possibly halved) budget; see below
  }
  public struct TreemapView: NSViewRepresentable                // hosts MTKView; with no Metal device (Ruling P2) a plain placeholder here, Task 9's renderer from then on
  ```
  One instanced draw of a unit quad; the fragment shader fills from the palette buffer and draws a 1 px inner border from fragment distance to the rect edge (no second draw call). On `MTLBuffer` allocation failure, halve the instance budget and retry (spec §11).

  **As built.**
  - **Colour space.** Palette values are sRGB-encoded and the targets are `.bgra8Unorm` (a non-sRGB format): the shader writes the raw palette values, so each stored byte is the palette's hex value, and the view's `colorspace` (sRGB) tells the compositor how to read them. The border is one *device* pixel wide, the fill's RGB × 0.7.
  - **`droppedTileCount` (review finding).** Budget-halving drops the deepest tiles (the list is breadth-first); that must never under-report silently, so the renderer counts them and the app shell shows a banner (Task 13). An allocator that always fails makes `init?` return nil.
  - **Tests compare pixels exactly** (zero tolerance, on the fill and the border), which caught a +1 fill mutant that a ±1 tolerance missed.
  - The shader ignores `TileInstance.flags` (selection, padlock and staging are not drawn by the Metal pass; the app draws the selection outline as an overlay, Task 13). The CI job downloads the Metal toolchain if a trivial shader will not compile (Task 3). A test kernel, `tile_instance_probe`, ships in the metallib so a test can read an instance back as the shader sees it.

- [ ] **Step 1: Failing tests** (skip with `XCTSkip("no Metal device")` only when `MTLCreateSystemDefaultDevice()` is nil — a loud, named skip)

```swift
func test_tile_centre_pixel_is_its_palette_colour()
func test_inner_border_is_one_pixel_and_darker_than_fill()
func test_instance_struct_layout_matches_the_shader()        // MemoryLayout stride vs a value written by a compute/readback test
func test_budget_halves_when_buffer_allocation_fails()       // inject an allocator that fails once
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): instanced Metal treemap renderer"`

---

### Task 9: CoreGraphics fallback and snapshot tests

**Files:**
- Create: `apple/TesseraeKit/Render/CGTreemapRenderer.swift`, `apple/TesseraeKitTests/RenderSnapshotTests.swift`, `apple/TesseraeKitTests/SnapshotTests/*.png`

**Interfaces:**
- Produces: `public struct CGTreemapRenderer { public func render(tiles: [Tile], colours: [SIMD4<Float>], colourOf: (Tile) -> UInt16, size: CGSize, scale: CGFloat) -> CGImage }` — same fill and 1 px border as the shader; used when Metal is unavailable, with zoom animation disabled (spec §11). It replaces Task 8's placeholder (Ruling P2); `TreemapView`'s fallback view re-renders only when what it would draw changes (tiles, colour indices, palette, appearance, size, backing scale).

  **As built — the CG quantiser matches the GPU.** A palette mutation failing the Metal/CG cross-check exposed a real defect: CoreGraphics rounds ties half away from zero, the GPU's unorm store rounds to nearest even, and `fill × 0.7` lands on exact .5 for shipped colours. The matching rule is the shader's `Float` product `v × 0.7`, then × 255 **in `Double`**, rounded ties-to-even (plain `.toNearestOrEven` on `Float` was still wrong on one channel, 0x37). The cross-check now covers **every palette** (depth, age, type focus, light and dark, neutral, and a status tile) byte-for-byte at 1× and 2×.

- [ ] **Step 1: Failing tests** — deterministic reference images (spec §12: "snapshot-test the treemap through the CoreGraphics fallback"). Reference PNGs are recorded once with `TESSERAE_RECORD_SNAPSHOTS=1` (through xcodebuild, `TEST_RUNNER_TESSERAE_RECORD_SNAPSHOTS=1`), located by `#filePath` rather than as bundle resources, and committed; comparison is exact on pixel bytes. Three references exist: depth light, depth dark at 2×, and type focus with permission-denied tiles (re-recorded when the placeholders became strips, T6-3).

```swift
func test_fixed_tree_depth_mode_light_matches_reference()
func test_fixed_tree_depth_mode_dark_matches_reference()
func test_type_focus_and_permission_denied_tiles_match_reference()
func test_tiny_and_zero_sizes_emit_no_nan()                 // Review Focus 4, Ruling P3: layout + both renderers at 0×0, 0.5×0.5, 1×1, no animation (the Metal half is a visible XCTSkip with no device)
func test_metal_and_coregraphics_agree_on_every_palette()   // the exact cross-check above
func test_fill_border_and_painter_order_pixels()
func test_fallback_view_rerenders_on_scale_change_but_not_on_unchanged_update()
```
`renderOffscreen` and `render` clamp a size that rounds to zero to 1×1.

- [ ] **Step 2–4:** fail, implement, pass; mutation-verify by changing one palette entry (reference test must fail).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): CoreGraphics fallback renderer with snapshot tests"`

---

### Task 10: Navigation, zoom animation, hit testing, inspector

**Files:**
- Create: `apple/TesseraeKit/Navigation/{Navigator.swift,ZoomAnimation.swift}`, `apple/TesseraeKit/Interaction/{HitTester.swift,Inspector.swift}`, tests for each

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class Navigator: ObservableObject {
      @Published public private(set) var root: UInt32
      public var breadcrumb: [UInt32] { get }          // root of the snapshot … current root
      public func descend(into node: UInt32)           // no-op for a file or an aggregate
      public func ascend()                              // ⌘↑
      public func sibling(_ step: Int)                  // ← / →, clamped
  }
  public struct ZoomAnimation {                         // spec §8: ~250 ms ease-out, old layout transformed so the clicked rect fills the viewport, cross-faded
      public init(from: CGRect, viewport: CGRect, duration: TimeInterval = 0.25)
      public func transform(at t: TimeInterval) -> CGAffineTransform
      public func alpha(at t: TimeInterval) -> Float
      public var isFinished: Bool { get }
  }
  public struct HitTester { public mutating func tile(at p: CGPoint, in tiles: [Tile]) -> Int? }   // linear scan from the end (deepest match), last-hit cache
  public struct InspectorInfo: Equatable {              // as built: subject and kind are enums, `path` is nil unless the tile is one node
      public var subject: Subject                       // .node(path:) / .aggregate(count:bytes:) / .unreadable(count:)
      public var allocated, logical: UInt64
      public var kind: Kind                             // .folder / .file / .fileKind(FileKind) / .aggregate / .unreadable
      public var modified: Date?                        // nil when unknown (a stored 0)
  }
  public func inspect(_ node: UInt32, in s: Snapshot) -> InspectorInfo
  public func inspect(tileAt index: Int, in tiles: [Tile], snapshot s: Snapshot) -> InspectorInfo
  ```

  **As built.**
  - **The cross-fade composites whole layers.** Fading per-tile alpha would blend a pixel twice where a child paints over its parent (found in Task 8's review). Each frame the old layout (through the animation's scale-and-translate, applied to the rects so borders stay one device pixel wide) and the new layout are drawn *opaque* into two offscreen textures, then a composite pass writes `mix(old, new, alpha)`. `TreemapRenderer` gained `beginZoom()` / `drawZoom(in:oldTransform:alpha:)` / `endZoom()`. Nothing is laid out during the animation, and the CoreGraphics fallback does not animate (Ruling P2). A `ZoomPlayer` runs one animation against the display clock; a resize cancels it.
  - **`InspectorInfo` (review finding I1).** The tile may stand for no single node, and display text must never sit in a field an action could treat as a path (deletion staging will act on it), so `path` is a computed property that is nil unless `subject` is `.node`; `title` is the heading text. `kind` is an enum shared with the file table (`nodeKind`).
  - **No `isFlipped` overrides.** The views stay unflipped (so their layers draw as before) and the event handlers convert y once (`TreemapInteraction.tilePoint`), tested with real mouse events in an `NSWindow`.
  - **Interaction lives in `TreemapInteraction`** (hover, click as press-and-release on the same tile, Return descends into the first descendable of the hovered or selected tile, ⌘↑, ← / →). A descend records the clicked rect as a *pending zoom* tied to the target root; it is dropped on ascend, sibling moves, a navigator swap and a resize, so a later tiles change never zooms from a stale rect. `Navigator` gained `canDescend(into:)` and `ascend(to:)` (a breadcrumb jump in one change); it refuses unreadable directories.
  - **Return to an ancestor animates too** (Task 14, below): the old root shrinks into its tile in the ancestor's layout using the same transform with a virtual old-layout window (`navigationZoomRect`); if that root has no emitted tile it redraws at once.
  - **Ruling P3:** `resize_to_zero_mid_animation_emits_no_nan` lives here, with `ZoomAnimation`.

- [ ] **Step 1: Failing tests**

```swift
func test_descend_ascend_and_breadcrumb_round_trip()
func test_descend_into_file_or_aggregate_is_a_no_op()
func test_sibling_navigation_clamps_at_the_ends()
func test_zoom_transform_maps_the_clicked_rect_onto_the_viewport_at_the_end()
func test_zoom_is_ease_out_and_finishes_at_250ms()
func test_hit_test_returns_the_deepest_tile_and_uses_the_cache()
func test_hit_test_of_50k_tiles_measured()                  // XCTest measure, recorded in docs/benchmarks.md, not asserted (spec §12)
func test_inspector_reports_both_sizes_kind_and_date()
func test_resize_to_zero_mid_animation_emits_no_nan()       // Ruling P3
func test_zoom_cross_fade_is_uniform_where_tiles_overlap()  // the layer-composited fade, against an oracle
func test_static_zoom_destination_is_cached_and_invalidated_without_changing_pixels()   // Task 14's cache
```
(Further tests cover `TreemapInteraction` — events flipped into tile coordinates, click needing press and release on one tile, Return after new tiles, pending zoom dropped — in `NavigatorTests`.)

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Wire into `TreemapView`:** click a directory tile → animate (two instance buffers + alpha uniform, no per-frame relayout) → descend; Return descends into the hovered directory. Commit — `git commit -m "feat(kit): navigation, zoom animation, hit testing and inspector"`

---

### Task 11: Labels

**Files:**
- Create: `apple/TesseraeKit/Labels/{LabelPlacer.swift,LabelsOverlay.swift}`, `apple/TesseraeKitTests/LabelTests.swift`

**Interfaces:**
- Produces: `public func placeLabels(_ tiles: [Tile], in s: Snapshot, measure: (String) -> CGSize, max: Int = 400, locale: Locale = .current) -> [PlacedLabel]` where `PlacedLabel { rect: CGRect; text: String }` — name plus size, middle-truncated, emitted only where both fit inside the tile with 4 pt padding, largest tiles first, at most `max`. `LabelsOverlay` is a SwiftUI overlay of positioned `Text` in ink tokens, hidden while a `ZoomAnimation` runs and faded in (0.15 s) once the current layout's labels have arrived (spec §8).

  **As built.**
  - **No label on a subdivided directory tile** (accepted ruling): its children are labelled and the breadcrumb names the root. "Subdivided" is "is the `parent` of any tile" (Ruling T11-1; a set lookup, replacing a quadratic scan that ran on the main thread after every zoom). Permission-denied placeholders get no label; the collapsed "N unreadable folders" square does, as do aggregates ("N smaller items — X", the inspector's wording).
  - **The locale is injectable** (the app uses `.current`; tests pin `en_US`), through `displaySize`, `displayCount` and `placeLabels`, including the inspector tests.
  - **The size is never truncated.** Only the words (the name, or "N smaller items") are cut in the middle, by whole grapheme clusters, keeping at least three characters; if the size and three characters do not fit there is no label.
  - **Hostile names are neutralised.** Newlines, tabs and line separators read as spaces; other control characters, bidi overrides and isolates, and invisible format characters (Unicode category Cf, except the joiners U+200C/U+200D that emoji and some scripts need) become U+FFFD; a name that is then empty reads "(unnamed)". Names are decoded from their bytes (crafted filenames in a deletion tool).
  - **Measurement and fade (Task 13/14 rounds).** `LabelStyle.measure` uses Core Text (immutable, thread-safe), so placement runs **off the main actor** under a generation guard; the overlay's opacity is keyed on the labels *arriving* (`labelsReady`), not on the end of the zoom, and fades in over 0.15 s.

- [ ] **Step 1: Failing tests**

```swift
func test_labels_only_where_they_fit()
func test_labels_truncate_long_and_control_character_names()   // Review Focus 3
func test_at_most_max_labels_largest_first()
func test_aggregate_tile_label_reads_n_smaller_items()          // "12,345 smaller items — 4.2 GB", locale pinned
func test_size_is_never_truncated_only_the_words()
func test_truncation_never_splits_a_grapheme_cluster()
func test_bidi_and_invisible_format_characters_are_neutralised()
func test_directory_whose_children_collapsed_is_not_labelled_over_them()
func test_locale_is_injectable()
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): label placement and overlay"`

---

### Task 12: File table, top-K, shared selection

**Files:**
- Create: `apple/TesseraeKit/Table/{FileTableModel.swift,FileTableView.swift,TopK.swift,Selection.swift}`, `apple/TesseraeKitTests/TableTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor public final class Selection: ObservableObject { @Published public var nodes: Set<UInt32> }   // shared by table and treemap (spec §8)
  public enum SortKey { case name, allocated, logical, modified, kind }
  public final class FileTableModel {                  // rows are [UInt32] indices into the snapshot, never copied nodes
      public init(snapshot: Snapshot, scope: UInt32, limit: Int = 1000)    // the current navigation root's subtree
      public func sorted(by: SortKey, ascending: Bool) async -> [UInt32]   // sorting happens off the main actor
  }
  public struct FileTableContent { public let snapshot: Snapshot; public let rows: [UInt32] }   // published as one value
  @MainActor public final class FileTableRows: ObservableObject { /* content, reset(), load(_:), sort(by:ascending:) */ }
  public func applySelection(_ tiles: inout [Tile], _ selection: Set<UInt32>)   // sets/clears flag bit 0
  public func topK(_ k: Int, files s: Snapshot, under root: UInt32) -> [UInt32]   // bounded min-heap, files only, by allocated
  public struct FileTableView: NSViewRepresentable    // NSTableView; columns Name, Allocated, Logical, Modified, Kind
  ```
  Default view lists the top 1,000 largest files under the current root; selecting a row highlights its tile (flag bit 0) and vice versa.

  **As built.** A column sort reorders those **top-1,000 candidates**, not every file in the subtree (the window says so: "Largest 1,000 files in this folder · column sorts apply to this list"). `FileTableRows` publishes `(snapshot, rows)` as one atomic `FileTableContent` — it is cleared when a load starts and swapped only when the rows are ready — so a reader can never pair one snapshot with another's indices; every load and sort takes a generation number and cancels the work in flight, and a stale result is dropped. Cells bounds-check their node index against the snapshot. A selection arriving from the treemap scrolls its row into view (a node outside the top 1,000 has no row). The default order is largest first with ties by lower node index; sorts are stable on ties whichever way they run, and a stored `modified` of 0 sorts as oldest. VoiceOver reads "modified unknown" for it. `nodeKind` is shared with the inspector.

- [ ] **Step 1: Failing tests**

```swift
func test_sort_orders_indices_not_nodes_for_every_key()
func test_sort_is_stable_on_ties()
func test_top_k_matches_a_full_sort()                       // SplitMix64-generated trees, 200 seeds
func test_selection_round_trips_between_table_and_treemap()
func test_table_cells_have_voiceover_labels()               // spec §12
func test_loading_never_publishes_a_snapshot_with_another_snapshots_rows()
func test_a_stale_sort_is_never_applied_to_a_newer_snapshot()
func test_cells_never_trap_on_rows_outside_the_snapshot()
func test_a_selection_from_the_treemap_scrolls_into_view()
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): file table with off-main sorting, top-K and shared selection"`

---

### Task 13: App shell

**Status (2026-10-19): complete (`f33dd4a`, with review fixes `9dabe7f` and `26e4ac5`); full gate and universal Release build passed; light/dark screenshots retained locally.**

**Files:**
- Modify: `apple/Tesserae/{TesseraeApp.swift,ContentView.swift}`
- Create: `apple/TesseraeKit/AppModel.swift`, `apple/TesseraeKit/ScanBanner.swift`, `apple/TesseraeKitTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel: ObservableObject` composing `ScanCoordinator`, `Navigator`, `Selection`, colour mode and the current layout; `ScanBanner.text(for: TessScanStats, stalledAt: String?) -> String?` (nil when complete).
  Window: toolbar with "Scan Data Volume" (`/System/Volumes/Data`), "Scan Folder…" (`NSOpenPanel`), Cancel, and the colour-mode picker (type focus lets the user tick up to three `FileKind`s; the focus legend is always visible in that mode); a progress view (counts and entries/s, no percentage) while scanning; then a horizontal split of treemap and table with the breadcrumb above and an inspector pane (a trailing column, not the macOS 14 `.inspector` modifier); an incompleteness banner whenever `stats.incomplete != TESS_INCOMPLETE_NONE` or `errors`/`unreadable_count` > 0, so a partial result is never shown as complete (spec §1 success criterion 3). Light and dark mode follow the system.

**As built.**
- **One session per snapshot (Ruling: replace the complete session on rescan).** `AppSession` owns one `Snapshot` and every index-bearing piece of UI state — `Navigator`, `Selection`, the table rows, tiles, labels, inspector, hover — and `AppModel` publishes replacement sessions; the SwiftUI subtree is keyed by the session's UUID. An old view or callback keeps its own snapshot and cannot write new-session state, so no index from the old snapshot survives. `FileTableRows.reset()` invalidates requests and clears synchronously before any asynchronous load.
- **Deferred decorations.** On a navigation the labels and the table's top-K work are deferred until motion settles (placement for a new root started only after the zoom ends; an empty folder, which has no renderer to report, settles directly), guarded by a layout generation so a stale completion is dropped. The deferral was found to matter: label placement dominated navigation preparation.
- **The selection outline is a SwiftUI overlay** (a 2 pt stroke on the tiles flagged `selected`, hidden during motion like the labels), because the Metal shader ignores `flags` (Task 8) and changing the pixel contracts there was out of scope. Permission-denied tiles get a lock badge overlay and a VoiceOver label.
- **`droppedTileCount`** (Task 8) shows as a "Rendering limit: N tiles could not be displayed" warning. The scan-banner text is "Partial result — …", built over every actual constant of the header (it has eight `TESS_INCOMPLETE_*` constants: `NONE` plus seven reasons, not eight reasons) and an unknown future code.
- The `focus legend` lists the chosen kinds and "Other files and folders" with VoiceOver labels. The window is an `HSplitView` (treemap over table, then a 240 pt trailing inspector column).

- [ ] **Step 1: Failing tests**

```swift
func test_banner_text_for_every_incomplete_code()           // table-driven over all 8 codes, incl. stalled path and volume lost
func test_banner_mentions_unreadable_and_errors_when_complete()
func test_empty_scan_shows_empty_state()                     // Review Focus 1
func test_rescan_swaps_snapshot_atomically()                 // Review Focus 5: navigation, selection and hover reset in one main-actor transaction; no index from the old snapshot survives (asserts the old Snapshot is released)
func test_focus_legend_has_voiceover_labels()
func test_navigation_defers_labels_and_table_until_zoom_settles()
func test_leaving_an_empty_folder_settles_labels_and_table()
func test_labels_ready_only_once_the_current_layouts_labels_are_applied()
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Run the app.** `just app-build`, launch it, scan this repository and then `/System/Volumes/Data`; screenshot both colour schemes. Commit — `git commit -m "feat(app): scan, treemap and table window"`

---

### Task 14: Phase gate — fluid zoom on a million-node tree

**Status (2026-10-19): PASSED on a Release build.** On the Apple M5 (60 Hz) with a 6.15M-node scan of `/System/Volumes/Data` (no incomplete stop code, 1,006 unreadable folders), the measured run had **0 of 414** presentation intervals spanning more than one refresh (maximum 16.668 ms, one refresh at 60 Hz; the warm-up run: 0 of 415, 16.671 ms), GPU maximum 9.312 ms and raw relayout maximum 1.202 ms. Details, the toolchain and workload caveats and the raw capture are in `docs/benchmarks.md` ("Phase 2: Release frame gate — PASSED").

**How it got there.** The first captures were taken on an optimised **Debug** build (`-O` on the Debug configuration), which keeps `Snapshot`'s Debug liveness lock and assertions on every access, and **failed**: presentation gaps reached 50.00 ms on a partial 3.22M-node scan, then on a 6.14M-node rerun after the user approved the macOS prompts, and 33.33 ms (2 of 411 intervals) after label/table deferral and renderer caching. Those verdicts stand, relabelled "Debug `-O`" in `docs/benchmarks.md`. Ruling G-1 then required measuring the gate on a Release build — the configuration that ships — before any further optimisation or any change to the gate's definition; the threshold was never moved. Alongside, label placement moved off the main actor (it had blocked ~67 ms after each settle and overlapped the next transition in the back-to-back protocol).

Spec §17: "Fluid zoom on a million-node tree." Defined here as: on the development machine (Apple M5), with the `/System/Volumes/Data` snapshot (6.7M nodes) loaded, every frame of a zoom animation into and out of the five largest directories completes within the display's frame budget (16.7 ms at 60 Hz; 8.3 ms at 120 Hz if the display runs ProMotion), and relayout for each new root completes in under 100 ms.

**Files:**
- Create: `apple/TesseraeKit/Diagnostics/FrameTimer.swift` (`FrameTimer`, `FrameGateConfiguration`, `PhaseGateRunner`, `FrameGateAutorun`; signposts + per-frame durations, recording only when `TESSERAE_FRAME_TIMING=1`, **in every build configuration**), `scripts/frame-gate-summary.py`, `docs/benchmarks/2026-10-19-phase2-release-gate.json` (the Release capture, minified) and `docs/benchmarks/2026-10-19-phase2-renderer-caches.json` (the last Debug `-O` capture, kept for comparison)
- Modify: `docs/benchmarks.md`, `docs/phase-2-backlog.md` (strike what Phase 2 closed), spec §13 (Phase 2 results line)

**As built.**
- `FrameTimer` records separately, per transition: layout and preparation (CPU), encode (CPU), GPU execution, **draw-callback cadence** and **presented cadence** (`addPresentedHandler` / `presentedTime`). GPU completion alone is not visible smoothness (a ruling: reporting them together risked a false pass), so the gate is judged on the presentation interval, against the display's refresh period (refresh read from `CGDisplayMode`, falling back to `NSScreen.maximumFramesPerSecond`).
- **The gate is defined and measured on a Release build, through environment variables** read once at launch: `TESSERAE_FRAME_TIMING=1` turns the timer on; `TESSERAE_FRAME_GATE_AUTORUN=<absolute path>` makes the app scan that root, fill the main screen's visible frame, run the protocol, write the capture and quit; `TESSERAE_FRAME_GATE_OUT=<absolute path>` is the output; `TESSERAE_FRAME_GATE_TIMEOUT=<seconds>` (default 900) bounds the whole autorun (window, scan, protocol), exiting 3 if it passes first. A mistyped variable aborts launch (exit 2); a run in which any zoom did not finish within 3 s is saved but rejected (exit 1); a screen that never draws (locked) is therefore a failure, never a pass. Only the Diagnostics menu is `#if DEBUG`. The runner exists only when timing is enabled and the capture embeds no source path.
- **Protocol** (unchanged by any ruling): the five largest sized, readable directories directly under the root, each entered and left three times (30 transitions: both directions, per Ruling "add return-to-ancestor animation").
- **Procedure of record:** a **warm-up run, then the measured run**, of the same Release binary (the first clears any macOS access prompts and warms the file cache; its result is recorded as a cross-check, not counted). `docs/benchmarks.md` ("Running the gate on a Release build") has the exact command; the local-only `ENABLE_HARDENED_RUNTIME=NO` override it uses is a measurement convenience (dyld rejects the ad-hoc framework under library validation) and changes no project setting.

- [ ] **Step 1:** Add `FrameTimer`: `os_signpost` intervals for layout, encode and present; collects per-frame durations during an animation.
- [ ] **Step 2:** Build Release and run the autorun on the Data volume (warm-up run, then the measured run), per `docs/benchmarks.md`.
- [ ] **Step 3:** Record in `docs/benchmarks.md`: display refresh rate, per-frame max and p99, relayout times, tile counts, commit. Expected: within the definition above. If not, stop and report the measurements — do not tune thresholds to pass. (The Debug `-O` captures stopped here, three times; the Release capture passed.)
- [ ] **Step 4: Commit** — as built, `docs: Phase 2 frame-time gate on the Data volume` became a series ending in `docs(bench): Phase 2 frame gate passes on a Release build`.

---

## Not in this plan

- **macOS 13/14 golden-buffer capture and the `O_NOFOLLOW_ANY` check on a 13.x kernel** need a machine or VM running those versions; they stay first in `docs/phase-2-backlog.md`.
- **Dataless (iCloud) directories** — the spec §16 decision needs a probe that evicts a folder in your iCloud Drive (`brctl evict`), which syncs through your iCloud account. It gets its own short task once you agree to that side effect.
- Reconciliation, scan report, FDA onboarding (Phase 3); Jetsam and deletion (Phase 4); signing, notarization, Sparkle (Phase 5).
