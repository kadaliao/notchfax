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

/// The layer tree of one sheet of paper. Purely presentational: the controller (or
/// the offscreen gallery) tells it where it is and what state it is in.
@MainActor
final class SheetNode {
    let root = CALayer()
    /// On-screen size in points.
    let size: CGSize
    let tail: CGFloat
    let paper: Paper

    private let ambient = CALayer()
    private let contact = CALayer()
    private let body = CALayer()
    private let printed = CALayer()
    private let lip = CAGradientLayer()
    private var gloss: CAGradientLayer?
    private var revealMask: CALayer?
    private let revealSolid = CALayer()
    private let revealRamp = CAGradientLayer()
    private let ambientSlice = ShadowImage.slice(blur: 13)
    private let contactSlice = ShadowImage.slice(blur: 1.6)
    private let fit: CGFloat
    /// Top of the visible paper in sheet coordinates once torn; nil while on the roll.
    private(set) var tornTop: CGFloat?
    private var shadowTop: CGFloat = 0

    static let developLength: CGFloat = 26
    static let lipLength: CGFloat = 18

    init(rendered: RenderedSheet, fit: CGFloat, progressive: Bool) {
        self.fit = fit
        paper = rendered.paper
        size = CGSize(width: rendered.size.width * fit, height: rendered.size.height * fit)
        tail = rendered.tailLength * fit
        let w = size.width, h = size.height

        root.anchorPoint = .zero
        root.position = .zero
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h + tail)

        for (layer, slice) in [(ambient, ambientSlice), (contact, contactSlice)] {
            layer.contents = slice.image
            layer.contentsCenter = slice.center
            layer.contentsScale = 2
            root.addSublayer(layer)
        }

        body.frame = root.bounds
        root.addSublayer(body)

        if let tailImage = rendered.tail {
            let tailLayer = CALayer()
            tailLayer.contents = tailImage
            tailLayer.frame = CGRect(x: 0, y: h, width: w, height: tail)
            body.addSublayer(tailLayer)
        }

        let blank = CALayer()
        blank.contents = rendered.blank
        blank.frame = CGRect(x: 0, y: 0, width: w, height: h)
        body.addSublayer(blank)

        printed.contents = rendered.printed
        printed.frame = blank.frame
        body.addSublayer(printed)

        if progressive {
            let mask = CALayer()
            mask.frame = printed.bounds
            revealSolid.backgroundColor = CGColor(gray: 0, alpha: 1)
            revealRamp.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0)]
            revealRamp.locations = [0, 0.55, 1]
            revealRamp.startPoint = CGPoint(x: 0.5, y: 0)
            revealRamp.endPoint = CGPoint(x: 0.5, y: 1)
            mask.addSublayer(revealSolid)
            mask.addSublayer(revealRamp)
            printed.mask = mask
            revealMask = mask
        }

        if paper != .thermal {
            let sheen = CAGradientLayer()
            sheen.frame = blank.frame
            sheen.cornerRadius = 1.4 * fit
            sheen.masksToBounds = true
            sheen.startPoint = CGPoint(x: 0, y: 1)
            sheen.endPoint = CGPoint(x: 1, y: 0)
            sheen.colors = [
                CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 0.03), CGColor(gray: 1, alpha: 0.15),
                CGColor(gray: 1, alpha: 0.02), CGColor(gray: 1, alpha: 0),
            ]
            body.addSublayer(sheen)
            gloss = sheen
            setGloss(phase: 0.5)
        }

        lip.colors = [CGColor(gray: 0, alpha: 0.44), CGColor(gray: 0, alpha: 0.13), CGColor(gray: 0, alpha: 0)]
        lip.locations = [0, 0.4, 1]
        lip.startPoint = CGPoint(x: 0.5, y: 1)
        lip.endPoint = CGPoint(x: 0.5, y: 0)
        lip.isHidden = true
        body.addSublayer(lip)

        setLift(0)
    }

    // MARK: State

    func setPose(_ pose: SheetPose, stageHeight: CGFloat) {
        // Layers live in y-up spaces; the pose is expressed y-down on both sides.
        let localFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let stageFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: stageHeight)
        root.setAffineTransform(localFlip.concatenating(pose.transform).concatenating(stageFlip))
    }

    /// `line` is the slot line in sheet coordinates: everything above it is still inside the machine.
    /// `developed` pushes the developing band up past the line once printing has stopped.
    func setSlotLine(_ line: CGFloat?, developed: CGFloat = 0) {
        guard let line else {
            lip.isHidden = true
            return
        }
        let w = size.width, h = size.height
        // The slot's upper edge shades the paper just below it.
        let visible = h - line
        lip.isHidden = false
        lip.opacity = Float(min(1, max(0, (visible - 6) / 14)))
        lip.frame = CGRect(x: 0, y: h - line - Self.lipLength, width: w, height: Self.lipLength)

        if revealMask != nil {
            let start = line - developed
            let rampTop = h - start
            revealRamp.frame = CGRect(x: 0, y: rampTop - Self.developLength, width: w, height: Self.developLength)
            revealSolid.frame = CGRect(x: 0, y: -4, width: w, height: max(0, rampTop - Self.developLength + 4))
        }
    }

    /// Ink is fully developed; stop masking it.
    func finishReveal() {
        printed.mask = nil
        revealMask = nil
    }

    var isRevealing: Bool { revealMask != nil }

    /// 0 = lying against the screen under the slot, 1 = lifted in the hand.
    func setLift(_ lift: CGFloat) {
        let w = size.width, h = size.height
        let l = min(1.4, max(0, lift))
        let top = h - shadowTop
        let caster = CGRect(x: 0, y: 0, width: w, height: top)

        let ambientRect = caster
            .insetBy(dx: 3 - 5 * l, dy: 2 - 2 * l)
            .offsetBy(dx: 0, dy: -(6 + 15 * l))
        ambient.frame = ambientRect.insetBy(dx: -ambientSlice.pad, dy: -ambientSlice.pad)
        ambient.opacity = Float(0.34 - 0.08 * l)

        contact.frame = caster.insetBy(dx: 0.3, dy: 0.3).offsetBy(dx: 0, dy: -0.9)
            .insetBy(dx: -contactSlice.pad, dy: -contactSlice.pad)
        contact.opacity = Float(0.5 * (1 - 0.75 * min(1, l)))
    }

    /// Moves the sheen across a glossy sheet. 0…1, 0.5 = centred.
    func setGloss(phase: Double) {
        guard let gloss else { return }
        let c = min(1.3, max(-0.3, phase))
        gloss.locations = [c - 0.34, c - 0.10, c, c + 0.07, c + 0.24].map { NSNumber(value: min(1, max(0, $0))) }
    }

    /// Cuts the sheet from the roll at `line` (sheet coordinates), leaving a serrated top edge.
    func tear(at line: CGFloat, seed: UInt64) {
        let w = size.width, h = size.height
        let y = min(0, max(-tail, line))
        tornTop = y
        shadowTop = y
        let top = h - y
        let depth = PaperRenderer.serrationDepth
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -8))
        path.addLine(to: CGPoint(x: w, y: -8))
        for point in PaperRenderer.serration(width: w, seed: seed, irregularity: 0.5).reversed() {
            path.addLine(to: CGPoint(x: point.x, y: top - depth + point.y))
        }
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.frame = body.bounds
        mask.path = path
        body.mask = mask
        lip.isHidden = true
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
}
