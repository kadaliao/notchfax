import CoreImage
import Foundation

/// Something that produces a live picture of the person in the booth: the camera, or a
/// stand-in on a Mac without one.
///
/// Frames arrive on the source's own queue. Sources are started once and stopped once;
/// `stop()` must take effect immediately, because it is what turns the camera light off.
public protocol FrameSource: AnyObject, Sendable {
    /// True for the stand-in; the viewfinder labels its picture as simulated.
    var isSimulated: Bool { get }
    func start(onFrame: @escaping @Sendable (CIImage) -> Void, onEvent: @escaping @Sendable (FrameSourceEvent) -> Void)
    func stop()
    /// Between shots. The stand-in changes pose; a real camera has nothing to do.
    func repose()
}

public enum FrameSourceEvent: Sendable, Equatable {
    /// Frames are flowing from the named device.
    case started(name: String)
    /// The device went away and another took over (Continuity Camera unplugged, say).
    case switched(name: String)
    /// The device went away and there is nothing to switch to.
    case lost
    case failed(String)
}

/// How the booth gets its picture, decided before the viewfinder opens.
public enum BoothCamera: Sendable, Equatable {
    case camera
    /// No camera on this Mac, or asked for with `--photobooth-simulated`.
    case simulated
    /// The person said no to camera access (or a profile forbids it).
    case denied
}
