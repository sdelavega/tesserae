# Handoff: Tesserae Phase 2, after Task 12 (2026-10-19)

You are picking up Phase 2 of Tesserae, a GPL-3 macOS disk-space visualiser: a
Rust scan engine behind a C ABI, with a SwiftUI/Metal app on top. Tasks 0–12 of
the Phase 2 plan are done and reviewed. **Tasks 13 and 14 remain**, then a final
whole-branch review and finishing the branch.

## Where things are

- **Repo:** `/Users/sdelavega/src/tesserae`, GitHub `sdelavega/tesserae` (private).
- **Branch:** `phase-2-treemap`, pushed. Head `d28c3b5`. Work on this branch;
  `main` has Phase 1 only.
- **PR:** draft [#2](https://github.com/sdelavega/tesserae/pull/2) against `main`.
  CI was green on all three jobs (`rust`, `fuzz`, `apple`, on `macos-26` with
  Xcode 26.6) as of the previous push. Confirm the run for `d28c3b5` passed before
  you start: `gh pr checks 2 --repo sdelavega/tesserae`.
- **Plan:** `docs/superpowers/plans/2026-10-19-tesserae-phase-2-treemap.md`. Read
  its Global Constraints, Review Focus, and the sections for Tasks 13 and 14.
- **Spec (binding authority):** `docs/superpowers/specs/2026-10-18-tesserae-design.md`,
  especially §8 (layout, rendering, interaction), §11 (degraded modes), §12 (testing).
- **Execution ledger:** `.superpowers/sdd/2026-10-19-tesserae-phase-2-treemap/progress.md`
  (git-ignored, local only). It records every ruling, binding and parked item with
  its reasoning. Per-task briefs, reports and reviews sit beside it. Read the
  ledger's last ~80 lines before starting.
- **Deferred Phase 1 work:** `docs/phase-2-backlog.md`.

## How the work has been run

Each task went: implement (TDD), then an independent review, then a fix round if
needed, then a scoped re-review or a mutation check. Hold the same bar:

- **TDD.** Write the failing test first and watch it fail.
- **Mutation-verify every new test.** Break the code it covers, see the test fail,
  restore. A test that can't fail is a defect.
- **Assert preconditions** so no test passes vacuously (for example "at least one
  aggregate tile occurred" before checking aggregates).
- **Never weaken an assertion to make a test pass.** Never rely on remembered macOS
  constants or behaviour: read the SDK header or probe.
- **Record each decision** in the ledger as
  `Ruling: <decision> — <why> — <cost if wrong>`.

## Practical rules

- **Toolchain.**
  - Use `PATH="$HOME/.cargo/bin:$PATH" RUSTUP_TOOLCHAIN=stable` for every cargo
    command. Homebrew's cargo shadows rustup's; `stable` is the same 1.99.1 build
    `rust-toolchain.toml` pins, and using it avoids a download.
  - `just` is installed: `just gate` runs CI's checks locally (Rust tests, the
    license, header and shipped-library checks, Xcode build and tests);
    `just app-test` runs the Xcode tests; `just ffi` rebuilds the universal Rust
    library.
- **Swift target.**
  - TesseraeKit targets **macOS 13** with Swift 6 language mode. Use
    `ObservableObject`/`@Published`, not `@Observable`, and no `.inspector`
    modifier. The test bundle targets macOS 14.
- **Project file.**
  - `apple/Tesserae.xcodeproj/project.pbxproj` is the source of truth; there is no
    `project.yml`.
  - Add files by hand-editing it: a PBXFileReference, a PBXBuildFile, a group entry
    and a Sources phase entry, each with a unique 24-hex ID.
- **License headers.**
  - Every new `.swift`, `.metal`, `.h`, `.modulemap` and `.sh` file needs the
    GPL-3 notice. Copy it from an existing file.
  - The copyright line is `Copyright (C) 2026 Stephen de la Vega`, with no
    "All rights reserved". A test enforces this.
- **Locale in tests.**
  - Tests that format numbers pin `Locale(identifier: "en_US")`; the app uses
    `.current`.
- **Commits and pushes.**
  - Commits go on `phase-2-treemap`.
  - The user approved pushing this branch so CI runs on the draft PR.
  - **Don't merge to `main`, mark the PR ready, or push anywhere else without
    asking the user.**
- **CI fixes.** The user's rule: apply CI fixes *between* tasks, never while other
  work is mid-edit in the checkout.
- **Side effects on the user's machine.**
  - Allowed: temporary disk images (always detached, check `hdiutil info`) and
    read-only scans of `/System/Volumes/Data`.
  - Not allowed: installing tools without asking, or sudo.

## Task 13: app shell (next)

Plan section "Task 13: App shell". These **bindings** come from earlier tasks and
must be honoured:

1. **Relayout on navigation.** When `Navigator.root` changes, re-run `squarify` for
   the new root and pass the new tiles to `TreemapView`. The zoom animation
   (`pendingZoom`) only plays when the new tiles are rooted at the clicked
   target.
2. **Labels.** Host `LabelsOverlay` over `TreemapView` with exactly the Metal view's
   frame and origin (top-left; the views are not flipped). The overlay's frame and
   offset are untested, so verify them visually.
3. **Selection.**
   - Keep one shared `Selection`.
   - Call `applySelection(&tiles, selection.nodes)` before handing tiles to the
     renderer.
   - Drive the table from `FileTableRows.content`, an atomic (snapshot, rows) value.
4. **Dropped tiles.** Show `TreemapRenderer.droppedTileCount` when it is above 0;
   the spec forbids silent under-reporting.
5. **Incompleteness banner.** Show a banner for every non-zero incomplete code (8
   codes including `TESS_INCOMPLETE_VOLUME_LOST`, with the stalled path where
   present), and whenever `errors` or `unreadable_count` is above 0.
6. **Rescan.** A rescan swaps everything atomically: navigation, selection, hover
   and the table reset in one main-actor transaction. Nothing may index the old
   snapshot.
7. **Inspector.**
   - Use `InspectorInfo.subject`/`kind`; `path` is nil for aggregate and
     unreadable tiles.
   - The inspector is a trailing column in the window, not the `.inspector`
     modifier.
8. **Progress.** While scanning, show counts and entries/second, never a
   percentage.
9. **Final step.** Launch the app (`just app-build`), scan this repo and then
   `/System/Volumes/Data`, and take screenshots in light and dark mode.

## Task 14: phase gate (after 13)

**Pass bar:** with the Data-volume snapshot loaded, every zoom frame must fit the
display's frame budget, and each relayout must take under 100 ms.

- Add `FrameTimer`, which records signposts and per-frame durations.
- Zoom in and out of the five largest directories three times.
- Record the display refresh rate, per-frame max and p99, relayout times and tile
  counts in `docs/benchmarks.md`.
- **If the gate isn't met, stop and report the numbers; don't tune thresholds to
  pass.**

## After Task 14

1. **Final whole-branch review** of `main..phase-2-treemap`, on the most capable
   model. Triage every PARKED item in the ledger: fix before merge, defer to the
   backlog, or drop. The notable parked items:
   - FAT symlink allocation measured for a 4-byte target only;
   - `SquarifiedLayout.swift` ~line 134 can trap with absurd bounds (clamp as a
     Double before converting to Int);
   - no explicit pixel assertion that a real 4×4 placeholder renders;
   - the 50 µs idle sleep in the Rust pool during stalls;
   - an unreadable folder nested under a zero-size directory gets no tile;
   - table sorting covers only the top 1,000 files;
   - cells are built on every `viewFor`.
2. **Reconcile the plan and spec** with what was built. The ledger lists rulings
   that changed the plan: T6-1 aspect property, T6-2/T6-3 placeholder squares,
   T11-1 `Tile.parent`, and others.
3. **Finish the branch.** Ask the user before marking PR #2 ready or merging.

## Open questions for the user

- The app's bundle ID is a placeholder, `io.github.sdelavega.*`. Confirm it before
  signing (Phase 5).
