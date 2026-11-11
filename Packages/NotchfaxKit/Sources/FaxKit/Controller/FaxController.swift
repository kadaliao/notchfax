import AppKit
import PrintKit
import SwiftUI

/// The fax feature's brain: identity, connection, store, printing, composing and the menu.
@MainActor
final class FaxController {
    let printer: Printer
    let launch: FaxLaunchOptions
    let environment: FaxEnvironment
    let store: FaxStore
    let log: FaxLog

    private(set) var status: ConnectionStatus
    private(set) var me: Me?
    private(set) var api: FaxAPI?
    private var connection: FaxConnection?
    private var monitors: SystemMonitors?
    private(set) lazy var printQueue = FaxPrintQueue(controller: self)
    private(set) lazy var notices = NoticeCenter(controller: self)
    private(set) lazy var composer = ComposeCoordinator(controller: self)
    private var debug: FaxDebugRunner?

    /// Lines whose next printed page should say the line has just connected.
    private var announceConnectionOnPage: Set<String> = []
    /// A connection notice waits briefly in case the reply that caused it is about to print.
    private var pendingConnectNotices: [String: Task<Void, Never>] = [:]
    private var downloads: Set<String> = []
    private var catchingUp = false

    init(printer: Printer, launch: FaxLaunchOptions) {
        self.printer = printer
        self.launch = launch
        environment = FaxEnvironment.make(launch: launch)
        store = FaxStore(directory: environment.directory)
        log = FaxLog(path: launch.script.logPath, profile: launch.profile)
        status = environment.server == nil ? .notConfigured : .connecting
        if launch.script.isActive { debug = FaxDebugRunner(script: launch.script, controller: self) }
    }

    // MARK: Lifecycle

    func start() {
        guard let server = environment.server else {
            log("no server configured")
            return
        }
        log("starting; server \(server.absoluteString); profile \(environment.profile ?? "default")")
        prune()
        let keyStore = environment.keyStore
        monitors = SystemMonitors(
            onSleep: { [weak self] in self?.pauseConnection(.sleeping) },
            onWake: { [weak self] in self?.resumeConnection(.sleeping) },
            onNetwork: { [weak self] available, _ in
                if available { self?.resumeConnection(.offline) } else { self?.pauseConnection(.offline) }
            }
        )
        // The key is read lazily by the API, off the main thread, the first time a session
        // is needed: launching never touches the key store by itself.
        let api = FaxAPI(
            baseURL: server,
            identity: { try DeviceIdentity.loadOrCreate(from: keyStore) },
            transport: URLSessionTransport(session: URLSessionTransport.makeSession())
        )
        self.api = api
        let connection = FaxConnection(authority: api)
        self.connection = connection
        Task {
            for await output in connection.outputs { self.handle(output) }
        }
        Task {
            await connection.start()
            // Anything received before a quit but never printed comes out now.
            for pending in store.archive.pendingPrints { schedulePrint(pending) }
        }
    }

    private func pauseConnection(_ reason: ConnectionMachine.Pauses) {
        log("pause: \(reason == .sleeping ? "sleep" : "offline")")
        Task { await connection?.pause(reason) }
    }

    private func resumeConnection(_ reason: ConnectionMachine.Pauses) {
        log("resume: \(reason == .sleeping ? "wake" : "online")")
        Task { await connection?.resume(reason) }
    }

    func reconnect() {
        Task { await connection?.reconnectNow() }
    }

    private func setStatus(_ new: ConnectionStatus) {
        guard new != status else { return }
        status = new
        log("status \(new)")
        debug?.statusChanged(new)
    }

    private func prune() {
        let dropped = store.update { $0.prune(now: Date().unixMilliseconds) }
        store.removeImages(dropped)
    }

    // MARK: Incoming

    private func handle(_ output: FaxConnection.Output) {
        switch output {
        case .status(let status):
            setStatus(status)
        case .opened:
            Task { await catchUp() }
        case .event(.fax(let line, let message)):
            log("socket fax \(message.kind.rawValue) \(message.id) line \(line.id) \(line.state.rawValue)")
            receive(message, line: line, origin: .live)
        case .event(.lineUpdated(let line)):
            log("socket line.updated \(line.id) \(line.state.rawValue)")
            apply(line, origin: .live)
        case .event(.pong), .event(.unknown):
            break
        }
    }

    enum Origin { case live, catchUp, local }

    /// After every connect: missed messages, line states, quota, unfinished acks.
    private func catchUp() async {
        guard let api, !catchingUp else { return }
        catchingUp = true
        defer { catchingUp = false }
        if let device = await api.deviceId { log("device \(device)") }
        do {
            let inbox = try await api.inbox()
            log("inbox: \(inbox.messages.count) message(s), \(inbox.lines.count) line(s)")
            for line in inbox.lines { apply(line, origin: .catchUp) }
            for message in inbox.messages {
                receive(message, line: inbox.lines.first { $0.id == message.lineId }, origin: .catchUp)
            }
        } catch {
            log("inbox failed: \(error)")
        }
        do {
            let open = try await api.lines()
            let changes = store.update { $0.reconcile(openLines: open, at: Date().unixMilliseconds) }
            for change in changes { lineDidChange(change, origin: .catchUp) }
        } catch {
            log("lines failed: \(error)")
        }
        await refreshMe()
        for printed in store.archive.pendingAcks { acknowledge(printed.id) }
        for pending in store.archive.pendingPrints { schedulePrint(pending) }
    }

    func refreshMe() async {
        guard let api else { return }
        do {
            me = try await api.me()
        } catch {
            log("me failed: \(error)")
        }
    }

    private func receive(_ message: Message, line: Line?, origin: Origin) {
        var change: FaxArchive.LineChange?
        if let line { change = store.update { $0.upsert(line, at: Date().unixMilliseconds) } }
        // A reply that connects a line arrives right after `line.updated`: fold the news into the page.
        if let pending = pendingConnectNotices.removeValue(forKey: message.lineId) {
            pending.cancel()
            announceConnectionOnPage.insert(message.lineId)
        }
        switch store.update({ $0.ingest(message, at: Date().unixMilliseconds) }) {
        case .duplicate:
            if let stored = store.archive.message(message.id) {
                if stored.status == .pending { schedulePrint(stored) }
                if stored.status == .printed { acknowledge(stored.id) }
            }
        case .new(let stored):
            log("received \(stored.message.kind.rawValue) \(stored.id) (\(origin))")
            if stored.isFromPeer { schedulePrint(stored) }
        }
        if let change { lineDidChange(change, origin: origin, withPage: true) }
    }

    /// A line state from the server, on its own.
    func apply(_ line: Line, origin: Origin) {
        if let change = store.update({ $0.upsert(line, at: Date().unixMilliseconds) }) {
            lineDidChange(change, origin: origin)
        }
    }

    private func lineDidChange(_ change: FaxArchive.LineChange, origin: Origin, withPage: Bool = false) {
        let line = change.line
        log("line \(line.id) \(change.previous?.rawValue ?? "new") → \(line.state.rawValue)")
        guard let previous = change.previous, previous != line.state, origin != .local else { return }
        let alias = line.peerAlias ?? "····"
        switch line.state {
        case .connected:
            if withPage || origin == .catchUp {
                announceConnectionOnPage.insert(line.id)
                return
            }
            // `line.updated` comes first and the reply right after; wait a moment for it.
            pendingConnectNotices[line.id]?.cancel()
            pendingConnectNotices[line.id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self else { return }
                self.pendingConnectNotices[line.id] = nil
                self.notices.show(FaxNotice(kind: .connected, title: "线路 #\(alias) 已接通", detail: "现在可以互发图片了", key: line.id))
            }
        case .delivered where previous == .queued:
            notices.show(FaxNotice(kind: .delivered, title: "传真已送达", detail: "线路 #\(alias) · 对方回复后就会接通", key: line.id))
        case .closed:
            pendingConnectNotices.removeValue(forKey: line.id)?.cancel()
            notices.show(FaxNotice(kind: .closed, title: "线路 #\(alias) 已挂断", detail: nil, key: line.id))
        default:
            break
        }
    }

    // MARK: Printing

    private func schedulePrint(_ stored: StoredMessage) {
        guard stored.isFromPeer, stored.status == .pending else { return }
        if stored.message.kind == .image, stored.imageFile == nil {
            download(stored)
        } else {
            printQueue.enqueue(stored.id)
        }
    }

    private func download(_ stored: StoredMessage) {
        guard let api, let imageId = stored.message.imageId, !downloads.contains(stored.id) else { return }
        downloads.insert(stored.id)
        Task {
            defer { downloads.remove(stored.id) }
            do {
                let data = try await api.image(id: imageId)
                guard ImageLoader.load(data: data) != nil else { throw FaxError.unreadableImage }
                let file = try store.writeImage(data, name: stored.id)
                store.update { $0.setImageFile(file, for: stored.id) }
                log("downloaded image \(stored.id) (\(data.count) bytes)")
                printQueue.enqueue(stored.id)
            } catch {
                log("image download failed \(stored.id): \(error)")
            }
        }
    }

    /// The print job for a stored message, built when it reaches the front of the queue so
    /// it reflects the line as it is now.
    func makeJob(for id: String, copy: Bool = false) -> (job: PrintJob, readingTime: TimeInterval)? {
        guard let stored = store.archive.message(id) else { return nil }
        let lineId = stored.message.lineId
        let line = store.archive.line(lineId)?.line
        let body: FaxPageModel.Body
        switch stored.message.kind {
        case .text:
            body = .text(stored.message.text ?? "")
        case .image:
            guard let file = stored.imageFile, let data = store.readImage(file), let image = ImageLoader.load(data: data) else { return nil }
            body = .image(image)
        }
        var footer: String?
        if let line {
            if line.state == .closed {
                footer = "线路已挂断"
            } else if !copy, announceConnectionOnPage.remove(lineId) != nil {
                footer = "对方回复了，线路已接通 · 现在可以互发图片"
            } else if line.state == .delivered, line.role == .recipient {
                footer = "一位陌生人发来的 · 回复后线路接通，就能互发图片"
            } else if line.state == .connected {
                footer = "线路已接通"
            }
        }
        let model = FaxPageModel(
            time: Date(unixMilliseconds: stored.message.sentAt),
            alias: line?.peerAlias,
            page: store.archive.page(of: id),
            body: body,
            footer: footer,
            isCopy: copy,
            byline: stored.isFromPeer ? nil : "我发出的"
        )
        let sheet = model.sheet(maxPaperWidth: printer.slot.maxPaperWidth)
        let reveal: PrintJob.Reveal
        var cadence: FeedCadence?
        let readingTime: TimeInterval
        switch body {
        case .text(let text):
            reveal = .progressive(lineHeight: FaxType.lineHeight)
            readingTime = min(14, 5 + Double(text.count) * 0.06)
        case .image:
            // A picture prints in fine, quick bands rather than line by line.
            let fit = printer.slot.fittingScale(forPaperWidth: FaxType.imagePaperWidth)
            reveal = .progressive(lineHeight: 6)
            cadence = FeedCadence(stepLength: 6 * Double(fit), stepDuration: 0.03, dwell: 0.022, variation: 0.3)
            readingTime = 12
        }
        let open = line?.isOpen ?? false
        var actions: [PaperAction] = []
        if open, line?.canSendText == true {
            actions.append(PaperAction(id: "reply", title: "回复", systemImage: "arrowshape.turn.up.left.fill") { [weak self] handle in
                self?.log("paper action: reply")
                self?.replyFromPaper(lineId: lineId, handle: handle)
            })
        }
        actions.append(PaperAction(id: "tear", title: "撕掉", systemImage: "scissors") { [weak self] handle in
            self?.log("paper action: tear")
            self?.tear(lineId: lineId, handle: handle, report: false)
        })
        if open {
            actions.append(PaperAction(id: "report", title: "举报", systemImage: "exclamationmark.bubble.fill", role: .destructive) { [weak self] handle in
                self?.log("paper action: report")
                self?.confirmReport(lineId: lineId, handle: handle)
            })
        }
        let handsOff = launch.script.handsOff
        let job = PrintJob(
            sheet,
            reveal: reveal,
            cadence: cadence,
            autoRetract: .after(max(20, readingTime + 10)),
            interaction: handsOff ? [] : .all,
            actions: handsOff ? [] : actions
        )
        return (job, readingTime)
    }

    /// Called once a page has come out (or failed to).
    func pageDidPrint(_ id: String, fed: Bool, handle: PrintHandle) {
        guard fed else {
            log("print interrupted \(id)")
            return
        }
        guard let stored = store.archive.message(id) else { return }
        log("printed \(stored.message.kind.rawValue) \(id)")
        if stored.status == .pending {
            store.update { $0.markPrinted(id) }
            acknowledge(id)
        }
        if let line = store.archive.line(stored.message.lineId)?.line {
            debug?.didPrint(stored, line: line, handle: handle)
        }
    }

    private func acknowledge(_ id: String) {
        guard let api else { return }
        Task {
            do {
                try await api.ack(messageId: id)
                store.update { $0.markAcknowledged(id) }
                log("acked \(id)")
            } catch {
                log("ack failed \(id): \(error)")
            }
        }
    }

    /// Prints the latest page of a line again, marked as a copy.
    func reprint(lineId: String) {
        let pages = store.archive.messages(inLine: lineId)
        guard let page = pages.last(where: { $0.message.kind == .text || $0.imageFile != nil }) else { return }
        printQueue.enqueueCopy(page.id)
    }

    // MARK: Line actions

    /// The page goes back into the slot and a fresh sheet comes out to write on.
    func replyFromPaper(lineId: String, handle: PrintHandle?, text: String? = nil, autoSend: TimeInterval? = nil) {
        handle?.retract()
        Task {
            if let handle {
                // Wait for the page to clear the slot, but not for long.
                for _ in 0..<12 {
                    if case .finished = handle.state { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            composer.open(target: .line(lineId), text: text, autoSend: autoSend)
        }
    }

    func tear(lineId: String, handle: PrintHandle?, report: Bool) {
        handle?.tearOff()
        guard let api else { return }
        log("\(report ? "report" : "tear") line \(lineId)")
        Task {
            do {
                let line = try await api.tear(lineId: lineId, report: report)
                apply(line, origin: .local)
                log("line \(lineId) closed by me")
            } catch let error as FaxError {
                log("tear failed: \(error)")
                if error.code == .notFound {
                    var closed = store.archive.line(lineId)?.line
                    closed?.state = .closed
                    if let closed { apply(closed, origin: .local) }
                } else {
                    notices.show(FaxNotice(kind: .problem, title: "没有挂断", detail: error.userMessage(for: report ? .report : .tear), key: "tear-\(lineId)"))
                }
            } catch {}
        }
    }

    private var reportPresentation: SlotPresentation?

    func confirmReport(lineId: String, handle: PrintHandle?) {
        guard reportPresentation == nil else { return }
        let alias = store.archive.line(lineId)?.line.peerAlias ?? "····"
        reportPresentation = printer.present(options: .init(
            chrome: .machine,
            acceptsKeyboard: true,
            onDismiss: { [weak self] in
                self?.reportPresentation = nil
                self?.slotDidFree()
            }
        )) { [weak self] presentation in
            ReportConfirmView(alias: alias) {
                presentation.dismiss()
                self?.tear(lineId: lineId, handle: handle, report: true)
            } cancel: {
                presentation.dismiss()
            }
        }
    }

    var isReportOpen: Bool { reportPresentation != nil }

    /// True while something of ours hangs under the slot that a printed page would collide with.
    var isPresentingUI: Bool {
        composer.isOpen || reportPresentation != nil || notices.isShowing
    }

    /// Something that was holding the slot has gone: let waiting pages and notices through.
    func slotDidFree() {
        printQueue.pump()
        notices.pump()
    }

    // MARK: Sending

    struct SendOutcome {
        var sent: [LineMessage] = []
        var error: FaxError?
    }

    func send(text: String, image: DitheredImage?, to target: ComposeTarget) async -> SendOutcome {
        guard let api else { return SendOutcome(error: .notConfigured) }
        var outcome = SendOutcome()
        let trimmed = ComposeRules.trimmed(text)
        do {
            switch target {
            case .stranger:
                let sent = try await api.sendFax(text: trimmed)
                outcome.sent.append(sent)
                store.update { $0.recordSent(sent, at: Date().unixMilliseconds) }
                if var quota = me?.quota {
                    quota.newFaxesLeft = max(0, quota.newFaxesLeft - 1)
                    me?.quota = quota
                }
                log("sent fax \(sent.message.id) line \(sent.line.id) \(sent.line.state.rawValue)")
            case .line(let lineId):
                if !trimmed.isEmpty {
                    let sent = try await api.sendText(lineId: lineId, text: trimmed)
                    outcome.sent.append(sent)
                    recordSent(sent)
                    log("sent text \(sent.message.id) line \(lineId) \(sent.line.state.rawValue)")
                }
                if let image {
                    let sent = try await api.sendImage(lineId: lineId, png: image.png)
                    outcome.sent.append(sent)
                    let file = try? store.writeImage(image.png, name: sent.message.id)
                    store.update { $0.recordSent(sent, imageFile: file, at: Date().unixMilliseconds) }
                    log("sent image \(sent.message.id) \(image.width)x\(image.height) \(image.png.count) bytes")
                }
            }
        } catch {
            outcome.error = FaxError.from(error)
            log("send failed: \(outcome.error.map { "\($0)" } ?? "")")
        }
        Task { await refreshMe() }
        return outcome
    }

    private func recordSent(_ sent: LineMessage) {
        let previous = store.archive.line(sent.line.id)?.line.state
        store.update { $0.recordSent(sent, at: Date().unixMilliseconds) }
        if previous == .delivered, sent.line.state == .connected {
            log("line \(sent.line.id) connected by my reply")
        }
    }

    /// The acknowledgement after a sheet has gone into the slot.
    func didSend(_ outcome: SendOutcome, target: ComposeTarget, previousState: LineState?) {
        guard let last = outcome.sent.last else { return }
        let line = last.line
        let alias = line.peerAlias ?? "····"
        switch target {
        case .stranger:
            if line.state == .queued {
                notices.show(FaxNotice(kind: .searching, title: "已发出，正在寻找收件人", detail: "有人上线时会自动送达", key: line.id))
            } else {
                notices.show(FaxNotice(kind: .delivered, title: "已送达一位陌生人", detail: "对方回复后，线路 #\(alias) 就会接通", key: line.id))
            }
        case .line:
            if previousState == .delivered, line.state == .connected {
                notices.show(FaxNotice(kind: .connected, title: "线路 #\(alias) 已接通", detail: "现在可以互发图片了", key: line.id))
            }
        }
        debug?.didSend(outcome, target: target)
    }

    func composeDidShowError(target: ComposeTarget) {
        debug?.composeShowedError(target: target)
    }

    // MARK: Menu

    var canWriteNewFax: Bool {
        guard api != nil else { return false }
        if let me, me.suspendedUntil != nil { return false }
        return true
    }

    func menuEntries() -> [MenuEntry] {
        guard status != .notConfigured else {
            return [.label("传真 · 未连接服务器")]
        }
        var entries: [MenuEntry] = [
            .action("写传真…", systemImage: "square.and.pencil", isEnabled: canWriteNewFax) { [weak self] in
                self?.composer.open(target: .stranger)
            },
        ]
        let lines = store.archive.openLines
        if !lines.isEmpty {
            entries.append(.submenu(title: "线路", systemImage: "phone", items: lines.map(lineEntry)))
        }
        // One quiet line: how the connection is, and what is left to send today.
        if status == .online, let quota = quotaText {
            entries.append(.label("传真在线 · \(quota)"))
        } else {
            entries.append(.label(statusText))
        }
        switch status {
        case .replaced, .retrying:
            entries.append(.action("重新连接", systemImage: "arrow.clockwise") { [weak self] in self?.reconnect() })
        default:
            break
        }
        return entries
    }

    private func lineEntry(_ stored: StoredLine) -> MenuEntry {
        let line = stored.line
        let state: String = switch line.state {
        case .queued: "正在寻找收件人"
        case .delivered: line.role == .initiator ? "等待对方回复" : "等你回复"
        case .connected: "已接通"
        case .closed: "已挂断"
        }
        let when = FaxFormat.relative(Date(unixMilliseconds: stored.lastActivityAt))
        let title = line.peerAlias.map { "#\($0)　\(state) · \(when)" } ?? "\(state) · \(when)"
        let hasPages = store.archive.messages(inLine: line.id).contains { $0.message.kind == .text || $0.imageFile != nil }
        let lineId = line.id
        return .submenu(title: title, items: [
            .action("重新打印", systemImage: "printer", isEnabled: hasPages) { [weak self] in self?.reprint(lineId: lineId) },
            .action(line.canSendImage ? "回复或发图片…" : "回复…", systemImage: "arrowshape.turn.up.left", isEnabled: line.canSendText) { [weak self] in
                self?.composer.open(target: .line(lineId))
            },
            .separator,
            .action("撕掉线路", systemImage: "scissors") { [weak self] in self?.tear(lineId: lineId, handle: nil, report: false) },
        ])
    }

    private var statusText: String {
        switch status {
        case .notConfigured: "传真 · 未连接服务器"
        case .unavailable: "传真 · 读不到这台 Mac 的传真身份"
        case .connecting: "传真 · 正在连接…"
        case .online: "传真 · 在线"
        case .retrying: "传真 · 连接中断，正在重试"
        case .offline: "传真 · 没有网络"
        case .asleep: "传真 · 休眠中"
        case .replaced: "传真 · 这个身份已在另一处连接"
        case .stopped: "传真 · 已停止"
        }
    }

    private var quotaText: String? {
        guard let me else { return nil }
        if let until = me.suspendedUntil {
            return "暂停发送，\(FaxFormat.day(Date(unixMilliseconds: until)))恢复"
        }
        let left = me.quota.newFaxesLeft
        return left > 0 ? "今日还可发 \(left) 封" : "今日新传真已发完"
    }
}
