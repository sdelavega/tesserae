# Tesserae Phase 0–1: Scan Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tested, fuzzed Rust library that scans a macOS volume with
`getattrlistbulk` and produces an immutable snapshot, exposed over a C ABI,
plus a dev CLI that prints totals. No UI.

**Architecture:** Parallel work-stealing traversal using fd-relative
`openat` descent, writing into per-thread chunked bump arenas. A single
freeze pass reorganizes the node soup into a flat array: sizes roll up
bottom-up first, then siblings are sorted, so each directory's children are
contiguous and size-descending. The result is
immutable and handed over the FFI boundary as raw pointers whose lifetime
the caller owns.

**Tech Stack:** Rust 2021, `libc`, `crossbeam-deque`, `proptest` (dev),
`criterion` (dev), `tempfile` (the test-fixture crate), `serde_json` (the
dev CLI), `cargo-fuzz`, and the `cbindgen` CLI (a pinned build tool, not a
dependency). macOS only.

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
- Stall timeout: **15 s** without a completed directory syscall (Task 12).
- `RLIMIT_NOFILE` raised to **4096** at scan start; on failure, reduce
  worker count to fit the existing limit rather than failing.
- Default scan root: `/System/Volumes/Data`.
- **Never request `ATTR_DIR_ALLOCSIZE` or `ATTR_FILE_TOTALSIZE`.** The
  question was asked and settled by measurement, so it does not need
  re-litigating. Neither is a *recursive* total — `getattrlist(2)` has no
  recursive-size attribute at all; both report a single object's own size.
  They are excluded because they add nothing. `ATTR_FILE_ALLOCSIZE` already
  covers every fork of a file. And a directory's own **allocated** size is a
  measured zero: `ATTR_DIR_ALLOCSIZE` is 0 for an empty directory, a
  400-entry directory and `/usr/share` alike, with the bit set in
  `ATTR_CMN_RETURNED_ATTRS`, so it is a real returned value and not an
  unsupplied default. (That APFS keeps directory entries in B-tree records
  rather than a per-directory data fork is the likely *explanation* for the
  zero; it is an inference, was not observed, and nothing depends on it.)
  Note the claim is about allocated bytes only — `ATTR_DIR_DATALENGTH` is
  non-zero (measured 64, 448, 1408, 12864) while the scan reports 0 for a
  directory's logical size, which is correct for a tool whose unit is
  allocated space. A directory's size therefore comes entirely from the
  bottom-up rollup, and adding these bits would change the packed buffer
  layout that Task 4's golden fixtures pin in order to gain a column of
  zeros.
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

Workspace member `crates/tesserae-core`; later tasks add `tesserae-testutil`
(Task 2), `tesserae-ffi` (Task 13) and `tesserae-cli` (Task 14). `fuzz/`
(Task 5) is deliberately *not* a member: it needs nightly and a
sanitizer-instrumented build, which must not leak into `cargo test
--workspace`. `[profile.release]` sets `panic = "unwind"`, `lto = true`,
`codegen-units = 1`. `tesserae-core` depends on `libc`. `LICENSE` is the
GPL-3.0 text. `deny.toml` allows only `MIT`, `Apache-2.0`,
`Apache-2.0 WITH LLVM-exception`, `Unicode-3.0`, `GPL-3.0`,
`GPL-3.0-or-later` (the project's own licence).

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
before any scanning code. It lives in its own dev crate, `tesserae-testutil`,
used as a dev-dependency: that makes it available to core's unit tests,
integration tests and benches and to other crates' tests alike, and keeps it
out of every production artefact. (An in-crate `testutil` module would have
been invisible to `tests/`, `benches/` and `tesserae-cli`.)

**Files:**
- Create: `crates/tesserae-testutil/Cargo.toml`, `src/lib.rs`, `src/tree.rs`
- Modify: root `Cargo.toml` (new workspace member);
  `crates/tesserae-core/Cargo.toml` (`[dev-dependencies]`)
- Test: `crates/tesserae-testutil/src/tree.rs` (inline `#[cfg(test)]`)

**Interfaces:**
- Produces:
  ```rust
  pub struct Fixture { /* TempDir plus the paths chmod-ed, restored on drop */ }
  impl Fixture {
      pub fn new() -> io::Result<Self>;   // panics if run as root
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
  `file` writes dense, non-zero data so every block is really allocated;
  `clone_of` uses `clonefile(2)`; `sparse` uses `ftruncate` with no writes;
  `raw_name` creates a file named by arbitrary bytes. Paths are relative and
  may not contain `..`, so a fixture cannot write outside its root; `chmod`
  refuses to pass through a symlink, and `Drop` restores every chmod-ed path
  so the tree can be deleted.

  The crate also exports the pieces that tests measuring free space need,
  added as later tasks required them: `allocation_lock()` (serialises
  anything that writes real data against a free-space measurement),
  `write_dense_file`, `copy_by_read_write` and `free_bytes`, and `DiskImage`
  (an `hdiutil` image with a `Drop` guard that detaches even on panic; Task 8,
  extended in Task 14).

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn file_has_exact_size() { /* file("a.bin", 4096): len == 4096 and fully allocated */ }

#[test]
fn sparse_file_allocates_less_than_logical() {
    // logical 1 GiB; assert st_size == 1<<30 && st_blocks * 512 < 1<<20
}

#[test]
fn clone_of_makes_distinct_inode() {
    // file("b.bin", 1<<20); clone_of("b.bin", "copy.bin");
    // assert both st_size == 1<<20 and inodes differ
}

#[test]
fn clone_consumes_no_new_space() {
    // 64 MiB file, then clone_of; under allocation_lock(), the volume's free
    // space falls by less than a quarter of the file. Only free space can
    // tell a clone from a copy: their st_blocks are identical.
}

#[test]
fn raw_name_round_trips_exact_bytes() {
    // a valid-UTF-8 name with a precomposed e-acute and a euro sign:
    // raw_name(".", name, 16), then read_dir returns exactly those bytes
    // (the filesystem must not have normalised it)
}
```

There is no fixture for a non-UTF-8 name: macOS rejects invalid UTF-8 at the
syscall boundary (measured: APFS `EILSEQ`, exFAT `EINVAL`), so none can be
created locally. That property is tested with a synthetic buffer (Tasks 4
and 6), and the finding is recorded in a comment on `raw_name`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-testutil`
Expected: FAIL — `Fixture` not defined.

- [ ] **Step 3: Implement `Fixture` in `crates/tesserae-testutil/src/tree.rs`**

`clonefile` is not in `libc`; declare it:
`extern "C" { fn clonefile(src: *const c_char, dst: *const c_char, flags: u32) -> c_int; }`
`raw_name` needs no `unsafe`: `OpenOptions` hands the OS string's bytes to
`open(2)` unchanged. The non-root assertion lives in `Fixture::new`, so it
holds for every consumer, not only for tests in `tesserae-core`'s lib.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-testutil`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml crates/tesserae-core/Cargo.toml crates/tesserae-testutil
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
fn attrlist_requests_returned_attrs() {
    assert_ne!(scan_attrlist().commonattr & libc::ATTR_CMN_RETURNED_ATTRS, 0);
}

#[test]
fn attrlist_requests_no_directory_or_total_size_attributes() {
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

`bitmapcount` must be `libc::ATTR_BIT_MAP_COUNT`. The masks are a format:
they fix the byte layout of every buffer, so changing a bit invalidates
Task 4's golden fixtures. The kernel's packing order is not guaranteed to
follow bit order, so Task 4 derives offsets from captured buffers rather
than from anything assumed here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core attrs`
Expected: PASS (the tests below, and the cases review added).

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
    // synthetic buffer (no filesystem): one entry whose name field holds
    // b"bad\xff\xfename", assembled by hand like the absent-attribute test
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

Read the leading `u32` length, then the `attribute_set_t` of returned
attributes, then each field at a fixed offset measured from the golden
buffers. A directory's entry carries no file-attribute group at all (it is
shorter than the fixed fields), so a slot is used only when two gates
agree: it lies wholly before the name's `attr_dataoffset`, and its returned
bit is set; otherwise the field takes its default. `ATTR_CMN_NAME` arrives as
an `attrreference_t` (`attr_dataoffset: i32`, `attr_length: u32`) whose offset
is relative to the reference's own address — its returned bit is checked
before it is read, and `offset + length` must land inside the entry before
slicing. A zero or overlong entry length returns `BadLength` and ends
iteration, so a malformed buffer cannot cause an infinite loop.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p tesserae-core parse`
Expected: PASS (the tests below, and the cases review added).

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/src/parse.rs crates/tesserae-core/tests/fixtures
git commit -m "feat: bounds-checked getattrlistbulk buffer parser"
```

---

## Task 5: Fuzz, ASAN, and Miri for the parser

**Files:**
- Create: `fuzz/Cargo.toml`, `fuzz/fuzz_targets/parse_entries.rs` (`fuzz/` is
  its own crate, outside the workspace, with its own lockfile)
- Create: `scripts/fuzz-parser.sh`, `scripts/parser-sanitizers.sh`,
  `scripts/nightly-toolchain` (the pinned dated nightly)
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

Run: `scripts/fuzz-parser.sh 30` (runs `cargo +<pinned nightly> fuzz run
parse_entries`, and fails unless seeds were loaded and runs executed)
Expected: no crash; corpus files written to `fuzz/corpus/parse_entries/`.

- [ ] **Step 3: Seed the corpus from the golden buffers**

Copy `crates/tesserae-core/tests/fixtures/golden_*.bin` into
`fuzz/corpus/parse_entries/` and commit them.

- [ ] **Step 4: Verify the parser under Miri**

The parser is pure over a byte buffer, so Miri applies. Add a
`#[cfg(miri)]`-compatible test module that runs the synthetic-buffer cases
only (no syscalls, no fixtures).
Run: `scripts/parser-sanitizers.sh miri` (the pinned nightly, test filter
`parse::tests::synthetic`)
Expected: PASS, no UB reported.

- [ ] **Step 5: Wire CI**

Add `scripts/fuzz-parser.sh 60` to the PR workflow. Create a nightly
workflow running `scripts/parser-sanitizers.sh miri`, `scripts/parser-sanitizers.sh asan`
(an ASAN build of the parser tests) and `scripts/fuzz-parser.sh 900`.
`libfuzzer-sys` is "(MIT OR Apache-2.0) AND NCSA", so `deny.toml` allows
NCSA for that one crate only, and `cargo deny` runs for `fuzz/` separately
(`--manifest-path fuzz/Cargo.toml`), as do `fmt` and `clippy`.

- [ ] **Step 6: Commit**

```bash
git add fuzz scripts .github/workflows deny.toml
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
      pub fn is_empty(&self) -> bool;
      pub fn get(&self, id: ScanId) -> Option<&ScanNode>;
      pub fn get_mut(&mut self, id: ScanId) -> Option<&mut ScanNode>;
      pub fn iter(&self) -> impl Iterator<Item = (ScanId, &ScanNode)> + '_;
      pub fn name_bytes(&self, r: NameRef) -> &[u8];
  }
  ```
  Tasks 7 and 9 add the two walker-set flag bits beside `ScanNode`:
  `FLAG_HARDLINK_DUP` (`1 << 2`) and `FLAG_PERM_DENIED` (`1 << 3`). The walk
  itself does not use an arena's own `node_budget` (it would multiply by the
  worker count); the shared ceiling is a `NodeBudget` in Task 7's module, and
  walkers build their arenas with no ceiling of their own.

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
Expected: PASS (the tests below, and the cases review added).

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
  #[derive(Debug, Clone)]
  pub struct WalkOptions {
      pub root: PathBuf,
      pub max_depth: u16,          // default 512
      pub node_budget: u64,        // default 25_000_000
      pub buffer_bytes: usize,     // default 256 KiB; below 2048 is InvalidInput
      pub include_non_local: bool, // default false
      pub workers: usize,          // default available_parallelism().clamp(4, 16)
      pub stall_timeout: Duration, // default 15 s; Task 12, read only by the pool
  }
  impl Default for WalkOptions { /* defaults above; root = /System/Volumes/Data */ }

  #[derive(Debug, Default)]
  pub struct WalkStats {
      pub dirs: u64,
      pub files: u64,
      pub errors: u64,
      pub unreadable: Vec<PathBuf>,
      pub skipped_mounts: Vec<(PathBuf, SkipReason)>,  // Task 8
      pub depth_capped: u64,
      pub lost_entries: u64,      // entries a malformed batch cost
      pub hardlink_dups: u64,     // Task 9
      pub stalled_at: Option<PathBuf>,                 // Task 12
      pub incomplete: Option<Incomplete>,
  }

  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum Incomplete {
      Cancelled, NodeBudget, OutOfMemory, Stalled,
      FdExhausted,     // EMFILE/ENFILE: some subtrees skipped
      MalformedBatch,  // the parser rejected a getattrlistbulk batch
      VolumeLost,      // Task 14: the scanned volume went away mid-walk
  }

  pub fn walk_serial(opts: &WalkOptions) -> io::Result<(Arena, WalkStats)>;
  ```
  `Err` means nothing could be scanned (bad options, or the root cannot be
  opened, with the OS error number preserved); everything after the root
  opens is absorbed into the stats.

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
`EPERM`/`EACCES` push to `unreadable` and flag the node `FLAG_PERM_DENIED`
(so it renders as locked, not as an empty folder); `ENOENT` and `ENOTDIR`
increment `errors`; `EINTR` retries; `EMFILE`/`ENFILE` and `ENOMEM` set
`incomplete` (`FdExhausted`, `OutOfMemory`) rather than being counted as
churn; a batch the parser rejects sets `MalformedBatch` and adds the entries
it lost to `lost_entries`.

To make Review Focus 3 testable, descent goes through the `DirOpener` trait
(`open_dir_at`) rather than calling `openat` directly. Production uses
`OpenAt`; tests substitute an opener that mutates the tree just before
delegating. A trait, not a `#[cfg(test)]` thread-local, so the parallel
walker's worker threads (Task 11) see the same seam.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core walk`
Expected: PASS (the tests below, and the cases review added).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/walk.rs
git commit -m "feat: single-threaded fd-relative directory walker"
```

---

## Task 8: Boundary and skip policy

An entry's `ATTR_CMN_DEVID` cannot see a mount: read from the parent, a mount
point's entry carries the *covered* directory's device. And `st_dev` does not
separate the sealed system volume from the data volume. So the check is made
on the opened directory: `fstatfs`'s `f_fsid` (both words) is the volume's
identity and its `f_flags` carry `MNT_LOCAL`, one syscall for both questions.

**Files:**
- Create: `crates/tesserae-core/src/boundary.rs`
- Modify: `crates/tesserae-core/src/walk.rs`, `crates/tesserae-testutil/src/diskimage.rs`
  (the minimal `DiskImage` attach/detach helper the end-to-end test needs;
  Task 14 extends it)

**Interfaces:**
- Produces:
  ```rust
  #[derive(Debug, Clone, Copy, PartialEq, Eq)]
  pub enum SkipReason { OtherVolume, NonLocalMount, DepthCap }  // should_descend never returns DepthCap

  pub struct VolumeId([i32; 2]);                          // fstatfs f_fsid
  pub fn volume_of(fd: c_int) -> io::Result<VolumeId>;
  pub fn is_local_mount(fd: c_int) -> io::Result<bool>;   // fstatfs f_flags & MNT_LOCAL
  pub fn should_descend(root_volume: VolumeId, entry_volume: VolumeId, fd: c_int,
                        include_non_local: bool) -> Result<(), SkipReason>;
  ```
  The walker opens the child, takes `volume_of` from the open descriptor, and
  only a change of volume is a crossing: the root's own volume is entered
  without a locality check, deliberately (`include_non_local` governs
  crossing *into* non-local mounts, not scanning the root the caller named).

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn refuses_descent_into_a_different_volume() {
    // a local fd on volume (2, 0) against a root on (1, 0) -> Err(OtherVolume)
}

#[test]
fn allows_descent_within_the_same_volume() {
    // same VolumeId, local fd -> Ok
}

#[test]
fn refuses_non_local_mount_unless_opted_in() {
    // is_local_mount == false -> Err(NonLocalMount); with include_non_local
    // == true -> Ok (the policy table is exercised with the locality
    // question injected, so no mount of each kind is needed)
}

#[test]
fn walk_does_not_cross_into_a_mounted_disk_image() {
    // hdiutil attach a 16 MiB image inside the fixture, put a file on it,
    // assert the file is absent from the walk and stats.skipped_mounts holds
    // (path, SkipReason::OtherVolume); a control walk rooted on the mount
    // point does find the file
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core boundary`
Expected: FAIL — `should_descend` not defined.

- [ ] **Step 3: Implement `boundary.rs` and call `should_descend` from the walker's descent path**

`is_local_mount` and `volume_of` use `fstatfs` on the open fd rather than
`statfs` on a path, so there is no second resolution and no TOCTOU window.
The `openat` into a mount point happens *before* the check and cannot be
avoided, so a hung remote mount can still block a worker before it is
declined; the stall watchdog (Task 12) is the only mitigation.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core boundary`
Expected: PASS (the tests below, and the cases review added).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/boundary.rs crates/tesserae-core/src/walk.rs
git commit -m "feat: volume boundary and non-local mount skip policy"
```

---

## Task 9: Hardlink dedup

Hardlinked files share an inode, so the raw numbers the parser reports would
count their bytes once per link. This task corrects that.

Resource-fork work was removed from this task: `ATTR_FILE_ALLOCSIZE` already
covers all of a file's forks (spec §7 "Size semantics"), so there is no
compressed-file correction and the attribute mask in `attrs.rs` is not
touched.

**Files:**
- Create: `crates/tesserae-core/src/dedup.rs`
- Modify: `crates/tesserae-core/src/walk.rs`, `crates/tesserae-core/src/arena.rs`
  (the flag constant)

**Interfaces:**
- Produces:
  ```rust
  pub struct InodeSet { /* sharded: Vec<Mutex<HashSet<(i32, u64)>>> */ }
  impl InodeSet {
      pub fn new(shards: usize) -> Self;
      pub fn claim(&self, dev: i32, ino: u64) -> bool;   // true on first claim
      pub fn try_claim(&self, dev: i32, ino: u64) -> Result<bool, ReserveFailed>;
      pub fn len(&self) -> usize;
      pub fn is_empty(&self) -> bool;
  }
  pub struct ReserveFailed;

  // arena.rs: set on every link after the first, which is stored with zero sizes
  pub const FLAG_HARDLINK_DUP: u16 = 1 << 2;
  // WalkStats::hardlink_dups counts them
  ```
  `try_claim` is what the walker calls: if the set cannot reserve memory the
  link keeps its bytes (the total errs high, never low) and
  `incomplete = OutOfMemory` says so. `claim` hides that shortfall.

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
    // assert stats.files == 2 but total allocated ~= 1 MiB, and exactly one
    // node carries FLAG_HARDLINK_DUP (which one depends on walk order; only
    // the total and the count are invariant)
}

#[test]
fn set_stays_empty_when_no_file_has_link_count_above_one() {
    // 100-file fixture, no hardlinks; assert set.len() == 0
}

// and: directories never enter the set (they report link_count 0); the set
// is exactly-once under contention from threads started together.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core -- dedup`
Expected: FAIL — `InodeSet` not defined.

- [ ] **Step 3: Implement `InodeSet` and gate insertion on `link_count > 1` in the walker**

The gate is the point: inserting every inode would make the set megabytes
large and a contention hotspot. Hardlinks are rare, so the set stays nearly
empty.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core -- dedup`
Expected: PASS (the tests below, and the cases review added).

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/dedup.rs crates/tesserae-core/src/walk.rs
git commit -m "feat: hardlink dedup"
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
  pub fn try_freeze(arenas: Vec<Arena>, stats: WalkStats)
      -> Result<Snapshot, FreezeError>;

  pub enum FreezeError { OutOfMemory, NamesTooLarge }
  ```
  `Vec<Arena>`, not one — Task 11's parallel walker produces one arena per
  worker, and `ScanId`'s thread field is what disambiguates them. Serial
  callers pass `vec![arena]`. `try_freeze` is the real entry point: every
  allocation goes through `try_reserve_exact`, so an allocation failure (or a
  name total above `u32::MAX` bytes, which `name_off` cannot address) is an
  error, not an abort; the FFI and the CLI call it. `freeze` panics where
  `try_freeze` errs, and is for callers with nowhere to report. No arenas, or
  only empty ones, give a snapshot with no nodes and `root == NODE_NONE`.

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

Six passes: build a `ScanId -> u32` mapping across all worker arenas; count
children per parent and prefix-sum the counts into per-parent ranges;
scatter nodes into their parent's range; **roll sizes up bottom-up; then**
sort each sibling range descending by `allocated`; then emit the sorted tree
breadth-first, which fixes every final index and makes each parent's
children contiguous.

**The rollup comes first and the sort second.** Arena directories carry
`allocated == 0` until they are rolled up, so sorting first would put every
directory last. Ties on `allocated` break by name and then by index, so equal
sizes still freeze to one deterministic order.

The mapping pass is what makes multiple arenas work — `ScanId`'s thread
field selects the arena, and the chunk and slot fields index within it.

Prefix sums must handle a zero-length child list without an off-by-one —
that is what Review Focus 5 pins.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core freeze`
Expected: PASS (the unit tests, seven property tests, and
`tests/freeze_oom.rs`, which fails each allocation in turn).

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
- Modify: `crates/tesserae-core/src/walk.rs` (the pieces the pool shares live
  there so there is one walk and not two: `Walker`, `NodeBudget`, `Halt`),
  `crates/tesserae-core/Cargo.toml` (`crossbeam-deque`)

**Interfaces:**
- Produces:
  ```rust
  pub fn walk(opts: &WalkOptions) -> io::Result<(Vec<Arena>, WalkStats)>;
  ```
  `walk_serial` stays, as the reference implementation the tests compare
  against. (Task 12's `walk_with_progress` is the same walk with live
  counters and cancellation; the FFI and CLI call that.)

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

`setrlimit` is process-wide, so that last test is `#[ignore]`d in the suite
and runs on its own, one thread, nothing beside it:
`cargo test -p tesserae-core --lib -- --ignored --exact --test-threads=1
pool::tests::raises_nofile_limit_and_falls_back_to_fewer_workers`. The pool
module carries further equivalence tests: frozen bytes identical to the serial
walk's on a hardlink-free tree, the node budget shared across workers, one
worker's failed push halting the whole walk, unreadable paths exact deep in
stolen subtrees, and a swapped ancestor not redirecting a reopened directory.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core pool`
Expected: FAIL — `walk` not defined.

- [ ] **Step 3: Implement the pool in `crates/tesserae-core/src/pool.rs`**

`crossbeam-deque`: one `Worker` per thread, `Stealer`s shared, plus an
`Injector` seeded with the root. Each worker descends depth-first with
fd-relative opens and publishes only the *sibling* directories it is not
about to enter. Each worker owns an `Arena` tagged with its thread index.

**Published tasks carry root-relative paths.** The fd chain is thread-local,
so a stolen task carries an `Arc<Path>` relative to the scan root, and the
worker that takes it reopens it with
`openat(root_fd, rel, O_NOFOLLOW_ANY | O_DIRECTORY | O_CLOEXEC)` beneath a
root fd held open for the whole walk. A symlink in any component of `rel`,
including an ancestor swapped in after enumeration, fails the open (`ELOOP`)
instead of redirecting the walk, which keeps the serial walker's property
that nothing above the root is ever resolved twice. (Probed on macOS 27.2
only; whether a 13.x kernel honours the flag is unverified. A relative path
longer than `PATH_MAX` cannot be reopened that way; such a directory is kept
and descended locally, never dropped.) Termination is counted in tasks created
and not yet completed, not in idle workers.

**One budget, one halt.** The node ceiling is a shared `NodeBudget` (an
atomic drawn in chunks of 1,024), not a per-arena limit, which would multiply
by the worker count. Any worker's failed push (budget or out of memory) halts
the *whole* walk through a shared `Halt`: the hardlink set records an inode
before its node is pushed, so a worker carrying on after another's failed
push could leave a claimed inode whose node was never stored, and those bytes
would vanish from the total.

Raise `RLIMIT_NOFILE` to 4096 at entry; if the limit in force is still below
4096, set `workers = max(1, (soft_limit - 32) / (max_depth + 1))` (capped at
the request). With the limit raised, the requested count stands even though
`workers * (max_depth + 1)` can exceed it; `Incomplete::FdExhausted` is the
safety net for a tree that deep.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core pool`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/tesserae-core/src/pool.rs crates/tesserae-core/src/walk.rs Cargo.toml
git commit -m "feat: work-stealing parallel walker"
```

---

## Task 12: Progress, cancellation, OOM, and stall detection

**Files:**
- Create: `crates/tesserae-core/src/progress.rs`
- Modify: `crates/tesserae-core/src/pool.rs`, `crates/tesserae-core/src/walk.rs`
  (the per-worker arena lock and syscall announcement live there),
  `crates/tesserae-core/src/arena.rs` (`ScanId::to_bits`/`from_bits`, so a
  worker can publish the id it is blocked on in an atomic)

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

`WalkOptions` gains `stall_timeout: Duration` (default 15 s) here.

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
    // every worker's arena refuses its 6th node as if the allocator had
    // refused a chunk (a test-only per-arena limit); assert the walk returns
    // Ok with stats.incomplete == Some(Incomplete::OutOfMemory), the nodes
    // stored before the refusal intact, and no panic
}

#[test]
fn watchdog_reports_the_path_a_worker_stalled_on() {
    // injected opener that blocks on one directory for 3s; stall_timeout = 1s
    // assert stats.stalled_at == Some(".../slow"), stats.incomplete ==
    // Some(Incomplete::Stalled), and that the walk RETURNED BEFORE the
    // blocked open did (abandonment, not waiting)
}

#[test]
fn watchdog_does_not_fire_on_a_merely_slow_but_progressing_walk() {
    // 2000-file fixture, stall_timeout = 1s, per-entry delay well under it
    // assert stats.stalled_at.is_none()
}

#[test]
fn cancel_returns_promptly_while_a_worker_is_blocked() {
    // user cancel with a worker stuck in an open: returns well before the
    // open does, flagged Cancelled
}

#[test]
fn watchdog_names_a_blocked_reopen_across_arenas() {
    // the stalled directory, its parent and the root sit in different
    // workers' arenas; stalled_at is still the full path
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core progress`
Expected: FAIL — `Progress` not defined.

- [ ] **Step 3: Implement `Progress` and check cancellation at directory boundaries in the worker loop**

Counters are `Relaxed`; the cancel flag is `Acquire`/`Release`. Workers
publish their counts once per `getattrlistbulk` batch from per-worker locals,
not per entry (sixteen workers hitting one cache line per entry would cost
more than the scan); the counters equal the result exactly once the walk has
returned. A `Progress` is single-use: a cancel is never undone.

A worker's `ArenaError` (like any failed push) halts every worker, but the
walk still *returns* the partial result flagged `Incomplete::OutOfMemory` —
never an `Err`, never a panic. Cancellation is checked at directory and batch
boundaries; the calling thread, which would otherwise only wait, is the
monitor: every 10 ms it copies the walk's counters into the caller's
`Progress` and turns a cancel into the shared halt.

- [ ] **Step 4: Implement the stall watchdog**

Spec §11 requires it: a hanging local volume blocks `openat`
uninterruptibly, and the user must be told which path rather than watching
a frozen progress display.

Each worker has an `AtomicU64` holding the `ScanId` of the directory it is
inside a syscall on (or idle). The monitor — the calling thread, ticking
every 10 ms — measures progress as **completed directory syscalls** (open,
read, `fstatfs`, close) across all workers, not the public counters. If that
has not advanced for `stall_timeout` while some worker is inside one, it
resolves that directory's absolute path, records it in `stalled_at`, and
raises the halt as `Incomplete::Stalled`.

**The blocked thread cannot be killed.** The walk is abandoned, not
stopped, and that needs a design that never joins every worker:

- Workers are unscoped threads; everything they touch is owned behind one
  `Arc` (opener, hardlink set, budget, halt, counters, the root fd, the
  lanes), so a worker left behind keeps what it needs alive.
- Each worker's arena sits behind a per-worker mutex that the worker holds
  while it mutates and **releases across every directory syscall**. So when
  the walk ends, the supervisor can lock a stuck worker's arena and *take*
  it. Taking it, rather than dropping it, keeps every other arena's parent
  links from dangling at freeze. A stuck worker that returns finds its slot
  gone (and the halt up) and exits without touching anything.
- The walk is over when every worker has finished or, once the halt is up,
  is inside a syscall. The same abandonment happens after any early end, so a
  user cancel also returns at once while a worker is blocked.

What the result is missing is the stuck worker's whole unfinished descent
chain, not just one directory. A hung **root** open is not covered: the root
is opened on the calling thread before any worker exists (the FFI calls the
walk from its scan thread, so the app stays responsive). A panic in an
abandoned worker after the walk has returned is lost by design. Document all
of that on `stall_timeout` — it is a deliberate limitation from spec §11, not
a bug to fix later.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test -p tesserae-core progress`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core/src/progress.rs crates/tesserae-core/src/pool.rs \
        crates/tesserae-core/src/walk.rs crates/tesserae-core/src/arena.rs
git commit -m "feat: atomic progress, cancellation, OOM recovery, and stall watchdog"
```

---

## Task 13: FFI surface

**Files:**
- Create: `crates/tesserae-ffi/Cargo.toml`, `crates/tesserae-ffi/src/lib.rs`
- Create: `crates/tesserae-ffi/cbindgen.toml`, `crates/tesserae-ffi/include/tesserae.h`
- Create: `scripts/gen-header.sh`, `scripts/check-shipped-lib.sh`
- Create: `crates/tesserae-ffi/tests/abi_layout.rs`, `crates/tesserae-ffi/tests/release_frees.rs`
- Create: `crates/tesserae-core/src/test_hooks.rs`
- Modify: root `Cargo.toml`, `crates/tesserae-core/Cargo.toml` (the `test-hooks`
  feature), `crates/tesserae-core/src/lib.rs`, `.github/workflows/ci.yml`

There is no `build.rs`. A build script that writes into the source tree on
every build is wrong, and `cbindgen` as a build-dependency would enter
`cargo deny`'s graph (it is MPL-2.0, outside the allowlist). The header is
generated by `scripts/gen-header.sh`, which runs the **cbindgen CLI pinned at
0.29.4** (a build tool, not a dependency: nothing of it is linked or shipped)
and refuses any other version, because cbindgen's output varies between
releases.

**Interfaces:**
- Consumes: everything above.
- Produces the C ABI in spec §6, verbatim: `tess_abi_version`,
  `tess_scan_begin`, `tess_scan_progress`, `tess_scan_cancel`,
  `tess_scan_finish`, `tess_snapshot_view`, `tess_snapshot_release`, plus
  `TessView`, `TessProgress`, `TessScanOptions`, and three additions the spec
  had no way around:
  ```c
  int32_t        tess_scan_status(const TessScan*);       // 0 running, 1 finished, -errno failed
  void           tess_snapshot_stats(const TessSnapshot*, TessScanStats* out);
  const uint8_t* tess_snapshot_stalled_at(const TessSnapshot*, uint64_t* len_out);
  ```
  `tess_scan_status` lets the app poll instead of blocking in finish and
  says why a scan failed, preserving the kernel's errno (`-EPERM`, macOS
  refusing a protected folder, stays distinct from `-EACCES`, which Full Disk
  Access cannot fix). `tess_snapshot_stats` is the only way to read
  `Snapshot.stats`: an `incomplete` code plus counts, which §7 and §11 need
  the UI to show. `tess_snapshot_stalled_at` is the stalled directory as
  borrowed bytes, not a C string. `TessScanOptions` is read as "0 = default"
  per field (a null pointer is all defaults); `include_non_local` is a `u8`,
  not a `bool`, so no value a C caller can write is invalid. `TessNode` is
  `tesserae-core`'s, exported into the header.
- Threading: `tess_scan_progress`, `tess_scan_cancel` and `tess_scan_status`
  may be called from any thread while the scan runs. `tess_scan_finish`
  consumes the handle and must not race any other call on it; after a cancel
  it is prompt, except while the root itself hangs in `open`, which is why the
  app polls `tess_scan_status`.

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
    // the view points into the snapshot's own Vecs, before and after an
    // unrelated allocation
}

#[test]
fn null_handle_arguments_return_errors_rather_than_dereferencing() {
    assert!(tess_scan_finish(std::ptr::null_mut()).is_null());
}

#[test]
fn a_worker_panic_is_caught_and_reported_as_null() {
    // arm the PanicOnce hook (the non-default `test-hooks` cargo feature of
    // tesserae-core, enabled only from tesserae-ffi's dev-dependencies);
    // assert status is -EIO, tess_scan_finish returns null, process survives
}
```

`#[cfg(test)]` would not work for the panic injection: it is not active in
`tesserae-core` when `tesserae-ffi`'s tests compile it. A feature in a
dev-dependency is not enabled for a normal build, and
`scripts/check-shipped-lib.sh` checks that the shipped library carries no
hook (cargo's feature resolution, plus the hook's panic message absent from
the archive, with a hooks-on control build so the search is known to work).

Further unit tests cover: scan options reaching the walk, zero options meaning
the defaults, the `TESS_INCOMPLETE_*` codes covering every `Incomplete`
variant, every stat landing in its own field, and a failed scan keeping its
errno end to end (a `chmod 000` root reads `-EACCES`; a wrapped `EPERM` reads
`-EPERM`). `tests/abi_layout.rs` compiles a small C file that includes the
header with `xcrun clang` and `_Static_assert`s the size, alignment and field
offsets of `TessNode`, `TessView`, `TessProgress`, `TessScanOptions` and
`TessScanStats` against values the Rust side asserts too, with a negative
control. `tests/release_frees.rs` checks that releasing a snapshot returns its
memory.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-ffi`
Expected: FAIL — crate does not exist.

- [ ] **Step 3: Implement the FFI surface in `crates/tesserae-ffi/src/lib.rs`**

`crate-type = ["staticlib", "rlib"]`. `tess_scan_begin` starts a scan
thread that runs `walk_with_progress` and then `try_freeze` (never `freeze`:
an allocation failure is a failed scan, `-ENOMEM`), with one fresh `Progress`
per scan. Every `extern "C"` body, and the scan thread's whole
walk-and-freeze, runs inside `std::panic::catch_unwind`. The pool's workers
carry no guard of their own: a worker panic unwinds only its own Rust thread
(it is never called from C), raises the shared halt, and is resumed into the
scan thread, whose guard catches it — a failed scan, `-EIO`. (A panic in a
worker abandoned after the walk has returned is lost by design.) No panic
crosses the boundary; that needs `panic = "unwind"`. `tess_scan_finish` joins
the scan thread, boxes the `Snapshot` and returns an opaque pointer;
`tess_snapshot_release` reclaims it with `Box::from_raw`. The shipped library
must be built with exactly `cargo build -p tesserae-ffi --release`; building
test targets would unify the hooks into it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-ffi`
Expected: PASS (17 unit tests, 2 layout tests, 1 release test).

- [ ] **Step 5: Generate and check in the header**

Run `scripts/gen-header.sh` (install the pinned tool with
`cargo install cbindgen --version 0.29.4 --locked`) to write
`crates/tesserae-ffi/include/tesserae.h`. Add a CI step that regenerates it
and `git diff --exit-code`s it, so ABI drift fails the build; `abi_layout`
then checks that the committed header has the layout the Rust types do.

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-ffi crates/tesserae-core scripts Cargo.toml .github/workflows/ci.yml
git commit -m "feat: C ABI surface with cbindgen header and panic isolation"
```

---

## Task 14: Disk-image integration harness, CLI, and benchmarks

**Files:**
- Create: `crates/tesserae-core/tests/volume.rs`
- Create: `crates/tesserae-cli/Cargo.toml`, `crates/tesserae-cli/src/main.rs`,
  `crates/tesserae-cli/tests/cli.rs`
- Create: `crates/tesserae-core/benches/scan.rs`
- Create: `scripts/lib.sh`, `scripts/gen-bench-volume.sh`, `scripts/bench-volume.sh`
- Create: `docs/benchmarks.md`, `justfile`
- Modify: `crates/tesserae-testutil/src/diskimage.rs` (extends the Task 8
  `DiskImage`), `crates/tesserae-core/src/walk.rs` (the volume-lost check),
  `crates/tesserae-ffi/src/lib.rs` (its incomplete code), and the Task 5 and
  13 scripts (each now sources `scripts/lib.sh`)

**Interfaces:**
- Produces: `tesserae-cli scan <path> [--json] [--workers N] [--max-depth N]
  [--node-budget N]`, printing dirs, files, logical and allocated totals,
  elapsed time, and every `WalkStats` incompleteness field. Exit status:
  `0` the scan completed, `2` a partial result (the totals are printed with
  the reason), `1` nothing was scanned. `--json` writes one object; paths are
  emitted lossily (invalid UTF-8 becomes U+FFFD).
- The `justfile` is a thin index: each recipe is one `cargo` command or a call
  to a script in `scripts/`, and CI runs the same scripts, so a recipe and a CI
  step cannot drift apart. `scripts/lib.sh` puts `$HOME/.cargo/bin` first on
  `PATH` (Homebrew's cargo can precede it and ignores `rust-toolchain.toml`),
  and every script that runs cargo sources it.
- A scan whose volume is lost mid-walk is `Incomplete::VolumeLost`: after a
  directory-level failure with an errno a vanished volume can produce
  (`ENOENT`, `ENOTDIR`, `EIO`, `ENXIO`, `ENODEV`, `EBADF`, `ENOTSUP`) the
  walker asks the root's held descriptor which volume it is on (`fstatfs`); if
  that fails or names another volume, the walk stops. On a live volume the
  same errnos stay ordinary churn in `errors`. Without this a detached image
  came back as a "complete" scan missing a third of its tree, because `ENOTDIR`
  on a dead descriptor is also what a directory replaced by a file gives.

- [ ] **Step 1: Write the failing integration tests**

```rust
#[test]
fn scans_a_known_disk_image_to_exact_totals() {
    // hdiutil create -fs APFS -size 64m; attach; write 3 files of known size;
    // assert files == 3 and allocated sum matches within one block
}

#[test]
fn reports_incomplete_when_the_image_detaches_mid_scan() {
    // force-detach during the walk, with a tree big enough that the walk is
    // still running (retried with a bigger tree a bounded number of times,
    // else a loud failure); assert incomplete == Some(Incomplete::VolumeLost),
    // errors > 0, the partial result still freezes, and the whole test is
    // bounded by a deadline so it cannot hang
}

#[test]
fn clones_make_the_tree_sum_exceed_the_volume_delta() {
    // 8 MiB file plus 4 clonefile copies on the image; under allocation_lock,
    // assert the volume's free-space delta stays near 8 MiB while the tree
    // allocated sum is 40 MiB, proving spec §7's "clones are not solvable"
    // claim is the observed behaviour. Control: the same with 4 real
    // read/write copies, where tree and volume agree.
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test -p tesserae-core --test volume`
Expected: FAIL — helpers not defined.

- [ ] **Step 3: Implement the image harness and the CLI**

The harness is `tesserae-testutil`'s `DiskImage`, extended (not duplicated):
`hdiutil create`/`attach`/`detach` with a `Drop` guard that detaches even on
panic, so a failed test never leaves an image mounted. The CLI is thin: parse
args, build `WalkOptions`, run `walk_with_progress`, `try_freeze` (never
`freeze`), print.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test -p tesserae-core --test volume && cargo run -p tesserae-cli -- scan .`
Expected: PASS (4 tests: the three above and the real-copies control), and
the CLI prints totals for the repo directory.

- [ ] **Step 5: Add criterion benchmarks and record a baseline**

Bench `parse::entries` over the golden buffers and `freeze` over a synthetic
100k-node arena. Generate a 500k-file volume with `scripts/gen-bench-volume.sh`
and time the CLI on it with `scripts/bench-volume.sh` (`just bench-volume`).
The method, the criterion and CLI numbers, the worker-count sweep and the
`/System/Volumes/Data` reconciliation against `du -sxk` are recorded in
`docs/benchmarks.md`. **Reported, not asserted** — CI runners are too
variable to gate on.

- [ ] **Step 6: Commit**

```bash
git add crates/tesserae-core crates/tesserae-cli crates/tesserae-testutil \
        crates/tesserae-ffi scripts docs/benchmarks.md justfile Cargo.toml Cargo.lock
git commit -m "test: disk-image integration harness, dev CLI, and benchmarks"
```

---

## Phase exit criteria

- `cargo test --workspace` green (plus the serialized `setrlimit` test);
  `cargo clippy --workspace --all-targets -- -D warnings` clean; `just gate`
  runs CI's whole sequence.
- `scripts/fuzz-parser.sh 900` finds no crash.
- Miri and ASAN jobs (`scripts/parser-sanitizers.sh miri|asan`) green on the
  parser.
- `tesserae-cli scan /System/Volumes/Data` completes and prints totals that
  reconcile against `du -sxk` (same volume, no crossing) within
  clone-explained variance.
- A measured scan time recorded in `docs/benchmarks.md`.
- `crates/tesserae-ffi/include/tesserae.h` committed and current:
  `scripts/gen-header.sh` (pinned cbindgen) leaves no diff.

Phase 2 (treemap, table, navigation) gets its own plan, written once these
criteria are met.
