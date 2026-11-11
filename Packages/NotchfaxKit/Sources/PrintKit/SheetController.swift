import AppKit

/// Drives one sheet of paper from the moment it starts to feed until it is gone:
/// motor, hanging physics, grabbing, tearing, drag-out and retraction.
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
    private unowned let stage: Stage
    private let rendered: RenderedSheet
    private let seed: UInt64
    private let w: CGFloat
    private let h: CGFloat
    private let restOut: Double
    private let cadence: FeedCadence

    // Attached to the slot.
    private var fed = 0.0
    private var motor: Motor?
    private var pull = Spring()
    private var sag = Spring()
    private var sagTarget = 0.0
    private var sway = Spring()
    private var lift = Spring()
    private var cutCountdown: TimeInterval?
    private var developed = 0.0
    private var isDeveloping = false
    private var glide = Spring()
    private var insertPause: TimeInterval = 0
    private var insertCompletion: (() -> Void)?

    // In the hand or in the air.
    private var grab: Grab?
    private var cursor = CGPoint.zero
    private var freePivot = CGPoint.zero
    private var pos = CGPoint.zero
    private var vel = CGVector.zero
    private var followX = Spring(), followY = Spring()
    private var pendulum = Pendulum()
    private var smoothedAcceleration = 0.0
    private var returnX = Spring(), returnY = Spring(), returnAngle = Spring()
    private var fallAngle = 0.0, fallSpin = 0.0, fallTime: TimeInterval = 0
    private var tearPose = SheetPose(pivotLocal: .zero, pivotStage: .zero, angle: 0)
    private var tearStartAngle = 0.0, tearSide = 1.0, tearTime: TimeInterval = 0

    private var glossShift = Spring()
    private var glossTarget = 0.0
    private var idle: TimeInterval = 0
    private var exportURL: URL?
    private var exportTask: Task<Void, Never>?

    init(job: PrintJob, handle: PrintHandle?, rendered: RenderedSheet, fit: CGFloat, stage: Stage, seed: UInt64) {
        self.job = job
        self.handle = handle
        self.rendered = rendered
        self.stage = stage
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
    }

    private var paper: Paper { job.sheet.paper }
    private var out: Double { fed + pull.value + sag.value }
    private var anchor: CGPoint { stage.geometry.anchor }

    // MARK: Starting

    func beginFeed() {
        handle?.emit(.startedFeeding)
        stage.place(node, clipped: true)
        if stage.reduceMotion {
            phase = .fadingIn
            fed = restOut
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
        stage.place(node, clipped: true)
        node.finishReveal()
        if stage.reduceMotion {
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

    var pose: SheetPose {
        switch phase {
        case .tearing:
            return tearPose
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

    private func apply() {
        guard phase != .gone else { return }
        let pose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        node.setPose(pose, stageHeight: stage.geometry.screenSize.height)
        let attached = !isFree && phase != .tearing && !isTorn
        node.setSlotLine(attached ? CGFloat(Double(h) - out) : nil, developed: developed)
        node.setLift(lift.value)
        var gloss = 0.5 + pose.angle * 1.7 + glossShift.value
        if isFree { gloss += Double(pos.x - anchor.x) * 0.0016 + Double(pos.y - anchor.y) * 0.0009 }
        node.setGloss(phase: gloss)
        CATransaction.commit()
    }

    /// The visible paper outline in stage coordinates, for hit-testing and for placing the action bar.
    func hitTest(_ point: CGPoint) -> Bool {
        switch phase {
        case .gone, .dragSession, .fadingOut, .inserting: return false
        default: break
        }
        if !isFree, point.y < anchor.y { return false }
        return node.paperRect.insetBy(dx: -3, dy: -3).contains(pose.localPoint(point))
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
            if motor != nil || grab != nil || cutCountdown != nil || isDeveloping { return true }
            return !(pull.isSettled(at: 0) && sway.isSettled(at: 0, tolerance: 0.0006, speed: 0.004)
                && sag.isSettled(at: sagTarget) && lift.isSettled(at: 0, tolerance: 0.01, speed: 0.05)
                && glossShift.isSettled(at: glossTarget, tolerance: 0.002, speed: 0.01))
        default: return true
        }
    }

    func tick(_ dt: TimeInterval) {
        switch phase {
        case .feeding, .hanging, .retracting, .inserting:
            tickAttached(dt)
        case .tearing:
            tearTime += dt
            let u = min(1, tearTime / 0.13)
            tearPose.angle = tearStartAngle - tearSide * 0.19 * u * u
            lift.step(to: 0.6, response: 0.2, damping: 0.9, dt: dt)
            if u >= 1 { finishTear() }
        case .freeHeld:
            followX.step(to: 0, response: 0.17, damping: 0.86, dt: dt)
            followY.step(to: 0, response: 0.17, damping: 0.86, dt: dt)
            let next = CGPoint(x: cursor.x + followX.value, y: cursor.y + followY.value)
            let v = CGVector(dx: (next.x - pos.x) / dt, dy: (next.y - pos.y) / dt)
            let acceleration = min(40_000, max(-40_000, (v.dx - vel.dx) / dt))
            smoothedAcceleration += (acceleration - smoothedAcceleration) * min(1, dt * 20)
            // Paper is light: it trails the hand a little, it does not swing like a weight.
            pendulum.step(pivotAcceleration: smoothedAcceleration * 0.3, length: leverLength, dt: dt)
            vel = v
            pos = next
            lift.step(to: 1, response: 0.28, damping: 0.8, dt: dt)
        case .returning:
            returnX.step(to: anchor.x, response: 0.44, damping: 0.8, dt: dt)
            returnY.step(to: anchor.y, response: 0.4, damping: 1, dt: dt)
            returnAngle.step(to: 0, response: 0.42, damping: 0.7, dt: dt)
            pos = CGPoint(x: returnX.value, y: max(anchor.y, returnY.value))
            lift.step(to: 0.25, response: 0.3, damping: 0.9, dt: dt)
            if returnX.isSettled(at: anchor.x, tolerance: 0.6, speed: 30), returnY.isSettled(at: anchor.y, tolerance: 0.6, speed: 30) {
                reattach()
            }
        case .falling:
            fallTime += dt
            vel.dy = min(1500, vel.dy + 2500 * dt)
            vel.dx *= exp(-1.3 * dt)
            pos.x += vel.dx * dt
            pos.y += vel.dy * dt
            fallSpin *= exp(-0.9 * dt)
            fallAngle += fallSpin * dt
            lift.step(to: 1.4, response: 0.3, damping: 1, dt: dt)
            if fallTime > 0.08 { node.opacity -= dt / 0.36 }
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
        glossShift.step(to: glossTarget, response: 0.5, damping: 1, dt: dt)
        apply()
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
                stage.sound.play(.feedStep(duration: step.duration, variant: index % 3))
                // Each burst flutters the sheet off the surface a little.
                lift.velocity += m.goal == .feedOut ? 2.2 : 1.2
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
            sway.step(to: 0, response: 0.66, damping: 0.36, dt: dt)
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
            stage.sound.play(.thunk)
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
        stage.pointerDidMove()
    }

    private func cut() {
        stage.sound.play(.cutter)
        sagTarget = 2.5
        sag.velocity += 85
        sway.velocity += (Hash.unit(2, 1, seed) < 0.5 ? -1 : 1) * 0.22
        lift.velocity += 2
    }

    // MARK: Requests

    func requestRetract() {
        guard phase == .hanging || phase == .feeding else { return }
        grab = nil
        cutCountdown = nil
        if stage.reduceMotion {
            phase = .fadingOut(.retracted)
        } else {
            phase = .retracting
            sagTarget = 0
            motor = Motor(program: FeedProgram(distance: max(0, fed), cadence: .retract, seed: seed), base: fed, direction: -1, goal: .retract)
        }
        stage.sheetStateDidChange()
    }

    func requestTearOff() {
        guard phase == .hanging, motor == nil else { return }
        guard paper.isTearable else { return requestRetract() }
        grab = nil
        beginTear(side: Hash.unit(9, 9, seed) < 0.5 ? -1 : 1)
    }

    func cancel() {
        guard phase != .gone else { return }
        grab = nil
        motor = nil
        phase = .fadingOut(.cancelled)
        stage.sheetStateDidChange()
    }

    func housekeeping(_ dt: TimeInterval) {
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
        stage.sheetStateDidChange()
    }

    func mouseDragged(to point: CGPoint, time: TimeInterval, event: NSEvent) {
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

        switch phase {
        case .feeding, .hanging:
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

            guard !held, job.interaction.contains(.detach) else { break }
            let speed = velocity(of: g)
            if paper.isTearable {
                let ripped = (abs(delta.dx) > 40 && abs(speed.dx) > 600) || abs(delta.dx) > 120
                if ripped || delta.dy > 95 || rawPull > 80 {
                    beginTear(side: delta.dx >= 0 ? 1 : -1)
                }
            } else if rawPull > 26 || hypot(delta.dx, delta.dy) > 52 {
                pullFree()
            }
        case .freeHeld:
            guard job.interaction.contains(.dragOut) else { break }
            let home = CGPoint(x: anchor.x, y: anchor.y + h / 2)
            let radius = max(isTorn ? 250 : 190, h * 0.9)
            if hypot(point.x - home.x, point.y - home.y) > radius {
                stage.beginDragSession(for: self, event: event)
            }
        default:
            break
        }
        stage.requestFrames()
    }

    func mouseUp(at point: CGPoint, time: TimeInterval) {
        guard let g = grab else { return }
        grab = nil
        cursor = point
        if !g.moved { handle?.emit(.tapped) }
        if phase == .freeHeld {
            let v = velocity(of: g, now: time)
            if isTorn { beginFalling(velocity: v) } else { beginReturning(velocity: v) }
        }
        stage.sheetStateDidChange()
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
        followX = Spring(value: point.x - cursor.x)
        followY = Spring(value: point.y - cursor.y)
        pendulum = Pendulum(angle: current.angle, omega: sway.velocity)
        phase = .freeHeld
        stage.place(node, clipped: false)
    }

    /// Cut paper slips out of the grip and comes away in the hand.
    private func pullFree() {
        guard let g = grab else { return }
        enterFreeHeld(pivot: g.local, from: pose)
        sway = Spring()
        pull = Spring()
        stage.sound.play(.slip)
        Haptics.tap(.alignment)
        stage.sheetStateDidChange()
    }

    private func beginTear(side: Double) {
        let current = pose
        let line = CGFloat(Double(h) - out)
        node.tear(at: line, seed: seed &+ 21)
        let corner = CGPoint(x: side > 0 ? w : 0, y: node.tornTop ?? 0)
        // Peel from the near edge: the far corner is the last fibre to let go.
        tearPose = SheetPose(pivotLocal: corner, pivotStage: current.stagePoint(corner), angle: current.angle)
        tearStartAngle = current.angle
        tearSide = side
        tearTime = 0
        isTorn = true
        cutCountdown = nil
        phase = .tearing
        stage.sound.play(.tear)
        Haptics.tap(.levelChange)
        handle?.emit(.torn)
        freeSlot()
        stage.sheetStateDidChange()
        if stage.reduceMotion { phase = .fadingOut(.torn) }
    }

    private func finishTear() {
        let current = tearPose
        if let g = grab {
            enterFreeHeld(pivot: g.local, from: current)
            pendulum.omega = -tearSide * 3.2
        } else {
            beginFalling(velocity: CGVector(dx: tearSide * 110, dy: 40), from: current, spin: -tearSide * 1.8)
        }
    }

    private func beginFalling(velocity: CGVector, from current: SheetPose? = nil, spin: Double? = nil) {
        let current = current ?? pose
        let rect = node.paperRect
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let limit = 1800.0
        fallAngle = current.angle
        fallSpin = spin ?? (pendulum.omega + Double(velocity.dx) * 0.0016)
        pos = current.stagePoint(centre)
        freePivot = centre
        vel = CGVector(dx: min(limit, max(-limit, velocity.dx)), dy: min(limit, max(-limit, velocity.dy)))
        fallTime = 0
        phase = stage.reduceMotion ? .fadingOut(.torn) : .falling
        stage.place(node, clipped: false)
    }

    private func beginReturning(velocity: CGVector) {
        let current = pose
        let top = CGPoint(x: w / 2, y: 0)
        let point = current.stagePoint(top)
        returnAngle = Spring(value: current.angle, velocity: pendulum.omega)
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
        stage.place(node, clipped: true)
        let grip = FeedCadence(stepLength: 6, stepDuration: 0.06, dwell: 0.02)
        motor = Motor(program: FeedProgram(distance: Double(h) - restOut, cadence: grip, seed: seed), base: Double(h), direction: -1, goal: .reposition)
        Haptics.tap(.alignment)
        stage.sheetStateDidChange()
    }

    // MARK: Drag-out

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
        stage.requestFrames()
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
        stage.slotDidFree(self)
    }

    private func finish(_ outcome: PrintOutcome?) {
        guard phase != .gone else { return }
        phase = .gone
        grab = nil
        motor = nil
        node.root.removeFromSuperlayer()
        switch outcome {
        case .retracted: handle?.emit(.retracted)
        case .cancelled: handle?.emit(.cancelled)
        case .torn, .draggedOut, nil: break
        }
        if let outcome { handle?.finish(outcome) }
        insertCompletion?()
        insertCompletion = nil
        freeSlot()
        stage.remove(self)
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

@MainActor
enum Haptics {
    static func tap(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
