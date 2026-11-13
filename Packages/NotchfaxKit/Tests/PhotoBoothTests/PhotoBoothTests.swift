import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os
import PrintKit
import Testing
@testable import PhotoBooth

// MARK: - Fixtures

/// A frame source that delivers one picture and records what is done to it.
private final class FakeSource: FrameSource, @unchecked Sendable {
    struct Log {
        var started = false
        var stopped = false
        var reposes = 0
        var onEvent: (@Sendable (FrameSourceEvent) -> Void)?
    }

    let isSimulated = true
    let picture: CIImage
    let log = OSAllocatedUnfairLock(uncheckedState: Log())

    init(picture: CIImage = solid(red: 0.8, green: 0.3, blue: 0.2, width: 640, height: 480)) {
        self.picture = picture
    }

    func start(onFrame: @escaping @Sendable (CIImage) -> Void, onEvent: @escaping @Sendable (FrameSourceEvent) -> Void) {
        log.withLockUnchecked {
            $0.started = true
            $0.onEvent = onEvent
        }
        onFrame(picture)
        onEvent(.started(name: "Fake"))
    }

    func stop() { log.withLockUnchecked { $0.stopped = true } }
    func repose() { log.withLockUnchecked { $0.reposes += 1 } }

    var stopped: Bool { log.withLockUnchecked { $0.stopped } }
    var reposes: Int { log.withLockUnchecked { $0.reposes } }
    func send(_ event: FrameSourceEvent) { log.withLockUnchecked { $0.onEvent }?(event) }
}

private func solid(red: CGFloat, green: CGFloat, blue: CGFloat, width: CGFloat, height: CGFloat) -> CIImage {
    CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

private func cgImage(_ image: CIImage) -> CGImage {
    CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
}

/// RGBA of one pixel, `y` counted from the top.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
    var data = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(
        data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Double(data[0]) / 255, Double(data[1]) / 255, Double(data[2]) / 255)
}

@MainActor
private func makeSession(
    _ source: FakeSource,
    script: BoothScript = BoothScript(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in await Task.yield() }
) -> BoothSession {
    let sink = PreviewSink()
    let pipeline = FramePipeline(aspect: BoothStrip.frameAspect, previewSize: CGSize(width: 200, height: 154), sink: sink)
    return BoothSession(source: source, pipeline: pipeline, sink: sink, script: script, sleep: sleep)
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Script

@Suite struct BoothScriptTests {
    @Test func fourShotsEachAfterThreeTwoOne() {
        let steps = BoothScript().steps
        let shutters = steps.compactMap { if case .shutter(let shot) = $0 { shot } else { nil } }
        #expect(shutters == [1, 2, 3, 4])
        for shot in 1...4 {
            let index = steps.firstIndex(of: .shutter(shot: shot))!
            #expect(Array(steps[(index - 3)..<index]) == [
                .count(shot: shot, value: 3), .count(shot: shot, value: 2), .count(shot: shot, value: 1),
            ])
        }
        #expect(steps.last == .finish)
    }

    @Test func aMomentToReposeBetweenShotsButNotAfterTheLast() {
        let steps = BoothScript().steps
        #expect(steps.filter { if case .repose = $0 { true } else { false } }.count == 3)
        #expect(!steps.contains(.repose(next: 5)))
    }

    @Test func aSittingIsBrief() {
        let duration = BoothScript().duration
        #expect(duration > .seconds(10))
        #expect(duration < .seconds(20))
    }
}

// MARK: - Session

@Suite @MainActor struct BoothSessionTests {
    @Test func aSittingTakesFourPicturesAndTurnsTheCameraOff() async throws {
        let source = FakeSource()
        let session = makeSession(source)
        var delivered: [CGImage] = []
        var events: [String] = []
        session.effects.tick = { events.append("tick") }
        session.effects.shutter = { events.append("shutter") }
        session.onFinish = { stills, _ in delivered = stills }

        session.open()
        await waitUntil { session.phase == .ready }
        #expect(session.phase == .ready)
        await session.perform()

        #expect(session.phase == .finished)
        #expect(delivered.count == 4)
        #expect(source.stopped)
        #expect(source.reposes == 3)
        #expect(events.filter { $0 == "tick" }.count == 12)
        #expect(events.filter { $0 == "shutter" }.count == 4)
        let still = try #require(delivered.first)
        #expect(abs(Double(still.width) / Double(still.height) - BoothStrip.frameAspect) < 0.01)
    }

    @Test func theCameraGoesOffAtTheLastShotNotWhenThePanelCloses() async {
        let source = FakeSource()
        let session = makeSession(source)
        var stoppedAtReview = false
        session.effects.shutter = { [weak session] in
            // When the fourth shutter fires the camera is still needed; right after, it is not.
            if session?.stills.count == 3 { stoppedAtReview = source.stopped }
        }
        session.open()
        await waitUntil { session.phase == .ready }
        let run = Task { await session.perform() }
        await waitUntil { session.phase == .review(shot: 4) || session.phase == .developing || session.phase == .finished }
        #expect(!stoppedAtReview)
        #expect(source.stopped)
        await run.value
    }

    @Test func cancellingStopsEverythingAndPrintsNothing() async {
        let source = FakeSource()
        let session = makeSession(source, script: BoothScript(tick: .seconds(5)), sleep: { try await Task.sleep(for: $0) })
        var finished = false
        session.onFinish = { _, _ in finished = true }
        session.open()
        await waitUntil { session.phase == .ready }
        session.begin()
        await waitUntil { if case .countdown = session.phase { true } else { false } }
        session.cancel()
        #expect(session.phase == .cancelled)
        #expect(source.stopped)
        #expect(!finished)
    }

    @Test func losingTheCameraEndsTheSitting() async {
        let source = FakeSource()
        let session = makeSession(source)
        var abandoned = false
        session.onAbandon = { abandoned = true }
        session.open()
        await waitUntil { session.phase == .ready }
        source.send(.lost)
        await waitUntil { if case .unavailable = session.phase { true } else { false } }
        #expect(session.phase == .unavailable("摄像头已断开"))
        #expect(source.stopped)
        await waitUntil({ abandoned }, timeout: .seconds(3))
        #expect(abandoned)
    }

    @Test func switchingCamerasKeepsGoingAndSaysSo() async {
        let source = FakeSource()
        let session = makeSession(source)
        session.open()
        await waitUntil { session.phase == .ready }
        source.send(.switched(name: "iPhone 相机"))
        await waitUntil { session.notice != nil }
        #expect(session.notice == "已切换到「iPhone 相机」")
        #expect(session.phase == .ready)
        #expect(!source.stopped)
    }
}

// MARK: - Pipeline

@Suite struct FramePipelineTests {
    @Test(arguments: [
        (CGSize(width: 1280, height: 720), CGFloat(4.0 / 3.0)),
        (CGSize(width: 720, height: 1280), CGFloat(4.0 / 3.0)),
        (CGSize(width: 1000, height: 1000), CGFloat(1.3)),
    ])
    func cropsAreCentredAndTheRightShape(size: CGSize, aspect: CGFloat) {
        let crop = FramePipeline.centredCrop(of: size, aspect: aspect)
        #expect(abs(crop.width / crop.height - aspect) < 0.01)
        #expect(crop.minX >= 0 && crop.maxX <= size.width && crop.minY >= 0 && crop.maxY <= size.height)
        #expect(abs(crop.midX - size.width / 2) <= 1 && abs(crop.midY - size.height / 2) <= 1)
    }

    @MainActor
    @Test func stillsAreMirroredLikeTheViewfinder() throws {
        // Left half red, right half blue.
        let red = solid(red: 1, green: 0, blue: 0, width: 400, height: 300)
        let blue = solid(red: 0, green: 0, blue: 1, width: 400, height: 300).transformed(by: CGAffineTransform(translationX: 400, y: 0))
        let pipeline = FramePipeline(aspect: 4.0 / 3.0, previewSize: CGSize(width: 100, height: 75), sink: PreviewSink())
        pipeline.receive(blue.composited(over: red))
        let still = try #require(pipeline.still())
        #expect(pixel(still, x: 20, y: still.height / 2).b > 0.8)
        #expect(pixel(still, x: still.width - 20, y: still.height / 2).r > 0.8)
    }
}

// MARK: - Looks

@Suite struct BoothLookTests {
    /// Grain must stay grain: no white sparks, no shift in overall brightness.
    @Test(arguments: BoothLook.allCases.filter(\.hasGrain))
    func grainIsFineAndUnbiased(look: BoothLook) {
        let grey = solid(red: 0.5, green: 0.5, blue: 0.5, width: 400, height: 300)
        func samples(_ picture: CIImage) -> [Double] {
            let image = cgImage(picture.cropped(to: grey.extent))
            var values: [Double] = []
            for y in stride(from: 120, to: 180, by: 3) {
                for x in stride(from: 170, to: 230, by: 3) { values.append(pixel(image, x: x, y: y).r) }
            }
            return values
        }
        let values = samples(look.apply(to: grey, grainSeed: 3))
        let spread = values.max()! - values.min()!
        #expect(spread < 0.12, "grain spread \(spread)")
        // The looks move mid-grey on purpose (the system's Instant effect lifts it to about 0.78),
        // so measure the grain against the same look without it, not against the input.
        let mean = values.reduce(0, +) / Double(values.count)
        let plain = samples(look.graded(grey))
        let plainMean = plain.reduce(0, +) / Double(plain.count)
        #expect(abs(mean - plainMean) < 0.02, "grain moved the mean from \(plainMean) to \(mean)")
    }

    @Test func blackAndWhiteHasNoColour() {
        let image = cgImage(BoothLook.mono.apply(to: solid(red: 0.9, green: 0.3, blue: 0.1, width: 200, height: 150)))
        let p = pixel(image, x: 100, y: 75)
        #expect(abs(p.r - p.g) < 0.02 && abs(p.g - p.b) < 0.02)
    }
}

// MARK: - Simulated camera

@Suite struct SimulatedSourceTests {
    @Test func itIsAliveAndChangesPoseBetweenShots() throws {
        let source = SimulatedFrameSource(size: CGSize(width: 320, height: 240))
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        source.start(onFrame: { _ in delivered.withLock { $0 += 1 } }, onEvent: { _ in })
        defer { source.stop() }
        // Poses are drawn in the background; give them a moment.
        let deadline = Date().addingTimeInterval(5)
        while delivered.withLock({ $0 }) < 5, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(delivered.withLock { $0 } >= 5)

        let now = ProcessInfo.processInfo.systemUptime
        let a = cgImage(try #require(source.frame(at: now)))
        let b = cgImage(try #require(source.frame(at: now + 1.3)))
        #expect(difference(a, b) > 0.002, "the picture moves on its own")

        Thread.sleep(forTimeInterval: 1.5)  // let the other poses finish drawing
        let before = cgImage(try #require(source.frame(at: ProcessInfo.processInfo.systemUptime)))
        source.repose()
        let after = cgImage(try #require(source.frame(at: ProcessInfo.processInfo.systemUptime + SimulatedFrameSource.poseTransition + 0.1)))
        #expect(difference(before, after) > 0.01, "a new pose after repose()")
    }

    @Test func stopIsImmediateAndFinal() {
        let source = SimulatedFrameSource(size: CGSize(width: 160, height: 120))
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        source.start(onFrame: { _ in delivered.withLock { $0 += 1 } }, onEvent: { _ in })
        let deadline = Date().addingTimeInterval(5)
        while delivered.withLock({ $0 }) < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        source.stop()
        #expect(!source.isRunning)
        Thread.sleep(forTimeInterval: 0.1)
        let count = delivered.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(delivered.withLock { $0 } == count)
    }

    /// Mean absolute difference of the two pictures, 0…1, on a coarse grid.
    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        var total = 0.0, count = 0
        for y in stride(from: 5, to: min(a.height, b.height), by: 23) {
            for x in stride(from: 5, to: min(a.width, b.width), by: 23) {
                let p = pixel(a, x: x, y: y), q = pixel(b, x: x, y: y)
                total += abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)
                count += 3
            }
        }
        return total / Double(max(1, count))
    }
}

// MARK: - Strip

@Suite @MainActor struct BoothStripTests {
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (0.1, 0.8, 0.2), (0.1, 0.2, 0.9), (0.95, 0.85, 0.1)]

    var stills: [CGImage] {
        colours.map { cgImage(solid(red: $0.0, green: $0.1, blue: $0.2, width: 1280, height: 985)) }
    }

    @Test func framesMatchThePaperGeometry() {
        #expect(BoothStrip.frameRects.count == 4)
        let content = BoothStrip.contentRect
        for rect in BoothStrip.frameRects {
            #expect(rect.width == content.width)
            #expect(rect.maxY <= content.height - Paper.stripFooterHeight + 0.01)
        }
    }

    @Test func developingKeepsEveryFrameAndMakesPrintSizedCopies() async {
        let developed = await BoothStrip.develop(stills, look: .mono)
        #expect(developed.frames.count == 4)
        #expect(developed.printFrames.count == 4)
        #expect(developed.printFrames.allSatisfy { max($0.width, $0.height) <= BoothStrip.printPixels })
        // Black and white really is.
        let p = pixel(developed.frames[0], x: 640, y: 492)
        #expect(abs(p.r - p.g) < 0.02 && abs(p.g - p.b) < 0.02)
    }

    @Test func exportIsHighResolutionWithFramesInOrder() async throws {
        let developed = await BoothStrip.develop(stills, look: .color)
        let export = StripExport(frames: developed.frames, caption: BoothStrip.renderCaption("2026.11.11 · 23:41", scale: 8), scale: 8)
        let png = try await export.png()
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == Int(BoothStrip.sheetSize.width * 8))
        #expect(image.height == Int(BoothStrip.sheetSize.height * 8))
        let content = BoothStrip.contentRect
        for (index, rect) in BoothStrip.frameRects.enumerated() {
            let centre = CGPoint(x: (content.minX + rect.midX) * 8, y: (content.minY + rect.midY) * 8)
            let p = pixel(image, x: Int(centre.x), y: Int(centre.y))
            // The look shifts colours a little; each frame must still be nearest its own colour.
            let distances = colours.map { c in
                pow(p.r - Double(c.0), 2) + pow(p.g - Double(c.1), 2) + pow(p.b - Double(c.2), 2)
            }
            #expect(distances.firstIndex(of: distances.min()!) == index, "frame \(index + 1)")
        }
        if let directory = ProcessInfo.processInfo.environment["NOTCHFAX_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("strip-export.png"))
        }
    }

    @Test func footerIsDated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9, minute: 5))!
        #expect(BoothStrip.caption(for: date, calendar: calendar) == "2026.11.11 · 09:05")
    }

    /// Writes strips in every look for a visual check: `NOTCHFAX_RENDER_DIR=… swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOTCHFAX_RENDER_DIR"] != nil))
    func renderStripsForInspection() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NOTCHFAX_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = SimulatedFrameSource(size: CGSize(width: 1280, height: 720))
        let sink = PreviewSink()
        let pipeline = FramePipeline(aspect: BoothStrip.frameAspect, previewSize: CGSize(width: 500, height: 385), sink: sink)
        source.start(onFrame: { pipeline.receive($0) }, onEvent: { _ in })
        _ = await pipeline.waitForFirstFrame(timeout: .seconds(5))
        try await Task.sleep(for: .seconds(2))
        var stills: [CGImage] = []
        for _ in 0..<4 {
            stills.append(try #require(pipeline.still()))
            source.repose()
            try await Task.sleep(for: .milliseconds(700))
        }
        source.stop()
        // A real picture, if one is given, says more about a look than the stand-in figure.
        if let path = ProcessInfo.processInfo.environment["NOTCHFAX_SAMPLE_IMAGE"],
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let sample = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let framed = FramePipeline.frame(CIImage(cgImage: sample), aspect: BoothStrip.frameAspect)
            let scale = min(1, 1280 / framed.extent.width)
            let sized = framed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let still = CIContext().createCGImage(sized, from: sized.extent.integral) {
                stills = Array(repeating: still, count: 4)
                // The same picture at viewfinder size, to compare with the print.
                let preview = sized.transformed(by: CGAffineTransform(scaleX: 504 / sized.extent.width, y: 504 / sized.extent.width))
                for look in BoothLook.allCases {
                    let looked = look.apply(to: preview.cropped(to: preview.extent.integral))
                    if let image = CIContext().createCGImage(looked, from: preview.extent.integral), let data = StripExport.pngData(image) {
                        try data.write(to: directory.appendingPathComponent("preview-\(look.rawValue).png"))
                    }
                }
            }
        }
        for look in BoothLook.allCases {
            let developed = await BoothStrip.develop(stills, look: look)
            let job = BoothStrip.job(developed, date: Date())
            let png = try #require(job.sheet.pngData(scale: 3))
            try png.write(to: directory.appendingPathComponent("strip-\(look.rawValue).png"))
        }
    }
}
