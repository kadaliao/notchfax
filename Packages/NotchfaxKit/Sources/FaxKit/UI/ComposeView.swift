import AppKit
import Observation
import PrintKit
import SwiftUI
import UniformTypeIdentifiers

/// Who a sheet being written goes to.
enum ComposeTarget: Hashable, Sendable {
    /// A new fax to a random stranger.
    case stranger
    /// A reply or follow-up on an existing line.
    case line(String)
}

/// The state of one compose sheet.
@MainActor
@Observable
final class ComposeModel {
    let target: ComposeTarget
    var text: String
    var image: DitheredImage?
    var isPreparingImage = false
    var error: String?
    var textHeight: CGFloat = FaxType.lineHeight
    var paperSize: CGSize = .zero
    var isDropTargeted = false

    /// The other side's alias, for a reply.
    var alias: String?
    /// The last thing the other side wrote, quoted for context.
    var excerpt: String?
    /// True when the other side spoke last, so this sheet answers them.
    var isReply = true
    var quotaLeft: Int?
    var allowsImage: Bool
    var blockedReason: String?
    let startedAt = Date()

    init(target: ComposeTarget, text: String = "", image: DitheredImage? = nil, allowsImage: Bool = false) {
        self.target = target
        self.text = text
        self.image = image
        self.allowsImage = allowsImage
    }

    /// Set once the sheet has been sent, so closing it does not keep a draft.
    var isSending = false

    var count: Int { ComposeRules.count(text) }
    var isOverLimit: Bool { count > ComposeRules.limit }
    var hasContent: Bool { count > 0 || image != nil }
    var canSend: Bool { hasContent && !isOverLimit && !isPreparingImage && blockedReason == nil && !isSending }

    static let maxTextHeight: CGFloat = 228
    static let minTextLines: CGFloat = 4

    /// The writing area grows with the text, from a few lines up to a page, then scrolls.
    /// With a picture attached it starts smaller: a caption is optional.
    var textAreaHeight: CGFloat {
        let lines = image == nil ? Self.minTextLines : 2
        return min(Self.maxTextHeight, max(FaxType.lineHeight * lines, textHeight))
    }

    var placeholder: String {
        switch target {
        case .stranger: "写给一位陌生人…"
        case .line: allowsImage ? "写点什么，或者放一张图片…" : "写下你的回复…"
        }
    }

    var header: ComposeHeader {
        let recipient = switch target {
        case .stranger: "致 一位陌生人"
        case .line: "\(isReply ? "回复" : "致") 线路 #\(alias ?? "····")"
        }
        return ComposeHeader(left: recipient, right: FaxFormat.headerTime(startedAt))
    }
}

struct ComposeHeader: Equatable {
    var left: String
    var right: String
}

/// Callbacks from the sheet to whoever presented it.
struct ComposeActions {
    var send: @MainActor () -> Void
    var cancel: @MainActor () -> Void
    var chooseImage: @MainActor () -> Void
    var removeImage: @MainActor () -> Void
    var dropImage: @MainActor ([NSItemProvider]) -> Bool
    var pasteImage: @MainActor (NSPasteboard) -> Bool
}

/// A sheet of thermal paper hanging under the slot, written on directly. Sending feeds
/// this very sheet up into the slot.
struct ComposeView: View {
    @Bindable var model: ComposeModel
    let actions: ComposeActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Distance from the top of the presentation's content to the top edge of the paper.
    static let paperTop: CGFloat = 10

    var body: some View {
        VStack(spacing: 12) {
            paper
            controls
        }
        .padding(.top, Self.paperTop)
        .padding(.horizontal, 26)
        .padding(.bottom, 12)
    }

    // MARK: Paper

    private var paper: some View {
        PaperSurface(.thermal) {
            ComposeSheetLayout(
                header: model.header,
                excerpt: model.excerpt,
                textHeight: model.textAreaHeight,
                image: model.image,
                isPreparingImage: model.isPreparingImage,
                footer: ComposeFooter(model: model)
            ) {
                ZStack(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text(model.placeholder)
                            .font(FaxType.body())
                            .foregroundStyle(.black.opacity(0.28))
                            .allowsHitTesting(false)
                    }
                    FaxTextEditor(
                        text: $model.text,
                        contentHeight: $model.textHeight,
                        limit: ComposeRules.limit,
                        onSubmit: actions.send,
                        onCancel: actions.cancel,
                        onPaste: actions.pasteImage
                    )
                }
            } imageOverlay: {
                Button(action: actions.removeImage) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(.black.opacity(0.62)))
                }
                .buttonStyle(.plain)
                .help("移除图片")
                .padding(4)
            }
        }
        .frame(width: FaxType.paperWidth)
        .overlay { dropHighlight }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.paperSize = $0 }
        .onDrop(of: [.fileURL, .image], isTargeted: $model.isDropTargeted) { providers in
            actions.dropImage(providers)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: model.textAreaHeight)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: model.image?.png)
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if model.isDropTargeted {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.black.opacity(0.35))
                .background(Color.white.opacity(0.35))
                .overlay {
                    Text(model.allowsImage ? "松手，放进这张传真" : "线路接通后才能发图片")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.62))
                }
                .padding(5)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            if let error = model.error {
                ErrorNote(text: error)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                CircleButton(systemImage: "xmark", help: "收起（Esc）", action: actions.cancel)
                if model.allowsImage {
                    CircleButton(systemImage: "photo", help: "附一张图片（也可以拖进来或粘贴）", action: actions.chooseImage)
                }
                SendButton(enabled: model.canSend, action: actions.send)
            }
        }
        .frame(width: max(FaxType.paperWidth, 190))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: model.error)
    }
}

/// Quota or hints on the left, the quiet character counter on the right.
struct ComposeFooter: View {
    let model: ComposeModel

    var body: some View {
        HStack(spacing: 4) {
            if let blocked = model.blockedReason {
                Text(blocked)
            } else if model.target == .stranger, let left = model.quotaLeft {
                Text(left > 0 ? "今日还可发 \(left) 封" : "今日新传真已发完")
            } else if model.allowsImage {
                Text("可附一张图片")
            }
            Spacer(minLength: 4)
            counter
        }
        .font(FaxType.footer())
        .foregroundStyle(.black.opacity(0.42))
        .lineLimit(1)
    }

    private var counter: some View {
        let count = model.count
        let over = count - ComposeRules.limit
        return Text(over > 0 ? "超出 \(over) 字" : "\(count)/\(ComposeRules.limit)")
            .monospacedDigit()
            .foregroundStyle(over > 0 ? Color(red: 0.78, green: 0.16, blue: 0.10) : .black.opacity(count >= 450 ? 0.62 : 0.34))
            .contentTransition(.numericText())
    }
}

/// The paper's layout, shared by the live sheet and the sheet that is fed into the slot,
/// so swapping one for the other moves nothing.
struct ComposeSheetLayout<TextBody: View, Footer: View, ImageOverlay: View>: View {
    let header: ComposeHeader
    let excerpt: String?
    let textHeight: CGFloat
    let image: DitheredImage?
    var isPreparingImage = false
    let footer: Footer
    @ViewBuilder let textBody: () -> TextBody
    @ViewBuilder let imageOverlay: () -> ImageOverlay

    init(
        header: ComposeHeader, excerpt: String?, textHeight: CGFloat, image: DitheredImage?, isPreparingImage: Bool = false,
        footer: Footer, @ViewBuilder textBody: @escaping () -> TextBody, @ViewBuilder imageOverlay: @escaping () -> ImageOverlay
    ) {
        self.header = header
        self.excerpt = excerpt
        self.textHeight = textHeight
        self.image = image
        self.isPreparingImage = isPreparingImage
        self.footer = footer
        self.textBody = textBody
        self.imageOverlay = imageOverlay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(header.left)
                Spacer(minLength: 4)
                Text(header.right)
            }
            .font(FaxType.header())
            .foregroundStyle(.black.opacity(0.78))
            .lineLimit(1)
            DashedRule(opacity: 0.7)
            if let excerpt {
                Text(excerpt)
                    .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.42))
                    .lineLimit(2)
                    .lineSpacing(1.5)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.25)).frame(width: 1)
                    }
            }
            textBody()
                .frame(height: textHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            if let image, let sheetDots = Self.sheetDots(image), let picture = sheetDots.cgImage() {
                // The very dots that will be sent, one per print-head dot: what is previewed here
                // is what goes into the slot and what comes out at the other end.
                ThermalBitmap(picture)
                    .overlay(alignment: .topTrailing) { imageOverlay() }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else if isPreparingImage {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            footer
        }
    }
}

extension ComposeSheetLayout {
    /// The picture's dots fitted to the compose sheet's width at two pixels per point.
    static func sheetDots(_ image: DitheredImage) -> BilevelImage? {
        image.bits.resampled(toWidth: FaxDither.printWidth)
    }
}

extension ComposeSheetLayout where ImageOverlay == EmptyView {
    init(
        header: ComposeHeader, excerpt: String?, textHeight: CGFloat, image: DitheredImage?,
        footer: Footer, @ViewBuilder textBody: @escaping () -> TextBody
    ) {
        self.init(header: header, excerpt: excerpt, textHeight: textHeight, image: image, footer: footer, textBody: textBody) { EmptyView() }
    }
}

// MARK: - Controls

private struct CircleButton: View {
    let systemImage: String
    let help: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(PressableStyle(shape: Circle(), fill: .regularMaterial))
        .help(help)
    }
}

private struct SendButton: View {
    let enabled: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("发送")
                    .font(.system(size: 12, weight: .semibold))
                Text("⌘↩")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.55)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
        }
        .buttonStyle(PressableStyle(shape: Capsule(), fill: Color(white: 0.11)))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help("发送（⌘↩）")
    }
}

/// Instant feedback on press: a slight dip in scale, released on a spring.
struct PressableStyle<S: InsettableShape, F: ShapeStyle>: ButtonStyle {
    let shape: S
    let fill: F

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// A plain-language problem, shown where the paper came back out.
struct ErrorNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.32))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 230, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.09).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
    }
}
