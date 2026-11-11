import AppKit
import PrintKit
import SwiftUI

/// Sample prints and panels for the 调试 menu. They double as small, working
/// examples of the PrintKit API.
@MainActor
final class DebugSamples {
    private let printer: Printer

    init(printer: Printer) {
        self.printer = printer
    }

    var menuEntries: [MenuEntry] {
        [
            .label("打印样张"),
            .action("热敏传真", systemImage: "scroll") { [weak self] in self?.run("fax") },
            .action("光面相片", systemImage: "photo") { [weak self] in self?.run("photo") },
            .action("四连拍相纸", systemImage: "rectangle.split.1x2") { [weak self] in self?.run("strip") },
            .action("连续三张（排队）", systemImage: "square.stack.3d.down.right") { [weak self] in self?.run("all") },
            .separator,
            .label("出纸口面板"),
            .action("取景框示例", systemImage: "camera.viewfinder") { [weak self] in self?.run("viewfinder") },
            .action("写传真并送入出纸口", systemImage: "square.and.pencil") { [weak self] in self?.run("compose") },
            .submenu(title: "模拟手势（作用于出纸口的纸）", systemImage: "hand.draw", items: Printer.debugGestureNames.map { name in
                .action(name) { [weak self] in self?.printer.debugPlayGesture(name) }
            }),
            .separator,
            .action("收回所有纸张", systemImage: "xmark.circle") { [weak self] in self?.printer.cancelAll() },
        ]
    }

    func run(_ name: String) {
        switch name {
        case "fax": printer.enqueue(PrintSamples.fax())
        case "photo": printer.enqueue(PrintSamples.photo(variant: Int.random(in: 0..<3)))
        case "strip": printer.enqueue(PrintSamples.strip())
        case "all":
            printer.enqueue(PrintSamples.photo())
            printer.enqueue(PrintSamples.strip())
            printer.enqueue(PrintSamples.fax())
        case "viewfinder": presentViewfinder()
        case "compose": presentCompose()
        case "compose-send": presentCompose(autoSend: true)
        case "pointer-report":
            print(printer.debugPointerReport())
            fflush(stdout)
        default:
            if name.hasPrefix("gesture:") { printer.debugPlayGesture(String(name.dropFirst(8))) }
        }
    }

    /// A panel that hangs from the slot like part of the machine; pressing the
    /// shutter prints a strip.
    private func presentViewfinder() {
        let printer = printer
        printer.present { presentation in
            ViewfinderDemo {
                printer.sound.play(.shutter)
                presentation.dismiss()
                printer.enqueue(PrintSamples.strip())
            }
        }
    }

    /// A sheet of paper to write on; sending feeds it up into the slot.
    private func presentCompose(autoSend: Bool = false) {
        let message = "你好，陌生人。\n这是一封从刘海里寄出的传真。"
        let send: (SlotPresentation, String) -> Void = { presentation, text in
            let sheet = PaperSheet(.thermal, size: ComposeDemo.sheetSize) { ComposeDemo.page(text) }
            Task { await presentation.feedIntoSlot(sheet, topOffset: ComposeDemo.paperTop) }
        }
        let presentation = printer.present(options: .init(chrome: .none, acceptsKeyboard: true)) { presentation in
            ComposeDemo(message: message) { send(presentation, $0) }
        }
        if autoSend {
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                send(presentation, message)
            }
        }
    }
}

private struct ViewfinderDemo: View {
    let shoot: () -> Void
    private let preview = PrintSamples.portrait(width: 480, height: 360, variant: 1)

    var body: some View {
        VStack(spacing: 10) {
            Image(decorative: preview, scale: 2)
                .resizable()
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(width: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Label("模拟画面", systemImage: "circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .labelStyle(.titleAndIcon)
                        .padding(7)
                }
            Button(action: shoot) {
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2).padding(-4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("拍照")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

private struct ComposeDemo: View {
    static let sheetSize = CGSize(width: 160, height: 150)
    static let paperTop: CGFloat = 26

    @State var message: String
    let send: (String) -> Void
    @FocusState private var focused: Bool

    static func page(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .lineSpacing(3.5)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var body: some View {
        let content = Paper.thermal.contentRect(in: Self.sheetSize).size
        VStack(spacing: 12) {
            PaperSurface(.thermal) {
                TextEditor(text: $message)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineSpacing(3.5)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .padding(.horizontal, -5)
                    .focused($focused)
                    .frame(width: content.width, height: content.height)
            }
            Button("发送") { send(message) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.top, Self.paperTop)
        .padding(.horizontal, 30)
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }
}
