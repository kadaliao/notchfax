import CoreGraphics
import Foundation

/// The fax pipeline's picture handling, for other modules that put pictures on thermal
/// paper: same toning, sharpening and dithering, without the fax protocol's size limits.
public enum ThermalPicture {
    /// Reads an image file's bytes with its orientation applied, reduced to a workable size.
    public static func image(from data: Data) -> CGImage? {
        ImageLoader.load(data: data)
    }

    /// One dot per print-head dot: as wide as a default thermal sheet allows (scaled up or
    /// down to fill it), and at most `maxHeight` dots tall. Show it with `ThermalBitmap`.
    public static func dithered(_ image: CGImage, maxHeight: Int) -> CGImage? {
        let w = Double(max(1, image.width)), h = Double(max(1, image.height))
        let scale = min(Double(FaxDither.printWidth) / w, Double(max(8, maxHeight)) / h)
        let width = max(1, min(FaxDither.printWidth, Int((w * scale).rounded())))
        let height = max(1, Int((h * scale).rounded()))
        guard let gray = FaxDither.grayscale(image, width: width, height: height) else { return nil }
        let prepared = FaxDither.prepare(gray, width: width, height: height, tone: FaxDither.Tone())
        return FaxDither.atkinson(prepared, width: width, height: height).cgImage()
    }
}
