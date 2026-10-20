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
