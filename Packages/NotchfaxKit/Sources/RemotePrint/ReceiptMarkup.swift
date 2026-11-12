import Foundation

/// One printed line of a receipt.
public struct ReceiptLine: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case body
        case bold
        /// Large and heavy; centred unless it has a right-hand column.
        case title
        /// Fine print.
        case small
    }

    public enum Kind: Equatable, Sendable {
        /// `right` is set flush right on the same line, the way a receipt prints a price.
        case text(left: String, right: String?)
        case rule(dashed: Bool)
        /// A blank line in the source.
        case gap
    }

    public var kind: Kind
    public var style: Style
    public var centered: Bool

    public init(_ kind: Kind, style: Style = .body, centered: Bool = false) {
        self.kind = kind
        self.style = style
        self.centered = centered
    }
}

/// A small line-based markup for receipts. Anything else prints as it is written.
///
/// | Line | Prints |
/// |---|---|
/// | `# 标题` | large heavy type, centred |
/// | `## 文字` | bold |
/// | `> 文字` | fine print |
/// | `^ 文字` | centred (combines with the others: `^ > 谢谢惠顾`) |
/// | `---` | dashed rule |
/// | `===` | solid rule |
/// | `左<Tab>右` | two columns, the right one flush right (works with every style) |
/// | blank line | a little space |
public enum ReceiptMarkup {
    public static func parse(_ source: String) -> [ReceiptLine] {
        let rawLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var lines: [ReceiptLine] = []
        for raw in rawLines {
            let line = parseLine(raw)
            // Runs of blank lines are one gap.
            if line.kind == .gap, lines.last?.kind == .gap { continue }
            lines.append(line)
        }
        while lines.first?.kind == .gap { lines.removeFirst() }
        while lines.last?.kind == .gap { lines.removeLast() }
        return lines
    }

    static func parseLine(_ raw: String) -> ReceiptLine {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ReceiptLine(.gap) }
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) { return ReceiptLine(.rule(dashed: true)) }
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "=" }) { return ReceiptLine(.rule(dashed: false)) }

        var rest = Substring(raw)
        var style = ReceiptLine.Style.body
        var centered = false
        prefixes: while true {
            for (prefix, apply) in prefixRules {
                if rest.hasPrefix(prefix) {
                    rest = rest.dropFirst(prefix.count)
                    apply(&style, &centered)
                    continue prefixes
                }
            }
            break
        }

        var left = String(rest)
        var right: String?
        if let tab = left.firstIndex(of: "\t") {
            let column = left[left.index(after: tab)...]
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            left = String(left[..<tab])
            right = column.isEmpty ? nil : column
        }
        left = left.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        if style == .title, right == nil { centered = true }
        return ReceiptLine(.text(left: left, right: right), style: style, centered: centered)
    }

    /// Longest first, so `## ` is not read as `# `.
    private static let prefixRules: [(String, @Sendable (inout ReceiptLine.Style, inout Bool) -> Void)] = [
        ("## ", { style, _ in style = .bold }),
        ("# ", { style, _ in style = .title }),
        ("> ", { style, _ in style = .small }),
        ("^ ", { _, centered in centered = true }),
    ]
}
