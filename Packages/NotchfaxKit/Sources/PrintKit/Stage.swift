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
/// Three windows, back to front: anchored presentations, the slot (drawn mouth), and
/// the stage. The stage covers the whole screen but ignores the mouse unless the
/// pointer is actually over paper, so everything beneath stays clickable.
@MainActor
final class Stage: NSObject {
    private(set) var geometry: SlotGeometry
    let sound: SoundPlayer
    var simulatesNotch = false { didSet { if oldValue != simulatesNotch { relayout() } } }
    var onSlotFree: ((SheetController) -> Void)?
    var onGeometryChange: (() -> Void)?

    private(set) var screen: NSScreen?
    private let slotPanel = OverlayPanel(level: 2)
    private let stagePanel = OverlayPanel(level: 3)
    private let stageView = StageView()
    private let slotLayer = CALayer()
    private let clipLayer = CALayer()
    private let freeLayer = CALayer()

    private var controllers: [SheetController] = []
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var housekeeping: Timer?
    private var monitors: [Any] = []
    private weak var mouseOwner: SheetController?
    private weak var dragSessionOwner: SheetController?
    private var actionBar: ActionBarView?
    private weak var actionBarOwner: SheetController?
    private var isStarted = false

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
        stagePanel.contentView = stageView
        stageView.stage = self
        stageView.canvas.layer?.addSublayer(clipLayer)
        stageView.canvas.layer?.addSublayer(freeLayer)
        clipLayer.masksToBounds = true
    }

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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
        }
    }

    // MARK: Sheets

    func add(_ controller: SheetController) {
        controllers.append(controller)
        if controllers.count == 1 {
            stagePanel.orderFrontRegardless()
            startWatchingPointer()
        }
        requestFrames()
    }

    func remove(_ controller: SheetController) {
        controllers.removeAll { $0 === controller }
        if actionBarOwner === controller || actionBarOwner == nil { hideActionBar() }
        if controllers.isEmpty {
            stopWatchingPointer()
            stagePanel.ignoresMouseEvents = true
            stagePanel.orderOut(nil)
        }
    }

    func place(_ node: SheetNode, clipped: Bool) {
        let target = clipped ? clipLayer : freeLayer
        guard node.root.superlayer !== target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.addSublayer(node.root)
        CATransaction.commit()
    }

    func slotDidFree(_ controller: SheetController) {
        onSlotFree?(controller)
    }

    func sheetStateDidChange() {
        pointerDidMove()
        requestFrames()
    }

    func cancelAll() {
        controllers.forEach { $0.cancel() }
    }

    // MARK: Frame clock

    func requestFrames() {
        guard link == nil, !controllers.isEmpty else { return }
        lastTimestamp = nil
        let link = stageView.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        let dt = lastTimestamp.map { min(1.0 / 30, max(1.0 / 240, link.timestamp - $0)) } ?? 1.0 / 60
        lastTimestamp = link.timestamp
        var active = false
        for controller in controllers where controller.needsFrames {
            controller.tick(dt)
            active = active || controller.needsFrames
        }
        layoutActionBar()
        if !active {
            link.invalidate()
            self.link = nil
        }
    }

    // MARK: Pointer

    private func startWatchingPointer() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerDidMove() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerDidMove() }
            return event
        }) {
            monitors.append(local)
        }
        // Paper also moves under a stationary pointer, and idle timers need a clock.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeepingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer
    }

    private func stopWatchingPointer() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        housekeeping?.invalidate()
        housekeeping = nil
    }

    private func housekeepingTick() {
        pointerDidMove()
        for controller in controllers { controller.housekeeping(0.1) }
        if controllers.contains(where: \.needsFrames) { requestFrames() }
    }

    func stagePoint(fromGlobal point: CGPoint) -> CGPoint {
        let frame = stagePanel.frame
        return CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
    }

    /// Decides whether the stage should intercept the mouse, and who is hovered.
    func pointerDidMove() {
        guard !controllers.isEmpty else { return }
        if dragSessionOwner != nil {
            stagePanel.ignoresMouseEvents = true
            return
        }
        if mouseOwner != nil {
            stagePanel.ignoresMouseEvents = false
            return
        }
        let point = stagePoint(fromGlobal: NSEvent.mouseLocation)
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
        stagePanel.ignoresMouseEvents = owner == nil
        updateActionBar(for: owner)
        if changed || hit != nil { requestFrames() }
    }

    fileprivate func mouseDown(_ event: NSEvent) {
        let point = stagePoint(fromGlobal: NSEvent.mouseLocation)
        guard let controller = controllers.last(where: { $0.hitTest(point) }) else { return }
        mouseOwner = controller
        controller.mouseDown(at: point, time: event.timestamp)
        requestFrames()
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        guard let controller = mouseOwner else { return }
        controller.mouseDragged(to: stagePoint(fromGlobal: NSEvent.mouseLocation), time: event.timestamp, event: event)
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        guard let controller = mouseOwner else { return }
        mouseOwner = nil
        controller.mouseUp(at: stagePoint(fromGlobal: NSEvent.mouseLocation), time: event.timestamp)
        pointerDidMove()
    }

    fileprivate func wantsMouse(at point: CGPoint) -> Bool {
        mouseOwner != nil || controllers.contains { $0.hitTest(point) }
    }

    // MARK: Drag-out

    func beginDragSession(for controller: SheetController, event: NSEvent) {
        guard dragSessionOwner == nil, let url = controller.exportFileURL() else { return }
        let frame = controller.dragFrame
        let height = stagePanel.frame.height
        let viewFrame = CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(viewFrame, contents: NSImage(cgImage: controller.dragImage, size: frame.size))
        dragSessionOwner = controller
        mouseOwner = nil
        controller.dragSessionDidBegin()
        hideActionBar()
        stagePanel.ignoresMouseEvents = true
        let session = stageView.beginDraggingSession(with: [item], event: event, source: stageView)
        session.animatesToStartingPositionsOnCancelOrFail = false
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
            if actionBarOwner != nil, owner == nil || owner?.showsActions == false { hideActionBar() }
            return
        }
        guard actionBarOwner !== owner else { return }
        hideActionBar()
        let bar = ActionBarView(actions: owner.job.actions) { [weak owner] action in
            guard let owner else { return }
            owner.performAction(action)
        }
        stageView.addSubview(bar)
        actionBar = bar
        actionBarOwner = owner
        layoutActionBar()
        bar.appear()
    }

    private func layoutActionBar() {
        guard let bar = actionBar, let owner = actionBarOwner else { return }
        if !owner.showsActions {
            hideActionBar()
            return
        }
        let bottom = owner.bottomCentre
        let size = bar.fittingBarSize
        let top = bottom.y + 9
        let height = stagePanel.frame.height
        let x = min(max(8, bottom.x - size.width / 2), stagePanel.frame.width - size.width - 8)
        bar.frame = CGRect(x: x.rounded(), y: (height - top - size.height).rounded(), width: size.width, height: size.height)
        bar.hoverRegion = CGRect(x: x - 10, y: bottom.y - 4, width: size.width + 20, height: size.height + 9 + 12)
    }

    private func hideActionBar() {
        actionBar?.disappear()
        actionBar = nil
        actionBarOwner = nil
    }
}

extension SheetController {
    func performAction(_ action: PaperAction) {
        guard let handle else { return }
        handle.emit(.action(id: action.id))
        action.handler(handle)
    }
}

// MARK: - Views

/// The stage's content view. Holds a layer-hosting canvas for paper and, above it,
/// ordinary subviews for the action bar.
final class StageView: NSView, NSDraggingSource {
    weak var stage: Stage?
    let canvas = NSView()

    init() {
        super.init(frame: .zero)
        canvas.layer = CALayer()
        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for view in subviews.reversed() where view !== canvas {
            if let hit = view.hitTest(convert(point, from: superview)) { return hit }
        }
        guard let stage else { return nil }
        let local = convert(point, from: superview)
        let stagePoint = CGPoint(x: local.x, y: bounds.height - local.y)
        return stage.wantsMouse(at: stagePoint) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { stage?.mouseDown(event) }
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

    func disappear() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
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
