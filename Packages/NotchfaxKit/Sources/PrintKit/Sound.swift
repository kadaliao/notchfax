import AVFoundation

/// The machine's sounds, synthesised from noise and a few oscillators. No audio files.
public enum SoundEffect: Hashable, Sendable {
    /// One burst of the paper-feed stepper motor.
    case feedStep(duration: TimeInterval, variant: Int = 0)
    /// The blade that cuts photo paper.
    case cutter
    /// Thermal paper tearing along the serrated edge.
    case tear
    /// A camera shutter.
    case shutter
    /// Paper slipping out of the rollers.
    case slip
    /// A sheet fully swallowed by the slot.
    case thunk
    /// A soft tick, for countdowns.
    case tick
}

/// Pure sample generation. Mono, 44.1 kHz, peak roughly ±0.6.
public enum SoundSynth {
    public static let sampleRate = 44_100.0

    public static func samples(for effect: SoundEffect) -> [Float] {
        switch effect {
        case .feedStep(let duration, let variant): feedStep(duration: duration, variant: variant)
        case .cutter: cutter()
        case .tear: tear()
        case .shutter: shutter()
        case .slip: slip()
        case .thunk: thunk()
        case .tick: tick()
        }
    }

    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 30) - 1
        }
    }

    private struct OnePole {
        var y = 0.0
        mutating func low(_ x: Double, cutoff: Double) -> Double {
            let a = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
            y += a * (x - y)
            return y
        }
    }

    private static func count(_ seconds: Double) -> Int { max(1, Int(seconds * sampleRate)) }

    /// A stepper burst: a soft buzz that spins up and down, paper hiss under it, a tick as it engages.
    static func feedStep(duration: TimeInterval, variant: Int) -> [Float] {
        let d = min(0.25, max(0.02, duration))
        let n = count(d + 0.035)
        var noise = Noise(state: 0x5EED &+ UInt64(variant) &* 977)
        var lowA = OnePole(), lowB = OnePole(), body = OnePole()
        let base = 410.0 * [1.0, 1.045, 0.965][abs(variant) % 3]
        var phase = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let u = min(1, t / d)
            // Spin up over the first third, coast, spin down.
            let speed = 0.55 + 0.45 * Motion.smoothstep(u / 0.3) - 0.3 * Motion.smoothstep((u - 0.7) / 0.3)
            phase += 2 * Double.pi * base * speed / sampleRate
            let envelope = Motion.smoothstep(t / 0.006) * (1 - Motion.smoothstep((t - d) / 0.03))
            let buzz = sin(phase) * 0.5 + sin(phase * 2 + 0.4) * 0.22 + sin(phase * 3 + 1.1) * 0.1 + sin(phase * 0.5) * 0.16
            let w = noise.next()
            let hiss = lowA.low(w, cutoff: 3200) - lowB.low(w, cutoff: 700)
            let engage = t < 0.004 ? w * (1 - t / 0.004) * 0.5 : 0
            let mixed = buzz * 0.34 * envelope + hiss * 0.42 * envelope + engage
            out[i] = Float(body.low(mixed, cutoff: 2600) * 0.9)
        }
        return out
    }

    /// A blade sliding across, then stopping against its end.
    static func cutter() -> [Float] {
        let n = count(0.17)
        var noise = Noise(state: 0xC077)
        var lowA = OnePole(), lowB = OnePole()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w = noise.next()
            var s = 0.0
            if t < 0.075 {
                let u = t / 0.075
                let centre = 1400 + 3200 * u
                let band = lowA.low(w, cutoff: centre * 1.5) - lowB.low(w, cutoff: centre * 0.6)
                s += band * 0.5 * Motion.smoothstep(u / 0.2) * (0.5 + 0.5 * u)
            }
            if t >= 0.075 {
                let c = t - 0.075
                s += w * exp(-c / 0.004) * 0.55
                s += sin(2 * Double.pi * 150 * c) * exp(-c / 0.03) * 0.5
                s += sin(2 * Double.pi * 1900 * c) * exp(-c / 0.008) * 0.12
            }
            out[i] = Float(s * 0.8)
        }
        return out
    }

    /// Dry, crackling noise that starts hard and thins out as the last fibres go.
    static func tear() -> [Float] {
        let n = count(0.26)
        var noise = Noise(state: 0x7EA2)
        var grainSource = Noise(state: 0x9A11)
        var low = OnePole(), high = OnePole()
        var grain = 0.0
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let envelope = Motion.smoothstep(t / 0.004) * exp(-t / 0.075)
            let density = 2600 * exp(-t / 0.11) + 200
            if (grainSource.next() + 1) / 2 < density / sampleRate { grain = 1 }
            grain *= exp(-1 / (0.0007 * sampleRate))
            let w = noise.next()
            let bright = low.low(w, cutoff: 9000 - 4500 * min(1, t / 0.2))
            let crisp = bright - high.low(bright, cutoff: 1400)
            out[i] = Float(crisp * envelope * (0.3 + 0.9 * grain) * 0.95)
        }
        return out
    }

    /// Two mechanical clicks: the curtain opening and closing.
    static func shutter() -> [Float] {
        let n = count(0.2)
        var noise = Noise(state: 0x5A77)
        var low = OnePole(), high = OnePole()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let w = noise.next()
            let band = low.low(w, cutoff: 5200) - high.low(w, cutoff: 900)
            var s = band * exp(-t / 0.0035) * 0.9
            s += sin(2 * Double.pi * 210 * t) * exp(-t / 0.016) * 0.5
            if t >= 0.062 {
                let c = t - 0.062
                s += band * exp(-c / 0.005) * 0.6
                s += sin(2 * Double.pi * 160 * c) * exp(-c / 0.022) * 0.4
                s += sin(2 * Double.pi * 980 * c) * exp(-c / 0.03) * 0.07
            }
            out[i] = Float(s * 0.8)
        }
        return out
    }

    static func slip() -> [Float] {
        let n = count(0.1)
        var noise = Noise(state: 0x511B)
        var low = OnePole(), high = OnePole()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let u = t / 0.1
            let w = noise.next()
            let band = low.low(w, cutoff: 2400 + 2000 * u) - high.low(w, cutoff: 500)
            out[i] = Float(band * sin(.pi * u) * sin(.pi * u) * 0.5)
        }
        return out
    }

    static func thunk() -> [Float] {
        let n = count(0.16)
        var noise = Noise(state: 0x7B0C)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let s = sin(2 * Double.pi * (120 - 180 * t) * t) * exp(-t / 0.04) * 0.6 + noise.next() * exp(-t / 0.003) * 0.25
            out[i] = Float(s)
        }
        return out
    }

    static func tick() -> [Float] {
        let n = count(0.06)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            out[i] = Float(sin(2 * Double.pi * 1320 * t) * exp(-t / 0.012) * 0.4 * Motion.smoothstep(t / 0.001))
        }
        return out
    }
}

/// Plays `SoundEffect`s through a small pool of player nodes. The engine starts on
/// first use and shuts itself down again after a few idle seconds.
@MainActor
public final class SoundPlayer {
    public var isMuted = false
    /// 0…1. The machine is meant to be heard, not noticed.
    public var volume: Float = 0.32

    private var engine: AVAudioEngine?
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var lastPlay = Date.distantPast
    private var idleCheck: Task<Void, Never>?
    private var isDisabled = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.sampleRate, channels: 1)

    public init() {}

    public func play(_ effect: SoundEffect) {
        guard !isMuted, !isDisabled, let format else { return }
        let key = Self.cacheKey(effect)
        let buffer: AVAudioPCMBuffer
        if let cached = buffers[key] {
            buffer = cached
        } else {
            let samples = SoundSynth.samples(for: key)
            guard let made = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = made.floatChannelData?[0] else { return }
            made.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
            buffers[key] = made
            buffer = made
        }
        guard startEngineIfNeeded(format: format) else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        lastPlay = Date()
        scheduleIdleCheck()
    }

    /// Step durations are quantised so a long print reuses a handful of buffers.
    private static func cacheKey(_ effect: SoundEffect) -> SoundEffect {
        if case .feedStep(let duration, let variant) = effect {
            return .feedStep(duration: (duration * 100).rounded() / 100, variant: abs(variant) % 3)
        }
        return effect
    }

    private func startEngineIfNeeded(format: AVAudioFormat) -> Bool {
        if let engine, engine.isRunning { return true }
        let engine = self.engine ?? {
            let engine = AVAudioEngine()
            players = (0..<6).map { _ in
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                return node
            }
            self.engine = engine
            return engine
        }()
        do {
            try engine.start()
            return true
        } catch {
            isDisabled = true
            return false
        }
    }

    private func scheduleIdleCheck() {
        guard idleCheck == nil else { return }
        idleCheck = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPlay) > 3.5 {
                    self.players.forEach { $0.stop() }
                    self.engine?.stop()
                    self.idleCheck = nil
                    return
                }
            }
        }
    }
}
