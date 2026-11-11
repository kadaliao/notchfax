import Foundation

/// A damped spring on one value, described the way a designer thinks about it:
/// `response` is roughly how long it takes to get there, `damping` is how much it
/// overshoots (1 = none). Stepping uses the closed-form solution, so it is stable
/// for any frame time and can be retargeted mid-flight without losing velocity.
public struct Spring: Sendable, Equatable {
    public var value: Double
    public var velocity: Double

    public init(value: Double = 0, velocity: Double = 0) {
        self.value = value
        self.velocity = velocity
    }

    public mutating func step(to target: Double, response: Double, damping: Double, dt: Double) {
        guard dt > 0, response > 0 else { return }
        let omega = 2 * Double.pi / response
        let zeta = max(0, damping)
        let x0 = value - target
        let v0 = velocity
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * dt)
            let c = cos(wd * dt), s = sin(wd * dt)
            let b = (v0 + zeta * omega * x0) / wd
            value = target + decay * (x0 * c + b * s)
            velocity = decay * (-zeta * omega * (x0 * c + b * s) + wd * (b * c - x0 * s))
        } else {
            let decay = exp(-omega * dt)
            let b = v0 + omega * x0
            value = target + decay * (x0 + b * dt)
            velocity = decay * (v0 - omega * b * dt)
        }
    }

    public func isSettled(at target: Double, tolerance: Double = 0.05, speed: Double = 1) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < speed
    }
}

/// A sheet held at one point swings like a heavily air-damped pendulum. Positive
/// angles swing the free end towards −x in a y-down coordinate space.
public struct Pendulum: Sendable, Equatable {
    public var angle: Double
    public var omega: Double

    public init(angle: Double = 0, omega: Double = 0) {
        self.angle = angle
        self.omega = omega
    }

    /// - Parameters:
    ///   - pivotAcceleration: horizontal acceleration of the held point, pt/s².
    ///   - length: distance from the held point to the sheet's centre of mass, pt.
    public mutating func step(
        pivotAcceleration: Double,
        length: Double,
        gravity: Double = 3200,
        drag: Double = 6.5,
        dt: Double
    ) {
        guard dt > 0 else { return }
        let l = max(30, length)
        let steps = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            let alpha = -(gravity / l) * sin(angle) - drag * omega + (pivotAcceleration / l) * cos(angle)
            omega += alpha * h
            angle += omega * h
        }
        let limit = 0.6
        if angle > limit { angle = limit; omega = min(omega, 0) }
        if angle < -limit { angle = -limit; omega = max(omega, 0) }
    }
}

public enum Motion {
    /// Follows the input 1:1 near zero and approaches `limit` asymptotically, so a
    /// boundary resists progressively instead of stopping hard.
    public static func softLimit(_ x: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return limit * tanh(x / limit)
    }

    /// Where a flick would come to rest, using scroll-style exponential decay.
    public static func project(velocity: Double, decelerationRate: Double = 0.998) -> Double {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    public static func smoothstep(_ u: Double) -> Double {
        let t = min(1, max(0, u))
        return t * t * (3 - 2 * t)
    }
}

/// Deterministic noise shared by the paper renderer, the feed cadence and the synth.
enum Hash {
    @inline(__always)
    static func unit(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = UInt64(truncatingIfNeeded: x) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(truncatingIfNeeded: y) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= seed &* 0x1656_67B1_9E37_79F9
        h ^= h >> 29
        h &*= 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        h &*= 0x94D0_49BB_1331_11EB
        h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53)
    }

    /// Smooth value noise in 0…1.
    static func smooth(_ x: Double, _ y: Double, _ seed: UInt64) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let fx = Motion.smoothstep(x - Double(xi)), fy = Motion.smoothstep(y - Double(yi))
        let a = unit(xi, yi, seed), b = unit(xi + 1, yi, seed)
        let c = unit(xi, yi + 1, seed), d = unit(xi + 1, yi + 1, seed)
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }
}
