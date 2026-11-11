import AppKit

/// Draws the machine's mouth: a notch stand-in, or a paper slot let into the top edge of the screen.
@MainActor
enum SlotRenderer {
    /// Extra room around the mouth for its shadow, in points.
    static let pad: CGFloat = 8

    /// An image of `geometry.mouth` plus `pad` on the left, right and bottom. Nil for a real notch,
    /// which needs no drawing.
    static func image(for geometry: SlotGeometry, scale: CGFloat) -> CGImage? {
        guard geometry.kind != .notch else { return nil }
        let mouth = geometry.mouth.size
        let size = CGSize(width: mouth.width + pad * 2, height: mouth.height + pad)
        let bitmap = Bitmap(width: Int(size.width * scale), height: Int(size.height * scale))
        let ctx = bitmap.context
        ctx.scaleBy(x: scale, y: scale)
        // y-up: the screen's top edge is at y = size.height.
        let body = CGRect(x: pad, y: pad, width: mouth.width, height: mouth.height)
        let shape = mouthPath(body, radius: geometry.cornerRadius, ear: geometry.kind == .drawnSlot ? 3 : 6)

        switch geometry.kind {
        case .simulatedNotch:
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        case .drawnSlot:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * scale), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.38))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()

            // Housing: near-black, catching a little light on its lower lip.
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            let colours = [CGColor(gray: 0.02, alpha: 1), CGColor(gray: 0.07, alpha: 1), CGColor(gray: 0.15, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 0.55, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
            }
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.addPath(mouthPath(body.offsetBy(dx: 0, dy: 0.6), radius: geometry.cornerRadius, ear: 3))
            ctx.addRect(body.insetBy(dx: -4, dy: -4))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.2))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()

            // The slit itself, with the paper line running through it.
            let lineY = body.maxY - geometry.slotLineY
            let slit = CGRect(x: body.minX + 10, y: lineY - 1.4, width: body.width - 20, height: 3.4)
            let slitPath = CGPath(roundedRect: slit, cornerWidth: 1.7, cornerHeight: 1.7, transform: nil)
            ctx.addPath(slitPath)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            ctx.saveGState()
            ctx.addPath(slitPath)
            ctx.clip()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.13))
            ctx.fill(CGRect(x: slit.minX, y: slit.minY, width: slit.width, height: 0.5))
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.07))
            ctx.setLineWidth(0.5)
            ctx.addPath(CGPath(roundedRect: slit.insetBy(dx: -0.5, dy: -0.5), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            ctx.strokePath()
        case .notch:
            break
        }
        return bitmap.image()
    }

    /// A notch silhouette hanging from the top edge of `rect` (y-up): small concave
    /// ears where it meets the screen edge, rounded lower corners.
    static func mouthPath(_ rect: CGRect, radius: CGFloat, ear: CGFloat) -> CGPath {
        let r = min(radius, rect.height - 0.5, rect.width / 2)
        let e = min(ear, max(0, rect.height - r))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX - e, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - e), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + e, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
