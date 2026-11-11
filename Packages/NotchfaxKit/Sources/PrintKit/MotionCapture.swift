import AppKit

/// A recorded pointer path, relative to the slot's anchor (x right, y down).
struct PointerScript {
    struct Key {
        var time: TimeInterval
        var x: CGFloat
        var y: CGFloat
    }

    var keys: [Key]
    var pressAt: TimeInterval
    var releaseAt: TimeInterval

    func point(at time: TimeInterval) -> CGPoint {
        guard let first = keys.first, let last = keys.last else { return .zero }
        if time <= first.time { return CGPoint(x: first.x, y: first.y) }
        if time >= last.time { return CGPoint(x: last.x, y: last.y) }
        for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
            let u = CGFloat(Motion.smoothstep((time - a.time) / max(0.0001, b.time - a.time)))
            return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
        }
        return CGPoint(x: last.x, y: last.y)
    }

    /// Plays a script against a sheet controller, one frame at a time.
    struct Run {
        let script: PointerScript
        let anchor: CGPoint
        private(set) var time: TimeInterval = 0
        private(set) var isDown = false

        init(script: PointerScript, anchor: CGPoint) {
            self.script = script
            self.anchor = anchor
        }

        var pointer: CGPoint {
            let p = script.point(at: time)
            return CGPoint(x: anchor.x + p.x, y: anchor.y + p.y)
        }

        /// Returns true once the script has released the button.
        @MainActor
        mutating func advance(_ dt: TimeInterval, on controller: SheetController) -> Bool {
            time += dt
            let point = pointer
            if !isDown, time >= script.pressAt, time < script.releaseAt {
                isDown = true
                controller.mouseDown(at: point, time: time)
            } else if isDown, time < script.releaseAt {
                controller.mouseDragged(to: point, time: time)
            } else if isDown {
                isDown = false
                controller.mouseUp(at: point, time: time)
            }
            return time >= script.releaseAt && !isDown
        }
    }

    // MARK: Library

    static let library: [String: @Sendable (CGFloat) -> PointerScript] = [
        "swing": swing, "carry": carry, "carry-out": carryOut, "rip": rip, "half-tear": halfTear, "fling": fling,
    ]

    /// Take hold of the middle of the sheet, swing it right then left, let go.
    static func swing(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: 6, y: h * 0.6), Key(time: 0.12, x: 6, y: h * 0.6),
            Key(time: 0.42, x: 34, y: h * 0.6 + 3), Key(time: 0.78, x: -30, y: h * 0.6 + 2),
        ], pressAt: 0.1, releaseAt: 0.82)
    }

    /// Pull a cut sheet out of the slot, carry it around, let go so it returns.
    static func carry(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: 0, y: h * 0.5), Key(time: 0.12, x: 0, y: h * 0.5),
            Key(time: 0.38, x: 12, y: h * 0.5 + 75), Key(time: 0.7, x: 120, y: h * 0.5 + 110),
            Key(time: 1.05, x: -90, y: h * 0.5 + 150), Key(time: 1.2, x: -100, y: h * 0.5 + 140),
        ], pressAt: 0.1, releaseAt: 1.22)
    }

    /// Carry a sheet well away from the machine and hold it still, as when aiming at a folder.
    static func carryOut(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: 0, y: h * 0.5), Key(time: 0.12, x: 0, y: h * 0.5),
            Key(time: 0.38, x: 12, y: h * 0.5 + 75), Key(time: 0.9, x: 250, y: h * 0.5 + 240),
            Key(time: 1.6, x: 252, y: h * 0.5 + 244),
        ], pressAt: 0.1, releaseAt: 1.6)
    }

    /// Rip a thermal sheet sideways in one motion and drop it.
    static func rip(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: 0, y: h * 0.45), Key(time: 0.12, x: 0, y: h * 0.45),
            Key(time: 0.26, x: 30, y: h * 0.45 + 6), Key(time: 0.5, x: 150, y: h * 0.45 + 50),
            Key(time: 0.8, x: 120, y: h * 0.45 + 60),
        ], pressAt: 0.1, releaseAt: 0.85)
    }

    /// Tear slowly, stop half way and let go: the sheet hangs by what is left, then gives way.
    static func halfTear(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: -10, y: h * 0.4), Key(time: 0.12, x: -10, y: h * 0.4),
            Key(time: 0.9, x: 120, y: h * 0.4 + 26),
        ], pressAt: 0.1, releaseAt: 1.0)
    }

    /// Rip and throw: released while still moving fast.
    static func fling(height h: CGFloat) -> PointerScript {
        PointerScript(keys: [
            Key(time: 0, x: 0, y: h * 0.45), Key(time: 0.12, x: 0, y: h * 0.45),
            Key(time: 0.24, x: 30, y: h * 0.45 + 6), Key(time: 0.56, x: 420, y: h * 0.45 + 40),
        ], pressAt: 0.1, releaseAt: 0.5)
    }
}

/// Runs a sheet through the real controller without windows and photographs it at set times.
@MainActor
struct MotionCapture {
    let name: String
    var job: () -> PrintJob
    /// Built from the sheet's on-screen height. Nil captures the feed itself.
    var script: ((CGFloat) -> PointerScript)?
    /// Capture times in seconds, from the start of the feed or of the script.
    var times: [TimeInterval]
    var reduceMotion = false
    var tile = CGSize(width: 400, height: 400)
    /// Shifts the view so sheets carried sideways stay in frame.
    var width: CGFloat = 640

    static var all: [MotionCapture] {
        [
            MotionCapture(name: "feed-photo", job: { PrintSamples.photo() }, times: [0.1, 0.25, 0.4, 0.6, 0.8, 1.0, 1.15, 1.25, 1.35, 1.5, 1.8, 2.4], tile: CGSize(width: 300, height: 230), width: 300),
            MotionCapture(name: "feed-fax", job: { PrintSamples.fax() }, times: [0.15, 0.4, 0.7, 1.0, 1.4, 1.8, 2.1, 2.3, 2.45, 2.6, 2.9, 3.6], tile: CGSize(width: 300, height: 360), width: 300),
            MotionCapture(name: "swing-strip", job: { PrintSamples.strip() }, script: PointerScript.swing, times: [0.1, 0.25, 0.42, 0.55, 0.68, 0.8, 0.9, 1.0, 1.15, 1.3, 1.6, 2.2], tile: CGSize(width: 300, height: 340), width: 300),
            MotionCapture(name: "carry-photo", job: { PrintSamples.photo() }, script: PointerScript.carry, times: [0.1, 0.25, 0.38, 0.5, 0.62, 0.72, 0.9, 1.05, 1.2, 1.35, 1.55, 2.2]),
            MotionCapture(name: "carry-out-photo", job: { PrintSamples.photo() }, script: PointerScript.carryOut, times: [0.5, 0.9, 1.0, 1.1, 1.2, 1.5], tile: CGSize(width: 640, height: 480)),
            MotionCapture(name: "rip-fax", job: { PrintSamples.fax() }, script: PointerScript.rip, times: [0.2, 0.28, 0.32, 0.36, 0.4, 0.44, 0.5, 0.6, 0.8, 0.95, 1.1, 1.3], tile: CGSize(width: 400, height: 520)),
            MotionCapture(name: "half-tear-fax", job: { PrintSamples.fax() }, script: PointerScript.halfTear, times: [0.3, 0.5, 0.7, 0.9, 1.1, 1.6, 3.2, 3.6, 3.75, 3.9, 4.05, 4.2], tile: CGSize(width: 400, height: 520)),
            MotionCapture(name: "fling-fax", job: { PrintSamples.fax() }, script: PointerScript.fling, times: [0.26, 0.38, 0.5, 0.62, 0.8, 1.0], tile: CGSize(width: 900, height: 520), width: 900),
            MotionCapture(name: "reduce-motion-fax", job: { PrintSamples.fax() }, times: [0.05, 0.15, 0.3, 0.5], reduceMotion: true, tile: CGSize(width: 300, height: 360), width: 300),
        ]
    }

    func contactSheet() -> CGImage {
        let host = OffscreenHost(size: CGSize(width: width, height: tile.height), reduceMotion: reduceMotion)
        let job = job()
        let layout = job.sheet.resolvedSize()
        let rendered = PaperRenderer.render(job.sheet, size: layout, scale: job.sheet.paper == .thermal ? 2 : 3, seed: 7)
        let fit = host.geometry.fittingScale(forPaperWidth: layout.width)
        let controller = SheetController(job: job, handle: nil, rendered: rendered, fit: fit, host: host, seed: 7)
        host.controllers.append(controller)
        host.scene.nodes.append(controller.node)
        controller.beginFeed()

        let dt = 1.0 / 120
        var frames: [(CGImage, String)] = []
        func step() {
            for sheet in host.controllers where sheet.needsFrames { sheet.tick(dt) }
        }
        var run: PointerScript.Run?
        if let script {
            // Let the sheet print and come to rest before the hand arrives.
            var waited = 0.0
            while waited < 8, controller.phase != .hanging || controller.needsFrames {
                step()
                waited += dt
            }
            run = PointerScript.Run(script: script(controller.node.size.height), anchor: host.geometry.anchor)
        }
        var time = 0.0, housekeeping = 0.0
        var pending = times.sorted()[...]
        while let next = pending.first, time < next + dt {
            if run != nil, run?.advance(dt, on: controller) == true {
                host.pointer = nil
                run = nil
            } else if let current = run {
                host.pointer = current.isDown ? current.pointer : nil
            }
            step()
            housekeeping += dt
            if housekeeping >= 0.25 {
                housekeeping = 0
                host.controllers.forEach { $0.housekeeping(0.25) }
            }
            time += dt
            if time >= next {
                var label = String(format: "%.2fs  %@", next, "\(controller.phase)".components(separatedBy: "(").first ?? "")
                if host.dragSessionRequested { label += "  [file drag]" }
                frames.append((host.render(viewWidth: tile.width), label))
                pending = pending.dropFirst()
            }
        }
        return Self.compose(frames, tile: tile)
    }

    private static func compose(_ frames: [(CGImage, String)], tile: CGSize) -> CGImage {
        let columns = min(6, max(1, frames.count))
        let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
        let scale: CGFloat = 1.25
        let gap: CGFloat = 3, caption: CGFloat = 16
        let cell = CGSize(width: tile.width + gap, height: tile.height + caption + gap)
        let bitmap = Bitmap(width: Int(cell.width * CGFloat(columns) * scale), height: Int(cell.height * CGFloat(rows) * scale))
        let ctx = bitmap.context
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows)))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            let x = CGFloat(column) * cell.width
            let y = cell.height * CGFloat(rows - 1 - row)
            ctx.draw(frame.0, in: CGRect(x: x, y: y, width: tile.width, height: tile.height))
            NSString(string: frame.1).draw(
                at: CGPoint(x: x + 4, y: y + tile.height + 2),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.image()
    }
}

/// The stage without windows: the same layers, rendered into bitmaps.
@MainActor
final class OffscreenHost: SheetHost {
    let scene: Scene
    let reduceMotion: Bool
    let sound = SoundPlayer()
    var controllers: [SheetController] = []
    var pointer: CGPoint? { didSet { updatePointer() } }
    private(set) var dragSessionRequested = false
    private let pointerLayer = CAShapeLayer()

    init(size: CGSize, reduceMotion: Bool) {
        scene = Scene(size: size)
        self.reduceMotion = reduceMotion
        sound.isMuted = true
        pointerLayer.fillColor = CGColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: 0.9)
        pointerLayer.strokeColor = CGColor(gray: 1, alpha: 0.9)
        pointerLayer.lineWidth = 1
        pointerLayer.isHidden = true
        scene.overlay.addSublayer(pointerLayer)
    }

    var geometry: SlotGeometry { scene.geometry }

    func place(_ layer: CALayer, clipped: Bool, atBack: Bool) {
        let target = clipped ? scene.clip : scene.free
        guard layer.superlayer !== target else { return }
        if atBack { target.insertSublayer(layer, at: 0) } else { target.addSublayer(layer) }
    }

    func slotDidFree(_ controller: SheetController) {}
    func remove(_ controller: SheetController) { controllers.removeAll { $0 === controller } }
    func sheetStateDidChange() {}
    func requestFrames() {}
    func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {}

    func beginDragSession(for controller: SheetController) -> Bool {
        dragSessionRequested = true
        return false
    }

    private func updatePointer() {
        guard let pointer else {
            pointerLayer.isHidden = true
            return
        }
        pointerLayer.isHidden = false
        pointerLayer.path = CGPath(ellipseIn: CGRect(x: pointer.x - 3.5, y: scene.size.height - pointer.y - 3.5, width: 7, height: 7), transform: nil)
    }

    /// Renders the middle `viewWidth` points of the scene.
    func render(viewWidth: CGFloat) -> CGImage {
        let full = scene.render(scale: 1.25)
        let inset = (scene.size.width - viewWidth) / 2 * 1.25
        return full.cropping(to: CGRect(x: inset, y: 0, width: viewWidth * 1.25, height: CGFloat(full.height))) ?? full
    }
}
