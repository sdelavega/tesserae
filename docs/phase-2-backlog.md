# Phase 2 backlog — items deferred from Phase 1

Everything below was found during Phase 1 (task reviews, the final whole-branch
review, and the exit checks) and deliberately not fixed then. Each line says what
the item is and, where it matters, why it waited. Reconstructed from the execution
record after the scratch ledger was deleted; the decisions themselves are in the
rulings list kept outside the repo.

## Post-0.1.0

- **Include system volume.** Add an explicit opt-in scan of the sealed system
  volume alongside the startup disk's Data volume. For 0.1.0, Scan Macintosh HD
  and selecting the boot volume in the folder picker scan `/System/Volumes/Data`;
  scanning `/` as "include system volume" is deferred.

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
- ~~**Decide how to treat dataless (iCloud "Optimize Mac Storage") items.**~~
  Done in Phase 3: read `SF_DATALESS`, flag and count cloud-only files/directories,
  and never enter a dataless directory (including a selected root). Set the
  thread-scoped no-materialize policy and report any failure. The measured census
  found 664,076 dataless regular files and no dataless directories; real dataless
  directory behaviour remains unmeasured (spec §16).

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

- **M1 — performance paths the frame gate never exercised. Done in Phase 3**
  (`310e023`): cache snapshot kinds, isolate hover observation, cache selected
  and denied tile lists and fallback colours, and extend the protocol with Age,
  Type focus and hover sweeps. The rerun found no Phase 3 regression versus
  control; neither build meets the unchanged zero-gap bar today (Ruling T11-G1;
  see `docs/benchmarks.md`).
- **M2 — the Age reference time is fixed at launch. Done in Phase 3**
  (`49400d5`): Age mode now uses the engine's scan start.
- **M3 — a hung root open blocks every later scan until relaunch. Done in Phase 3**
  (`44b8bf0`): bound scan-restart waits after cancellation so a hung prior
  scan does not block a new one.
- **M4 — duplicated logic. Done in Phase 3** (`fcee206`): use shared size
  formatting and display-name sorting.
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
- **M8 — a refused `tess_scan_begin` shows `strerror(EINVAL)`. Done in Phase 3**
  (`8ddbf5f`): explain refused scan starts plainly.
- **M9 — `FileTableContent` is `@unchecked Sendable`** but could be plain `Sendable`
  (`Snapshot` is Sendable, and so is `[UInt32]`).

**Parked items deferred by the review's triage**

- `assemble_path` doc on '/'-terminated components (P1-2): behaviour is correct and
  tested; a one-line doc clarification.
- FAT symlink 1,536-byte rule measured on a 4-byte target only (P2-1): XSym is
  fixed-format and the doc argues the whole 1,025–1,536 range rounds the same; measure
  one 1,024-byte target to close it. FAT symlinks are rare.
- Bundle ID placeholder question **decided by the user on 2026-10-20**:
  app `com.sdelavega.Tesserae`, framework `com.sdelavega.TesseraeKit`,
  test bundle `com.sdelavega.TesseraeKitTests`.
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

**Resolved after the review**

- ~~**I3 — label ink unreadable on the darker ramp steps.**~~ Resolved: the user
  chose per-tile ink. Each label (and the unreadable-folder lock badge) uses
  whichever of `#0b0b0b` and `#f0efec` has the higher WCAG 2.x contrast against
  its tile's actual fill, in every mode and appearance (spec §8 "Labels"). The
  worst case over every shipped colour was 4.46:1 on `#2a78d6` (light depth
  step 3 and light type-focus slot 1), just under the 4.5:1 AA text threshold.
  ~~That blue~~ is resolved too: the user chose to darken it. It is now `#256bc0`
  (4.63:1 with `#f0efec`), with light depth steps 4–5 moved to `#184f95` and
  `#0d366b` to keep the ramp's adjacent ΔL ≥ 0.06 (revalidated; spec §8
  Colour). Every label now clears 4.5:1; a test asserts that and pins the
  4.63 minimum on `#256bc0`.
- ~~**Watchdog test's wall-clock bound.**~~ `watchdog_names_a_blocked_reopen_across_arenas`
  now asserts the ordering it means (the walk returned before the blocked
  reopen's sleep ended, read from a flag the hook sets after its sleep)
  instead of `elapsed < 2500 ms`, which failed once at 2.58 s. The sibling
  `watchdog_reports_the_path_a_worker_stalled_on` still carries the same
  `elapsed < 2500 ms` bound (alongside its ordering check) and could flake the
  same way.

**Found while fixing the review's findings**

- `Navigator.breadcrumb` (and its `parent` walk) has no parent-cycle bound, unlike
  `Snapshot`'s path builders, which now trap on a cycle. Only a malformed snapshot can
  have one; bound the loop by the node count when next touched.
