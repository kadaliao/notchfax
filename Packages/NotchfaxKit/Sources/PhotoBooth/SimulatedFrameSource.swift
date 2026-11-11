import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import os
import PrintKit

/// A stand-in camera for Macs without one: PrintKit's procedural portrait, alive.
///
/// The figure breathes and sways a little, the light flickers the way a webcam's does,
/// there is faint sensor noise, and between shots the figure moves to a new pose (each
/// of `PrintSamples.portrait`'s variants), so a strip from the stand-in looks like a
/// strip: four different moments.
public final class SimulatedFrameSource: FrameSource, @unchecked Sendable {
    // @unchecked: all mutable state is behind `lock`; the timer is only touched under it.

    public let isSimulated = true
    public static let poseCount = 4

    private let size: CGSize
    private let fps: Double
    private let queue = DispatchQueue(label: "com.kadaliao.notchfax.simulated-camera", qos: .userInteractive)
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    private struct State {
        var timer: DispatchSourceTimer?
        var isRunning = false
        var poses: [Int: CIImage] = [:]
        var pose = 0
        var change: (from: Int, at: TimeInterval)?
        var startedAt: TimeInterval = 0
    }

    /// Seconds a change of pose takes.
    static let poseTransition: TimeInterval = 0.5

    public init(size: CGSize = CGSize(width: 960, height: 720), fps: Double = 30) {
        self.size = size
        self.fps = fps
    }

    public func start(onFrame: @escaping @Sendable (CIImage) -> Void, onEvent: @escaping @Sendable (FrameSourceEvent) -> Void) {
        lock.withLockUnchecked { $0.isRunning = true }
        queue.async { [self] in
            // The first pose is needed now; the others are drawn on the side.
            let first = pose(0)
            guard lock.withLockUnchecked({ state -> Bool in
                state.poses[0] = first
                state.startedAt = Self.now
                return state.isRunning
            }) else { return }
            DispatchQueue.global(qos: .utility).async { [self] in
                for index in 1..<Self.poseCount {
                    let image = pose(index)
                    lock.withLockUnchecked { $0.poses[index] = image }
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in
                guard let self, let frame = self.frame(at: Self.now) else { return }
                onFrame(frame)
            }
            let started = lock.withLockUnchecked { state -> Bool in
                guard state.isRunning else { return false }
                state.timer = timer
                return true
            }
            guard started else { return }
            timer.resume()
            onEvent(.started(name: "模拟摄像头"))
        }
    }

    public func stop() {
        let timer = lock.withLockUnchecked { state -> DispatchSourceTimer? in
            state.isRunning = false
            defer { state.timer = nil }
            return state.timer
        }
        timer?.cancel()
    }

    public func repose() {
        let now = Self.now
        lock.withLockUnchecked { state in
            state.change = (state.pose, now)
            state.pose = (state.pose + 1) % Self.poseCount
        }
    }

    var isRunning: Bool { lock.withLockUnchecked { $0.isRunning } }

    // MARK: Drawing

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func pose(_ index: Int) -> CIImage {
        CIImage(cgImage: PrintSamples.portrait(width: Int(size.width), height: Int(size.height), variant: index))
    }

    /// The picture at `time` (seconds of system uptime).
    func frame(at time: TimeInterval) -> CIImage? {
        let (poses, pose, change, startedAt) = lock.withLockUnchecked { ($0.poses, $0.pose, $0.change, $0.startedAt) }
        guard let base = poses[pose] ?? poses[0] else { return nil }
        let t = time - startedAt
        let bounds = CGRect(origin: .zero, size: size)

        var picture = base
        var shift = CGPoint.zero
        if let change, time - change.at < Self.poseTransition, let previous = poses[change.from] {
            let p = Self.easeOut(max(0, (time - change.at) / Self.poseTransition))
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = previous
            dissolve.targetImage = base
            dissolve.time = Float(p)
            picture = dissolve.outputImage ?? base
            // The figure settles into the new pose from a little to one side.
            let side: CGFloat = change.from.isMultiple(of: 2) ? -1 : 1
            shift = CGPoint(x: side * 26 * (1 - p), y: -8 * (1 - p))
        }

        // Breathing and the small sway of someone holding still.
        let w = size.width, h = size.height
        let breathe = 1.035 + 0.009 * sin(2 * .pi * t / 3.7)
        let dx = 5 * sin(2 * .pi * t / 5.3) + 1.6 * sin(2 * .pi * t / 2.3) + shift.x
        let dy = 3 * sin(2 * .pi * t / 3.7 + 0.8) + shift.y
        let tilt = 0.006 * sin(2 * .pi * t / 4.6)
        let transform = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(rotationAngle: tilt))
            .concatenating(CGAffineTransform(scaleX: breathe, y: breathe))
            .concatenating(CGAffineTransform(translationX: w / 2 + dx, y: h / 2 + dy))
        picture = picture.clampedToExtent().transformed(by: transform).cropped(to: bounds)

        // Auto-exposure hunting a little, and sensor noise.
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = picture
        exposure.ev = Float(0.05 * sin(2 * .pi * t / 2.9) + 0.025 * sin(2 * .pi * t * 1.7))
        picture = exposure.outputImage ?? picture
        if let noise = CIFilter.randomGenerator().outputImage {
            // Faint chroma noise around mid-grey, soft-light blended so it never brightens
            // or darkens the picture on average.
            let offset = CGFloat(Int(t * fps) % 997) * 13
            let grain = noise
                .transformed(by: CGAffineTransform(translationX: offset, y: -offset * 0.61))
                .settingAlphaOne(in: bounds)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.07, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.08, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0.465, y: 0.47, z: 0.46, w: 1),
                ])
                .cropped(to: bounds)
            let blend = CIFilter.softLightBlendMode()
            blend.inputImage = grain
            blend.backgroundImage = picture
            picture = blend.outputImage ?? picture
        }
        return picture.cropped(to: bounds)
    }

    private static func easeOut(_ x: Double) -> Double {
        1 - pow(1 - min(1, x), 3)
    }
}
