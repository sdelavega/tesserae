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
import XCTest
@testable import TesseraeKit

struct ContainedTrasher: Trasher {
    let fixtureRoot: URL
    let inner: any Trasher

    func trash(_ url: URL) throws -> URL {
        let root = fixtureRoot.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard path.count > root.count, path.starts(with: root) else {
            XCTFail("Trash path escaped fixture root")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        return try inner.trash(url)
    }
}
