import CoreImage
import CoreImage.CIFilterBuiltins

/// The looks the booth offers. Each is a short Core Image chain, applied live to
/// the viewfinder and again, at full resolution, to the printed frames.
public enum BoothLook: String, CaseIterable, Sendable, Identifiable {
    /// Flat, bright colour inside ink outlines, like a cel from an animated film.
    case cartoon
    /// Halftone dots and heavy ink, like a printed comic.
    case comic
    /// A soft pencil drawing on paper.
    case sketch
    /// A handful of loud, flat colours, like a silkscreen poster.
    case pop
    /// Glowing highlights and pastel colour.
    case dreamy
    /// An instant print: creamy highlights, faded blacks, a heavy vignette.
    case instant
    /// Faded, warm film: lifted blacks, amber cast, grain.
    case warm
    /// Cross-processed film: cool shadows, a green-blue cast.
    case cool
    /// Silver-gelatin black and white: deep blacks, soft highlights, a little grain.
    case mono
    /// Clean colour with the slight fall-off of a booth's flash.
    case color

    /// What a booth opened for the first time shoots in.
    public static let standard: BoothLook = .cartoon

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cartoon: "卡通"
        case .comic: "漫画"
        case .sketch: "素描"
        case .pop: "波普"
        case .dreamy: "梦幻"
        case .instant: "拍立得"
        case .warm: "暖调"
        case .cool: "冷调"
        case .mono: "黑白"
        case .color: "原色"
        }
    }

    /// Looks that draw lines or dots are worked out at this width whatever the size of the
    /// picture, so the viewfinder and the print show strokes of the same weight.
    static let drawingWidth: CGFloat = 520

    /// - Parameter grainSeed: moves the grain between frames so it lives like film grain.
    public func apply(to image: CIImage, grainSeed: Int = 0) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, !extent.isInfinite else { return image }
        var out = image
        switch self {
        case .cartoon:
            out = drawn(out) { small in
                // Flatten skin and cloth into a few even tones, then ink the edges.
                var flat = small.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.035, "inputSharpness": 0.7])
                flat = flat.applyingFilter("CIMedianFilter")
                // Lines come from the smoothed picture, so pores and stubble do not turn into specks.
                let lines = flat.applyingFilter("CILineOverlay", parameters: [
                    "inputNRNoiseLevel": 0.07, "inputNRSharpness": 0.7,
                    "inputEdgeIntensity": 0.9, "inputThreshold": 0.27, "inputContrast": 40,
                ])
                flat = colour(flat, saturation: 1.4, contrast: 1.04, brightness: 0.03)
                flat = posterize(flat, levels: 9)
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.5])
                    .cropped(to: small.extent)
                return lines.composited(over: flat)
            }
        case .comic:
            out = drawn(out, width: 1040) { $0.applyingFilter("CIComicEffect") }
        case .sketch:
            out = drawn(out) { small in
                // Dodging a picture with its own blurred negative leaves only the edges, as pencil.
                let grey = colour(small, saturation: 0, contrast: 1.05)
                let negative = grey.applyingFilter("CIColorInvert")
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
                    .cropped(to: small.extent)
                let dodge = CIFilter.colorDodgeBlendMode()
                dodge.inputImage = negative
                dodge.backgroundImage = grey
                let pencil = curve(dodge.outputImage ?? grey, [(0, 0), (0.25, 0.14), (0.5, 0.36), (0.75, 0.66), (1, 0.97)])
                // Graphite on cream paper rather than black on white.
                return pencil.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.86, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0),
                    "inputBiasVector": CIVector(x: 0.13, y: 0.13, z: 0.13, w: 0),
                ])
            }
        case .pop:
            out = colour(out, saturation: 1.7, contrast: 1.06, brightness: 0.02)
            out = posterize(out, levels: 4)
        case .dreamy:
            let bloom = CIFilter.bloom()
            bloom.inputImage = out.clampedToExtent()
            bloom.radius = Float(extent.width / 42)
            bloom.intensity = 0.62
            out = (bloom.outputImage ?? out).cropped(to: extent)
            out = colour(out, saturation: 0.9, contrast: 0.95, brightness: 0.03)
            let tint = CIFilter.temperatureAndTint()
            tint.inputImage = out
            tint.neutral = CIVector(x: 6500, y: 0)
            tint.targetNeutral = CIVector(x: 6900, y: 24)
            out = tint.outputImage ?? out
            out = curve(out, [(0, 0.07), (0.25, 0.31), (0.5, 0.56), (0.75, 0.8), (1, 0.98)])
        case .instant:
            out = out.applyingFilter("CIPhotoEffectInstant")
            out = curve(out, [(0, 0.05), (0.25, 0.26), (0.5, 0.53), (0.75, 0.79), (1, 0.97)])
            out = vignette(out, intensity: 0.6)
            out = grain(out, amount: 0.07, seed: grainSeed)
        case .cool:
            out = out.applyingFilter("CIPhotoEffectProcess")
            out = colour(out, saturation: 0.95, contrast: 1.04)
            out = vignette(out, intensity: 0.4)
            out = grain(out, amount: 0.07, seed: grainSeed)
        case .color:
            out = colour(out, saturation: 1.06, contrast: 1.03)
            out = vignette(out, intensity: 0.32)
        case .mono:
            out = colour(out, saturation: 0, contrast: 1.16, brightness: 0.015)
            out = curve(out, [(0, 0.015), (0.25, 0.21), (0.5, 0.50), (0.75, 0.80), (1, 0.985)])
            out = vignette(out, intensity: 0.45)
            out = grain(out, amount: 0.12, seed: grainSeed)
        case .warm:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = out
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5300, y: 8)
            out = temperature.outputImage ?? out
            out = colour(out, saturation: 0.9, contrast: 0.97)
            // Lifted, slightly warm blacks; highlights that never quite reach white.
            out = curve(out, [(0, 0.06), (0.25, 0.27), (0.5, 0.52), (0.75, 0.76), (1, 0.95)])
            out = vignette(out, intensity: 0.4)
            out = grain(out, amount: 0.09, seed: grainSeed)
        }
        return out.cropped(to: extent)
    }

    /// Whether the look lays film grain over the picture.
    var hasGrain: Bool {
        switch self {
        case .instant, .warm, .cool, .mono: true
        default: false
        }
    }

    /// Runs `body` on the picture resampled to `width` and brings the result back to size.
    private func drawn(_ image: CIImage, width: CGFloat = BoothLook.drawingWidth, _ body: (CIImage) -> CIImage) -> CIImage {
        let extent = image.extent
        let scale = width / extent.width
        guard abs(scale - 1) > 0.05 else { return body(image).cropped(to: extent) }
        let small = image
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let bounds = small.extent.integral
        let result = body(small.clampedToExtent().cropped(to: bounds)).cropped(to: bounds)
        return result
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / bounds.width, y: extent.height / bounds.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// Posterises in display space: in linear light every shadow would fall into the lowest step.
    private func posterize(_ image: CIImage, levels: Int) -> CIImage {
        image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    private func colour(_ image: CIImage, saturation: Float, contrast: Float, brightness: Float = 0) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = saturation
        controls.contrast = contrast
        controls.brightness = brightness
        return controls.outputImage ?? image
    }

    private func curve(_ image: CIImage, _ points: [(CGFloat, CGFloat)]) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        let p = points.map { CGPoint(x: $0.0, y: $0.1) }
        filter.point0 = p[0]
        filter.point1 = p[1]
        filter.point2 = p[2]
        filter.point3 = p[3]
        filter.point4 = p[4]
        return filter.outputImage ?? image
    }

    private func vignette(_ image: CIImage, intensity: Float) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = image
        filter.intensity = intensity
        filter.radius = Float(max(image.extent.width, image.extent.height) / 160)
        return filter.outputImage ?? image
    }

    /// Fine monochrome grain, soft-light blended so it lives mostly in the mid-tones.
    private func grain(_ image: CIImage, amount: CGFloat, seed: Int) -> CIImage {
        guard let random = CIFilter.randomGenerator().outputImage else { return image }
        let offset = CGFloat((seed &* 7919) % 4096)
        // The generator's alpha is random too; make it opaque before any colour maths,
        // or unpremultiplying turns near-transparent pixels into white sparks.
        let noise = random
            .transformed(by: CGAffineTransform(translationX: offset, y: offset * 0.37))
            .settingAlphaOne(in: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 1),
            ])
            .cropped(to: image.extent)
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = noise
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }
}
