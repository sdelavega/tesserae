// Tesserae: a disk-space visualizer.
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! Fault injection for the tests of crates that drive the walker.
//!
//! Compiled only with the `test-hooks` cargo feature, which no normal build
//! enables: `tesserae-ffi` turns it on in `[dev-dependencies]`, so it reaches
//! that crate's tests and nothing that ships. With the feature off this module
//! and the call into it from the worker loop do not exist.
//!
//! A hook is armed for one scan root and acts only in a walk of exactly that
//! root. Tests in one process run in parallel, each on its own temporary
//! directory, so a hook keyed by root cannot reach a neighbour's walk the way a
//! global "panic next" switch would.

use std::path::{Path, PathBuf};

/// Present in a binary exactly when this module is compiled in.
///
/// `scripts/check-shipped-lib.sh` searches the shipped static library for these
/// bytes. It cannot search for a hook's panic message instead: whole-program
/// LTO may prove the hook registry is never written outside tests and delete
/// that message even from a build that has the hooks. `#[used]` keeps this
/// symbol through compilation and `#[no_mangle]` exports it from the static
/// library, so the optimiser cannot remove it.
#[used]
#[no_mangle]
pub static TESSERAE_TEST_HOOKS_PRESENT: [u8; 27] = *b"tesserae-test-hooks-present";
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// What an armed hook does in the worker loop, just before a worker runs a task.
#[derive(Debug, Clone, Copy)]
pub enum Action {
    /// Panic in the first worker to take a task, once; later tasks run normally.
    PanicOnce,
    /// Sleep this long before every task: holds a scan open long enough for a
    /// test to observe it running and to cancel it.
    DelayEachTask(Duration),
}

struct Entry {
    root: PathBuf,
    action: Action,
    fired: Arc<AtomicU64>,
}

static HOOKS: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

/// An armed hook. Disarms when dropped.
#[must_use = "the hook is disarmed as soon as this is dropped"]
pub struct Armed {
    fired: Arc<AtomicU64>,
}

impl Armed {
    /// How many times the hook has acted. A test asserts this so that it
    /// cannot pass for a scan the hook never touched.
    pub fn fired(&self) -> u64 {
        self.fired.load(Ordering::Acquire)
    }
}

impl Drop for Armed {
    fn drop(&mut self) {
        HOOKS
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|e| !Arc::ptr_eq(&e.fired, &self.fired));
    }
}

/// Arm `action` for walks of exactly `root`, compared as the path the walk was
/// given.
pub fn arm(root: &Path, action: Action) -> Armed {
    let fired = Arc::new(AtomicU64::new(0));
    HOOKS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .push(Entry {
            root: root.to_path_buf(),
            action,
            fired: Arc::clone(&fired),
        });
    Armed { fired }
}

/// Called by a worker before it runs a task of a walk of `root`.
pub(crate) fn before_task(root: &Path) {
    let action = {
        let hooks = HOOKS.lock().unwrap_or_else(PoisonError::into_inner);
        hooks.iter().find(|e| e.root == root).and_then(|e| {
            let acts = match e.action {
                Action::PanicOnce => e
                    .fired
                    .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
                    .is_ok(),
                Action::DelayEachTask(_) => {
                    e.fired.fetch_add(1, Ordering::AcqRel);
                    true
                }
            };
            acts.then_some(e.action)
        })
    };
    // Outside the lock: a panic here must not poison it, and a sleep must not
    // hold every other test's hooks hostage.
    match action {
        Some(Action::PanicOnce) => panic!("test-hooks: injected worker panic"),
        Some(Action::DelayEachTask(d)) => std::thread::sleep(d),
        None => {}
    }
}
