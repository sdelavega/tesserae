# Tesserae — Design Spec

**Date:** 2026-10-18
**Status:** Approved design. Implementation plan not yet written.

---

## 1. Purpose

Tesserae is a disk space visualizer for macOS: the visual density and
navigational model of WizTree, the scan speed to match, delivered as a native
Mac app of the quality people expect from DaisyDisk.

### Intended outcome

Someone whose Mac is full opens Tesserae, waits a few seconds, and can see
where their space went — at file granularity, in one screen, without
waiting through a minutes-long scan or guessing at macOS's opaque "System
Data" category. They can then reclaim space without fear of breaking
anything.

### Who it is for

Mac users who have run out of disk space and want to understand why. The
distribution model — GitHub releases, GPL-3, donations — aims this
squarely at technically-comfortable users first, with the polish to be
recommendable to anyone.

### Success criteria

1. A full data-volume scan of a typical Mac completes fast enough that no
   persistent index is warranted. The target is single-digit seconds for
   1–2M files on Apple Silicon NVMe. **This number is an estimate and must
   be validated by the spike in §13 before implementation begins.**
2. The treemap stays fluid — smooth zoom, no stutter — on a tree of a
   million nodes.
3. The app can account for the whole volume, including the space it cannot
   see, and never silently under-reports.
4. No user has ever lost data they didn't intend to lose.

### Stated requirements

These came from the project owner and are not open for re-litigation
during implementation:

- macOS only.
- Rust scan engine, SwiftUI shell.
- Full Disk Access, no root, no privileged helper.
- GPL-3.0.
- GitHub-style releases; donations as the funding mechanism.
- Staged delivery: speed and density first, hidden-space breakdown second.
- Named Tesserae.

### Assumptions

These are the author's inferences, recorded so they can be challenged:

- Deployment target macOS 13 (Ventura), universal binary. Chosen to reach
  Intel Macs that cannot upgrade, which are disproportionately the machines
  with small SSDs.
- The default scan root is the data volume, not `/`.
- Allocated size (not logical) is the default display, because the user's
  question is "how much will I get back."
- Depth is the default colour encoding; age is one click away. This is a
  UX judgment to confirm against a prototype, not a settled fact.

---

## 2. Scope

### v1

- Full-volume scan, stateless, no persistent index.
- Squarified treemap with level-of-detail and smooth zoom.
- Sortable file table, selection synced with the treemap.
- Space reconciliation with a signed residual (§9).
- Snapshot count and dates, reported not deleted.
- Jetsam staging and trash-only deletion with a two-layer guard list (§10).
- Full Disk Access onboarding, and a clearly-labelled Limited scan when
  declined.
- Scan report surfacing every incompleteness.

### 1.x

- Container breakdown via `diskutil apfs list -plist`.
- Purgeable estimate.
- "System Data" explainer — mapping macOS's residual category to real
  directories. This is curation work, not API work.
- One-click cleanup presets (DerivedData, caches, Homebrew), deliberately
  deferred until there is a bug history to design them against.

### Explicitly never

- Purgeable *breakdown*. There is no public API; delivering it would mean
  private frameworks or guessing.
- Permanent delete or secure erase.
- Snapshot deletion.
- Background or scheduled deletion.
- Telemetry.
- Mac App Store distribution — sandboxing is incompatible with whole-disk
  scanning.

---

## 3. Decisions and their reasons

| Decision | Reason |
|---|---|
| Name: Tesserae | A treemap is a field of mosaic tiles. Plural avoids a crowded field of macOS apps named "Tessera" — at least three tiling window managers, a code editor, a notes app, an App Store design app. |
| Not "Ballast" | `reloadlife/ballast` is an existing macOS disk-space app in the same niche. Direct collision. |
| Rust core + SwiftUI | Rust is the best available language for an arena-allocated flat tree with work-stealing parallelism. SwiftUI/AppKit is the only way to ship Mac-native polish. Neither alone does both. |
| FDA, no root | **Root does not bypass TCC on macOS.** It buys only POSIX wins (other users' homes, restrictive modes). A privileged helper would still need its own FDA grant, so root costs an XPC attack surface and an authorization prompt while skipping nothing. Staying non-root is also a safety property for a tool that deletes. |
| GPL-3.0 | Prevents closed-source resale. Its App Store incompatibility costs nothing here. GPLv3's System Libraries exception covers linking AppKit/Metal. |
| Stateless scan | If the scan is genuinely fast, an index buys nothing and costs a database, cache invalidation, and FSEvents reconciliation gaps across reboots. "Fast enough not to need a cache" is also the better product story. |
| Trash-only deletion | Free undo; correct `.Trashes` and Put Back semantics; and trashing a directory is an O(1) rename regardless of how many files it holds. |
| No sidecar process | Crash isolation obtained more cheaply via `catch_unwind`, depth caps, and refusing non-local mounts. Accepted cost: a genuine segfault in the parser takes the app down. |

### Why not the other language stacks

- **Pure Rust UI** (`objc2`, `egui`, `iced`): hand-rolling AppKit bindings
  for menus, sheets, dark mode and accessibility; VoiceOver becomes
  near-impossible. Competing against DaisyDisk on polish and shipping
  something non-native loses on the axis that matters most.
- **Swift-only**: achievable, but only by refusing idiomatic Swift in the
  engine — structs in `ContiguousArray`, integer indices, no reference
  types in the hot path. ARC retain/release traffic across threads on 10M
  nodes is the failure mode. Rust removes the discipline requirement.
- **C++/ObjC++**: performance equal to Rust and the tightest native
  integration without FFI, but no memory-safety net in exactly the code
  that parses raw buffers.
- **Go**: GC pressure on a 10M-node heap; no viable native Mac GUI.
- **Electron/Tauri**: the scan needs a native module anyway, so the FFI
  cost stays and the native UI is lost.

---

## 4. The speed problem

WizTree is fast because it reads the NTFS Master File Table directly off
the raw volume — all metadata in one sequential read, zero per-file
syscalls. **That trick does not exist on macOS.** Apple's published APFS
on-disk reference is read-only and version-drifting; the data volume is
encrypted at rest on Apple Silicon, so raw block reads return ciphertext;
and the system volume is sealed.

So the speed has to be re-derived from different primitives:

- **`getattrlistbulk(2)`** — many directory entries' attributes per
  syscall. This is the central mechanism.
- **fd-relative descent** (`openat` with `O_DIRECTORY`) — avoids
  re-resolving every path component on each descent. Compounds with depth.
- **Work-stealing parallelism** over directories — the APFS catalog is a
  B-tree and concurrent readers scale well on NVMe.
- **Flat arena storage** — no per-node allocation, no strings built during
  the scan.

---

## 5. Architecture: snapshot handoff

Rust owns the scan and produces an **immutable snapshot**. Swift borrows it
and owns all presentation.

```
Tesserae.app
├── UI (SwiftUI)              chrome: sidebar, toolbar, inspector, settings, onboarding
├── TesseraeKit (framework)
│   ├── ScanCoordinator       drives the engine, owns snapshot lifetime
│   ├── Snapshot              ARC wrapper over borrowed Rust memory
│   ├── TreemapLayout         squarified + level-of-detail
│   ├── TreemapView           MTKView via NSViewRepresentable
│   ├── FileTable             NSTableView via NSViewRepresentable
│   ├── SpaceReconciler       volume facts, snapshots, signed residual
│   ├── Jetsam                staging set + trash execution
│   └── Permissions           FDA probe + onboarding
└── libtesserae.a (Rust staticlib)
    ├── walk                  getattrlistbulk traversal + worker pool
    ├── arena                 node and name storage
    ├── freeze                snapshot construction
    ├── dedup                 inode set for hardlinks
    └── ffi                   #[repr(C)] surface, catch_unwind
```

The Swift side is a **framework, not app-target code**, so layout,
reconciliation, guard lists and Jetsam are unit-testable without launching
a window. The engine stays replaceable behind the FFI surface.

### Alternatives considered

- **Thin Swift** (Rust owns layout too, writing into a Metal-shared
  buffer): avoids all per-frame FFI, but puts presentation logic in Rust so
  every visual iteration is a Rust change, and requires managing Metal's
  frame lifetime across the boundary. Layout is cheap enough that this buys
  nothing real.
- **Sidecar process**: genuine crash isolation, but two binaries to sign
  and notarize, a protocol to design, and an unverified assumption about
  whether a spawned child inherits the app's FDA grant.

---

## 6. The node and the snapshot contract

```rust
#[repr(C)]
pub struct TessNode {
    pub name_off:    u32,   // byte offset into the name arena
    pub name_len:    u16,
    pub flags:       u16,   // dir | symlink | clone | perm_denied | aggregated
    pub parent:      u32,   // index; u32::MAX for root
    pub child_start: u32,   // index of first child
    pub child_count: u32,   // 0 for files
    pub logical:     u64,   // sum of st_size
    pub allocated:   u64,   // sum of st_blocks * 512
}
```

40 bytes aligned. 1–3M files costs 40–120 MB; 10M files costs 400 MB.

**Children are contiguous and pre-sorted descending by `allocated`.**
Squarified layout wants exactly that, so the freeze step pays once and
every layout pass reads a cache-friendly slice with no work.

**Array-of-structs, not struct-of-arrays.** SoA would help a full-tree
sweep, but level-of-detail means only the visible level is ever touched.
The cache win is theoretical; the complexity is not.

### The freeze step

After the parallel scan lands nodes in per-thread arenas:

1. count children per parent, prefix-sum, scatter into the final array
2. sort each sibling range descending by `allocated`
3. roll sizes up bottom-up

One counting-sort-style pass, parallelizable by subtree.

### FFI surface

```c
uint32_t      tess_abi_version(void);

TessScan*     tess_scan_begin(const char* root, const TessScanOptions*);
void          tess_scan_progress(TessScan*, TessProgress* out);
void          tess_scan_cancel(TessScan*);
TessSnapshot* tess_scan_finish(TessScan*);   // consumes the scan

typedef struct {
    const TessNode* nodes;  uint64_t  count;
    const uint8_t*  names;  uint64_t  names_len;
    uint32_t        root;
} TessView;

void tess_snapshot_view(const TessSnapshot*, TessView* out);
void tess_snapshot_release(TessSnapshot*);
```

`tesserae.h` is generated by `cbindgen`, with a CI check that the committed
header matches a fresh regeneration.

### How the borrow is made safe

The one real hazard in this architecture is Swift holding a pointer into
Rust memory. It is closed structurally, not by discipline:

1. **The snapshot is immutable** from the moment `tess_scan_finish`
   returns. Rust never mutates it, never reallocates it, never hands out a
   second mutable path to it. The only remaining transition is destruction.
2. **ARC owns the Rust allocation**, so lifetime is enforced by the
   language:

   ```swift
   final class Snapshot {
       private let handle: OpaquePointer
       let nodes: UnsafeBufferPointer<TessNode>
       let names: UnsafeRawBufferPointer
       let root:  UInt32
       deinit { tess_snapshot_release(handle) }
   }
   ```

   **Code rule:** `UnsafeBufferPointer` must never outlive the `Snapshot`
   instance. Never capture the raw pointers in an escaping closure without
   capturing the class. Debug builds carry a generation counter asserted on
   access.
3. **Deletion does not mutate the snapshot.** Swift keeps an overlay — a
   `[UInt32: Int64]` size-delta map plus a deleted-node set — consulted
   during layout. Past ~10k entries or a 10% root delta, prompt a rescan.
4. **Panics never cross the boundary.** `catch_unwind` at every FFI entry
   *and inside every worker thread*, since by the time workers run the
   entry-point guard has already returned. `panic = "unwind"` pinned in the
   release profile; with `abort`, a bad symlink kills the app.
5. **ABI drift traps loudly.** A mismatch is a build defect, not a user
   condition.
6. **Progress counters are atomics**, so `tess_scan_progress` is safe to
   poll from the main thread mid-scan. The frozen snapshot is immutable and
   therefore safe to read from a background queue.

---

## 7. Scan engine

### Attribute set

Kept lean, because every additional attribute costs scan time.
`ATTR_CMN_RETURNED_ATTRS` is requested first so per-entry absence is
detectable rather than guessed. `FSOPT_PACK_INVAL_ATTRS` keeps offsets
predictable; `FSOPT_NOFOLLOW` keeps symlinks unresolved.

| Attribute | Purpose |
|---|---|
| `ATTR_CMN_RETURNED_ATTRS` | know what actually came back |
| `ATTR_CMN_NAME` | name |
| `ATTR_CMN_OBJTYPE` | file / dir / symlink |
| `ATTR_CMN_FILEID` | inode, for hardlink dedup |
| `ATTR_CMN_DEVID` | volume boundary detection |
| `ATTR_CMN_FLAGS` | `UF_COMPRESSED`, `SF_RESTRICTED`, immutability |
| `ATTR_FILE_DATALENGTH` | logical size |
| `ATTR_FILE_ALLOCSIZE` | allocated size |
| `ATTR_FILE_LINKCOUNT` | gate the dedup set |

**Never request a recursive-size attribute** such as `ATTR_DIR_ALLOCSIZE` —
that asks the filesystem to do this program's job, slowly.

### Worker pool

A work-stealing deque per worker (`crossbeam-deque`), seeded with the root.
Each worker: pop a task, `openat(parent_fd, name, O_RDONLY | O_DIRECTORY |
O_NOFOLLOW | O_CLOEXEC)`, loop `getattrlistbulk` into a reusable
thread-local buffer, append entries to a thread-local arena, push child
directories, close the fd.

**Depth-first within a worker, breadth-shared across workers.** A worker
descends using fd-relative opens, so its open-fd chain equals *tree depth*,
not tree size. Tasks pushed for stealing carry an `Arc<Path>` instead.
Bound is `workers × max_depth`; raise `RLIMIT_NOFILE` to 4096 at startup.
If `setrlimit` fails, reduce worker count to fit rather than failing.

Thread count defaults to `available_parallelism()` clamped 4–16, tunable.
This work is mostly kernel-CPU-bound on NVMe, so core count is roughly
right — reasoning that fails completely on spinning or network volumes,
which is one more reason `/Volumes` is opt-in.

### Arena allocation

Per-thread chunked bump allocators: `TessNode` chunks of 64 Ki, name-byte
chunks alongside. Chunks are never reallocated, so nothing is invalidated
mid-scan, and the only shared-state touch is claiming a new chunk.

Scan-time ids are temporary `(thread, chunk, slot)` packed into a `u64`;
the freeze pass assigns final indices.

**Chunk allocation must use `try_reserve`.** Rust aborts the process on
allocation failure by default — `Vec::push` does not return an error, it
dies. OOM must arrive as a `Result` the engine can report.

### Boundaries and skip policy

**Default scan root is `/System/Volumes/Data`, not `/`.** The sealed system
volume is read-only and essentially fixed; all actionable space is on the
data volume. Scanning `/` is offered as "include system volume."

- **Volume boundary:** compare each directory's `ATTR_CMN_DEVID` to the
  root's and refuse to cross. One check handles firmlinks, mounted volumes
  and `/Volumes` entries.
- **Non-local mounts:** check `MNT_LOCAL` in `statfs` `f_flags` before
  descending into any mount point. A dead SMB or NFS mount blocks `openat`
  indefinitely and uninterruptibly; this check is the actual fix, not a
  timeout.
- **Symlinks:** never followed, counted at their own size.
- **Depth cap** of 512, flagged when hit.
- `/private/var/vm` is **scanned but marked non-deletable** — real space,
  and users ask about it.

### Dedup: three problems, two solvable

**Hardlinks — solvable.** A concurrent inode set, with insertion gated on
`ATTR_FILE_LINKCOUNT > 1` so the set stays nearly empty in practice. First
occurrence counts full; later ones count zero and are flagged.

**APFS clones — not solvable.** Copy-on-write copies have *different*
inodes while sharing blocks, and `ATTR_FILE_ALLOCSIZE` reports full size
for each. There is no public API to detect block sharing. Therefore
`sum(allocated) > volume_used` is **expected and normal**, and the UI must
never present the tree sum as "space used." This is why §9 anchors on
volume facts instead.

**Sparse files — free.** Tracking both `logical` and `allocated` handles
them.

### Size semantics

Both stored; **allocated is the default display.**

Known accounting trap: `UF_COMPRESSED` files (common in `/usr`, `/System`)
report a data-fork allocated size near zero, with real bytes in the
resource fork. For flagged files that means consulting
`ATTR_FILE_RSRCALLOCSIZE`. Whether that is cheap enough to request
unconditionally is a spike question (§13).

### Progress and cancellation

Four atomics — `dirs_done`, `files_done`, `bytes_seen`, `errors` — polled
at ~10 Hz. No callbacks from Rust threads into Swift.

**Progress is not a percentage.** The total is unknown until completion; a
fake progress bar on a five-second operation is worse than counts plus a
throughput rate, which also happens to demonstrate the speed.

Cancellation is an `AtomicBool` checked at directory boundaries.
`tess_scan_finish` returns a **partial snapshot flagged incomplete** — a
cancelled scan covering most of the disk is still useful.

---

## 8. Layout, rendering, interaction

### Squarified layout with level-of-detail

Bruls–Huizing–van Wijk. Children arrive pre-sorted, so layout is O(n) in
visible children with no sorting at layout time.

- **Subdivide threshold** — a child whose minimum dimension falls below
  ~24px becomes a terminal tile; don't recurse.
- **Cull threshold** — rects below ~16px² are not emitted.
- **Tail aggregation** — because siblings are sorted descending, everything
  too small is a *contiguous suffix*. Emit `children[0..k]` individually,
  collapse `children[k..]` into one "N smaller items — X MB" tile. A prefix
  cut, no scanning.
- **Hard instance budget** (~50k tiles), whichever binds first.

Typical render sets are a few thousand rects; the worst case at a 16px²
cutoff is tens of thousands, which is nothing to a GPU. The genuinely
bounded-small set is *labels*.

### Metal

One instanced draw call:

```
struct TileInstance {
    float4 rect;        // x, y, w, h in points
    uint16 colorIdx;
    uint8  depth;
    uint8  flags;       // selected | staged | permDenied | aggregated
}
```

A unit quad expanded per instance. The fragment shader fills from a palette
buffer and derives the 1px inner border from fragment-space distance to the
rect edge, so nesting cues cost no second draw call. Instance buffers are
triple-buffered round-robin with a counting semaphore,
`MTLResourceStorageModeShared`.

### Colour

A treemap is an **all-pairs form** — any two tiles can end up adjacent.
Validated under `--pairs all`, the eight-slot categorical palette caps at
**three slots**. So a rainbow-by-file-type is not available, which is
fortunate, because a twelve-hue legend was never readable anyway.

**Mode 1 — Depth (default).** Ordinal blue ramp, steps 250–650 light,
anchor-flipped dark.

```
light  #86b6ef  #5598e7  #2a78d6  #1c5cab  #104281
dark   #184f95  #256abf  #3987e5  #6da7ec  #9ec5f4
```

Validated: monotone L, adjacent ΔL ≥ 0.06, light-end contrast 2.06:1 light
/ 2.15:1 dark, hue spread 3°. Passes both modes.

**Mode 2 — Age.** Sequential blue ramp, full 100→700, light = recently
modified, dark = stale, flipped in dark mode. Old-and-large is the reclaim
signal, so this is prominent.

**Mode 3 — Type focus.** Up to **three** file-type categories take slots
1–3; everything else goes neutral. "Show me where my video files are"
beats a twelve-colour mosaic.

```
light  #2a78d6  #eb6834  #1baf7a   worst all-pairs CVD ΔE 9.2 · normal 24.0
dark   #3987e5  #d95926  #199e70   worst all-pairs CVD ΔE 9.4 · normal 20.9
```

**Explicitly not colour-by-size.** Area already encodes size; colouring by
it spends the identity channel re-encoding what the rectangle says.

Two binding obligations:

- Light-mode aqua is **2.74:1** against the surface — a contrast WARN,
  discharged by tile labels plus the file table. This is why the table is
  not merely a convenience.
- Identity is never colour-alone: the focus legend is always present, and
  the 45°/135° line texture is wired for the accessibility setting, print,
  and `forced-colors`.

**Status colours stay reserved.** `permDenied` tiles get `#fab219` *plus a
lock badge and a label*. Non-deletable regions likewise. These steps sit
close to categorical hues in CVD terms, so the icon pairing is load-bearing.

### Labels

A SwiftUI overlay of positioned `Text` views, not a glyph atlas. At 50–400
visible labels SwiftUI copes. **Labels are suppressed during zoom
animation** and fade in when motion settles — this avoids SwiftUI diffing
hundreds of views per frame and reads as intentional. Name plus size,
middle-truncated, only where it fits. Text wears ink tokens
(`#0b0b0b` / `#f0efec`), never a tile's series colour.

### Zoom and navigation

Clicking a directory tile makes it the layout root. The animation computes
the target layout, renders the *old* layout transformed so the clicked rect
fills the viewport, and cross-fades — ~250ms ease-out, two instance buffers
and an alpha uniform, no per-frame relayout.

Breadcrumb for ancestry. Arrows between siblings, ⌘↑ to ascend, Return to
descend. Hover drives the inspector: full path, both sizes, type, dates.

### Hit testing

Linear scan over the emitted tile list with a last-hit cache. At
mouse-event frequency even 50k rects is well under a millisecond.

### File table

`NSTableView` via `NSViewRepresentable`, data source reading the snapshot
through a sorted index array. Column sorts reorder `[UInt32]` indices,
never nodes, off the main thread. Top-K largest files comes from a bounded
heap in Swift rather than extra FFI surface. Selection is a shared
`Set<UInt32>`, so table and treemap highlight each other both ways.

---

## 9. Space reconciliation

```
capacity = used + free
used     = scanned + snapshots + residual
```

**The residual is signed**, and this is the crux:

- permission-skipped files are missing from `scanned` → **positive**
- purgeable space and snapshots aren't in the tree → **positive**
- APFS clones make `scanned` overstate physical bytes → **negative**

Snapshots usually dominate and the residual is positive. On a dev machine
thick with cloned DerivedData it can invert. A tool presenting a single
unsigned "Hidden Space" number is lying in one of those directions, so
Tesserae shows the sign:

- **positive** → space the scan cannot see
- **negative** → the scan is double-counting shared blocks

### Sources

**Volume facts** via `getattrlist` on the volume root:
`ATTR_VOL_CAPACITY`, `ATTR_VOL_SPACEUSED`, `ATTR_VOL_SPACEFREE`,
`ATTR_VOL_SPACEAVAIL`.

Not `statfs` as the primary source: on APFS, volumes share a container's
free space, so `f_blocks - f_bfree` is *container-wide* usage.
`ATTR_VOL_SPACEUSED` exists specifically to report per-volume usage.

The gap between `SPACEAVAIL` and `SPACEFREE` is the system's own estimate
of reclaimable-on-demand space. **Verify the direction empirically** (§13);
this semantic is easy to get backwards.

**Snapshots** via `fs_snapshot_list` on a volume fd, or `tmutil
listlocalsnapshots` as fallback. Both give names and dates; **neither gives
sizes.** A snapshot's size is the unique blocks it retains, known only to
the filesystem. v1 reports count and oldest date; the bytes stay in the
residual with the count displayed prominently as the likely explanation.

**Container breakdown** (1.x) via `/usr/sbin/diskutil apfs list -plist`.
The APFS framework is private and private APIs break on point releases; a
shelled-out CLI with stable plist output is uglier and more durable.
Invoked through `Process` with an absolute path, fixed arguments, no shell,
no interpolation, 5-second timeout, killed on expiry.

### Skipped bytes are unknowable

When `openat` returns `EPERM` on a directory, **its size cannot be
determined** — there is no read access, so there is no size. The only
honest report is a count of inaccessible locations.

```
Capacity                   994 GB
├─ Scanned (data volume)   412 GB   ████████
├─ System volume            11 GB   ▎         read-only, not scanned by default
├─ Residual               +195 GB   ████      space the scan can't see
│    └─ 7 local snapshots, oldest 12 Oct — size not reported by macOS
└─ Free                    376 GB

⚠  3 locations unreadable — grant Full Disk Access to include them
```

The summands total capacity exactly. Snapshots are **not** a separate
summand, because their size is unavailable — they appear as an annotation
on the residual, naming its most likely cause. Once §2's 1.x container
breakdown lands, a snapshot figure can be promoted out of the residual
into its own line.

### The seam

A pure function over value types, so every case — including the negative
residual — is testable with synthetic input and no filesystem:

```swift
struct VolumeFacts   { let capacity, used, free, available: UInt64 }
struct SnapshotFacts { let count: Int; let oldest: Date?; let aggregateBytes: UInt64? }
struct ScanFacts     { let allocatedSum: UInt64
                       let unreadableLocations: Int
                       let incomplete: Bool }

struct Reconciliation {
    let capacity, scanned, free: UInt64
    let snapshots: UInt64?          // nil when unavailable, never 0
    let residual: Int64             // signed
    let purgeableEstimate: UInt64?
    let caveats: [Caveat]           // .cloneDoubleCounting, .noFullDiskAccess,
                                    // .partialScan, .containerDataUnavailable
}

func reconcile(_: VolumeFacts, _: SnapshotFacts, _: ScanFacts) -> Reconciliation
```

`nil` rather than `0` for unavailable values, so "we don't know" never
renders as "there is none."

### Snapshots: report, don't delete

v1 does **not** run `tmutil deletelocalsnapshots`. Snapshots are a recovery
mechanism; a disk cleaner that silently removes someone's ability to roll
back a bad update has done harm. Tesserae explains them, estimates their
likely contribution, and deep-links to Time Machine settings.

---

## 10. Jetsam and deletion safety

### Four invariants

1. **Rust never deletes.** It computes; Swift destroys.
2. **Trash-first, always.** No permanent delete, no secure erase in v1.
3. **Nothing happens at selection time.** Jetsam is a staging set.
4. **Every guard is re-evaluated at execution time.**

### Why trash

`FileManager.trashItem(at:resultingItemURL:)` handles per-volume
`.Trashes`, Put Back metadata and name collisions — all miserable to
reimplement and dangerous to get wrong. It gives undo for free. And
**trashing a directory is a rename**, so it is O(1) whether it holds three
files or 500,000, where a recursive unlink of a large `node_modules` takes
minutes.

**The UX trap:** trashing doesn't free space until the Trash is emptied.
The result screen says *"40 GB moved to Trash — empty Trash to reclaim it"*
with a button that **opens** Finder's Trash, never one that empties it
silently.

Some volumes have no usable `.Trashes` and `trashItem` fails there; report
it and offer nothing destructive as a fallback.

### The guard list

**Policy layer** — paths refused on principle:

| Denied | Why |
|---|---|
| `/System`, `/bin`, `/sbin`, `/Library/Apple` | OS integrity |
| `/usr` except `/usr/local` | OS integrity |
| `/private/var/db`, `/cores`, `/private/var/vm` | system state, swap |
| `/private/var/folders` | every app's `$TMPDIR`; removal breaks running apps confusingly |
| `.Trashes`, `.Spotlight-V100`, `.fseventsd` | system-managed |
| `Backups.backupdb` | needs `tmutil delete`; Finder-style removal corrupts it |
| volume root and its first-level children | nothing good comes of this |
| anything on a different volume than the scan root | no cross-volume surprises |
| the running app bundle or any ancestor | self-deletion |

**Warn, don't deny:** `~/Library/Containers` and `~/Library/Group
Containers`. Removing a container resets an app *including the documents of
sandboxed apps* — user data loss, but a legitimate informed choice. Hard
warning, explicit per-item confirmation, never silent.

**Physics layer** — what the OS itself refuses: check `st_flags` for
`SF_RESTRICTED` (SIP; unmodifiable even by root) and
`UF_IMMUTABLE`/`SF_IMMUTABLE`. The flag check catches what the path list
forgot; the path list expresses policy the flags don't.

### Time-of-check to time-of-use

Immediately before each operation:

1. **Re-stat and compare identity** — inode and device against the
   snapshot's record. Mismatch skips the item and reports it.
2. **Reject symlinked ancestry** — `lstat` up the parent chain and refuse
   any path with a symlink component.
3. **Re-run both guard layers** on the resolved path.

`trashItem` takes a URL, not a directory fd, so Foundation offers no way to
make this atomic. **This is a correctness guard against ordinary
filesystem churn, not a security boundary against a local attacker** — and
the threat model (your own Mac, your own files) does not require one.

### Staging

```swift
struct JetsamItem {
    let nodeIndex: UInt32
    let path: URL
    let recordedInode: UInt64
    let recordedDevice: dev_t
    let recordedSize: UInt64
    let isDirectory: Bool
    var verdict: Verdict
}

enum Verdict { case ok, warn(Reason), denied(Reason) }
```

- Staging a directory stages **one item**, recursively — not its contents.
- **Ancestry dedup:** staging `~/foo` then `~/foo/bar` drops the
  descendant, or the total double-counts and the second operation fails.
- Staged verdicts are UI hints; **execution verdicts decide.**

### Execution

A serial background queue — deletion throughput is not worth risking
ordering bugs for, and serial keeps the audit log coherent.

1. Confirmation sheet: count, total, every `.warn` item with its reason.
2. Per item: re-verify identity → re-run guards → `trashItem` → record
   `resultingItemURL`.
3. **One failure never aborts the batch.** Record, continue, report.
4. Apply size deltas to the overlay, propagating up parent chains.
5. Summary: trashed / skipped / failed with reasons, plus the reclaim
   affordance.

### Undo, in two layers

**In-app Put Back** from the recorded `resultingItemURL`. **Finder's
Trash** as the backstop — it works if Tesserae crashes or is uninstalled.
The safety net must not depend on this code being correct.

### Audit log

Append-only JSONL at
`~/Library/Application Support/Tesserae/jettison.log`, size-rotated:

```json
{"ts":"2026-10-18T14:22:03Z","action":"trash","path":"…","inode":918273,
 "bytes":4194304,"trashURL":"…","result":"ok"}
```

It powers Put Back across launches, and when someone reports that the app
ate their project, both parties need to know what happened. For a tool
granted Full Disk Access, that record separates a diagnosable bug from an
unfalsifiable accusation.

---

## 11. Error handling and degraded modes

**Organizing principle:** almost every failure here is *partial*, and the
cardinal sin is silent under-reporting. A tool that says "412 GB" when the
truth is "412 GB plus 40 GB I couldn't see" sends someone hunting in the
wrong place. Every incompleteness reaches the UI as a counter, caveat or
flag.

### Permissions

**Detecting FDA.** There is no API for it. Probe a known TCC-protected path
whose contents aren't needed — `~/Library/Application
Support/com.apple.TCC/TCC.db` is conventional since it always exists;
`EPERM` means no FDA. Keep `~/Library/Mail` as a secondary probe. Verify
the primary's behaviour in the spike (§13).

**FDA cannot be requested programmatically.** There is no prompt to
trigger. The only move is opening the pane:

```
x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
```

**The grant does not apply to the already-running process**, so onboarding
must be built around a relaunch: "Grant access, then Tesserae will
restart." Pretending otherwise produces the worst bug report — "I granted
it and it still doesn't work."

**Desktop, Documents and Downloads are separately promptable.** Without
FDA, a scan wandering into them fires modal prompts mid-run. So onboarding
asks for FDA *first*, and if declined the app runs an explicitly-labelled
**Limited scan** that skips promptable categories rather than ambushing the
user.

### Filesystem hazards

| Condition | Handling |
|---|---|
| Non-local mount | refused before descent via `MNT_LOCAL` |
| `ENOENT` mid-scan | normal churn; counted silently |
| `EINTR` | retry |
| `ELOOP`, `ENAMETOOLONG` | count, skip, continue |
| Symlink cycles | impossible — never followed |
| Hardlinked directory cycles | HFS+ Time Machine only; depth cap catches it |

**A hanging local volume** has no clean recovery — a blocked `openat` is
uninterruptible from userspace. A watchdog detects a worker making no
progress for ~15s and surfaces *"scan stalled at /path"*; Cancel returns
the partial snapshot. The blocked thread cannot be killed and leaks until
the syscall returns or the app quits. Stated plainly rather than papered
over.

### Resource exhaustion

- **Memory:** hard node budget (~25M nodes). Hitting it returns a partial
  snapshot flagged `.nodeLimitReached` — a truthful partial beats an
  OOM-kill the user reads as a crash. Requires `try_reserve` (§7).
- **File descriptors:** bounded by design; reduce workers if `setrlimit`
  fails.
- **Disk full while logging:** log writes are best-effort and never block a
  deletion, but the failure is surfaced.

### The riskiest code in the project

The `getattrlistbulk` buffer parser. It walks a packed binary buffer using
lengths and offsets supplied by the filesystem, in unsafe Rust. One
unchecked offset is a segfault — or worse, a silent misread producing
plausible wrong numbers.

Every offset is bounds-checked against both the entry length and the buffer
length before use. This is the one component that gets fuzzed (§12). Since
the sidecar architecture was rejected, a genuine segfault here takes the
app down; that is the price of the simpler architecture and the reason this
parser earns disproportionate paranoia.

### Rendering

Metal unavailable falls back to a CoreGraphics renderer with zoom animation
disabled — a degraded treemap beats a dialog saying the app won't run.
`MTLBuffer` allocation failure clamps the instance budget and retries.

### Degraded-mode matrix

| Condition | Still works | What the user sees |
|---|---|---|
| No FDA | unprotected scan, treemap, table, reconciliation | **Limited scan** badge, unreadable count, Grant Access |
| FDA granted mid-session | — | relaunch prompt, with the reason |
| `diskutil` unavailable | all but container breakdown | snapshot/container lines show `—` |
| Snapshot list unavailable | everything else | snapshot count `—` |
| Node limit reached | partial treemap, table, deletion | **Partial scan** badge + what was cut |
| Scan cancelled | partial tree, deletion | **Partial** badge; residual suppressed |
| Volume stalled | partial tree | stalled path named; Cancel offered |
| No Metal | treemap, no zoom animation | nothing stated; it looks plain |
| Rust panic | app survives, no tree | error + Copy Diagnostics |

### Diagnostics

A **Scan report** panel, not a modal, always reachable: counts, every
incompleteness flag, every reconciliation caveat, and a Copy Diagnostics
button producing plaintext for a GitHub issue. Diagnostics contain file
paths, so they go to the **clipboard** for the user to review before
pasting, and are never transmitted.

**v1 ships no telemetry** — not even opt-in. For a tool asking strangers
for Full Disk Access, that is worth more than the analytics, and it is
verifiable by anyone reading the source. See §14 for the precise claim,
which Sparkle qualifies.

---

## 12. Testing

Investment follows blast radius: deletion, then the parser, then size
accounting, then reconciliation, then lifetime, then layout, then chrome.

### Fixtures carry the whole strategy

The filesystem *is* the input, so manufacturing filesystem state comes
first.

**Declarative synthetic trees** materialized into a temp directory —
exact-size files, sparse files via `ftruncate`, hardlinks, symlinks,
unreadable directories, deep nesting, long names, and **real APFS clones
via `clonefile(2)`**. That last one makes clone double-counting an
*asserted* behaviour rather than a documented hope.

```rust
tree! {
    "a.bin"        => 4096,
    "dir/" => {
        "b.bin"      => 1_048_576,
        "sparse.bin" => sparse(1 << 30, allocated: 4096),
        "link"       => symlink("../a.bin"),
        "hard"       => hardlink("../a.bin"),
        "copy.bin"   => clone("b.bin"),
        "locked/"    => mode(0o000),
    }
}
```

**Disk images for volume-level tests.** `hdiutil create -fs APFS -size 1g`
plus `hdiutil attach` gives a known, isolated, disposable volume: assert
scanned totals exactly, `fs_snapshot_create` and assert reconciliation sees
it, fill it for disk-full, nest a second image to assert the volume
boundary, detach mid-scan to assert graceful degradation.

Image behaviour can differ subtly from a real internal SSD, so performance
numbers never come from images — only correctness does.

### Rust

- **Parser:** a golden corpus of real `getattrlistbulk` output committed as
  binary fixtures; `cargo-fuzz` on `parse_entries(&[u8])` (60s per PR,
  longer nightly); **ASAN** on parser tests and fuzz runs; **Miri** on the
  parser specifically, since it is pure over a byte buffer and Miri catches
  UB that ASAN misses.
- **Freeze pass — property tests (`proptest`)** over random trees: child
  ranges in bounds; siblings sorted descending; parent and child links
  agree both ways; no index appears twice as a child; rollup equals an
  independently computed sum.
- **Integration:** symlink loops terminate; volume boundaries hold;
  cancellation yields a flagged partial; node limit returns partial rather
  than aborting; hardlinks count once.

**The suite must not run as root** — `chmod 000` is bypassed as root and
every permission test passes for the wrong reason. Assert non-root at
startup.

### Swift

- **`reconcile` — table-driven**, with the **negative residual** case
  first; snapshots unavailable → `nil` rendering as `—`; partial scan →
  residual suppressed; inconsistent capacity/used/free.
- **Guard list — table-driven over paths:** every denied prefix,
  `/usr/local` permitted while `/usr` denied, volume root denied,
  app-bundle ancestor denied, containers warn rather than deny.
- **TOCTOU verification** — pure over (recorded, observed): inode changed,
  device changed, now a symlink, gone.
- **Jetsam ancestry dedup** — property test: no staged set retains both an
  ancestor and its descendant.
- **Layout — property tests:** rects disjoint; rects plus aggregate cover
  the parent within epsilon; area proportional to size within tolerance;
  aspect ratios bounded; tail aggregate is a contiguous suffix; budget
  respected.
- **Overlay arithmetic** — removing a leaf reduces every ancestor by
  exactly its size and no one else.

### Deletion tests need their own containment

A bug in a *deletion test* can destroy the developer's home directory. The
harness gets an independent guard asserting every path handed to
`trashItem` lies under the fixture root — deliberately redundant with the
production guard list, because if production guards regress, the test suite
must not execute the consequences.

### Lifetime, visual, accessibility

- Debug generation counter: release a snapshot, assert access traps. A test
  holding buffers in a background task while dropping the local reference
  must *not* crash, proving ARC ownership holds.
- **Snapshot-test the treemap through the CoreGraphics fallback**, not
  Metal — it exists anyway and is deterministic across machines.
- **Wire the palette validator into CI**, both modes, `--pairs all`. If
  anyone nudges a colour, CI fails. That makes §8's guarantees durable
  rather than a one-time check.
- Assert VoiceOver labels on the table and the focus legend.

### Performance

**Reported, never asserted in CI** — hosted runners are too variable.
`criterion` micro-benchmarks on parser and freeze; a harness against a
generated 500k-file volume on a known machine, with the number committed to
a tracked file so regressions appear in diffs.

### Two deliberate non-goals

**No filesystem abstraction for testability.** A `FileSystem` trait with a
mock would test the mock. Every interesting bug lives in real
`getattrlistbulk` semantics, real clone behaviour, real `EPERM`.

**No broad XCUITest suite.** Instead, inject synthetic `Reconciliation` and
scan-report values and snapshot-test that each row of the degraded-mode
matrix renders correctly.

TDD applies normally during implementation; the above describes the shapes
those tests take.

---

## 13. Open questions for the spike

Everything downstream assumes scan speed. **A short throwaway Rust spike
runs before implementation:** `getattrlistbulk` plus a work-stealing pool
over a real volume, printing wall time and file count. No UI, no tree.

Five things to measure rather than assume:

1. **Actual scan wall time** for 1–2M files. If it is 30 seconds rather
   than 5, the correct architecture is a different one — persistent index,
   background scanning — and that must be known before a UI is built on
   the wrong assumption.
2. **Buffer size knee** — 64 KB vs 256 KB vs 1 MB.
3. **Marginal cost of `ATTR_FILE_RSRCALLOCSIZE`**, which decides whether
   compressed-file accounting can be unconditional.
4. **Direction of `SPACEAVAIL` vs `SPACEFREE`** on APFS, and whether the
   gap really corresponds to purgeable space.
5. **FDA probe behaviour** — that reading `TCC.db` returns `EPERM` without
   FDA and succeeds with it, and that the probe itself triggers no prompt.

Where thread count stops helping falls out of (1).

---

## 14. Build and distribution

### Rust inside Xcode

A Run Script phase calling `cargo` fights Xcode on three fronts: sanitized
`PATH`, `ENABLE_USER_SCRIPT_SANDBOXING` blocking writes to `target/`, and
Xcode not knowing cargo's inputs and outputs.

**Build Rust out-of-band; link a prebuilt `.a`.** A `justfile` runs cargo
then `xcodebuild`. A Run Script phase that *only verifies* — comparing the
`.a`'s mtime against Rust sources, failing with a readable message —
closes the stale-library footgun. Checking is cheap and sandbox-safe;
building is not.

```
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --target aarch64-apple-darwin
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --target x86_64-apple-darwin
lipo -create -output libtesserae.a \
  target/aarch64-apple-darwin/release/libtesserae.a \
  target/x86_64-apple-darwin/release/libtesserae.a
```

Exporting `MACOSX_DEPLOYMENT_TARGET` to match Xcode's setting avoids link
warnings that are easy to ignore until they aren't.

### Signing

```
codesign --force --options runtime --timestamp \
         --sign "Developer ID Application: …" Tesserae.app
xcrun notarytool submit Tesserae.dmg --keychain-profile AC_PASSWORD --wait
xcrun stapler staple Tesserae.dmg
```

Hardened runtime is required for notarization; Rust needs no special
entitlements under it. Ship a **DMG**, signed, notarized and stapled.
Stapling matters for offline first launch — exactly when a Gatekeeper
dialog does the most damage to a tool requesting Full Disk Access.

### Entitlements and Info.plist

**No App Sandbox** — incompatible with whole-disk scanning.

**There is no entitlement that grants Full Disk Access.** FDA is a TCC
grant made by the user in System Settings.
`com.apple.security.files.all` is a *sandbox* entitlement and irrelevant.

Usage-description keys, so a Limited-mode prompt explains itself:
`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
`NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`,
`NSNetworkVolumesUsageDescription`.

### Updates, and the precise privacy claim

Sparkle makes network connections, so "zero network connections" would be
false. The accurate claim, and the one that goes in the README:

> **No telemetry. The only network traffic is the update check.**

Sparkle's appcast request transmits app and macOS version in a user agent.
That is documented precisely, the check is toggleable, and first-launch
disclosure says what it sends.

The alternative — Homebrew and GitHub Releases only, genuinely zero
connections — is rejected: non-brew users would never update, and an
un-updatable tool holding Full Disk Access is the worse outcome. Sparkle
2.x, EdDSA-signed appcast, public key in `SUPublicEDKey`, appcast on GitHub
Pages.

### Homebrew

Start with a personal tap (`brew tap sdelavega/tap`) — homebrew-cask has
notability thresholds a new project won't meet. Graduate later.
`auto_updates true`, since Sparkle handles it.

### Licence mechanics

- GPLv3's **System Libraries exception** covers linking AppKit, Metal and
  Foundation.
- Sparkle is MIT — compatible; its licence ships in the bundle.
- Code signing and notarization do not restrict source rights.
- GPL-3 is incompatible with the Mac App Store, which costs nothing here.
- **`cargo deny check licenses` in CI** with an explicit allowlist.
  `crossbeam-deque`, `rayon` and friends are MIT/Apache and combine into
  GPL-3 fine, but that is enforced rather than assumed as the tree grows.

### Donations

`.github/FUNDING.yml` → GitHub Sponsors: no platform fee, lowest friction
for a GitHub-native project. In-app it is a single "Support Tesserae" menu
item. **No nag, no modal, nothing on launch** — for a GPL tool, nagging
converts goodwill into forks.

Put the $99/yr Developer Program cost in the README. "Donations cover the
Apple Developer account that lets this ship notarized" is a concrete ask.

### CI

**Per PR** (macOS runner): `cargo fmt --check` · `cargo clippy -D warnings`
· `cargo test` · `cargo deny check licenses` · `cargo fuzz run
parse_entries -max_total_time=60` · `xcodebuild test` on the framework
scheme · palette validator · unsigned universal build.

**Nightly** (nightly toolchain): ASAN on parser tests, longer fuzz run.

**On tag `v*`:** both Rust targets → lipo → `xcodebuild archive` →
`-exportArchive` with Developer ID → DMG → sign → notarize → staple →
`generate_appcast` → commit to `gh-pages` → GitHub Release with DMG and
checksums → update the tap.

Secrets: Developer ID `.p12` (base64) and password, notarytool credentials,
Sparkle EdDSA private key. Importing the certificate into a temporary
keychain inside the job is the step that breaks most release pipelines —
get it working before a real release depends on it.

### Repo layout

```
tesserae/
├── Cargo.toml                    workspace
├── crates/
│   ├── tesserae-core/            walk · arena · freeze · dedup
│   └── tesserae-ffi/             staticlib + #[repr(C)] surface
│       └── include/tesserae.h    generated by cbindgen
├── fuzz/
├── apple/
│   ├── Tesserae.xcodeproj
│   ├── Tesserae/                 app target — SwiftUI chrome
│   └── TesseraeKit/              framework — all testable logic
├── scripts/                      build-rust · make-dmg · validate-palette
├── justfile
├── LICENSE                       GPL-3.0
└── docs/superpowers/specs/
```

---

## 15. Competitive context

`reloadlife/ballast` is an existing macOS disk-space app in the same niche:
Swift/SwiftUI, macOS 26, AGPL-3.0, SQLite index with FSEvents change-log
replay, treemap plus sortable table, System Data breakdown, Sparkle. Small
at the time of writing (13 stars, 28 commits), but directly comparable.

Three consequences for Tesserae:

1. **The engine is the wedge.** Ballast is Swift with a SQLite index;
   Tesserae's Rust core and Metal treemap are what it does not have. Speed
   and visual density at scale is a real difference, not a me-too.
2. **Don't match its feature surface.** It competes on breadth — Homebrew
   cleanup, git worktrees, unused apps, duplicates, auto-clean rules,
   widgets, Siri intents. Tesserae competes on scan time, a treemap fluid
   at a million nodes, honest accounting, and restraint around deletion.
3. **AGPL-3.0 means no code may be borrowed** into this GPL-3 project.

Its macOS 26 floor is also an opening: Tesserae's macOS 13 universal build
reaches Intel Macs that cannot upgrade, which are disproportionately the
machines that need a disk visualizer.

---

## 16. Principal risks

| Risk | Mitigation |
|---|---|
| Scan is slower than assumed, invalidating the stateless design | Spike first (§13). A 30-second result changes the architecture, and better now than after a UI exists. |
| Unchecked offset in the bulk parser | Bounds-check against entry and buffer length; fuzz, ASAN, Miri. Accepted residual: a segfault takes the app down. |
| Deletion bug destroys user data | Trash-only; two guard layers; identity re-verification; audit log; independent test containment; no cleanup presets in 1.0. |
| Snapshot use-after-release | Immutability plus ARC ownership plus a debug generation counter. One stated code rule. |
| `diskutil` plist schema drifts across macOS releases | Parse defensively; missing key means unknown, never error; degrades one UI line. |
| FDA onboarding confusion loses users at first run | Design for the relaunch explicitly; Limited scan is labelled, not silent. |
| Donations don't cover the $99/yr | Stated plainly in §1's funding assumption; the project should not depend on donations funding sustained labour. |
| Name crowding hurts discoverability | "Tesserae" is rarer than "Tessera". Trademark not verified — **check USPTO Class 9 before shipping.** |

---

## 17. Next step

Hand off to the writing-plans skill. v1 as scoped in §2 is too large for a
single flat plan, so the plan should be **phased**, each phase independently
verifiable:

| Phase | Deliverable | Gate |
|---|---|---|
| 0 | Throwaway spike (§13) | The five measurements. A slow result re-opens §5. |
| 1 | Rust engine + FFI + snapshot, no UI | Scan a disk image, assert totals; parser fuzzed |
| 2 | Treemap + table + navigation | Fluid zoom on a million-node tree |
| 3 | Reconciliation + scan report + FDA onboarding | Degraded-mode matrix renders correctly |
| 4 | Jetsam + deletion | Full guard-list and TOCTOU test suites green |
| 5 | Build, sign, notarize, Sparkle, tap | A notarized DMG installs and updates cleanly |

Phase 0 gates everything. Phases 1–2 are the product's actual wedge (§15)
and should not be traded away for breadth.
