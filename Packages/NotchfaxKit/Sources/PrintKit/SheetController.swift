import AppKit

/// What a sheet needs from the surface it lives on. The live `Stage` and the
/// offscreen motion capture both provide it, so both run the same physics.
@MainActor
protocol SheetHost: AnyObject {
    var geometry: SlotGeometry { get }
    var reduceMotion: Bool { get }
    var sound: SoundPlayer { get }
    /// Puts a layer under the slot (hidden above the slot line) or on the open stage.
    func place(_ layer: CALayer, clipped: Bool, atBack: Bool)
    func slotDidFree(_ controller: SheetController)
    func remove(_ controller: SheetController)
    func sheetStateDidChange()
    func requestFrames()
    func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern)
    /// Starts a system file drag for the sheet. Returns false if that is not possible.
    func beginDragSession(for controller: SheetController) -> Bool
}

/// Drives one sheet of paper from the moment it starts to feed until it is gone:
/// motor, hanging physics, bending, grabbing, tearing, drag-out and retraction.
///
/// Every state reads its starting values from what is currently on screen, so any
/// motion can be interrupted by the pointer or by another request at any time.
@MainActor
final class SheetController {
    enum Phase: Equatable {
        case feeding, hanging, retracting, inserting
        case tearing, freeHeld, dragSession, returning, falling
        case fadingIn
        case fadingOut(PrintOutcome?)
        case gone
    }

    private enum MotorGoal { case feedOut, reposition, retract, insert }

    private struct Motor {
        var program: FeedProgram
        var base: Double
        var direction: Double
        var goal: MotorGoal
        var time: TimeInterval = 0
        var lastStep = -1
    }

    private struct Grab {
        var start: CGPoint
        var local: CGPoint
        var lever: CGVector
        var baseSway: Double
        var basePull: Double
        var moved = false
        var samples: [(time: TimeInterval, point: CGPoint)] = []
        var lastTime: TimeInterval
    }

    /// A tear in progress. It starts at the edge away from the pull and its front
    /// travels across the sheet as the pointer drags.
    private struct Tear {
        /// +1 when pulled to the right (the tear starts at the left edge), −1 the other way.
        var side: Double
        var progress = 0.0
        var base = 0.0
        var origin: CGPoint
        var angle: Spring
        var offsetX: Spring
        var offsetY: Spring
        var finishesAlone = false
        var grains = 0
    }

    let id = UUID()
    let job: PrintJob
    let node: SheetNode
    private(set) var phase: Phase = .feeding
    private(set) var isTorn = false
    private(set) var slotFreed = false
    var hovered = false { didSet { if hovered { idle = 0 } } }
    /// When another job is waiting, the sheet leaves after this long instead of its own policy.
    var hurryLimit: TimeInterval?

    private(set) weak var handle: PrintHandle?
    private unowned let host: any SheetHost
    private let rendered: RenderedSheet
    private let seed: UInt64
    private let w: CGFloat
    private let h: CGFloat
    private let restOut: Double
    private let cadence: FeedCadence
    private let restCurl: Double
    private let tipCurl: Double
    /// How readily the stock bends: roll paper is limp, photo paper is stiff.
    private let flex: Double

    // Attached to the slot.
    private var fed = 0.0
    private var motor: Motor?
    private var pull = Spring()
    private var sag = Spring()
    private var sagTarget = 0.0
    private var sway = Spring()
    private var cutCountdown: TimeInterval?
    private var developed = 0.0
    private var isDeveloping = false
    private var glide = Spring()
    private var insertPause: TimeInterval = 0
    private var insertCompletion: (() -> Void)?

    // Shape.
    private var lift = Spring()
    private var curl = Spring()
    private var lagBelow = Spring()
    private var lagAbove = Spring()
    private var lastAngle = 0.0
    private var angularVelocity = 0.0

    // In the hand or in the air.
    private var grab: Grab?
    private var cursor = CGPoint.zero
    private var freePivot = CGPoint.zero
    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var followX = Spring(), followY = Spring()
    private var pendulum = Pendulum()
    private var smoothedAcceleration = 0.0
    private var smoothedSpeed = 0.0
    private var carryDwell: TimeInterval = 0
    private var returnX = Spring(), returnY = Spring(), returnAngle = Spring()
    private var fallAngle = 0.0, fallSpin = 0.0, fallTime: TimeInterval = 0

    // Tearing.
    private var tear: Tear?
    private var stub: CALayer?
    private var stubAge: TimeInterval?
    private var stubAngle = 0.0
    static let stubLength: CGFloat = 5

    private var glossShift = Spring()
    private var glossTarget = 0.0
    private var idle: TimeInterval = 0
    private var exportURL: URL?
    private var exportTask: Task<Void, Never>?

    init(job: PrintJob, handle: PrintHandle?, rendered: RenderedSheet, fit: CGFloat, host: any SheetHost, seed: UInt64) {
        self.job = job
        self.handle = handle
        self.rendered = rendered
        self.host = host
        self.seed = seed
        var progressive = false
        var cadence = job.cadence ?? job.sheet.paper.defaultCadence
        if case .progressive(let lineHeight) = job.reveal {
            progressive = true
            if job.cadence == nil { cadence = .text(lineHeight: Double(lineHeight * fit)) }
        }
        self.cadence = cadence
        node = SheetNode(rendered: rendered, fit: fit, progressive: progressive)
        w = node.size.width
        h = node.size.height
        // Cut paper stays gripped by its top edge; roll paper shows a little extra leader.
        restOut = Double(job.sheet.paper.isTearable ? h + 3 : h - 5)
        // Roll paper remembers the roll; photo paper is stiffer and nearly flat.
        switch job.sheet.paper {
        case .thermal:
            restCurl = min(20, 9 + Double(h) * 0.025)
            tipCurl = 7
            flex = 1
        case .glossyPhoto:
            restCurl = 5
            tipCurl = 1.5
            flex = 0.3
        case .photoStrip:
            restCurl = 9
            tipCurl = 3
            flex = 0.55
        }
    }

    private var paper: Paper { job.sheet.paper }
    private var out: Double { fed + pull.value + sag.value }
    private var anchor: CGPoint { host.geometry.anchor }
    /// Thermal paper tears a little below the slot, against the serrated bar.
    private var tearLineStage: CGPoint { CGPoint(x: anchor.x, y: anchor.y + Self.stubLength) }

    // MARK: Starting

    func beginFeed() {
        handle?.emit(.startedFeeding)
        host.place(node.root, clipped: true, atBack: false)
        if host.reduceMotion {
            phase = .fadingIn
            fed = restOut
            curl = Spring(value: restCurl)
            node.opacity = 0
            node.finishReveal()
        } else {
            phase = .feeding
            fed = 0
            motor = Motor(program: FeedProgram(distance: restOut, cadence: cadence, seed: seed), base: 0, direction: 1, goal: .feedOut)
        }
        apply()
    }

    /// The reverse of printing: the sheet starts `gap` points below the slot and is taken in.
    func beginInsert(gap: CGFloat, completion: @escaping () -> Void) {
        insertCompletion = completion
        host.place(node.root, clipped: true, atBack: false)
        node.finishReveal()
        if host.reduceMotion {
            fed = Double(h + gap)
            phase = .fadingOut(nil)
        } else {
            phase = .inserting
            glide = Spring(value: Double(gap))
            fed = Double(h) + glide.value
            lift = Spring(value: 0.9)
        }
        apply()
    }

    // MARK: Pose

    private var isFree: Bool {
        switch phase {
        case .freeHeld, .dragSession, .returning, .falling: true
        default: false
        }
    }

    private var tearFrontLocal: CGPoint {
        guard let tear else { return .zero }
        let x = tear.side > 0 ? CGFloat(tear.progress) * w : w - CGFloat(tear.progress) * w
        return CGPoint(x: x, y: node.tornTop ?? 0)
    }

    var pose: SheetPose {
        switch phase {
        case .tearing where tear != nil:
            let front = tearFrontLocal
            let line = tearLineStage
            return SheetPose(
                pivotLocal: front,
                pivotStage: CGPoint(
                    x: line.x - w / 2 + front.x + (tear?.offsetX.value ?? 0),
                    y: line.y + (tear?.offsetY.value ?? 0)
                ),
                angle: tear?.angle.value ?? 0
            )
        case .freeHeld, .dragSession:
            return SheetPose(pivotLocal: freePivot, pivotStage: pos, angle: pendulum.angle)
        case .returning:
            return SheetPose(pivotLocal: freePivot, pivotStage: pos, angle: returnAngle.value)
        case .falling:
            return SheetPose(pivotLocal: freePivot, pivotStage: pos, angle: fallAngle)
        default:
            return SheetPose(pivotLocal: CGPoint(x: w / 2, y: h - out), pivotStage: anchor, angle: sway.value)
        }
    }

    private var bend: SheetBend {
        var bend = SheetBend()
        bend.lift = lift.value * 9
        bend.tip = tipCurl
        switch phase {
        case .freeHeld, .dragSession, .returning, .falling:
            bend.holdY = freePivot.y
            bend.lagBelow = lagBelow.value
            bend.lagAbove = lagAbove.value
            let rect = node.paperRect
            let below = max(0, min(1, (rect.maxY - freePivot.y) / rect.height))
            bend.curlBelow = curl.value * below
            bend.curlAbove = curl.value * (1 - below) * 0.7
            bend.tip = tipCurl * below
        case .tearing:
            bend.holdY = node.tornTop ?? 0
            bend.lagBelow = lagBelow.value
            bend.curlBelow = curl.value
        default:
            bend.holdY = CGFloat(Double(h) - out)
            bend.lagBelow = lagBelow.value
            // A short tongue of paper has not had room to curl yet.
            let exposed = min(1, max(0, out / Double(max(60, h))))
            bend.curlBelow = curl.value * exposed
            bend.tip = tipCurl * min(1, max(0, out / 50))
        }
        return bend
    }

    private func apply() {
        guard phase != .gone else { return }
        let pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let stageHeight = host.geometry.screenSize.height
        node.setPose(pose, stageHeight: stageHeight)
        let attached = !isFree && phase != .tearing && !isTorn
        node.setSlotLine(attached ? CGFloat(Double(h) - out) : nil, developed: developed, tilt: pose.angle)
        node.setBend(bend)
        var gloss = 0.5 + pose.angle * 1.7 + glossShift.value + lagBelow.value * 0.004
        if isFree { gloss += Double(pos.x - anchor.x) * 0.0016 + Double(pos.y - anchor.y) * 0.0009 }
        node.setGloss(phase: gloss)
        if let stub {
            let line = tearLineStage
            let rise = stubRise
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: stageHeight)
            let place = CGAffineTransform(translationX: -w / 2, y: -Self.stubCanvas)
                .concatenating(CGAffineTransform(rotationAngle: stubAngle))
                .concatenating(CGAffineTransform(translationX: line.x, y: line.y - rise))
            let local = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Self.stubCanvas + PaperRenderer.serrationDepth)
            stub.setAffineTransform(local.concatenating(place).concatenating(flip))
        }
        CATransaction.commit()
    }

    /// Whether `point` (stage coordinates) is on the visible paper.
    func hitTest(_ point: CGPoint) -> Bool {
        switch phase {
        case .gone, .dragSession, .fadingOut, .inserting: return false
        default: break
        }
        if !isFree, phase != .tearing, point.y < anchor.y { return false }
        return node.paperRect.insetBy(dx: -3, dy: -3).contains(pose.localPoint(point))
    }

    /// The area the pointer can reach the sheet in, in stage coordinates; nil when it cannot be touched.
    var interactiveBounds: CGRect? {
        switch phase {
        case .gone, .dragSession, .fadingOut, .inserting: return nil
        default: break
        }
        let pose = pose
        let rect = node.paperRect
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map(pose.stagePoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        var bounds = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)
        ).insetBy(dx: -3, dy: -3)
        if !isFree, phase != .tearing {
            let top = max(bounds.minY, anchor.y)
            bounds = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
        }
        return bounds.height > 1 ? bounds : nil
    }

    /// Bottom-centre of the hanging sheet in stage coordinates.
    var bottomCentre: CGPoint { pose.stagePoint(CGPoint(x: w / 2, y: h)) }

    var showsActions: Bool {
        phase == .hanging && motor == nil && grab == nil && hovered && !job.actions.isEmpty && !isTorn
    }

    // MARK: Frame

    var needsFrames: Bool {
        switch phase {
        case .gone: return false
        case .hanging:
            if motor != nil || grab != nil || cutCountdown != nil || isDeveloping || stub != nil { return true }
            return !(pull.isSettled(at: 0) && sway.isSettled(at: 0, tolerance: 0.0006, speed: 0.004)
                && sag.isSettled(at: sagTarget) && lift.isSettled(at: 0, tolerance: 0.01, speed: 0.05)
                && curl.isSettled(at: restCurl, tolerance: 0.05, speed: 0.4)
                && lagBelow.isSettled(at: 0, tolerance: 0.05, speed: 0.4)
                && glossShift.isSettled(at: glossTarget, tolerance: 0.002, speed: 0.01))
        default: return true
        }
    }

    func tick(_ dt: TimeInterval) {
        switch phase {
        case .feeding, .hanging, .retracting, .inserting:
            tickAttached(dt)
        case .tearing:
            tickTear(dt)
        case .freeHeld:
            followX.step(to: 0, response: 0.17, damping: 0.86, dt: dt)
            followY.step(to: 0, response: 0.17, damping: 0.86, dt: dt)
            let next = CGPoint(x: cursor.x + followX.value, y: cursor.y + followY.value)
            let v = CGVector(dx: (next.x - pos.x) / dt, dy: (next.y - pos.y) / dt)
            let acceleration = min(40_000, max(-40_000, (v.dx - vel.dx) / dt))
            smoothedAcceleration += (acceleration - smoothedAcceleration) * min(1, dt * 20)
            // Paper is light: it trails the hand a little, it does not swing like a weight.
            pendulum.step(pivotAcceleration: smoothedAcceleration * 0.12, length: leverLength, dt: dt)
            vel = v
            pos = next
            smoothedSpeed += (Double(hypot(v.dx, v.dy)) - smoothedSpeed) * min(1, dt * 14)
            lift.step(to: 1, response: 0.28, damping: 0.8, dt: dt)
            tickCarry(dt)
        case .returning:
            let before = pos
            returnX.step(to: anchor.x, response: 0.46, damping: 0.82, dt: dt)
            returnY.step(to: anchor.y, response: 0.42, damping: 1, dt: dt)
            returnAngle.step(to: 0, response: 0.44, damping: 0.72, dt: dt)
            pos = CGPoint(x: returnX.value, y: max(anchor.y, returnY.value))
            vel = CGVector(dx: (pos.x - before.x) / dt, dy: (pos.y - before.y) / dt)
            lift.step(to: 0.25, response: 0.3, damping: 0.9, dt: dt)
            if returnX.isSettled(at: anchor.x, tolerance: 0.6, speed: 30), returnY.isSettled(at: anchor.y, tolerance: 0.6, speed: 30) {
                reattach()
            }
        case .falling:
            fallTime += dt
            // A loose sheet does not drop like a stone: it planes from side to side as it goes.
            let flutter = sin(fallTime * 7.5 + Double(seed % 7))
            vel.dy = min(900, vel.dy + 1500 * dt)
            vel.dy *= exp(-1.1 * dt)
            vel.dx = vel.dx * exp(-2.6 * dt) + flutter * 520 * dt
            pos.x += vel.dx * dt
            pos.y += vel.dy * dt
            fallSpin = fallSpin * exp(-1.4 * dt) + flutter * 1.5 * dt
            fallAngle += fallSpin * dt
            lift.step(to: 1.5, response: 0.3, damping: 1, dt: dt)
            if fallTime > 0.22 { node.opacity -= dt / 0.4 }
            if node.opacity <= 0.001 { finish(.torn) }
        case .fadingIn:
            node.opacity += dt / 0.32
            if node.opacity >= 0.999 {
                node.opacity = 1
                feedDidFinish()
            }
        case .fadingOut(let outcome):
            node.opacity -= dt / 0.24
            if node.opacity <= 0.001 { finish(outcome) }
        case .dragSession, .gone:
            break
        }
        guard phase != .gone else { return }
        tickShape(dt)
        tickStub(dt)
        glossShift.step(to: glossTarget, response: 0.5, damping: 1, dt: dt)
        apply()
    }

    /// The free end lags whatever the held part does, then catches up and settles.
    private func tickShape(_ dt: TimeInterval) {
        let angle = pose.angle
        let rawAngular = (angle - lastAngle) / dt
        lastAngle = angle
        angularVelocity += (rawAngular - angularVelocity) * min(1, dt * 25)
        let rect = node.paperRect
        var lagTargetBelow = 0.0, lagTargetAbove = 0.0, curlTarget = restCurl
        switch phase {
        case .freeHeld, .returning, .falling:
            let below = Double(rect.maxY - freePivot.y), above = Double(freePivot.y - rect.minY)
            // Air resists the moving sheet: both free ends trail behind the hand.
            let drag = -Double(vel.dx) * 0.03
            lagTargetBelow = Motion.softLimit(drag * below / 160 + angularVelocity * below * 0.05, limit: below * 0.3)
            lagTargetAbove = Motion.softLimit(drag * above / 160 - angularVelocity * above * 0.05, limit: above * 0.3)
            curlTarget = restCurl * 0.9 + min(10, abs(Double(vel.dy)) * 0.006)
            if phase == .falling { curlTarget = restCurl * 1.4 + 6 * sin(fallTime * 7.5) }
        case .tearing:
            let length = Double(rect.height)
            lagTargetBelow = Motion.softLimit(angularVelocity * length * 0.05 + angle * length * 0.16, limit: length * 0.2)
        case .dragSession, .gone, .fadingIn, .fadingOut:
            break
        default:
            let length = max(0, out)
            var target = angularVelocity * length * 0.07
            // Below the hand the paper hangs from the hand, not from the slot, so it straightens up.
            if let grab { target += angle * Double(max(0, h - grab.local.y)) * 0.55 }
            lagTargetBelow = Motion.softLimit(target, limit: length * 0.25)
        }
        lagBelow.step(to: lagTargetBelow * flex, response: 0.26, damping: 0.42, dt: dt)
        lagAbove.step(to: lagTargetAbove * flex, response: 0.26, damping: 0.42, dt: dt)
        curl.step(to: curlTarget, response: 0.42, damping: 0.4, dt: dt)
    }

    private func tickAttached(_ dt: TimeInterval) {
        if phase == .inserting, motor == nil {
            glide.step(to: 0, response: 0.42, damping: 1, dt: dt)
            fed = Double(h) + max(0, glide.value)
            if glide.value < 0.5 {
                insertPause += dt
                if insertPause > 0.09 {
                    fed = Double(h)
                    motor = Motor(program: FeedProgram(distance: Double(h), cadence: .insert, seed: seed), base: Double(h), direction: -1, goal: .insert)
                }
            }
        }
        if var m = motor {
            m.time += dt
            fed = m.base + m.direction * m.program.position(at: m.time)
            if let index = m.program.stepIndex(at: m.time), index != m.lastStep {
                m.lastStep = index
                let step = m.program.steps[index]
                host.sound.play(.feedStep(duration: step.duration, variant: index % 3))
                // Each burst flicks the free end off the surface a little.
                curl.velocity += m.goal == .feedOut ? 34 : 18
                sway.velocity += (Hash.unit(index, 3, seed) - 0.5) * 0.07
            }
            if m.program.isFinished(at: m.time) {
                motor = nil
                motorDidFinish(m.goal)
                if phase == .gone { return }
            } else {
                motor = m
            }
        }
        if grab == nil {
            pull.step(to: 0, response: 0.34, damping: 0.6, dt: dt)
            sway.step(to: 0, response: 0.7, damping: 0.34, dt: dt)
        }
        sag.step(to: sagTarget, response: 0.36, damping: 0.36, dt: dt)
        lift.step(to: phase == .inserting ? 0.3 : (grab != nil ? 0.3 : 0), response: 0.32, damping: 0.7, dt: dt)
        if let remaining = cutCountdown {
            if remaining - dt <= 0 {
                cutCountdown = nil
                cut()
            } else {
                cutCountdown = remaining - dt
            }
        }
        if isDeveloping {
            developed += dt * 150
            if developed > Double(SheetNode.developLength) + 14 {
                isDeveloping = false
                node.finishReveal()
            }
        }
    }

    private func motorDidFinish(_ goal: MotorGoal) {
        switch goal {
        case .feedOut: feedDidFinish()
        case .reposition: break
        case .retract: finish(.retracted)
        case .insert:
            host.sound.play(.thunk)
            finish(nil)
        }
    }

    private func feedDidFinish() {
        phase = .hanging
        idle = 0
        isDeveloping = node.isRevealing
        if paper.isTearable {
            // The motor lets go: the sheet settles under its own weight.
            sagTarget = 1.5
            sag.velocity += 55
            sway.velocity += (Hash.unit(1, 1, seed) - 0.5) * 0.3
        } else {
            cutCountdown = 0.1
        }
        handle?.emit(.finishedFeeding)
        prepareExport()
        host.sheetStateDidChange()
    }

    private func cut() {
        host.sound.play(.cutter)
        sagTarget = 2.5
        sag.velocity += 85
        sway.velocity += (Hash.unit(2, 1, seed) < 0.5 ? -1 : 1) * 0.22
        curl.velocity += 40
    }

    // MARK: Requests

    func requestRetract() {
        if phase == .tearing {
            tear?.finishesAlone = true
            return
        }
        guard phase == .hanging || phase == .feeding else { return }
        grab = nil
        cutCountdown = nil
        if host.reduceMotion {
            phase = .fadingOut(.retracted)
        } else {
            phase = .retracting
            sagTarget = 0
            motor = Motor(program: FeedProgram(distance: max(0, fed), cadence: .retract, seed: seed), base: fed, direction: -1, goal: .retract)
        }
        host.sheetStateDidChange()
    }

    func requestTearOff() {
        if phase == .tearing {
            tear?.finishesAlone = true
            return
        }
        guard phase == .hanging, motor == nil else { return }
        guard paper.isTearable else { return requestRetract() }
        grab = nil
        beginTear(side: Hash.unit(9, 9, seed) < 0.5 ? -1 : 1)
        tear?.finishesAlone = true
    }

    func cancel() {
        guard phase != .gone else { return }
        grab = nil
        motor = nil
        phase = .fadingOut(.cancelled)
        host.sheetStateDidChange()
    }

    func housekeeping(_ dt: TimeInterval) {
        if phase == .tearing, grab == nil {
            // A half-torn sheet left alone gives way under its own weight.
            idle += dt
            if idle >= 2.5 { tear?.finishesAlone = true; host.requestFrames() }
            return
        }
        guard phase == .hanging, motor == nil, grab == nil, !hovered else {
            idle = 0
            return
        }
        idle += dt
        var limit: TimeInterval?
        if case .after(let seconds) = job.autoRetract { limit = seconds }
        if let hurryLimit { limit = min(limit ?? hurryLimit, hurryLimit) }
        if let limit, idle >= limit { requestRetract() }
    }

    // MARK: Pointer

    func pointerHover(at point: CGPoint?) {
        guard paper != .thermal else { return }
        if let point {
            let local = pose.localPoint(point)
            glossTarget = Double((local.x / w - 0.5) * 0.55 + (local.y / h - 0.5) * 0.25)
        } else {
            glossTarget = 0
        }
    }

    func mouseDown(at point: CGPoint, time: TimeInterval) {
        cursor = point
        let current = pose
        let local = current.localPoint(point)
        switch phase {
        case .retracting:
            // Caught on the way in: push it back out.
            phase = .hanging
            motor = Motor(program: FeedProgram(distance: max(0, restOut - fed), cadence: .photo, seed: seed), base: fed, direction: 1, goal: .reposition)
            fallthrough
        case .feeding, .hanging:
            var lever = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
            let length = hypot(lever.dx, lever.dy)
            if length < 1 {
                lever = CGVector(dx: 0, dy: 70)
            } else if length < 70 {
                lever = CGVector(dx: lever.dx / length * 70, dy: lever.dy / length * 70)
            }
            grab = Grab(start: point, local: local, lever: lever, baseSway: sway.value, basePull: pull.value, lastTime: time)
        case .tearing:
            grab = Grab(start: point, local: local, lever: .zero, baseSway: 0, basePull: 0, lastTime: time)
            if var current = tear {
                current.origin = point
                current.base = current.progress
                tear = current
            }
            idle = 0
        case .returning, .falling:
            grab = Grab(start: point, local: local, lever: .zero, baseSway: 0, basePull: 0, lastTime: time)
            let angle = current.angle
            let omega = phase == .returning ? returnAngle.velocity : fallSpin
            node.opacity = 1
            enterFreeHeld(pivot: local, from: current)
            pendulum = Pendulum(angle: angle, omega: omega)
        default:
            return
        }
        grab?.samples = [(time, point)]
        host.sheetStateDidChange()
    }

    func mouseDragged(to point: CGPoint, time: TimeInterval) {
        guard var g = grab else { return }
        cursor = point
        g.samples.append((time, point))
        g.samples.removeAll { time - $0.time > 0.1 }
        let delta = CGVector(dx: point.x - g.start.x, dy: point.y - g.start.y)
        if hypot(delta.dx, delta.dy) > 3 { g.moved = true }
        let elapsed = max(0.001, time - g.lastTime)
        g.lastTime = time
        grab = g
        guard job.interaction.contains(.grab) else { return }

        if phase == .feeding || phase == .hanging {
            let c = CGVector(dx: g.lever.dx + delta.dx, dy: g.lever.dy + delta.dy)
            let rawAngle = atan2(g.lever.dx * c.dy - g.lever.dy * c.dx, g.lever.dx * c.dx + g.lever.dy * c.dy)
            let rawPull = hypot(c.dx, c.dy) - hypot(g.lever.dx, g.lever.dy)
            let held = phase == .feeding || motor != nil
            let newSway = g.baseSway + Motion.softLimit(rawAngle, limit: held ? 0.22 : 0.42)
            let pullLimit: Double = paper.isTearable ? 38 : 9
            let newPull = g.basePull + (rawPull > 0 ? Motion.softLimit(rawPull, limit: held ? 6 : pullLimit) : Motion.softLimit(rawPull, limit: 5))
            sway.velocity += ((newSway - sway.value) / elapsed - sway.velocity) * 0.5
            pull.velocity += ((newPull - pull.value) / elapsed - pull.velocity) * 0.5
            sway.value = newSway
            pull.value = newPull

            if !held, job.interaction.contains(.detach) {
                let speed = velocity(of: g)
                if paper.isTearable {
                    let ripped = (abs(delta.dx) > 34 && abs(speed.dx) > 500) || abs(delta.dx) > 110
                    if ripped || delta.dy > 95 || rawPull > 80 {
                        beginTear(side: delta.dx >= 0 ? 1 : -1)
                    }
                } else if rawPull > 26 || hypot(delta.dx, delta.dy) > 52 {
                    pullFree()
                }
            }
        }
        host.requestFrames()
    }

    func mouseUp(at point: CGPoint, time: TimeInterval) {
        guard let g = grab else { return }
        grab = nil
        cursor = point
        if !g.moved { handle?.emit(.tapped) }
        // Most of the way through, what is left cannot carry the sheet's weight.
        if phase == .tearing, let progress = tear?.progress, progress >= 0.5 { tear?.finishesAlone = true }
        if phase == .freeHeld {
            let v = velocity(of: g, now: time)
            if isTorn { beginFalling(velocity: v) } else { beginReturning(velocity: v) }
        }
        idle = 0
        host.sheetStateDidChange()
    }

    private func velocity(of grab: Grab, now: TimeInterval? = nil) -> CGVector {
        guard let first = grab.samples.first, let last = grab.samples.last else { return .zero }
        // A pause before letting go means the sheet is at rest, whatever the earlier samples say.
        if let now, now - last.time > 0.07 { return .zero }
        let dt = last.time - first.time
        guard dt > 0.004 else { return .zero }
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    private var leverLength: Double {
        let rect = node.paperRect
        return Double(hypot(rect.midX - freePivot.x, rect.midY - freePivot.y))
    }

    // MARK: Leaving the slot

    private func enterFreeHeld(pivot: CGPoint, from current: SheetPose) {
        let point = current.stagePoint(pivot)
        freePivot = pivot
        pos = point
        vel = .zero
        smoothedAcceleration = 0
        smoothedSpeed = 0
        carryDwell = 0
        followX = Spring(value: point.x - cursor.x)
        followY = Spring(value: point.y - cursor.y)
        pendulum = Pendulum(angle: current.angle, omega: angularVelocity)
        phase = .freeHeld
        host.place(node.root, clipped: false, atBack: false)
    }

    /// Cut paper slips out of the grip and comes away in the hand.
    private func pullFree() {
        guard let g = grab else { return }
        enterFreeHeld(pivot: g.local, from: pose)
        sway = Spring()
        pull = Spring()
        host.sound.play(.slip)
        host.haptic(.alignment)
        host.sheetStateDidChange()
    }

    private func beginReturning(velocity: CGVector) {
        let current = pose
        let top = CGPoint(x: w / 2, y: 0)
        let point = current.stagePoint(top)
        returnAngle = Spring(value: current.angle, velocity: pendulum.omega)
        // The hold moves from the hand to the top edge; carry the shape across so nothing jumps.
        lagBelow.value += lagAbove.value
        lagAbove = Spring()
        freePivot = top
        pos = point
        returnX = Spring(value: point.x, velocity: velocity.dx)
        returnY = Spring(value: point.y, velocity: velocity.dy)
        phase = .returning
    }

    /// Back under the slot: the rollers take the top edge again.
    private func reattach() {
        sway = Spring(value: returnAngle.value, velocity: returnAngle.velocity)
        pull = Spring()
        sag = Spring()
        sagTarget = 2.5
        fed = Double(h)
        idle = 0
        phase = .hanging
        host.place(node.root, clipped: true, atBack: false)
        let grip = FeedCadence(stepLength: 6, stepDuration: 0.06, dwell: 0.02)
        motor = Motor(program: FeedProgram(distance: Double(h) - restOut, cadence: grip, seed: seed), base: Double(h), direction: -1, goal: .reposition)
        host.haptic(.alignment)
        host.sheetStateDidChange()
    }

    private func beginFalling(velocity: CGVector, from current: SheetPose? = nil, spin: Double? = nil) {
        let current = current ?? pose
        let rect = node.paperRect
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // A thrown sheet keeps some of the throw, but air takes most of it at once.
        let limit = 620.0
        fallAngle = current.angle
        fallSpin = spin ?? (pendulum.omega + Double(velocity.dx) * 0.0012)
        pos = current.stagePoint(centre)
        lagBelow.value = (lagBelow.value + lagAbove.value) / 2
        lagAbove.value = lagBelow.value
        freePivot = centre
        vel = CGVector(dx: min(limit, max(-limit, velocity.dx * 0.45)), dy: min(limit, max(-limit, velocity.dy * 0.45)))
        fallTime = 0
        phase = host.reduceMotion ? .fadingOut(.torn) : .falling
        host.place(node.root, clipped: false, atBack: false)
    }

    // MARK: Tearing

    private func beginTear(side: Double) {
        let current = pose
        // The serrated bar sits just below the slot; what stays above it is the stub.
        let line = CGFloat(Double(h) - out) + Self.stubLength
        node.tear(at: line, seed: seed &+ 21)
        cutCountdown = nil
        var state = Tear(side: side, origin: cursor, angle: Spring(value: current.angle, velocity: angularVelocity), offsetX: Spring(), offsetY: Spring())
        tear = state
        phase = .tearing
        // Start exactly where the sheet is now and ease onto the tear line.
        let ideal = pose
        let actual = current.stagePoint(tearFrontLocal)
        state.offsetX = Spring(value: actual.x - ideal.pivotStage.x)
        state.offsetY = Spring(value: actual.y - ideal.pivotStage.y)
        tear = state
        stubAngle = current.angle
        makeStub()
        idle = 0
        host.sheetStateDidChange()
        if host.reduceMotion {
            tear?.progress = 1
            completeTear()
        }
    }

    private func tickTear(_ dt: TimeInterval) {
        guard var t = tear else { return }
        t.offsetX.step(to: 0, response: 0.14, damping: 1, dt: dt)
        t.offsetY.step(to: 0, response: 0.14, damping: 1, dt: dt)
        stubAngle *= exp(-dt / 0.05)
        let peel = -t.side
        if let g = grab, !t.finishesAlone {
            // The front follows the hand across the sheet; it never heals.
            // A fast rip carries through: the front runs ahead of the hand by its momentum.
            let speed = velocity(of: g)
            let momentum = max(0, Double(speed.dx) * t.side, Double(speed.dy) * 0.7) * 0.09
            let travel = max(Double(cursor.x - t.origin.x) * t.side, Double(cursor.y - t.origin.y) * 0.7) + momentum
            let wanted = min(1, max(0, t.base + (travel + 12) / Double(w * 0.82)))
            t.progress = max(t.progress, min(wanted, t.progress + dt * 13))
            tear = t
            let current = pose
            let a = CGVector(dx: g.local.x - current.pivotLocal.x, dy: g.local.y - current.pivotLocal.y)
            let b = CGVector(dx: cursor.x - current.pivotStage.x, dy: cursor.y - current.pivotStage.y)
            let raw = atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy)
            let opened = min(0.42, max(0.03 + 0.2 * t.progress, raw * peel))
            t.angle.step(to: opened * peel, response: 0.09, damping: 0.9, dt: dt)
        } else {
            if t.finishesAlone { t.progress = min(1, t.progress + dt * (1.6 + 7 * t.progress)) }
            t.angle.step(to: peel * (0.06 + 0.3 * t.progress), response: 0.34, damping: 0.5, dt: dt)
        }
        // Fibres let go in a run of small snaps as the front moves.
        let due = Int(t.progress * 9)
        while t.grains < due {
            t.grains += 1
            host.sound.playTearGrain(t.grains)
            if t.grains % 3 == 1 { host.haptic(.generic) }
        }
        tear = t
        lift.step(to: 0.35 + 0.4 * t.progress, response: 0.2, damping: 0.9, dt: dt)
        if t.progress >= 1 { completeTear() }
    }

    private func completeTear() {
        guard let t = tear else { return }
        let current = pose
        tear = nil
        isTorn = true
        stubAge = 0
        host.sound.playTearGrain(0)
        host.haptic(.levelChange)
        handle?.emit(.torn)
        if host.reduceMotion {
            phase = .fadingOut(.torn)
        } else if let g = grab {
            enterFreeHeld(pivot: g.local, from: current)
            pendulum.omega = -t.side * 2.2
        } else {
            beginFalling(velocity: CGVector(dx: t.side * 90, dy: 30), from: current, spin: -t.side * 1.4)
        }
        host.sheetStateDidChange()
    }

    private static let stubCanvas: CGFloat = 24

    /// The strip of roll paper left under the slot, with the other half of the serration.
    private func makeStub() {
        guard stub == nil, let tailImage = rendered.tail else { return }
        let depth = PaperRenderer.serrationDepth
        let height = Self.stubCanvas + depth
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: height)
        layer.contents = tailImage
        layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: min(1, height / max(height, node.tail)))
        layer.contentsGravity = .resize
        // Layer space is y-up with the serration at the bottom; teeth mesh with the sheet's.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: w, y: height))
        for tooth in PaperRenderer.serration(width: w, seed: seed &+ 21, irregularity: 0.5).reversed() {
            path.addLine(to: CGPoint(x: tooth.x, y: tooth.y))
        }
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.path = path
        layer.mask = mask
        layer.shadowColor = CGColor(gray: 0, alpha: 1)
        stub = layer
        host.place(layer, clipped: true, atBack: true)
    }

    private var stubRise: CGFloat {
        guard let age = stubAge else { return 0 }
        return (Self.stubLength + PaperRenderer.serrationDepth + 2) * CGFloat(Motion.smoothstep((age - 0.16) / 0.2))
    }

    private func tickStub(_ dt: TimeInterval) {
        guard stub != nil, let age = stubAge else { return }
        let next = age + dt
        if age < 0.16, next >= 0.16 { host.sound.play(.feedStep(duration: 0.12, variant: 1)) }
        stubAge = next
        if next > 0.42 { removeStub() }
    }

    private func removeStub() {
        stub?.removeFromSuperlayer()
        stub = nil
        stubAge = nil
        freeSlot()
    }

    // MARK: Drag-out

    /// A sheet becomes a file drag only when it is carried well away from the machine
    /// and then slowed down, as one does when aiming at a destination. A fling never qualifies.
    private func tickCarry(_ dt: TimeInterval) {
        guard grab != nil, job.interaction.contains(.dragOut) else { return }
        let home = CGPoint(x: anchor.x, y: anchor.y + h / 2)
        let radius = max(260, h * 0.75 + 150)
        let outside = hypot(cursor.x - home.x, cursor.y - home.y) > radius
        if outside, smoothedSpeed < 260 {
            carryDwell += dt
        } else {
            carryDwell = 0
        }
        if carryDwell >= 0.18 {
            carryDwell = 0
            if !host.beginDragSession(for: self) { carryDwell = -1 }
        }
    }

    /// The file handed to a drag session. Falls back to the sheet as printed if the
    /// job's own export is not ready yet.
    func exportFileURL() -> URL? {
        if let exportURL { return exportURL }
        guard let data = PaperRenderer.pngData(rendered.printed) else { return nil }
        exportURL = ExportStore.write(data, name: job.export?.filename, id: id)
        return exportURL
    }

    var dragImage: CGImage { rendered.printed }

    /// Rectangle of the upright sheet in stage coordinates, keeping the grabbed point under the pointer.
    var dragFrame: CGRect {
        CGRect(x: cursor.x - freePivot.x, y: cursor.y - freePivot.y, width: w, height: h)
    }

    func dragSessionDidBegin() {
        grab = nil
        phase = .dragSession
        node.opacity = 0
    }

    func dragSessionDidEnd(at point: CGPoint, delivered: Bool) {
        guard phase == .dragSession else { return }
        if delivered {
            let url = exportURL
            handle?.emit(.draggedOut(url))
            finish(.draggedOut(url))
            return
        }
        cursor = point
        pos = point
        pendulum = Pendulum()
        node.opacity = 1
        phase = .freeHeld
        if isTorn { beginFalling(velocity: .zero) } else { beginReturning(velocity: .zero) }
        host.requestFrames()
    }

    private func prepareExport() {
        guard let export = job.export, exportTask == nil, exportURL == nil else { return }
        let id = id
        exportTask = Task { [weak self] in
            guard let data = try? await export.data() else { return }
            guard let self, self.exportURL == nil else { return }
            self.exportURL = ExportStore.write(data, name: export.filename, id: id)
        }
    }

    // MARK: Ending

    private func freeSlot() {
        guard !slotFreed else { return }
        slotFreed = true
        host.slotDidFree(self)
    }

    private func finish(_ outcome: PrintOutcome?) {
        guard phase != .gone else { return }
        phase = .gone
        grab = nil
        motor = nil
        tear = nil
        node.root.removeFromSuperlayer()
        stub?.removeFromSuperlayer()
        stub = nil
        switch outcome {
        case .retracted: handle?.emit(.retracted)
        case .cancelled: handle?.emit(.cancelled)
        case .torn, .draggedOut, nil: break
        }
        if let outcome { handle?.finish(outcome) }
        insertCompletion?()
        insertCompletion = nil
        freeSlot()
        host.remove(self)
    }
}

/// Temporary files for sheets that are dragged out.
enum ExportStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Notchfax-Export", isDirectory: true)
    }

    static func write(_ data: Data, name: String?, id: UUID) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = (name?.isEmpty == false ? name : nil) ?? "Notchfax \(formatter.string(from: Date()))"
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(safe).appendingPathExtension("png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Removes exports left over from earlier runs.
    static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }
}
