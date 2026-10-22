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
import CoreGraphics
import ImageIO

// Art direction: edit these constants, then run `just icon`.
let depthBlues: [UInt32] = [0x86b6ef, 0x5598e7, 0x256bc0, 0x184f95, 0x0d366b]
let statusAccent: UInt32 = 0xfab219
let groutColour: UInt32 = 0xf4f7fb
let centreWeights: [CGFloat] = [30, 25, 20, 15, 10]
let centreColours = [3, 1, 0, 5, 2]
let shapeMargin: CGFloat = 0.10
let cornerRadiusRatio: CGFloat = 0.2237
let groutRatio: CGFloat = 0.012
let tileTopLightening: CGFloat = 0.05
let shadowOpacity: CGFloat = 0.20
let shadowBlurRatio: CGFloat = 0.012
let shadowOffsetRatio: CGFloat = 0.008
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colourSpace, components: [
        CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, alpha])!
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
              bytesPerRow: width * 4, space: colourSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Standalone Bruls–Huizing–van Wijk squarification; no app runtime imports.
func squarify(_ weights: [CGFloat], in bounds: CGRect) -> [CGRect] {
    let factor = bounds.width * bounds.height / weights.reduce(0, +)
    let areas = weights.map { $0 * factor }
    var remaining = bounds
    var result: [CGRect] = []
    var start = 0
    func worst(_ row: ArraySlice<CGFloat>, _ side: CGFloat) -> CGFloat {
        let sum = row.reduce(0, +)
        return max(side * side * row.max()! / (sum * sum),
                   sum * sum / (side * side * row.min()!))
    }
    while start < areas.count {
        let side = min(remaining.width, remaining.height)
        var end = start + 1
        while end < areas.count && worst(areas[start...end], side)
            <= worst(areas[start..<end], side) { end += 1 }
        let row = areas[start..<end]
        let thickness = row.reduce(0, +) / side
        var cursor = remaining.width >= remaining.height ? remaining.minY : remaining.minX
        for area in row {
            let length = area / thickness
            if remaining.width >= remaining.height {
                result.append(CGRect(x: remaining.minX, y: cursor, width: thickness, height: length))
            } else {
                result.append(CGRect(x: cursor, y: remaining.minY, width: length, height: thickness))
            }
            cursor += length
        }
        if remaining.width >= remaining.height {
            remaining.origin.x += thickness
            remaining.size.width -= thickness
        } else {
            remaining.origin.y += thickness
            remaining.size.height -= thickness
        }
        start = end
    }
    return result
}

// Reserve generous corner tiles; squarify only the enclosed middle band.
// Coordinates are bottom-up, placing amber in the upper-right third.
func mosaicLayout(in shape: CGRect, small: Bool) -> ([CGRect], [Int]) {
    let x = shape.minX, y = shape.minY, w = shape.width, h = shape.height
    let corners = [CGRect(x: x, y: y, width: w * 0.4, height: h * 0.5),
                   CGRect(x: x, y: y + h * 0.5, width: w * 0.4, height: h * 0.5),
                   CGRect(x: x + w * 0.4, y: y, width: w * 0.6, height: h * 0.35),
                   CGRect(x: x + w * 0.4, y: y + h * 0.75, width: w * 0.6, height: h * 0.25)]
    let centre = CGRect(x: x + w * 0.4, y: y + h * 0.35, width: w * 0.6, height: h * 0.4)
    if small { return (corners + [centre], [2, 0, 4, 2, 5]) }
    return (corners + squarify(centreWeights, in: centre), [2, 0, 4, 2] + centreColours)
}

func render(_ pixels: Int) -> CGImage {
    let c = context(pixels, pixels)
    let n = CGFloat(pixels)
    let margin = (n * shapeMargin).rounded()
    let shape = CGRect(x: margin, y: margin, width: n - 2 * margin, height: n - 2 * margin)
    let radius = shape.width * cornerRadiusRatio
    // Circular rounded rect approximates Apple's continuous-corner icon shape.
    let outline = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -n * shadowOffsetRatio),
                blur: n * shadowBlurRatio, color: colour(0, alpha: shadowOpacity))
    c.setFillColor(colour(groutColour))
    c.addPath(outline)
    c.fillPath()
    c.restoreGState()
    c.addPath(outline)
    c.clip()
    let gap = max(1, (shape.width * groutRatio).rounded())
    let (rects, indices) = mosaicLayout(in: shape, small: pixels <= 32)
    let palette = depthBlues + [statusAccent]
    c.setShouldAntialias(false)
    for (rect, index) in zip(rects, indices) {
        // Snap shared edges first; complementary integer half-gaps stay uniform.
        let x = rect.minX.rounded(), y = rect.minY.rounded()
        let snapped = CGRect(x: x, y: y, width: rect.maxX.rounded() - x,
                             height: rect.maxY.rounded() - y)
        // Half-grout only on shared edges: outer edges stay full bleed.
        let left = rect.minX > shape.minX + 0.01 ? ceil(gap / 2) : 0
        let right = rect.maxX < shape.maxX - 0.01 ? floor(gap / 2) : 0
        let bottom = rect.minY > shape.minY + 0.01 ? ceil(gap / 2) : 0
        let top = rect.maxY < shape.maxY - 0.01 ? floor(gap / 2) : 0
        let tile = CGRect(x: snapped.minX + left, y: snapped.minY + bottom,
                          width: snapped.width - left - right, height: snapped.height - bottom - top)
        precondition(tile.width > 0 && tile.height > 0)
        let base = colour(palette[index])
        let components = base.components!
        let light = CGColor(colorSpace: colourSpace, components:
            components.prefix(3).map { $0 + (1 - $0) * tileTopLightening } + [1])!
        let gradient = CGGradient(colorsSpace: colourSpace, colors: [base, light] as CFArray,
                                  locations: [0, 1])!
        c.saveGState()
        c.clip(to: tile)
        c.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.minY),
                             end: CGPoint(x: tile.midX, y: tile.maxY), options: [])
        c.restoreGState()
    }
    if pixels >= 128 {
        // One physical pixel, clipped to the outer silhouette; no inner mask.
        c.setShouldAntialias(true)
        c.setStrokeColor(colour(0xffffff, alpha: 0.18))
        c.setLineWidth(2)
        c.saveGState()
        c.clip(to: CGRect(x: shape.minX, y: shape.maxY - 1, width: shape.width, height: 1))
        c.addPath(outline)
        c.strokePath()
        c.restoreGState()
    }
    return c.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { throw NSError(domain: "IconPNG", code: 1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "IconPNG", code: 2) }
}

// Previews contain no type or labels; columns follow `sizes`, left to right.
func review(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writePNG(render(1024), to: directory.appendingPathComponent("icon-1024.png"))
    for (name, background) in [("light", UInt32(0xf3f3f1)), ("dark", UInt32(0x202124))] {
        let c = context(1600, 1160)
        c.setFillColor(colour(background))
        c.fill(CGRect(x: 0, y: 0, width: 1600, height: 1160))
        var x: CGFloat = 24
        // Native pixels up to 512; master displayed at 512 below the row.
        for size in sizes.dropLast() {
            c.draw(render(size), in: CGRect(x: x, y: 608, width: CGFloat(size), height: CGFloat(size)))
            x += CGFloat(size) + 32
        }
        c.draw(render(1024), in: CGRect(x: 24, y: 40, width: 512, height: 512))
        try writePNG(c.makeImage()!, to: directory.appendingPathComponent("contact-\(name).png"))
    }
    let c = context(720, 200)
    c.setFillColor(colour(0x242a35))
    c.fill(CGRect(x: 0, y: 0, width: 720, height: 200))
    c.setFillColor(colour(0xd1d7e0, alpha: 0.22))
    c.addPath(CGPath(roundedRect: CGRect(x: 64, y: 42, width: 592, height: 104),
                     cornerWidth: 24, cornerHeight: 24, transform: nil))
    c.fillPath()
    for (i, hex) in [UInt32(0x78b8ac), 0xdc907d, 0, 0xaaa0d8, 0x8da5bf].enumerated() {
        let rect = CGRect(x: 112 + i * 104, y: 62, width: 64, height: 64)
        if i == 2 { c.draw(render(64), in: rect); continue }
        c.setFillColor(colour(hex))
        if i % 2 == 0 { c.fillEllipse(in: rect.insetBy(dx: 6, dy: 6)) }
        else {
            c.addPath(CGPath(roundedRect: rect.insetBy(dx: 6, dy: 6),
                             cornerWidth: 12, cornerHeight: 12, transform: nil))
            c.fillPath()
        }
    }
    try writePNG(c.makeImage()!, to: directory.appendingPathComponent("dock-mock.png"))
}

precondition(CommandLine.arguments.count == 2 || CommandLine.arguments.count == 4,
             "Usage: xcrun swift scripts/make-icon.swift <Assets.xcassets> [--review <directory>]")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icon = output.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
for size in sizes { try writePNG(render(size), to: icon.appendingPathComponent("icon-\(size).png")) }
let info: [String: Any] = ["author": "xcode", "version": 1]
func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try (data + Data([10])).write(to: url)
}
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x",
                       "filename": "icon-\(size * scale).png"])
    }
}
try writeJSON(["info": info], to: output.appendingPathComponent("Contents.json"))
try writeJSON(["images": images, "info": info], to: icon.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count == 4 {
    precondition(CommandLine.arguments[2] == "--review")
    try review(at: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
}
