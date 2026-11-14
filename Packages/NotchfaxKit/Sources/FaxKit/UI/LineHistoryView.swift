import AppKit
import Observation
import PrintKit
import SwiftUI

/// One page of a line's history, as it was printed here or sent from here.
struct HistoryPage: Identifiable, Equatable {
    enum Body: Equatable {
        case text(String)
        /// A picture on disk; `file` is `nil` while it is still being fetched.
        case image(file: String?)
    }

    var id: String
    /// The page number printed in its header, counting both directions.
    var number: Int
    var fromPeer: Bool
    var time: Date
    var body: Body

    /// Something is there to print again.
    var canReprint: Bool {
        if case .image(nil) = body { return false }
        return true
    }
}

extension FaxArchive {
    /// Every page on a line, oldest first, numbered the way they were printed.
    func historyPages(inLine lineId: String) -> [HistoryPage] {
        messages(inLine: lineId).enumerated().map { index, stored in
            let body: HistoryPage.Body = switch stored.message.kind {
            case .text: .text(stored.message.text ?? "")
            case .image: .image(file: stored.imageFile)
            }
            return HistoryPage(
                id: stored.id,
                number: index + 1,
                fromPeer: stored.isFromPeer,
                time: Date(unixMilliseconds: stored.message.sentAt),
                body: body
            )
        }
    }

    /// A closed line can be deleted once nothing on it still has to print or be acknowledged.
    func canForget(lineId: String) -> Bool {
        guard let stored = line(lineId), !stored.line.isOpen else { return false }
        return !messages(inLine: lineId).contains { $0.status == .pending || $0.status == .printed }
    }
}

/// The state of an open history panel. Reloaded whenever the store changes, so a page
/// that arrives while it is open shows up at the bottom.
@MainActor
@Observable
final class LineHistoryModel {
    let lineId: String
    private(set) var line: Line?
    private(set) var pages: [HistoryPage] = []
    private(set) var startedAt: Date?
    private(set) var canDelete = false
    var isConfirmingDelete = false
    /// Measured height of the pages, so a short history gets a short panel.
    var contentHeight: CGFloat = 0
    /// Decoded pictures by file name. Not observed: filling it never redraws anything.
    @ObservationIgnored private var pictures: [String: CGImage] = [:]
    @ObservationIgnored private let loadPicture: (String) -> CGImage?

    init(lineId: String, loadPicture: @escaping (String) -> CGImage?) {
        self.lineId = lineId
        self.loadPicture = loadPicture
    }

    func reload(from archive: FaxArchive) {
        let stored = archive.line(lineId)
        line = stored?.line
        let pages = archive.historyPages(inLine: lineId)
        if pages != self.pages { self.pages = pages }
        startedAt = stored.map { Date(unixMilliseconds: $0.line.createdAt) } ?? pages.first?.time
        canDelete = archive.canForget(lineId: lineId)
        if !canDelete { isConfirmingDelete = false }
    }

    func picture(_ file: String) -> CGImage? {
        if let cached = pictures[file] { return cached }
        let picture = loadPicture(file)
        pictures[file] = picture
        return picture
    }

    var alias: String { line?.peerAlias ?? "····" }

    var summary: String {
        var parts: [String] = []
        if let line {
            let state = switch line.state {
            case .queued: "正在寻找收件人"
            case .delivered: line.role == .initiator ? "等待对方回复" : "等你回复"
            case .connected: "已接通"
            case .closed: "已挂断"
            }
            parts.append(state)
        }
        parts.append("\(pages.count) 页")
        if let startedAt {
            let day = Calendar.current.dateComponents([.month, .day], from: startedAt)
            parts.append("\(day.month ?? 1)月\(day.day ?? 1)日开始")
        }
        return parts.joined(separator: " · ")
    }
}

/// What the panel can ask for.
struct LineHistoryActions {
    var close: @MainActor () -> Void
    var reply: @MainActor () -> Void
    var reprint: @MainActor (String) -> Void
    var delete: @MainActor () -> Void
}

/// A line's whole conversation, page by page, hanging from the slot: the other side's
/// pages on the left, this Mac's on the right, newest at the bottom.
struct LineHistoryView: View {
    @Bindable var model: LineHistoryModel
    let actions: LineHistoryActions
    let maxHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let rollWidth: CGFloat = 232

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            roll
            controls
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("线路 #\(model.alias)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(model.summary)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 4)
    }

    private var roll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    if model.pages.isEmpty {
                        Text("这条线路还没有记录")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(model.pages) { page in
                        HistorySlip(page: page, alias: model.alias, picture: model.picture) {
                            actions.reprint(page.id)
                        }
                        .frame(maxWidth: .infinity, alignment: page.fromPeer ? .leading : .trailing)
                        .id(page.id)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.bottom)
            .frame(width: Self.rollWidth, height: min(maxHeight, max(76, model.contentHeight)))
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.045)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: model.pages.last?.id) { _, last in
                guard let last else { return }
                // A page that arrives while the panel is open slides in at the bottom.
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.9)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            if model.isConfirmingDelete {
                Text("删掉就找不回来了")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 4)
                Button("取消") { model.isConfirmingDelete = false }
                    .buttonStyle(PillStyle(fill: Color.white.opacity(0.14)))
                    .keyboardShortcut(.cancelAction)
                Button("删除", action: actions.delete)
                    .buttonStyle(PillStyle(fill: Color(red: 0.86, green: 0.22, blue: 0.18)))
            } else {
                CircleButton(systemImage: "xmark", help: "收起（Esc）", action: actions.close)
                Spacer(minLength: 4)
                if model.canDelete {
                    Button("删除记录") { model.isConfirmingDelete = true }
                        .buttonStyle(PillStyle(fill: Color.white.opacity(0.14)))
                        .help("这些记录只存在这台 Mac 上")
                }
                if model.line?.canSendText == true {
                    Button(model.line?.canSendImage == true ? "回复或发图片…" : "回复…", action: actions.reply)
                        .buttonStyle(PillStyle(fill: Color.white.opacity(0.2)))
                }
            }
        }
        .frame(width: Self.rollWidth)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: model.isConfirmingDelete)
    }
}

/// One page as a slip of thermal paper, laid out exactly as it was printed.
private struct HistorySlip: View {
    let page: HistoryPage
    let alias: String
    let picture: (String) -> CGImage?
    let reprint: () -> Void
    @State private var isHovering = false

    var body: some View {
        PaperSurface(.thermal) {
            FaxPageView(model: FaxPageModel(
                time: page.time,
                alias: alias,
                page: page.number,
                body: pageBody,
                footer: nil,
                byline: page.fromPeer ? nil : "我发出的"
            ))
        }
        .frame(width: FaxType.paperWidth)
        .overlay(alignment: .topTrailing) {
            if isHovering, page.canReprint {
                Button(action: reprint) {
                    Image(systemName: "printer.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.72)))
                }
                .buttonStyle(.plain)
                .help("再打印一份")
                .padding(4)
                .transition(.opacity)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var pageBody: FaxPageModel.Body {
        switch page.body {
        case .text(let text):
            return .text(text)
        case .image(let file):
            guard let file else { return .text("〔图片还没收到〕") }
            guard let image = picture(file) else { return .text("〔这张图片读不出来了〕") }
            return .image(image)
        }
    }
}
