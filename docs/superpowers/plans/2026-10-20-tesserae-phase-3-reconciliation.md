# Tesserae Phase 3: Reconciliation, Scan Report, Full Disk Access — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app accounts for the whole volume with a signed residual, reports every incompleteness in a scan report, and handles Full Disk Access honestly — onboarding with a relaunch, and a clearly labelled Limited scan when access is declined.

**Architecture:** Volume and snapshot facts are read in Swift (`getattrlist`, Foundation, snapshot listing) and fed with the scan's facts into a pure `reconcile` function (spec §9's seam). Full Disk Access is detected by probing a candidate list (§11). The Rust engine gains a skip list (for Limited scans), dataless-item handling, and an FFI accessor for the unreadable and skipped paths. The window adds a reconciliation view, a scan-report panel with Copy Diagnostics, and the degraded-mode states of §11's matrix.

**Tech Stack:** Rust 1.99.1 engine + C ABI (existing); Swift 6 / SwiftUI + AppKit, macOS 13 deployment; XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md` — §1 success criterion 3, §3 (stateless scan, provisional), §9 (reconciliation), §11 (permissions, degraded modes, diagnostics), §12 (reconcile tests, degraded-mode snapshot tests), §16 (dataless risk). Deferred work: `docs/phase-2-backlog.md`, section "Phase 2 → Phase 3".

## Global Constraints

- Everything in the Phase 2 plan's Global Constraints still holds (macOS 13 APIs only in TesseraeKit, `ObservableObject` not `@Observable`, GPL notice on every new file with `Copyright (C) 2026 Stephen de la Vega`, hand-edited `project.pbxproj`, tests pin `Locale(identifier: "en_US")`, TDD with mutation-verified tests, never weaken an assertion, never rely on recalled macOS constants — read the SDK header or probe).
- **Never silent under-reporting** (spec §11): every incompleteness reaches the UI as a counter, caveat or flag. Unavailable values are `nil` and render as `—`, never `0`.
- **The reconciliation summands total capacity exactly**; snapshots are an annotation on the residual, not a summand (spec §9).
- **No deletion of anything** in this phase: snapshots are reported, never removed (spec §9).
- **Diagnostics go only to the clipboard**, never transmitted; no telemetry (spec §11).
- **FDA cannot be requested programmatically**; the only action is opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, and the grant needs a relaunch (spec §11).
- **Steps that need the user** (revoking/granting FDA, `sudo purge`, evicting an iCloud folder) are explicit and paused for; agents never use sudo, never change privacy settings themselves, and touch iCloud Drive only inside a folder created for the probe.
- **CI is not available** (the private repo's free Actions minutes are spent); `just gate` is the check.

## Review Focus

1. **Negative residual** (APFS clones make the scan exceed physical use). Expected: shown with its sign and the clone caveat, summands still total capacity. Test: Task 3 `negative_residual_is_signed_and_explained` (first in the table, per spec §12).
2. **Full Disk Access indeterminate** (every candidate path missing). Expected: treated as unknown, Limited caveat shown, never assumed granted. Test: Task 5 `all_candidates_missing_is_indeterminate_not_granted`.
3. **Snapshot listing unavailable** (API refused, `tmutil` missing or slow). Expected: snapshot line `—`, everything else works. Test: Task 2 `listing_failure_yields_nil_not_zero`.
4. **A partial scan** (cancelled, stalled, node limit, volume lost). Expected: residual suppressed with the reason, partial badge, report lists what was cut. Test: Task 3 `partial_scan_suppresses_residual`, Task 10 matrix rows.
5. **A scan root on a dead network share** (open hangs). Expected: the UI stays usable and a new scan starts at once; the hung one is abandoned. Test: Task 11 `hung_root_does_not_block_a_new_scan`.

---

### Task 1: Volume facts

**Files:** Create `apple/TesseraeKit/Reconciliation/VolumeFacts.swift`, `apple/TesseraeKitTests/VolumeFactsTests.swift`.

**Interfaces — Produces:**
```swift
public struct VolumeFacts: Equatable { public let capacity, used, free, available: UInt64; public let purgeable: UInt64? }
public enum VolumeFactsError: Error { case unsupported(errno: Int32), malformed }
public func readVolumeFacts(at volumeRoot: URL) throws -> VolumeFacts      // getattrlist ATTR_VOL_*
public func readSystemVolumeUsed() -> UInt64?                             // the sealed system volume at "/", nil if unreadable
```

- [ ] **Step 1: Probe.** Read `ATTR_VOL_CAPACITY`, `ATTR_VOL_SPACEUSED`, `ATTR_VOL_SPACEFREE`, `ATTR_VOL_SPACEAVAIL` values and sizes from `$(xcrun --show-sdk-path)/usr/include/sys/attr.h`. Spec §9 records that `SPACEUSED` packs out of bit order on 27.2: request it **in its own `getattrlist` call**, as §9 recommends, rather than assuming an order. Purgeable = `volumeAvailableCapacityForImportantUsageKey` − available (§9). Record measured values for `/System/Volumes/Data` and `/` beside `diskutil info` in the commit message.
- [ ] **Step 2: Failing tests.** `facts_match_diskutil_within_a_few_megabytes` (shells out to `/usr/sbin/diskutil info -plist /System/Volumes/Data`, parses `APFSContainerSize`, `CapacityInUse`/volume used, `APFSContainerFree`; skips loudly if `diskutil` is missing); `purgeable_is_nil_when_foundation_does_not_report`; `used_is_read_by_a_separate_call` (a seam asserts two calls).
- [ ] **Step 3: Implement**, byte-copy reads, no `repr(C)` casts.
- [ ] **Step 4: Pass, mutation-verify, commit** — `feat(kit): read volume facts with SPACEUSED in its own call`.

### Task 2: Snapshot facts

**Files:** Create `apple/TesseraeKit/Reconciliation/SnapshotFacts.swift`, tests.

**Interfaces — Produces:**
```swift
public struct SnapshotFacts: Equatable { public let count: Int?; public let oldest: Date?; public let aggregateBytes: UInt64? }  // nil = unknown
public func readSnapshotFacts(volumeRoot: URL, runner: CommandRunner = .system) -> SnapshotFacts
```

- [ ] **Step 1: Probe** `fs_snapshot_list` on a volume fd as an unentitled, unsandboxed app: does it list, or need an entitlement? Then `tmutil listlocalsnapshots /` (absolute `/usr/bin/tmutil`, fixed arguments, no shell, 5 s timeout, killed on expiry — spec §9). Record both results. Use whichever works; `aggregateBytes` is always `nil` in v1 (macOS gives no sizes).
- [ ] **Step 2: Failing tests** with an injected `CommandRunner`: parses names and dates; `listing_failure_yields_nil_not_zero` (non-zero exit, timeout, garbage output → `count == nil`); zero snapshots → `count == 0` (known zero, distinct from unknown); timeout kills the child.
- [ ] **Step 3–4: Implement, pass, mutation-verify, commit** — `feat(kit): count local snapshots without sizes`.

### Task 3: The reconciliation seam

**Files:** Create `apple/TesseraeKit/Reconciliation/Reconcile.swift`, `apple/TesseraeKitTests/ReconcileTests.swift`.

**Interfaces — Produces (spec §9, extended for the system volume and access state):**
```swift
public struct ScanFacts: Equatable { public let allocatedSum: UInt64; public let unreadableLocations: Int; public let incomplete: Bool; public let limited: Bool; public let datalessItems: UInt64? }
public enum Caveat: Equatable { case cloneDoubleCounting, noFullDiskAccess, accessUnknown, limitedScan, partialScan(String), containerDataUnavailable, snapshotsUnavailable, datalessNotCounted(UInt64) }
public struct Reconciliation: Equatable {
    public let capacity, scanned, free: UInt64
    public let systemVolume: UInt64?          // read-only system volume, not scanned
    public let snapshots: SnapshotFacts
    public let residual: Int64?                // signed; nil when suppressed (partial scan)
    public let purgeableEstimate: UInt64?
    public let caveats: [Caveat]
}
public func reconcile(_ v: VolumeFacts, systemVolumeUsed: UInt64?, _ s: SnapshotFacts, _ scan: ScanFacts) -> Reconciliation
```
`residual = capacity − free − scanned − (systemVolume ?? 0)`; other container volumes (Preboot, VM, Recovery) land in the residual until the 1.x container breakdown (record this in spec §9). Summands (scanned + systemVolume + residual + free) total capacity exactly whenever the residual is shown.

- [ ] **Step 1: Failing table-driven tests** (spec §12 order, negative first): `negative_residual_is_signed_and_explained` (`.cloneDoubleCounting`); `positive_residual_with_snapshots_annotates_count_and_oldest`; `snapshots_unavailable_renders_nil_not_zero` (`.snapshotsUnavailable`); `partial_scan_suppresses_residual` (`residual == nil`, `.partialScan(reason)`); `inconsistent_capacity_used_free_is_reported_not_clamped`; `no_fda_and_unknown_access_add_their_caveats`; `limited_scan_adds_its_caveat`; `summands_total_capacity_exactly` (property test, SplitMix64, 500 seeds); overflow-safe at UInt64 extremes.
- [ ] **Step 2–4: Implement, pass, mutation-verify, commit** — `feat(kit): signed space reconciliation`.

### Task 4: Reconciliation view

**Files:** Create `apple/TesseraeKit/Reconciliation/ReconciliationView.swift`, `ReconciliationViewModel.swift`, tests; modify `apple/Tesserae/ContentView.swift`.

- [ ] Build the breakdown of spec §9's example: Capacity; Scanned; System volume ("read-only, not scanned by default"); Residual with its sign and meaning ("space the scan can't see" / "the scan is double-counting shared blocks"); the snapshot annotation ("N local snapshots, oldest D — size not reported by macOS"); Free; purgeable line ("about X purgeable", nil → hidden, labelled derived); the unreadable warning with Grant Access when FDA is missing or unknown. Bars proportional to the summands; `—` for every `nil`. Text in ink tokens.
- [ ] Tests on the view model (pure): row text and order for each `Caveat`; `nil` renders `—`; a suppressed residual shows its reason; numbers via `displaySize` with an injected locale.
- [ ] Wire it into the window (a pane beside the inspector or above the treemap — keep the treemap's viewport); read volume and snapshot facts off the main actor after each scan.
- [ ] Commit — `feat(app): reconciliation breakdown`.

### Task 5: Full Disk Access detection

**Files:** Create `apple/TesseraeKit/Permissions/FullDiskAccess.swift`, tests.

**Interfaces — Produces:**
```swift
public enum AccessState: Equatable { case granted, denied(evidence: String), unknown }
public struct AccessProbe { public init(candidates: [URL] = .defaultCandidates, open: (URL) -> Int32 /* errno or 0 */ = AccessProbe.realOpen) ; public func probe() -> AccessState }
```
Candidates (spec §11): `~/Library/Mail`, `~/Library/Messages`, `~/Library/Safari`, and the user-level `TCC.db` when present. Rules: any existing candidate readable → granted (measured); an `EPERM` on an existing candidate → denied (**hypothesis until Step 3's run**); every candidate `ENOENT` → unknown (never granted).

- [ ] **Step 1: Failing tests** with an injected `open`: `all_candidates_missing_is_indeterminate_not_granted`; `one_readable_candidate_is_granted`; `eperm_on_an_existing_candidate_is_denied`; mixed `EPERM`/readable → decide and document (spec: readable wins only if *every* existing candidate is readable — follow it).
- [ ] **Step 2: Implement; pass; mutation-verify; commit** — `feat(kit): probe for Full Disk Access`.
- [ ] **Step 3: GUIDED no-FDA run (needs the user).** Build Release; ask the user to remove Tesserae from System Settings → Privacy & Security → Full Disk Access and quit any running copy; launch it; record the probe's verdict and the per-candidate errnos, and run a scan of `/System/Volumes/Data` recording `unreadable`, `errors`, entry count and time. Then ask the user to grant access again and relaunch; record the same. Write both to `docs/benchmarks.md` ("Full Disk Access: with and without") and update spec §11: turn the `EPERM → no FDA` hypothesis into a measured rule or correct it, and say whether the unreadable count discriminates.

### Task 6: Onboarding and relaunch

**Files:** Create `apple/TesseraeKit/Permissions/Onboarding.swift`, `apple/Tesserae/OnboardingView.swift`, tests.

- [ ] First launch (and whenever access is `.denied`/`.unknown` and the user hasn't chosen Limited): explain why Full Disk Access is needed and what it isn't (no network, no telemetry — spec §11/§14); **Open Settings** opens the pane URL; **Relaunch Tesserae** relaunches the app (new instance via `NSWorkspace.openApplication(at:configuration:)` with `createsNewApplicationInstance`, then terminate) — copy says "Grant access, then Tesserae will restart"; **Use Limited Scan** records the choice.
- [ ] Re-probe when the app becomes active; if the state changed to granted in this process (it won't, per §11) or on relaunch, dismiss. Show "FDA granted — relaunch to apply" when the user returns from Settings (spec matrix row "FDA granted mid-session").
- [ ] Tests on the pure state machine (no AppKit): transitions for granted/denied/unknown × choice × app-activation; the relaunch command is issued exactly once.
- [ ] Commit — `feat(app): Full Disk Access onboarding with relaunch`.

### Task 7: Limited scan in the engine

**Files:** Modify `crates/tesserae-core/src/walk/` (options, admission), `crates/tesserae-ffi/src/lib.rs`, header (regenerate), tests; `apple/TesseraeKit/ScanCoordinator.swift`.

- [ ] Add `WalkOptions.skip: Vec<PathBuf>` — absolute directories the walk records as nodes but never enters, counted in a new `WalkStats::skipped_by_request` list (path + reason "limited scan"). Matching is by **device + inode** of each listed directory, resolved once at scan start (never by path string, which symlinks and firmlinks defeat); missing entries are ignored and reported.
- [ ] FFI: `TessScanOptions` gains a skip list (count + array of C strings, owned by the caller for the duration of `tess_scan_begin`); ABI 1 is still unshipped — no version bump; update the clang layout test.
- [ ] Limited scan skips the promptable locations of spec §11: `~/Desktop`, `~/Documents`, `~/Downloads`, plus `~/Library/Mobile Documents` (iCloud Drive) — probe each for prompting behaviour in Task 5's no-FDA run and record which actually prompt; adjust the list to the evidence.
- [ ] Tests (Rust): skipped directories appear with no children and are listed; a symlink to a skipped directory doesn't bypass it; totals exclude them. Swift: Limited scans pass the list and set `ScanFacts.limited`.
- [ ] Commit — `feat(core): skip list for Limited scans`.

### Task 8: Dataless (cloud-only) items

**Files:** Modify `crates/tesserae-core/src/{parse,walk/*}.rs`, FFI, header, tests; spec §16; benchmarks.

- [ ] **Step 1: Probe (needs the user's OK at the moment of running; touches only a folder created for it).** In iCloud Drive create `~/Library/Mobile Documents/com~apple~CloudDocs/tesserae-dataless-probe/` with nested folders and files of known sizes; wait for upload; evict it with `/usr/bin/brctl evict <path>`; confirm `SF_DATALESS` on files and directories via `stat -f %Xf` / the scanner's `ATTR_CMN_FLAGS` (read `SF_DATALESS` from the SDK header). Scan it twice: default I/O policy, and with `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` on every worker (read the constants from `<sys/resource.h>`). Record: did enumeration trigger a download, time taken, errnos, what sizes were reported. Delete the probe folder afterwards (ask first).
- [ ] **Step 2: Policy from the evidence.** Default expectation (to confirm): set the no-materialize policy on scan threads; flag dataless files and directories with a new `TESS_FLAG_DATALESS` (next free bit; document); count them in `WalkStats::dataless` (files, directories); a dataless directory is recorded but not entered (its contents are not local) and is counted, never silently treated as empty. Spec §16's risk row is updated to the measured behaviour.
- [ ] Tests: synthetic buffers with `SF_DATALESS`; the policy is set on every worker thread (a thread-local check through a test seam); stats counted; FFI exposes the counts.
- [ ] Commit — `feat(core): count cloud-only items without downloading them`.

### Task 9: Scan report and Copy Diagnostics

**Files:** FFI accessors for path lists; `apple/TesseraeKit/Report/ScanReport.swift`, `apple/Tesserae/ScanReportView.swift`, tests.

- [ ] FFI: `tess_snapshot_unreadable(index)` / count, `tess_snapshot_skipped(index)` / count (mounts, limited-scan skips, dataless directories) returning borrowed raw path bytes (like `stalled_at`); header regenerated; layout test updated.
- [ ] `ScanReport` (pure, value types): counts (entries, dirs, files, errors, unreadable, skipped by reason, dataless, hardlink dups, lost entries, depth capped), every incomplete flag with its wording from `ScanBanner`, every reconciliation caveat, access state, scan root, time, engine/app versions. Paths are listed with display-sanitised names; raw bytes kept for actions.
- [ ] Panel (not modal, always reachable from the window): the report, plus the unreadable-path list (this closes the deferred P6-1 gap: an unreadable folder under a zero-size directory now appears here). **Copy Diagnostics** writes plaintext to `NSPasteboard.general` only, with a one-line note that it contains file paths and should be reviewed before sharing.
- [ ] Tests: report text for a fully synthetic snapshot (golden string); every `Incomplete` code and caveat appears; nothing but the pasteboard is written (a seam).
- [ ] Commit — `feat(app): scan report and Copy Diagnostics`.

### Task 10: Degraded-mode matrix

**Files:** `apple/TesseraeKitTests/DegradedModeTests.swift`, reference images under `SnapshotTests/`, small view fixes as needed.

- [ ] For every row of spec §11's matrix (No FDA; FDA granted mid-session; `diskutil` unavailable; snapshot list unavailable; node limit reached; scan cancelled; volume stalled; volume lost; no Metal; Rust panic), inject synthetic `Reconciliation`/`ScanReport`/`AccessState` values (no filesystem) and render the window's status area, reconciliation view and banner with `ImageRenderer` (macOS 13) into reference PNGs; assert the row's required text is present (accessibility tree or the view model) and compare pixels exactly, as in Phase 2's snapshot tests. Record with `TEST_RUNNER_TESSERAE_RECORD_SNAPSHOTS=1`.
- [ ] This is the **Phase 3 gate** (spec §17: "Degraded-mode matrix renders correctly").
- [ ] Commit — `test(app): degraded-mode matrix snapshots`.

### Task 11: Phase 2 leftovers that belong here

**Files:** as each item names; tests.

- [ ] **M3 — a hung root open must not block later scans.** `ScanCoordinator.start` must not await a previous scan's `finish` indefinitely: after cancel, if status hasn't left running within a bounded wait (e.g. 2 s), abandon that handle (it leaks until its syscall returns, as the engine's watchdog already accepts) and start the new scan at once. Test with the fake `ScanDriving`: `hung_root_does_not_block_a_new_scan`.
- [ ] **M2 — Age's "now"** is the snapshot's scan start (`WalkStats.started_at`, exposed through `TessScanStats`), not app launch.
- [ ] **M8 —** a refused scan start reads "Couldn't start the scan" (with the errno detail in the report), not "Invalid argument".
- [ ] **M4 —** `sizeText` in ContentView uses `displaySize` with the injected locale; the table's name sort keys on the display name.
- [ ] **M1 —** a per-node file-kind byte computed once per snapshot off the main actor; the inspector in its own `ObservableObject` so hover doesn't re-evaluate the session view; selected/denied tile lists precomputed when tiles change. Extend the Release frame-gate protocol with an Age pass, a Type-focus pass and a hover sweep; rerun the gate (needs the user at an unlocked Mac) and record it.
- [ ] Each item mutation-verified; commit per item or grouped by area.

### Task 12: Cold-cache scan speed (needs the user)

**Files:** `docs/benchmarks.md`, spec §3, §13, §16.

- [ ] For each of 5 runs: the user runs `sudo purge` in their own terminal (agents never use sudo), then the agent runs `tesserae-cli scan /System/Volumes/Data` immediately (release build, default workers) and records wall time, entries and entries/s; then one warm run after each cold one. Report median and worst cold per 1M entries next to the warm figures.
- [ ] Update spec §3's provisional "stateless scan" decision with the measured cold result: if the cold median is within spec §1's rate (≈5 s per 1M entries) the decision becomes settled; if not, record the gap and open the index question for the user (do not decide it).
- [ ] Commit — `docs(bench): cold-cache scan speed`.

## Not in this plan

- Container breakdown via `diskutil apfs list -plist`, the purgeable *breakdown*, and the "System Data" explainer (spec §2, 1.x).
- Jetsam and deletion (Phase 4), signing/notarization/Sparkle (Phase 5), the bundle ID is decided: `com.sdelavega.Tesserae`.
- The remaining housekeeping items in the backlog's Phase 2 → Phase 3 section that Task 11 doesn't name.
