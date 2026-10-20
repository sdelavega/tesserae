# Phase 2 backlog — items deferred from Phase 1

Everything below was found during Phase 1 (task reviews, the final whole-branch
review, and the exit checks) and deliberately not fixed then. Each line says what
the item is and, where it matters, why it waited. Reconstructed from the execution
record after the scratch ledger was deleted; the decisions themselves are in the
rulings list kept outside the repo.

## Do first

- ~~**Link the static library from Xcode.**~~ Closed in Phase 2 Task 3;
  TesseraeKit tests and unsigned universal Release app builds link successfully.
- **Capture golden buffers on macOS 13 and 14.** The parser now accepts only the
  two fixed-region layouts measured on macOS 27.2 (68 bytes for directories, 88
  for everything else, across APFS, HFS+, exFAT and FAT32). On another macOS
  version, or over SMB/NFS, a different layout fails loudly as `MalformedBatch`
  with lost entries rather than producing wrong sizes. Also unmeasured: block and
  character devices, and a non-directory at 88 bytes with a zero file word (now
  refused).
- **Confirm `O_NOFOLLOW_ANY` on a macOS 13.x kernel.** It builds for the 13.0
  target (it is a flag bit, not a symbol), but whether the kernel honours it there
  is untested; the root-relative reopen of stolen directories depends on it.
- ~~**Run CI for the first time.**~~ Closed: rust, fuzz and apple jobs passed
  for `f33dd4a` on PR #2; the Apple runner is now `macos-26`.
- ~~**Split `walk.rs` as a pure move.**~~ Closed in Phase 2 Task 1; the lane,
  coordination, opening and error modules are now separate.
- **Decide how to treat dataless (iCloud "Optimize Mac Storage") items.** The Data
  volume census found 664,076 dataless regular files and no dataless directories.
  Enumerating a dataless directory may trigger downloads, slow the scan or trip the
  stall watchdog (inferred from the API, not measured). `ATTR_CMN_FLAGS` is already
  requested for this (`SF_DATALESS`) and for `UF_COMPRESSED`, but nothing reads it.

## Engine behaviour

- **Idle workers wake every 50 µs** (`pool.rs`), which costs roughly 0.5–1 core
  for the whole 15 s of every stall and at each scan's tail. Back off to ~1 ms, or
  park idle workers and unpark them on publish.
- **A returning stuck worker** makes `fstatfs`/`getattrlistbulk` calls on the dead
  volume before its first lock; check the halt right after `Lane::during` returns.
- **`guard` can write a slot it no longer owns** after abandonment (harmless,
  overwritten later); the doc claiming it "records nothing" is wrong.
- **The unreachable safeguard in the collector** (adds a taken arena's unpublished
  counts) should become `debug_assert_eq!(unpublished, ProgressValues::ZERO)`.
- **A hung root open is not covered by the watchdog** — it happens on the
  caller's thread before workers exist. The FFI's status polling is the
  mitigation; the root fd's own close is also unannounced.
- **`VolumeLost` detection is measured only for a force-detached disk image.** A
  pulled USB drive and a dropped network mount are unprobed; `ESTALE` (NFS) is not
  in the errno set that triggers the re-check. The cost of one `fstatfs` per failed
  directory under heavy churn is unmeasured.
- **A `getattrlistbulk` failure partway through a directory** counts only in
  `errors` (the spec's chosen taxonomy), so a scan that lost entries that way
  still reports complete. Revisit if it proves common (`ETIMEDOUT` was seen once
  cold).
- **A subtree skipped under `FdExhausted`** is flagged but not counted anywhere.
- **`open_root` follows symlinks in the scan root path** itself (arguably intended).
- **Worker-count default:** `clamp(cores, 4, 16)` is supported by the Data-volume
  sweep (2 → 50.2 s, 4 → 29.4 s, 10 → 21.8 s), but 16 workers and other core
  counts are unmeasured, and a sparse disk image showed the opposite trend.
- **`hardlink_dups` grew by 12,687** between two Data scans 1.5 h apart; plausibly
  cargo build hardlinks, not traced.

## Tests

- No parallel test asserts `skipped_mounts` paths inside a stolen subtree.
- Live-churn tests inject only at `open_dir_at`; the `getattrlistbulk` and reopen
  paths share `note_error` but have no churn test of their own.
- Busy-marking around close, `fstatfs` and `getattrlistbulk` is verified by reading
  only (the test opener intercepts only the opens).
- The `KEPT_TOO_LONG` precondition counter is process-global; a second long-path
  pool test would make it vacuous.
- Untested out-of-memory branches: `flag_foreign`'s reserve failure and the
  `fstatfs`/dup error wraps (covered only through the shared helper).
- Flake risks (loud, not vacuous): the cancel test's `nodes < whole` is
  timing-based; the cross-arena reopen test depends on scheduling; the
  detach-mid-scan race is probabilistic across three tree sizes; the 2.5 s stall
  threshold is machine-dependent.
- The disk-image `fill()` and the undisturbed-walk precondition sit outside the
  detach test's hang bound.
- `DiskImage` reclaim after a failed attach does not record whether the
  mountpoint was already a separate mount (all current callers pass fresh temp
  directories).

## C interface

- `Progress` counters are `pub AtomicU64`; expose getters only.
- The `test-hooks` feature can be unified into a release build by `--all-targets`
  or `cargo test --release`; revisit with the Xcode build phase (a `--cfg` set in
  test scripts cannot unify).
- The layout test compiles the header for the host architecture only; the app
  ships as a universal binary.
- `os_errno` unwraps one level of context only; iterate the `source()` chain.
- `with_context` is `pub` in core only so an FFI test can build the same error;
  narrow it (`#[doc(hidden)]` or behind `test-hooks`).
- `guarded` drops a panic payload inside the extern frame (a payload whose `Drop`
  panics would abort; theoretical).
- Housekeeping: split `tesserae-ffi/src/lib.rs` (~1,250 lines) into tests and ABI
  modules; `Default` impls instead of zero literals; cbindgen prints 7 warnings
  per run; the cbindgen version appears in three places.

## Tooling and CI

- `--locked` is missing from `cargo tree` (check-shipped-lib.sh), the `cargo deny`
  calls, and the justfile `bench` and `run` recipes; cargo-fuzz rejects it.
- ~~CI never builds the release profile or the Intel target.~~ Closed:
  the Apple job builds the unsigned universal Release app, and the shipped-library
  checks build the Rust release static library.
- `deny.toml`'s `confidence-threshold = 0.93` was never justified (default 0.8).
- `check-shipped-lib.sh` does a full release build into a fresh target directory
  on every run.
- `cargo doc` reports 26 warnings (mostly private intra-doc links).
- CLI: `print!` panics on a closed stdout (exit 101 with `| head`); no `--`
  separator for paths starting with `--`.
- `gen-bench-volume.sh` resolves a relative directory against the repo root.
- The 500k-file benchmark timings are bimodal (~4.2 s and ~5.4 s), cause unknown.

## Space reconciliation (spec §9)

- The Data volume's tree sits 57–77 GB under `df`'s used figure while agreeing
  with `du` to within churn. Candidates — local Time Machine snapshots, the 252
  protected paths, clones — are unmeasured.
- Purgeable space comes from a Foundation read that crosses the FFI boundary while
  the Rust core owns `purgeableEstimate`; the spec does not say how.
- The compressed-file finding rests on a single 5 MB test file.

## Phase 2 exit gate (2026-10-19)

- **Frame gate passed on a Release build.** On the 6.15M-node Data volume (no incomplete
  stop code, 1,006 unreadable folders) at 60 Hz, 0 of 414 presentation intervals spanned
  more than one refresh (maximum 16.668 ms) and relayout peaked at 1.2 ms. The earlier
  Debug `-O` captures failed (33–50 ms gaps); the Release build drops Snapshot's debug
  liveness lock, and label measurement now runs off the main actor. See
  `docs/benchmarks.md`, "Phase 2: Release frame gate — PASSED".
- Not yet measured: a 120 Hz (ProMotion) display, an Intel Mac, and hit testing in a
  Release build (the 0.08 ms figure is from a Debug `-O` build).
- An optimized ad-hoc Debug app can fail dyld library validation with the
  project's hardened runtime enabled. The measurements used a command-line-only
  `ENABLE_HARDENED_RUNTIME=NO` override. Resolve development/distribution signing
  deliberately; keep the shipped hardened-runtime setting enabled.

## Phase 2 → Phase 3 (deferred by the Phase 2 final review)

Everything the Phase 2 final whole-branch review deferred rather than fixed before
merge, one line each with the review's reason. (Its critical and important
findings C1, I1 and I2, and its doc batch, were fixed before merge.)

**Minor findings**

- **M1 — performance paths the frame gate never exercised.** The gate ran Depth mode
  only. Type focus calls `FileKind.kind(forName:)` per tile, allocating a `Data` and a
  `String` each time (about 15–20 ms per 50k lookups at `-O`), before the first zoom
  frame on every navigation and selection change, and the CG fallback recomputes
  `tiles.map(colourOf)` for its cache key on every SwiftUI update, hover included. Each
  hover republishes `AppSession.inspector`, re-evaluating `SessionView.body`: two full
  `filter`s over the tiles, three `[Tile]` comparisons and a palette allocation. Fix
  together: a per-node kind byte computed off the main actor, the inspector in its own
  `ObservableObject`, selected and denied tile lists precomputed when `tiles` is set,
  and Age, Type focus and hover-sweep runs added to the gate protocol.
- **M2 — the Age reference time is fixed at launch** (`AppModel.swift`,
  `ageReference = Date()`). After a day of uptime a rescan buckets ages against a stale
  "now" and anything newer lands in "future → most recent". Use the snapshot's scan
  start, or a `Date()` captured per session.
- **M3 — a hung root open blocks every later scan until relaunch**
  (`ScanCoordinator.start` awaits the previous task). A `finish` stuck in `open` on a
  dead SMB/NFS share never returns; Cancel abandons only the waiting scan, new scans
  chain behind it at zero counts, and the call holds a cooperative-pool thread. This
  is the UI half of the engine item "hung root open not covered by the watchdog".
- **M4 — duplicated logic.** `sizeText` in `ContentView.swift` duplicates
  `displaySize` without the locale injection. `Snapshot.name` (C0 only) and
  `Snapshot.displayName` (the label rules) are still two sanitisers; every display
  site now uses `displayName`, but the table's name sort still keys on `name`.
  (`aggregateLogical`'s copy of the tail rule went with the C1 fix.)
- **M5 — dead or vestigial code.** `Snapshot.generation` is public, Debug-only and
  unused outside tests. `TessNode`'s `AGGREGATED` bit is reserved and set by nothing
  (now documented so). `Tile.Flag.staged`, and `TileInstance.depth`/`.flags`, which the
  shader never reads, are reserved by the spec (`staged` is documented as reserved for
  Phase 3).
- **M6 — the FFI input stamp includes `crates/tesserae-testutil`**, which is not an
  input of the shipped library, so editing a test utility forces `just ffi`. Scope
  `ffi_inputs` to `tesserae-core`, `tesserae-ffi`, the manifests and the header.
- **M7 — CLI doc wording** (`crates/tesserae-cli/src/main.rs`): the root's `modified`
  is the newest *not later than the scan's start*, not "the newest anywhere beneath
  it" — the cutoff exists for the 2076-dated files.
- **M8 — a refused `tess_scan_begin` shows `strerror(EINVAL)`** ("Invalid argument")
  in the welcome view; "Couldn't start the scan" would be accurate.
- **M9 — `FileTableContent` is `@unchecked Sendable`** but could be plain `Sendable`
  (`Snapshot` is Sendable, and so is `[UInt32]`).

**Parked items deferred by the review's triage**

- `assemble_path` doc on '/'-terminated components (P1-2): behaviour is correct and
  tested; a one-line doc clarification.
- FAT symlink 1,536-byte rule measured on a 4-byte target only (P2-1): XSym is
  fixed-format and the doc argues the whole 1,025–1,536 range rounds the same; measure
  one 1,024-byte target to close it. FAT symlinks are rare.
- Bundle ID `io.github.sdelavega.*` is a placeholder: needs the user's decision before
  the first signing; does not block merge.
- The FFI stamp ignores `include_str!`/`include_bytes!` and `.cargo/config.toml`: the
  only includes are in benches, and there is no `.cargo/config.toml` or build.rs.
  Revisit if the shipped crates gain any.
- An unreadable folder under a zero-size directory gets no tile (P6-1): it is counted
  in the banner's unreadable total, so nothing is silent; the Phase 3 scan report lists
  it (spec §8 records the deferral).
- The placeholder-cap branch is untested (P6-2): reachable only with non-default
  parameters; a test with a custom `LayoutParameters` is cheap.
- `balancedSlivers` is printed, not asserted (P6-3): weakens one test, not behaviour.
- `typeFocus([])`, more than three kinds and duplicates are not asserted: correct by
  inspection (`prefix(3)`, `firstIndex`).
- `FileKind` lookup allocates per call: fix with M1.
- Border corner and fractional-coverage render cases are untested: CG and GPU agree
  byte for byte on the snapshot fixtures.
- Thread-safety of `TreemapRenderer.renderOffscreen` and `draw` is undocumented: mark
  the type `@MainActor` (or document it main-only); every caller already is.
- `Int()` of length/cell in the placeholder strip can trap at absurd bounds (about
  1e100 pt): unreachable from the UI; clamp as a `Double` when next touched.
- The `stripArea` test helper mirrors the implementation: add one hard-coded expected
  strip.
- The watchdog test's `elapsed < 2500 ms` is not retried: already a known flake risk.
- No layer-resize test: covered indirectly by the resize-cancels-zoom tests.
- Label overlay frame and offset are untested: verified visually in the gate runs; a
  view-hosting test would pin them.
- The table's `viewFor` constructs cells per call: 1,000 rows; reuse cells with
  `makeView(withIdentifier:)` later.
- Table column titles are not localised: for the localisation phase.
- `sawDirBiggerThanFile` scope in a table test: test hygiene.
- Label line height is a constant that matches AppKit only for the tested fonts: a
  test checks it across scripts; revisit for exotic fallback fonts.
- Labels flicker during live resize: visual only; hide them for the whole live resize
  and fade in after it ends.

**Found while fixing the review's findings**

- `Navigator.breadcrumb` (and its `parent` walk) has no parent-cycle bound, unlike
  `Snapshot`'s path builders, which now trap on a cycle. Only a malformed snapshot can
  have one; bound the loop by the node count when next touched.
