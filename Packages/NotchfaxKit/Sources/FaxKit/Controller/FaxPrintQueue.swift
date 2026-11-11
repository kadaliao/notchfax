import Foundation
import PrintKit

/// Hands received pages to the printer in order.
///
/// A page's job is built only when the page before it has come out, so its footer
/// reflects the line as it is then. Pacing is the printer's: each job carries a reading
/// time, and the printer keeps a page out that long before the next may replace it,
/// holds pages back while something is presented under the slot, and lets them through
/// afterwards.
@MainActor
final class FaxPrintQueue {
    private unowned let controller: FaxController
    private var waiting: [(id: String, copy: Bool)] = []
    private var known: Set<String> = []
    /// A page has been handed to the printer and has not finished feeding yet.
    private var isFeeding = false

    init(controller: FaxController) {
        self.controller = controller
    }

    func enqueue(_ id: String) {
        guard !known.contains(id) else { return }
        known.insert(id)
        waiting.append((id, false))
        pump()
    }

    func enqueueCopy(_ id: String) {
        waiting.append((id, true))
        pump()
    }

    private func pump() {
        guard !isFeeding, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        guard let job = controller.makeJob(for: next.id, copy: next.copy) else {
            if !next.copy { known.remove(next.id) }
            pump()
            return
        }
        let handle = controller.printer.enqueue(job)
        isFeeding = true
        Task {
            let fed = await handle.finishedFeeding()
            if !next.copy {
                controller.pageDidPrint(next.id, fed: fed, handle: handle)
                known.remove(next.id)
            }
            isFeeding = false
            pump()
        }
    }
}

/// Shows one notice at a time, only when the slot is idle, and drops news that has gone
/// stale while it waited.
@MainActor
final class NoticeCenter {
    private unowned let controller: FaxController
    private var queue: [(notice: FaxNotice, at: Date)] = []
    private var current: SlotPresentation?
    private var observation: ActivityObservation?
    private let maxWait: TimeInterval = 45
    private let showFor: Duration = .milliseconds(2800)

    init(controller: FaxController) {
        self.controller = controller
        // Whenever the slot falls idle, the next piece of news may come down.
        observation = controller.printer.observeActivity { [weak self] activity in
            if activity.isIdle { self?.pump() }
        }
    }

    func show(_ notice: FaxNotice) {
        queue.removeAll { $0.notice.key == notice.key }
        queue.append((notice, Date()))
        controller.log("notice: \(notice.title)")
        pump()
    }

    private func pump() {
        queue.removeAll { Date().timeIntervalSince($0.at) > maxWait }
        let printer = controller.printer
        guard current == nil, printer.activity.isIdle, !queue.isEmpty else { return }
        let notice = queue.removeFirst().notice
        if notice.kind == .connected { printer.sound.play(.tick) }
        let presentation = printer.present(options: .init(
            chrome: .machine,
            acceptsKeyboard: false,
            dismissesOnOutsideClick: true,
            dismissesOnEscape: false,
            onDismiss: { [weak self] in self?.current = nil }
        )) { _ in
            NoticeView(notice: notice)
        }
        current = presentation
        controller.log("notice shown: \(notice.title)")
        Task {
            try? await Task.sleep(for: showFor)
            presentation.dismiss()
        }
    }
}
