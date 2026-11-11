#!/usr/bin/env swift
// Draws the Notchfax app icon and writes the asset catalog.
//
//     swift scripts/make-icon.swift App/Assets.xcassets
//
// The icon is the product in one picture: the top of a screen, a notch, and a sheet of
// thermal paper feeding out of it. Everything is drawn here; there are no source images.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// Draws the icon into a square of `pixels`. All measurements are on a 1024 grid, y up.
func drawIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high

    // The standard macOS icon body: an 824-point rounded square with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * CGFloat(pixels) / 1024), blur: 24 * CGFloat(pixels) / 1024, color: colour(0x000000, 0.32))
    ctx.addPath(bodyPath)
    ctx.setFillColor(colour(0xD8DCE4))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // A calm desktop: cool at the top, warming slightly towards the bottom.
    ctx.drawLinearGradient(
        gradient([(0, colour(0xC3CCDA)), (0.55, colour(0xD9DDE6)), (1, colour(0xECE6E2))]),
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: []
    )
    // The strip of menu bar across the top of the screen.
    ctx.setFillColor(colour(0xFFFFFF, 0.42))
    ctx.fill(CGRect(x: body.minX, y: body.maxY - 104, width: body.width, height: 104))
    ctx.setFillColor(colour(0x000000, 0.05))
    ctx.fill(CGRect(x: body.minX, y: body.maxY - 106, width: body.width, height: 2))

    // Paper, hanging from under the notch.
    let notch = CGRect(x: 512 - 222, y: body.maxY - 118, width: 444, height: 118)
    let paperWidth: CGFloat = 348
    let paperTop = notch.minY + 6
    let paperBottom: CGFloat = 248
    let left = 512 - paperWidth / 2, right = 512 + paperWidth / 2
    let teeth = 12, depth: CGFloat = 13
    let paper = CGMutablePath()
    paper.move(to: CGPoint(x: left, y: paperTop))
    paper.addLine(to: CGPoint(x: right, y: paperTop))
    paper.addLine(to: CGPoint(x: right, y: paperBottom + depth))
    for i in 0..<teeth * 2 {
        let x = right - paperWidth * CGFloat(i + 1) / CGFloat(teeth * 2)
        paper.addLine(to: CGPoint(x: x, y: i.isMultiple(of: 2) ? paperBottom : paperBottom + depth))
    }
    paper.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * CGFloat(pixels) / 1024), blur: 34 * CGFloat(pixels) / 1024, color: colour(0x1B2333, 0.34))
    ctx.addPath(paper)
    ctx.setFillColor(colour(0xFAF8F2))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(paper)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, colour(0xF4F1E9)), (0.12, colour(0xFCFAF5)), (0.82, colour(0xFBF9F3)), (1, colour(0xEDE9DF))]),
        start: CGPoint(x: 0, y: paperTop), end: CGPoint(x: 0, y: paperBottom), options: []
    )
    // The slot's shadow on the paper just below it.
    ctx.drawLinearGradient(
        gradient([(0, colour(0x000000, 0.30)), (0.45, colour(0x000000, 0.08)), (1, colour(0x000000, 0))]),
        start: CGPoint(x: 0, y: paperTop), end: CGPoint(x: 0, y: paperTop - 70), options: []
    )
    // Edges: a little light on the left, a little weight on the right.
    ctx.setFillColor(colour(0xFFFFFF, 0.7))
    ctx.fill(CGRect(x: left, y: paperBottom, width: 3, height: paperTop - paperBottom))
    ctx.setFillColor(colour(0x000000, 0.07))
    ctx.fill(CGRect(x: right - 3, y: paperBottom, width: 3, height: paperTop - paperBottom))

    // What is printed: a header, a dashed rule, a few lines, and the orange date of a photo.
    let ink = colour(0x26242B)
    let margin: CGFloat = 40
    func bar(_ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: CGColor, x: CGFloat? = nil) {
        let rect = CGRect(x: x ?? left + margin, y: y, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    let inner = paperWidth - margin * 2
    var y = paperTop - 96
    bar(y, 118, 26, ink)
    y -= 44
    var x = left + margin
    while x < right - margin - 4 {
        bar(y, min(22, right - margin - x), 8, colour(0x26242B, 0.55), x: x)
        x += 36
    }
    y -= 58
    for fraction in [1.0, 0.86, 0.94, 0.58] as [CGFloat] {
        bar(y, inner * fraction, 22, colour(0x26242B, 0.82))
        y -= 50
    }
    y -= 12
    // A row of dots: the dot-matrix date stamp.
    let dot: CGFloat = 17
    var dx = right - margin - dot
    for index in 0..<6 where index != 2 {
        let rect = CGRect(x: dx - CGFloat(index) * (dot + 9), y: y, width: dot, height: dot)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(colour(0xFF8A1F))
        ctx.fillPath()
        dx -= 0
    }
    ctx.restoreGState()

    // The notch, drawn over the paper so the sheet comes out from behind it.
    let r: CGFloat = 42, ear: CGFloat = 22
    let mouth = CGMutablePath()
    mouth.move(to: CGPoint(x: notch.minX - ear, y: notch.maxY))
    mouth.addQuadCurve(to: CGPoint(x: notch.minX, y: notch.maxY - ear), control: CGPoint(x: notch.minX, y: notch.maxY))
    mouth.addLine(to: CGPoint(x: notch.minX, y: notch.minY + r))
    mouth.addQuadCurve(to: CGPoint(x: notch.minX + r, y: notch.minY), control: CGPoint(x: notch.minX, y: notch.minY))
    mouth.addLine(to: CGPoint(x: notch.maxX - r, y: notch.minY))
    mouth.addQuadCurve(to: CGPoint(x: notch.maxX, y: notch.minY + r), control: CGPoint(x: notch.maxX, y: notch.minY))
    mouth.addLine(to: CGPoint(x: notch.maxX, y: notch.maxY - ear))
    mouth.addQuadCurve(to: CGPoint(x: notch.maxX + ear, y: notch.maxY), control: CGPoint(x: notch.maxX, y: notch.maxY))
    mouth.closeSubpath()
    ctx.addPath(mouth)
    ctx.setFillColor(colour(0x050506))
    ctx.fillPath()
    // A breath of light on the notch's lower lip.
    ctx.saveGState()
    ctx.addPath(mouth)
    ctx.clip()
    ctx.setFillColor(colour(0xFFFFFF, 0.16))
    ctx.fill(CGRect(x: notch.minX + r, y: notch.minY, width: notch.width - r * 2, height: 3))
    ctx.restoreGState()

    // Glass: a soft highlight along the body's top edge and a hairline all round.
    ctx.drawLinearGradient(
        gradient([(0, colour(0xFFFFFF, 0.28)), (1, colour(0xFFFFFF, 0))]),
        start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - 26), options: []
    )
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(colour(0x000000, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <path to Assets.xcassets> [preview.png]\n".utf8))
    exit(64)
}
let catalog = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconset = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var entries: [[String: String]] = []
var drawn: [Int: String] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = drawn[pixels] ?? "icon-\(pixels).png"
        if drawn[pixels] == nil {
            try write(drawIcon(pixels: pixels), to: iconset.appendingPathComponent(name))
            drawn[pixels] = name
        }
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let info: [String: Any] = ["author": "xcode", "version": 1]
try JSONSerialization.data(withJSONObject: ["images": entries, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appendingPathComponent("Contents.json"))
if arguments.count >= 3 {
    try write(drawIcon(pixels: 1024), to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(drawn.count) images to \(iconset.path)")
