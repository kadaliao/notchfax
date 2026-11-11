import AVFoundation
import CoreImage
import os

/// The Mac's camera, through AVFoundation.
///
/// Follows `AVCaptureDevice.systemPreferredCamera`, as Apple recommends: when an iPhone
/// is mounted as a Continuity Camera the session moves to it, and when the device in
/// use disappears the session moves to whatever the system prefers next, or reports
/// `.lost` if there is nothing left.
///
/// Threading: the capture session is configured, started and stopped on `sessionQueue`;
/// frames arrive on `videoQueue`. Callbacks are stored under a lock.
public final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: `session`, `input` and `output` are only touched on `sessionQueue`;
    // everything else is behind `callbacks` or immutable.

    public let isSimulated = false

    private let sessionQueue = DispatchQueue(label: "com.kadaliao.notchfax.camera.session")
    private let videoQueue = DispatchQueue(label: "com.kadaliao.notchfax.camera.video", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    /// Keeps frames level when the camera is an iPhone mounted upright (Continuity Camera).
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var isObservingPreferred = false
    private static let preferredKey = "systemPreferredCamera"
    private var notificationTokens: [NSObjectProtocol] = []

    private struct Callbacks {
        var onFrame: (@Sendable (CIImage) -> Void)?
        var onEvent: (@Sendable (FrameSourceEvent) -> Void)?
        var isStopped = false
    }

    private let callbacks = OSAllocatedUnfairLock(initialState: Callbacks())

    // MARK: Discovery and permission

    /// The camera to use, if this Mac has any.
    public static func preferredDevice() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.systemPreferredCamera { return device }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { !$0.isSuspended }
    }

    /// Decides how the booth gets its picture, asking for camera access if needed.
    public static func resolve(forceSimulated: Bool) async -> BoothCamera {
        if forceSimulated { return .simulated }
        guard preferredDevice() != nil else { return .simulated }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .camera
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .camera : .denied
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: FrameSource

    public func start(onFrame: @escaping @Sendable (CIImage) -> Void, onEvent: @escaping @Sendable (FrameSourceEvent) -> Void) {
        callbacks.withLock {
            $0.onFrame = onFrame
            $0.onEvent = onEvent
        }
        observeDevices()
        sessionQueue.async { [self] in
            guard !isStopped else { return }
            guard let device = Self.preferredDevice() else {
                emit(.lost)
                return
            }
            do {
                try configure(with: device)
                session.startRunning()
                emit(.started(name: device.localizedName))
            } catch {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    public func stop() {
        let wasStopped = callbacks.withLock { state -> Bool in
            defer {
                state.isStopped = true
                state.onFrame = nil
                state.onEvent = nil
            }
            return state.isStopped
        }
        guard !wasStopped else { return }
        if isObservingPreferred {
            (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: Self.preferredKey)
            isObservingPreferred = false
        }
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        // The camera light goes out when the session stops running. Nothing else is queued
        // ahead of this, so it happens as soon as the queue is free.
        sessionQueue.async { [self] in
            output.setSampleBufferDelegate(nil, queue: nil)
            session.stopRunning()
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            session.commitConfiguration()
            input = nil
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotation = nil
        }
    }

    public func repose() {}

    // MARK: Session

    private var isStopped: Bool { callbacks.withLock { $0.isStopped } }

    private func emit(_ event: FrameSourceEvent) {
        callbacks.withLock { $0.onEvent }?(event)
    }

    /// On `sessionQueue`.
    private func configure(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        let newInput = try AVCaptureDeviceInput(device: device)
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else { throw CameraError.cannotUse(device.localizedName) }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        followRotation(of: device)
    }

    /// On `sessionQueue`.
    private func followRotation(of device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            guard let self else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self.sessionQueue.async { self.applyRotation(angle) }
        }
    }

    /// On `sessionQueue`.
    private func applyRotation(_ angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// On `sessionQueue`: move to the device the system now prefers.
    private func follow(_ device: AVCaptureDevice?) {
        guard !isStopped else { return }
        guard let device else {
            if input.map({ !$0.device.isConnected }) ?? true { emit(.lost) }
            return
        }
        guard device.uniqueID != input?.device.uniqueID else { return }
        do {
            try configure(with: device)
            if !session.isRunning { session.startRunning() }
            emit(.switched(name: device.localizedName))
        } catch {
            emit(.lost)
        }
    }

    private func observeDevices() {
        // A class property: observed on the class object itself.
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: Self.preferredKey, options: [.new], context: nil)
        isObservingPreferred = true
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            let id = device.uniqueID
            self.sessionQueue.async {
                guard self.input?.device.uniqueID == id else { return }
                self.follow(CameraFrameSource.preferredDevice().flatMap { $0.uniqueID == id ? nil : $0 })
            }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.emit(.failed(error?.localizedDescription ?? "摄像头出错"))
        })
    }

    override public func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == Self.preferredKey else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        sessionQueue.async { [self] in follow(AVCaptureDevice.systemPreferredCamera) }
    }

    // MARK: Frames

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let onFrame = callbacks.withLock({ $0.onFrame }) else { return }
        onFrame(CIImage(cvPixelBuffer: pixels))
    }

    enum CameraError: LocalizedError {
        case cannotUse(String)
        var errorDescription: String? {
            switch self {
            case .cannotUse(let name): "无法使用「\(name)」"
            }
        }
    }
}
