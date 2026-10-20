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
import TesseraeFFI

/// The palette buffer and the mapping from a node to an index into it
/// (spec §8 "Colour"). Task 8's shader and Task 9's CoreGraphics renderer both
/// index into the buffer returned by `Palette.colours`.
///
/// Buffer layout, the same for every mode:
///
///     [0]  neutral     (aggregates and non-focus tiles in age/type modes)
///     [1]  status      (#fab219, permission denied, every mode)
///     [2…] the mode's ramp: depth 5 steps, age 7 buckets (recent first),
///          type focus 3 slots
///
/// so `colourIndex` results for ramp colours are `firstColourIndex + step`.
public struct Palette {
    public static let neutralIndex = 0
    public static let statusIndex = 1
    public static let firstColourIndex = 2

    private static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(
            Float((hex >> 16) & 0xff) / 255, Float((hex >> 8) & 0xff) / 255,
            Float(hex & 0xff) / 255, 1)
    }

    private static let status = rgb(0xfab219)

    private static let depthLight: [UInt32] = [0x86b6ef, 0x5598e7, 0x256bc0, 0x184f95, 0x0d366b]
    private static let depthDark: [UInt32] = [0x184f95, 0x256abf, 0x3987e5, 0x6da7ec, 0x9ec5f4]
    private static let ageLight: [UInt32] = [
        0xcde2fb, 0x9ec5f4, 0x6da7ec, 0x3987e5, 0x256abf, 0x184f95, 0x0d366b,
    ]
    private static let focusLight: [UInt32] = [0x256bc0, 0xeb6834, 0x1baf7a]
    private static let focusDark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70]

    /// The page surface the treemap sits on (light `#fcfcfb`, dark `#1a1a19`).
    public static func surface(dark: Bool) -> SIMD4<Float> {
        rgb(dark ? 0x1a1a19 : 0xfcfcfb)
    }

    /// The palette buffer for `m` (layout above). The `SIMD4<Float>` values are
    /// sRGB-encoded (hex / 255), not linear: a shader must not blend them as
    /// if they were linear light.
    public static func colours(_ m: ColourMode, dark: Bool) -> [SIMD4<Float>] {
        let ramp: [UInt32]
        switch m {
        case .depth: ramp = dark ? depthDark : depthLight
        case .age: ramp = dark ? ageLight.reversed() : ageLight
        case .typeFocus: ramp = dark ? focusDark : focusLight
        }
        return [rgb(dark ? 0x3a3a37 : 0xd6d5cf), status] + ramp.map(rgb)
    }
}

/// Upper bounds (inclusive, seconds) of the first six age buckets (a year is
/// taken as 365 days).
private let ageLimits: [Int64] = [7, 30, 90, 365, 730, 1825].map { $0 * 86_400 }

/// The palette-buffer index for node `node` at layout depth `depth`.
///
/// A permission-denied node is the status colour in every mode. Depth mode
/// cycles the ramp every five levels; age buckets `now - modified` (a future
/// time counts as the most recent bucket); type focus colours only files of
/// the first three listed kinds and leaves everything else neutral.
public func colourIndex(_ node: UInt32, depth: UInt8, in src: Snapshot, mode: ColourMode) -> UInt16 {
    let first = Palette.firstColourIndex
    if src.isPermissionDenied(node) { return UInt16(Palette.statusIndex) }
    switch mode {
    case .depth:
        return UInt16(first + Int(depth) % 5)
    case .age(let now):
        let nowSecs = Int64(now.timeIntervalSince1970.rounded(.down))
        let (diff, overflow) = nowSecs.subtractingReportingOverflow(src.nodes[Int(node)].modified)
        let delta = overflow ? Int64.max : diff  // only a hugely negative `modified` overflows: oldest
        let bucket = ageLimits.firstIndex { delta <= $0 } ?? ageLimits.count
        return UInt16(first + bucket)
    case .typeFocus(let kinds):
        guard !src.isDirectory(node),
            let kind = FileKind.kind(forName: src.nameBytes(node)),
            let slot = kinds.prefix(3).firstIndex(of: kind)
        else { return UInt16(Palette.neutralIndex) }
        return UInt16(first + slot)
    }
}

/// As above for a layout tile, which may stand for no single node:
/// - a permission-denied tile (including the "N unreadable folders" aggregate)
///   is the status colour in every mode;
/// - any other aggregate ("N small items") uses its depth in depth mode and
///   the neutral colour in age and type-focus modes, having no single age or
///   kind.
public func colourIndex(for tile: Tile, in src: Snapshot, mode: ColourMode) -> UInt16 {
    if tile.isPermissionDenied { return UInt16(Palette.statusIndex) }
    if tile.node == Tile.noNode {
        if case .depth = mode { return UInt16(Palette.firstColourIndex + Int(tile.depth) % 5) }
        return UInt16(Palette.neutralIndex)
    }
    return colourIndex(tile.node, depth: tile.depth, in: src, mode: mode)
}
