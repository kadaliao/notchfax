import AppKit
import PrintKit
import SwiftUI

/// Type and measures shared by the printed page and the compose sheet, so a sheet being
/// written and the same sheet printed line up.
enum FaxType {
    static let bodySize: CGFloat = 11.5
    static let bodySpacing: CGFloat = 3.5
    static let headerSize: CGFloat = 7.5
    static let footerSize: CGFloat = 6.5
    /// A receipt-printer face: fixed-pitch Latin; CJK falls back to PingFang.
    static func body(_ scale: CGFloat = 1) -> Font {
        .system(size: bodySize * scale, weight: .medium, design: .monospaced)
    }
    static func header(_ scale: CGFloat = 1) -> Font {
        .system(size: headerSize * scale, weight: .semibold, design: .monospaced)
    }
    static func footer(_ scale: CGFloat = 1) -> Font {
        .system(size: footerSize * scale, weight: .medium)
    }

    static var bodyNSFont: NSFont {
        .monospacedSystemFont(ofSize: bodySize, weight: .medium)
    }

    /// One printed line of body text, so the motor advances a line per burst.
    static let lineHeight: CGFloat = {
        let latin = NSLayoutManager().defaultLineHeight(for: bodyNSFont)
        let cjk = NSFont(name: "PingFangSC-Medium", size: bodySize).map { NSLayoutManager().defaultLineHeight(for: $0) } ?? latin
        return (max(latin, cjk) + bodySpacing).rounded()
    }()

    /// Thermal paper as PrintKit cuts it for text.
    static let paperWidth: CGFloat = Paper.thermal.defaultSize.width
    static var contentWidth: CGFloat {
        paperWidth - Paper.thermal.contentInsets.leading - Paper.thermal.contentInsets.trailing
    }

    /// Picture pages are laid out so one PNG dot is one rendered pixel (paper renders at 2x),
    /// then scaled by the slot like any wide sheet.
    static let imageContentWidth = CGFloat(FaxDither.maxWidth) / 2
    static var imagePaperWidth: CGFloat {
        imageContentWidth + Paper.thermal.contentInsets.leading + Paper.thermal.contentInsets.trailing
    }
}

/// What goes on one printed page.
struct FaxPageModel {
    enum Body {
        case text(String)
        case image(CGImage)
    }

    var time: Date
    /// The other side's alias, shown as 「线路 #A3F2」.
    var alias: String?
    var page: Int
    var body: Body
    var footer: String?
    /// A reprint is marked as a copy, the way fax machines do.
    var isCopy = false
    /// Who wrote it, when it is not the other side (a copy of something this Mac sent).
    var byline: String?
}

/// A received fax as printed on thermal paper: the header line a fax machine stamps on
/// every page, the message, and a short footer.
struct FaxPageView: View {
    let model: FaxPageModel
    /// Type is scaled up on wide picture pages, which the slot then scales down again.
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            header
            DashedRule(scale: scale)
            if let byline = model.byline {
                Text(byline)
                    .font(FaxType.footer(scale))
                    .tracking(0.4 * scale)
            }
            content
                .padding(.vertical, 2 * scale)
            if let footer = model.footer {
                DashedRule(scale: scale)
                HStack(alignment: .center, spacing: 5 * scale) {
                    LineMark(seed: model.alias ?? "FAX", scale: scale)
                    Text(footer)
                        .font(FaxType.footer(scale))
                        .tracking(0.3 * scale)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(FaxFormat.headerTime(model.time))
            Spacer(minLength: 4 * scale)
            Text(aliasText)
            Spacer(minLength: 4 * scale)
            Text(model.isCopy ? "副本" : String(format: "P.%02d", model.page))
        }
        .font(FaxType.header(scale))
        .lineLimit(1)
    }

    private var aliasText: String {
        "线路 #\(model.alias ?? "····")"
    }

    @ViewBuilder
    private var content: some View {
        switch model.body {
        case .text(let text):
            Text(text)
                .font(FaxType.body(scale))
                .lineSpacing(FaxType.bodySpacing * scale)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let image):
            // Two dots per point: at the paper's 2x render scale each PNG dot is one pixel.
            Image(decorative: image, scale: 2)
                .interpolation(.none)
                .frame(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A dashed hairline, the rule a receipt printer draws between sections.
struct DashedRule: View {
    var scale: CGFloat = 1
    var opacity: Double = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.black.opacity(opacity)), style: StrokeStyle(lineWidth: scale, dash: [3 * scale, 2 * scale]))
        }
        .frame(height: max(1, scale))
    }
}

/// A short bar pattern derived from the line's alias: a quiet machine-made mark.
struct LineMark: View {
    let seed: String
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let width = CGFloat(1 + Int((hash >> 33) % 3)) * 0.75 * scale
                if index.isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: 0, width: min(width, size.width - x), height: size.height)), with: .color(.black))
                }
                x += width
                index += 1
            }
        }
        .frame(width: 30 * scale, height: 9 * scale)
    }
}

// MARK: - Building print jobs

extension FaxPageModel {
    /// The sheet for this page: text pages on standard thermal paper, picture pages wide
    /// enough that every dot of the PNG lands on its own pixel.
    @MainActor
    func sheet(maxPaperWidth: CGFloat) -> PaperSheet {
        switch body {
        case .text:
            return PaperSheet(.thermal) { FaxPageView(model: self) }
        case .image:
            // The slot scales a wide sheet down; enlarge the type to match so the header
            // reads at the same size as on a text page.
            let fit = min(1, maxPaperWidth / FaxType.imagePaperWidth)
            let textPageFit = min(1, maxPaperWidth / FaxType.paperWidth)
            let typeScale = min(1.6, max(1, textPageFit / max(0.01, fit)))
            let view = FaxPageView(model: self, scale: typeScale)
            let insets = Paper.thermal.contentInsets
            let height = Self.fittedHeight(view, width: FaxType.imageContentWidth) + insets.top + insets.bottom
            return PaperSheet(.thermal, size: CGSize(width: FaxType.imagePaperWidth, height: min(1400, height))) { view }
        }
    }

    @MainActor
    static func fittedHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view.frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height.rounded(.up)
    }
}
