# Tesserae Phase 2: Treemap, File Table, Navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native Mac app that scans a folder or the Data volume with the Phase 1 engine and shows the result as a fluid, zoomable squarified treemap beside a sortable file table, with selection shared between them.

**Architecture:** Rust stays the engine behind the C ABI; it gains a per-node modification time. A Swift framework, `TesseraeKit`, owns everything testable — the snapshot wrapper, scan coordinator, layout, colour, Metal and CoreGraphics renderers, hit testing, labels, the table model — and a thin SwiftUI app target, `Tesserae`, hosts it. The Rust static library is built out of band by a script and linked as a prebuilt universal `.a` (spec §14).

**Tech Stack:** Rust 1.99.1 (existing workspace); Swift 6.4 / Xcode 27.2; SwiftUI + AppKit (`NSTableView`, `MTKView` via `NSViewRepresentable`); Metal; CoreGraphics; XCTest. No third-party Swift dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md` — §5 (architecture), §6 (node and FFI contract), §8 (layout, rendering, interaction), §11 Rendering, §12 Swift and Lifetime/visual/accessibility tests, §14 (Rust inside Xcode, entitlements, CI, repo layout). Deferred Phase 1 work: `docs/phase-2-backlog.md`.

## Global Constraints

- Deployment target **macOS 13.0**, universal binary (arm64 + x86_64). Only APIs available on macOS 13: use `ObservableObject`/`@Published`, not `@Observable`; no `.inspector` modifier; `NavigationSplitView` is fine.
- **No App Sandbox**; hardened runtime on. Info.plist carries the five usage-description keys of spec §14 (`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`, `NSNetworkVolumesUsageDescription`).
- The Rust library the app links is built with exactly `cargo build -p tesserae-ffi --release` per target (never `--all-targets` or `cargo test --release`), with `MACOSX_DEPLOYMENT_TARGET=13.0`, then `lipo`'d (spec §14). Xcode never runs cargo; a Run Script phase only *verifies* the `.a` is newer than the Rust sources.
- Every new `.swift`, `.metal`, `.h` and `.modulemap` file carries the project's GPL-3 notice in that language's comment form, with the copyright line `Copyright (C) 2026 Stephen de la Vega` (no "All rights reserved"); extend `crates/tesserae-core/tests/license_headers.rs` to walk `apple/` and check these extensions.
- `TesseraeKit` is a framework target; all logic lives there and is tested with XCTest. The app target holds only SwiftUI chrome.
- Snapshot memory is borrowed: an `UnsafeBufferPointer` into Rust memory never outlives the `Snapshot` instance that owns it (spec §6 "code rule").
- Colours are exactly the spec §8 values (and this plan's Age ramp below); text uses ink tokens `#0b0b0b` (light) / `#f0efec` (dark), never a tile's colour. Status colour `#fab219` is reserved for permission-denied tiles and always paired with a lock badge and a label.
- Layout constants from spec §8: subdivide threshold **24 px** minimum dimension, cull threshold **16 px²**, instance budget **50,000** tiles, zoom animation **~250 ms ease-out**.
- Performance numbers are reported in `docs/benchmarks.md`, never asserted in CI (spec §12).
- Same discipline as Phase 1: TDD, assert preconditions so no test passes vacuously, mutation-verify new tests, and never rely on recalled macOS constants — read the SDK header or probe.

## Review Focus

1. **Empty or zero-size subtrees** (an empty folder as the scan root; a directory whose allocated size is 0 because every file is dataless or a hardlink duplicate). Expected: no NaN rects, no divide-by-zero, an empty-state message instead of a blank canvas. Tests: Task 6 `zero_size_root_yields_no_tiles_and_no_nan`, Task 13 `empty_scan_shows_empty_state`.
2. **A single directory with hundreds of thousands of children** (a mail store, a node_modules cache). Expected: tail aggregation and the 50k budget keep layout bounded; the aggregate tile reports the right count and size. Test: Task 6 `huge_flat_directory_is_bounded_and_aggregate_is_exact`.
3. **Names that are not UTF-8, very long, or contain newlines/control characters** in labels, the table, the breadcrumb and the inspector. Expected: shown lossily and on one line, never a crash or an empty cell. Tests: Task 4 `names_decode_lossily_and_never_empty`, Task 11 `labels_truncate_long_and_control_character_names`.
4. **A window resized to (near) zero, or resized mid-animation.** Expected: layout skipped below 1×1 point, animation completes or cancels cleanly, no NaN reaches the GPU. Test: Task 9 `resize_to_zero_mid_animation_emits_no_nan`.
5. **Rescanning while the previous snapshot is on screen** (table rows, hover, a running zoom animation all hold indices into it). Expected: the UI swaps to the new snapshot atomically; nothing indexes the old one after release. Tests: Task 4 `buffers_survive_while_snapshot_is_retained`, Task 13 `rescan_swaps_snapshot_atomically`.

---

## File Structure

```
crates/tesserae-core/src/walk/            Task 1: walk.rs split as a pure move
  mod.rs  lane.rs  coordination.rs  open.rs  errors.rs
crates/tesserae-core/src/{attrs,parse,arena,freeze,node}.rs   Task 2: modification time
crates/tesserae-ffi/src/lib.rs, include/tesserae.h            Task 2: TessNode.modified
scripts/build-ffi.sh                       Task 3: both targets + lipo -> apple/build/libtesserae.a
scripts/verify-ffi-fresh.sh                Task 3: Xcode Run Script (verify only)
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
    Interaction/HitTester.swift, Inspector.swift                       Task 10
    Labels/LabelPlacer.swift, LabelsOverlay.swift                      Task 11
    Table/FileTableModel.swift, FileTableView.swift, TopK.swift        Task 12
  TesseraeKitTests/                        one test file per source area; SnapshotTests/ reference PNGs
docs/benchmarks.md                         Tasks 2 and 14 append
```

---

### Task 1: Split `walk.rs` as a pure move

The final Phase 1 review asked for this before Phase 2 builds on the engine (backlog "Do first"). Behaviour must not change.

**Files:**
- Create: `crates/tesserae-core/src/walk/{mod.rs,lane.rs,coordination.rs,open.rs,errors.rs}`
- Delete: `crates/tesserae-core/src/walk.rs`
- Modify: `crates/tesserae-core/src/pool.rs` (imports only), `crates/tesserae-core/src/lib.rs`

**Interfaces:**
- Produces: the unchanged public API `tesserae_core::walk::{walk_serial, WalkOptions, WalkStats, Incomplete, os_errno, with_context}`. Module split: `lane` (Lane, Slot, Held, Dir), `coordination` (Halt, NodeBudget, Share), `open` (open_root, openat_retrying, DirOpener and its impls), `errors` (note_error's classification, `may_mean_volume_gone`, `Incomplete::rank`), `mod` (Walker, the public entry points, re-exports).

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
- Modify: `crates/tesserae-core/src/attrs.rs`, `parse.rs`, `arena.rs`, `freeze.rs`, `node.rs`; `crates/tesserae-ffi/src/lib.rs`, `tests/abi_layout.rs`, `include/tesserae.h` (regenerated); `crates/tesserae-core/tests/fixtures/golden_*` (recaptured); `crates/tesserae-cli/src/main.rs` (inspector-style output of the root's `modified`); spec §6 and §7; `docs/benchmarks.md`

**Interfaces:**
- Produces: `TessNode.modified: i64` — seconds since the Unix epoch (UTC), appended after `allocated`, making the node **48 bytes**. For a file or symlink: its `ATTR_CMN_MODTIME` seconds. For a directory: the maximum of its own modification time and every descendant's (rolled up at freeze, like sizes), so a directory tile's age is its most recently touched content. `RawEntry` gains `modified: i64`.

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

Adding a common attribute shifts every later common field and grows both fixed regions. Run the same census as the final Phase 1 fix (temporarily behind the `test-hooks` feature, not committed otherwise): count fixed-region sizes and object types over a full read-only scan of `/System/Volumes/Data`. Record the table in the commit message. Expected: exactly two sizes again, one for directories and one for everything else.

- [ ] **Step 4: Implement**

Request the attribute; parse it at its measured offset (byte copies, no `repr(C)` cast, as for FILEID); accept only the two newly measured region sizes; add the field through arena, freeze (max rollup) and node; recapture the golden buffers with `tests/golden_capture.rs` and update `.expect` files; regenerate the header with `scripts/gen-header.sh`; show the root's modified time in the CLI.

- [ ] **Step 5: Verify, then measure the cost**

Run: `just gate`, `scripts/parser-sanitizers.sh asan`, `scripts/parser-sanitizers.sh miri`, `scripts/fuzz-parser.sh 120`.
Expected: all pass. Then `tesserae-cli scan /System/Volumes/Data --workers 10` three times warm, median, vs the 21.8 s Phase 1 median: record both in `docs/benchmarks.md`. If the median slows by more than 10 %, stop and report rather than commit.

- [ ] **Step 6: Amend spec §6 (node struct, 48 bytes, memory figures 48–144 MB per 1–3M files) and §7 (ten attributes, the new layout sizes), then commit**

```bash
git commit -am "feat: per-node modification time (TessNode grows to 48 bytes)"
```

---

### Task 3: Xcode project and the first real link

Backlog "Do first": no Xcode/Swift link of the static library has been done; the archive embeds LLVM 23 bitcode that Apple's `nm` cannot read.

**Files:**
- Create: `scripts/build-ffi.sh`, `scripts/verify-ffi-fresh.sh`, `apple/Tesserae.xcodeproj`, `apple/Tesserae/{TesseraeApp.swift,ContentView.swift,Info.plist,Tesserae.entitlements}`, `apple/TesseraeKit/{TesseraeKit.h,FFI/module.modulemap,Version.swift}`, `apple/TesseraeKitTests/LinkTests.swift`
- Modify: `justfile` (recipes `ffi`, `app-test`, `app-build`; `gate` gains `app-test`), `.gitignore` (`apple/build/`, `xcuserdata/`), `.github/workflows/ci.yml` (a job running `just ffi && just app-test && just app-build`, the last an unsigned universal Release build, per spec §14), `crates/tesserae-core/tests/license_headers.rs`

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

`scripts/verify-ffi-fresh.sh` fails with "Rust library is older than its sources: run `just ffi`" when any `crates/**/*.rs` or `Cargo.lock` is newer than `apple/build/libtesserae.a`, or the `.a` is missing. Declare its input/output files so it works under `ENABLE_USER_SCRIPT_SANDBOXING`; it never builds.

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
      public let nodes: UnsafeBufferPointer<TessNode>
      public let names: UnsafeRawBufferPointer
      public let stats: TessScanStats
      public let stalledAt: Data?                 // raw path bytes, nil if absent
      init(handle: OpaquePointer)                  // takes ownership; deinit calls tess_snapshot_release
      public func name(_ i: UInt32) -> String      // lossy UTF-8, control characters replaced, never ""
      public func nameBytes(_ i: UInt32) -> Data
      public func children(_ i: UInt32) -> Range<UInt32>
      public func path(_ i: UInt32) -> String      // root name is the scan root as given (spec §6)
      public func isDirectory(_ i: UInt32) -> Bool
      #if DEBUG
      public var generation: UInt64 { get }        // asserted on access; release bumps a global counter
      #endif
  }
  ```

- [ ] **Step 1: Write the failing tests** (scan a temporary directory through the C ABI directly to obtain a real handle)

```swift
func test_counts_and_root_match_the_view()
func test_children_are_contiguous_and_sorted_by_allocated_descending()
func test_names_decode_lossily_and_never_empty()          // a non-UTF-8 name built with open(2) on bytes
func test_path_joins_from_the_root_as_given()
func test_buffers_survive_while_snapshot_is_retained()    // spec §12: a background task holds the Snapshot, the local ref is dropped, reads succeed
func test_access_after_release_traps_in_debug()           // spec §12: run in a child process (XCTest + posix_spawn of the test binary with a filter) and assert it crashed
```

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
  Progress is polled with `tess_scan_progress` at 10 Hz on the main actor; `tess_scan_finish` is called off the main actor only after `tess_scan_status` reports finished (it consumes the handle; nothing else touches the handle after that call). A new `start` cancels and waits out any scan in flight before beginning. A cancelled scan still delivers its partial snapshot (spec §7). Progress shows counts and a rate, never a percentage (spec §7).

- [ ] **Step 1: Failing tests**

```swift
func test_scan_of_a_temp_tree_finishes_with_matching_totals()
func test_progress_is_published_while_scanning()          // a tree big enough that at least one progress update arrives; assert it did
func test_cancel_returns_a_partial_snapshot_flagged_cancelled()
func test_missing_root_fails_with_enoent()
func test_restart_cancels_the_previous_scan_and_never_mixes_snapshots()
```

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
  }
  extension Snapshot: TreeSource {}
  public struct Tile: Equatable {
      public var rect: CGRect           // points
      public var node: UInt32           // TESS_NODE_NONE for an aggregate
      public var depth: UInt8
      public var flags: UInt8           // bit 0 selected, 1 staged, 2 permDenied, 3 aggregated (spec §8)
      public var aggregateCount: UInt32 // number of collapsed siblings, 0 otherwise
      public var aggregateBytes: UInt64
  }
  public struct LayoutParameters { public var subdivideMin: CGFloat = 24; public var cullArea: CGFloat = 16; public var budget = 50_000 }
  public func squarify(_ src: TreeSource, root: UInt32, in bounds: CGRect, _ p: LayoutParameters = .init()) -> [Tile]
  ```
  Bruls–Huizing–van Wijk over the pre-sorted children (no sorting at layout time). A child whose minimum dimension is below `subdivideMin` is a terminal tile (not recursed). The first child that would fall below `cullArea` starts the tail: `children[k...]` collapses into one aggregate tile ("N smaller items — X"). Stop emitting at `budget`. Output is in paint order (parents before children). A zero-size subtree emits nothing.

- [ ] **Step 1: Failing property tests** over `SyntheticTree` trees generated from a seeded `SplitMix64` (500 seeds each; print the seed on failure):

```swift
func test_rects_are_disjoint_among_siblings()
func test_rects_plus_aggregate_cover_the_parent_within_epsilon()     // epsilon 1e-6 of parent area
func test_area_is_proportional_to_size_within_tolerance()           // relative error ≤ 1e-3
func test_aspect_ratios_are_bounded()                               // worst ratio of emitted tiles ≤ 20 for non-aggregate tiles larger than subdivideMin
func test_tail_aggregate_is_a_contiguous_suffix()
func test_budget_is_respected()
func test_zero_size_root_yields_no_tiles_and_no_nan()
func test_huge_flat_directory_is_bounded_and_aggregate_is_exact()    // 500_000 children
func test_no_rect_is_nan_or_negative()
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
  ```
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

Note: spec §12 asks for the palette validator in CI. The validator is not part of this repository; pinning the validated values in a test meets the same goal (a nudge fails CI). Record this in spec §12 when committing.

---

### Task 8: Metal renderer

**Files:**
- Create: `apple/TesseraeKit/Render/{TreemapRenderer.swift,Shaders.metal,TreemapView.swift}`, `apple/TesseraeKitTests/MetalRendererTests.swift`

**Interfaces:**
- Consumes: `Tile` (Task 6), `Palette` (Task 7).
- Produces:
  ```swift
  public struct TileInstance { var rect: SIMD4<Float>; var colorIdx: UInt16; var depth: UInt8; var flags: UInt8 }  // spec §8, 20 bytes, matched by Shaders.metal
  public final class TreemapRenderer {                       // owns device, pipeline, 3 instance buffers + DispatchSemaphore(value: 3), storageModeShared
      public init?(device: MTLDevice)
      public func update(tiles: [Tile], colourOf: (Tile) -> UInt16, palette: [SIMD4<Float>])
      public func draw(in view: MTKView, alpha: Float = 1)
      public func renderOffscreen(size: CGSize, scale: CGFloat) -> CGImage   // for tests
  }
  public struct TreemapView: NSViewRepresentable                // hosts MTKView; falls back to Task 9's renderer when init? returns nil
  ```
  One instanced draw of a unit quad; the fragment shader fills from the palette buffer and draws a 1 px inner border from fragment distance to the rect edge (no second draw call). On `MTLBuffer` allocation failure, halve the instance budget and retry (spec §11).

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
- Produces: `public struct CGTreemapRenderer { public func render(tiles: [Tile], colours: [SIMD4<Float>], colourOf: (Tile) -> UInt16, size: CGSize, scale: CGFloat) -> CGImage }` — same fill and 1 px border as the shader; used when Metal is unavailable, with zoom animation disabled (spec §11).

- [ ] **Step 1: Failing tests** — deterministic reference images (spec §12: "snapshot-test the treemap through the CoreGraphics fallback"). Reference PNGs are recorded once with `TESSERAE_RECORD_SNAPSHOTS=1` and committed; comparison is exact on pixel bytes.

```swift
func test_fixed_tree_depth_mode_light_matches_reference()
func test_fixed_tree_depth_mode_dark_matches_reference()
func test_type_focus_and_permission_denied_tiles_match_reference()
func test_resize_to_zero_mid_animation_emits_no_nan()       // Review Focus 4: layout + both renderers at 0×0, 0.5×0.5, 1×1
```

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
  public struct HitTester { public mutating func tile(at p: CGPoint, in tiles: [Tile]) -> Int? }   // linear scan, deepest match, last-hit cache
  public struct InspectorInfo: Equatable { public var path: String; public var allocated, logical: UInt64; public var kind: String; public var modified: Date? }
  public func inspect(_ node: UInt32, in s: Snapshot) -> InspectorInfo
  ```

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
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Wire into `TreemapView`:** click a directory tile → animate (two instance buffers + alpha uniform, no per-frame relayout) → descend; Return descends into the hovered directory. Commit — `git commit -m "feat(kit): navigation, zoom animation, hit testing and inspector"`

---

### Task 11: Labels

**Files:**
- Create: `apple/TesseraeKit/Labels/{LabelPlacer.swift,LabelsOverlay.swift}`, `apple/TesseraeKitTests/LabelTests.swift`

**Interfaces:**
- Produces: `public func placeLabels(_ tiles: [Tile], in s: Snapshot, measure: (String) -> CGSize, max: Int = 400) -> [PlacedLabel]` where `PlacedLabel { rect: CGRect; text: String }` — name plus size, middle-truncated, emitted only where both fit inside the tile with 4 pt padding, largest tiles first, at most `max`. `LabelsOverlay` is a SwiftUI overlay of positioned `Text` in ink tokens, hidden while a `ZoomAnimation` runs and faded in (0.15 s) after it finishes (spec §8).

- [ ] **Step 1: Failing tests**

```swift
func test_labels_only_where_they_fit()
func test_labels_truncate_long_and_control_character_names()   // Review Focus 3
func test_at_most_max_labels_largest_first()
func test_aggregate_tile_label_reads_n_smaller_items()          // "12,345 smaller items — 4.2 GB"
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
      public init(snapshot: Snapshot, scope: UInt32)    // the current navigation root's subtree
      public func sorted(by: SortKey, ascending: Bool) async -> [UInt32]   // sorting happens off the main actor
  }
  public func topK(_ k: Int, files s: Snapshot, under root: UInt32) -> [UInt32]   // bounded min-heap, files only, by allocated
  public struct FileTableView: NSViewRepresentable    // NSTableView; columns Name, Allocated, Logical, Modified, Kind
  ```
  Default view lists the top 1,000 largest files under the current root; selecting a row highlights its tile (flag bit 0) and vice versa.

- [ ] **Step 1: Failing tests**

```swift
func test_sort_orders_indices_not_nodes_for_every_key()
func test_sort_is_stable_on_ties()
func test_top_k_matches_a_full_sort()                       // SplitMix64-generated trees, 200 seeds
func test_selection_round_trips_between_table_and_treemap()
func test_table_cells_have_voiceover_labels()               // spec §12
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): file table with off-main sorting, top-K and shared selection"`

---

### Task 13: App shell

**Files:**
- Modify: `apple/Tesserae/{TesseraeApp.swift,ContentView.swift}`
- Create: `apple/TesseraeKit/AppModel.swift`, `apple/TesseraeKit/ScanBanner.swift`, `apple/TesseraeKitTests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel: ObservableObject` composing `ScanCoordinator`, `Navigator`, `Selection`, colour mode and the current layout; `ScanBanner.text(for: TessScanStats, stalledAt: String?) -> String?` (nil when complete).
  Window: toolbar with "Scan Data Volume" (`/System/Volumes/Data`), "Scan Folder…" (`NSOpenPanel`), Cancel, and the colour-mode picker (type focus lets the user tick up to three `FileKind`s; the focus legend is always visible in that mode); a progress view (counts and entries/s, no percentage) while scanning; then a horizontal split of treemap and table with the breadcrumb above and an inspector pane (a trailing column, not the macOS 14 `.inspector` modifier); an incompleteness banner whenever `stats.incomplete != TESS_INCOMPLETE_NONE` or `errors`/`unreadable_count` > 0, so a partial result is never shown as complete (spec §1 success criterion 3). Light and dark mode follow the system.

- [ ] **Step 1: Failing tests**

```swift
func test_banner_text_for_every_incomplete_code()           // table-driven over all 8 codes, incl. stalled path and volume lost
func test_banner_mentions_unreadable_and_errors_when_complete()
func test_empty_scan_shows_empty_state()                     // Review Focus 1
func test_rescan_swaps_snapshot_atomically()                 // Review Focus 5: navigation, selection and hover reset in one main-actor transaction; no index from the old snapshot survives
func test_focus_legend_has_voiceover_labels()
```

- [ ] **Step 2–4:** fail, implement, pass, mutation-verify.
- [ ] **Step 5: Run the app.** `just app-build`, launch it, scan this repository and then `/System/Volumes/Data`; screenshot both colour schemes. Commit — `git commit -m "feat(app): scan, treemap and table window"`

---

### Task 14: Phase gate — fluid zoom on a million-node tree

Spec §17: "Fluid zoom on a million-node tree." Defined here as: on the development machine (Apple M5), with the `/System/Volumes/Data` snapshot (6.7M nodes) loaded, every frame of a zoom animation into and out of the five largest directories completes within the display's frame budget (16.7 ms at 60 Hz; 8.3 ms at 120 Hz if the display runs ProMotion), and relayout for each new root completes in under 100 ms.

**Files:**
- Create: `apple/TesseraeKit/Diagnostics/FrameTimer.swift` (signposts + per-frame durations, off in Release unless an environment variable enables it)
- Modify: `docs/benchmarks.md`, `docs/phase-2-backlog.md` (strike what Phase 2 closed), spec §13 (Phase 2 results line)

- [ ] **Step 1:** Add `FrameTimer`: `os_signpost` intervals for layout, encode and present; collects per-frame durations during an animation.
- [ ] **Step 2:** Run the app on the Data volume with `TESSERAE_FRAME_TIMING=1`, zoom in and out of the five largest directories, repeat three times.
- [ ] **Step 3:** Record in `docs/benchmarks.md`: display refresh rate, per-frame max and p99, relayout times, tile counts, commit. Expected: within the definition above. If not, stop and report the measurements — do not tune thresholds to pass.
- [ ] **Step 4: Commit** — `git commit -m "docs: Phase 2 frame-time gate on the Data volume"`

---

## Not in this plan

- **macOS 13/14 golden-buffer capture and the `O_NOFOLLOW_ANY` check on a 13.x kernel** need a machine or VM running those versions; they stay first in `docs/phase-2-backlog.md`.
- **Dataless (iCloud) directories** — the spec §16 decision needs a probe that evicts a folder in your iCloud Drive (`brctl evict`), which syncs through your iCloud account. It gets its own short task once you agree to that side effect.
- Reconciliation, scan report, FDA onboarding (Phase 3); Jetsam and deletion (Phase 4); signing, notarization, Sparkle (Phase 5).
