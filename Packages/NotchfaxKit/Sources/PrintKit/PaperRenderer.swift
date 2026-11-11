import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A sheet rasterised and ready to be put on layers.
struct RenderedSheet {
    let paper: Paper
    /// Layout size in points.
    let size: CGSize
    let scale: CGFloat
    /// Stock with the content printed on it. Alpha carries the outline (serrations, corners).
    let printed: CGImage
    /// The same stock with nothing printed, shown where ink has not developed yet.
    let blank: CGImage
    /// Thermal only: blank paper still on the roll, revealed when the sheet is pulled.
    let tail: CGImage?
    let tailLength: CGFloat
}

/// Draws paper. Everything here is CPU work on small bitmaps, done once per sheet.
@MainActor
enum PaperRenderer {
    static let thermalTailLength: CGFloat = 70
    static let serrationPitch: CGFloat = 3.6
    static let serrationDepth: CGFloat = 2.1

    static func render(_ sheet: PaperSheet, size: CGSize, scale: CGFloat, seed: UInt64) -> RenderedSheet {
        let paper = sheet.paper
        let pxW = max(2, Int((size.width * scale).rounded()))
        let pxH = max(2, Int((size.height * scale).rounded()))

        // Roll paper is one continuous web: the leader above the sheet is cut from the same
        // stock, so no seam shows where a torn sheet's top meets its body.
        let tailPx = paper == .thermal ? Int((thermalTailLength * scale).rounded()) : 0
        let web = Bitmap(width: pxW, height: pxH + tailPx)
        fillStock(web, paper: paper, scale: scale, seed: seed)
        let stock = web.rows(from: tailPx, count: pxH)

        let blankBitmap = stock.copy()
        shade(blankBitmap, paper: paper, scale: scale)
        let blank = clipped(blankBitmap, paper: paper, size: size, scale: scale)

        let contentRect = paper.contentRect(in: size)
        if let content = rasterise(sheet.content, size: contentRect.size, scale: scale) {
            if paper == .thermal {
                thermalPrint(content, onto: stock, at: contentRect, scale: scale, seed: seed)
            } else {
                drawContent(content, onto: stock, at: contentRect, sheetSize: size, scale: scale, framed: paper == .glossyPhoto)
            }
        }
        shade(stock, paper: paper, scale: scale)
        let printed = clipped(stock, paper: paper, size: size, scale: scale)

        var tail: CGImage?
        if tailPx > 0 {
            let tailBitmap = web.rows(from: 0, count: tailPx)
            shade(tailBitmap, paper: paper, scale: scale, sidesOnly: true)
            tail = tailBitmap.image()
        }
        return RenderedSheet(
            paper: paper, size: size, scale: scale,
            printed: printed, blank: blank,
            tail: tail, tailLength: tail == nil ? 0 : thermalTailLength
        )
    }

    /// Unprinted stock, for live SwiftUI surfaces.
    static func blankStock(_ paper: Paper, size: CGSize, scale: CGFloat) -> CGImage {
        let bitmap = Bitmap(
            width: max(2, Int((size.width * scale).rounded())),
            height: max(2, Int((size.height * scale).rounded()))
        )
        fillStock(bitmap, paper: paper, scale: scale, seed: 5)
        shade(bitmap, paper: paper, scale: scale)
        return clipped(bitmap, paper: paper, size: size, scale: scale)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Outline

    /// The sheet's silhouette in a y-up space with the origin at its bottom-left corner.
    static func outline(_ paper: Paper, size: CGSize) -> CGPath {
        switch paper {
        case .thermal:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            for point in serration(width: size.width, seed: 3, irregularity: 0.12).reversed() {
                path.addLine(to: CGPoint(x: point.x, y: serrationDepth - point.y))
            }
            path.closeSubpath()
            return path
        case .glossyPhoto, .photoStrip:
            return CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 1.4, cornerHeight: 1.4, transform: nil)
        }
    }

    /// A zigzag across `width`. `y` is 0 at the valleys and up to `serrationDepth`
    /// at the tips of the teeth, which point away from the paper.
    static func serration(width: CGFloat, seed: UInt64, irregularity: Double) -> [CGPoint] {
        let count = max(2, Int((width / serrationPitch).rounded()) * 2)
        return (0...count).map { i in
            let x = width * CGFloat(i) / CGFloat(count)
            let tip = serrationDepth * (1 - irregularity * Hash.unit(i, 11, seed))
            return CGPoint(x: x, y: i.isMultiple(of: 2) ? 0 : tip)
        }
    }

    // MARK: Stock

    private struct Stock {
        var r: Double, g: Double, b: Double
        var grain: Double, fibre: Double, mottle: Double, sheen: Double
    }

    private static func stock(_ paper: Paper) -> Stock {
        switch paper {
        case .thermal: Stock(r: 0.968, g: 0.958, b: 0.934, grain: 0.011, fibre: 0.010, mottle: 0.009, sheen: 0.006)
        case .glossyPhoto: Stock(r: 0.990, g: 0.990, b: 0.984, grain: 0.004, fibre: 0.0, mottle: 0.005, sheen: 0.014)
        case .photoStrip: Stock(r: 0.986, g: 0.982, b: 0.970, grain: 0.005, fibre: 0.0, mottle: 0.006, sheen: 0.012)
        }
    }

    private static func fillStock(_ bitmap: Bitmap, paper: Paper, scale: CGFloat, seed: UInt64) {
        let s = stock(paper)
        let k = Double(scale)
        let w = bitmap.width, h = bitmap.height
        for y in 0..<h {
            let row = bitmap.pixels + y * bitmap.rowBytes
            for x in 0..<w {
                let dx = Double(x), dy = Double(y)
                var f = 1.0
                f += (Hash.unit(x, y, seed) - 0.5) * 2 * s.grain
                if s.fibre > 0 {
                    f += (Hash.smooth(dx / (0.9 * k), dy / (7 * k), seed &+ 1) - 0.5) * 2 * s.fibre
                }
                f += (Hash.smooth(dx / (20 * k), dy / (20 * k), seed &+ 2) - 0.5) * 2 * s.mottle
                // Light falls from the upper left.
                f += s.sheen * (0.5 - (dx / Double(w) * 0.6 + dy / Double(h) * 0.4)) * 2
                let p = row + x * 4
                p[0] = byte(s.r * f)
                p[1] = byte(s.g * f)
                p[2] = byte(s.b * f)
                p[3] = 255
            }
        }
    }

    /// Thickness at the edges, a slight cup across the width and the curl at the free end.
    private static func shade(_ bitmap: Bitmap, paper: Paper, scale: CGFloat, sidesOnly: Bool = false) {
        let w = bitmap.width, h = bitmap.height
        let edge = Double(scale) * 0.8
        let curlStart = paper == .thermal ? 0.76 : 0.84
        let curlDepth = paper == .thermal ? 0.055 : 0.03
        for y in 0..<h {
            let row = bitmap.pixels + y * bitmap.rowBytes
            let v = Double(y) / Double(max(1, h - 1))
            var rowShade = 0.0
            if !sidesOnly {
                if paper != .thermal, Double(y) < edge { rowShade += 0.035 * (1 - Double(y) / edge) }
                if paper != .thermal, Double(h - 1 - y) < edge { rowShade -= 0.10 * (1 - Double(h - 1 - y) / edge) }
                if v > curlStart {
                    let u = (v - curlStart) / (1 - curlStart)
                    rowShade += 0.018 * sin(.pi * min(1, u * 1.25)) - curlDepth * u * u * u
                }
            }
            for x in 0..<w {
                let hx = Double(x) / Double(max(1, w - 1)) * 2 - 1
                var f = 1 + rowShade - 0.016 * hx * hx
                if Double(x) < edge { f += 0.03 * (1 - Double(x) / edge) }
                if Double(w - 1 - x) < edge { f -= 0.075 * (1 - Double(w - 1 - x) / edge) }
                let p = row + x * 4
                p[0] = byte(Double(p[0]) / 255 * f)
                p[1] = byte(Double(p[1]) / 255 * f)
                p[2] = byte(Double(p[2]) / 255 * f)
            }
        }
    }

    private static func clipped(_ bitmap: Bitmap, paper: Paper, size: CGSize, scale: CGFloat) -> CGImage {
        let output = Bitmap(width: bitmap.width, height: bitmap.height)
        let ctx = output.context
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(bitmap.width) / size.width, y: CGFloat(bitmap.height) / size.height)
        ctx.addPath(outline(paper, size: size))
        ctx.clip()
        ctx.scaleBy(x: size.width / CGFloat(bitmap.width), y: size.height / CGFloat(bitmap.height))
        ctx.draw(bitmap.image(), in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        ctx.restoreGState()
        return output.image()
    }

    // MARK: Content

    private static func rasterise(_ content: PaperContent, size: CGSize, scale: CGFloat) -> CGImage? {
        switch content {
        case .blank:
            return nil
        case .image(let image):
            return image
        case .view(let view):
            let renderer = ImageRenderer(
                content: view
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.cgImage
        }
    }

    /// Aspect-fills `image` into `rect` (sheet coordinates, origin top-left).
    private static func draw(_ image: CGImage, in rect: CGRect, of bitmap: Bitmap, sheetHeight: CGFloat, scale: CGFloat) {
        let ctx = bitmap.context
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let target = CGRect(x: rect.minX, y: sheetHeight - rect.maxY, width: rect.width, height: rect.height)
        ctx.clip(to: target)
        let imageAspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var drawRect = target
        if imageAspect > target.width / target.height {
            drawRect.size.width = target.height * imageAspect
            drawRect.origin.x = target.midX - drawRect.width / 2
        } else {
            drawRect.size.height = target.width / imageAspect
            drawRect.origin.y = target.midY - drawRect.height / 2
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()
    }

    private static func drawContent(
        _ image: CGImage, onto bitmap: Bitmap, at rect: CGRect, sheetSize: CGSize, scale: CGFloat, framed: Bool
    ) {
        draw(image, in: rect, of: bitmap, sheetHeight: sheetSize.height, scale: scale)
        guard framed else { return }
        // The emulsion sits a hair below the border: a faint step where the picture begins.
        let ctx = bitmap.context
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        let target = CGRect(x: rect.minX, y: sheetSize.height - rect.maxY, width: rect.width, height: rect.height)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.16))
        ctx.setLineWidth(0.5)
        ctx.stroke(target.insetBy(dx: 0.25, dy: 0.25))
        ctx.restoreGState()
    }

    private static let bayer: [Double] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ].map { ($0 + 0.5) / 16 }

    /// Burns `image` into thermal stock: one dot per pixel, dithered, with the uneven
    /// density of a worn print head.
    private static func thermalPrint(_ image: CGImage, onto bitmap: Bitmap, at rect: CGRect, scale: CGFloat, seed: UInt64) {
        let w = max(1, Int((rect.width * scale).rounded()))
        let h = max(1, Int((rect.height * scale).rounded()))
        let source = Bitmap(width: w, height: h)
        source.context.setFillColor(CGColor(gray: 1, alpha: 1))
        source.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height), of: source, sheetHeight: rect.height, scale: scale)

        let ox = Int((rect.minX * scale).rounded()), oy = Int((rect.minY * scale).rounded())
        let ink = (r: 0.135, g: 0.125, b: 0.155)
        let band = max(2, Int(14 * scale))
        for y in 0..<h {
            let ty = y + oy
            guard ty >= 0, ty < bitmap.height else { continue }
            let src = source.pixels + y * source.rowBytes
            let dst = bitmap.pixels + ty * bitmap.rowBytes
            let rowGain = 0.93 + 0.07 * Hash.unit(0, y / band, seed &+ 5)
            for x in 0..<w {
                let tx = x + ox
                guard tx >= 0, tx < bitmap.width else { continue }
                let s = src + x * 4
                let luminance = (0.299 * Double(s[0]) + 0.587 * Double(s[1]) + 0.114 * Double(s[2])) / 255
                let darkness = 1 - luminance
                guard darkness > 0.04 else { continue }
                let threshold = 0.5 + (bayer[(y & 3) * 4 + (x & 3)] - 0.5) * 0.74
                var k = min(1, max(0, (darkness - threshold) * 5 + 0.5))
                guard k > 0 else { continue }
                let weakColumn = Hash.unit(x, 0, seed &+ 6) < 0.018 ? 0.55 : 1
                let columnGain = 0.9 + 0.1 * Hash.unit(x, 1, seed &+ 6)
                let density = 0.78 + 0.22 * Hash.smooth(Double(x) / (11 * Double(scale)), Double(y) / (7 * Double(scale)), seed &+ 7)
                if Hash.unit(x, y, seed &+ 8) < 0.035 { k *= 0.45 }
                k *= 0.95 * density * columnGain * weakColumn * rowGain
                let d = dst + tx * 4
                d[0] = byte(Double(d[0]) / 255 * (1 - k) + ink.r * k)
                d[1] = byte(Double(d[1]) / 255 * (1 - k) + ink.g * k)
                d[2] = byte(Double(d[2]) / 255 * (1 - k) + ink.b * k)
            }
        }
    }

    @inline(__always)
    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, (value * 255).rounded())))
    }
}

/// An RGBA8 bitmap whose first row in memory is the top of the image.
final class Bitmap {
    let width: Int
    let height: Int
    let context: CGContext

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: self.width,
            height: self.height,
            bitsPerComponent: 8,
            bytesPerRow: self.width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("Could not create a \(width)x\(height) bitmap context")
        }
        context = ctx
    }

    var rowBytes: Int { context.bytesPerRow }

    var pixels: UnsafeMutablePointer<UInt8> {
        guard let data = context.data else { preconditionFailure("Bitmap context has no backing store") }
        return data.assumingMemoryBound(to: UInt8.self)
    }

    func copy() -> Bitmap {
        let other = Bitmap(width: width, height: height)
        other.pixels.update(from: pixels, count: rowBytes * height)
        return other
    }

    /// A new bitmap holding `count` rows starting at row `from` (0 = top).
    func rows(from: Int, count: Int) -> Bitmap {
        let other = Bitmap(width: width, height: count)
        other.pixels.update(from: pixels + from * rowBytes, count: min(count, height - from) * rowBytes)
        return other
    }

    func image() -> CGImage {
        guard let image = context.makeImage() else { preconditionFailure("Bitmap context produced no image") }
        return image
    }
}

/// Soft shadows as nine-slice images, so one bitmap serves sheets of any size.
@MainActor
enum ShadowImage {
    struct Slice {
        let image: CGImage
        /// How far the image extends beyond the rectangle casting the shadow, in points.
        let pad: CGFloat
        let center: CGRect
    }

    private static var cache: [Int: Slice] = [:]

    static func slice(blur: CGFloat, scale: CGFloat = 2) -> Slice {
        let key = Int(blur * 10) * 10 + Int(scale)
        if let cached = cache[key] { return cached }
        let pad = (blur * 2.4).rounded(.up) + 2
        let core: CGFloat = max(24, blur * 4)
        let side = core + pad * 2
        let px = Int(side * scale)
        let bitmap = Bitmap(width: px, height: px)
        let ctx = bitmap.context
        // Draw the caster off-canvas so only its shadow lands in the image.
        let away = CGFloat(px) * 2
        ctx.setShadow(offset: CGSize(width: away, height: 0), blur: blur * scale, color: CGColor(gray: 0, alpha: 1))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: pad * scale - away, y: pad * scale, width: core * scale, height: core * scale))
        let unit = 1 / side
        let slice = Slice(
            image: bitmap.image(),
            pad: pad,
            center: CGRect(x: (side / 2 - 1) * unit, y: (side / 2 - 1) * unit, width: 2 * unit, height: 2 * unit)
        )
        cache[key] = slice
        return slice
    }
}
