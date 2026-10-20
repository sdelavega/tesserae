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

import TesseraeFFI

/// The C ABI version of the Rust library this framework linked
/// (`TESS_ABI_VERSION` in tesserae.h). The app refuses to run against a
/// library whose version differs from the header it was compiled with.
public var abiVersion: UInt32 {
    tess_abi_version()
}

/// The linked Rust engine's package version, rather than a UI-side constant.
public var engineVersion: String { String(cString: tess_engine_version()) }
