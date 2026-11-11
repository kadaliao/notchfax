import AppKit
import SwiftUI

/// What is going on at the slot right now. Features read this instead of guessing
/// from windows, and wait for `isIdle` before doing anything nobody asked for.
public struct SlotActivity: Sendable, Equatable {
    public enum Sheet: Sendable, Equatable {
        case none
        /// Paper is moving: feeding out, or going back in.
        case feeding
        /// A sheet is out and at rest.
        case hanging
        /// A sheet has been drawn back in to make room for a presentation and will return.
        case stowed
    }

    /// The sheet that occupies the slot. A torn sheet in the hand or falling no longer counts.
    public var sheet: Sheet = .none
    /// A presentation hangs from the slot (including while it slides away).
    public var isPresenting = false
    /// Jobs waiting behind the slot's occupant.
    public var waitingJobs = 0

    /// Nothing is out, nothing is open and nothing is waiting.
    public var isIdle: Bool { sheet == .none && !isPresenting && waitingJobs == 0 }
}

/// Stops an activity observation when cancelled or released.
@MainActor
public final class ActivityObservation {
    fileprivate var handler: (@MainActor (SlotActivity) -> Void)?
    public func cancel() { handler = nil }
}

/// The machine. One instance owns the slot, the queue of jobs, the sounds and the
/// menu contributions; the app creates it once and hands it to every feature.
///
/// ## One thing under the slot at a time
///
/// - A **sheet** occupies the slot from the moment it starts feeding until it is
///   retracted, torn off or dragged away. Other jobs wait.
/// - When an ordinary job is waiting, the sheet that is out is taken back once it has
///   been out, untouched, for its `readingTime` (or the short `handoffDelay`).
///   `.ambient` jobs wait behind everything and never hurry a sheet.
/// - A **presentation** takes precedence over paper. A sheet that is out is drawn
///   back into the slot (stowed) and comes out again when the presentation closes;
///   jobs enqueued meanwhile wait. Opening a second presentation closes the first.
/// - `activity` says which of these is happening; `observeActivity` and
///   `waitUntilIdle()` let optional things (notices, daily prints) pick their moment.
@MainActor
public final class Printer {
    public struct Configuration: Sendable {
        /// When a new job arrives while a sheet is hanging, the hanging sheet is taken
        /// back after this many seconds without the pointer on it, unless its job asks
        /// for a longer `readingTime`.
        public var handoffDelay: TimeInterval = 1.4
        public init() {}
    }

    public let configuration: Configuration
    /// Play machine sounds from a feature (for example the shutter).
    public let sound = SoundPlayer()
    /// Menu-bar items contributed by features.
    public let menu = MenuRegistry()

    private let stage: Stage
    private var queue = PrintQueue<UUID>()
    private var waiting: [UUID: (job: PrintJob, handle: PrintHandle)] = [:]
    private var handles: [UUID: PrintHandle] = [:]
    private var controllers: [UUID: SheetController] = [:]
    private var presentations: [SlotPresentation] = []
    private var observations: [ActivityObservation] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var settleTask: Task<Void, Never>?
    private var seed: UInt64 = UInt64(Date().timeIntervalSince1970)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        stage = Stage(sound: sound)
        stage.onSlotFree = { [weak self] controller in self?.slotDidFree(controller) }
        stage.onGeometryChange = { [weak self] in self?.presentations.forEach { $0.reposition() } }
        stage.onStateChange = { [weak self] in self?.refreshActivity() }
    }

    // MARK: Lifecycle

    /// Shows the slot and starts following screen changes. Call once at launch.
    public func start() {
        ExportStore.purge()
        stage.start()
    }

    public func stop() {
        cancelAll()
        presentations.forEach { $0.dismiss() }
        stage.stop()
    }

    /// Where paper comes out on the current screen.
    public var slot: SlotGeometry { stage.geometry }

    public var isMuted: Bool {
        get { sound.isMuted }
        set { sound.isMuted = newValue }
    }

    /// Draws a notch on a display that has none, to develop against notch geometry.
    public var simulatesNotch: Bool {
        get { stage.simulatesNotch }
        set { stage.simulatesNotch = newValue }
    }

    /// True while the system's Reduce Motion setting is on; paper then fades instead of feeding.
    public var reducesMotion: Bool { stage.reduceMotion }

    // MARK: Activity

    /// What the slot is doing right now.
    public private(set) var activity = SlotActivity()

    /// Calls `handler` every time `activity` changes, until the returned observation is
    /// cancelled or released.
    public func observeActivity(_ handler: @escaping @MainActor (SlotActivity) -> Void) -> ActivityObservation {
        let observation = ActivityObservation()
        observation.handler = handler
        observations.append(observation)
        return observation
    }

    /// Suspends until nothing is out, open or waiting. Returns at once if that is already so.
    public func waitUntilIdle() async {
        if activity.isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func refreshActivity() {
        var next = SlotActivity()
        if let active = queue.active {
            // Between jobs the slot is spoken for even though no paper has appeared yet.
            next.sheet = controllers[active].map(\.slotState) ?? .feeding
            if next.sheet == .none { next.sheet = .feeding }
        }
        next.isPresenting = !presentations.isEmpty
        next.waitingJobs = queue.pending.count
        guard next != activity else { return }
        activity = next
        observations.removeAll { $0.handler == nil }
        for observation in observations { observation.handler?(next) }
        if next.isIdle {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    // MARK: Printing

    /// Adds a job to the queue. It starts at once if the slot is free and nothing is presented.
    @discardableResult
    public func enqueue(_ job: PrintJob) -> PrintHandle {
        let handle = PrintHandle()
        handle.printer = self
        handle.onEvent = job.onEvent
        handles[handle.id] = handle
        waiting[handle.id] = (job, handle)
        if let ready = queue.enqueue(handle.id, ambient: job.priority == .ambient) {
            startJob(ready)
        } else {
            hurryActiveSheet()
        }
        refreshActivity()
        return handle
    }

    /// Prints a sheet and suspends until it is gone.
    @discardableResult
    public func print(_ job: PrintJob) async -> PrintOutcome {
        await enqueue(job).outcome()
    }

    /// Number of jobs waiting behind the one in the slot.
    public var pendingCount: Int { queue.pending.count }

    public func cancelAll() {
        for id in queue.removeAllPending() {
            waiting.removeValue(forKey: id)
            handles.removeValue(forKey: id)?.finishCancelled()
        }
        stage.cancelAll()
        refreshActivity()
    }

    func cancel(_ handle: PrintHandle) {
        switch queue.cancel(handle.id) {
        case .removedPending:
            waiting.removeValue(forKey: handle.id)
            handles.removeValue(forKey: handle.id)
            handle.finishCancelled()
        case .isActive, .unknown:
            if let controller = controllers[handle.id] {
                controller.cancel()
            } else if waiting.removeValue(forKey: handle.id) != nil {
                // Next in line but not started yet; `startJob` will skip it.
                handles.removeValue(forKey: handle.id)
                handle.finishCancelled()
            }
        }
        refreshActivity()
    }

    private func startJob(_ id: UUID) {
        guard let (job, handle) = waiting.removeValue(forKey: id) else {
            if let next = queue.finishActive() { startJob(next) }
            refreshActivity()
            return
        }
        seed &+= 0x9E37
        let layout = job.sheet.resolvedSize()
        let rendered = PaperRenderer.render(job.sheet, size: layout, scale: PaperRenderer.scale(for: job.sheet.paper), seed: seed)
        let fit = stage.geometry.fittingScale(forPaperWidth: layout.width)
        let controller = SheetController(job: job, handle: handle, rendered: rendered, fit: fit, host: stage, seed: seed)
        handle.controller = controller
        controllers[id] = controller
        stage.add(controller)
        controller.beginFeed()
        hurryActiveSheet()
        Task { [weak self] in
            _ = await handle.outcome()
            self?.handles.removeValue(forKey: id)
            self?.controllers.removeValue(forKey: id)
            self?.refreshActivity()
        }
        refreshActivity()
    }

    private func hurryActiveSheet() {
        guard let active = queue.active, let controller = controllers[active] else { return }
        // An ordinary job moves any sheet along. An ambient one only moves another ambient
        // sheet: it never displaces something a person asked for.
        if queue.shouldHurryActive || (!queue.pending.isEmpty && controller.job.priority == .ambient) {
            hurry(controller)
        }
    }

    /// A waiting job shortens the stay of the sheet that is out, but never below its reading time.
    private func hurry(_ controller: SheetController) {
        controller.hurryLimit = max(configuration.handoffDelay, controller.job.readingTime ?? 0)
    }

    private func slotDidFree(_ controller: SheetController) {
        guard let id = controllers.first(where: { $0.value === controller })?.key, queue.active == id else { return }
        if let next = queue.finishActive() {
            // Let the previous sheet clear the slot before the motor starts again.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                self?.startJob(next)
            }
        }
        refreshActivity()
    }

    // MARK: Taking paper in

    /// The reverse of printing: a sheet that starts `gap` points below the slot is
    /// drawn up into it with the motor's cadence. Suspends until it is fully inside.
    public func feedIntoSlot(_ sheet: PaperSheet, startingBelowSlot gap: CGFloat = 36) async {
        seed &+= 0x9E37
        let layout = sheet.resolvedSize()
        let rendered = PaperRenderer.render(sheet, size: layout, scale: PaperRenderer.scale(for: sheet.paper), seed: seed)
        let fit = stage.geometry.fittingScale(forPaperWidth: layout.width)
        let job = PrintJob(sheet, autoRetract: .never, interaction: [])
        let controller = SheetController(job: job, handle: nil, rendered: rendered, fit: fit, host: stage, seed: seed)
        stage.add(controller)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.beginInsert(gap: max(0, gap)) { continuation.resume() }
        }
    }

    // MARK: Anchored presentations

    /// Shows a SwiftUI view hanging from the slot as part of the machine: a viewfinder,
    /// a compose sheet. The closure receives the presentation so the view can dismiss itself.
    ///
    /// Any presentation already open is closed first. A sheet that is out is drawn back
    /// into the slot and returns when the presentation closes (see `Options.hangingSheet`);
    /// jobs enqueued while it is open wait.
    @discardableResult
    public func present<Content: View>(
        options: SlotPresentation.Options = SlotPresentation.Options(),
        @ViewBuilder content: (SlotPresentation) -> Content
    ) -> SlotPresentation {
        let replacing = !presentations.isEmpty
        presentations.forEach { $0.dismiss() }
        settleTask?.cancel()
        queue.pause()
        if let active = queue.active, let controller = controllers[active] {
            switch options.hangingSheet {
            case .stow: controller.stow()
            case .retract: controller.requestRetract()
            case .leave: break
            }
        }
        let presentation = SlotPresentation(printer: self, stage: stage, options: options)
        presentations.append(presentation)
        // Give the paper, or the panel being replaced, a head start out of the way.
        let busy = replacing || (activity.sheet != .none && options.hangingSheet != .leave)
        presentation.show(AnyView(content(presentation)), after: busy ? .milliseconds(240) : .zero)
        refreshActivity()
        return presentation
    }

    func presentationDidClose(_ presentation: SlotPresentation) {
        presentations.removeAll { $0 === presentation }
        refreshActivity()
        guard presentations.isEmpty else { return }
        // The slot is clear again. Anything that was enqueued meanwhile goes first; a stowed
        // sheet gives way to it, or comes back out if nothing is waiting.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled, let self, self.presentations.isEmpty else { return }
            self.settleAfterPresentation()
        }
    }

    private func settleAfterPresentation() {
        let stowed = queue.active.flatMap { controllers[$0] }.flatMap { $0.isStowed ? $0 : nil }
        if let stowed {
            if queue.shouldHurryActive {
                stowed.requestRetract()
            } else {
                stowed.unstow()
            }
        }
        if let next = queue.resume() { startJob(next) }
        refreshActivity()
    }

    // MARK: Debugging

    /// Scripted pointer gestures that can be played against the sheet in the slot.
    public static let debugGestureNames = ["hover", "swing", "carry", "carry-out", "rip", "half-tear", "fling"]

    /// Plays a scripted gesture through the real interaction code, as if a hand were on
    /// the sheet. No system events are posted and the real pointer does not move.
    /// Returns false if the name is unknown or there is no sheet to act on.
    @discardableResult
    public func debugPlayGesture(_ name: String) -> Bool {
        stage.runGesture(named: name)
    }

    /// Behaves as if the system's Reduce Motion setting were on.
    public var debugForcesReducedMotion: Bool {
        get { stage.forcesReducedMotion }
        set { stage.forcesReducedMotion = newValue }
    }

    /// Reports which window a click would land on at a few points on and around the
    /// sheet in the slot, to check that only the paper itself takes the mouse.
    public func debugPointerReport() -> String {
        stage.pointerReport()
    }
}

extension PrintHandle {
    func finishCancelled() {
        emit(.cancelled)
        finish(.cancelled)
    }
}
