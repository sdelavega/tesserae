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


import Foundation

/// How the treemap is coloured (spec §8 "Colour").
public enum ColourMode: Equatable {
    /// Ordinal blue ramp by nesting depth, cycling every five levels.
    case depth
    /// Sequential ramp by time since last modification, relative to `now`.
    case age(now: Date)
    /// Up to three file kinds each get one slot colour; everything else,
    /// directories included, is neutral. Kinds beyond the third get no slot
    /// (they are neutral): a treemap is an all-pairs form, so three is the
    /// validated limit.
    case typeFocus([FileKind])
}
