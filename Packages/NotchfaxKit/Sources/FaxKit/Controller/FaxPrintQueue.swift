import Foundation
import PrintKit

/// Feeds received pages to the printer one at a time.
///
/// PrintKit queues jobs too, but hurries a hanging sheet away as soon as another job is
/// waiting. A fax deserves to be read, so the next page is only handed over once the
/// current one has been out for a reading time, or is gone.
@MainActor
final class FaxPrintQueue {
    private unowned let controller: FaxController
    private var waiting: [(id: String, copy: Bool)] = []
    private var known: Set<String> = []
    private var active: String?
    private var lastHandle: PrintHandle?

    init(controller: FaxController) {
        self.controller = controller
    }

    /// A page is coming out or still hanging under the slot.
    var hasVisibleSheet: Bool {
        guard let lastHandle else { return false }
        if case .finished = lastHandle.state { return false }
        return true
    }

    var isPrinting: Bool { active != nil }

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

    func pump() {
        guard active == nil, !controller.isPresentingUI, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        guard let built = controller.makeJob(for: next.id, copy: next.copy) else {
            if !next.copy { known.remove(next.id) }
            pump()
            return
        }
        let handle = controller.printer.enqueue(built.job)
        active = next.id
        lastHandle = handle
        Task {
            let fed = await handle.finishedFeeding()
            if !next.copy { controller.pageDidPrint(next.id, fed: fed, handle: handle) }
            let until = Date().addingTimeInterval(fed ? built.readingTime : 0)
            while Date() < until {
                if case .finished = handle.state { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            active = nil
            if !next.copy { known.remove(next.id) }
            controller.slotDidFree()
        }
        Task {
            _ = await handle.outcome()
            controller.slotDidFree()
        }
    }
}

/// Shows one notice at a time, only when nothing else is hanging from the slot, and drops
/// news that has gone stale while it waited.
@MainActor
final class NoticeCenter {
    private unowned let controller: FaxController
    private var queue: [(notice: FaxNotice, at: Date)] = []
    private var current: SlotPresentation?
    private let maxWait: TimeInterval = 45
    private let showFor: Duration = .milliseconds(2800)

    init(controller: FaxController) {
        self.controller = controller
    }

    var isShowing: Bool { current != nil }

    func show(_ notice: FaxNotice) {
        queue.removeAll { $0.notice.key == notice.key }
        queue.append((notice, Date()))
        controller.log("notice: \(notice.title)")
        pump()
    }

    func pump() {
        queue.removeAll { Date().timeIntervalSince($0.at) > maxWait }
        guard current == nil, !controller.composer.isOpen, !controller.isReportOpen,
              !controller.printQueue.isPrinting, !controller.printQueue.hasVisibleSheet,
              !queue.isEmpty else { return }
        let notice = queue.removeFirst().notice
        let printer = controller.printer
        if notice.kind == .connected { printer.sound.play(.tick) }
        let presentation = printer.present(options: .init(
            chrome: .machine,
            acceptsKeyboard: false,
            dismissesOnOutsideClick: true,
            dismissesOnEscape: false,
            onDismiss: { [weak self] in
                self?.current = nil
                Task { [weak self] in
                    // Let it slide back up before anything else uses the slot.
                    try? await Task.sleep(for: .milliseconds(450))
                    self?.controller.slotDidFree()
                }
            }
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
