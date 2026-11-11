import AppKit
import SwiftUI

/// The machine. One instance owns the slot, the queue of jobs, the sounds and the
/// menu contributions; the app creates it once and hands it to every feature.
@MainActor
public final class Printer {
    public struct Configuration: Sendable {
        /// When a new job arrives while a sheet is hanging, the hanging sheet is taken
        /// back after this many seconds without the pointer on it.
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
    private var seed: UInt64 = UInt64(Date().timeIntervalSince1970)

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        stage = Stage(sound: sound)
        stage.onSlotFree = { [weak self] controller in self?.slotDidFree(controller) }
        stage.onGeometryChange = { [weak self] in self?.presentations.forEach { $0.reposition() } }
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

    // MARK: Printing

    /// Adds a job to the queue. It starts at once if the slot is free.
    @discardableResult
    public func enqueue(_ job: PrintJob) -> PrintHandle {
        let handle = PrintHandle()
        handle.printer = self
        handle.onEvent = job.onEvent
        handles[handle.id] = handle
        waiting[handle.id] = (job, handle)
        if let ready = queue.enqueue(handle.id) {
            startJob(ready)
        } else {
            hurryActiveSheet()
        }
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
    }

    private func startJob(_ id: UUID) {
        guard let (job, handle) = waiting.removeValue(forKey: id) else {
            if let next = queue.finishActive() { startJob(next) }
            return
        }
        seed &+= 0x9E37
        let layout = job.sheet.resolvedSize()
        let rendered = PaperRenderer.render(job.sheet, size: layout, scale: renderScale(for: job.sheet.paper), seed: seed)
        let fit = stage.geometry.fittingScale(forPaperWidth: layout.width)
        let controller = SheetController(job: job, handle: handle, rendered: rendered, fit: fit, stage: stage, seed: seed)
        handle.controller = controller
        controllers[id] = controller
        stage.add(controller)
        controller.beginFeed()
        if queue.shouldHurryActive { controller.hurryLimit = configuration.handoffDelay }
        Task { [weak self] in
            _ = await handle.outcome()
            self?.handles.removeValue(forKey: id)
            self?.controllers.removeValue(forKey: id)
        }
    }

    /// Thermal paper is rendered at the screen's scale so one print-head dot is one
    /// pixel; photo paper gets extra resolution for fine detail like the date stamp.
    private func renderScale(for paper: Paper) -> CGFloat {
        let screen = max(2, stage.screen?.backingScaleFactor ?? 2)
        return paper == .thermal ? screen : max(3, screen)
    }

    private func hurryActiveSheet() {
        guard let active = queue.active else { return }
        controllers[active]?.hurryLimit = configuration.handoffDelay
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
    }

    // MARK: Taking paper in

    /// The reverse of printing: a sheet that starts `gap` points below the slot is
    /// drawn up into it with the motor's cadence. Suspends until it is fully inside.
    public func feedIntoSlot(_ sheet: PaperSheet, startingBelowSlot gap: CGFloat = 36) async {
        seed &+= 0x9E37
        let layout = sheet.resolvedSize()
        let rendered = PaperRenderer.render(sheet, size: layout, scale: renderScale(for: sheet.paper), seed: seed)
        let fit = stage.geometry.fittingScale(forPaperWidth: layout.width)
        let job = PrintJob(sheet, autoRetract: .never, interaction: [])
        let controller = SheetController(job: job, handle: nil, rendered: rendered, fit: fit, stage: stage, seed: seed)
        stage.add(controller)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.beginInsert(gap: max(0, gap)) { continuation.resume() }
        }
    }

    // MARK: Anchored presentations

    /// Shows a SwiftUI view hanging from the slot as part of the machine: a viewfinder,
    /// a compose sheet. The closure receives the presentation so the view can dismiss itself.
    @discardableResult
    public func present<Content: View>(
        options: SlotPresentation.Options = SlotPresentation.Options(),
        @ViewBuilder content: (SlotPresentation) -> Content
    ) -> SlotPresentation {
        let presentation = SlotPresentation(printer: self, stage: stage, options: options)
        presentations.append(presentation)
        presentation.show(AnyView(content(presentation)))
        return presentation
    }

    func presentationDidClose(_ presentation: SlotPresentation) {
        presentations.removeAll { $0 === presentation }
    }
}

extension PrintHandle {
    func finishCancelled() {
        emit(.cancelled)
        finish(.cancelled)
    }
}
