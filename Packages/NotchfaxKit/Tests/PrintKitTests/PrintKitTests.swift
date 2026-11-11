import CoreGraphics
import Foundation
import SwiftUI
import Testing

private typealias Spring = PrintKit.Spring

@testable import PrintKit

@Suite struct PrintQueueTests {
    @Test func `first job starts at once and the rest wait in order`() {
        var queue = PrintQueue<Int>()
        #expect(queue.enqueue(1) == 1)
        #expect(queue.enqueue(2) == nil)
        #expect(queue.enqueue(3) == nil)
        #expect(queue.active == 1)
        #expect(queue.pending == [2, 3])
        #expect(queue.finishActive() == 2)
        #expect(queue.finishActive() == 3)
        #expect(queue.finishActive() == nil)
        #expect(queue.isIdle)
    }

    @Test func `a waiting job asks the hanging sheet to hurry`() {
        var queue = PrintQueue<Int>()
        _ = queue.enqueue(1)
        #expect(!queue.shouldHurryActive)
        _ = queue.enqueue(2)
        #expect(queue.shouldHurryActive)
        _ = queue.finishActive()
        #expect(!queue.shouldHurryActive)
    }

    @Test func `cancelling distinguishes waiting, active and unknown jobs`() {
        var queue = PrintQueue<Int>()
        _ = queue.enqueue(1)
        _ = queue.enqueue(2)
        _ = queue.enqueue(3)
        #expect(queue.cancel(2) == .removedPending)
        #expect(queue.cancel(1) == .isActive)
        #expect(queue.cancel(9) == .unknown)
        #expect(queue.active == 1)
        #expect(queue.finishActive() == 3)
    }

    @Test func `the same job cannot be queued twice`() {
        var queue = PrintQueue<Int>()
        _ = queue.enqueue(1)
        #expect(queue.enqueue(1) == nil)
        _ = queue.enqueue(2)
        #expect(queue.enqueue(2) == nil)
        #expect(queue.pending == [2])
        #expect(queue.removeAllPending() == [2])
        #expect(queue.pending.isEmpty)
    }
}

@Suite struct PrintQueuePolicyTests {
    @Test func `ambient jobs wait behind ordinary ones and never hurry a sheet`() {
        var queue = PrintQueue<Int>()
        #expect(queue.enqueue(1) == 1)
        #expect(queue.enqueue(2, ambient: true) == nil)
        #expect(!queue.shouldHurryActive)
        #expect(queue.enqueue(3) == nil)
        #expect(queue.shouldHurryActive)
        #expect(queue.pending == [3, 2])
        #expect(queue.finishActive() == 3)
        #expect(!queue.shouldHurryActive)
        #expect(queue.finishActive() == 2)
        #expect(queue.cancel(2) == .isActive)
    }

    @Test func `a paused queue holds new jobs until it is resumed`() {
        var queue = PrintQueue<Int>()
        queue.pause()
        #expect(queue.enqueue(1) == nil)
        #expect(queue.enqueue(2, ambient: true) == nil)
        #expect(queue.active == nil && queue.pending == [1, 2])
        #expect(queue.resume() == 1)
        #expect(queue.resume() == nil)
    }

    @Test func `pausing leaves the sheet in the slot alone but stops the hand-off`() {
        var queue = PrintQueue<Int>()
        _ = queue.enqueue(1)
        _ = queue.enqueue(2)
        queue.pause()
        #expect(queue.active == 1)
        #expect(queue.finishActive() == nil)
        #expect(queue.active == nil && !queue.isIdle)
        #expect(queue.resume() == 2)
        #expect(queue.cancel(9) == .unknown)
    }
}

@Suite struct FeedProgramTests {
    @Test(arguments: [FeedCadence.photo, .text(), .retract, .insert])
    func `position runs monotonically from zero to the full distance`(cadence: FeedCadence) {
        let program = FeedProgram(distance: 233, cadence: cadence, seed: 4)
        #expect(program.position(at: -1) == 0)
        #expect(program.position(at: 0) == 0)
        var previous = 0.0
        var t = 0.0
        while t <= program.duration + 0.05 {
            let p = program.position(at: t)
            #expect(p >= previous - 1e-9)
            previous = p
            t += 0.002
        }
        #expect(abs(previous - 233) < 1e-6)
        #expect(program.isFinished(at: program.duration))
    }

    @Test func `paper advances in bursts with pauses between them`() throws {
        let cadence = FeedCadence(stepLength: 10, stepDuration: 0.05, dwell: 0.05)
        let program = FeedProgram(distance: 100, cadence: cadence)
        #expect(program.steps.count == 10)
        #expect(abs(program.duration - (10 * 0.05 + 9 * 0.05)) < 1e-9)
        // Mid-dwell after the first burst: exactly one step out, and not moving.
        #expect(abs(program.position(at: 0.075) - 10) < 1e-9)
        #expect(program.position(at: 0.09) == program.position(at: 0.075))
        // Mid-burst: strictly between two steps.
        let moving = program.position(at: 0.125)
        #expect(moving > 10 && moving < 20)
        #expect(program.stepIndex(at: 0.125) == 1)
    }

    @Test func `the last burst covers only what is left`() throws {
        let program = FeedProgram(distance: 25, cadence: FeedCadence(stepLength: 10, stepDuration: 0.05, dwell: 0.02))
        let last = try #require(program.steps.last)
        #expect(program.steps.count == 3)
        #expect(abs(last.to - last.from - 5) < 1e-9)
        #expect(last.duration < 0.05)
    }

    @Test func `variation changes the rhythm but not the distance, and is deterministic`() {
        let cadence = FeedCadence.text(lineHeight: 14)
        let a = FeedProgram(distance: 300, cadence: cadence, seed: 1)
        let b = FeedProgram(distance: 300, cadence: cadence, seed: 1)
        let c = FeedProgram(distance: 300, cadence: cadence, seed: 2)
        #expect(a == b)
        #expect(a.duration != c.duration)
        #expect(a.steps.count == c.steps.count)
        #expect(c.position(at: c.duration) == 300)
    }

    @Test func `an empty program is finished immediately`() {
        let program = FeedProgram(distance: 0, cadence: .photo)
        #expect(program.steps.isEmpty)
        #expect(program.duration == 0)
        #expect(program.position(at: 1) == 0)
        #expect(program.stepIndex(at: 1) == nil)
    }
}

@Suite struct SlotGeometryTests {
    let external = ScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true)
    let notched = ScreenDescriptor(
        frame: CGRect(x: 1920, y: 0, width: 1512, height: 982),
        safeAreaTop: 32,
        topLeftAuxWidth: 663.5,
        topRightAuxWidth: 663.5,
        isBuiltIn: true
    )

    @Test func `a display without a notch gets a drawn slot at top centre`() {
        let slot = SlotGeometry.make(for: external)
        #expect(slot.kind == .drawnSlot)
        #expect(slot.centerX == 960)
        #expect(slot.mouth.midX == 960)
        #expect(slot.mouth.minY == 0)
        #expect(slot.slotLineY > 0 && slot.slotLineY < slot.mouth.maxY)
        #expect(slot.maxPaperWidth < slot.mouth.width)
    }

    @Test func `a notched display puts the slot line at the bottom of the notch`() throws {
        let rect = try #require(notched.notchRect)
        #expect(rect == CGRect(x: 663.5, y: 0, width: 185, height: 32))
        let slot = SlotGeometry.make(for: notched, simulateNotch: true)
        #expect(slot.kind == .notch)
        #expect(slot.slotLineY == 32)
        #expect(slot.centerX == 756)
        #expect(slot.maxPaperWidth == 165)
    }

    @Test func `simulating a notch only affects displays without one`() {
        let slot = SlotGeometry.make(for: external, simulateNotch: true)
        #expect(slot.kind == .simulatedNotch)
        #expect(slot.mouth.size == SlotGeometry.simulatedNotchSize)
        #expect(slot.slotLineY == SlotGeometry.simulatedNotchSize.height)
    }

    @Test func `the notched display wins, then built-in, then main`() {
        let plainBuiltIn = ScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isBuiltIn: true)
        let other = ScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(SlotGeometry.preferredScreenIndex([external, notched]) == 1)
        #expect(SlotGeometry.preferredScreenIndex([external, plainBuiltIn]) == 1)
        #expect(SlotGeometry.preferredScreenIndex([other, external]) == 1)
        #expect(SlotGeometry.preferredScreenIndex([other]) == 0)
        #expect(SlotGeometry.preferredScreenIndex([]) == nil)
    }

    @Test func `wide sheets are scaled to fit through the slot`() {
        let slot = SlotGeometry.make(for: notched)
        #expect(slot.fittingScale(forPaperWidth: 120) == 1)
        #expect(abs(slot.fittingScale(forPaperWidth: 330) - 0.5) < 1e-9)
    }

    @Test func `a zero safe area or missing auxiliary areas means no notch`() {
        var screen = notched
        screen.safeAreaTop = 0
        #expect(screen.notchRect == nil)
        screen = notched
        screen.topRightAuxWidth = nil
        #expect(screen.notchRect == nil)
    }
}

@Suite struct MotionTests {
    @Test(arguments: [0.3, 0.6, 1.0])
    func `a spring settles on its target`(damping: Double) {
        var spring = Spring(value: 0, velocity: 0)
        for _ in 0..<600 { spring.step(to: 10, response: 0.4, damping: damping, dt: 1.0 / 120) }
        #expect(spring.isSettled(at: 10, tolerance: 0.01, speed: 0.1))
    }

    @Test func `a critically damped spring does not overshoot, an underdamped one does`() {
        var critical = Spring(), bouncy = Spring()
        var criticalPeak = 0.0, bouncyPeak = 0.0
        for _ in 0..<400 {
            critical.step(to: 1, response: 0.4, damping: 1, dt: 1.0 / 120)
            bouncy.step(to: 1, response: 0.4, damping: 0.4, dt: 1.0 / 120)
            criticalPeak = max(criticalPeak, critical.value)
            bouncyPeak = max(bouncyPeak, bouncy.value)
        }
        #expect(criticalPeak <= 1 + 1e-9)
        #expect(bouncyPeak > 1.05)
    }

    @Test func `stepping is independent of frame rate`() {
        var coarse = Spring(value: 0, velocity: 300), fine = Spring(value: 0, velocity: 300)
        for _ in 0..<30 { coarse.step(to: 50, response: 0.5, damping: 0.5, dt: 1.0 / 60) }
        for _ in 0..<120 { fine.step(to: 50, response: 0.5, damping: 0.5, dt: 1.0 / 240) }
        #expect(abs(coarse.value - fine.value) < 1e-6)
        #expect(abs(coarse.velocity - fine.velocity) < 1e-5)
    }

    @Test func `the analytic velocity matches the change in position`() {
        var spring = Spring(value: 0, velocity: 0)
        let dt = 1e-5
        spring.step(to: 1, response: 0.3, damping: 0.5, dt: 0.05)
        let before = spring
        spring.step(to: 1, response: 0.3, damping: 0.5, dt: dt)
        #expect(abs((spring.value - before.value) / dt - before.velocity) < 0.01)
    }

    @Test func `a soft limit tracks small input one to one and never exceeds the limit`() {
        #expect(abs(Motion.softLimit(0.01, limit: 10) - 0.01) < 1e-6)
        #expect(Motion.softLimit(1000, limit: 10) <= 10)
        #expect(Motion.softLimit(-1000, limit: 10) >= -10)
        #expect(Motion.softLimit(5, limit: 10) < 5)
    }

    @Test func `a pushed pendulum swings back and comes to rest hanging down`() {
        var pendulum = Pendulum()
        for _ in 0..<12 { pendulum.step(pivotAcceleration: 9000, length: 100, dt: 1.0 / 120) }
        #expect(pendulum.angle > 0.05)
        for _ in 0..<600 { pendulum.step(pivotAcceleration: 0, length: 100, dt: 1.0 / 120) }
        #expect(abs(pendulum.angle) < 0.002)
        #expect(abs(pendulum.omega) < 0.01)
    }
}

@Suite struct PaperLayoutTests {
    @Test(arguments: Paper.allCases)
    func `the content area sits inside the sheet`(paper: Paper) {
        let size = paper.defaultSize
        let rect = paper.contentRect(in: size)
        #expect(CGRect(origin: .zero, size: size).contains(rect))
        #expect(rect.width > size.width * 0.8)
    }

    @Test func `strip frames are four equal, non-overlapping boxes above the footer`() {
        let content = Paper.photoStrip.contentRect(in: Paper.photoStrip.defaultSize).size
        let rects = Paper.stripFrameRects(contentSize: content)
        #expect(rects.count == 4)
        for (a, b) in zip(rects, rects.dropFirst()) {
            #expect(a.height == b.height)
            #expect(abs(b.minY - a.maxY - Paper.stripFrameGap) < 1e-9)
        }
        #expect(abs((rects.last?.maxY ?? 0) - (content.height - Paper.stripFooterHeight)) < 1e-9)
    }

    @Test func `a pose maps its pivot onto the stage and round-trips other points`() {
        let pose = SheetPose(pivotLocal: CGPoint(x: 80, y: 0), pivotStage: CGPoint(x: 500, y: 32), angle: 0.3)
        let pivot = pose.stagePoint(CGPoint(x: 80, y: 0))
        #expect(abs(pivot.x - 500) < 1e-9 && abs(pivot.y - 32) < 1e-9)
        let local = CGPoint(x: 12, y: 140)
        let back = pose.localPoint(pose.stagePoint(local))
        #expect(abs(back.x - local.x) < 1e-9 && abs(back.y - local.y) < 1e-9)
        // Positive angles swing the hanging end towards −x.
        #expect(pose.stagePoint(CGPoint(x: 80, y: 100)).x < 500)
    }
}

@Suite struct SoundSynthTests {
    @Test(arguments: [
        SoundEffect.feedStep(duration: 0.05, variant: 0), .cutter, .tear, .shutter, .slip, .thunk, .tick,
    ])
    func `every effect is short, finite, within range and ends quietly`(effect: SoundEffect) {
        let samples = SoundSynth.samples(for: effect)
        #expect(!samples.isEmpty)
        #expect(Double(samples.count) / SoundSynth.sampleRate < 0.5)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(samples.contains { abs($0) > 0.02 })
        #expect(samples.suffix(20).allSatisfy { abs($0) < 0.08 })
    }
}

/// Sheets driven through the real controller by a scripted pointer, without any windows.
@MainActor
@Suite struct SheetInteractionTests {
    struct Result {
        var events: [PrintEvent] = []
        var requestedFileDrag = false
        var phase: SheetController.Phase = .gone
        var slotFreed = false
    }

    /// Prints `paper`, waits for it to hang, plays `gesture`, then keeps simulating for `after` seconds.
    func simulate(_ paper: Paper, gesture: String?, after: TimeInterval, reduceMotion: Bool = false) -> Result {
        let host = OffscreenHost(size: CGSize(width: 900, height: 700), reduceMotion: reduceMotion)
        let handle = PrintHandle()
        var events: [PrintEvent] = []
        handle.onEvent = { event, _ in events.append(event) }
        let job = PrintJob(PaperSheet(paper, size: CGSize(width: 160, height: 240)), autoRetract: .never)
        let rendered = PaperRenderer.render(job.sheet, size: job.sheet.resolvedSize(), scale: 1, seed: 3)
        let controller = SheetController(job: job, handle: handle, rendered: rendered, fit: 1, host: host, seed: 3)
        host.controllers.append(controller)
        controller.beginFeed()
        let dt = 1.0 / 120
        var guardTime = 0.0
        while guardTime < 10, controller.phase != .hanging || controller.needsFrames {
            controller.tick(dt)
            guardTime += dt
        }
        var run = gesture.flatMap { PointerScript.library[$0] }.map {
            PointerScript.Run(script: $0(controller.node.size.height), anchor: host.geometry.anchor)
        }
        var time = 0.0, housekeeping = 0.0
        while time < after {
            if run != nil, run?.advance(dt, on: controller) == true { run = nil }
            if controller.needsFrames { controller.tick(dt) }
            housekeeping += dt
            if housekeeping >= 0.25 {
                housekeeping = 0
                controller.housekeeping(0.25)
            }
            time += dt
        }
        return Result(events: events, requestedFileDrag: host.dragSessionRequested, phase: controller.phase, slotFreed: controller.slotFreed)
    }

    @Test func `a printed sheet feeds out and comes to rest hanging`() {
        let result = simulate(.thermal, gesture: nil, after: 0.5)
        #expect(result.events == [.startedFeeding, .finishedFeeding])
        #expect(result.phase == .hanging)
        #expect(!result.slotFreed)
    }

    @Test func `swinging a sheet neither removes it nor counts as a tap`() {
        let result = simulate(.photoStrip, gesture: "swing", after: 3)
        #expect(result.events == [.startedFeeding, .finishedFeeding])
        #expect(result.phase == .hanging)
    }

    @Test func `ripping thermal paper tears it, frees the slot and lets it fall away`() {
        let result = simulate(.thermal, gesture: "rip", after: 2.5)
        #expect(result.events == [.startedFeeding, .finishedFeeding, .torn])
        #expect(result.phase == .gone)
        #expect(result.slotFreed)
        #expect(!result.requestedFileDrag)
    }

    @Test func `a flung sheet never becomes a file drag`() {
        let result = simulate(.thermal, gesture: "fling", after: 2.5)
        #expect(result.events.contains(.torn))
        #expect(!result.requestedFileDrag)
        #expect(result.phase == .gone)
    }

    @Test func `a half-torn sheet hangs on, then gives way on its own`() {
        let early = simulate(.thermal, gesture: "half-tear", after: 1.6)
        #expect(early.phase == .tearing)
        #expect(!early.events.contains(.torn))
        let late = simulate(.thermal, gesture: "half-tear", after: 6)
        #expect(late.events.contains(.torn))
        #expect(late.phase == .gone)
    }

    @Test func `cut paper pulled free and let go returns to the slot`() {
        let result = simulate(.glossyPhoto, gesture: "carry", after: 3.5)
        #expect(result.events == [.startedFeeding, .finishedFeeding])
        #expect(result.phase == .hanging)
        #expect(!result.requestedFileDrag)
        #expect(!result.slotFreed)
    }

    @Test func `carrying a sheet far away and holding it still starts a file drag`() {
        let result = simulate(.glossyPhoto, gesture: "carry-out", after: 2)
        #expect(result.requestedFileDrag)
    }

    @Test func `with reduced motion a sheet fades in and a tear fades out`() {
        let shown = simulate(.thermal, gesture: nil, after: 0.2, reduceMotion: true)
        #expect(shown.events == [.startedFeeding, .finishedFeeding])
        let torn = simulate(.thermal, gesture: "rip", after: 1.5, reduceMotion: true)
        #expect(torn.events.contains(.torn))
        #expect(torn.phase == .gone)
    }

    /// A sheet, printed and hanging, with its controller and host.
    func hangingSheet(_ paper: Paper, interaction: PrintJob.Interaction = .all) -> (SheetController, OffscreenHost, () -> [PrintEvent]) {
        let host = OffscreenHost(size: CGSize(width: 900, height: 700), reduceMotion: false)
        let handle = PrintHandle()
        let log = EventLog()
        handle.onEvent = { event, _ in log.events.append(event) }
        let job = PrintJob(PaperSheet(paper, size: CGSize(width: 160, height: 240)), autoRetract: .never, interaction: interaction)
        let rendered = PaperRenderer.render(job.sheet, size: job.sheet.resolvedSize(), scale: 1, seed: 3)
        let controller = SheetController(job: job, handle: handle, rendered: rendered, fit: 1, host: host, seed: 3)
        host.controllers.append(controller)
        controller.beginFeed()
        settle(controller)
        // Keep the handle alive for as long as the caller reads events.
        return (controller, host, { _ = handle; _ = host; return log.events })
    }

    func settle(_ controller: SheetController, limit: TimeInterval = 10) {
        var time = 0.0
        while time < limit, controller.needsFrames {
            controller.tick(1.0 / 120)
            time += 1.0 / 120
        }
    }

    @Test func `a stowed sheet goes into the slot, keeps its place and comes back without new events`() {
        let (controller, _, events) = hangingSheet(.glossyPhoto)
        #expect(controller.slotState == .hanging)
        controller.stow()
        #expect(controller.slotState == .stowed)
        settle(controller)
        #expect(controller.phase == .stowed)
        #expect(controller.interactiveBounds == nil)
        #expect(!controller.slotFreed)
        controller.unstow()
        settle(controller)
        #expect(controller.phase == .hanging)
        #expect(events() == [.startedFeeding, .finishedFeeding])
    }

    @Test func `retracting or tearing a stowed sheet ends it where it is`() {
        let (first, _, firstEvents) = hangingSheet(.thermal)
        first.stow()
        settle(first)
        first.requestRetract()
        #expect(first.phase == .gone && first.slotFreed)
        #expect(firstEvents().last == .retracted)

        let (second, _, secondEvents) = hangingSheet(.thermal)
        second.stow()
        settle(second)
        second.requestTearOff()
        #expect(second.phase == .gone)
        #expect(secondEvents().last == .torn)
    }

    @Test func `a sheet that is already retracting is not stowed`() {
        let (controller, _, events) = hangingSheet(.glossyPhoto)
        controller.requestRetract()
        controller.stow()
        settle(controller)
        #expect(controller.phase == .gone)
        #expect(events().last == .retracted)
    }

    @Test func `a sheet with no interaction and no actions never takes the mouse`() {
        let (inert, host, _) = hangingSheet(.glossyPhoto, interaction: [])
        let middle = CGPoint(x: host.geometry.anchor.x, y: host.geometry.anchor.y + 100)
        #expect(inert.interactiveBounds == nil)
        #expect(!inert.hitTest(middle))
        let (live, liveHost, _) = hangingSheet(.glossyPhoto)
        _ = liveHost
        #expect(live.interactiveBounds != nil)
        #expect(live.hitTest(middle))
    }

    @Test func `a pointer script interpolates between its keys and holds at the ends`() {
        let script = PointerScript(keys: [.init(time: 1, x: 0, y: 0), .init(time: 2, x: 100, y: 50)], pressAt: 1, releaseAt: 2)
        #expect(script.point(at: 0) == .zero)
        #expect(script.point(at: 1.5) == CGPoint(x: 50, y: 25))
        #expect(script.point(at: 9) == CGPoint(x: 100, y: 50))
    }
}

@MainActor
@Suite struct PaperRenderingTests {
    /// A checkerboard of single dots, as an 8-bit grey image.
    func checkerboard(_ side: Int) -> CGImage {
        let pixels = (0..<side * side).map { UInt8((($0 % side) + ($0 / side)).isMultiple(of: 2) ? 0 : 255) }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test func `a pre-dithered bitmap prints dot for dot on thermal paper`() throws {
        let side = 64
        let insets = Paper.thermal.contentInsets
        let size = CGSize(width: Paper.thermal.defaultSize.width, height: CGFloat(side) / 2 + insets.top + insets.bottom)
        let sheet = PaperSheet(.thermal, size: size) {
            ThermalBitmap(checkerboard(side)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        let rendered = PaperRenderer.render(sheet, size: size, scale: PaperRenderer.scale(for: .thermal), seed: 9)
        #expect(rendered.scale == Paper.thermalDotsPerPoint)
        let bitmap = Bitmap(width: rendered.printed.width, height: rendered.printed.height)
        bitmap.context.draw(rendered.printed, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let originX = Int(insets.leading * 2), originY = Int(insets.top * 2)
        var wrong = 0
        for y in 0..<side {
            for x in 0..<side {
                let p = bitmap.pixels + (originY + y) * bitmap.rowBytes + (originX + x) * 4
                // Ink is uneven, as from a worn print head, but a dot is always clearly darker than bare paper.
                let isInk = p[1] < 226
                if isInk != (x + y).isMultiple(of: 2) { wrong += 1 }
            }
        }
        #expect(wrong == 0, "\(wrong) of \(side * side) dots did not land on their own pixel")
    }

    @Test func `the emulsion edge belongs to the picture, not to the whole content area`() {
        // A view that leaves its content area empty must leave the paper blank: no box around it.
        let size = Paper.glossyPhoto.defaultSize
        let blank = PaperRenderer.render(PaperSheet(.glossyPhoto, size: size), size: size, scale: 2, seed: 4)
        let empty = PaperRenderer.render(PaperSheet(.glossyPhoto, size: size) { Color.clear }, size: size, scale: 2, seed: 4)
        let a = Bitmap(width: blank.printed.width, height: blank.printed.height)
        a.context.draw(blank.printed, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        let b = Bitmap(width: empty.printed.width, height: empty.printed.height)
        b.context.draw(empty.printed, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
        var differing = 0
        for i in 0..<(a.width * a.height * 4) where a.pixels[i] != b.pixels[i] { differing += 1 }
        #expect(differing == 0)
    }

    @Test func `an export can be just a file name, or a main-actor closure`() async throws {
        #expect(PNGExport(filename: "传真 #A3F2").data == nil)
        let export = PNGExport(filename: "x", onMainActor: { Data([1, 2, 3]) })
        let provider = try #require(export.data)
        let data = try await provider()
        #expect(data == Data([1, 2, 3]))
    }
}

@MainActor
final class EventLog {
    var events: [PrintEvent] = []
}
