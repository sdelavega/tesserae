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

/// The descend animation (spec §8 "Zoom and navigation"): ~250 ms, ease-out.
///
/// The *old* layout is drawn through `transform(at:)`, which grows the window
/// it shows from the whole viewport (identity at t = 0) down to the clicked
/// rect `from` (which then fills the viewport exactly), while the *new*
/// layout is cross-faded in over it with `alpha(at:)` as a whole layer
/// (`TreemapRenderer.drawZoom`). Nothing is laid out during the animation.
///
/// `t` is seconds since the animation started. Both curves use the ease-out
/// progress `1 - (1 - t/duration)³`, clamped to [0, 1]; a non-finite `t`
/// counts as the end.
///
/// **Degenerate input.** If `from` or `viewport` is empty or not finite, or
/// the final scale would not be a finite, representable `Float`, there is
/// nothing to animate: the animation is finished from the start, its
/// transform is the identity and its alpha 1 (the new layout, opaque). So no
/// NaN or infinity can come out of it, whatever the view's size.
public struct ZoomAnimation {
    public let from: CGRect
    public let viewport: CGRect
    public let duration: TimeInterval
    /// Seconds since the start, as last given to `advance(to:)`.
    public private(set) var elapsed: TimeInterval = 0
    /// Set by `cancel()` or by degenerate input.
    public private(set) var isCancelled: Bool

    /// The largest final zoom factor animated (a 1-pt tile on a 1e6-pt
    /// viewport); beyond it the transform would lose all precision in `Float`.
    static let maxScale: CGFloat = 1e6

    public init(from: CGRect, viewport: CGRect, duration: TimeInterval = 0.25) {
        precondition(duration.isFinite && duration > 0, "ZoomAnimation duration must be positive")
        self.from = from
        self.viewport = viewport
        self.duration = duration
        isCancelled = !Self.animatable(from: from, viewport: viewport)
    }

    private static func animatable(from: CGRect, viewport: CGRect) -> Bool {
        func ok(_ r: CGRect) -> Bool {
            r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite
                && r.width > 0 && r.height > 0
        }
        guard ok(from), ok(viewport) else { return false }
        let sx = viewport.width / from.width
        let sy = viewport.height / from.height
        return sx.isFinite && sy.isFinite && sx <= maxScale && sy <= maxScale && sx > 1 / maxScale
            && sy > 1 / maxScale
    }

    public var isFinished: Bool { isCancelled || elapsed >= duration }

    public mutating func advance(to t: TimeInterval) {
        elapsed = t.isFinite ? max(t, elapsed) : duration
    }

    /// Stop now: `transform`/`alpha` report the end state from here on.
    public mutating func cancel() {
        isCancelled = true
    }

    /// Ease-out progress in [0, 1].
    public func progress(at t: TimeInterval) -> CGFloat {
        if isCancelled || !t.isFinite { return 1 }
        let x = min(max(t / duration, 0), 1)
        let inv = 1 - x
        return CGFloat(1 - inv * inv * inv)
    }

    /// Maps the old layout's coordinates to the viewport's at time `t`.
    public func transform(at t: TimeInterval) -> CGAffineTransform {
        if isCancelled { return .identity }
        let p = progress(at: t)
        // The window of the old layout shown at `t`, mapped onto the viewport.
        let wx = viewport.minX + (from.minX - viewport.minX) * p
        let wy = viewport.minY + (from.minY - viewport.minY) * p
        let ww = viewport.width + (from.width - viewport.width) * p
        let wh = viewport.height + (from.height - viewport.height) * p
        let sx = viewport.width / ww
        let sy = viewport.height / wh
        let tx = viewport.minX - wx * sx
        let ty = viewport.minY - wy * sy
        let m = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        guard [m.a, m.d, m.tx, m.ty].allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return .identity }
        return m
    }

    /// Opacity of the new layout over the old one at `t`.
    public func alpha(at t: TimeInterval) -> Float {
        Float(progress(at: t))
    }
}

/// Runs one `ZoomAnimation` against a clock, for the view's frame loop.
///
/// A resize cancels the animation (the view then shows the new layout, laid
/// out again for the new size): the old layout's transform was computed for
/// the old viewport, and nothing about a 0×0 or 0.5×0.5 view is worth
/// animating.
struct ZoomPlayer {
    private(set) var animation: ZoomAnimation?
    private var startTime: TimeInterval = 0

    var isRunning: Bool { animation.map { !$0.isFinished } ?? false }

    /// Starts a zoom of `from` onto `viewport` at clock time `now`; false
    /// (and nothing running) if the input is degenerate.
    mutating func start(from: CGRect, viewport: CGRect, now: TimeInterval) -> Bool {
        let a = ZoomAnimation(from: from, viewport: viewport)
        guard !a.isFinished, now.isFinite else {
            animation = nil
            return false
        }
        animation = a
        startTime = now
        return true
    }

    /// The old layout's transform and the new layout's alpha for the frame
    /// at `now`, or nil once the animation is finished (or none is running).
    mutating func frame(now: TimeInterval) -> (transform: CGAffineTransform, alpha: Float)? {
        guard var a = animation, !a.isFinished else {
            animation = nil
            return nil
        }
        let t = now - startTime
        a.advance(to: t)
        animation = a
        if a.isFinished {
            animation = nil
            return nil
        }
        return (a.transform(at: a.elapsed), a.alpha(at: a.elapsed))
    }

    /// The view changed size: cancel.
    mutating func resize(to viewport: CGRect) {
        guard let a = animation, a.viewport != viewport else { return }
        animation = nil
    }

    mutating func cancel() { animation = nil }
}
