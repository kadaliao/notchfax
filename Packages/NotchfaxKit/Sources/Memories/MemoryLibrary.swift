import CoreGraphics
import Foundation

/// One photo in the library that could be printed, described only by the facts the
/// selection needs. PhotoKit's `PHAsset` is turned into this at the boundary so the
/// choosing logic can be tested on made-up libraries.
public struct MemoryCandidate: Sendable, Hashable, Identifiable {
    public var id: String
    /// When the photo was taken.
    public var date: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isFavorite: Bool
    public var isScreenshot: Bool
    /// Edited in Photos: a weak sign the picture mattered to someone.
    public var hasAdjustments: Bool
    /// Shared by every frame of a burst.
    public var burstIdentifier: String?

    public init(
        id: String,
        date: Date,
        pixelWidth: Int = 4032,
        pixelHeight: Int = 3024,
        isFavorite: Bool = false,
        isScreenshot: Bool = false,
        hasAdjustments: Bool = false,
        burstIdentifier: String? = nil
    ) {
        self.id = id
        self.date = date
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isFavorite = isFavorite
        self.isScreenshot = isScreenshot
        self.hasAdjustments = hasAdjustments
        self.burstIdentifier = burstIdentifier
    }

    public var aspectRatio: Double {
        Double(max(1, pixelWidth)) / Double(max(1, pixelHeight))
    }
}

/// Whether the app may read the photo library.
public enum MemoryAccess: Sendable, Equatable {
    case notDetermined
    case denied
    /// The person chose a subset of their library.
    case limited
    case authorized

    public var canRead: Bool { self == .limited || self == .authorized }
}

public enum MemoryLibraryError: Error, Equatable {
    case notAuthorized
    /// The picture could not be loaded, or (for iCloud originals) did not arrive in time.
    case imageUnavailable
    case timedOut
}

/// Where memories come from. The app uses Photos; tests and the debug menu use stand-ins.
public protocol MemoryLibrary: Sendable {
    /// A short name for logs and the menu ("照片图库", "样张").
    var name: String { get }
    /// The current permission, without asking.
    func access() -> MemoryAccess
    /// Asks for permission if it has not been decided yet. May show a system prompt.
    func requestAccess() async -> MemoryAccess
    /// Photos taken in earlier years on any of the given days.
    func candidates(in windows: [DateInterval]) async throws -> [MemoryCandidate]
    /// The picture, at most `maxPixel` on its long side, oriented upright.
    /// Gives up after `timeout`, which matters for originals that live in iCloud.
    func image(for candidate: MemoryCandidate, maxPixel: Int, timeout: Duration) async throws -> CGImage
}
