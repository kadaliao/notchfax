import AppKit
import Carbon.HIToolbox
import os
import PrintKit

/// 大头贴: a four-shot photo booth that hangs from the slot and prints a strip.
///
/// Launch arguments, for development:
/// - `--photobooth-simulated`: use the stand-in camera even if a real one exists.
/// - `--photobooth-demo`: open the booth at launch and start shooting.
/// - `--photobooth-look color|mono|warm`: the look to start with.
///
/// Shortcut: ⌃⌥⌘B opens the booth from anywhere.
@MainActor
public final class PhotoBoothFeature: FeatureModule {
    private let printer: Printer
    private let options: LaunchOptions
    private let flash = ScreenFlash()
    private let log = Logger(subsystem: "com.kadaliao.notchfax", category: "photobooth")
    private var hotKey: GlobalHotKey?

    private var presentation: SlotPresentation?
    private var model: BoothViewModel?
    private var session: BoothSession?

    private static let lookKey = "photobooth.look"
    private static let cameraPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")

    struct LaunchOptions {
        var forceSimulated = false
        var demo = false
        var look: BoothLook?

        init(arguments: [String] = ProcessInfo.processInfo.arguments) {
            forceSimulated = arguments.contains("--photobooth-simulated")
            demo = arguments.contains("--photobooth-demo")
            if let index = arguments.firstIndex(of: "--photobooth-look"), index + 1 < arguments.count {
                look = BoothLook(rawValue: arguments[index + 1])
            }
        }
    }

    public init(printer: Printer) {
        self.printer = printer
        options = LaunchOptions()
        printer.menu.addSection(id: "photobooth", order: 20) { [weak self] in
            guard let self else { return [] }
            var entries: [MenuEntry] = [
                .action(
                    "拍大头贴…", systemImage: "camera", isEnabled: self.presentation == nil,
                    shortcut: MenuShortcut("b", modifiers: [.control, .option, .command])
                ) { [weak self] in self?.open() },
            ]
            #if DEBUG
            entries.append(.action("拍大头贴（模拟画面）", systemImage: "hammer", isEnabled: self.presentation == nil) { [weak self] in
                self?.open(simulated: true)
            })
            #endif
            return entries
        }
    }

    public func start() {
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey | controlKey, id: 1) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil { log.notice("The ⌃⌥⌘B shortcut is taken; the booth is only in the menu.") }
        if options.demo {
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                open(autoStart: true)
            }
        }
    }

    private var look: BoothLook {
        get { options.look ?? UserDefaults.standard.string(forKey: Self.lookKey).flatMap(BoothLook.init) ?? .color }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.lookKey) }
    }

    // MARK: Opening and closing

    private func toggle() {
        if let presentation { presentation.dismiss() } else { open() }
    }

    /// Shows the booth at once, then works out which camera to use: the permission
    /// prompt, if any, appears over a booth that is already there.
    func open(autoStart: Bool = false, simulated: Bool = false) {
        guard presentation == nil else { return }
        // Whatever sheet is out is drawn back into the slot by the printer while the booth
        // is open; the new strip then prints before it would come back.

        let model = BoothViewModel(look: look, reduceMotion: printer.reducesMotion)
        self.model = model
        let options = SlotPresentation.Options(
            chrome: .machine,
            acceptsKeyboard: true,
            dismissesOnOutsideClick: false,
            dismissesOnEscape: true,
            onDismiss: { [weak self] in self?.didClose() }
        )
        presentation = printer.present(options: options) { presentation in
            ViewfinderView(
                model: model,
                close: { presentation.dismiss() },
                openSettings: {
                    if let url = Self.cameraPrivacy { NSWorkspace.shared.open(url) }
                    presentation.dismiss()
                }
            )
        }

        Task { [weak self] in
            let camera = await CameraFrameSource.resolve(forceSimulated: simulated || self?.options.forceSimulated ?? false)
            guard let self, self.model === model else { return }
            switch camera {
            case .denied:
                model.stage = .denied
            case .camera, .simulated:
                let session = self.makeSession(camera == .camera ? CameraFrameSource() : SimulatedFrameSource(), model: model)
                self.session = session
                model.stage = .live(session)
                session.open()
                if autoStart { await self.startWhenReady(session) }
            }
        }
    }

    private func makeSession(_ source: any FrameSource, model: BoothViewModel) -> BoothSession {
        let sink = PreviewSink()
        let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let pipeline = FramePipeline(
            aspect: BoothStrip.frameAspect,
            previewSize: CGSize(width: ViewfinderView.previewWidth * scale, height: ViewfinderView.previewHeight * scale),
            sink: sink
        )
        let session = BoothSession(source: source, pipeline: pipeline, sink: sink, look: model.look)
        let printer = printer
        let flash = flash
        let peak: Float = printer.reducesMotion ? 0.3 : 0.78
        session.effects.tick = { printer.sound.play(.tick) }
        session.effects.shutter = { printer.sound.play(.shutter) }
        session.effects.flash = { [weak sink] in flash.fire(on: sink?.screen, peak: peak) }
        session.onFinish = { [weak self] stills, look in self?.finish(stills, look: look) }
        session.onAbandon = { [weak self] in self?.presentation?.dismiss() }
        return session
    }

    private func startWhenReady(_ session: BoothSession) async {
        var waited = 0
        while session.phase == .starting, waited < 100 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        try? await Task.sleep(for: .milliseconds(700))
        session.begin()
    }

    /// However the booth closes (Esc, ✕, the shortcut, finishing), the camera goes off.
    private func didClose() {
        if let model { look = model.look }
        session?.cancel()
        session = nil
        model = nil
        presentation = nil
    }

    // MARK: Printing

    private func finish(_ stills: [CGImage], look: BoothLook) {
        self.look = look
        let date = Date()
        presentation?.dismiss()
        Task { [weak self] in
            // Develop while the viewfinder slides back into the slot, then feed the strip
            // out of the same slot.
            async let developed = BoothStrip.develop(stills, look: look)
            try? await Task.sleep(for: .milliseconds(520))
            let strip = await developed
            guard let self else { return }
            self.printer.enqueue(BoothStrip.job(strip, date: date))
        }
    }
}
