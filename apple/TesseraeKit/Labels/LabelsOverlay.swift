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

/// The label font and ink (spec §8 "Labels"): text wears the ink tokens
/// `#0b0b0b` (light) and `#f0efec` (dark), never a tile's colour.
public enum LabelStyle {
    public static let fontSize: CGFloat = 11
    public static var font: NSFont { .systemFont(ofSize: fontSize) }

    /// The ink as sRGB 0...255 components.
    public static func ink(dark: Bool) -> (red: Int, green: Int, blue: Int) {
        dark ? (0xf0, 0xef, 0xec) : (0x0b, 0x0b, 0x0b)
    }

    public static func inkColour(dark: Bool) -> Color {
        let c = ink(dark: dark)
        return Color(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255)
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

/// Positioned `Text` views over the treemap, one per `PlacedLabel`.
///
/// Hidden while a zoom animates (`zoomRunning`, i.e. a `ZoomAnimation` that is
/// not `isFinished`) so SwiftUI never diffs hundreds of views per frame, and
/// until the current layout's labels arrive (`labelsReady`), then faded in
/// over `LabelStyle.fadeDuration`. Hit testing is off: the labels never take
/// the pointer from the treemap underneath.
public struct LabelsOverlay: View {
    public var labels: [PlacedLabel]
    public var dark: Bool
    public var zoomRunning: Bool
    public var labelsReady: Bool

    public init(labels: [PlacedLabel], dark: Bool, zoomRunning: Bool, labelsReady: Bool) {
        self.labels = labels
        self.dark = dark
        self.zoomRunning = zoomRunning
        self.labelsReady = labelsReady
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label.text)
                    .font(Font(LabelStyle.font))
                    .foregroundColor(LabelStyle.inkColour(dark: dark))
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
