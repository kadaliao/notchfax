import AppKit
import PrintKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens the compose sheet under the slot, sends it up into the slot, and brings it back
/// out with an explanation when the server says no.
@MainActor
final class ComposeCoordinator {
    private struct Draft {
        var text: String
        var image: DitheredImage?
    }

    private unowned let controller: FaxController
    private var session: (model: ComposeModel, presentation: SlotPresentation)?
    private var drafts: [ComposeTarget: Draft] = [:]
    private var clickMonitor: Any?

    init(controller: FaxController) {
        self.controller = controller
    }

    var isOpen: Bool { session != nil }

    // MARK: Opening

    /// - Parameters:
    ///   - forceImage: debug only; offers the picture button whatever the line's state,
    ///     so the server's own refusal can be exercised.
    ///   - autoSend: debug only; sends by itself after this many seconds.
    func open(
        target: ComposeTarget,
        text: String? = nil,
        image: DitheredImage? = nil,
        error: String? = nil,
        forceImage: Bool = false,
        autoSend: TimeInterval? = nil
    ) {
        guard session == nil else {
            NSSound.beep()
            return
        }
        guard controller.status != .notConfigured else { return }
        let line: Line? = if case .line(let id) = target { controller.store.archive.line(id)?.line } else { nil }
        let draft = drafts.removeValue(forKey: target)
        let model = ComposeModel(
            target: target,
            text: text ?? draft?.text ?? "",
            image: image ?? draft?.image,
            allowsImage: forceImage || (line?.canSendImage ?? false)
        )
        model.alias = line?.peerAlias
        if case .line(let id) = target {
            if let last = controller.store.archive.lastPeerMessage(inLine: id) {
                model.excerpt = Self.excerpt(of: last)
            }
            model.isReply = controller.store.archive.messages(inLine: id).last?.isFromPeer ?? false
        }
        model.quotaLeft = controller.me?.quota.newFaxesLeft
        model.blockedReason = forceImage ? nil : blockedReason(for: target, line: line)
        model.error = error

        let actions = ComposeActions(
            send: { [weak self] in self?.send() },
            cancel: { [weak self] in self?.cancel() },
            chooseImage: { [weak self] in self?.chooseImage() },
            removeImage: { [weak model] in model?.image = nil },
            dropImage: { [weak self] providers in self?.take(providers) ?? false },
            pasteImage: { [weak self] pasteboard in self?.take(pasteboard) ?? false }
        )
        let presentation = controller.printer.present(options: .init(
            chrome: .none,
            acceptsKeyboard: true,
            // A sheet being written should not vanish because the picture panel took a click;
            // clicks in other apps are watched below instead.
            dismissesOnOutsideClick: false,
            dismissesOnEscape: true,
            onDismiss: { [weak self, weak model] in
                guard let self, let model else { return }
                self.didClose(model)
            }
        )) { _ in
            ComposeView(model: model, actions: actions)
        }
        session = (model, presentation)
        installClickMonitor()
        controller.log("compose opened \(target)\(error == nil ? "" : " with error")")
        if error != nil { controller.composeDidShowError(target: target) }
        if let autoSend {
            Task { [weak self, weak model] in
                try? await Task.sleep(for: .seconds(autoSend))
                guard let self, let model, self.session?.model === model else { return }
                self.send()
            }
        }
    }

    func cancel() {
        session?.presentation.dismiss()
    }

    private func didClose(_ model: ComposeModel) {
        if session?.model === model { session = nil }
        removeClickMonitor()
        if !model.isSending, model.hasContent {
            drafts[model.target] = Draft(text: model.text, image: model.image)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            controller.slotDidFree()
        }
    }

    private func blockedReason(for target: ComposeTarget, line: Line?) -> String? {
        if let until = controller.me?.suspendedUntil {
            return "暂停发送，\(FaxFormat.day(Date(unixMilliseconds: until)))恢复"
        }
        switch target {
        case .stranger:
            if controller.me?.quota.newFaxesLeft == 0 { return "今日新传真已发完" }
            return nil
        case .line:
            guard let line else { return "找不到这条线路" }
            switch line.state {
            case .closed: return "线路已挂断"
            case .queued: return "还在寻找收件人"
            case .delivered where line.role == .initiator: return "等对方回复后才能继续写"
            default: return nil
            }
        }
    }

    static func excerpt(of stored: StoredMessage) -> String? {
        switch stored.message.kind {
        case .image:
            return "对方：〔图片〕"
        case .text:
            let flat = (stored.message.text ?? "")
                .split(whereSeparator: \.isNewline)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { return nil }
            return "对方：" + (flat.count > 64 ? String(flat.prefix(64)) + "…" : flat)
        }
    }

    // MARK: Sending

    func send() {
        guard let (model, presentation) = session else { return }
        guard model.canSend else {
            NSSound.beep()
            return
        }
        model.isSending = true
        session = nil
        removeClickMonitor()

        let target = model.target
        let text = model.text
        let image = model.image
        let previousState: LineState? = if case .line(let id) = target { controller.store.archive.line(id)?.line.state } else { nil }
        let sheet = sentSheet(model)
        controller.log("compose send \(target)")

        Task {
            // The request flies while the paper goes in.
            let request = Task { await controller.send(text: text, image: image, to: target) }
            await presentation.feedIntoSlot(sheet, topOffset: ComposeView.paperTop)
            let outcome = await request.value
            if let error = outcome.error {
                let textWentThrough = outcome.sent.contains { $0.message.kind == .text }
                let operation: FaxOperation = switch target {
                case .stranger: .newFax
                case .line: (textWentThrough || ComposeRules.count(text) == 0) && image != nil ? .image : .reply
                }
                let message = error.userMessage(
                    for: operation,
                    resetsAt: controller.me.map { Date(unixMilliseconds: $0.quota.resetsAt) },
                    suspendedUntil: controller.me?.suspendedUntil.map { Date(unixMilliseconds: $0) }
                )
                controller.log("compose comes back out: \(message)")
                // The same sheet comes back out, with what did not go through still on it.
                try? await Task.sleep(for: .milliseconds(250))
                open(target: target, text: textWentThrough ? "" : text, image: image, error: message, forceImage: model.allowsImage)
            } else {
                controller.didSend(outcome, target: target, previousState: previousState)
            }
        }
    }

    /// The written sheet as paper: same size and layout as on screen, printed in thermal ink.
    private func sentSheet(_ model: ComposeModel) -> PaperSheet {
        var size = model.paperSize
        if size.width < 10 || size.height < 10 {
            size = CGSize(width: FaxType.paperWidth, height: 180)
        }
        let header = model.header
        let excerpt = model.excerpt
        let textHeight = model.textAreaHeight
        let image = model.image
        let text = model.text
        let footer = ComposeFooter(model: model).hidden()
        return PaperSheet(.thermal, size: size) {
            ComposeSheetLayout(header: header, excerpt: excerpt, textHeight: textHeight, image: image, footer: footer) {
                Text(text)
                    .font(FaxType.body())
                    .lineSpacing(FaxType.bodySpacing)
                    .foregroundStyle(.black)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Pictures

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选一张图片。它会被转成热敏纸上的黑白点。"
        panel.prompt = "放进传真"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.attach { ImageLoader.load(url: url) } }
        }
    }

    private func take(_ providers: [NSItemProvider]) -> Bool {
        guard let model = session?.model, model.allowsImage else { return false }
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.attach { ImageLoader.load(url: url) } }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor in self?.attach { ImageLoader.load(data: data) } }
            }
            return true
        }
        return false
    }

    private func take(_ pasteboard: NSPasteboard) -> Bool {
        guard let model = session?.model else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        let fileURL = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
        let imageData = pasteboard.string(forType: .string) == nil
            ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff))
            : nil
        guard fileURL != nil || imageData != nil else { return false }
        guard model.allowsImage else {
            model.error = FaxError.message(for: .lineNotConnected, operation: .image, resetsAt: nil, suspendedUntil: nil)
            return true
        }
        if let fileURL {
            attach { ImageLoader.load(url: fileURL) }
        } else if let imageData {
            attach { ImageLoader.load(data: imageData) }
        }
        return true
    }

    /// Loads and dithers off the main thread, then shows the exact dots that will be sent.
    func attach(_ load: @escaping @Sendable () -> CGImage?) {
        guard let model = session?.model else { return }
        model.isPreparingImage = true
        model.error = nil
        Task {
            let result = await Self.prepare(load)
            model.isPreparingImage = false
            switch result {
            case .success(let image):
                model.image = image
                controller.log("image attached \(image.width)x\(image.height) \(image.png.count) bytes")
            case .failure:
                model.error = FaxError.unreadableImage.userMessage(for: .image)
            }
        }
    }

    nonisolated static func prepare(_ load: @Sendable () -> CGImage?) async -> Result<DitheredImage, FaxError> {
        guard let image = load(), let dithered = try? FaxDither.make(from: image) else { return .failure(.unreadableImage) }
        return .success(dithered)
    }

    // MARK: Outside clicks

    private func installClickMonitor() {
        removeClickMonitor()
        guard !controller.launch.script.handsOff else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
