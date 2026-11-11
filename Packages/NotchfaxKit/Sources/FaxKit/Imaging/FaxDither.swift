import CoreGraphics
import Foundation
import ImageIO

/// A picture reduced to what a thermal print head can do: one dot, black or not.
struct BilevelImage: Sendable, Equatable {
    let width: Int
    let height: Int
    /// Row-major, one byte per pixel; 1 = ink.
    let ink: [UInt8]

    /// The same dots on a coarser grid, still strictly black or white: each output pixel takes
    /// the nearest source dot. Used where the picture must sit on a narrower sheet without
    /// being smeared to grey and dithered a second time by the paper renderer.
    func resampled(toWidth target: Int) -> BilevelImage {
        guard target > 0, target < width else { return self }
        let targetHeight = max(1, Int((Double(height) * Double(target) / Double(width)).rounded()))
        var out = [UInt8](repeating: 0, count: target * targetHeight)
        for y in 0..<targetHeight {
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(targetHeight)))
            for x in 0..<target {
                let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(target)))
                out[y * target + x] = ink[sy * width + sx]
            }
        }
        return BilevelImage(width: target, height: targetHeight, ink: out)
    }

    /// The dots as an 8-bit grayscale image, for previews and printing.
    func cgImage() -> CGImage? {
        let gray = ink.map { $0 == 0 ? UInt8(255) : UInt8(0) }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// A picture ready to send: the dots and the exact PNG the server will receive.
struct DitheredImage: Sendable, Equatable {
    let bits: BilevelImage
    let png: Data

    var width: Int { bits.width }
    var height: Int { bits.height }
}

/// Turns any picture into a fax: scaled to the print head, toned for thermal paper,
/// error-diffused to 1 bit, and encoded as a grayscale 1-bit PNG under 64 KB.
enum FaxDither {
    static let maxWidth = 384
    static let maxHeight = 768
    static let maxBytes = 64 * 1024

    struct Tone: Sendable, Equatable {
        /// Fraction of the darkest and lightest pixels clipped when stretching levels.
        var clip: Float = 0.006
        /// Cap on how much a flat picture's levels may be stretched.
        var maxStretch: Float = 2.6
        /// Below 1 lifts the midtones; thermal dots spread, so prints run dark.
        var gamma: Float = 0.86
        /// Unsharp mask that keeps edges legible at 384 dots.
        var sharpenAmount: Float = 0.7
        var sharpenRadius: Int = 2
    }

    enum Failure: Error { case unreadable, tooLarge }

    /// The whole pipeline. Shrinks further until the PNG fits under the size limit.
    static func make(from image: CGImage, tone: Tone = Tone()) throws -> DitheredImage {
        var (width, height) = targetSize(width: image.width, height: image.height)
        for _ in 0..<12 {
            guard let gray = grayscale(image, width: width, height: height) else { throw Failure.unreadable }
            let prepared = prepare(gray, width: width, height: height, tone: tone)
            let bits = atkinson(prepared, width: width, height: height)
            let png = PNGEncoder.encodeBilevel(width: width, height: height, ink: bits.ink)
            if png.count <= maxBytes { return DitheredImage(bits: bits, png: png) }
            width = max(8, Int(Double(width) * 0.9))
            height = max(8, Int(Double(height) * 0.9))
        }
        throw Failure.tooLarge
    }

    /// Fills the print width, unless that would make the picture taller than the page allows.
    static func targetSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = Double(max(1, width)), h = Double(max(1, height))
        let scale = min(Double(maxWidth) / w, Double(maxHeight) / h)
        return (max(1, min(maxWidth, Int((w * scale).rounded()))), max(1, min(maxHeight, Int((h * scale).rounded()))))
    }

    // MARK: Steps

    /// Lightness in 0 (black) … 1 (white), gamma-encoded, composited over white paper.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        // Large reductions in one step alias; go via an intermediate at twice the target.
        var source = image
        if image.width > width * 3 || image.height > height * 3,
           let half = draw(image, width: width * 2, height: height * 2)?.makeImage() {
            source = half
        }
        guard let context = draw(source, width: width, height: height), let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var gray = [Float](repeating: 1, count: width * height)
        for y in 0..<height {
            let row = pixels + y * context.bytesPerRow
            for x in 0..<width { gray[y * width + x] = Float(row[x]) / 255 }
        }
        return gray
    }

    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Levels, midtone lift and a gentle unsharp mask.
    static func prepare(_ gray: [Float], width: Int, height: Int, tone: Tone) -> [Float] {
        var values = gray
        // Levels from a histogram, ignoring a sliver of outliers at each end.
        var histogram = [Int](repeating: 0, count: 256)
        for v in values { histogram[Int(min(255, max(0, v * 255)))] += 1 }
        let clipCount = Int(Float(values.count) * tone.clip)
        var low = 0, high = 255, seen = 0
        for i in 0..<256 { seen += histogram[i]; if seen > clipCount { low = i; break } }
        seen = 0
        for i in stride(from: 255, through: 0, by: -1) { seen += histogram[i]; if seen > clipCount { high = i; break } }
        var black = Float(low) / 255, white = Float(high) / 255
        if white - black < 1 / tone.maxStretch {
            let middle = (white + black) / 2
            black = middle - 0.5 / tone.maxStretch
            white = middle + 0.5 / tone.maxStretch
        }
        let range = max(0.01, white - black)
        for i in values.indices {
            let v = min(1, max(0, (values[i] - black) / range))
            values[i] = pow(v, tone.gamma)
        }

        guard tone.sharpenAmount > 0, tone.sharpenRadius > 0 else { return values }
        let blurred = boxBlur(boxBlur(values, width: width, height: height, radius: tone.sharpenRadius), width: width, height: height, radius: tone.sharpenRadius)
        for i in values.indices {
            values[i] = min(1, max(0, values[i] + tone.sharpenAmount * (values[i] - blurred[i])))
        }
        return values
    }

    /// Separable box blur; two passes approximate a Gaussian.
    static func boxBlur(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            var sum: Float = 0
            let base = y * width
            for x in -radius...radius { sum += input[base + min(width - 1, max(0, x))] }
            for x in 0..<width {
                horizontal[base + x] = sum / Float(radius * 2 + 1)
                sum += input[base + min(width - 1, x + radius + 1)] - input[base + max(0, x - radius)]
            }
        }
        var output = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var sum: Float = 0
            for y in -radius...radius { sum += horizontal[min(height - 1, max(0, y)) * width + x] }
            for y in 0..<height {
                output[y * width + x] = sum / Float(radius * 2 + 1)
                sum += horizontal[min(height - 1, y + radius + 1) * width + x] - horizontal[max(0, y - radius) * width + x]
            }
        }
        return output
    }

    /// Atkinson error diffusion with serpentine scanning. Passing on only 6/8 of the error
    /// keeps highlights clean and shadows open, which suits a narrow thermal print.
    static func atkinson(_ gray: [Float], width: Int, height: Int) -> BilevelImage {
        var value = gray
        var ink = [UInt8](repeating: 0, count: width * height)
        let neighbours: [(dx: Int, dy: Int)] = [(1, 0), (2, 0), (-1, 1), (0, 1), (1, 1), (0, 2)]
        for y in 0..<height {
            let forward = y % 2 == 0
            for step in 0..<width {
                let x = forward ? step : width - 1 - step
                let i = y * width + x
                let old = value[i]
                let new: Float = old < 0.5 ? 0 : 1
                if new == 0 { ink[i] = 1 }
                let error = (old - new) / 8
                for n in neighbours {
                    let nx = x + (forward ? n.dx : -n.dx), ny = y + n.dy
                    guard nx >= 0, nx < width, ny < height else { continue }
                    value[ny * width + nx] += error
                }
            }
        }
        return BilevelImage(width: width, height: height, ink: ink)
    }
}

// MARK: - Loading pictures

enum ImageLoader {
    /// Reads a file with its orientation applied, already reduced to a workable size.
    static func load(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source)
    }

    static func load(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source)
    }

    private static func thumbnail(_ source: CGImageSource) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
