import CoreImage
import CoreImage.CIFilterBuiltins

/// The few looks the booth offers. Each is a short Core Image chain, applied live to
/// the viewfinder and again, at full resolution, to the printed frames.
public enum BoothLook: String, CaseIterable, Sendable, Identifiable {
    /// Clean colour with the slight fall-off of a booth's flash.
    case color
    /// Silver-gelatin black and white: deep blacks, soft highlights, a little grain.
    case mono
    /// Faded, warm film: lifted blacks, amber cast, grain.
    case warm

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .color: "彩色"
        case .mono: "黑白"
        case .warm: "暖调"
        }
    }

    /// - Parameter grainSeed: moves the grain between frames so it lives like film grain.
    public func apply(to image: CIImage, grainSeed: Int = 0) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, !extent.isInfinite else { return image }
        var out = image
        switch self {
        case .color:
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.saturation = 1.06
            controls.contrast = 1.03
            out = controls.outputImage ?? out
            out = vignette(out, intensity: 0.32)
        case .mono:
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.saturation = 0
            controls.contrast = 1.16
            controls.brightness = 0.015
            out = controls.outputImage ?? out
            out = curve(out, [(0, 0.015), (0.25, 0.21), (0.5, 0.50), (0.75, 0.80), (1, 0.985)])
            out = vignette(out, intensity: 0.45)
            out = grain(out, amount: 0.12, seed: grainSeed)
        case .warm:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = out
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 5300, y: 8)
            out = temperature.outputImage ?? out
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.saturation = 0.9
            controls.contrast = 0.97
            out = controls.outputImage ?? out
            // Lifted, slightly warm blacks; highlights that never quite reach white.
            out = curve(out, [(0, 0.06), (0.25, 0.27), (0.5, 0.52), (0.75, 0.76), (1, 0.95)])
            out = vignette(out, intensity: 0.4)
            out = grain(out, amount: 0.09, seed: grainSeed)
        }
        return out.cropped(to: extent)
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
