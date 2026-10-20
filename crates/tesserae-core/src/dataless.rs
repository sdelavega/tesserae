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

//! Cloud-only metadata and the per-thread no-materialize policy.
use std::io;

// Read from the macOS SDK's sys/stat.h and sys/resource.h (2026-10-20).
pub const SF_DATALESS: u32 = 0x4000_0000;
const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: i32 = 3;
const IOPOL_SCOPE_THREAD: i32 = 1;
const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: i32 = 1;

unsafe extern "C" {
    fn setiopolicy_np(iotype: i32, scope: i32, policy: i32) -> i32;
}

pub fn is_dataless(flags: u32) -> bool {
    flags & SF_DATALESS != 0
}

/// Applies only to the calling thread; failure must be reported but is nonfatal.
pub fn no_materialize() -> io::Result<()> {
    // SAFETY: SDK-defined scalar arguments; no pointers or ownership involved.
    let result = unsafe {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
            IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
