import SwiftUI

/// Sample sheets for the debug menu and the offscreen gallery. Everything is drawn
/// procedurally so the samples need no photo library, camera or network.
public enum PrintSamples {
    // MARK: Jobs

    @MainActor
    public static func fax() -> PrintJob {
        PrintJob(
            PaperSheet(.thermal) { SampleFaxPage() },
            reveal: .progressive(lineHeight: 14),
            autoRetract: .after(12),
            actions: [
                PaperAction(id: "reply", title: "回复", systemImage: "arrowshape.turn.up.left.fill") { _ in },
                PaperAction(id: "tear", title: "撕掉", systemImage: "scissors") { $0.tearOff() },
                PaperAction(id: "report", title: "举报", systemImage: "exclamationmark.bubble.fill", role: .destructive) { $0.retract() },
            ]
        )
    }

    @MainActor
    public static func photo(variant: Int = 0) -> PrintJob {
        let image = landscape(width: 936, height: 702, variant: variant)
        let date = Calendar.current.date(byAdding: .year, value: -(3 + variant), to: Date()) ?? Date()
        return PrintJob(PaperSheet(.glossyPhoto) { PhotoPrintContent(image: image, date: date) })
    }

    @MainActor
    public static func strip() -> PrintJob {
        let frames = (0..<4).map { portrait(width: 432, height: 324, variant: $0) }
        return PrintJob(PaperSheet(.photoStrip) { PhotoStripContent(frames: frames, caption: "NOTCHFAX · 大头贴") })
    }

    // MARK: Pictures

    /// A dusk landscape: sky, sun, ridgelines, water.
    public static func landscape(width: Int, height: Int, variant: Int = 0) -> CGImage {
        let bitmap = Bitmap(width: width, height: height)
        let ctx = bitmap.context
        let w = CGFloat(width), h = CGFloat(height)
        let seed = UInt64(variant) &* 131 &+ 17
        let palettes: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0.13, 0.22, 0.42), (0.55, 0.42, 0.58), (0.97, 0.66, 0.42), (1.0, 0.86, 0.62)],
            [(0.07, 0.16, 0.30), (0.20, 0.42, 0.56), (0.62, 0.78, 0.76), (0.98, 0.90, 0.72)],
            [(0.20, 0.12, 0.30), (0.62, 0.28, 0.42), (0.98, 0.52, 0.34), (1.0, 0.80, 0.50)],
        ]
        let p = palettes[abs(variant) % palettes.count]
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        func colour(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a) }

        let horizon = h * 0.36
        if let sky = CGGradient(colorsSpace: space, colors: p.map { colour($0) } as CFArray, locations: [0, 0.45, 0.8, 1]) {
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])
        }
        let sun = CGPoint(x: w * (0.62 + 0.1 * CGFloat(variant % 2)), y: horizon + h * 0.07)
        if let glow = CGGradient(colorsSpace: space, colors: [colour((1, 0.97, 0.86), 1), colour((1, 0.85, 0.6), 0.55), colour((1, 0.8, 0.5), 0)] as CFArray, locations: [0, 0.12, 1]) {
            ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: w * 0.42, options: [])
        }
        ctx.setFillColor(colour((1, 0.98, 0.9)))
        ctx.fillEllipse(in: CGRect(x: sun.x - w * 0.028, y: sun.y - w * 0.028, width: w * 0.056, height: w * 0.056))

        // Ridgelines, hazier with distance.
        let ridges: [(base: CGFloat, amp: CGFloat, tone: (CGFloat, CGFloat, CGFloat), freq: Double)] = [
            (0.10, 0.11, (0.52, 0.40, 0.56), 2.2),
            (0.05, 0.10, (0.32, 0.25, 0.42), 3.4),
            (0.0, 0.07, (0.15, 0.13, 0.25), 5.1),
        ]
        for (index, ridge) in ridges.enumerated() {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: horizon))
            for step in 0...120 {
                let u = Double(step) / 120
                let n = Hash.smooth(u * ridge.freq, Double(index), seed) * 0.7 + Hash.smooth(u * ridge.freq * 3.1, Double(index) + 9, seed) * 0.3
                path.addLine(to: CGPoint(x: CGFloat(u) * w, y: horizon + h * (ridge.base + ridge.amp * CGFloat(n))))
            }
            path.addLine(to: CGPoint(x: w, y: horizon))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(colour(ridge.tone))
            ctx.fillPath()
        }

        // Water: the sky folded over, darker, with a sun track.
        if let water = CGGradient(colorsSpace: space, colors: [colour(p[2], 1), colour(p[1], 1), colour(p[0], 1)] as CFArray, locations: [0, 0.4, 1]) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
            ctx.drawLinearGradient(water, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.18))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: horizon))
            for i in 0..<46 {
                let v = CGFloat(Hash.unit(i, 1, seed))
                let y = horizon * (1 - v * v) - 2
                let spread = w * (0.03 + 0.2 * (1 - y / horizon))
                let x = sun.x + (CGFloat(Hash.unit(i, 2, seed)) - 0.5) * spread
                let length = w * (0.02 + 0.07 * CGFloat(Hash.unit(i, 3, seed)))
                ctx.setFillColor(colour((1, 0.9, 0.68), 0.3 + 0.4 * CGFloat(Hash.unit(i, 4, seed))))
                ctx.fill(CGRect(x: x - length / 2, y: y, width: length, height: max(1.5, h * 0.004)))
            }
            ctx.restoreGState()
        }
        addGrain(bitmap, amount: 0.035, seed: seed)
        return bitmap.image()
    }

    /// A stand-in for a photo-booth frame: a friendly figure against a coloured backdrop.
    public static func portrait(width: Int, height: Int, variant: Int = 0) -> CGImage {
        let bitmap = Bitmap(width: width, height: height)
        let ctx = bitmap.context
        let w = CGFloat(width), h = CGFloat(height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let backdrops: [((CGFloat, CGFloat, CGFloat), (CGFloat, CGFloat, CGFloat))] = [
            ((0.96, 0.74, 0.62), (0.86, 0.50, 0.46)),
            ((0.66, 0.80, 0.86), (0.36, 0.54, 0.70)),
            ((0.95, 0.86, 0.60), (0.88, 0.66, 0.36)),
            ((0.76, 0.72, 0.90), (0.50, 0.44, 0.74)),
        ]
        let b = backdrops[abs(variant) % backdrops.count]
        if let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(srgbRed: b.0.0, green: b.0.1, blue: b.0.2, alpha: 1), CGColor(srgbRed: b.1.0, green: b.1.1, blue: b.1.2, alpha: 1)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: w * 0.5, y: h * 0.62), startRadius: 0, endCenter: CGPoint(x: w * 0.5, y: h * 0.5), endRadius: w * 0.75, options: [.drawsAfterEndLocation])
        }
        let lean = [0.0, -0.06, 0.05, 0.02][abs(variant) % 4]
        let shift = [0.0, -0.04, 0.05, 0.0][abs(variant) % 4]
        ctx.saveGState()
        ctx.translateBy(x: w * (0.5 + shift), y: h * 0.0)
        ctx.rotate(by: lean)
        let skin = CGColor(srgbRed: 0.97, green: 0.83, blue: 0.72, alpha: 1)
        let shirt = [CGColor(srgbRed: 0.2, green: 0.22, blue: 0.3, alpha: 1), CGColor(srgbRed: 0.93, green: 0.93, blue: 0.9, alpha: 1)][variant % 2]
        let hair = CGColor(srgbRed: 0.16, green: 0.12, blue: 0.12, alpha: 1)
        // Shoulders, neck, head, hair.
        ctx.setFillColor(shirt)
        ctx.fillEllipse(in: CGRect(x: -w * 0.3, y: -h * 0.42, width: w * 0.6, height: h * 0.74))
        ctx.setFillColor(skin)
        ctx.fill(CGRect(x: -w * 0.05, y: h * 0.26, width: w * 0.1, height: h * 0.14))
        let head = CGRect(x: -h * 0.19, y: h * 0.34, width: h * 0.38, height: h * 0.44)
        ctx.setFillColor(hair)
        ctx.fillEllipse(in: head.insetBy(dx: -h * 0.025, dy: -h * 0.02).offsetBy(dx: 0, dy: h * 0.03))
        ctx.setFillColor(skin)
        ctx.fillEllipse(in: head.insetBy(dx: h * 0.012, dy: 0).offsetBy(dx: 0, dy: -h * 0.02))
        // Face.
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        let eyeY = head.midY - h * 0.005
        let wink = variant % 4 == 2
        ctx.fillEllipse(in: CGRect(x: -h * 0.085, y: eyeY, width: h * 0.03, height: h * 0.036))
        if wink {
            ctx.fill(CGRect(x: h * 0.05, y: eyeY + h * 0.014, width: h * 0.04, height: h * 0.008))
        } else {
            ctx.fillEllipse(in: CGRect(x: h * 0.055, y: eyeY, width: h * 0.03, height: h * 0.036))
        }
        ctx.setStrokeColor(CGColor(srgbRed: 0.6, green: 0.25, blue: 0.25, alpha: 1))
        ctx.setLineWidth(h * 0.012)
        ctx.setLineCap(.round)
        let smile = variant % 4 == 1 ? 0.5 : 1.0
        ctx.addArc(center: CGPoint(x: 0, y: head.minY + h * 0.14), radius: h * 0.07, startAngle: .pi * (1.5 - 0.28 * smile), endAngle: .pi * (1.5 + 0.28 * smile), clockwise: false)
        ctx.strokePath()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.55, blue: 0.5, alpha: 0.28))
        ctx.fillEllipse(in: CGRect(x: -h * 0.15, y: head.minY + h * 0.13, width: h * 0.06, height: h * 0.04))
        ctx.fillEllipse(in: CGRect(x: h * 0.09, y: head.minY + h * 0.13, width: h * 0.06, height: h * 0.04))
        ctx.restoreGState()
        // On-camera flash: bright centre, falling off to the corners.
        if let vignette = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.30)] as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: w * 0.72, options: [.drawsAfterEndLocation])
        }
        addGrain(bitmap, amount: 0.04, seed: UInt64(variant) &+ 400)
        return bitmap.image()
    }

    private static func addGrain(_ bitmap: Bitmap, amount: Double, seed: UInt64) {
        for y in 0..<bitmap.height {
            let row = bitmap.pixels + y * bitmap.rowBytes
            for x in 0..<bitmap.width {
                let n = 1 + (Hash.unit(x, y, seed) - 0.5) * 2 * amount
                let p = row + x * 4
                for c in 0..<3 { p[c] = UInt8(min(255, max(0, Double(p[c]) * n))) }
            }
        }
    }
}

/// A received fax as it will roughly look: a header line, the message, a footer.
struct SampleFaxPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("NOTCHFAX").font(.system(size: 8, weight: .heavy, design: .monospaced)).tracking(1)
                Spacer()
                Text("11-11 22:40").font(.system(size: 7, weight: .medium, design: .monospaced))
            }
            DashedRule()
            Text("线路 #4F2A · 第 1 封").font(.system(size: 7.5, weight: .medium, design: .monospaced))
            Text("你好，陌生人。\n今晚的月亮很圆，我这边刚下过雨，路面像一张刚洗出来的照片。\n\n如果你也还没睡，回我一句吧。")
                .font(.system(size: 11.5, weight: .medium))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
            DashedRule()
            HStack(spacing: 5) {
                Barcode().frame(width: 44, height: 12)
                Text("回复后线路接通，可发图片").font(.system(size: 6.5, weight: .medium))
            }
        }
        .foregroundStyle(.black)
    }
}

private struct DashedRule: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(Line().stroke(.black, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

private struct Barcode: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                let width = CGFloat(1 + Int(Hash.unit(index, 0, 42) * 3)) * 0.75
                if index.isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(.black))
                }
                x += width
                index += 1
            }
        }
    }
}
