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


import SwiftUI
import AppKit

/// Native mapping of Aether7B v1.1, sourced from ../aether7b/tokens/aether7b.tokens.json.
/// Content stays opaque; material is reserved for navigation chrome.
enum Aether {
    static let classic = color(0x7BAFD4)
    static let web = color(0x4B9CD3)
    static let ice = color(0x99C5E3)
    static let navy = color(0x13294B)
    static let accent = adaptive(light: 0x2B72A6, dark: 0x7BAFD4)
    static let accentTint = adaptive(light: 0x4B9CD3, dark: 0x7BAFD4, lightAlpha: 0.12, darkAlpha: 0.15)
    static let canvas = adaptive(light: 0xEDF3F8, dark: 0x0A1320)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x0E1A2B)
    static let well = adaptive(light: 0xE3EEF7, dark: 0x13294B)
    static let text = adaptive(light: 0x13294B, dark: 0xE6F0F8)
    static let muted = adaptive(light: 0x4A6583, dark: 0x8CA7C0)
    static let border = adaptive(light: 0x13294B, dark: 0x7BAFD4, lightAlpha: 0.12, darkAlpha: 0.22)
    static let specular = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.95, darkAlpha: 0.16)
    static let borderStrong = adaptive(light: 0x13294B, dark: 0x7BAFD4, lightAlpha: 0.55, darkAlpha: 0.55)
    static let warning = adaptive(light: 0xB45309, dark: 0xF59E0B)
    static let danger = adaptive(light: 0xB91C1C, dark: 0xEF4444)
    static let success = adaptive(light: 0x047857, dark: 0x10B981)
    // These type tokens and TesseraeKit's AetherTypography in ReconciliationView.swift
    // both mirror Aether7B v1.1; keep them aligned without a Kit dependency here.
    enum TypeSize {
        static let xs: CGFloat = 12
        static let sm: CGFloat = 13
        static let md: CGFloat = 15
        static let xl: CGFloat = 22
        static let xxl: CGFloat = 34
    }
    static let xs = Font.system(size: TypeSize.xs)
    static let sm = Font.system(size: TypeSize.sm)
    static let md = Font.system(size: TypeSize.md)
    static let xl = Font.system(size: TypeSize.xl, weight: .semibold)
    static let xxl = Font.system(size: TypeSize.xxl, weight: .semibold)
    static let metadata = Font.system(size: TypeSize.xs, design: .monospaced)

    private static func color(_ hex: UInt32) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: alpha)
    }

    private static func adaptive(light: UInt32, dark: UInt32,
                                 lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

struct AetherCanvas: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Aether.canvas
            .overlay {
                if !reduceTransparency {
                    RadialGradient(colors: [(scheme == .dark ? Aether.web.opacity(0.18) : Aether.classic.opacity(0.22)), .clear],
                                   center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: 520)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct AetherSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Aether.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(contrast == .increased ? Aether.muted : Aether.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

struct AetherChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Aether.canvas
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Aether.navy.opacity(0.05))
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Aether.specular).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// Localize before passing text; casing follows the user's locale.
struct AetherEyebrow: View {
    let text: String
    @Environment(\.locale) private var locale

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "//").opacity(0.6).accessibilityHidden(true)
            Text(text.uppercased(with: locale))
        }
        .font(Aether.metadata).kerning(0.72)
        .foregroundStyle(Aether.accent)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct AetherSheetHeading: View {
    let title: String
    let eyebrow: String
    init(_ title: String, eyebrow: String = String(localized: "aether.sheet.section", defaultValue: "Review",
        comment: "Section label above confirmation sheet headings.")) {
        self.title = title
        self.eyebrow = eyebrow
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AetherEyebrow(eyebrow)
            Text(title).font(Aether.xl).kerning(-0.33)
                .monospacedDigit().accessibilityAddTraits(.isHeader)
        }
    }
}

/// Status stays on an opaque card: colour belongs to the rim, dot and message.
struct AetherStatus: View {
    let text: String
    var color: Color = Aether.warning
    var isDanger: Bool { color == Aether.danger }
    init(_ text: String, color: Color = Aether.warning) {
        self.text = text
        self.color = color
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(Aether.sm)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color).padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Aether.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 1))
        .overlay {
            if isDanger {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color.opacity(0.3), lineWidth: 2).padding(-2)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct AetherBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Aether.metadata)
            .foregroundStyle(Aether.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Aether.accentTint, in: Capsule())
            .overlay(Capsule().strokeBorder(Aether.borderStrong, lineWidth: 1))
    }
}

struct AetherPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Aether.sm.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(Aether.colorForButtonText)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Aether.classic, Aether.web],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .top) {
                // CTA specular is inset inside the rim, distinct from chrome specular.
                Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
                    .padding(.horizontal, 8).padding(.top, 1)
                    .allowsHitTesting(false)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Aether.ice, lineWidth: 1))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Aether.accent, lineWidth: 2).padding(-4)
                }
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.14),
                       value: configuration.isPressed)
    }
}

extension Aether {
    static let colorForButtonText = Color(nsColor: NSColor(srgbRed: 10.0 / 255,
                                                          green: 19.0 / 255,
                                                          blue: 32.0 / 255, alpha: 1))
}

private struct AetherCanvasPresent: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var aetherCanvasPresent: Bool {
        get { self[AetherCanvasPresent.self] }
        set { self[AetherCanvasPresent.self] = newValue }
    }
}

private struct AetherTheme: ViewModifier {
    @Environment(\.aetherCanvasPresent) private var canvasPresent
    func body(content: Content) -> some View {
        content.tint(Aether.accent)
            .buttonStyle(AetherSecondaryButtonStyle())
            .foregroundStyle(Aether.text, Aether.muted)
            .font(Aether.sm)
            .background { if !canvasPresent { AetherCanvas() } }
            .environment(\.aetherCanvasPresent, true)
    }
}
extension View {
    func aetherSurface() -> some View { modifier(AetherSurface()) }
    func aetherTheme() -> some View { modifier(AetherTheme()) }
}

/// Native layout evidence used by the minimum-window regression. Read live
/// coordinates: split panes can move without resizing their child probes.
final class SessionLayout {
    weak var summaryView: NSView?
    weak var stageView: NSView?
    weak var reviewView: NSView?
    private func rect(_ view: NSView?) -> CGRect {
        guard let view, let content = view.window?.contentView else { return .zero }
        return content.convert(view.bounds, from: view)
    }
    var summary: CGRect { rect(summaryView) }
    var stage: CGRect { rect(stageView) }
    var review: CGRect { rect(reviewView) }
    var summaryScrolls: Bool { summaryView?.enclosingScrollView != nil }
}

struct SessionBounds: NSViewRepresentable {
    let layout: SessionLayout
    var summary = false
    var review = false
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if summary { layout.summaryView = view }
        else if review { layout.reviewView = view }
        else { layout.stageView = view }
    }
}

struct AetherSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    func makeBody(configuration: Configuration) -> some View {
        GhostBody(label: configuration.label, pressed: configuration.isPressed,
                  enabled: enabled, focused: focused, contrast: contrast)
    }

    private struct GhostBody<Label: View>: View {
        let label: Label
        let pressed: Bool
        let enabled: Bool
        let focused: Bool
        let contrast: ColorSchemeContrast
        @State private var hovering = false
        var body: some View {
            label
            .foregroundStyle(enabled ? Aether.text : Aether.muted)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(enabled && (hovering || pressed) ? Aether.accentTint : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                focused ? Aether.accent : (contrast == .increased ? Aether.muted : Aether.borderStrong),
                lineWidth: focused ? 2 : 1))
        }
    }
}
