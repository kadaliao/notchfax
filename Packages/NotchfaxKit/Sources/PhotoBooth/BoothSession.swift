import CoreGraphics
import Foundation
import Observation
import PrintKit

/// The timing of one sitting: a breath before the first count, 3-2-1 before every
/// shot, a moment to change pose between shots, and a beat after the last one.
public struct BoothScript: Sendable, Equatable {
    public var shots: Int
    public var countFrom: Int
    public var lead: Duration
    public var tick: Duration
    /// After the flash: the shot stays on screen this long…
    public var review: Duration
    /// …then the live picture returns and the person has this long to change pose.
    public var repose: Duration
    /// After the last shot, before the viewfinder closes.
    public var hold: Duration

    public init(
        shots: Int = 4,
        countFrom: Int = 3,
        lead: Duration = .milliseconds(500),
        tick: Duration = .milliseconds(850),
        review: Duration = .milliseconds(650),
        repose: Duration = .milliseconds(1100),
        hold: Duration = .milliseconds(900)
    ) {
        self.shots = shots
        self.countFrom = countFrom
        self.lead = lead
        self.tick = tick
        self.review = review
        self.repose = repose
        self.hold = hold
    }

    public enum Step: Sendable, Equatable {
        case wait(Duration)
        /// Shows `value` for one tick. Shots are numbered from 1.
        case count(shot: Int, value: Int)
        case shutter(shot: Int)
        /// The picture just taken stays up.
        case review(shot: Int)
        /// Live again, time to strike the next pose.
        case repose(next: Int)
        case finish
    }

    public var steps: [Step] {
        var steps: [Step] = [.wait(lead)]
        for shot in 1...max(1, shots) {
            for value in stride(from: countFrom, through: 1, by: -1) {
                steps.append(.count(shot: shot, value: value))
            }
            steps.append(.shutter(shot: shot))
            steps.append(.review(shot: shot))
            if shot < shots { steps.append(.repose(next: shot + 1)) }
        }
        steps.append(.finish)
        return steps
    }

    /// Roughly how long a sitting takes.
    public var duration: Duration {
        steps.reduce(.zero) { total, step in
            switch step {
            case .wait(let d): total + d
            case .count: total + tick
            case .review: total + review
            case .repose: total + repose
            case .shutter, .finish: total
            }
        }
    }
}

/// One sitting in the booth: owns the frame source for its lifetime, runs the script,
/// and hands over the four pictures at the end.
@MainActor
@Observable
public final class BoothSession {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the first picture from the source.
        case starting
        /// Live picture; waiting for the person to press the button.
        case ready
        case countdown(shot: Int, value: Int)
        /// The shot just taken is on screen.
        case review(shot: Int)
        /// Live again before the next count.
        case repose(next: Int)
        /// All four taken; the camera is already off.
        case developing
        case finished
        case cancelled
        /// The camera could not be used or went away.
        case unavailable(String)

        public var isShooting: Bool {
            switch self {
            case .countdown, .review, .repose: true
            default: false
            }
        }

        /// The shot being worked on, 1…4, for the frame counter.
        public var shot: Int? {
            switch self {
            case .countdown(let shot, _), .review(let shot): shot
            case .repose(let next): next
            default: nil
            }
        }
    }

    /// What happens around the shots, outside the session: sounds and the flash.
    public struct Effects {
        public var tick: @MainActor () -> Void = {}
        public var shutter: @MainActor () -> Void = {}
        public var flash: @MainActor () -> Void = {}
        public init() {}
    }

    public private(set) var phase: Phase = .starting
    /// The pictures taken so far: mirrored, cropped, no look applied.
    public private(set) var stills: [CGImage] = []
    /// Small, with the look, for the counter under the viewfinder.
    public private(set) var thumbnails: [CGImage] = []
    public var look: BoothLook {
        didSet { pipeline.look = look }
    }
    public private(set) var deviceName: String?
    /// A passing remark ("已切换到 iPhone 相机").
    public private(set) var notice: String?
    /// Bumped at every shutter; the viewfinder flashes when it changes.
    public private(set) var flashCount = 0
    public let isSimulated: Bool
    public let script: BoothScript

    @ObservationIgnored let pipeline: FramePipeline
    @ObservationIgnored let sink: PreviewSink
    @ObservationIgnored public var effects = Effects()
    /// All four pictures are in.
    @ObservationIgnored public var onFinish: (@MainActor ([CGImage], BoothLook) -> Void)?
    /// The session ended without pictures (camera lost); the viewfinder should close.
    @ObservationIgnored public var onAbandon: (@MainActor () -> Void)?

    @ObservationIgnored private let source: any FrameSource
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var sourceStopped = false

    public init(
        source: any FrameSource,
        pipeline: FramePipeline,
        sink: PreviewSink,
        look: BoothLook = .standard,
        script: BoothScript = BoothScript(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.source = source
        self.pipeline = pipeline
        self.sink = sink
        self.look = look
        self.script = script
        self.sleep = sleep
        isSimulated = source.isSimulated
        pipeline.look = look
    }

    // MARK: Lifecycle

    /// Starts the picture. Call once, when the viewfinder appears.
    public func open() {
        let pipeline = pipeline
        source.start(
            onFrame: { pipeline.receive($0) },
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        )
        // A camera that never delivers is as good as none.
        Task { [weak self, pipeline] in
            let ok = await pipeline.waitForFirstFrame(timeout: .seconds(6))
            guard let self, self.phase == .starting else { return }
            if ok { self.phase = .ready } else { self.abandon("摄像头没有画面") }
        }
    }

    /// Starts the countdown for the first shot.
    public func begin() {
        guard phase == .ready, run == nil else { return }
        run = Task { [weak self] in await self?.perform() }
    }

    /// Ends the sitting at once: the camera turns off, nothing is printed.
    public func cancel() {
        guard phase != .finished, phase != .cancelled else { return }
        run?.cancel()
        run = nil
        stopSource()
        if case .unavailable = phase {} else { phase = .cancelled }
    }

    /// Runs the script to the end. Exposed for tests; the viewfinder calls `begin()`.
    func perform() async {
        for step in script.steps {
            guard !Task.isCancelled, phase != .cancelled else { return }
            switch step {
            case .wait(let duration):
                guard await pause(duration) else { return }
            case .count(let shot, let value):
                phase = .countdown(shot: shot, value: value)
                effects.tick()
                guard await pause(script.tick) else { return }
            case .shutter(let shot):
                guard await shoot(shot) else { return }
            case .review(let shot):
                phase = .review(shot: shot)
                if shot == script.shots {
                    // That was the last one: the camera goes off now, not when the panel closes.
                    stopSource()
                }
                guard await pause(script.review) else { return }
            case .repose(let next):
                sink.isFrozen = false
                source.repose()
                phase = .repose(next: next)
                guard await pause(script.repose) else { return }
            case .finish:
                stopSource()
                phase = .developing
                guard await pause(script.hold) else { return }
                phase = .finished
                onFinish?(stills, look)
            }
        }
    }

    private func shoot(_ shot: Int) async -> Bool {
        effects.shutter()
        effects.flash()
        flashCount += 1
        // Like Photo Booth, the picture is taken while the screen is lit by the flash.
        guard await pause(.milliseconds(70)) else { return false }
        let pipeline = pipeline
        guard let still = await Self.capture(pipeline) else {
            abandon("没能拍下这一张")
            return false
        }
        guard phase != .cancelled else { return false }
        sink.isFrozen = true
        stills.append(still)
        if let shown = sink.current {
            thumbnails.append(shown)
        }
        return true
    }

    @concurrent
    private static func capture(_ pipeline: FramePipeline) async -> CGImage? {
        pipeline.still()
    }

    private func pause(_ duration: Duration) async -> Bool {
        do {
            try await sleep(duration)
        } catch {
            return false
        }
        return !Task.isCancelled && phase != .cancelled
    }

    private func stopSource() {
        guard !sourceStopped else { return }
        sourceStopped = true
        source.stop()
    }

    // MARK: Source events

    func handle(_ event: FrameSourceEvent) {
        switch event {
        case .started(let name):
            deviceName = name
        case .switched(let name):
            deviceName = name
            show(notice: "已切换到「\(name)」")
        case .lost:
            abandon("摄像头已断开")
        case .failed(let message):
            abandon(message)
        }
    }

    private func abandon(_ message: String) {
        guard phase != .finished, phase != .cancelled, phase != .developing else { return }
        run?.cancel()
        run = nil
        stopSource()
        phase = .unavailable(message)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1800))
            self?.onAbandon?()
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2600))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
