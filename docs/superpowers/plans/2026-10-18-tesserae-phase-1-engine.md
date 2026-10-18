# Tesserae Phase 0–1: Scan Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested, fuzzed Rust library that scans a macOS volume with
`getattrlistbulk` and produces an immutable snapshot, exposed over a C ABI,
plus a dev CLI that prints totals. No UI.

**Architecture:** Parallel work-stealing traversal using fd-relative
`openat` descent, writing into per-thread chunked bump arenas. A single
freeze pass reorganizes the node soup into a flat array with contiguous,
size-descending children and bottom-up size rollups. The result is
immutable and handed over the FFI boundary as raw pointers whose lifetime
the caller owns.

**Tech Stack:** Rust 2021, `libc`, `crossbeam-deque`, `proptest` (dev),
`criterion` (dev), `cargo-fuzz`, `cbindgen`. macOS only.

**Spec:** `docs/superpowers/specs/2026-10-18-tesserae-design.md`

## Global Constraints

Every task's requirements implicitly include these. Values are copied
verbatim from the spec.

- Deployment target `MACOSX_DEPLOYMENT_TARGET=13.0`; universal binary
  (`aarch64-apple-darwin` + `x86_64-apple-darwin`).
- Release profile pins `panic = "unwind"`. With `abort`, a bad symlink
  kills the host app.
- All chunk allocation uses `try_reserve`. Rust aborts the process on
  allocation failure by default; OOM must arrive as a `Result`.
- Default depth cap: **512**. Default node budget: **25_000_000**. Chunk
  size: **65_536** nodes.
- Worker count: `available_parallelism()` clamped to **4..=16**.
- `RLIMIT_NOFILE` raised to **4096** at scan start; on failure, reduce
  worker count to fit the existing limit rather than failing.
- Default scan root: `/System/Volumes/Data`.
- **Never request a recursive-size attribute** (`ATTR_DIR_ALLOCSIZE` and
  similar).
- `TessNode` is exactly the eight fields in spec §6, `#[repr(C)]`, 40 bytes
  aligned. No field may be added in this phase.
- Every source file carries a GPL-3.0 header. `LICENSE` is GPL-3.0.
- `cargo deny check licenses` passes against an explicit allowlist.
- The test suite asserts non-root at startup. As root, `chmod 000` is
  bypassed and permission tests pass for the wrong reason.

## Review Focus

Input classes the spec implies but does not state, most likely to bite
first. Each has a test pinned to the task that owns the code.

1. **Non-UTF-8 filenames.** The parser's input is a byte buffer and must
   never assume UTF-8: nothing may panic, and name bytes must round-trip
   through the name arena unchanged. Such names are unreachable through
   any local fixture, because macOS rejects invalid UTF-8 at the syscall
   boundary (measured: APFS `EILSEQ` (92), exFAT `EINVAL` (22)). They
   remain reachable only via removable media or network mounts written by
   another OS. The property is therefore tested synthetically, with a
   buffer fed straight to the parser (Task 4), not via a fixture file.
   → Tasks 4 and 6.
2. **`ATTR_CMN_RETURNED_ATTRS` reporting an absent attribute.** The parser
   must substitute a default, not read garbage at a shifted offset. A
   silent misread here produces plausible wrong sizes. → Task 4.
3. **`ENOTDIR` on descent.** A directory enumerated as a directory, then
   replaced by a file before `openat`. The spec covers `ENOENT` but not
   this. → Task 7.
4. **A single directory with more entries than one buffer holds.** The
   `getattrlistbulk` loop must continue to exhaustion, and an entry must
   never straddle a call boundary. → Task 7.
5. **An empty root.** The freeze pass runs prefix sums over zero children;
   an off-by-one here panics on the first real use. → Task 10.

---

## Task 0: Spike — measure before building (THROWAWAY)

**This task's code is deleted when it ends.** Its deliverable is five
numbers written into the spec, not software.

**Files:**
- Create: `spike/` (deleted in Step 5)

- [ ] **Step 1: Write a single-file Rust binary that walks a path with `getattrlistbulk` and prints elapsed time and file count**

No tests, no error handling beyond `eprintln!`, no abstraction. Single
thread first, then a crude thread pool. Hardcode everything.

- [ ] **Step 2: Measure, on a real volume with at least 1M files**

Record: wall time and file count; wall time at buffer sizes 64 KB, 256 KB
and 1 MB; wall time with and without `ATTR_FILE_RSRCALLOCSIZE`; wall time
at 1, 4, 8, 16 threads.

- [ ] **Step 3: Probe the two API semantics the spec flags as unverified**

Print `ATTR_VOL_SPACEAVAIL` and `ATTR_VOL_SPACEFREE` for the data volume
and record which is larger. Attempt to open
`~/Library/Application Support/com.apple.TCC/TCC.db` with and without Full
Disk Access granted, and record the errno and whether any prompt appears.

- [ ] **Step 4: Write findings into spec §13, replacing the open questions with measured values**

**GATE:** If the 1M-file scan exceeds ~10 seconds, stop. The spec's
stateless design (§3) no longer holds and §5 must be reopened before any
further task runs.

- [ ] **Step 5: Delete `spike/` and commit the spec update**

```bash
rm -rf spike
git add docs/superpowers/specs/2026-10-18-tesserae-design.md
git commit -m "docs: record spike measurements in design spec"
```

---

## Task 1: Workspace scaffold

**Files:**
- Create: `Cargo.toml`, `LICENSE`, `deny.toml`, `rust-toolchain.toml`
- Create: `crates/tesserae-core/Cargo.toml`, `crates/tesserae-core/src/lib.rs`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces: the `tesserae_core` crate root; workspace release profile with
  `panic = "unwind"`.

- [ ] **Step 1: Write the failing test**

```rust
// crates/tesserae-core/src/lib.rs
#[cfg(test)]
mod tests {
    #[test]
    fn suite_does_not_run_as_root() {
        assert_ne!(unsafe { libc::geteuid() }, 0,
                   "tests must not run as root: chmod 000 is bypassed and \
                    permission tests pass for the wrong reason");
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p tesserae-core`
Expected: FAIL — no `libc` dependency.

- [ ] **Step 3: Create the workspace**

Workspace members `crates/tesserae-core` and `fuzz` (added in Task 5).
`[profile.release]` sets `panic = "unwind"`, `lto = true`,
`codegen-units = 1`. `tesserae-core` depends on `libc`. `LICENSE` is the
GPL-3.0 text. `deny.toml` allows only `MIT`, `Apache-2.0`,
`Apache-2.0 WITH LLVM-exception`, `Unicode-3.0`, `GPL-3.0`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p tesserae-core && cargo deny check licenses`
Expected: PASS, and no licence violations.

- [ ] **Step 5: Add the CI workflow**

macOS runner. Steps: `cargo fmt --check`, `cargo clippy -- -D warnings`,
`cargo test`, `cargo deny check licenses`.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml LICENSE deny.toml rust-toolchain.toml crates .github
git commit -m "chore: workspace scaffold with GPL-3 licence and CI"
```

---

## Task 2: Test fixture builder

Everything downstream needs manufactured filesystem state. This comes
before any scanning code.

**Files:**
- Create: `crates/tesserae-core/src/testutil/mod.rs`
- Create: `crates/tesserae-core/src/testutil/tree.rs`
- Test: `crates/tesserae-core/src/testutil/tree.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces:
  ```rust
  pub struct Fixture { root: TempDir }
  impl Fixture {
      pub fn new() -> io::Result<Self>;
      pub fn path(&self) -> &Path;
      pub fn file(&self, rel: &str, len: u64) -> io::Result<&Self>;
      pub fn sparse(&self, rel: &str, logical: u64) -> io::Result<&Self>;
      pub fn clone_of(&self, src: &str, dst: &str) -> io::Result<&Self>;
      pub fn hardlink(&self, src: &str, dst: &str) -> io::Result<&Self>;
      pub fn symlink(&self, target: &str, dst: &str) -> io::Result<&Self>;
      pub fn dir(&self, rel: &str) -> io::Result<&Self>;
      pub fn chmod(&self, rel: &str, mode: u32) -> io::Result<&Self>;
      pub fn raw_name(&self, dir: &str, name: &[u8], len: u64) -> io::Result<&Self>;
  }
  ```
  `clone_of` uses `clonefile(2)`; `sparse` uses `ftruncate` with no writes;
  `raw_name` creates a file whose name is arbitrary bytes.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn file_has_exact_size() { /* fixture.file("a.bin", 4096); assert metadata().len() == 4096 */ }

#[test]
fn sparse_file_allocates_less_than_logical() {
    // logical 1 GiB; assert st_size == 1<<30 && st_blocks * 512 < 1<<20
}

#[test]
fn clonefile_shares_blocks() {
    // file("b.bin", 1<<20); clone_of("b.bin", "copy.bin");
    // assert both st_size == 1<<20 and inodes differ
}

#[test]
fn raw_name_accepts_non_utf8_bytes() {
    // raw_name(".", b"bad\xff\xfename", 16) then read_dir finds a 16-byte entry
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core testutil`
Expected: FAIL — `Fixture` not defined.

- [ ] **Step 3: Implement `Fixture` in `crates/tesserae-core/src/testutil/tree.rs`**

`clonefile` is not in `libc`; declare it:
`extern "C" { fn clonefile(src: *const c_char, dst: *const c_char, flags: c_int) -> c_int; }`
Use `CString::from_vec_unchecked` for `raw_name` so non-UTF-8 bytes survive.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core testutil`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/testutil
git commit -m "test: filesystem fixture builder with clonefile and sparse support"
```

---

## Task 3: Attribute request construction

**Files:**
- Create: `crates/tesserae-core/src/attrs.rs`

**Interfaces:**
- Produces:
  ```rust
  pub const SCAN_OPTIONS: u64;        // FSOPT_PACK_INVAL_ATTRS | FSOPT_NOFOLLOW
  pub fn scan_attrlist() -> libc::attrlist;
  pub const COMMON_MASK: u32;
  pub const FILE_MASK: u32;
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn attrlist_requests_returned_attrs_first() {
    assert_ne!(scan_attrlist().commonattr & libc::ATTR_CMN_RETURNED_ATTRS, 0);
}

#[test]
fn attrlist_requests_no_recursive_size_attributes() {
    let a = scan_attrlist();
    assert_eq!(a.dirattr & libc::ATTR_DIR_ALLOCSIZE, 0);
    assert_eq!(a.fileattr & libc::ATTR_FILE_TOTALSIZE, 0);
}

#[test]
fn attrlist_requests_the_nine_spec_attributes() {
    // assert each of ATTR_CMN_{RETURNED_ATTRS,NAME,OBJTYPE,FILEID,DEVID,FLAGS}
    // and ATTR_FILE_{DATALENGTH,ALLOCSIZE,LINKCOUNT} is set
}

#[test]
fn scan_options_set_pack_inval_and_nofollow() {
    assert_eq!(SCAN_OPTIONS,
               (libc::FSOPT_PACK_INVAL_ATTRS | libc::FSOPT_NOFOLLOW) as u64);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core attrs`
Expected: FAIL — `scan_attrlist` not defined.

- [ ] **Step 3: Implement in `crates/tesserae-core/src/attrs.rs`**

`bitmapcount` must be `libc::ATTR_BIT_MAP_COUNT`. Attribute ordering in the
returned buffer follows the mask bit order, which Task 4 depends on.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core attrs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/attrs.rs
git commit -m "feat: getattrlistbulk attribute request construction"
```

---

## Task 4: The bulk-buffer parser

Spec §11 names this the riskiest code in the project. Every offset is
bounds-checked against both the entry length and the buffer length before
use.

**Files:**
- Create: `crates/tesserae-core/src/parse.rs`
- Create: `crates/tesserae-core/tests/fixtures/` (golden buffers)

**Interfaces:**
- Consumes: `attrs::{scan_attrlist, SCAN_OPTIONS}` from Task 3.
- Produces:
  ```rust
  #[derive(Debug, Clone, PartialEq)]
  pub struct RawEntry<'a> {
      pub name: &'a [u8],
      pub obj_type: ObjType,
      pub file_id: u64,
      pub dev_id: i32,
      pub flags: u32,
      pub logical: u64,
      pub allocated: u64,
      pub link_count: u32,
  }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum ObjType { Reg, Dir, Lnk, Other }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum ParseError { Truncated, BadLength, NameOutOfBounds }

  pub struct EntryIter<'a>;
  impl<'a> Iterator for EntryIter<'a> { type Item = Result<RawEntry<'a>, ParseError>; }

  pub fn entries(buf: &[u8], count: u32) -> EntryIter<'_>;
  ```

- [ ] **Step 1: Capture a golden corpus**

A `#[test]` gated behind `--ignored` that calls `getattrlistbulk` on a
`Fixture` tree and writes the raw buffer plus its entry count to
`tests/fixtures/golden_<name>.bin`. Commit the outputs.

- [ ] **Step 2: Write the failing tests**

```rust
#[test]
fn parses_golden_buffer_into_expected_entries() {
    // golden_simple.bin built from file("a.bin", 4096) + dir("d")
    // assert names, obj_types, and allocated sizes
}

#[test]
fn preserves_non_utf8_names_as_bytes() {            // Review Focus 1
    // golden_nonutf8.bin from raw_name(".", b"bad\xff\xfename", 16)
    // assert entry.name == b"bad\xff\xfename"   (no panic, no lossy conversion)
}

#[test]
fn absent_attribute_yields_default_not_shifted_read() {   // Review Focus 2
    // synthetic buffer whose returned_attrs omits ATTR_FILE_ALLOCSIZE
    // assert allocated == 0 and logical is still read correctly
}

#[test]
fn rejects_entry_length_exceeding_buffer() {
    assert_eq!(entries(&[0xFF, 0xFF, 0xFF, 0x7F], 1).next(),
               Some(Err(ParseError::BadLength)));
}

#[test]
fn rejects_zero_entry_length() { /* ParseError::BadLength, and does not loop forever */ }

#[test]
fn rejects_name_reference_pointing_outside_entry() {
    // ParseError::NameOutOfBounds
}

#[test]
fn stops_at_count_even_if_buffer_has_more_bytes() { /* yields exactly `count` items */ }

#[test]
fn empty_buffer_yields_no_entries() { assert!(entries(&[], 0).next().is_none()); }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cargo test -p tesserae-core parse`
Expected: FAIL — `entries` not defined.

- [ ] **Step 4: Implement `entries` and `EntryIter` in `crates/tesserae-core/src/parse.rs`**

Read the leading `u32` length, then `attribute_set_t` of returned
attributes, then fields in mask-bit order. `ATTR_CMN_NAME` arrives as an
`attrreference_t` (`attr_dataoffset: i32`, `attr_length: u32`) whose offset
is relative to the reference's own address — validate that
`offset + length` lands inside the entry before slicing. A zero or
overlong entry length returns `BadLength` and ends iteration, so a
malformed buffer cannot cause an infinite loop.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p tesserae-core parse`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/src/parse.rs crates/tesserae-core/tests/fixtures
git commit -m "feat: bounds-checked getattrlistbulk buffer parser"
```

---

## Task 5: Fuzz, ASAN, and Miri for the parser

**Files:**
- Create: `fuzz/Cargo.toml`, `fuzz/fuzz_targets/parse_entries.rs`
- Modify: `.github/workflows/ci.yml`
- Create: `.github/workflows/nightly.yml`

**Interfaces:**
- Consumes: `parse::entries` from Task 4.

- [ ] **Step 1: Write the fuzz target**

```rust
fuzz_target!(|data: &[u8]| {
    if data.len() < 4 { return; }
    let count = u32::from(data[0]);
    for e in tesserae_core::parse::entries(&data[1..], count) {
        let _ = e.map(|e| (e.name.len(), e.allocated));
    }
});
```

- [ ] **Step 2: Run it briefly to confirm the harness works**

Run: `cargo fuzz run parse_entries -- -max_total_time=30`
Expected: no crash; corpus files written to `fuzz/corpus/parse_entries/`.

- [ ] **Step 3: Seed the corpus from the golden buffers**

Copy `crates/tesserae-core/tests/fixtures/golden_*.bin` into
`fuzz/corpus/parse_entries/` and commit them.

- [ ] **Step 4: Verify the parser under Miri**

The parser is pure over a byte buffer, so Miri applies. Add a
`#[cfg(miri)]`-compatible test module that runs the synthetic-buffer cases
only (no syscalls, no fixtures).
Run: `cargo +nightly miri test -p tesserae-core parse::tests::synthetic`
Expected: PASS, no UB reported.

- [ ] **Step 5: Wire CI**

Add `cargo fuzz run parse_entries -- -max_total_time=60` to the PR
workflow. Create a nightly workflow running the Miri test, an ASAN build
(`RUSTFLAGS="-Zsanitizer=address"`) of the parser tests, and a 15-minute
fuzz run.

- [ ] **Step 6: Commit**

```bash
git add fuzz .github/workflows
git commit -m "test: fuzz, ASAN and Miri coverage for the buffer parser"
```

---

## Task 6: Chunked arena

**Files:**
- Create: `crates/tesserae-core/src/arena.rs`

**Interfaces:**
- Produces:
  ```rust
  pub const CHUNK_NODES: usize = 65_536;

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub struct ScanId(u64);              // (thread:16 | chunk:24 | slot:24)
  impl ScanId { pub const NONE: ScanId; }

  #[derive(Debug, Clone, Copy)]
  pub struct ScanNode {
      pub name: NameRef,
      pub parent: ScanId,
      pub obj_type: ObjType,
      pub flags: u16,
      pub logical: u64,
      pub allocated: u64,
  }

  #[derive(Debug, Clone, Copy)]
  pub struct NameRef { pub chunk: u32, pub off: u32, pub len: u16 }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum ArenaError { OutOfMemory, NodeBudgetExceeded }

  pub struct Arena { /* per-thread chunk lists */ }
  impl Arena {
      pub fn new(thread: u16, node_budget: u64) -> Self;
      pub fn push_name(&mut self, bytes: &[u8]) -> Result<NameRef, ArenaError>;
      pub fn push_node(&mut self, n: ScanNode) -> Result<ScanId, ArenaError>;
      pub fn len(&self) -> u64;
      pub fn get(&self, id: ScanId) -> Option<&ScanNode>;
      pub fn name_bytes(&self, r: NameRef) -> &[u8];
  }
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn scan_id_round_trips_thread_chunk_slot() {
    // pack(7, 1234, 56789) then assert the three accessors return those values
}

#[test]
fn push_node_returns_increasing_ids_across_chunk_boundary() {
    // push CHUNK_NODES + 1 nodes; assert chunk index increments exactly once
}

#[test]
fn existing_node_references_survive_chunk_growth() {
    // hold the ScanId of node 0, push CHUNK_NODES + 1 more, assert get() still
    // returns the original node unchanged
}

#[test]
fn name_bytes_round_trip_non_utf8() {              // Review Focus 1
    let r = arena.push_name(b"bad\xff\xfename").unwrap();
    assert_eq!(arena.name_bytes(r), b"bad\xff\xfename");
}

#[test]
fn push_node_past_budget_returns_node_budget_exceeded() {
    // Arena::new(0, 10); push 11; assert Err(ArenaError::NodeBudgetExceeded)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core arena`
Expected: FAIL — `Arena` not defined.

- [ ] **Step 3: Implement `Arena` in `crates/tesserae-core/src/arena.rs`**

Chunks are `Vec<ScanNode>` allocated with `Vec::try_reserve_exact` then
filled; name chunks are `Vec<u8>`. **No `Vec::push` on a chunk that may
grow** — growth means allocating a new chunk, never reallocating an
existing one, which is what makes `get()` stable across growth.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core arena`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/arena.rs
git commit -m "feat: chunked bump arena with try_reserve and stable references"
```

---

## Task 7: Single-threaded walker

Correctness before parallelism. Task 11 parallelizes this without changing
its observable behaviour.

**Files:**
- Create: `crates/tesserae-core/src/walk.rs`

**Interfaces:**
- Consumes: `attrs`, `parse::entries`, `arena::{Arena, ScanNode, ScanId}`.
- Produces:
  ```rust
  pub struct WalkOptions {
      pub root: PathBuf,
      pub max_depth: u16,          // default 512
      pub node_budget: u64,        // default 25_000_000
      pub buffer_bytes: usize,     // default from Task 0's measurement
      pub include_non_local: bool, // default false
      pub workers: usize,          // default available_parallelism().clamp(4, 16)
  }
  impl Default for WalkOptions { /* defaults above; root = /System/Volumes/Data */ }

  #[derive(Debug, Default)]
  pub struct WalkStats {
      pub dirs: u64,
      pub files: u64,
      pub errors: u64,
      pub unreadable: Vec<PathBuf>,
      pub skipped_mounts: Vec<PathBuf>,
      pub depth_capped: u64,
      pub stalled_at: Option<PathBuf>,
      pub incomplete: Option<Incomplete>,
  }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum Incomplete { Cancelled, NodeBudget, OutOfMemory, Stalled }

  pub fn walk_serial(opts: &WalkOptions) -> io::Result<(Arena, WalkStats)>;
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn counts_files_and_sums_allocated_size() {
    // fixture: a.bin 4096, d/b.bin 1 MiB
    // assert stats.files == 2 && total allocated >= 1 MiB + 4096
}

#[test]
fn does_not_follow_symlinks() {
    // fixture: dir "d", symlink "d/loop" -> ".."
    // assert the walk terminates and the symlink is counted as one entry
}

#[test]
fn records_unreadable_directory_without_failing() {
    // fixture: dir "secret" chmod 000
    // assert stats.unreadable.len() == 1 and the walk completes
}

#[test]
fn survives_directory_replaced_by_file_before_open() {   // Review Focus 3
    // inject an ENOTDIR by swapping the entry between enumeration and open
    // (use a hook on the open call); assert stats.errors == 1, walk completes
}

#[test]
fn enumerates_a_directory_larger_than_one_buffer() {     // Review Focus 4
    // fixture: 5000 files in one dir, buffer_bytes = 4096
    // assert stats.files == 5000
}

#[test]
fn stops_at_depth_cap() {
    // fixture: 20 nested dirs, max_depth = 5
    // assert stats.depth_capped > 0 and no node deeper than 5 exists
}

#[test]
fn returns_incomplete_node_budget_when_budget_is_hit() {
    // node_budget = 3 over a 10-file fixture
    // assert stats.incomplete == Some(Incomplete::NodeBudget)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core walk`
Expected: FAIL — `walk_serial` not defined.

- [ ] **Step 3: Implement `walk_serial` in `crates/tesserae-core/src/walk.rs`**

Explicit stack of `(dirfd, ScanId, depth)`, descending with
`openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)` and
closing each fd when its subtree is done — so the open-fd chain is bounded
by depth, not by tree size. Loop `getattrlistbulk` until it returns 0; an
entry never straddles calls because the kernel only writes whole entries.
`EPERM`/`EACCES` push to `unreadable`; `ENOENT` and `ENOTDIR` increment
`errors`; `EINTR` retries.

To make Review Focus 3 testable, descent goes through a
`#[cfg(test)]`-injectable open hook rather than calling `openat` directly.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core walk`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/walk.rs
git commit -m "feat: single-threaded fd-relative directory walker"
```

---

## Task 8: Boundary and skip policy

**Files:**
- Create: `crates/tesserae-core/src/boundary.rs`
- Modify: `crates/tesserae-core/src/walk.rs`

**Interfaces:**
- Produces:
  ```rust
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum SkipReason { OtherVolume, NonLocalMount, DepthCap }

  pub fn is_local_mount(fd: c_int) -> io::Result<bool>;   // statfs f_flags & MNT_LOCAL
  pub fn should_descend(root_dev: i32, entry_dev: i32, fd: c_int,
                        include_non_local: bool) -> Result<(), SkipReason>;
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn refuses_descent_into_a_different_device() {
    assert_eq!(should_descend(1, 2, -1, false), Err(SkipReason::OtherVolume));
}

#[test]
fn allows_descent_within_the_same_device() {
    assert!(should_descend(1, 1, local_fd, false).is_ok());
}

#[test]
fn refuses_non_local_mount_unless_opted_in() {
    // same dev, is_local_mount == false -> Err(NonLocalMount)
    // and with include_non_local == true -> Ok
}

#[test]
fn walk_does_not_cross_into_a_mounted_disk_image() {
    // hdiutil attach a 16 MiB image inside the fixture, put a file on it,
    // assert the file is absent from the walk and stats.skipped_mounts has 1
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core boundary`
Expected: FAIL — `should_descend` not defined.

- [ ] **Step 3: Implement `boundary.rs` and call `should_descend` from the walker's descent path**

`is_local_mount` uses `fstatfs` on the open fd rather than `statfs` on a
path, so there is no second resolution and no TOCTOU window.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core boundary`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/boundary.rs crates/tesserae-core/src/walk.rs
git commit -m "feat: volume boundary and non-local mount skip policy"
```

---

## Task 9: Size correctness — hardlink dedup and compressed files

Two corrections to the raw numbers the parser reports. Both are
size-accuracy concerns, so they share a task.

**Files:**
- Create: `crates/tesserae-core/src/dedup.rs`
- Create: `crates/tesserae-core/src/compressed.rs`
- Modify: `crates/tesserae-core/src/walk.rs`, `crates/tesserae-core/src/attrs.rs`

**Interfaces:**
- Produces:
  ```rust
  pub struct InodeSet { /* sharded: Vec<Mutex<HashSet<(i32, u64)>>> */ }
  impl InodeSet {
      pub fn new(shards: usize) -> Self;
      pub fn claim(&self, dev: i32, ino: u64) -> bool;   // true on first claim
      pub fn len(&self) -> usize;
  }

  /// Returns the allocated size to record, consulting the resource fork
  /// when `UF_COMPRESSED` is set and the data fork reports ~zero.
  pub fn effective_allocated(flags: u32, data_alloc: u64, rsrc_alloc: u64) -> u64;
  pub const UF_COMPRESSED: u32 = 0x0000_0020;
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn first_claim_is_true_and_repeat_is_false() {
    let s = InodeSet::new(4);
    assert!(s.claim(1, 42));
    assert!(!s.claim(1, 42));
}

#[test]
fn same_inode_on_different_devices_claims_separately() {
    // claim(1, 42) and claim(2, 42) both true
}

#[test]
fn hardlinked_file_is_counted_once_in_a_walk() {
    // fixture: a.bin 1 MiB, hardlink a.bin -> b.bin
    // assert stats.files == 2 but total allocated ~= 1 MiB, and the second
    // node carries the clone/dedup flag
}

#[test]
fn set_stays_empty_when_no_file_has_link_count_above_one() {
    // 100-file fixture, no hardlinks; assert set.len() == 0
}

#[test]
fn uncompressed_file_uses_the_data_fork_size() {
    assert_eq!(effective_allocated(0, 8192, 0), 8192);
}

#[test]
fn compressed_file_with_empty_data_fork_uses_the_resource_fork() {
    assert_eq!(effective_allocated(UF_COMPRESSED, 0, 4096), 4096);
}

#[test]
fn compressed_file_with_both_forks_sums_them() {
    assert_eq!(effective_allocated(UF_COMPRESSED, 4096, 4096), 8192);
}

#[test]
fn walk_of_a_compressed_system_file_reports_nonzero_allocated() {
    // scan /usr/share/man (contains UF_COMPRESSED files on a stock system);
    // assert no scanned regular file with UF_COMPRESSED has allocated == 0
    // while logical > 0.  Skipped with a clear message if no such file exists.
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core -- dedup compressed`
Expected: FAIL — `InodeSet` and `effective_allocated` not defined.

- [ ] **Step 3: Implement `InodeSet` and gate insertion on `link_count > 1` in the walker**

The gate is the point: inserting every inode would make the set megabytes
large and a contention hotspot. Hardlinks are rare, so the set stays nearly
empty.

- [ ] **Step 4: Implement `effective_allocated` and add `ATTR_FILE_RSRCALLOCSIZE` to the request**

Spec §7 flags compressed files as a known accounting trap: `UF_COMPRESSED`
files report a near-zero data fork with the real bytes in the resource
fork, and `/usr` and `/System` are full of them.

**Whether the attribute is requested unconditionally depends on Task 0's
third measurement.** If its marginal cost is negligible, request it
always. If not, add a `WalkOptions::resource_fork_sizes: bool` defaulting
to true and let the caller trade accuracy for speed. Record which way you
went, and why, in a comment on `effective_allocated`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p tesserae-core -- dedup compressed`
Expected: PASS (8 tests).

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/src/dedup.rs crates/tesserae-core/src/compressed.rs \
        crates/tesserae-core/src/walk.rs crates/tesserae-core/src/attrs.rs
git commit -m "feat: hardlink dedup and compressed-file resource fork sizing"
```

---

## Task 10: Freeze pass

**Files:**
- Create: `crates/tesserae-core/src/freeze.rs`
- Create: `crates/tesserae-core/src/node.rs`

**Interfaces:**
- Consumes: `arena::{Arena, ScanId}`, `walk::WalkStats`.
- Produces:
  ```rust
  #[repr(C)]
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub struct TessNode {
      pub name_off: u32,
      pub name_len: u16,
      pub flags: u16,
      pub parent: u32,
      pub child_start: u32,
      pub child_count: u32,
      pub logical: u64,
      pub allocated: u64,
  }
  pub const NODE_NONE: u32 = u32::MAX;

  pub struct Snapshot {
      pub nodes: Vec<TessNode>,
      pub names: Vec<u8>,
      pub root: u32,
      pub stats: WalkStats,
  }

  pub fn freeze(arenas: Vec<Arena>, stats: WalkStats) -> Snapshot;
  ```
  `Vec<Arena>`, not one — Task 11's parallel walker produces one arena per
  worker, and `ScanId`'s thread field is what disambiguates them. Serial
  callers pass `vec![arena]`.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn tess_node_is_forty_bytes() {
    assert_eq!(std::mem::size_of::<TessNode>(), 40);
}

#[test]
fn empty_root_freezes_to_a_single_childless_node() {    // Review Focus 5
    let s = freeze(vec![empty_arena_with_root()], WalkStats::default());
    assert_eq!(s.nodes.len(), 1);
    assert_eq!(s.nodes[0].child_count, 0);
    assert_eq!(s.nodes[0].parent, NODE_NONE);
}

#[test]
fn merges_nodes_from_multiple_worker_arenas() {
    // two arenas tagged thread 0 and thread 1, each holding part of one tree;
    // assert the frozen array contains every node exactly once and all
    // parent links resolve
}

#[test]
fn siblings_are_contiguous_and_sorted_descending_by_allocated() { /* ... */ }

#[test]
fn directory_allocated_equals_sum_of_descendants() { /* ... */ }

#[test]
fn name_offsets_resolve_to_the_original_bytes() { /* incl. non-UTF-8 */ }
```

Property tests (`proptest`) over randomly generated trees:

```rust
proptest! {
    #[test] fn every_child_range_is_in_bounds(t in arb_tree()) { /* ... */ }
    #[test] fn parent_and_child_links_agree(t in arb_tree()) { /* ... */ }
    #[test] fn no_index_appears_twice_as_a_child(t in arb_tree()) { /* ... */ }
    #[test] fn rollup_matches_independent_sum(t in arb_tree()) { /* ... */ }
    #[test] fn siblings_sorted_descending(t in arb_tree()) { /* ... */ }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core freeze`
Expected: FAIL — `freeze` not defined.

- [ ] **Step 3: Implement `freeze` in `crates/tesserae-core/src/freeze.rs`**

Five sub-passes: build a `ScanId -> u32` mapping across all worker arenas;
count children per parent; prefix-sum into `child_start`; scatter nodes
into the final array by parent; sort each sibling range descending by
`allocated`, then roll sizes up bottom-up.

The mapping pass is what makes multiple arenas work — `ScanId`'s thread
field selects the arena, and the chunk and slot fields index within it.

Prefix sums must handle a zero-length child list without an off-by-one —
that is what Review Focus 5 pins.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core freeze`
Expected: PASS (6 unit + 5 property tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/freeze.rs crates/tesserae-core/src/node.rs
git commit -m "feat: freeze pass producing contiguous size-sorted snapshot"
```

---

## Task 11: Work-stealing pool

Parallelizes Task 7 without changing observable behaviour. The tests are
the equivalence tests.

**Files:**
- Create: `crates/tesserae-core/src/pool.rs`
- Modify: `crates/tesserae-core/src/walk.rs`, `Cargo.toml`

**Interfaces:**
- Produces:
  ```rust
  pub fn walk(opts: &WalkOptions) -> io::Result<(Vec<Arena>, WalkStats)>;
  ```
  `walk_serial` stays, as the reference implementation the tests compare
  against.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn parallel_walk_matches_serial_walk_totals() {
    // 3000-file fixture across 50 dirs; assert files, dirs and total allocated
    // are identical between walk_serial and walk
}

#[test]
fn parallel_walk_is_deterministic_after_freeze() {
    // run walk twice, freeze both, assert the node arrays are equal
    // (freeze's sibling sort is what makes this true despite scan order)
}

#[test]
fn raises_nofile_limit_and_falls_back_to_fewer_workers() {
    // set RLIMIT_NOFILE to 64, request 16 workers, assert the walk succeeds
    // and the effective worker count was reduced
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core pool`
Expected: FAIL — `walk` not defined.

- [ ] **Step 3: Implement the pool in `crates/tesserae-core/src/pool.rs`**

`crossbeam-deque`: one `Worker` per thread, `Stealer`s shared, plus an
`Injector` seeded with the root. Each worker descends depth-first with
fd-relative opens and pushes only *sibling* directories for stealing; a
stolen task carries an `Arc<Path>` since the fd chain is thread-local. Each
worker owns an `Arena` tagged with its thread index.

Raise `RLIMIT_NOFILE` to 4096 at entry; if `setrlimit` fails, set
`workers = max(1, (soft_limit - 32) / max_depth)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core pool`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/pool.rs crates/tesserae-core/src/walk.rs Cargo.toml
git commit -m "feat: work-stealing parallel walker"
```

---

## Task 12: Progress, cancellation, OOM, and stall detection

**Files:**
- Create: `crates/tesserae-core/src/progress.rs`
- Modify: `crates/tesserae-core/src/pool.rs`

**Interfaces:**
- Produces:
  ```rust
  #[derive(Debug, Default)]
  pub struct Progress {
      pub dirs: AtomicU64,
      pub files: AtomicU64,
      pub bytes: AtomicU64,
      pub errors: AtomicU64,
      cancelled: AtomicBool,
  }
  impl Progress {
      pub fn snapshot(&self) -> ProgressValues;
      pub fn cancel(&self);
      pub fn is_cancelled(&self) -> bool;
  }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub struct ProgressValues { pub dirs: u64, pub files: u64, pub bytes: u64, pub errors: u64 }

  pub fn walk_with_progress(opts: &WalkOptions, p: &Progress)
      -> io::Result<(Vec<Arena>, WalkStats)>;
  ```

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn progress_counters_advance_during_a_walk() {
    // poll from another thread; assert files is non-zero before completion
    // and equals stats.files afterwards
}

#[test]
fn cancellation_returns_a_partial_snapshot_flagged_cancelled() {
    // cancel after the first 100 files; assert stats.incomplete ==
    // Some(Incomplete::Cancelled) and the arena holds fewer nodes than the fixture
}

#[test]
fn arena_out_of_memory_surfaces_as_incomplete_not_a_panic() {
    // node_budget 5 with an injected ArenaError::OutOfMemory;
    // assert stats.incomplete == Some(Incomplete::OutOfMemory) and no panic
}

#[test]
fn watchdog_reports_the_path_a_worker_stalled_on() {
    // injected open hook that sleeps 3s on "slow/"; stall_timeout = 1s
    // assert stats.stalled_at == Some(".../slow") and
    // stats.incomplete == Some(Incomplete::Stalled)
}

#[test]
fn watchdog_does_not_fire_on_a_merely_slow_but_progressing_walk() {
    // 2000-file fixture, stall_timeout = 1s, per-entry delay well under it
    // assert stats.stalled_at.is_none()
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core progress`
Expected: FAIL — `Progress` not defined.

- [ ] **Step 3: Implement `Progress` and check cancellation at directory boundaries in the worker loop**

Counters are `Relaxed`; the cancel flag is `Acquire`/`Release`. An
`ArenaError` in a worker sets `incomplete` and drains rather than
propagating, so one worker's OOM does not abort the others' results.

- [ ] **Step 4: Implement the stall watchdog**

Spec §11 requires it: a hanging local volume blocks `openat`
uninterruptibly, and the user must be told which path rather than watching
a frozen progress display.

Add `WalkOptions::stall_timeout: Duration` (default 15s) and an
`AtomicU64` per worker holding the path id it is currently descending into.
A monitor thread polls every second; if total progress has not advanced
within `stall_timeout`, it records the offending path in `stalled_at`, sets
`Incomplete::Stalled`, and signals cancellation.

**The blocked thread cannot be killed.** The walk is abandoned, not
stopped: remaining workers drain and results return, while the stuck
thread leaks until its syscall returns or the process exits. Document that
on `stall_timeout` — it is a deliberate limitation from spec §11, not a bug
to fix later.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p tesserae-core progress`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/src/progress.rs crates/tesserae-core/src/pool.rs
git commit -m "feat: atomic progress, cancellation, OOM recovery, and stall watchdog"
```

---

## Task 13: FFI surface

**Files:**
- Create: `crates/tesserae-ffi/Cargo.toml`, `crates/tesserae-ffi/src/lib.rs`
- Create: `crates/tesserae-ffi/cbindgen.toml`, `crates/tesserae-ffi/build.rs`
- Modify: `Cargo.toml`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: everything above.
- Produces the C ABI in spec §6, verbatim: `tess_abi_version`,
  `tess_scan_begin`, `tess_scan_progress`, `tess_scan_cancel`,
  `tess_scan_finish`, `tess_snapshot_view`, `tess_snapshot_release`, plus
  `TessView`, `TessProgress`, `TessScanOptions`.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn abi_version_is_nonzero_and_stable() { assert_eq!(tess_abi_version(), 1); }

#[test]
fn scan_finish_yields_a_view_whose_counts_match_the_node_array() {
    // begin/finish over a fixture; assert view.count == nodes.len()
    // and view.root is a valid index
}

#[test]
fn view_pointers_stay_valid_until_release() {
    // read nodes[0] before and after an unrelated allocation; assert equal
}

#[test]
fn null_handle_arguments_return_errors_rather_than_dereferencing() {
    assert!(tess_scan_finish(std::ptr::null_mut()).is_null());
}

#[test]
fn a_worker_panic_is_caught_and_reported_as_null() {
    // inject a panic in the worker loop behind #[cfg(test)];
    // assert tess_scan_finish returns null and the process survives
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-ffi`
Expected: FAIL — crate does not exist.

- [ ] **Step 3: Implement the FFI surface in `crates/tesserae-ffi/src/lib.rs`**

`crate-type = ["staticlib", "rlib"]`. Every `extern "C"` body is wrapped in
`std::panic::catch_unwind`, **and each worker closure in the pool carries
its own** — by the time workers run, the entry-point guard has returned.
`tess_scan_finish` boxes the `Snapshot` and returns an opaque pointer;
`tess_snapshot_release` reclaims it with `Box::from_raw`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-ffi`
Expected: PASS (5 tests).

- [ ] **Step 5: Generate and check in the header**

`build.rs` runs `cbindgen` into `include/tesserae.h`. Add a CI step that
regenerates and `git diff --exit-code`s it, so ABI drift fails the build.

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-ffi Cargo.toml .github/workflows/ci.yml
git commit -m "feat: C ABI surface with cbindgen header and panic isolation"
```

---

## Task 14: Disk-image integration harness, CLI, and benchmarks

**Files:**
- Create: `crates/tesserae-core/tests/volume.rs`
- Create: `crates/tesserae-cli/Cargo.toml`, `crates/tesserae-cli/src/main.rs`
- Create: `crates/tesserae-core/benches/scan.rs`
- Modify: `justfile`

**Interfaces:**
- Produces: `tesserae-cli scan <path> [--json]` printing dirs, files,
  totals, elapsed time, and every `WalkStats` incompleteness field.

- [ ] **Step 1: Write the failing integration tests**

```rust
#[test]
fn scans_a_known_disk_image_to_exact_totals() {
    // hdiutil create -fs APFS -size 64m; attach; write 3 files of known size;
    // assert files == 3 and allocated sum matches within one block
}

#[test]
fn reports_incomplete_when_the_image_detaches_mid_scan() {
    // detach during the walk; assert the walk returns an error or a flagged
    // partial, and does not hang or panic
}

#[test]
fn clones_make_the_tree_sum_exceed_the_volume_delta() {
    // 8 MiB file plus 4 clonefile copies on the image;
    // assert tree allocated sum > (volume used delta), proving spec §7's
    // "clones are not solvable" claim is the observed behaviour
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core --test volume`
Expected: FAIL — helpers not defined.

- [ ] **Step 3: Implement the image harness and the CLI**

Harness wraps `hdiutil create`/`attach`/`detach` with a `Drop` guard that
detaches even on panic, so a failed test never leaves an image mounted.
The CLI is thin: parse args, build `WalkOptions`, run
`walk_with_progress`, `freeze`, print.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core --test volume && cargo run -p tesserae-cli -- scan .`
Expected: PASS (3 tests), and the CLI prints totals for the repo directory.

- [ ] **Step 5: Add criterion benchmarks and record a baseline**

Bench `parse::entries` over a golden buffer and `freeze` over a synthetic
100k-node arena. Run against a generated 500k-file volume and commit the
wall time to `docs/benchmarks.md`. **Reported, not asserted** — CI runners
are too variable to gate on.

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/tests crates/tesserae-cli \
        crates/tesserae-core/benches docs/benchmarks.md justfile
git commit -m "test: disk-image integration harness, dev CLI, and benchmarks"
```

---

## Phase exit criteria

- `cargo test` green; `cargo clippy -- -D warnings` clean.
- `cargo fuzz run parse_entries -max_total_time=900` finds no crash.
- Miri and ASAN jobs green on the parser.
- `tesserae-cli scan /System/Volumes/Data` completes and prints totals that
  reconcile against `du -sh` within clone-explained variance.
- A measured scan time recorded in `docs/benchmarks.md`.
- `include/tesserae.h` committed and matching a fresh `cbindgen` run.

Phase 2 (treemap, table, navigation) gets its own plan, written once these
criteria are met.
