import AppKit

/// The menu-bar icon: a slot with a sheet of paper coming out of it, drawn as a
/// template image so the system tints it for light, dark and highlighted menu bars.
enum MenuBarGlyph {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)

            // The slot: a solid bar with rounded lower corners, like a notch seen small.
            let slot = CGMutablePath()
            slot.move(to: CGPoint(x: 1.5, y: 16))
            slot.addLine(to: CGPoint(x: 1.5, y: 13.6))
            slot.addQuadCurve(to: CGPoint(x: 3.1, y: 12), control: CGPoint(x: 1.5, y: 12))
            slot.addLine(to: CGPoint(x: 14.9, y: 12))
            slot.addQuadCurve(to: CGPoint(x: 16.5, y: 13.6), control: CGPoint(x: 16.5, y: 12))
            slot.addLine(to: CGPoint(x: 16.5, y: 16))
            slot.closeSubpath()
            ctx.addPath(slot)
            ctx.fillPath()

            // The sheet: an outline hanging from it, torn into teeth along the bottom.
            let left: CGFloat = 4.25, right: CGFloat = 13.75, bottom: CGFloat = 2.4, tooth: CGFloat = 1.5
            let sheet = CGMutablePath()
            sheet.move(to: CGPoint(x: left, y: 12))
            sheet.addLine(to: CGPoint(x: left, y: bottom + tooth))
            let teeth = 4
            for i in 0..<teeth * 2 {
                let x = left + (right - left) * CGFloat(i + 1) / CGFloat(teeth * 2)
                sheet.addLine(to: CGPoint(x: x, y: i.isMultiple(of: 2) ? bottom : bottom + tooth))
            }
            sheet.addLine(to: CGPoint(x: right, y: 12))
            ctx.addPath(sheet)
            ctx.setLineWidth(1.25)
            ctx.setLineJoin(.round)
            ctx.strokePath()

            // Two printed lines.
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.1)
            ctx.move(to: CGPoint(x: 6.6, y: 9.2))
            ctx.addLine(to: CGPoint(x: 11.4, y: 9.2))
            ctx.move(to: CGPoint(x: 6.6, y: 6.6))
            ctx.addLine(to: CGPoint(x: 9.8, y: 6.6))
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notchfax"
        return image
    }
}
