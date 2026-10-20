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

import AppKit
import CoreText
import SwiftUI

/// The label font and ink (spec §8 "Labels"): text wears one of the two ink
/// tokens, `#0b0b0b` and `#f0efec`, never a tile's colour. Which one is
/// chosen per tile: the token with the higher WCAG 2.x contrast against that
/// tile's fill (`ink(over:)`; final review I3).
public enum LabelStyle {
    public static let fontSize: CGFloat = 11
    public static var font: NSFont { .systemFont(ofSize: fontSize) }

    /// The appearance's ink token as sRGB 0...255 components: `#0b0b0b` in
    /// light mode, `#f0efec` in dark. Text over a tile uses `ink(over:)`.
    public static func ink(dark: Bool) -> (red: Int, green: Int, blue: Int) {
        dark ? (0xf0, 0xef, 0xec) : (0x0b, 0x0b, 0x0b)
    }

    /// The ink token that reads better on `fill` (sRGB-encoded, as the
    /// palette is): whichever of `#0b0b0b` and `#f0efec` has the higher WCAG
    /// 2.x contrast ratio against it; the dark token on a tie.
    public static func ink(over fill: SIMD4<Float>) -> (red: Int, green: Int, blue: Int) {
        let darkInk = ink(dark: false), lightInk = ink(dark: true)
        let f = relativeLuminance(Double(fill.x), Double(fill.y), Double(fill.z))
        func lum(_ c: (red: Int, green: Int, blue: Int)) -> Double {
            relativeLuminance(Double(c.red) / 255, Double(c.green) / 255, Double(c.blue) / 255)
        }
        return contrast(f, lum(darkInk)) >= contrast(f, lum(lightInk)) ? darkInk : lightInk
    }

    /// WCAG 2.x relative luminance of an sRGB-encoded colour (components 0...1).
    static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG 2.x contrast ratio of two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static func inkColour(dark: Bool) -> Color { colour(ink(dark: dark)) }

    /// `ink(over:)` as a SwiftUI colour.
    public static func inkColour(over fill: SIMD4<Float>) -> Color { colour(ink(over: fill)) }

    private static func colour(_ c: (red: Int, green: Int, blue: Int)) -> Color {
        Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }

    /// The label font as a Core Text font. Core Text fonts and lines are
    /// immutable and documented as safe to use from any thread, unlike the
    /// AppKit string-drawing additions, so labels can be measured off the
    /// main actor.
    nonisolated(unsafe) private static let ctFont: CTFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

    /// One line's height as AppKit sets it: the label font's own ascent,
    /// descent and leading, each rounded up, whatever fallback fonts the text
    /// pulls in.
    private static let lineHeight: CGFloat =
        CTFontGetAscent(ctFont).rounded(.up) + CTFontGetDescent(ctFont).rounded(.up)
        + CTFontGetLeading(ctFont).rounded(.up)

    /// The size of one line of `text` in the label font, rounded up to whole
    /// points; what the overlay draws is measured with the same font. The
    /// width is a Core Text line's (with the font cascade AppKit also uses),
    /// so this is thread-safe; a test checks it matches
    /// `NSString.size(withAttributes:)` across scripts.
    public static func measure(_ text: String) -> CGSize {
        guard let attributed = CFAttributedStringCreate(
            nil, text as CFString, [kCTFontAttributeName: ctFont] as CFDictionary)
        else { return CGSize(width: 0, height: lineHeight) }
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        return CGSize(width: CGFloat(width).rounded(.up), height: lineHeight)
    }

    /// Seconds the labels take to fade in once motion settles.
    public static let fadeDuration: TimeInterval = 0.15

    /// Opacity of the labels: shown only when no zoom runs and the current
    /// layout's labels have arrived (`AppSession.labelsReady`; placement runs
    /// off the main actor and finishes after motion settles).
    public static func opacity(zoomRunning: Bool, labelsReady: Bool) -> Double {
        !zoomRunning && labelsReady ? 1 : 0
    }

    /// How a change to this state animates: a fade-in over `fadeDuration`
    /// when the labels become visible, nothing (at once) when they hide.
    public static func fadeDuration(zoomRunning: Bool, labelsReady: Bool) -> TimeInterval? {
        opacity(zoomRunning: zoomRunning, labelsReady: labelsReady) == 1 ? fadeDuration : nil
    }
}

/// Positioned `Text` views over the treemap, one per `PlacedLabel`, each in
/// the ink that reads better on its tile's colour (`ink(for:)`): the colour
/// the renderer paints, from the same `palette` and `colourOf`, so the ink
/// follows the colour mode and the appearance without a relayout.
///
/// Hidden while a zoom animates (`zoomRunning`, i.e. a `ZoomAnimation` that is
/// not `isFinished`) so SwiftUI never diffs hundreds of views per frame, and
/// until the current layout's labels arrive (`labelsReady`), then faded in
/// over `LabelStyle.fadeDuration`. Hit testing is off: the labels never take
/// the pointer from the treemap underneath.
public struct LabelsOverlay: View {
    public var labels: [PlacedLabel]
    public var palette: [SIMD4<Float>]
    public var colourOf: (Tile) -> UInt16
    public var dark: Bool
    public var zoomRunning: Bool
    public var labelsReady: Bool

    public init(
        labels: [PlacedLabel], palette: [SIMD4<Float>], colourOf: @escaping (Tile) -> UInt16, dark: Bool,
        zoomRunning: Bool, labelsReady: Bool
    ) {
        self.labels = labels
        self.palette = palette
        self.colourOf = colourOf
        self.dark = dark
        self.zoomRunning = zoomRunning
        self.labelsReady = labelsReady
    }

    /// The ink for `label`: the token that reads better on its tile's fill,
    /// or the appearance's token if the tile's colour index is outside the
    /// palette (never expected; the renderer would not paint it either).
    public func ink(for label: PlacedLabel) -> (red: Int, green: Int, blue: Int) {
        let i = Int(colourOf(label.tile))
        guard palette.indices.contains(i) else { return LabelStyle.ink(dark: dark) }
        return LabelStyle.ink(over: palette[i])
    }

    private func inkColour(for label: PlacedLabel) -> Color {
        let c = ink(for: label)
        return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label.text)
                    .font(Font(LabelStyle.font))
                    .foregroundColor(inkColour(for: label))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: label.rect.minX, y: label.rect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(LabelStyle.opacity(zoomRunning: zoomRunning, labelsReady: labelsReady))
        .animation(
            LabelStyle.fadeDuration(zoomRunning: zoomRunning, labelsReady: labelsReady).map { .easeIn(duration: $0) },
            value: LabelStyle.opacity(zoomRunning: zoomRunning, labelsReady: labelsReady))
        .allowsHitTesting(false)
    }
}
