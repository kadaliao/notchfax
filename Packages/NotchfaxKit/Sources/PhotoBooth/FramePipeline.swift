import AppKit
import CoreImage
import os
import QuartzCore

/// Turns raw frames into what the viewfinder shows and what the strip keeps.
///
/// Every frame is mirrored (people expect to see themselves as in a mirror, and the
/// print keeps what they saw), cropped to the shape of a strip frame, so what is
/// framed is exactly what prints, and given the current look for the preview.
/// Rendering happens on the source's queue; only the finished bitmap goes to the main
/// thread, and a new one is not rendered until the last one has been shown.
public final class FramePipeline: Sendable {
    /// Width / height of a frame on the strip.
    public let aspect: CGFloat
    /// Pixel size of the viewfinder image.
    public let previewSize: CGSize

    private let context = CIContext(options: [.cacheIntermediates: false, .name: "PhotoBooth"])
    private let sink: PreviewSink
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var latest: CIImage?
        var look: BoothLook = .standard
        var displayPending = false
        var frameCount = 0
    }

    public init(aspect: CGFloat, previewSize: CGSize, sink: PreviewSink) {
        self.aspect = aspect
        self.previewSize = previewSize
        self.sink = sink
    }

    public var look: BoothLook {
        get { state.withLock { $0.look } }
        set { state.withLock { $0.look = newValue } }
    }

    public var frameCount: Int { state.withLock { $0.frameCount } }

    /// Called by the source for every frame, on its queue.
    public func receive(_ frame: CIImage) {
        let (render, look, count) = state.withLock { state -> (Bool, BoothLook, Int) in
            state.latest = frame
            state.frameCount += 1
            let render = !state.displayPending
            if render { state.displayPending = true }
            return (render, state.look, state.frameCount)
        }
        guard render else { return }
        guard let image = renderPreview(frame, look: look, seed: count) else {
            state.withLock { $0.displayPending = false }
            return
        }
        let sink = sink
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { sink.show(image) }
            state.withLock { $0.displayPending = false }
        }
    }

    public var hasFrame: Bool { state.withLock { $0.latest != nil } }

    /// Suspends until at least one frame has arrived, or `timeout` passes.
    public func waitForFirstFrame(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasFrame, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return hasFrame
    }

    /// The current frame, mirrored and cropped, without a look, at most `maxWidth` wide.
    public func still(maxWidth: CGFloat = 1280) -> CGImage? {
        guard let frame = state.withLock({ $0.latest }) else { return nil }
        let framed = Self.frame(frame, aspect: aspect)
        let scale = min(1, maxWidth / framed.extent.width)
        let sized = scale < 1 ? Self.scaled(framed, by: scale) : framed
        return context.createCGImage(sized, from: sized.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func renderPreview(_ frame: CIImage, look: BoothLook, seed: Int) -> CGImage? {
        let framed = Self.frame(frame, aspect: aspect)
        let scale = min(1, previewSize.width / framed.extent.width)
        let sized = Self.scaled(framed, by: scale)
        let looked = look.apply(to: sized, grainSeed: seed)
        return context.createCGImage(looked, from: sized.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Geometry

    /// Mirrored and centre-cropped to `aspect`, with its origin at zero.
    static func frame(_ image: CIImage, aspect: CGFloat) -> CIImage {
        let e = image.extent
        let mirrored = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.minX + e.maxX, ty: 0))
        let crop = centredCrop(of: e.size, aspect: aspect).offsetBy(dx: e.minX, dy: e.minY)
        return mirrored.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    /// The largest rectangle of `aspect` centred in `size`.
    static func centredCrop(of size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let width = (size.height * aspect).rounded()
            return CGRect(x: ((size.width - width) / 2).rounded(), y: 0, width: width, height: size.height)
        }
        let height = (size.width / aspect).rounded()
        return CGRect(x: 0, y: ((size.height - height) / 2).rounded(), width: size.width, height: height)
    }

    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 0.999 else { return image }
        let filter = CIFilter(name: "CILanczosScaleTransform", parameters: [
            kCIInputImageKey: image, kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
        ])
        return filter?.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// The viewfinder's picture: a layer whose contents the pipeline replaces directly,
/// bypassing SwiftUI so the live image costs one assignment per frame.
@MainActor
public final class PreviewSink {
    weak var layer: CALayer?
    weak var view: NSView?
    /// The newest frame, shown again if the layer is recreated.
    private(set) var current: CGImage?
    /// Frozen frames are kept on screen but no longer replaced.
    var isFrozen = false

    public nonisolated init() {}

    func show(_ image: CGImage) {
        guard !isFrozen else { return }
        current = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    /// The screen the viewfinder is on, for the flash.
    var screen: NSScreen? { view?.window?.screen }
}
