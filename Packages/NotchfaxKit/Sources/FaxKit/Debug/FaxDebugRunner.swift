import AppKit
import PrintKit

/// Scripted actions for unattended end-to-end runs. Everything goes through the same UI
/// paths a person would use: the compose sheet, the paper's actions, the menu.
///
/// - `--fax-debug-send <text>`: once online, write a new fax and send it.
/// - `--fax-debug-auto-reply <text>` (+ `--fax-debug-reply-delay <s>`, default 6): after the
///   first page of a new line has printed here, press 回复 on it and send this text.
/// - `--fax-debug-early-image <s>`: that many seconds after sending a new fax, try to send a
///   picture on the still-unconnected line (the server must refuse it).
/// - `--fax-debug-image-on-connect <s>`: when a line this Mac started gets its reply, send a
///   picture (`--fax-debug-image <path>`, else a generated one) with
///   `--fax-debug-image-caption <text>`.
/// - `--fax-debug-tear-after-image <s>`: after a picture has printed here, press 撕掉 on it.
/// - `--fax-debug-show-menu <s>`: pop the menu-bar menu up on screen for a screenshot.
/// - `--fax-debug-confirm-report <s>`: after a page has printed, press 举报 on it (the
///   confirmation is shown, never answered).
/// - `--fax-debug-hands-off`: pages show no action bar and ignore the pointer, and the compose
///   sheet ignores clicks in other apps, so stray clicks from other automation change nothing.
/// - `--fax-debug-log <file>`: a plain-text trail of what happened (no message text, no tokens).
struct FaxDebugScript: Sendable, Equatable {
    var sendText: String?
    var autoReplyText: String?
    var autoReplyDelay: TimeInterval = 6
    var earlyImageDelay: TimeInterval?
    var imageOnConnectDelay: TimeInterval?
    var imagePath: String?
    var imageCaption: String?
    var tearAfterImageDelay: TimeInterval?
    var showMenuAfter: TimeInterval?
    var confirmReportAfter: TimeInterval?
    /// Pages carry no actions and ignore the pointer, and the compose sheet ignores clicks
    /// elsewhere: for runs on a screen that other automation is clicking on.
    var handsOff = false
    var logPath: String?

    var isActive: Bool {
        sendText != nil || autoReplyText != nil || earlyImageDelay != nil || imageOnConnectDelay != nil
            || tearAfterImageDelay != nil || showMenuAfter != nil || confirmReportAfter != nil
    }
}

@MainActor
final class FaxDebugRunner {
    private let script: FaxDebugScript
    private unowned let controller: FaxController
    private var didSendFirst = false
    private var didTryEarlyImage = false
    private var didShowMenu = false
    private var askedToReport = false
    private var replied: Set<String> = []
    private var sentPicture: Set<String> = []
    private var tore: Set<String> = []

    init(script: FaxDebugScript, controller: FaxController) {
        self.script = script
        self.controller = controller
    }

    func statusChanged(_ status: ConnectionStatus) {
        guard status == .online else { return }
        if let text = script.sendText, !didSendFirst {
            didSendFirst = true
            after(2) { [controller] in
                controller.log("debug: composing a new fax")
                controller.composer.open(target: .stranger, text: text, autoSend: 1.8)
            }
        }
        if let delay = script.showMenuAfter, !didShowMenu {
            didShowMenu = true
            after(delay) { [weak self] in self?.showMenu() }
        }
    }

    func didSend(_ outcome: FaxController.SendOutcome, target: ComposeTarget) {
        guard target == .stranger, let line = outcome.sent.last?.line, let delay = script.earlyImageDelay, !didTryEarlyImage else { return }
        didTryEarlyImage = true
        after(delay) { [weak self] in
            guard let self else { return }
            self.controller.log("debug: trying a picture before the line is connected")
            self.withPicture { picture in
                self.controller.composer.open(target: .line(line.id), image: picture, forceImage: true, autoSend: 1.8)
            }
        }
    }

    func composeShowedError(target: ComposeTarget) {
        // Leave the explanation up long enough to be seen, then tidy away.
        after(6) { [controller] in controller.composer.cancel() }
    }

    func didPrint(_ stored: StoredMessage, line: Line, handle: PrintHandle) {
        if let delay = script.confirmReportAfter, !askedToReport {
            askedToReport = true
            after(delay) { [controller] in
                controller.log("debug: asking whether to report")
                controller.confirmReport(lineId: line.id, handle: handle)
            }
        }
        if let reply = script.autoReplyText, line.role == .recipient, line.state == .delivered, !replied.contains(line.id) {
            replied.insert(line.id)
            // Both test instances share one slot on screen: clear it while the other side acts.
            after(min(5, script.autoReplyDelay)) { handle.retract() }
            after(script.autoReplyDelay) { [controller] in
                controller.log("debug: replying from the paper")
                controller.replyFromPaper(lineId: line.id, handle: handle, text: reply, autoSend: 1.8)
            }
        }
        if let delay = script.imageOnConnectDelay, line.role == .initiator, line.state == .connected,
           stored.message.kind == .text, !sentPicture.contains(line.id) {
            sentPicture.insert(line.id)
            after(delay) { [weak self] in
                guard let self else { return }
                self.controller.log("debug: sending a picture on the connected line")
                handle.retract()
                self.withPicture { picture in
                    self.controller.composer.open(
                        target: .line(line.id), text: self.script.imageCaption ?? "", image: picture, autoSend: 2.4
                    )
                }
            }
        }
        if let delay = script.tearAfterImageDelay, stored.message.kind == .image, !tore.contains(line.id) {
            tore.insert(line.id)
            after(delay) { [controller] in
                controller.log("debug: tearing the line from the paper")
                controller.tear(lineId: line.id, handle: handle, report: false)
            }
        }
    }

    // MARK: Helpers

    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    private func withPicture(_ use: @escaping @MainActor (DitheredImage) -> Void) {
        let path = script.imagePath
        Task {
            let result = await ComposeCoordinator.prepare {
                if let path { return ImageLoader.load(url: URL(fileURLWithPath: path)) }
                return PrintSamples.landscape(width: 960, height: 720, variant: 2)
            }
            switch result {
            case .success(let picture):
                controller.log("debug: picture ready \(picture.width)x\(picture.height) \(picture.png.count) bytes")
                use(picture)
            case .failure(let error):
                controller.log("debug: picture failed \(error)")
            }
        }
    }

    /// Pops the menu-bar menu up near the top of the screen and closes it a few seconds later.
    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        MenuEntry.menuItems(for: controller.printer.menu.entries()).forEach(menu.addItem)
        guard let screen = NSScreen.main else { return }
        let point = NSPoint(x: screen.frame.midX + 140, y: screen.frame.maxY - 30)
        Task {
            // The main queue keeps draining while the menu tracks, so this still runs.
            try? await Task.sleep(for: .seconds(7))
            menu.cancelTracking()
        }
        controller.log("debug: showing the menu")
        menu.popUp(positioning: nil, at: point, in: nil)
    }
}
