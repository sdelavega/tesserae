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

import XCTest
@testable import TesseraeKit

final class HoverCalloutTests: XCTestCase {
    func test_callout_after_half_second_and_hides_on_move_out_scroll_click_motion() {
        var h = HoverCallout()
        h.pointerMoved(to: 2, at: 10)
        XCTAssertNil(h.tick(10.499)); XCTAssertEqual(h.tick(10.5), 2)
        h.pointerMoved(to: 2, at: 10.6)
        XCTAssertEqual(h.tick(10.6), 2)
        h.pointerMoved(to: nil, at: 11); XCTAssertNil(h.tick(12))
        for event in [HoverCallout.Event.scroll, .click, .motion] {
            h.pointerMoved(to: 3, at: 20); XCTAssertEqual(h.tick(20.5), 3)
            h.hide(for: event); XCTAssertNil(h.tick(30))
        }
    }
    @MainActor
    func test_callout_resolves_path_once_after_dwell() async throws {
        let model = HoverCalloutModel()
        var resolutions = 0
        let tree = TestSnapshot(.dir("/fixture", [.file("a", 512)]))
        let info = inspect(tree["a"], in: tree.snapshot)
        for x in 0..<10 {
            model.move(to: 1, at: CGPoint(x: x, y: 1), resolve: { resolutions += 1; return info })
        }
        XCTAssertEqual(resolutions, 0)
        XCTAssertNil(model.info)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(model.info, info)
        model.move(to: 1, at: CGPoint(x: 20, y: 1), resolve: { resolutions += 1; return info })
        XCTAssertEqual(resolutions, 1)
        model.move(to: 2, at: .zero, resolve: { resolutions += 1; return info })
        model.hide(for: .click)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(resolutions, 1)
    }

    func test_callout_position_is_clamped_and_avoids_pointer() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        for p in [CGPoint(x: 1, y: 1), CGPoint(x: 299, y: 199), CGPoint(x: 150, y: 100)] {
            let r = HoverCallout.frame(near: p, size: CGSize(width: 120, height: 50), in: bounds)
            XCTAssertFalse(r.isEmpty); XCTAssertTrue(bounds.contains(r)); XCTAssertFalse(r.contains(p))
        }
    }
}
