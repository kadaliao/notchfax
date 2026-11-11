import AppKit
import SwiftUI

/// Renders every paper type offscreen, through the same layer tree the live stage
/// uses, so the look can be checked without a screen recording.
@MainActor
public enum Gallery {
    /// Writes the gallery PNGs into `directory` and returns their URLs.
    @discardableResult
    public static func render(to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        func save(_ image: CGImage, _ name: String) throws {
            guard let data = PaperRenderer.pngData(image) else { return }
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
            try data.write(to: url)
            written.append(url)
        }

        let fax = sheet(PrintSamples.fax(), seed: 11)
        let photo = sheet(PrintSamples.photo(), seed: 12)
        let strip = sheet(PrintSamples.strip(), seed: 13)

        try save(scene(height: fax.size.height + 90) { stage in
            stage.hang(fax, progressive: false)
        }, "thermal")
        try save(scene(height: 300) { stage in
            stage.hang(fax, progressive: true, fraction: 0.52)
        }, "thermal-printing")
        try save(scene(height: fax.size.height + 150) { stage in
            let node = SheetNode(rendered: fax, fit: 1, progressive: false)
            node.tear(at: -8, seed: 5)
            node.setLift(1)
            stage.free.addSublayer(node.root)
            node.setPose(
                SheetPose(pivotLocal: CGPoint(x: 40, y: 30), pivotStage: CGPoint(x: stage.geometry.centerX - 30, y: 90), angle: -0.13),
                stageHeight: stage.size.height
            )
        }, "thermal-torn")
        try save(scene(height: photo.size.height + 110) { stage in
            stage.hang(photo, progressive: false)
        }, "glossy-photo")
        try save(scene(height: photo.size.height + 110, dark: true, simulateNotch: true) { stage in
            stage.hang(photo, progressive: false, sway: 0.03)
        }, "glossy-photo-notch-dark")
        try save(scene(height: strip.size.height + 90) { stage in
            stage.hang(strip, progressive: false)
        }, "photo-strip")
        try save(scene(height: 120) { _ in }, "slot-idle")
        try save(scene(height: 120, dark: true, simulateNotch: true) { _ in }, "slot-notch-idle")

        try save(detail(fax.printed, rect: CGRect(x: 0, y: 0, width: 110, height: 86), scale: fax.scale), "detail-thermal-top")
        try save(detail(fax.printed, rect: CGRect(x: 60, y: fax.size.height - 60, width: 100, height: 60), scale: fax.scale), "detail-thermal-edge")
        try save(detail(photo.printed, rect: CGRect(x: photo.size.width - 100, y: photo.size.height - 70, width: 100, height: 70), scale: photo.scale), "detail-photo-stamp")
        return written
    }

    private static func sheet(_ job: PrintJob, seed: UInt64) -> RenderedSheet {
        PaperRenderer.render(job.sheet, size: job.sheet.resolvedSize(), scale: job.sheet.paper == .thermal ? 2 : 3, seed: seed)
    }

    // MARK: Scenes

    private struct SceneStage {
        let size: CGSize
        let geometry: SlotGeometry
        let clip: CALayer
        let free: CALayer

        @MainActor
        func hang(_ rendered: RenderedSheet, progressive: Bool, fraction: CGFloat = 1, sway: Double = 0.012) {
            let fit = geometry.fittingScale(forPaperWidth: rendered.size.width)
            let node = SheetNode(rendered: rendered, fit: fit, progressive: progressive)
            let h = node.size.height
            let rest = rendered.paper.isTearable ? h + 3 : h - 3
            let out = rest * fraction
            clip.addSublayer(node.root)
            node.setPose(
                SheetPose(pivotLocal: CGPoint(x: node.size.width / 2, y: h - out), pivotStage: geometry.anchor, angle: sway),
                stageHeight: size.height
            )
            node.setSlotLine(h - out)
            if !progressive { node.finishReveal() }
        }
    }

    private static func scene(
        width: CGFloat = 420,
        height: CGFloat,
        dark: Bool = false,
        simulateNotch: Bool = false,
        build: (SceneStage) -> Void
    ) -> CGImage {
        let size = CGSize(width: width, height: height.rounded(.up))
        let geometry = SlotGeometry.make(for: ScreenDescriptor(frame: CGRect(origin: .zero, size: size)), simulateNotch: simulateNotch)
        let scale: CGFloat = 2

        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: size)
        let backdrop = CALayer()
        backdrop.frame = root.bounds
        backdrop.contents = wallpaper(size: size, dark: dark, menuBarHeight: simulateNotch ? 32 : 24)
        root.addSublayer(backdrop)

        if let slotImage = SlotRenderer.image(for: geometry, scale: scale) {
            let pad = SlotRenderer.pad
            let slot = CALayer()
            slot.contents = slotImage
            slot.frame = CGRect(
                x: geometry.mouth.minX - pad,
                y: size.height - geometry.mouth.maxY - pad,
                width: geometry.mouth.width + pad * 2,
                height: geometry.mouth.height + pad
            )
            root.addSublayer(slot)
        }
        let clip = CALayer()
        clip.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height - geometry.slotLineY)
        clip.masksToBounds = true
        let free = CALayer()
        free.frame = root.bounds
        root.addSublayer(clip)
        root.addSublayer(free)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        build(SceneStage(size: size, geometry: geometry, clip: clip, free: free))
        CATransaction.commit()
        CATransaction.flush()

        let bitmap = Bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        bitmap.context.scaleBy(x: scale, y: scale)
        root.render(in: bitmap.context)
        return bitmap.image()
    }

    private static func wallpaper(size: CGSize, dark: Bool, menuBarHeight: CGFloat) -> CGImage {
        let scale: CGFloat = 2
        let bitmap = Bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        let ctx = bitmap.context
        ctx.scaleBy(x: scale, y: scale)
        let colours: [CGColor] = dark
            ? [CGColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.22, green: 0.16, blue: 0.30, alpha: 1)]
            : [CGColor(srgbRed: 0.74, green: 0.82, blue: 0.90, alpha: 1), CGColor(srgbRed: 0.90, green: 0.86, blue: 0.84, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        // A stand-in menu bar, so the slot is judged against what it will sit on.
        ctx.setFillColor(dark ? CGColor(gray: 0, alpha: 0.42) : CGColor(gray: 1, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: size.height - menuBarHeight, width: size.width, height: menuBarHeight))
        return bitmap.image()
    }

    /// A magnified crop of a printed sheet (rect in sheet points, origin top-left).
    private static func detail(_ image: CGImage, rect: CGRect, scale: CGFloat) -> CGImage {
        let zoom = 4
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let crop = image.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) ?? image
        let bitmap = Bitmap(width: crop.width * zoom, height: crop.height * zoom)
        let ctx = bitmap.context
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.56, blue: 0.62, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        return bitmap.image()
    }
}
