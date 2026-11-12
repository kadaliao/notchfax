import PrintKit
import SwiftUI

/// Type for receipts sent from the command line: a receipt printer's fixed-pitch face
/// (CJK falls back to PingFang), a little smaller than a fax so two columns fit.
enum ReceiptType {
    static let bodySize: CGFloat = 9.5
    static let lineSpacing: CGFloat = 2.5

    static func font(_ style: ReceiptLine.Style) -> Font {
        switch style {
        case .body: .system(size: bodySize, weight: .medium, design: .monospaced)
        case .bold: .system(size: 10.5, weight: .bold, design: .monospaced)
        case .title: .system(size: 15, weight: .heavy, design: .monospaced)
        case .small: .system(size: 7.5, weight: .medium, design: .monospaced)
        }
    }

    /// How far the motor advances per burst while the ink comes up.
    static let feedLine: CGFloat = 13
}

/// What goes on a receipt: an optional picture, then text.
struct ReceiptContent {
    enum Body {
        case lines([ReceiptLine])
        /// Printed exactly as written, whitespace included.
        case plain(String)
    }

    /// Already dithered, one pixel per print-head dot.
    var picture: CGImage?
    var body: Body?
}

struct ReceiptView: View {
    let content: ReceiptContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let picture = content.picture {
                ThermalBitmap(picture)
                    .frame(maxWidth: .infinity)
            }
            switch content.body {
            case .lines(let lines):
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        LineView(line: line)
                    }
                }
            case .plain(let text):
                Text(text.replacingOccurrences(of: "\t", with: "    "))
                    .font(ReceiptType.font(.body))
                    .lineSpacing(ReceiptType.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case nil:
                EmptyView()
            }
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LineView: View {
    let line: ReceiptLine

    var body: some View {
        switch line.kind {
        case .gap:
            Color.clear.frame(height: 4)
        case .rule(let dashed):
            Rule(dashed: dashed)
                .padding(.vertical, 2)
        case .text(let left, let right):
            if let right {
                Columns {
                    text(left)
                    text(right).multilineTextAlignment(.trailing)
                }
            } else {
                text(left)
                    .multilineTextAlignment(line.centered ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: line.centered ? .center : .leading)
            }
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(ReceiptType.font(line.style))
            .lineSpacing(ReceiptType.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Two columns on one line, the second flush right. Each keeps its natural width when both
/// fit; otherwise the right one gives way first, down to a little over half the line, and wraps.
struct Columns: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let total = proposal.width ?? subviews.reduce(spacing) { $0 + $1.sizeThatFits(.unspecified).width }
        let (left, right) = widths(total: total, subviews: subviews)
        let height = max(
            subviews[0].sizeThatFits(ProposedViewSize(width: left, height: nil)).height,
            subviews[1].sizeThatFits(ProposedViewSize(width: right, height: nil)).height
        )
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (left, right) = widths(total: bounds.width, subviews: subviews)
        let leftProposal = ProposedViewSize(width: left, height: nil)
        let rightProposal = ProposedViewSize(width: right, height: nil)
        let rightWidth = subviews[1].sizeThatFits(rightProposal).width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: leftProposal)
        subviews[1].place(at: CGPoint(x: bounds.maxX - rightWidth, y: bounds.minY), proposal: rightProposal)
    }

    private func widths(total: CGFloat, subviews: Subviews) -> (left: CGFloat, right: CGFloat) {
        let available = max(0, total - spacing)
        let leftIdeal = subviews[0].sizeThatFits(.unspecified).width
        let rightIdeal = subviews[1].sizeThatFits(.unspecified).width
        let right = leftIdeal + rightIdeal <= available
            ? rightIdeal
            : min(rightIdeal, max(available * 0.6, available - leftIdeal))
        return (available - right, right)
    }
}

private struct Rule: View {
    let dashed: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            let style = dashed ? StrokeStyle(lineWidth: 1, dash: [3, 2]) : StrokeStyle(lineWidth: 1)
            context.stroke(path, with: .color(.black), style: style)
        }
        .frame(height: 1)
    }
}
