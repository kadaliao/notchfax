import AppKit
import SwiftUI

/// Renders every paper type offscreen, through the same layer tree the live stage
/// uses, so the look can be checked without a screen recording. Also plays scripted
/// pointer paths through the real sheet physics and lays the frames out as contact
/// sheets, which is how motion is reviewed without a person at the machine.
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

        try save(still(height: fax.size.height + 90) { $0.hang(fax) }, "thermal")
        try save(still(height: 300) { $0.hang(fax, progressive: true, fraction: 0.52) }, "thermal-printing")
        try save(still(height: fax.size.height + 150) { scene in
            let node = SheetNode(rendered: fax, fit: 1, progressive: false)
            node.tear(at: -8, seed: 5)
            node.setBend(SheetBend(holdY: 30, lagBelow: 0, lagAbove: 0, curlBelow: 12, curlAbove: 3, tip: 6, lift: 9))
            scene.free.addSublayer(node.root)
            scene.nodes.append(node)
            node.setPose(
                SheetPose(pivotLocal: CGPoint(x: 40, y: 30), pivotStage: CGPoint(x: scene.geometry.centerX - 30, y: 90), angle: -0.13),
                stageHeight: scene.size.height
            )
        }, "thermal-torn")
        try save(still(height: photo.size.height + 110) { $0.hang(photo) }, "glossy-photo")
        try save(still(height: photo.size.height + 110, dark: true, simulateNotch: true) { $0.hang(photo, sway: 0.03) }, "glossy-photo-notch-dark")
        try save(still(height: strip.size.height + 90) { $0.hang(strip) }, "photo-strip")
        try save(still(height: 120) { _ in }, "slot-idle")
        try save(still(height: 120, dark: true, simulateNotch: true) { _ in }, "slot-notch-idle")

        try save(detail(fax.printed, rect: CGRect(x: 0, y: 0, width: 110, height: 86), scale: fax.scale), "detail-thermal-top")
        try save(detail(fax.printed, rect: CGRect(x: 60, y: fax.size.height - 60, width: 100, height: 60), scale: fax.scale), "detail-thermal-edge")
        try save(detail(photo.printed, rect: CGRect(x: photo.size.width - 100, y: photo.size.height - 70, width: 100, height: 70), scale: photo.scale), "detail-photo-stamp")

        for capture in MotionCapture.all {
            try save(capture.contactSheet(), "motion-\(capture.name)")
        }
        return written
    }

    private static func sheet(_ job: PrintJob, seed: UInt64) -> RenderedSheet {
        PaperRenderer.render(job.sheet, size: job.sheet.resolvedSize(), scale: job.sheet.paper == .thermal ? 2 : 3, seed: seed)
    }

    private static func still(height: CGFloat, dark: Bool = false, simulateNotch: Bool = false, build: (Scene) -> Void) -> CGImage {
        let scene = Scene(size: CGSize(width: 420, height: height.rounded(.up)), dark: dark, simulateNotch: simulateNotch)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        build(scene)
        CATransaction.commit()
        return scene.render(scale: 2)
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

/// A stand-in screen: wallpaper, a menu bar, the slot, and the two layers paper lives in.
@MainActor
final class Scene {
    let size: CGSize
    let geometry: SlotGeometry
    let root = CALayer()
    let clip = CALayer()
    let free = CALayer()
    /// Annotations drawn over everything (the scripted pointer).
    let overlay = CALayer()

    init(size: CGSize, dark: Bool = false, simulateNotch: Bool = false) {
        self.size = size
        geometry = SlotGeometry.make(for: ScreenDescriptor(frame: CGRect(origin: .zero, size: size)), simulateNotch: simulateNotch)
        root.frame = CGRect(origin: .zero, size: size)
        let backdrop = CALayer()
        backdrop.frame = root.bounds
        backdrop.contents = Self.wallpaper(size: size, dark: dark, menuBarHeight: simulateNotch ? 32 : 24)
        root.addSublayer(backdrop)
        if let slotImage = SlotRenderer.image(for: geometry, scale: 2) {
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
        clip.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height - geometry.slotLineY)
        clip.masksToBounds = true
        free.frame = root.bounds
        overlay.frame = root.bounds
        root.addSublayer(clip)
        root.addSublayer(free)
    }

    func hang(_ rendered: RenderedSheet, progressive: Bool = false, fraction: CGFloat = 1, sway: Double = 0.012) {
        let fit = geometry.fittingScale(forPaperWidth: rendered.size.width)
        let node = SheetNode(rendered: rendered, fit: fit, progressive: progressive)
        let h = node.size.height
        let rest = rendered.paper.isTearable ? h + 3 : h - 3
        let out = rest * fraction
        clip.addSublayer(node.root)
        nodes.append(node)
        node.setPose(
            SheetPose(pivotLocal: CGPoint(x: node.size.width / 2, y: h - out), pivotStage: geometry.anchor, angle: sway),
            stageHeight: size.height
        )
        node.setSlotLine(h - out)
        let curl: CGFloat = rendered.paper == .thermal ? min(20, 9 + h * 0.025) : (rendered.paper == .photoStrip ? 9 : 5)
        let tip: CGFloat = rendered.paper == .thermal ? 7 : (rendered.paper == .photoStrip ? 3 : 1.5)
        node.setBend(SheetBend(holdY: h - out, curlBelow: curl * min(1, out / max(60, h)), tip: tip))
        if !progressive { node.finishReveal() }
    }

    /// Sheets whose shadows should be drawn. `CALayer.render(in:)` skips layer shadows,
    /// so they are painted here from the same paths and radii the live layers use.
    var nodes: [SheetNode] = []

    func render(scale: CGFloat) -> CGImage {
        CATransaction.flush()
        let bitmap = Bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        let ctx = bitmap.context
        ctx.scaleBy(x: scale, y: scale)
        clip.isHidden = true
        free.isHidden = true
        root.render(in: ctx)
        clip.isHidden = false
        free.isHidden = false
        for node in nodes where node.root.superlayer != nil {
            ctx.saveGState()
            if node.root.superlayer === clip { ctx.clip(to: clip.frame) }
            let transform = node.root.affineTransform()
            // Paint only the shadow: the caster is drawn far off-canvas and its shadow offset back.
            let away = (size.width + size.height) * 4
            for shadow in node.shadows {
                var shift = transform.concatenating(CGAffineTransform(translationX: away, y: 0))
                guard let path = shadow.path.copy(using: &shift) else { continue }
                let offset = CGSize(width: shadow.offset.width, height: shadow.offset.height).applying(
                    CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
                )
                ctx.setShadow(
                    offset: CGSize(width: (offset.width - away) * scale, height: offset.height * scale),
                    blur: shadow.radius * 2 * scale,
                    color: CGColor(gray: 0, alpha: shadow.opacity)
                )
                ctx.addPath(path)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.clip(to: clip.frame)
        clip.render(in: ctx)
        ctx.restoreGState()
        free.render(in: ctx)
        overlay.render(in: ctx)
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
}
