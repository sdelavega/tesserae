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
///     [2…] the mode's ramp: folder 8 slots × 4 steps, age 7 buckets (recent first),
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

    private static let folderLight: [UInt32] = [
        0x256bc0, 0x0d59ac, 0x004893, 0x003976,
        0xeb6834, 0xff7d4b, 0xff9e7b, 0xfebca5,
        0x1baf7a, 0x3bc28c, 0x53d69e, 0x69eab1,
        0xeda100, 0xffb63e, 0xffd08f, 0xffe9cc,
        0xe87ba4, 0xfd8eb7, 0xffaeca, 0xffcddd,
        0x007a00, 0x036602, 0x025301, 0x014001,
        0x6250d6, 0x533cc1, 0x4427ad, 0x370a99,
        0xe34948, 0xf95d5a, 0xfe8079, 0xfea29a,
    ]
    private static let folderDark: [UInt32] = [
        0x3987e5, 0x4c9afa, 0x6faefe, 0x92c2ff,
        0xd95926, 0xee6c3b, 0xfe8458, 0xffa484,
        0x199e70, 0x37b182, 0x4ec494, 0x64d8a6,
        0xc98500, 0xdd982a, 0xf1ab43, 0xffc16c,
        0xd55181, 0xea6493, 0xff78a5, 0xff9dba,
        0x007a00, 0x036602, 0x025301, 0x014001,
        0x9085e9, 0xa298fe, 0xb5b0fe, 0xc9c7fe,
        0xe66767, 0xfb7a79, 0xfe9a97, 0xfeb9b6,
    ]
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
        case .folder: ramp = dark ? folderDark : folderLight
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
/// A permission-denied node is the status colour in every mode. Folder mode
/// needs layout context (the tile overload below); age buckets `now - modified` (a future
/// time counts as the most recent bucket); type focus colours only files of
/// the first three listed kinds and leaves everything else neutral.
public func colourIndex(_ node: UInt32, depth: UInt8, in src: Snapshot, mode: ColourMode) -> UInt16 {
    let first = Palette.firstColourIndex
    if src.isPermissionDenied(node) { return UInt16(Palette.statusIndex) }
    switch mode {
    case .folder:
        return UInt16(Palette.neutralIndex)
    case .age(let now):
        let nowSecs = Int64(now.timeIntervalSince1970.rounded(.down))
        let (diff, overflow) = nowSecs.subtractingReportingOverflow(src.nodes[Int(node)].modified)
        let delta = overflow ? Int64.max : diff  // only a hugely negative `modified` overflows: oldest
        let bucket = ageLimits.firstIndex { delta <= $0 } ?? ageLimits.count
        return UInt16(first + bucket)
    case .typeFocus(let kinds):
        guard !src.isDirectory(node),
            let kind = src.fileKind(node),
            let slot = kinds.prefix(3).firstIndex(of: kind)
        else { return UInt16(Palette.neutralIndex) }
        return UInt16(first + slot)
    }
}

/// A tile takes its top-level folder's hue at its relative depth. Root tiles,
/// loose root files and aggregates directly under the root stay neutral.
/// Permission denial overrides every mode; age/type aggregates stay neutral.
public func colourIndex(
    for tile: Tile, in src: Snapshot, mode: ColourMode,
    slots: [UInt32: Int] = [:], rootChildOf: (UInt32) -> UInt32? = { _ in nil }
) -> UInt16 {
    if tile.isPermissionDenied { return UInt16(Palette.statusIndex) }
    if tile.node != Tile.noNode, src.isPermissionDenied(tile.node) { return UInt16(Palette.statusIndex) }
    if case .folder = mode {
        let child = tile.node == Tile.noNode ? rootChildOf(tile.parent) : rootChildOf(tile.node)
        guard let child, let slot = slots[child], (1...8).contains(slot), tile.depth > 0 else {
            return UInt16(Palette.neutralIndex)
        }
        return UInt16(2 + (slot - 1) * 4 + min(Int(tile.depth) - 1, 3))
    }
    if tile.node == Tile.noNode { return UInt16(Palette.neutralIndex) }
    return colourIndex(tile.node, depth: tile.depth, in: src, mode: mode)
}
