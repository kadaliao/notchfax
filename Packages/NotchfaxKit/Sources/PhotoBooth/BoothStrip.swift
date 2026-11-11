import CoreGraphics
import CoreImage
import ImageIO
import PrintKit
import SwiftUI
import UniformTypeIdentifiers

/// Turns four stills into a photo-booth strip: the look applied at full resolution,
/// a print-sized copy for the sheet, and a high-resolution PNG for drag-out.
public enum BoothStrip {
    /// Paper and frame geometry, straight from PrintKit.
    public static var sheetSize: CGSize { Paper.photoStrip.defaultSize }
    public static var contentRect: CGRect { Paper.photoStrip.contentRect(in: sheetSize) }
    public static var frameRects: [CGRect] { Paper.stripFrameRects(contentSize: contentRect.size) }
    /// Width / height of one frame; the viewfinder crops to this so what is framed prints.
    public static var frameAspect: CGFloat {
        let frame = frameRects[0]
        return frame.width / frame.height
    }

    /// Long side of each frame handed to the sheet renderer (photo paper renders at 3x).
    static let printPixels = 320
    /// Resolution of the exported strip, in pixels per point.
    static let exportScale: CGFloat = 8

    public struct Developed: Sendable {
        /// The look applied, full resolution.
        public var frames: [CGImage]
        /// The same, small enough for the sheet.
        public var printFrames: [CGImage]
    }

    /// Applies the look to every still. Runs off the main actor.
    @concurrent
    public static func develop(_ stills: [CGImage], look: BoothLook) async -> Developed {
        let context = CIContext(options: [.cacheIntermediates: false])
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        var frames: [CGImage] = []
        for (index, still) in stills.enumerated() {
            let input = CIImage(cgImage: still)
            let output = look.apply(to: input, grainSeed: 101 + index * 37)
            frames.append(context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space) ?? still)
        }
        let printFrames = frames.map { downscaled($0, maxPixel: printPixels) }
        return Developed(frames: frames, printFrames: printFrames)
    }

    /// The footer line: the date and time of the sitting.
    public static func caption(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d.%02d.%02d · %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    @MainActor
    public static func job(_ developed: Developed, date: Date) -> PrintJob {
        let caption = caption(for: date)
        let sheet = PaperSheet(.photoStrip, size: sheetSize) {
            PhotoStripContent(frames: developed.printFrames)
                .overlay(alignment: .bottom) { StripFooter(text: caption) }
        }
        let export = StripExport(frames: developed.frames, caption: renderCaption(caption, scale: exportScale), scale: exportScale)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let name = String(format: "大头贴 %04d-%02d-%02d %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return PrintJob(
            sheet,
            autoRetract: .after(18),
            export: PNGExport(filename: name) { try await export.png() }
        )
    }

    /// The footer drawn once at export resolution.
    @MainActor
    static func renderCaption(_ text: String, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: StripFooter(text: text).environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixel else { return image }
        let factor = Double(maxPixel) / Double(long)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let ctx = bitmap(width: width, height: height) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

/// The date along the bottom of the strip, set small like a booth's own imprint.
struct StripFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 5.8, weight: .medium, design: .monospaced))
            .tracking(0.45)
            .foregroundStyle(Color.black.opacity(0.5))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: BoothStrip.contentRect.width, height: Paper.stripFooterHeight)
            .offset(y: 1)
    }
}

/// The strip as a PNG, laid out like the sheet but at `scale` pixels per point.
struct StripExport: Sendable {
    var frames: [CGImage]
    var caption: CGImage?
    var scale: CGFloat

    @concurrent
    func png() async throws -> Data {
        guard let image = composite(), let data = Self.pngData(image) else { throw ExportError.failed }
        return data
    }

    func composite() -> CGImage? {
        let size = BoothStrip.sheetSize
        let content = BoothStrip.contentRect
        guard let ctx = BoothStrip.bitmap(width: Int(size.width * scale), height: Int(size.height * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        let sheet = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.986, green: 0.982, blue: 0.970, alpha: 1))
        ctx.fill(sheet)

        for (index, rect) in BoothStrip.frameRects.enumerated() {
            let target = rect.offsetBy(dx: content.minX, dy: content.minY)
            if index < frames.count {
                Self.draw(frames[index], aspectFillIn: target, context: ctx)
            } else {
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(target)
            }
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.14))
            ctx.setLineWidth(0.5)
            ctx.stroke(target.insetBy(dx: 0.25, dy: 0.25))
        }
        if let caption {
            let height = Paper.stripFooterHeight
            let rect = CGRect(x: content.minX, y: content.maxY - height, width: content.width, height: height)
            Self.draw(caption, in: rect, context: ctx)
        }
        return ctx.makeImage()
    }

    /// Draws upright into the y-down context.
    private static func draw(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func draw(_ image: CGImage, aspectFillIn rect: CGRect, context ctx: CGContext) {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        var target = rect
        if aspect > rect.width / rect.height {
            target.size.width = rect.height * aspect
            target.origin.x = rect.midX - target.width / 2
        } else {
            target.size.height = rect.width / aspect
            target.origin.y = rect.midY - target.height / 2
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        draw(image, in: target, context: ctx)
        ctx.restoreGState()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    enum ExportError: Error { case failed }
}
