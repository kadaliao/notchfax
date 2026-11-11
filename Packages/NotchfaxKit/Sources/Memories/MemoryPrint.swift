import CoreGraphics
import ImageIO
import PrintKit
import SwiftUI
import UniformTypeIdentifiers

/// Where things go on a memory print.
///
/// A lab print: the picture inside a white border, the camera's orange dot-matrix date
/// in one bottom corner and, opposite it, a quiet line saying how long ago it was.
public struct MemoryPrintLayout: Sendable, Equatable {
    /// Prints are cropped to between 2:3 and 3:2, like lab paper; panoramas and
    /// phone-shaped pictures are cut to the nearest print shape.
    public static let aspectRange: ClosedRange<Double> = (2.0 / 3.0)...(3.0 / 2.0)

    /// Whole sheet, in points.
    public var sheetSize: CGSize
    /// The picture, in sheet coordinates (origin top-left). It fills the content area.
    public var photoRect: CGRect
    /// The picture's shape after cropping, width / height.
    public var aspect: Double

    public init(imageAspect: Double) {
        let aspect = min(Self.aspectRange.upperBound, max(Self.aspectRange.lowerBound, imageAspect))
        let insets = Paper.glossyPhoto.contentInsets
        let long = Paper.glossyPhoto.defaultSize.width - insets.leading - insets.trailing
        // Same proportions as PrintKit's own photo sizing: landscape prints are full
        // width; upright ones are a little taller than the landscape ones are wide.
        let photo: CGSize = aspect >= 1
            ? CGSize(width: long, height: (long / aspect).rounded())
            : CGSize(width: (long * 1.2 * aspect).rounded(), height: (long * 1.2).rounded())
        self.aspect = aspect
        photoRect = CGRect(x: insets.leading, y: insets.top, width: photo.width, height: photo.height)
        sheetSize = CGSize(width: photo.width + insets.leading + insets.trailing, height: photo.height + insets.top + insets.bottom)
    }
}

/// The printed picture: photo, a breath of shade along the bottom edge so the lettering
/// reads on any picture, the caption bottom-left and the date stamp bottom-right.
struct MemoryPrintContent: View {
    let image: CGImage
    let date: Date
    let caption: String

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay(alignment: .bottom) { MemoryScrim().frame(height: proxy.size.height * MemoryScrim.coverage) }
                .overlay(alignment: .bottomLeading) { MemoryCaption(text: caption) }
                .overlay(alignment: .bottomTrailing) { MemoryStamp(date: date) }
        }
    }
}

/// A faint shade at the bottom of the picture, like the edge of a print that caught less light.
struct MemoryScrim: View {
    nonisolated static let coverage: CGFloat = 0.34
    nonisolated static let depth: Double = 0.26

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(Self.depth * 0.45), location: 0.55),
                .init(color: .black.opacity(Self.depth), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

/// "3 年前的今天", set small and light, sitting on the stamp's baseline.
struct MemoryCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 6.4, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 0.8, y: 0.3)
            .padding(.leading, 5.5)
            .padding(.bottom, 4)
    }
}

/// The dot-matrix date. A finer dot than PrintKit's default keeps it the size a film
/// camera's imprint is relative to the frame; 0.75 pt still lands on whole pixels at 3x.
struct MemoryStamp: View {
    static let dotSize: CGFloat = 0.75
    let date: Date

    var body: some View {
        DateStamp(date, dotSize: Self.dotSize)
            .padding(.trailing, 3.5)
            .padding(.bottom, 3)
    }
}

// MARK: - Job

/// Builds the print for one memory.
@MainActor
enum MemoryPrint {
    /// Long side of the picture handed to the sheet renderer. PrintKit rasterises photo
    /// paper at 3x, so this leaves headroom for the 148-point-wide picture.
    static let printPixels = 960

    struct Prepared: Sendable {
        var candidate: MemoryCandidate
        /// For the sheet on screen.
        var printImage: CGImage
        /// For the file a dragged-out print becomes.
        var exportImage: CGImage
    }

    static func job(
        _ prepared: Prepared,
        today: Date,
        calendar: MemoryCalendar,
        actions: [PaperAction],
        onEvent: (@MainActor (PrintEvent, PrintHandle) -> Void)? = nil
    ) -> PrintJob {
        let candidate = prepared.candidate
        let layout = MemoryPrintLayout(imageAspect: Double(prepared.printImage.width) / Double(max(1, prepared.printImage.height)))
        let caption = calendar.caption(for: candidate.date, today: today)
        let sheet = PaperSheet(.glossyPhoto, size: layout.sheetSize) {
            MemoryPrintContent(image: prepared.printImage, date: candidate.date, caption: caption)
        }
        let export = exportRecipe(prepared.exportImage, date: candidate.date, caption: caption, layout: layout)
        let filename = "那年今日 \(exportName(candidate.date, calendar: calendar.calendar))"
        return PrintJob(
            sheet,
            autoRetract: .after(16),
            export: PNGExport(filename: filename) { try await export.png() },
            actions: actions,
            onEvent: onEvent
        )
    }

    /// The small overlays are drawn here, on the main actor, while they are cheap; the
    /// large composite happens later, off it.
    static func exportRecipe(_ image: CGImage, date: Date, caption: String, layout: MemoryPrintLayout) -> MemoryExport {
        let longPoints = max(layout.photoRect.width, layout.photoRect.height)
        let sourceLong = CGFloat(max(image.width, image.height))
        let scale = max(4, min(14, sourceLong / longPoints)).rounded(.down)
        let stamp = render(MemoryStamp(date: date), scale: scale)
        let captionImage = render(MemoryCaption(text: caption), scale: scale)
        return MemoryExport(image: image, layout: layout, scale: scale, stamp: stamp, caption: captionImage)
    }

    private static func render(_ view: some View, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    private static func exportName(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Export

/// A memory print as a high-resolution PNG: paper, picture, stamp and caption, as the
/// sheet looks but at the resolution of the original picture.
struct MemoryExport: Sendable {
    var image: CGImage
    var layout: MemoryPrintLayout
    var scale: CGFloat
    var stamp: CGImage?
    var caption: CGImage?

    @concurrent
    func png() async throws -> Data {
        guard let composite = composite(), let data = ImageTools.pngData(composite) else {
            throw MemoryLibraryError.imageUnavailable
        }
        return data
    }

    func composite() -> CGImage? {
        let size = layout.sheetSize
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard let ctx = ImageTools.context(width: width, height: height) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Top-left origin, like the layout.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let sheet = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 1.4, cornerHeight: 1.4, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 0.990, green: 0.990, blue: 0.984, alpha: 1))
        ctx.fill(sheet)

        let photo = layout.photoRect
        ImageTools.draw(image, aspectFillIn: photo, flipped: true, context: ctx)
        drawScrim(in: photo, context: ctx)
        // The overlays were rendered with their padding, so they sit in the corners as on screen.
        if let caption {
            let size = CGSize(width: CGFloat(caption.width) / scale, height: CGFloat(caption.height) / scale)
            ImageTools.draw(caption, in: CGRect(x: photo.minX, y: photo.maxY - size.height, width: size.width, height: size.height), flipped: true, context: ctx)
        }
        if let stamp {
            let size = CGSize(width: CGFloat(stamp.width) / scale, height: CGFloat(stamp.height) / scale)
            ImageTools.draw(stamp, in: CGRect(x: photo.maxX - size.width, y: photo.maxY - size.height, width: size.width, height: size.height), flipped: true, context: ctx)
        }
        // The emulsion begins a hair inside the border.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.16))
        ctx.setLineWidth(0.5)
        ctx.stroke(photo.insetBy(dx: 0.25, dy: 0.25))
        return ctx.makeImage()
    }

    /// The same shade as `MemoryScrim`, in a y-down context.
    private func drawScrim(in photo: CGRect, context ctx: CGContext) {
        let height = photo.height * MemoryScrim.coverage
        let depth = CGFloat(MemoryScrim.depth)
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: depth * 0.45), CGColor(gray: 0, alpha: depth)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: photo.minX, y: photo.maxY - height, width: photo.width, height: height))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: photo.maxY - height), end: CGPoint(x: 0, y: photo.maxY), options: [])
        ctx.restoreGState()
    }
}

/// Small Core Graphics helpers that are safe to call from any thread.
enum ImageTools {
    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// `image` no larger than `maxPixel` on its long side.
    static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixel else { return image }
        let factor = Double(maxPixel) / Double(long)
        let width = Int((Double(image.width) * factor).rounded()), height = Int((Double(image.height) * factor).rounded())
        guard let ctx = context(width: width, height: height) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Draws into a context whose y axis points down (`flipped`), keeping the image upright.
    static func draw(_ image: CGImage, in rect: CGRect, flipped: Bool, context ctx: CGContext) {
        ctx.saveGState()
        if flipped {
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        } else {
            ctx.draw(image, in: rect)
        }
        ctx.restoreGState()
    }

    static func draw(_ image: CGImage, aspectFillIn rect: CGRect, flipped: Bool, context ctx: CGContext) {
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
        draw(image, in: target, flipped: flipped, context: ctx)
        ctx.restoreGState()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
