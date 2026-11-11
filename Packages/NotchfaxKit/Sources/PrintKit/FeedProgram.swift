import Foundation

/// How the stepper motor advances paper: a burst of `stepLength`, then a dwell.
public struct FeedCadence: Sendable, Equatable {
    /// Paper advanced per burst, in points.
    public var stepLength: Double
    /// Time one burst takes.
    public var stepDuration: TimeInterval
    /// Pause between bursts (the print head working on the next band).
    public var dwell: TimeInterval
    /// 0…1. How uneven the dwell is from one burst to the next.
    public var variation: Double

    public init(stepLength: Double, stepDuration: TimeInterval, dwell: TimeInterval, variation: Double = 0) {
        self.stepLength = max(0.5, stepLength)
        self.stepDuration = max(0.005, stepDuration)
        self.dwell = max(0, dwell)
        self.variation = min(1, max(0, variation))
    }

    /// Photo paper: confident, even bursts.
    public static let photo = FeedCadence(stepLength: 13, stepDuration: 0.062, dwell: 0.034, variation: 0.15)
    /// Text on thermal paper: one burst per printed line, slightly irregular.
    public static func text(lineHeight: Double = 14) -> FeedCadence {
        FeedCadence(stepLength: lineHeight, stepDuration: 0.05, dwell: 0.058, variation: 0.45)
    }
    /// Pulling a sheet back into the slot: quicker, nearly continuous.
    public static let retract = FeedCadence(stepLength: 24, stepDuration: 0.05, dwell: 0.008)
    /// Taking a sheet in from below (sending a fax).
    public static let insert = FeedCadence(stepLength: 18, stepDuration: 0.056, dwell: 0.022, variation: 0.2)
}

/// The position of the paper over time for one motor run. Pure and deterministic:
/// the same distance, cadence and seed always give the same curve.
public struct FeedProgram: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var start: TimeInterval
        public var duration: TimeInterval
        public var from: Double
        public var to: Double
    }

    public let distance: Double
    public let steps: [Step]
    public let duration: TimeInterval

    public init(distance: Double, cadence: FeedCadence, seed: UInt64 = 0) {
        let total = max(0, distance)
        var steps: [Step] = []
        var t: TimeInterval = 0
        var covered = 0.0
        var index = 0
        while total - covered > 0.01 {
            let length = min(cadence.stepLength, total - covered)
            // A short final burst should not take as long as a full one.
            let fraction = max(0.35, length / cadence.stepLength)
            let duration = cadence.stepDuration * fraction
            steps.append(Step(start: t, duration: duration, from: covered, to: covered + length))
            covered += length
            t += duration
            if total - covered > 0.01 {
                let jitter = (Hash.unit(index, 7, seed) - 0.5) * 2 * cadence.variation
                t += cadence.dwell * (1 + jitter)
            }
            index += 1
        }
        self.distance = total
        self.steps = steps
        self.duration = t
    }

    /// Index of the burst that is running, or has most recently run, at `time`.
    public func stepIndex(at time: TimeInterval) -> Int? {
        guard let first = steps.first, time >= first.start else { return nil }
        var low = 0, high = steps.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if steps[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Paper advanced at `time`, in 0…distance. Monotonic.
    public func position(at time: TimeInterval) -> Double {
        guard let index = stepIndex(at: time) else { return 0 }
        let step = steps[index]
        let u = (time - step.start) / step.duration
        return step.from + (step.to - step.from) * Motion.smoothstep(u)
    }

    public func isFinished(at time: TimeInterval) -> Bool { time >= duration }
}
