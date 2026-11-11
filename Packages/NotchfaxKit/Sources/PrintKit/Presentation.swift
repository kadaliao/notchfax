import AppKit
import Observation
import SwiftUI

/// A SwiftUI view hanging from the slot as if it were part of the machine.
/// Created by `Printer.present`.
@MainActor
public final class SlotPresentation {
    public struct Options {
        public enum Chrome: Sendable {
            /// A black body that grows out of the notch, with the content inside it.
            case machine
            /// No background; the content draws everything itself.
            case none
        }

        public var chrome: Chrome
        /// Lets the panel take keyboard input (text fields) without activating the app.
        public var acceptsKeyboard: Bool
        public var dismissesOnOutsideClick: Bool
        public var dismissesOnEscape: Bool
        /// Called once, however the presentation ends.
        public var onDismiss: (@MainActor () -> Void)?

        public init(
            chrome: Chrome = .machine,
            acceptsKeyboard: Bool = false,
            dismissesOnOutsideClick: Bool = true,
            dismissesOnEscape: Bool = true,
            onDismiss: (@MainActor () -> Void)? = nil
        ) {
            self.chrome = chrome
            self.acceptsKeyboard = acceptsKeyboard
            self.dismissesOnOutsideClick = dismissesOnOutsideClick
            self.dismissesOnEscape = dismissesOnEscape
            self.onDismiss = onDismiss
        }
    }

    public private(set) var isPresented = false

    private weak var printer: Printer?
    private let stage: Stage
    private let options: Options
    private let model = PresentationModel()
    private let panel: PresentationPanel
    private var host: NSHostingView<PresentationRoot>?
    private var monitors: [Any] = []
    private var closeTask: Task<Void, Never>?

    init(printer: Printer, stage: Stage, options: Options) {
        self.printer = printer
        self.stage = stage
        self.options = options
        panel = PresentationPanel(level: 1)
        panel.allowsKey = options.acceptsKeyboard
        panel.level = stage.presentationLevel
    }

    // MARK: Public

    /// Slides the presentation back up into the slot.
    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        stopMonitoring()
        model.isShown = false
        let callback = options.onDismiss
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard let self else { return }
            self.panel.orderOut(nil)
            self.host = nil
            self.panel.contentView = nil
            self.printer?.presentationDidClose(self)
        }
        callback?()
    }

    /// Sends a sheet up into the slot from where it sits inside this presentation, then
    /// dismisses. The rest of the content fades away as the paper starts to move.
    ///
    /// - Parameter topOffset: distance from the top of the content to the top edge of
    ///   the paper being sent. The sheet is assumed to be centred under the slot.
    public func feedIntoSlot(_ sheet: PaperSheet, topOffset: CGFloat = 0) async {
        guard let printer else { return }
        let gap = model.topInset + topOffset - stage.geometry.slotLineY
        withAnimation(.easeOut(duration: 0.16)) { model.contentOpacity = 0 }
        let feeding = Task { await printer.feedIntoSlot(sheet, startingBelowSlot: gap) }
        try? await Task.sleep(for: .milliseconds(140))
        dismiss()
        await feeding.value
    }

    // MARK: Internal

    func show(_ content: AnyView) {
        model.chrome = options.chrome
        model.topInset = stage.geometry.mouth.maxY + (options.chrome == .machine ? 6 : 4)
        model.reduceMotion = stage.reduceMotion
        let host = NSHostingView(rootView: PresentationRoot(model: model, content: content) { [weak self] in
            self?.reposition()
        })
        self.host = host
        panel.contentView = host
        panel.onCancel = { [weak self] in
            guard let self, self.options.dismissesOnEscape else { return }
            self.dismiss()
        }
        reposition()
        isPresented = true
        if options.acceptsKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        startMonitoring()
        // One runloop turn so the hidden state is on screen before it animates in.
        Task { [model] in model.isShown = true }
    }

    func reposition() {
        guard let host, let screen = stage.screen else { return }
        model.topInset = stage.geometry.mouth.maxY + (options.chrome == .machine ? 6 : 4)
        let size = host.fittingSize
        let frame = screen.frame
        let x = frame.minX + stage.geometry.centerX - size.width / 2
        panel.setFrame(CGRect(x: x.rounded(), y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    private func startMonitoring() {
        guard options.dismissesOnOutsideClick else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                // Clicks on paper or on other machine panels are part of the same surface.
                if !(event.window is OverlayPanel) { self?.dismiss() }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

final class PresentationPanel: OverlayPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
@Observable
final class PresentationModel {
    var isShown = false
    var contentOpacity = 1.0
    var topInset: CGFloat = 0
    var chrome: SlotPresentation.Options.Chrome = .machine
    var reduceMotion = false
}

struct PresentationRoot: View {
    let model: PresentationModel
    let content: AnyView
    let sizeChanged: () -> Void
    @State private var height: CGFloat = 400

    var body: some View {
        content
            .opacity(model.contentOpacity)
            .padding(.top, model.topInset)
            .background {
                if model.chrome == .machine {
                    MachineBody()
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { height = proxy.size.height }
                        .onChange(of: proxy.size) { _, new in
                            height = new.height
                            sizeChanged()
                        }
                }
            }
            .offset(y: model.reduceMotion || model.isShown ? 0 : -(height + 30))
            .opacity(model.reduceMotion && !model.isShown ? 0 : 1)
            .animation(model.isShown ? .spring(response: 0.46, dampingFraction: 0.84) : .spring(response: 0.36, dampingFraction: 1), value: model.isShown)
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
            .fixedSize()
    }
}

/// The black body a presentation sits in: flush with the top of the screen, like the notch grown larger.
struct MachineBody: View {
    var body: some View {
        MachineShape(radius: 20, ear: 8)
            .fill(Color.black)
            .overlay {
                MachineShape(radius: 20, ear: 8)
                    .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.32), radius: 14, y: 8)
    }
}

struct MachineShape: Shape {
    var radius: CGFloat
    var ear: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - ear, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + ear), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + ear, y: rect.minY), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
