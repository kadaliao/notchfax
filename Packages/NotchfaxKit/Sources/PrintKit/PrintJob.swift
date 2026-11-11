import SwiftUI

// MARK: - Paper

/// The stock a sheet is printed on.
public enum Paper: String, Sendable, CaseIterable {
    /// Fax / receipt paper. Warm white; content is converted to a thermal print; tears along a serrated edge.
    case thermal
    /// A lab photo print with a white border and a gloss sheen.
    case glossyPhoto
    /// A tall, narrow photo-booth strip holding four frames.
    case photoStrip

    /// Sheet size used when a job does not give one. Thermal sheets grow to fit their content.
    public var defaultSize: CGSize {
        switch self {
        case .thermal: CGSize(width: 160, height: 220)
        case .glossyPhoto: CGSize(width: 164, height: 130)
        case .photoStrip: CGSize(width: 84, height: 268)
        }
    }

    /// Unprinted margin around the content area.
    public var contentInsets: EdgeInsets {
        switch self {
        case .thermal: EdgeInsets(top: 14, leading: 11, bottom: 18, trailing: 11)
        case .glossyPhoto: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        case .photoStrip: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        }
    }

    /// The area content is drawn into, in sheet coordinates (origin top-left).
    public func contentRect(in size: CGSize) -> CGRect {
        let i = contentInsets
        return CGRect(
            x: i.leading,
            y: i.top,
            width: max(1, size.width - i.leading - i.trailing),
            height: max(1, size.height - i.top - i.bottom)
        )
    }

    /// Thermal paper comes off a roll and is torn; the others are cut by the machine.
    public var isTearable: Bool { self == .thermal }

    public var defaultCadence: FeedCadence {
        switch self {
        case .thermal: .text()
        case .glossyPhoto, .photoStrip: .photo
        }
    }

    /// Print-head resolution of thermal paper: two dots per point, one per pixel on a Retina screen.
    public static let thermalDotsPerPoint: CGFloat = 2

    /// How many print-head dots fit across the content area of a default thermal sheet.
    public static var thermalContentDots: Int {
        Int((Paper.thermal.contentRect(in: Paper.thermal.defaultSize).width * thermalDotsPerPoint).rounded(.down))
    }

    /// Height of the caption band at the bottom of a photo strip.
    public static let stripFooterHeight: CGFloat = 22
    public static let stripFrameGap: CGFloat = 4

    /// The four frame rectangles of a photo strip, in content coordinates
    /// (relative to `contentRect(in:)`'s origin).
    public static func stripFrameRects(contentSize: CGSize) -> [CGRect] {
        let gap = stripFrameGap
        let height = max(1, (contentSize.height - stripFooterHeight - gap * 3) / 4)
        return (0..<4).map { i in
            CGRect(x: 0, y: CGFloat(i) * (height + gap), width: contentSize.width, height: height)
        }
    }
}

/// What is printed on a sheet.
public enum PaperContent {
    case blank
    /// Scaled to fill the content area, cropping if the aspect ratio differs.
    case image(CGImage)
    /// Laid out at the content area's size and rasterised once when the job starts.
    case view(AnyView)
}

/// One piece of paper: stock, size and what is on it.
public struct PaperSheet {
    public var paper: Paper
    /// Whole-sheet size in points. `nil` picks a size from the content:
    /// thermal paper grows to the content's height, photos follow the image's aspect ratio.
    public var size: CGSize?
    public var content: PaperContent

    public init(_ paper: Paper, size: CGSize? = nil, content: PaperContent = .blank) {
        self.paper = paper
        self.size = size
        self.content = content
    }

    public init(_ paper: Paper, size: CGSize? = nil, image: CGImage) {
        self.init(paper, size: size, content: .image(image))
    }

    public init<V: View>(_ paper: Paper, size: CGSize? = nil, @ViewBuilder content: () -> V) {
        self.init(paper, size: size, content: .view(AnyView(content())))
    }

    /// The size the sheet will have before any scaling to fit the slot.
    @MainActor
    public func resolvedSize() -> CGSize {
        if let size { return size }
        let fallback = paper.defaultSize
        let insets = paper.contentInsets
        let horizontal = insets.leading + insets.trailing
        let vertical = insets.top + insets.bottom
        switch (paper, content) {
        case (.thermal, .view(let view)):
            let width = fallback.width - horizontal
            let host = NSHostingController(rootView: view.frame(width: width))
            let fitted = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
            return CGSize(width: fallback.width, height: min(1400, max(40, fitted.height.rounded(.up) + vertical)))
        case (.thermal, .image(let image)):
            let width = fallback.width - horizontal
            let height = width * CGFloat(image.height) / CGFloat(max(1, image.width))
            return CGSize(width: fallback.width, height: min(1400, height.rounded() + vertical))
        case (.glossyPhoto, .image(let image)):
            let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
            let long = fallback.width - horizontal
            if aspect >= 1 {
                return CGSize(width: fallback.width, height: (long / aspect).rounded() + vertical)
            }
            let tall = long * 1.2
            return CGSize(width: (tall * aspect).rounded() + horizontal, height: tall.rounded() + vertical)
        default:
            return fallback
        }
    }

    /// The printed face as PNG data, as it would look on paper (no shadow).
    @MainActor
    public func pngData(scale: CGFloat = 3) -> Data? {
        let rendered = PaperRenderer.render(self, size: resolvedSize(), scale: paper == .thermal ? Paper.thermalDotsPerPoint : scale, seed: 1)
        return PaperRenderer.pngData(rendered.printed)
    }
}

// MARK: - Job

/// A request to print one sheet.
public struct PrintJob {
    /// How ink appears while the paper feeds.
    public enum Reveal: Sendable, Equatable {
        /// The sheet comes out already printed.
        case withPaper
        /// The sheet is printed as it comes out: it advances one line at a time and
        /// each band darkens just below the slot, as thermal paper does.
        case progressive(lineHeight: CGFloat = 14)
    }

    /// What happens to a sheet nobody touches.
    public enum AutoRetract: Sendable, Equatable {
        case never
        /// Pulled back into the slot after hanging untouched this long.
        case after(TimeInterval)
    }

    /// What the pointer may do to the sheet.
    public struct Interaction: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Grab and swing the sheet while it stays in the slot.
        public static let grab = Interaction(rawValue: 1 << 0)
        /// Take the sheet out of the slot: tearing thermal paper, pulling cut paper free.
        public static let detach = Interaction(rawValue: 1 << 1)
        /// Carry the sheet away from the machine as a real PNG file drag.
        public static let dragOut = Interaction(rawValue: 1 << 2)
        // An empty set makes the sheet inert: with no actions either, clicks pass straight through it.
        public static let all: Interaction = [.grab, .detach, .dragOut]
    }

    /// How a job stands in line.
    public enum Priority: Sendable, Equatable {
        /// Prints in turn; a sheet already hanging is moved along to make room.
        case normal
        /// Something nobody asked for just now (a daily print). It waits behind every
        /// ordinary job and never hurries a sheet that is already out.
        case ambient
    }

    public var sheet: PaperSheet
    public var reveal: Reveal
    /// Overrides the paper's default motor cadence.
    public var cadence: FeedCadence?
    public var autoRetract: AutoRetract
    public var interaction: Interaction
    /// The file handed over when the sheet is dragged out. Defaults to the sheet as printed.
    public var export: PNGExport?
    /// Small affordances shown under the sheet while the pointer is over it.
    public var actions: [PaperAction]
    /// Called on the main actor for every event of this job.
    public var onEvent: (@MainActor (PrintEvent, PrintHandle) -> Void)?
    public var priority: Priority
    /// How long the sheet should stay out, untouched, before a waiting job may take its
    /// place. `nil` uses the printer's short hand-off delay; give text the time it takes to read.
    public var readingTime: TimeInterval?

    public init(
        _ sheet: PaperSheet,
        reveal: Reveal = .withPaper,
        cadence: FeedCadence? = nil,
        autoRetract: AutoRetract = .after(10),
        interaction: Interaction = .all,
        export: PNGExport? = nil,
        actions: [PaperAction] = [],
        priority: Priority = .normal,
        readingTime: TimeInterval? = nil,
        onEvent: (@MainActor (PrintEvent, PrintHandle) -> Void)? = nil
    ) {
        self.priority = priority
        self.readingTime = readingTime
        self.sheet = sheet
        self.reveal = reveal
        self.cadence = cadence
        self.autoRetract = autoRetract
        self.interaction = interaction
        self.export = export
        self.actions = actions
        self.onEvent = onEvent
    }
}

/// Names, and optionally supplies, the PNG a dragged-out sheet becomes.
public struct PNGExport: Sendable {
    /// File name without extension.
    public var filename: String
    /// Called once, off the critical path, shortly after the sheet finishes feeding.
    /// `nil` exports the sheet as printed, under `filename`.
    public var data: (@Sendable () async throws -> Data)?

    /// The sheet as printed, saved under a name of your choosing.
    public init(filename: String) {
        self.filename = filename
        data = nil
    }

    /// A PNG produced off the main actor (a full-resolution composite, say).
    public init(filename: String, data: @escaping @Sendable () async throws -> Data) {
        self.filename = filename
        self.data = data
    }

    /// A PNG produced on the main actor, for exports that read main-actor state or render SwiftUI.
    public init(filename: String, onMainActor data: @escaping @MainActor () async throws -> Data) {
        self.filename = filename
        self.data = { try await data() }
    }
}

/// An understated button shown under a hanging sheet on hover.
public struct PaperAction: Identifiable {
    public enum Role: Sendable { case normal, destructive }

    public var id: String
    public var title: String
    public var systemImage: String?
    public var role: Role
    /// Runs on the main actor. Use the handle to retract or tear the sheet in response.
    public var handler: @MainActor (PrintHandle) -> Void

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        role: Role = .normal,
        handler: @escaping @MainActor (PrintHandle) -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.handler = handler
    }
}

// MARK: - Events

public enum PrintEvent: Sendable, Equatable {
    /// The job left the queue and paper started to move.
    case startedFeeding
    /// The whole sheet is out and hanging.
    case finishedFeeding
    /// Clicked without dragging.
    case tapped
    /// One of the job's `actions` was chosen.
    case action(id: String)
    /// Torn off the roll (thermal) or pulled out of the slot and discarded.
    case torn
    /// Dropped on another app or the Finder. The URL is the temporary PNG that was handed over.
    case draggedOut(URL?)
    /// Went back into the slot, by timeout or by request.
    case retracted
    /// Removed before or during printing by `PrintHandle.cancel()`.
    case cancelled
}

/// How a sheet's life ended.
public enum PrintOutcome: Sendable, Equatable {
    case torn
    case draggedOut(URL?)
    case retracted
    case cancelled
}

/// A live reference to an enqueued job.
@MainActor
public final class PrintHandle: Identifiable {
    public enum State: Sendable, Equatable {
        case queued, feeding, hanging
        case finished(PrintOutcome)
    }

    public nonisolated let id = UUID()
    public private(set) var state: State = .queued

    /// Every event of this job, in order. Finishes when the sheet is gone.
    public let events: AsyncStream<PrintEvent>

    private let continuation: AsyncStream<PrintEvent>.Continuation
    private var feedWaiters: [CheckedContinuation<Bool, Never>] = []
    private var outcomeWaiters: [CheckedContinuation<PrintOutcome, Never>] = []
    private var didFinishFeeding = false
    var onEvent: (@MainActor (PrintEvent, PrintHandle) -> Void)?
    weak var controller: SheetController?
    weak var printer: Printer?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: PrintEvent.self, bufferingPolicy: .unbounded)
    }

    /// Suspends until the sheet has fully fed out. Returns `false` if it never got that far.
    @discardableResult
    public func finishedFeeding() async -> Bool {
        if didFinishFeeding { return true }
        if case .finished = state { return false }
        return await withCheckedContinuation { feedWaiters.append($0) }
    }

    /// Suspends until the sheet is gone and reports how.
    public func outcome() async -> PrintOutcome {
        if case .finished(let outcome) = state { return outcome }
        return await withCheckedContinuation { outcomeWaiters.append($0) }
    }

    /// Feeds the sheet back into the slot.
    public func retract() {
        if let controller { controller.requestRetract() } else { cancel() }
    }

    /// Tears the sheet off and lets it fall away. Cut paper, which cannot tear, is retracted instead.
    public func tearOff() {
        if let controller { controller.requestTearOff() } else { cancel() }
    }

    /// Removes the job. A waiting job never prints; a visible sheet fades out.
    public func cancel() {
        printer?.cancel(self)
    }

    // MARK: Internal

    func emit(_ event: PrintEvent) {
        if case .finished = state { return }
        switch event {
        case .startedFeeding: state = .feeding
        case .finishedFeeding:
            state = .hanging
            didFinishFeeding = true
            resumeFeedWaiters(true)
        default: break
        }
        continuation.yield(event)
        onEvent?(event, self)
    }

    func finish(_ outcome: PrintOutcome) {
        if case .finished = state { return }
        state = .finished(outcome)
        resumeFeedWaiters(didFinishFeeding)
        let waiters = outcomeWaiters
        outcomeWaiters.removeAll()
        waiters.forEach { $0.resume(returning: outcome) }
        continuation.finish()
        onEvent = nil
    }

    private func resumeFeedWaiters(_ value: Bool) {
        let waiters = feedWaiters
        feedWaiters.removeAll()
        waiters.forEach { $0.resume(returning: value) }
    }
}
