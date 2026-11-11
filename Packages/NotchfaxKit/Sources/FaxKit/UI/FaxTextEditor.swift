import AppKit
import SwiftUI

/// The writing surface of the compose sheet: a plain `NSTextView`, so input methods
/// (Pinyin, Zhuyin, Japanese…) work exactly as everywhere else on the Mac.
///
/// The length limit never interferes with an input method: while text is being composed
/// nothing is clipped, and a committed phrase that runs over the limit is kept and
/// flagged by the counter instead of being cut mid-word.
struct FaxTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Height the text needs, reported as it changes.
    @Binding var contentHeight: CGFloat
    var limit: Int
    var onSubmit: @MainActor () -> Void
    var onCancel: @MainActor () -> Void
    /// Offered every paste first; return `true` if it was a picture and has been taken.
    var onPaste: @MainActor (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        let textView = ComposeTextView(frame: NSRect(x: 0, y: 0, width: FaxType.contentWidth, height: 40))
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let ink = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = FaxType.bodySpacing
        textView.defaultParagraphStyle = paragraph
        textView.font = FaxType.bodyNSFont
        textView.textColor = ink
        textView.insertionPointColor = ink
        textView.typingAttributes = [.font: FaxType.bodyNSFont, .foregroundColor: ink, .paragraphStyle: paragraph]
        textView.selectedTextAttributes = [.backgroundColor: NSColor(white: 0, alpha: 0.12)]
        textView.string = text

        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.reportHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Never overwrite text that an input method is still composing.
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            context.coordinator.reportHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FaxTextEditor
        weak var textView: NSTextView?

        init(parent: FaxTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            reportHeight()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, !replacement.isEmpty else { return true }
            // Composition in progress, or the commit of one: leave the input method alone.
            if textView.hasMarkedText() { return true }
            let current = textView.string as NSString
            let remaining = current.replacingCharacters(in: range, with: "")
            let room = parent.limit - ComposeRules.count(remaining)
            if ComposeRules.count(remaining + replacement) <= parent.limit { return true }
            guard room > 0 else {
                NSSound.beep()
                return false
            }
            // Typed or pasted past the limit: keep what fits.
            let clipped = ComposeRules.prefix(replacement, scalars: room)
            DispatchQueue.main.async {
                textView.insertText(clipped, replacementRange: range)
            }
            return false
        }

        func reportHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            var height = layout.usedRect(for: container).height
            if layout.extraLineFragmentTextContainer != nil || textView.string.isEmpty {
                height = max(height, layout.extraLineFragmentRect.maxY)
            }
            let rounded = max(FaxType.lineHeight, height.rounded(.up))
            if abs(rounded - parent.contentHeight) > 0.5 { parent.contentHeight = rounded }
        }
    }
}

/// Text counting shared with the server's rule: trimmed, counted in Unicode scalars.
enum ComposeRules {
    static let limit = 500

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func count(_ text: String) -> Int {
        trimmed(text).unicodeScalars.count
    }

    static func prefix(_ text: String, scalars: Int) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars.prefix(max(0, scalars)) { result.append(scalar) }
        return String(result)
    }
}

final class ComposeTextView: NSTextView {
    weak var coordinator: FaxTextEditor.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Pictures are taken by the sheet around this view, not inserted as file paths.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === self {
            coordinator?.parent.onSubmit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape first belongs to an input method that is composing.
        if hasMarkedText() {
            super.cancelOperation(sender)
        } else {
            coordinator?.parent.onCancel()
        }
    }

    override func paste(_ sender: Any?) {
        if let coordinator, coordinator.parent.onPaste(.general) { return }
        pasteAsPlainText(sender)
    }
}
