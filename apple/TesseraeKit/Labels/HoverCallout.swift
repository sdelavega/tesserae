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

import CoreGraphics
import Foundation
import SwiftUI

public typealias TileID = Int

/// A dismissal requires a fresh pointer event before another dwell can begin.
public struct HoverCallout {
    public enum Event { case scroll, click, motion }
    private var tile: TileID?
    private var since: TimeInterval = 0
    public init() {}
    public mutating func pointerMoved(to tile: TileID?, at t: TimeInterval) {
        guard tile != self.tile else { return }
        self.tile = tile
        since = t
    }
    public func tick(_ t: TimeInterval) -> TileID? { t - since >= 0.5 ? tile : nil }
    public mutating func hide(for event: Event) { tile = nil }

    /// Try below, then above, then beside the pointer; suppress if no room.
    public static func frame(near p: CGPoint, size: CGSize, in bounds: CGRect) -> CGRect {
        let w = min(size.width, bounds.width), h = min(size.height, bounds.height)
        let x = min(max(p.x + 12, bounds.minX), bounds.maxX - w)
        let y = min(max(p.y + 12, bounds.minY), bounds.maxY - h)
        let candidates = [CGRect(x: x, y: y, width: w, height: h),
            CGRect(x: x, y: p.y - 12 - h, width: w, height: h),
            CGRect(x: p.x - 12 - w, y: y, width: w, height: h)]
        return candidates.first { bounds.contains($0) && !$0.insetBy(dx: -4, dy: -4).contains(p) } ?? .zero
    }
}

/// Isolates pointer updates from the expensive treemap and labels view tree.
@MainActor
public final class HoverCalloutModel: ObservableObject {
    @Published public private(set) var info: InspectorInfo?
    @Published public private(set) var pointer = CGPoint.zero
    private var state = HoverCallout()
    private var pending: Task<Void, Never>?
    private var currentTile: TileID?
    public init() {}
    public func move(to tile: TileID?, at point: CGPoint?, resolve: @escaping @MainActor () -> InspectorInfo?) {
        if let point { pointer = point }
        guard tile != currentTile else { return }
        currentTile = tile
        let now = ProcessInfo.processInfo.systemUptime
        state.pointerMoved(to: tile, at: now)
        pending?.cancel()
        if state.tick(now) != nil { self.info = resolve(); return }
        self.info = nil
        guard tile != nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.state.tick(ProcessInfo.processInfo.systemUptime) == tile else { return }
            self.info = resolve()
        }
    }
    public func hide(for event: HoverCallout.Event) {
        pending?.cancel(); pending = nil
        state.hide(for: event); info = nil; currentTile = nil
    }
    deinit { pending?.cancel() }
}

public struct HoverCalloutOverlay: View {
    @ObservedObject var model: HoverCalloutModel
    var hidden: Bool
    @Environment(\.locale) private var locale
    public init(model: HoverCalloutModel, hidden: Bool) { self.model = model; self.hidden = hidden }
    public var body: some View {
        GeometryReader { geometry in
            if let info = model.info, !hidden {
                let text = info.displayTitle + "\n" + displaySize(info.allocated, locale: locale)
                let width = min(360, max(120, text.split(separator: "\n").map { LabelStyle.measure(String($0)).width }.max() ?? 120) + 16)
                let rect = HoverCallout.frame(near: model.pointer, size: CGSize(width: width, height: 52),
                    in: CGRect(origin: .zero, size: geometry.size))
                if !rect.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.displayTitle).lineLimit(1).truncationMode(.middle)
                        Text(displaySize(info.allocated, locale: locale)).lineLimit(1).fixedSize()
                    }.font(.system(size: LabelStyle.fontSize))
                        .padding(8).frame(width: rect.width, height: rect.height, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }.allowsHitTesting(false)
        .onChange(of: hidden) { if $0 { model.hide(for: .motion) } }
    }
}
