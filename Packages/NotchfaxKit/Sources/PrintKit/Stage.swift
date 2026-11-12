import AppKit
import SwiftUI

/// A panel that floats above the menu bar and never takes focus.
class OverlayPanel: NSPanel {
    var allowsKey = false

    init(level offset: Int) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + offset)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { allowsKey }

    /// AppKit would otherwise push the panel down below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeMain: Bool { false }
}

/// Owns the windows the paper lives in, the frame clock, and pointer routing.
///
/// Back to front: anchored presentations, the slot (drawn mouth), the stage, and one
/// small hit panel per sheet. The stage covers the whole screen and never takes the
/// mouse. Each hit panel is an invisible window kept exactly over its sheet, so the
/// window server itself decides what a click lands on: there is nothing to poll, and
/// everything outside the paper stays clickable.
@MainActor
final class Stage: NSObject, SheetHost {
    private(set) var geometry: SlotGeometry
    let sound: SoundPlayer
    var simulatesNotch = false { didSet { if oldValue != simulatesNotch { relayout() } } }
    var onSlotFree: ((SheetController) -> Void)?
    var onGeometryChange: (() -> Void)?
    /// A sheet changed phase; the printer re-reads what the slot is doing.
    var onStateChange: (() -> Void)?

    private(set) var screen: NSScreen?
    private let slotPanel = OverlayPanel(level: 2)
    private let stagePanel = OverlayPanel(level: 3)
    private let canvas = NSView()
    private let slotLayer = CALayer()
    private let clipLayer = CALayer()
    private let freeLayer = CALayer()

    private var controllers: [SheetController] = []
    private var hitPanels: [UUID: HitPanel] = [:]
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var housekeeping: Timer?
    private weak var mouseOwner: SheetController?
    private weak var dragSessionOwner: SheetController?
    private var lastMouseEvent: NSEvent?
    private var actionBar: ActionBarView?
    private weak var actionBarOwner: SheetController?
    private var actionBarRect = CGRect.zero
    /// A bar that is fading out still needs its place in the hit panel until it is gone.
    private var fadingBar: (owner: UUID, rect: CGRect)?
    private var script: (run: PointerScript.Run, controller: SheetController)?
    private var isStarted = false
    /// Stands in for the real pointer position while a debug hover is playing.
    private var pointerOverride: CGPoint?

    init(sound: SoundPlayer) {
        self.sound = sound
        geometry = SlotGeometry.make(for: ScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1440, height: 900)))
        super.init()

        slotPanel.ignoresMouseEvents = true
        let slotView = NSView()
        slotView.wantsLayer = true
        slotView.layer?.addSublayer(slotLayer)
        slotPanel.contentView = slotView

        stagePanel.ignoresMouseEvents = true
        canvas.layer = CALayer()
        canvas.wantsLayer = true
        stagePanel.contentView = canvas
        canvas.layer?.addSublayer(clipLayer)
        canvas.layer?.addSublayer(freeLayer)
        clipLayer.masksToBounds = true
    }

    var forcesReducedMotion = false
    var reduceMotion: Bool { forcesReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var presentationLevel: NSWindow.Level { NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) }
    var hasSheets: Bool { !controllers.isEmpty }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        relayout()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        slotPanel.orderOut(nil)
        stagePanel.orderOut(nil)
        hitPanels.values.forEach { $0.orderOut(nil) }
    }

    @objc private func screensDidChange() {
        relayout()
    }

    private func relayout() {
        let screens = NSScreen.screens
        let descriptors = screens.map(ScreenDescriptor.init)
        guard let index = SlotGeometry.preferredScreenIndex(descriptors) else {
            slotPanel.orderOut(nil)
            return
        }
        let screen = screens[index]
        self.screen = screen
        let previous = geometry
        geometry = SlotGeometry.make(for: descriptors[index], simulateNotch: simulatesNotch)

        let frame = screen.frame
        stagePanel.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: frame.size)
        freeLayer.frame = bounds
        clipLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - geometry.slotLineY)

        if let image = SlotRenderer.image(for: geometry, scale: screen.backingScaleFactor) {
            let pad = SlotRenderer.pad
            let mouth = geometry.mouth
            let slotFrame = CGRect(
                x: frame.minX + mouth.minX - pad,
                y: frame.maxY - mouth.maxY - pad,
                width: mouth.width + pad * 2,
                height: mouth.height + pad
            )
            slotPanel.setFrame(slotFrame, display: false)
            slotLayer.frame = CGRect(origin: .zero, size: slotFrame.size)
            slotLayer.contents = image
            slotLayer.contentsScale = screen.backingScaleFactor
            if isStarted { slotPanel.orderFrontRegardless() }
        } else {
            slotPanel.orderOut(nil)
        }
        CATransaction.commit()

        if previous != geometry {
            onGeometryChange?()
            requestFrames()
            syncHitPanels()
        }
    }

    // MARK: Sheets

    func add(_ controller: SheetController) {
        controllers.append(controller)
        if controllers.count == 1 {
            stagePanel.orderFrontRegardless()
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.housekeepingTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            housekeeping = timer
        }
        requestFrames()
    }

    func remove(_ controller: SheetController) {
        controllers.removeAll { $0 === controller }
        if actionBarOwner === controller || actionBarOwner == nil { hideActionBar() }
        if let panel = hitPanels.removeValue(forKey: controller.id) { panel.orderOut(nil) }
        if script?.controller === controller { script = nil }
        if controllers.isEmpty {
            housekeeping?.invalidate()
            housekeeping = nil
            stagePanel.orderOut(nil)
        }
    }

    func place(_ layer: CALayer, clipped: Bool, atBack: Bool) {
        let target = clipped ? clipLayer : freeLayer
        guard layer.superlayer !== target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if atBack {
            target.insertSublayer(layer, at: 0)
        } else {
            target.addSublayer(layer)
        }
        CATransaction.commit()
    }

    func slotDidFree(_ controller: SheetController) {
        onSlotFree?(controller)
    }

    func sheetStateDidChange() {
        pointerDidMove()
        requestFrames()
        onStateChange?()
    }

    func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    func cancelAll() {
        controllers.forEach { $0.cancel() }
    }

    // MARK: Frame clock

    func requestFrames() {
        guard link == nil, !controllers.isEmpty else { return }
        lastTimestamp = nil
        let link = canvas.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { min(1.0 / 30, max(1.0 / 240, link.timestamp - $0)) } ?? 1.0 / 60
        lastTimestamp = link.timestamp
        advanceScript(dt)
        var active = script != nil
        for controller in controllers where controller.needsFrames {
            controller.tick(dt)
            active = active || controller.needsFrames
        }
        // Paper moves under a still pointer too, so hover is re-evaluated with every frame.
        pointerDidMove()
        if !active {
            link.invalidate()
            self.link = nil
        }
    }

    private func housekeepingTick() {
        for controller in controllers { controller.housekeeping(0.25) }
        pointerDidMove()
        if controllers.contains(where: \.needsFrames) { requestFrames() }
    }

    // MARK: Pointer

    func stagePoint(fromGlobal point: CGPoint) -> CGPoint {
        let frame = stagePanel.frame
        return CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    private func globalRect(fromStage rect: CGRect) -> CGRect {
        let frame = stagePanel.frame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Works out who is hovered, shows or hides the action bar, and keeps each hit panel over its sheet.
    func pointerDidMove() {
        guard !controllers.isEmpty else { return }
        if dragSessionOwner == nil, mouseOwner == nil, script == nil {
            let point = pointerOverride ?? stagePoint(fromGlobal: NSEvent.mouseLocation)
            let hit = controllers.last { $0.hitTest(point) }
            var owner = hit
            if owner == nil, let bar = actionBar, let barOwner = actionBarOwner, bar.hoverRegion.contains(point) {
                owner = barOwner
            }
            var changed = false
            for controller in controllers {
                let hovered = controller === owner
                if controller.hovered != hovered {
                    controller.hovered = hovered
                    changed = true
                }
                controller.pointerHover(at: controller === hit ? point : nil)
            }
            updateActionBar(for: owner)
            if changed || hit != nil { requestFrames() }
        } else if actionBarOwner?.showsActions == false {
            hideActionBar()
        }
        syncHitPanels()
    }

    private func syncHitPanels() {
        for controller in controllers {
            guard var rect = controller.interactiveBounds else {
                hitPanels[controller.id]?.orderOut(nil)
                continue
            }
            if actionBarOwner === controller, actionBar != nil {
                layoutActionBar()
                rect = rect.union(actionBarRect.insetBy(dx: -2, dy: -2))
            } else if let fadingBar, fadingBar.owner == controller.id {
                rect = rect.union(fadingBar.rect.insetBy(dx: -2, dy: -2))
            }
            rect = rect.integral
            let panel = hitPanels[controller.id] ?? {
                let panel = HitPanel(stage: self, controller: controller)
                hitPanels[controller.id] = panel
                return panel
            }()
            let frame = globalRect(fromStage: rect)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            panel.ignoresMouseEvents = dragSessionOwner != nil
            if !panel.isVisible { panel.orderFrontRegardless() }
            if actionBarOwner === controller, let bar = actionBar {
                if bar.superview !== panel.hitView { panel.hitView.addSubview(bar) }
                bar.frame = CGRect(
                    x: actionBarRect.minX - rect.minX, y: rect.maxY - actionBarRect.maxY,
                    width: actionBarRect.width, height: actionBarRect.height
                )
            }
        }
    }

    fileprivate func mouseDown(_ event: NSEvent, on controller: SheetController?) {
        let point = stagePoint(fromGlobal: NSEvent.mouseLocation)
        // The hit panel is a rectangle; the paper inside it may be tilted.
        guard script == nil, let controller, controllers.contains(where: { $0 === controller }), controller.hitTest(point) else { return }
        mouseOwner = controller
        lastMouseEvent = event
        controller.mouseDown(at: point, time: event.timestamp)
        requestFrames()
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        guard let controller = mouseOwner else { return }
        lastMouseEvent = event
        controller.mouseDragged(to: stagePoint(fromGlobal: NSEvent.mouseLocation), time: event.timestamp)
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        guard let controller = mouseOwner else { return }
        mouseOwner = nil
        lastMouseEvent = nil
        controller.mouseUp(at: stagePoint(fromGlobal: NSEvent.mouseLocation), time: event.timestamp)
        pointerDidMove()
    }

    // MARK: Drag-out

    func beginDragSession(for controller: SheetController) -> Bool {
        guard dragSessionOwner == nil, mouseOwner === controller,
              let event = lastMouseEvent, let source = hitPanels[controller.id]?.hitView,
              let url = controller.exportFileURL() else { return false }
        // The dragging frame is given in the source view's coordinates.
        let frame = globalRect(fromStage: controller.dragFrame)
        let origin = source.window?.convertPoint(fromScreen: frame.origin) ?? .zero
        let viewFrame = CGRect(origin: source.convert(origin, from: nil), size: frame.size)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(viewFrame, contents: NSImage(cgImage: controller.dragImage, size: frame.size))
        dragSessionOwner = controller
        mouseOwner = nil
        lastMouseEvent = nil
        controller.dragSessionDidBegin()
        hideActionBar()
        // Our own windows must not sit between the dragged file and its destination.
        hitPanels.values.forEach { $0.ignoresMouseEvents = true }
        let session = source.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        return true
    }

    func saveToDesktop(_ file: URL) -> URL? {
        ExportStore.desktop.flatMap { ExportStore.copy(file, into: $0) }
    }

    fileprivate func dragSessionEnded(operation: NSDragOperation) {
        guard let controller = dragSessionOwner else { return }
        dragSessionOwner = nil
        controller.dragSessionDidEnd(at: stagePoint(fromGlobal: NSEvent.mouseLocation), delivered: !operation.isEmpty)
        pointerDidMove()
        requestFrames()
    }

    // MARK: Action bar

    private func updateActionBar(for owner: SheetController?) {
        guard let owner, owner.showsActions else {
            if actionBarOwner != nil { hideActionBar() }
            return
        }
        guard actionBarOwner !== owner else { return }
        hideActionBar()
        let bar = ActionBarView(actions: owner.job.actions) { [weak owner] action in
            guard let owner else { return }
            owner.performAction(action)
        }
        actionBar = bar
        actionBarOwner = owner
        layoutActionBar()
        syncHitPanels()
        bar.appear()
    }

    private func layoutActionBar() {
        guard let bar = actionBar, let owner = actionBarOwner else { return }
        let bottom = owner.bottomCentre
        let size = bar.fittingBarSize
        let width = stagePanel.frame.width
        let x = min(max(8, bottom.x - size.width / 2), width - size.width - 8)
        actionBarRect = CGRect(x: x.rounded(), y: (bottom.y + 9).rounded(), width: size.width, height: size.height)
        bar.hoverRegion = CGRect(x: x - 10, y: bottom.y - 4, width: size.width + 20, height: size.height + 9 + 12)
    }

    private func hideActionBar() {
        guard let bar = actionBar else { return }
        if let owner = actionBarOwner { fadingBar = (owner.id, actionBarRect) }
        actionBar = nil
        actionBarOwner = nil
        bar.disappear { [weak self] in
            self?.fadingBar = nil
            self?.syncHitPanels()
        }
    }

    // MARK: Debugging

    /// Plays a recorded pointer path against the sheet in the slot, as if a hand were on it.
    func runGesture(named name: String) -> Bool {
        if name == "hover" {
            // Rest an imaginary pointer on the sheet for a while, to bring up its actions.
            guard let bounds = controllers.last?.interactiveBounds else { return false }
            pointerOverride = CGPoint(x: bounds.midX, y: bounds.midY)
            pointerDidMove()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.pointerOverride = nil
                self?.pointerDidMove()
            }
            return true
        }
        guard script == nil, mouseOwner == nil, let controller = controllers.last,
              let make = PointerScript.library[name] else { return false }
        script = (PointerScript.Run(script: make(controller.node.size.height), anchor: geometry.anchor), controller)
        requestFrames()
        return true
    }

    private func advanceScript(_ dt: TimeInterval) {
        guard var current = script else { return }
        let finished = current.run.advance(dt, on: current.controller)
        script = finished ? nil : (current.run, current.controller)
    }

    /// Asks the window server which window a click would land on at a few telling points.
    func pointerReport() -> String {
        guard let controller = controllers.last, let bounds = controller.interactiveBounds else { return "no sheet in the slot" }
        let ours = Set(([stagePanel, slotPanel] + Array(hitPanels.values)).map(\.windowNumber))
        let probes: [(String, CGPoint)] = [
            ("paper centre", CGPoint(x: bounds.midX, y: bounds.midY)),
            ("12pt left of paper", CGPoint(x: bounds.minX - 12, y: bounds.midY)),
            ("12pt right of paper", CGPoint(x: bounds.maxX + 12, y: bounds.midY)),
            ("40pt below paper", CGPoint(x: bounds.midX, y: bounds.maxY + 40)),
            ("menu bar beside slot", CGPoint(x: geometry.mouth.maxX + 60, y: 12)),
        ]
        return probes.map { name, point in
            let global = globalRect(fromStage: CGRect(origin: point, size: .zero)).origin
            let number = NSWindow.windowNumber(at: global, belowWindowWithWindowNumber: 0)
            let hit = hitPanels.values.contains { $0.windowNumber == number }
            return "\(name): \(hit ? "sheet takes the click" : (ours.contains(number) ? "BLOCKED by a Notchfax window" : "click passes through"))"
        }.joined(separator: "\n")
    }
}

extension SheetController {
    func performAction(_ action: PaperAction) {
        guard let handle else { return }
        handle.emit(.action(id: action.id))
        action.handler(handle)
    }
}

// MARK: - Hit panels

/// An invisible window kept over one sheet. It exists only to receive the mouse.
final class HitPanel: OverlayPanel {
    let hitView: HitView

    init(stage: Stage, controller: SheetController) {
        hitView = HitView(stage: stage, controller: controller)
        super.init(level: 4)
        // Set explicitly: a clear window otherwise lets clicks fall through its transparent pixels.
        ignoresMouseEvents = false
        contentView = hitView
    }
}

final class HitView: NSView, NSDraggingSource {
    private weak var stage: Stage?
    private weak var controller: SheetController?

    init(stage: Stage, controller: SheetController) {
        self.stage = stage
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) { stage?.pointerDidMove() }
    override func mouseMoved(with event: NSEvent) { stage?.pointerDidMove() }
    override func mouseExited(with event: NSEvent) { stage?.pointerDidMove() }
    override func mouseDown(with event: NSEvent) { stage?.mouseDown(event, on: controller) }
    override func mouseDragged(with event: NSEvent) { stage?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { stage?.mouseUp(event) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        stage?.dragSessionEnded(operation: operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// The row of small buttons that appears under a hovered sheet.
final class ActionBarView: NSView {
    /// Stage-coordinate area that keeps the bar alive while the pointer travels to it.
    var hoverRegion = CGRect.zero
    private let effect = NSVisualEffectView()
    private let host: FirstMouseHostingView<ActionBarContent>

    init(actions: [PaperAction], perform: @escaping (PaperAction) -> Void) {
        host = FirstMouseHostingView(rootView: ActionBarContent(actions: actions, perform: perform))
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        // A floor under the blur, so the labels stay legible over any backdrop.
        effect.layer?.backgroundColor = CGColor(gray: 0.08, alpha: 0.55)
        effect.autoresizingMask = [.width, .height]
        host.autoresizingMask = [.width, .height]
        addSubview(effect)
        addSubview(host)
        shadow = NSShadow()
        layer?.shadowColor = CGColor(gray: 0, alpha: 1)
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var fittingBarSize: CGSize { host.fittingSize }

    override func layout() {
        super.layout()
        effect.layer?.cornerRadius = bounds.height / 2
    }

    func appear() {
        alphaValue = 0
        let target = frame
        frame = target.offsetBy(dx: 0, dy: 5)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            animator().alphaValue = 1
            animator().frame = target
        }
    }

    func disappear(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeFromSuperview()
                completion()
            }
        })
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ActionBarContent: View {
    let actions: [PaperAction]
    let perform: (PaperAction) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(actions) { action in
                ActionChip(action: action) { perform(action) }
            }
        }
        .padding(3)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

private struct ActionChip: View {
    let action: PaperAction
    let perform: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 3.5) {
            if let symbol = action.systemImage {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            }
            Text(action.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(action.role == .destructive ? Color(red: 1, green: 0.47, blue: 0.42) : Color.white.opacity(hovering ? 0.96 : 0.8))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(pressed ? 0.2 : (hovering ? 0.12 : 0))))
        .contentShape(Capsule())
        .scaleEffect(pressed ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { value in
                    pressed = false
                    if abs(value.translation.width) < 12, abs(value.translation.height) < 12 { perform() }
                }
        )
        .accessibilityElement()
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(.isButton)
    }
}
