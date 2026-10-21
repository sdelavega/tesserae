# Tesserae Phase 4: Jetsam and Deletion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The user stages files and folders in Jetsam, reviews every warning, and moves them to the Trash. Every guard is re-checked at the moment of the move, nothing is ever deleted permanently, and every action is logged and can be put back.

**Architecture:** Rust gains one thing: each node's file ID and the scan root's device, so Swift can re-verify identity (spec §10 compares against "the snapshot's record"). Everything else is Swift (invariant 1, "Rust never deletes"):
- a pure two-layer guard (policy paths plus `st_flags`);
- a pure identity check (TOCTOU);
- a staging model with ancestry dedup;
- a serial trash executor behind a seam;
- an append-only JSONL audit log that powers Put Back;
- a size overlay the layout and table consult instead of mutating the snapshot (spec §6.3).

**Tech Stack:** Rust 1.99.1 engine + C ABI (existing); Swift 6 / SwiftUI + AppKit, macOS 13 deployment; XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md`. The sections this plan draws on:
- §10, Jetsam and deletion safety: the whole phase.
- §6.3, the overlay.
- §8, the staged tile flag, and inspector actions that act only on a real node.
- §11, "disk full while logging".
- §12, the guard-list, TOCTOU, ancestry and overlay tests, and the deletion-test containment.
- §16's deletion risk row.
- §17's Phase 4 gate: "Full guard-list and TOCTOU test suites green".

## Global Constraints

- **Earlier phases' constraints still hold:**
  - Everything in the Phase 2 and Phase 3 plans' Global Constraints.
  - macOS 13 APIs only in TesseraeKit.
  - `ObservableObject`, not `@Observable`.
  - The GPL notice on every new file, with `Copyright (C) 2026 Stephen de la Vega`.
  - `project.pbxproj` is hand-edited.
  - Tests pin `Locale(identifier: "en_US")`.
  - TDD, with every test mutation-verified; never weaken an assertion.
  - Read SDK headers; never recall macOS constants.
- **The four invariants (spec §10), verbatim:**
  1. Rust never deletes.
  2. Trash-first, always: no permanent delete, no secure erase.
  3. Nothing happens at selection time: Jetsam is a staging set.
  4. Every guard is re-evaluated at execution time.
- **The only destructive call is `FileManager.trashItem(at:resultingItemURL:)`:**
  - It is called from exactly one place, the executor's production `Trasher`.
  - No `removeItem`, `unlink`, `rmdir` or `tmutil` call appears anywhere in the app target or TesseraeKit, outside tests.
  - A test asserts this by scanning the sources.
- **No silent fallback:** when `trashItem` fails (for example on a volume with no usable `.Trashes`), the item is reported as failed and nothing destructive is tried instead.
- **The Trash is never emptied by the app.** The result screen offers **Open Trash**, which shows Finder's Trash, and nothing else.
- **Staged verdicts are hints; execution verdicts decide.**
- **Never silent under-reporting:** an item of unknown size (unreadable, cloud-only, skipped) counts as "unknown", never 0, in every total.
- **Deletion tests are contained** (spec §12):
  - Every path handed to the real `trashItem` in a test passes through an independent containment check, which asserts the path lies under that test's fixture root.
  - Fixtures live on a temporary disk image the test attaches and always detaches, because `$TMPDIR` sits under `/private/var/folders`, which the policy denies.
  - Tests never touch the user's real files or the user's volumes, and never use `/Volumes/hdd-raid-0`, `/Volumes/ISOs` or `/Volumes/USB321FD`, except in Task 9's explicitly named manual checks.
- **Commits stay clean:** never `git add -f` anything under `.superpowers/` or `apple/build/`, and never write absolute home paths into tracked files. `just no-home-paths` enforces the second.
- **CI is not available;** `just gate` is the check.

## Review Focus

1. **A path on the Data volume** (`/System/Volumes/Data/Users/…`). Expected: judged as its firmlinked path (`/Users/…`), so the `/System` rule doesn't deny everything on the Data volume, and `/System/Volumes/Data/private/var/db` is still denied. Test: Task 2 `data_volume_paths_are_judged_by_their_firmlinked_path`.
2. **A cloud-only (dataless) item.** Expected: a warning that trashing removes it from iCloud on every device and frees no space on this Mac. It is never presented as reclaimable bytes. Test: Task 2 `cloud_only_item_warns_and_frees_nothing`.
3. **A file with other hard links.** Expected: a warning that its space is freed only when every link is gone; the reclaim total doesn't count it. Tests: Task 2 `other_hard_links_warn`; Task 5 `extra_hard_links_warn_and_count_nothing_reclaimed` (a confirmed hard-linked file is trashed but excluded from `reclaimableBytes`).
4. **Something already in a Trash** (`~/.Trash`, a volume's `.Trashes`). Expected: denied, with "Already in the Trash — empty it from Finder". Test: Task 2 `items_in_a_trash_are_denied`.
5. **The volume disappears mid-batch** (USB pulled). Expected: each remaining item fails with its reason, the batch finishes, nothing crashes, and the log records every outcome. Test: Task 5 `volume_lost_mid_batch_fails_each_remaining_item`.

---

### Task 1: Per-node file identity in the snapshot

**Files:**
- Modify: `crates/tesserae-core/src/{walk/*,freeze.rs,node.rs}`, `crates/tesserae-ffi/src/lib.rs`, header (regenerate), `crates/tesserae-ffi/tests/abi_layout.rs`, `apple/TesseraeKit/Snapshot.swift`.
- Tests: Rust walk/freeze/FFI tests; `apple/TesseraeKitTests/SnapshotIdentityTests.swift`.

**Interfaces — Produces:**
```c
// Device of the scan root (st_dev), recorded once at scan start.
// In TessScanStats, appended at the end.
int32_t root_device;
// File ID (ATTR_CMN_FILEID / st_ino) of a node, from a side array parallel to the nodes.
// Returns false, with *out zeroed, for a bad snapshot or index, or when the
// volume returned no file ID (0).
bool tess_snapshot_file_id(const TessSnapshot *snapshot, uint32_t index, uint64_t *out);
```
```swift
extension Snapshot {
    public var rootDevice: Int32 { get }
    public func fileID(_ i: UInt32) -> UInt64?   // nil when the engine has none
}
```

- [ ] **Step 1: Failing tests.**
  - Rust:
    - `file_ids_match_lstat_for_every_node` on a temp tree: a file, a directory, a symlink and a hardlink pair, where both links carry the same ID.
    - `file_ids_survive_freeze_reordering`: IDs follow their nodes through the sibling sort.
    - FFI: out-of-range, null and zero-ID cases return false with `*out == 0`.
  - Swift: `fileID` and `rootDevice` agree with `lstat` on a temp tree scanned through the FFI.
- [ ] **Step 2: Implement.**
  - Keep `TessNode` at 48 bytes. Do not change it.
  - Carry the parsed FILEID into a `Vec<u64>` side array that the freeze permutes with the nodes.
  - Record `root_device` from the root's `fstat`.
  - Update the clang layout test.
  - No ABI version bump: ABI 1 is unshipped.
- [ ] **Step 3: Measure** peak RSS of `tesserae-cli scan /System/Volumes/Data` before and after. Expected cost: about 8 bytes per node, around 55 MB at 6.8M nodes. Record the numbers in `docs/benchmarks.md` and update spec §6's memory sentence.
- [ ] **Step 4:** `just ffi`; `just gate`; commit `feat(core): record each node's file identity`.

### Task 2: The guard (policy and physics layers)

**Files:**
- Create: `apple/TesseraeKit/Jetsam/Guard.swift`.
- Test: `apple/TesseraeKitTests/GuardTests.swift`.

**Interfaces — Produces:**
```swift
public enum Reason: Equatable, Sendable {
    case osIntegrity, systemState, appTemporaryFiles, systemManaged, timeMachineBackup,
         volumeRootOrTopLevel, otherVolume, selfOrAncestorOfApp, alreadyInTrash,
         restricted /* SF_RESTRICTED */, immutable /* UF_/SF_IMMUTABLE */,
         symlinkInPath, appContainer, cloudOnly, otherHardLinks
}
public enum Verdict: Equatable, Sendable { case ok, warn(Reason), denied(Reason) }
public struct GuardContext: Sendable {
    public let scanRoot: Data         // raw path bytes
    public let scanRootDevice: Int32
    public let appBundle: URL         // Bundle.main.bundleURL, resolved
    public let home: Data             // the user's home, raw bytes
}
public struct Observed: Equatable, Sendable { public let device: Int32; public let flags: UInt32; public let isDirectory: Bool; public let linkCount: UInt16 }
// cloud-only = flags & SF_DATALESS (read from <sys/stat.h>); no separate field
public func policyVerdict(_ rawPath: Data, _ ctx: GuardContext) -> Verdict
public func physicsVerdict(_ o: Observed, _ ctx: GuardContext) -> Verdict
public func combinedVerdict(_ rawPath: Data, _ o: Observed, _ ctx: GuardContext) -> Verdict  // denied wins over warn, warn over ok
```

**Policy rules.** The table is spec §10's, verbatim:

| Denied | Reason |
|---|---|
| `/System`, `/bin`, `/sbin`, `/Library/Apple`, and `/usr` except `/usr/local` | `osIntegrity` |
| `/private/var/db`, `/cores`, `/private/var/vm` | `systemState` |
| `/private/var/folders` | `appTemporaryFiles` |
| any `.Trashes`, `.Spotlight-V100` or `.fseventsd` component | `systemManaged` |
| any `Backups.backupdb` component | `timeMachineBackup` |
| the scan's volume root and its first-level children | `volumeRootOrTopLevel` |
| a different device than the scan root | `otherVolume` |
| the running app bundle or any ancestor | `selfOrAncestorOfApp` |

Three more rules complete the guard:

| Rule | Verdict |
|---|---|
| Anything under `~/.Trash`, or with a `.Trashes` component | denied `alreadyInTrash` (Review Focus 4), checked before `systemManaged` |
| `~/Library/Containers/*` and `~/Library/Group Containers/*` | warn `appContainer` |
| `flags & SF_DATALESS` | warn `cloudOnly` (Review Focus 2) |
| `linkCount > 1` on a file | warn `otherHardLinks` (Review Focus 3) |

**How paths are matched:**
- Compare **component-wise on raw bytes**, so `/usrlocal` matches no rule.
- Fold ASCII case for the fixed system prefixes. APFS is case-insensitive by default, and folding only ever denies more.
- **Data-volume normalisation (Review Focus 1):** before matching, a path under `/System/Volumes/Data/` is judged as the path with that prefix removed. The volume-root rule then applies to `/System/Volumes/Data` and its children.

**Physics:** `flags & SF_RESTRICTED` gives denied `restricted`; `UF_IMMUTABLE | SF_IMMUTABLE` gives denied `immutable`. Read all three values from `<sys/stat.h>`.

- [ ] **Step 1: Table-driven failing tests**, spec §12 order:
  - every denied prefix;
  - `/usr/local/x` ok while `/usr/x` denied;
  - volume root denied, and its first-level child denied;
  - app-bundle ancestor denied;
  - containers warn rather than deny;
  - `data_volume_paths_are_judged_by_their_firmlinked_path`;
  - `cloud_only_item_warns_and_frees_nothing`;
  - `items_in_a_trash_are_denied`;
  - `other_hard_links_warn`;
  - `component_matching_not_string_prefix`;
  - case-folded system prefixes denied;
  - other-device denied;
  - each physics flag denied;
  - denied beats warn in `combinedVerdict`.
- [ ] **Step 2: Implement; pass; mutation-verify.** Each rule's test must fail when that rule is removed.
- [ ] **Step 3:** commit `feat(kit): two-layer deletion guard`.

### Task 3: Identity re-verification (TOCTOU)

**Files:**
- Create: `apple/TesseraeKit/Jetsam/Identity.swift`.
- Test: `apple/TesseraeKitTests/IdentityTests.swift`.

**Interfaces — Produces:**
```swift
public struct Recorded: Equatable, Sendable { public let fileID: UInt64; public let device: Int32; public let isDirectory: Bool }
public enum IdentityResult: Equatable, Sendable { case same, gone, inodeChanged, deviceChanged, nowSymlink, typeChanged, symlinkInPath(Data) }
public enum StatResult: Equatable, Sendable { case ok(Observed, fileID: UInt64, isSymlink: Bool), error(errno: Int32) }
public protocol FileStat: Sendable { func lstat(_ rawPath: Data) -> StatResult }
public func verifyIdentity(_ rawPath: Data, _ r: Recorded, stat: FileStat) -> IdentityResult
public func symlinkedAncestor(_ rawPath: Data, stat: FileStat) -> Data?            // lstat every component from "/" down
```

- [ ] **Step 1: Failing tests, pure over (recorded, observed)** with a fake `FileStat`:
  - same;
  - inode changed;
  - device changed;
  - now a symlink;
  - gone (`ENOENT`);
  - type changed;
  - a symlink at any ancestor depth, including the scan root's own path.
- [ ] **Step 2: Production `FileStat`.**
  - Implement it with `lstat` and `fstatat(AT_FDCWD, …, AT_SYMLINK_NOFOLLOW)`.
  - Read the constants from the SDK.
  - Add one real-filesystem test on a temp tree. It reads only, so `$TMPDIR` is fine.
- [ ] **Step 3: Implement; pass; mutation-verify; commit** `feat(kit): verify identity before acting`.

### Task 4: Jetsam staging

**Files:**
- Create: `apple/TesseraeKit/Jetsam/Jetsam.swift`.
- Modify: `apple/TesseraeKit/AppModel.swift`, `apple/TesseraeKit/Layout/Tile.swift` (set `Tile.Flag.staged`).
- Test: `apple/TesseraeKitTests/JetsamTests.swift`.

**Interfaces — Produces:**
```swift
public struct JetsamItem: Equatable, Identifiable, Sendable {   // spec §10's fields, regrouped: inode, device and isDirectory live in `recorded`
    public let nodeIndex: UInt32; public let path: Data; public let recorded: Recorded
    public let recordedSize: UInt64?   // nil = unknown (unreadable, cloud-only, skipped)
    public var verdict: Verdict
}
@MainActor public final class Jetsam: ObservableObject {
    @Published public private(set) var items: [JetsamItem]
    public func stage(_ nodes: [UInt32], in snapshot: Snapshot, context: GuardContext, stat: FileStat)
    public func unstage(_ nodes: Set<UInt32>)
    public func clear()
    public var knownBytes: UInt64 { get }      // sum of non-nil sizes of non-denied items
    public var unknownSizeCount: Int { get }
    public var stagedNodes: Set<UInt32> { get }
}
```
- [ ] **Step 1: Failing tests.**
  - Staging a directory stages one item.
  - **Ancestry dedup property test** (SplitMix64, 500 seeds): no staged set ever holds both an ancestor and its descendant. Staging an ancestor drops its staged descendants; staging a descendant of a staged item is a no-op.
  - Totals never count an item twice.
  - An unknown-size item counts in `unknownSizeCount`, never as 0 bytes.
  - Denied items stay listed with their reason but count in no total.
  - Nodes without a file path can't be staged: aggregates, placeholders, the unreadable-folders collapse (spec §8).
  - A rescan clears Jetsam, because indices belong to a snapshot.
- [ ] **Step 2: Implement.**
  - Staging reads each item's path through `Snapshot.rawPath`, and its identity through `fileID` and `rootDevice` (Task 1).
  - It computes a staged verdict with Tasks 2 and 3.
  - Nothing touches the filesystem except `lstat` (invariant 3).
  - `AppModel` gains `stageSelection()` and the staged flag on tiles.
- [ ] **Step 3: Pass; mutation-verify; commit** `feat(kit): Jetsam staging with ancestry dedup`.

### Task 5: Trash execution with test containment

**Files:**
- Create: `apple/TesseraeKit/Jetsam/Executor.swift`.
- Create test support: `apple/TesseraeKitTests/Support/DiskImageFixture.swift`, `apple/TesseraeKitTests/Support/ContainedTrasher.swift`.
- Test: `apple/TesseraeKitTests/ExecutorTests.swift`.

**Interfaces — Produces:**
```swift
public protocol Trasher: Sendable { func trash(_ url: URL) throws -> URL }   // production: FileManager.trashItem(at:resultingItemURL:)
public enum Outcome: Equatable, Sendable { case trashed(trashURL: URL), skipped(Reason), notConfirmed(Reason), identityChanged(IdentityResult), failed(errno: Int32, message: String) }
public struct ExecutionResult: Sendable { public let outcomes: [(JetsamItem, Outcome)]; public let reclaimableBytes: UInt64; public let unknownSizeTrashed: Int }
public actor Executor {   // one serial executor
    public init(trasher: Trasher, stat: FileStat, log: JettisonLog, context: GuardContext)
    public func run(_ items: [JetsamItem], confirmedWarnings: Set<UInt32>) async -> ExecutionResult
}
```

**Per item, in order** (spec §10):
1. Verify identity (Task 3).
2. Re-run both guard layers on the path (Task 2).
3. A `warn` item proceeds only if its node is in `confirmedWarnings`.
4. Call `trash`, then record the returned URL.
5. Append the outcome to the log.

One failure never aborts the batch.

**Reclaimable bytes** cover only the sizes of trashed items: not `otherHardLinks`, not `cloudOnly`, and not unknown sizes, which are counted separately.

- [ ] **Step 1: Test support first.**
  - `DiskImageFixture` creates a small APFS sparse image with `hdiutil` and attaches it with `-nobrowse`.
  - It returns the mount point, and always detaches in `tearDown`, even after a failure.
  - It builds trees at depth 2 or more below the image root, because depth 1 is denied by the volume-root rule.
  - `ContainedTrasher` wraps the real trasher and fails the test **before** calling `trashItem` on any path outside the fixture root (spec §12).
  - A test proves the containment check refuses an outside path without trashing anything.
- [ ] **Step 2: Failing tests.** Fakes for pure ordering; the disk image for the real thing:
  - happy path, where the item lands in the image's `.Trashes`;
  - identity changed between staging and execution (replace the file) → skipped;
  - guard newly denying at execution → skipped;
  - an unconfirmed warn → `notConfirmed`;
  - one failing item mid-batch, with the rest still executed;
  - `volume_lost_mid_batch_fails_each_remaining_item`: detach the image after the first item;
  - `extra_hard_links_warn_and_count_nothing_reclaimed`;
  - trasher errors surface as `failed` with no fallback;
  - a source-scan test that no `removeItem`, `unlink`, `rmdir` or `tmutil` exists outside tests.
- [ ] **Step 3: Implement; pass; mutation-verify; commit** `feat(kit): serial trash executor`.

### Task 6: Audit log and Put Back

**Files:**
- Create: `apple/TesseraeKit/Jetsam/JettisonLog.swift`, `apple/TesseraeKit/Jetsam/PutBack.swift`.
- Test: `apple/TesseraeKitTests/JettisonLogTests.swift`, `PutBackTests.swift`.

**Interfaces — Produces:**
```swift
public struct LogEntry: Codable, Equatable, Sendable { public let ts: Date; public let action: String /* "trash" | "putBack" */; public let path: String; public let inode: UInt64; public let bytes: UInt64?; public let trashURL: String?; public let result: String }
public final class JettisonLog: @unchecked Sendable {
    public init(directory: URL, maxBytes: Int = 5 * 1024 * 1024, keep: Int = 3)
    public func append(_ e: LogEntry) -> Bool            // best-effort, never throws, never blocks a deletion (spec §11)
    public var lastWriteFailed: Bool { get }             // surfaced in the UI
    public func entries() -> [LogEntry]                  // current and rotated files, oldest first
}
public enum PutBackResult: Equatable, Sendable { case restored, trashItemGone, trashItemChanged, originalOccupied, parentMissing, failed(String) }
public protocol Mover: Sendable { func move(_ from: URL, to: URL) throws }   // production: FileManager.moveItem (a rename)
public func putBack(_ e: LogEntry, stat: FileStat, mover: Mover) -> PutBackResult
```
- **Format:** one JSON object per line. The shape is spec §10's example: ISO-8601 UTC `ts`, and paths as UTF-8 where valid, otherwise base64 under `pathB64`.
- **Location:** production directory `~/Library/Application Support/Tesserae/`, file `jettison.log`. Rotation renames it to `jettison.log.1` … `.3`.
- **Put Back** restores an item only when all of these hold:
  - the trash item exists, and its file ID equals the logged inode (a same-volume move to Trash is a rename, which keeps the inode);
  - the original path is free;
  - its parent exists.

  It then moves the item with `FileManager.moveItem`, which is a rename, never a copy and delete, and logs `putBack`.

- [ ] **Step 1: Failing tests.**
  - The line format round-trips, including non-UTF-8 names.
  - Rotation at `maxBytes` keeps exactly `keep` files.
  - Entries come back across rotation.
  - A log write failure (read-only directory) returns false, sets `lastWriteFailed`, and the executor still trashes the item.
  - Put Back tests on the disk-image fixture, one per `PutBackResult` case.
  - The executor writes one entry per outcome.
- [ ] **Step 2: Implement; pass; mutation-verify; commit** `feat(kit): jettison log and Put Back`.

### Task 7: The size overlay

**Files:**
- Create: `apple/TesseraeKit/Jetsam/SizeOverlay.swift`.
- Modify: `apple/TesseraeKit/Layout/TreeSource.swift`, `SquarifiedLayout.swift` (to consume the new children type), the table's row source, `AppModel.swift`.
- Test: `apple/TesseraeKitTests/SizeOverlayTests.swift`.

**Interfaces — Produces:**
```swift
public struct SizeOverlay: Sendable {   // spec §6.3: deltas plus a deleted-node set; the snapshot is never mutated
    public private(set) var deltas: [UInt32: Int64]
    public private(set) var deleted: Set<UInt32>
    public mutating func remove(_ node: UInt32, in s: Snapshot)   // propagates -allocated up the parent chain
    public mutating func restore(_ node: UInt32, in s: Snapshot)  // Put Back
    public func needsRescan(rootAllocated: UInt64) -> Bool        // > 10_000 entries or |root delta| > 10% (spec §6.3)
}
public struct ChildList: RandomAccessCollection { /* either a Range<UInt32> fast path or a re-sorted [UInt32] */ }
// TreeSource.children(_:) returns ChildList instead of Range<UInt32>.
public struct OverlaySource: TreeSource { public init(_ s: Snapshot, _ o: SizeOverlay) }
```
**Overlay rules:**
- `OverlaySource` hides deleted nodes and applies deltas.
- It re-sorts children by adjusted size **only for parents with a delta**. Every other parent keeps the range fast path, so the layout still never sorts unaffected siblings.
- The table excludes deleted nodes.
- Wiring: `AppModel` holds the overlay with the session. After `Executor.run`, it calls `remove` for every `.trashed` outcome (spec §10 execution step 4); a successful Put Back calls `restore`. Both happen in one main-actor transaction, so layout, table and totals change together. A rescan resets the overlay.

- [ ] **Step 1: Failing tests.**
  - Spec §12 "overlay arithmetic": removing a leaf reduces every ancestor by exactly its size and no one else, as a property test over random trees.
  - Restore is the exact inverse.
  - Children stay sorted by adjusted size.
  - The fast path is used for untouched parents.
  - The existing layout property tests still pass through `OverlaySource` with an empty overlay.
  - The `needsRescan` thresholds trigger at exactly 10,001 entries and just over 10%.
- [ ] **Step 2: Implement; pass; mutation-verify.** Re-run the Phase 2 layout and frame-gate-relevant unit tests. Commit `feat(kit): size overlay for trashed items`.

### Task 8: The Jetsam UI

**Files:**
- Create: `apple/Tesserae/JetsamView.swift`, `ConfirmTrashSheet.swift`, `TrashSummaryView.swift`.
- Modify: `ContentView.swift`, the renderers (draw staged tiles), `apple/TesseraeKitTests/DegradedModeTests.swift` (or a new `JetsamSnapshotTests.swift`).

**What to build:**
- **Staging:**
  - The **Add to Jetsam** command is ⌘⌫, with a context-menu item on table rows and treemap tiles and a button in the inspector. It stages the selection and does nothing else (invariant 3).
  - **Remove from Jetsam** undoes it.
- **Staged tiles** get a diagonal hatch plus outline in both the Metal and CoreGraphics renderers, a non-colour cue that works in light and dark. Extend the Metal/CoreGraphics cross-check test.
- **The Jetsam pane** (non-modal, beside the inspector) lists every item with its verdict and reason. It shows the total as "X GB staged" plus "N items of unknown size" when there are any, and has **Move to Trash…**.
- **The confirmation sheet** shows:
  - the count;
  - the total;
  - every `warn` item with its reason and a checkbox per item, unchecked by default (spec §10, "explicit per-item confirmation");
  - every `denied` item with its reason, listed as "will be skipped".
- **During execution:** progress shows count done and total; the sheet can't be dismissed mid-batch.
- **The summary:**
  - trashed, skipped and failed, each with its reasons;
  - **"X moved to Trash — empty Trash to reclaim it"**, using spec §10's copy with the measured figure;
  - **Open Trash**, which opens Finder's Trash and never empties it;
  - per-item **Put Back**.
- **History:** a **Recently trashed** list from the log, across launches, with Put Back.
- **Rescan prompt:** after `needsRescan`, a banner: "Sizes include N trashed items; rescan for exact figures".
- **Log failure:** if `lastWriteFailed`, show a line: "The Tesserae log couldn't be written; trashing still worked."

**Copy:** spec §10's strings verbatim where it gives them; plain sentences elsewhere.

- [ ] **Step 1: View-model tests first** (pure):
  - every outcome's wording;
  - totals with unknown sizes;
  - warn items unchecked by default;
  - the Open Trash URL is the user's Trash and no API that empties it is reachable.
- [ ] **Step 2: Snapshot tests**, light and dark, in the Task 10 pattern from Phase 3 (fixed size, locale, time zone): pane with mixed verdicts, confirmation sheet with warns, summary with all three outcome kinds, staged tiles.
- [ ] **Step 3: Implement; pass; mutation-verify; commit** `feat(app): Jetsam pane, confirmation and summary`.

### Task 9: Phase 4 gate and live checks

- [ ] **Gate (spec §17):**
  - The full guard-list and TOCTOU suites pass (Tasks 2, 3 and 5).
  - So do the rest of the suite and `just gate`.
  - Record the counts in `docs/benchmarks.md`.
- [ ] **End to end on a disk image:**
  1. Scan a disk-image fixture through the app's real model path.
  2. Stage a mix: ok, warn, denied and unknown size.
  3. Execute, with the containment check active.
  4. Check the overlay, the log and the summary.
  5. Put Back one item and verify it is restored at its original path with its file ID.
- [ ] **Manual checks.** These need the coordinator, and they run only on the volumes and directories named here:
  - **exFAT trash and Put Back on `USB321FD`:**
    - The user owns it fully, but first verify the volume UUID `7031D3E6-71F0-3E7C-9DA3-5087E0973DD0`.
    - Create and trash test files inside `/Volumes/USB321FD/tesserae-test/`, then Put Back.
  - **SMB with no usable trash, on `hdd-raid-0`:**
    - Use only a new `/Volumes/hdd-raid-0/tesserae-test/` directory, never anything else.
    - Expect `trashItem` to fail, be reported as failed, and nothing destructive to be tried.
  - Record both in `docs/benchmarks.md`. **Never touch `/Volumes/ISOs`.**
- [ ] **Spec and docs:**
  - Update spec §10 with what was built: the reason list, the Data-volume normalisation, the hard-link and cloud-only warnings, the log's `pathB64`, and the overlay's `ChildList`.
  - Update spec §6 (the file-ID side array).
  - Update spec §16's deletion row with the measured state.
- [ ] Commit `docs: Phase 4 gate`.

## Not in this plan

- Permanent delete, secure erase, snapshot deletion, background or scheduled deletion, cleanup presets (spec §2, out of scope for 1.0).
- Emptying the Trash from the app.
- Signing, notarization, Sparkle and the Homebrew tap (Phase 5).
- Backlog housekeeping not named here: M5–M7, M9 and the parked items in `docs/phase-2-backlog.md`.
