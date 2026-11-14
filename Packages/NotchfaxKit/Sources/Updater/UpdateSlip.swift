import PrintKit
import SwiftUI

/// What an update slip says. Every slip has the same shape: the machine's name and a tag
/// in the header, a line in bold, a few lines under it, and a footnote.
struct UpdateSlip: Equatable {
    var tag: String
    var title: String
    var lines: [String] = []
    var bullets: [String] = []
    var footnote: String?

    static func ready(_ version: AppVersion, current: AppVersion, notes: [String]) -> UpdateSlip {
        UpdateSlip(
            tag: "新版本",
            title: "\(version) 已经下好了",
            lines: ["现在用的是 \(current)。"],
            bullets: notes,
            footnote: "重启 Notchfax 就换上新版本。不理它的话，下次退出时自动装好。"
        )
    }

    static func manual(_ version: AppVersion, current: AppVersion, notes: [String], reason: String) -> UpdateSlip {
        UpdateSlip(
            tag: "新版本",
            title: "\(version) 出来了",
            lines: ["现在用的是 \(current)。"],
            bullets: notes,
            footnote: reason
        )
    }

    static func upToDate(_ current: AppVersion) -> UpdateSlip {
        UpdateSlip(tag: "检查更新", title: "已经是最新版本", lines: ["Notchfax \(current)"])
    }

    /// Without a version the check itself failed; with one, getting or installing that version did.
    static func failed(_ error: UpdateError, version: AppVersion? = nil) -> UpdateSlip {
        guard let version else { return UpdateSlip(tag: "检查更新", title: "没能检查更新", lines: [error.message]) }
        return UpdateSlip(tag: "新版本", title: "没能更新到 \(version)", lines: [error.message], footnote: "可以到发布页自己下载。")
    }

    static func installed(_ version: AppVersion, from previous: AppVersion?) -> UpdateSlip {
        UpdateSlip(
            tag: "已更新",
            title: "现在是 \(version)",
            lines: previous.map { ["从 \($0) 换过来了。"] } ?? []
        )
    }

    /// Roughly how long it takes to read.
    var readingTime: TimeInterval {
        let characters = ([title, footnote ?? ""] + lines + bullets).reduce(0) { $0 + $1.count }
        return min(24, max(5, Double(characters) / 12))
    }
}

struct UpdateSlipView: View {
    let slip: UpdateSlip

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("NOTCHFAX").font(.system(size: 8, weight: .heavy, design: .monospaced)).tracking(1.2)
                Spacer()
                Text(slip.tag).font(.system(size: 7, weight: .medium, design: .monospaced))
            }
            Rule()
            Text(slip.title)
                .font(.system(size: 13, weight: .semibold))
            ForEach(Array(slip.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 9.5, weight: .medium))
                    .lineSpacing(3)
            }
            if !slip.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(slip.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("·").font(.system(size: 9.5, weight: .bold))
                            Text(bullet).font(.system(size: 9.5, weight: .medium)).lineSpacing(2.5)
                        }
                    }
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) { Rectangle().frame(width: 1.5) }
            }
            if let footnote = slip.footnote {
                Rule()
                Text(footnote)
                    .font(.system(size: 7.5, weight: .medium))
                    .lineSpacing(2.5)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.black)
    }

    private struct Rule: View {
        var body: some View {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(height: 1)
        }
    }
}
