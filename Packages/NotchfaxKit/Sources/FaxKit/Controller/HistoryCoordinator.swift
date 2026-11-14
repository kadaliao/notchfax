import AppKit
import PrintKit
import SwiftUI

/// Opens a line's whole history under the slot, and does what is asked from it: reply,
/// print a page again, or delete a hung-up line's record.
@MainActor
final class HistoryCoordinator {
    private unowned let controller: FaxController
    private var session: (model: LineHistoryModel, presentation: SlotPresentation)?

    init(controller: FaxController) {
        self.controller = controller
    }

    var openLineId: String? { session?.model.lineId }

    func open(lineId: String) {
        guard session?.model.lineId != lineId else { return }
        let store = controller.store
        let model = LineHistoryModel(lineId: lineId) { file in
            store.readImage(file).flatMap(ImageLoader.load(data:))
        }
        model.reload(from: store.archive)
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        let maxHeight = min(600, max(240, screen * 0.62))
        let presentation = controller.printer.present(options: .init(
            chrome: .machine,
            acceptsKeyboard: true,
            onDismiss: { [weak self, weak model] in
                guard let self, self.session?.model === model else { return }
                self.session = nil
            }
        )) { [weak self] presentation in
            LineHistoryView(model: model, actions: LineHistoryActions(
                close: { presentation.dismiss() },
                reply: { [weak self] in
                    presentation.dismiss()
                    self?.controller.composer.open(target: .line(lineId))
                },
                reprint: { [weak self] id in
                    // The copy prints once the panel is back in the slot.
                    presentation.dismiss()
                    self?.controller.log("history: reprint \(id)")
                    self?.controller.printQueue.enqueueCopy(id)
                },
                delete: { [weak self] in
                    self?.forget(lineId)
                    presentation.dismiss()
                }
            ), maxHeight: maxHeight)
        }
        session = (model, presentation)
        controller.log("history opened \(lineId) (\(model.pages.count) page(s))")
    }

    func close() {
        session?.presentation.dismiss()
    }

    /// Keeps an open panel in step with the store.
    func storeDidChange() {
        session?.model.reload(from: controller.store.archive)
    }

    private func forget(_ lineId: String) {
        guard let files = controller.store.update({ $0.forget(lineId: lineId) }) else {
            NSSound.beep()
            return
        }
        controller.store.removeImages(files)
        controller.log("history: forgot line \(lineId), \(files.count) picture(s)")
    }
}
