import AppKit
import QuartzCore

/// Where a sheet is: one of its own points pinned to a point on the stage, rotated about it.
/// Sheet coordinates have their origin at the sheet's top-left corner with y down
/// (paper still on the roll has negative y). Stage coordinates are screen-local, y down.
struct SheetPose: Equatable {
    var pivotLocal: CGPoint
    var pivotStage: CGPoint
    var angle: Double

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: -pivotLocal.x, y: -pivotLocal.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: pivotStage.x, y: pivotStage.y))
    }

    func stagePoint(_ local: CGPoint) -> CGPoint { local.applying(transform) }
    func localPoint(_ stage: CGPoint) -> CGPoint { stage.applying(transform.inverted()) }
}

/// How a sheet is bent, on top of its rigid pose. The sheet is held along the
/// horizontal line `holdY`; the paper on either side of that line is free to trail
/// sideways (`lag`) and to stand off the screen towards the viewer (`curl`, `lift`).
struct SheetBend: Equatable {
    /// The held line, in sheet coordinates.
    var holdY: CGFloat = 0
    /// Sideways displacement of the bottom edge, in points. Grows with the square of the distance from the hold.
    var lagBelow: CGFloat = 0
    /// Sideways displacement of the top edge.
    var lagAbove: CGFloat = 0
    /// How far the bottom edge stands off the screen, in points.
    var curlBelow: CGFloat = 0
    var curlAbove: CGFloat = 0
    /// Extra curl over the last stretch of the free end, as roll paper has.
    var tip: CGFloat = 0
    /// Distance of the whole sheet from the screen, in points.
    var lift: CGFloat = 0
}

/// The layer tree of one sheet of paper. Purely presentational: the controller (or
/// the offscreen gallery) tells it where it is and what state it is in.
///
/// The paper is cut into horizontal strips, each an affine-mapped slice of the same
/// image. Shearing a strip sideways bends the sheet in the plane of the screen;
/// squashing it vertically and widening it slightly reads as paper tilting towards
/// the viewer. Neighbouring strips share their edges exactly, so there are no seams.
@MainActor
final class SheetNode {
    let root = CALayer()
    /// On-screen size in points.
    let size: CGSize
    let tail: CGFloat
    let paper: Paper

    private struct Strip {
        let layer: CALayer
        let top: CGFloat
        let bottom: CGFloat
        let blank: CALayer
        let printed: CALayer?
        var revealMask: CAGradientLayer?
    }

    private let far = CALayer()
    private let near = CALayer()
    private let body = CALayer()
    private let lip = CAGradientLayer()
    private var gloss: CALayer?
    private let overlay = CALayer()
    private let overlayMask = CAShapeLayer()
    private let shade = CAGradientLayer()
    private let margin: CGFloat
    private var strips: [Strip] = []
    private let pad: CGFloat
    private var isRevealingInk: Bool
    private var bend = SheetBend()
    private var needsLayout = true
    private var tornSeed: UInt64 = 0
    /// Top of the visible paper in sheet coordinates once torn; nil while on the roll.
    private(set) var tornTop: CGFloat?

    static let developLength: CGFloat = 26
    static let lipLength: CGFloat = 18
    private static let stripLength: CGFloat = 9
    private static let overlap: CGFloat = 0.8

    init(rendered: RenderedSheet, fit: CGFloat, progressive: Bool) {
        paper = rendered.paper
        size = CGSize(width: rendered.size.width * fit, height: rendered.size.height * fit)
        tail = rendered.tailLength * fit
        isRevealingInk = progressive
        let w = size.width, h = size.height

        // One transparent pixel row around the images lets texture filtering smooth the paper's edges.
        let pixelsPerPoint = CGFloat(rendered.printed.width) / w
        let padPixels = max(1, Int(pixelsPerPoint.rounded(.up)))
        pad = CGFloat(padPixels) / pixelsPerPoint
        margin = ((h + tail) * 0.35).rounded(.up)
        let tailPixels = rendered.tail.map { _ in Int((tail * pixelsPerPoint).rounded()) } ?? 0
        let blankImage = Self.canvas(sheet: rendered.blank, tail: rendered.tail, tailPixels: tailPixels, pad: padPixels)
        let printedImage = Self.canvas(sheet: rendered.printed, tail: nil, tailPixels: tailPixels, pad: padPixels)
        let canvasHeight = tail + h + pad * 2
        let glossImage = paper == .thermal ? nil : Self.glossImage(width: w, height: h)

        // Fade the sheet and its shadows as one image, so the shadow never shows through the paper.
        root.allowsGroupOpacity = true
        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h + tail)

        for layer in [far, near] {
            layer.frame = root.bounds
            layer.shadowColor = CGColor(gray: 0, alpha: 1)
            root.addSublayer(layer)
        }
        body.frame = root.bounds
        root.addSublayer(body)

        let count = max(1, Int(((h + tail) / Self.stripLength).rounded(.up)))
        for index in 0..<count {
            let nominalTop = -tail + (h + tail) * CGFloat(index) / CGFloat(count)
            let nominalBottom = -tail + (h + tail) * CGFloat(index + 1) / CGFloat(count)
            let top = index == 0 ? nominalTop - pad : nominalTop
            let bottom = index == count - 1 ? nominalBottom + pad : nominalBottom + Self.overlap
            let length = bottom - top
            let unit = CGRect(x: 0, y: 1 - (bottom + tail + pad) / canvasHeight, width: 1, height: length / canvasHeight)

            let layer = CALayer()
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.bounds = CGRect(x: 0, y: 0, width: w + pad * 2, height: length)

            let blank = CALayer()
            blank.frame = layer.bounds
            blank.contents = blankImage
            blank.contentsRect = unit
            layer.addSublayer(blank)

            var printed: CALayer?
            if bottom > 0 {
                let ink = CALayer()
                ink.frame = layer.bounds
                ink.contents = printedImage
                ink.contentsRect = unit
                layer.addSublayer(ink)
                printed = ink
            }

            body.addSublayer(layer)
            // Where ink fully covers the stock, the stock underneath is not drawn at all: two
            // stacked slices with soft edges would let a hairline of white through at every seam.
            blank.isHidden = !progressive && printed != nil && top >= 0
            strips.append(Strip(layer: layer, top: top, bottom: bottom, blank: blank, printed: printed))
        }

        // Light on the paper (tilt shading, gloss) is drawn once for the whole sheet and cut
        // to its bent outline. Sliced per strip, translucent pieces would overlap by a pixel
        // row and show as faint lines on dark pictures.
        overlay.frame = CGRect(x: -margin, y: 0, width: w + margin * 2, height: h + tail)
        overlayMask.frame = overlay.bounds
        overlay.mask = overlayMask
        shade.frame = overlay.bounds
        shade.startPoint = CGPoint(x: 0.5, y: 1)
        shade.endPoint = CGPoint(x: 0.5, y: 0)
        overlay.addSublayer(shade)
        if let glossImage {
            let sheen = CALayer()
            sheen.frame = CGRect(x: margin - w * 0.25, y: 0, width: w * 1.5, height: h)
            sheen.contents = glossImage
            sheen.contentsRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
            overlay.addSublayer(sheen)
            gloss = sheen
        }
        body.addSublayer(overlay)

        lip.colors = [CGColor(gray: 0, alpha: 0.44), CGColor(gray: 0, alpha: 0.13), CGColor(gray: 0, alpha: 0)]
        lip.locations = [0, 0.4, 1]
        lip.startPoint = CGPoint(x: 0.5, y: 1)
        lip.endPoint = CGPoint(x: 0.5, y: 0)
        lip.isHidden = true
        body.addSublayer(lip)

        layout()
    }

    // MARK: Pose and bend

    func setPose(_ pose: SheetPose, stageHeight: CGFloat) {
        // Layers live in y-up spaces; the pose is expressed y-down on both sides.
        let localFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let stageFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: stageHeight)
        root.setAffineTransform(localFlip.concatenating(pose.transform).concatenating(stageFlip))
    }

    func setBend(_ newBend: SheetBend) {
        guard newBend != bend || needsLayout else { return }
        bend = newBend
        layout()
    }

    /// The shape of the sheet for the current bend: where each sheet point ends up.
    private struct Profile {
        let bend: SheetBend
        let top: CGFloat
        let bottom: CGFloat
        let width: CGFloat
        /// Sample lines and their foreshortened positions.
        var grid: [CGFloat] = []
        var mapped: [CGFloat] = []

        init(bend: SheetBend, top: CGFloat, bottom: CGFloat, width: CGFloat, lines: [CGFloat]) {
            self.bend = bend
            self.top = top
            self.bottom = bottom
            self.width = width
            grid = lines
            mapped = lines
            guard !lines.isEmpty else { return }
            // Paper tilted towards the viewer covers less height on screen. Accumulate outwards from the hold.
            let start = lines.firstIndex { $0 >= bend.holdY } ?? lines.count
            var previous = bend.holdY, value = bend.holdY
            for index in start..<lines.count {
                let middle = (previous + lines[index]) / 2
                value += (lines[index] - previous) * foreshortening(at: middle)
                mapped[index] = value
                previous = lines[index]
            }
            previous = bend.holdY
            value = bend.holdY
            for index in stride(from: start - 1, through: 0, by: -1) {
                let middle = (previous + lines[index]) / 2
                value += (lines[index] - previous) * foreshortening(at: middle)
                mapped[index] = value
                previous = lines[index]
            }
        }

        private var below: CGFloat { max(24, bottom - bend.holdY) }
        private var above: CGFloat { max(24, bend.holdY - top) }

        func lateral(_ y: CGFloat) -> CGFloat {
            if y >= bend.holdY {
                let u = min(1.2, (y - bend.holdY) / below)
                return bend.lagBelow * u * u
            }
            let u = min(1.2, (bend.holdY - y) / above)
            return bend.lagAbove * u * u
        }

        func depth(_ y: CGFloat) -> CGFloat {
            if y >= bend.holdY {
                let u = min(1.2, (y - bend.holdY) / below)
                let t = max(0, (u - 0.72) / 0.28)
                return bend.lift + bend.curlBelow * u * u + bend.tip * t * t
            }
            let u = min(1.2, (bend.holdY - y) / above)
            return bend.lift + bend.curlAbove * u * u
        }

        /// Change of depth per point travelled down the sheet. Positive = coming towards the viewer.
        func slope(_ y: CGFloat) -> CGFloat {
            if y >= bend.holdY {
                let u = min(1.2, (y - bend.holdY) / below)
                let t = max(0, (u - 0.72) / 0.28)
                return (2 * bend.curlBelow * u + 2 * bend.tip * t / 0.28) / below
            }
            let u = min(1.2, (bend.holdY - y) / above)
            return -(2 * bend.curlAbove * u) / above
        }

        func foreshortening(at y: CGFloat) -> CGFloat {
            let m = slope(y)
            return 1 / (1 + m * m).squareRoot()
        }

        func widthScale(_ y: CGFloat) -> CGFloat { 1 + depth(y) / 700 }

        func mappedY(_ y: CGFloat) -> CGFloat {
            guard let first = grid.first, let last = grid.last else { return y }
            if y <= first { return mapped[0] + (y - first) }
            if y >= last { return mapped[mapped.count - 1] + (y - last) }
            var low = 0, high = grid.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if grid[mid] <= y { low = mid } else { high = mid }
            }
            let span = grid[high] - grid[low]
            let f = span > 0 ? (y - grid[low]) / span : 0
            return mapped[low] + (mapped[high] - mapped[low]) * f
        }

        /// Sheet point → root layer point (y up, origin at the sheet's bottom-left when flat).
        func point(x: CGFloat, y: CGFloat) -> CGPoint {
            let centre = width / 2
            return CGPoint(x: centre + (x - centre) * widthScale(y) + lateral(y), y: bottom - mappedY(y))
        }
    }

    private func layout() {
        needsLayout = false
        let w = size.width, h = size.height
        let lines = strips.map(\.top) + [strips.last?.bottom ?? h]
        let profile = Profile(bend: bend, top: paperRect.minY, bottom: h, width: w, lines: lines)

        for strip in strips {
            let length = strip.bottom - strip.top
            let middle = (strip.top + strip.bottom) / 2
            let scale = profile.widthScale(middle)
            let lateralTop = profile.lateral(strip.top), lateralBottom = profile.lateral(strip.bottom)
            let mappedTop = profile.mappedY(strip.top), mappedBottom = profile.mappedY(strip.bottom)
            strip.layer.setAffineTransform(CGAffineTransform(
                a: scale, b: 0,
                c: (lateralTop - lateralBottom) / length, d: (mappedBottom - mappedTop) / length,
                tx: w / 2 - (pad + w / 2) * scale + lateralBottom, ty: h - mappedBottom
            ))
        }

        // Shadows follow the outline: the further a part stands off the screen, the further its shadow falls.
        let rect = paperRect
        let steps = max(4, Int((rect.height / 14).rounded(.up)))
        var left: [(CGPoint, CGFloat)] = [], right: [(CGPoint, CGFloat)] = []
        var depthSum: CGFloat = 0
        for index in 0...steps {
            let y = rect.minY + rect.height * CGFloat(index) / CGFloat(steps)
            let z = profile.depth(y)
            depthSum += z
            left.append((profile.point(x: 0, y: y), z))
            right.append((profile.point(x: w, y: y), z))
        }
        let meanDepth = depthSum / CGFloat(steps + 1)
        func outline(drop: CGFloat, spread: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for (index, entry) in left.enumerated() {
                let p = CGPoint(x: entry.0.x - entry.1 * spread, y: entry.0.y - entry.1 * drop)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for entry in right.reversed() {
                path.addLine(to: CGPoint(x: entry.0.x + entry.1 * spread, y: entry.0.y - entry.1 * drop))
            }
            path.closeSubpath()
            return path
        }
        far.shadowPath = outline(drop: 1.05, spread: 0.06)
        far.shadowOffset = CGSize(width: 0, height: -5)
        far.shadowRadius = 8 + meanDepth * 0.55
        far.shadowOpacity = Float(max(0.16, 0.30 - meanDepth * 0.004))
        near.shadowPath = outline(drop: 0.12, spread: 0)
        near.shadowOffset = CGSize(width: 0, height: -0.9)
        near.shadowRadius = 1.4 + meanDepth * 0.12
        near.shadowOpacity = Float(0.42 * max(0.15, 1 - meanDepth / 16))

        // Tilt shading: one gradient with a stop at every strip line, placed where that line now sits.
        let total = h + tail
        var stops: [(CGFloat, CGColor)] = lines.map { line in
            (min(1, max(0, (profile.mappedY(line) + tail) / total)), Self.shade(profile.slope(line)))
        }
        stops.sort { $0.0 < $1.0 }
        shade.colors = stops.map(\.1)
        shade.locations = stops.map { NSNumber(value: Double($0.0)) }
        let inkBottom = h - (paper == .thermal ? PaperRenderer.serrationDepth : 0)
        let cut = CGMutablePath()
        let cutSteps = max(4, Int(((inkBottom - rect.minY) / 12).rounded(.up)))
        var rightSide: [CGPoint] = []
        for index in 0...cutSteps {
            let y = rect.minY + (inkBottom - rect.minY) * CGFloat(index) / CGFloat(cutSteps)
            let l = profile.point(x: 0.4, y: y), r = profile.point(x: w - 0.4, y: y)
            let p = CGPoint(x: l.x + margin, y: l.y)
            if index == 0 { cut.move(to: p) } else { cut.addLine(to: p) }
            rightSide.append(CGPoint(x: r.x + margin, y: r.y))
        }
        for p in rightSide.reversed() { cut.addLine(to: p) }
        cut.closeSubpath()
        overlayMask.path = cut

        if let tornTop {
            let depth = PaperRenderer.serrationDepth
            let path = CGMutablePath()
            let teeth = PaperRenderer.serration(width: w, seed: tornSeed, irregularity: 0.5)
            for (index, tooth) in teeth.enumerated() {
                let p = profile.point(x: tooth.x, y: tornTop + depth - tooth.y)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            let reach = max(w, h) + 400
            path.addLine(to: CGPoint(x: w + reach, y: h - tornTop))
            path.addLine(to: CGPoint(x: w + reach, y: -reach))
            path.addLine(to: CGPoint(x: -reach, y: -reach))
            path.addLine(to: CGPoint(x: -reach, y: h - tornTop))
            path.closeSubpath()
            let mask = (body.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = body.bounds
            mask.path = path
            body.mask = mask
        }
    }

    /// The two shadows as plain data, for renderers that cannot draw layer shadows.
    var shadows: [(path: CGPath, offset: CGSize, radius: CGFloat, opacity: CGFloat)] {
        [far, near].compactMap { layer in
            guard let path = layer.shadowPath else { return nil }
            return (path, layer.shadowOffset, layer.shadowRadius, CGFloat(layer.shadowOpacity) * CGFloat(root.opacity))
        }
    }

    private static func shade(_ slope: CGFloat) -> CGColor {
        // Lit from above: paper leaning out towards the viewer catches more light.
        if slope >= 0 { return CGColor(gray: 1, alpha: min(0.16, slope * 0.3)) }
        return CGColor(gray: 0, alpha: min(0.2, -slope * 0.42))
    }

    // MARK: State

    /// `line` is the slot line in sheet coordinates: everything above it is still inside the machine.
    /// `developed` pushes the developing band up past the line once printing has stopped.
    func setSlotLine(_ line: CGFloat?, developed: CGFloat = 0, tilt: Double = 0) {
        guard let line else {
            lip.isHidden = true
            return
        }
        let w = size.width, h = size.height
        // The slot's upper edge shades the paper just below it.
        let visible = h - line
        lip.isHidden = false
        // The shadow belongs to the slot, not the paper: it fades rather than tilting with a swung sheet.
        lip.opacity = Float(min(1, max(0, (visible - 6) / 14)) * max(0, 1 - abs(tilt) / 0.12))
        lip.frame = CGRect(x: 0, y: h - line - Self.lipLength, width: w, height: Self.lipLength)

        guard isRevealingInk else { return }
        let start = line - developed
        let end = start + Self.developLength
        for index in strips.indices {
            guard let ink = strips[index].printed else { continue }
            let top = strips[index].top, bottom = strips[index].bottom
            strips[index].blank.isHidden = top >= end && top >= 0
            if top >= end {
                ink.isHidden = false
                ink.mask = nil
            } else if bottom <= start {
                ink.isHidden = true
            } else {
                ink.isHidden = false
                let mask = strips[index].revealMask ?? {
                    let gradient = CAGradientLayer()
                    gradient.startPoint = CGPoint(x: 0.5, y: 1)
                    gradient.endPoint = CGPoint(x: 0.5, y: 0)
                    gradient.colors = [
                        CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0),
                        CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1),
                    ]
                    strips[index].revealMask = gradient
                    return gradient
                }()
                mask.frame = ink.bounds
                let a = min(1, max(0, (start - top) / (bottom - top)))
                let b = min(1, max(a, (end - top) / (bottom - top)))
                mask.locations = [0, NSNumber(value: a), NSNumber(value: b), 1]
                ink.mask = mask
            }
        }
    }

    /// Ink is fully developed; stop masking it.
    func finishReveal() {
        guard isRevealingInk else { return }
        isRevealingInk = false
        for strip in strips {
            strip.printed?.isHidden = false
            strip.printed?.mask = nil
            strip.blank.isHidden = strip.printed != nil && strip.top >= 0
        }
    }

    var isRevealing: Bool { isRevealingInk }

    /// Moves the sheen across a glossy sheet. 0…1, 0.5 = centred.
    func setGloss(phase: Double) {
        guard let gloss else { return }
        // The image is three sheets wide with the band in the middle; the layer shows half of it.
        let c = CGFloat(min(1.2, max(-0.2, phase)))
        gloss.contentsRect.origin.x = min(0.5, max(0, 0.25 - (c - 0.5) / 3))
    }

    /// Cuts the sheet from the roll at `line` (sheet coordinates), leaving a serrated top edge.
    func tear(at line: CGFloat, seed: UInt64) {
        tornTop = min(size.height * 0.3, max(-tail, line))
        tornSeed = seed
        lip.isHidden = true
        needsLayout = true
        layout()
    }

    var opacity: CGFloat {
        get { CGFloat(root.opacity) }
        set { root.opacity = Float(min(1, max(0, newValue))) }
    }

    /// The visible paper in sheet coordinates.
    var paperRect: CGRect {
        let top = tornTop ?? -tail
        return CGRect(x: 0, y: top, width: size.width, height: size.height - top)
    }

    // MARK: Images

    /// The sheet (and the roll paper above it) on one padded canvas, so every strip samples the same image.
    private static func canvas(sheet: CGImage, tail: CGImage?, tailPixels: Int, pad: Int) -> CGImage {
        let bitmap = Bitmap(width: sheet.width + pad * 2, height: sheet.height + tailPixels + pad * 2)
        let ctx = bitmap.context
        ctx.interpolationQuality = .none
        if let tail {
            ctx.draw(tail, in: CGRect(x: pad, y: pad + sheet.height, width: sheet.width, height: tailPixels))
        }
        ctx.draw(sheet, in: CGRect(x: pad, y: pad, width: sheet.width, height: sheet.height))
        return bitmap.image()
    }

    /// A soft diagonal band of light, three sheets wide so it can slide across.
    private static func glossImage(width: CGFloat, height: CGFloat) -> CGImage {
        let w = max(3, Int(width * 3)), h = max(1, Int(height))
        let bitmap = Bitmap(width: w, height: h)
        for y in 0..<h {
            let row = bitmap.pixels + y * bitmap.rowBytes
            for x in 0..<w {
                let centre = Double(width) * 1.5 - (Double(y) - Double(height) / 2) * 0.62
                let d = (Double(x) - centre) / Double(width)
                let band = 0.15 * exp(-(d * d) / 0.018) + 0.035 * exp(-(d * d) / 0.16)
                let value = UInt8(min(255, max(0, band * 255)))
                let p = row + x * 4
                p[0] = value
                p[1] = value
                p[2] = value
                p[3] = value
            }
        }
        return bitmap.image()
    }
}
