import Foundation

/// One call to a model, as the usage history lists it.
struct UsageRecord: Equatable, Sendable {
    var time: Date?
    /// The agent that made the call, by its id (`claude`, `codex`, …).
    var agent: String
    var model: String
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var cost: Double = 0

    var isEmpty: Bool { input == 0 && output == 0 && cacheWrite == 0 && cacheRead == 0 && cost == 0 }
}

/// Reads the usage history's CSV export: a header naming the columns, then a row per request.
enum UsageCSV {
    struct Failure: Error, Equatable {
        let message: String
    }

    static func records(from text: String) throws(Failure) -> [UsageRecord] {
        let rows = rows(text)
        // Anything printed before the header (a notice, say) is not data.
        guard let headerIndex = rows.firstIndex(where: { $0.contains("agent") && $0.contains("cost_usd") }) else {
            throw Failure(message: "no usage header in \(rows.count) rows")
        }
        var column: [String: Int] = [:]
        for (index, name) in rows[headerIndex].enumerated() where column[name] == nil {
            column[name] = index
        }
        let parseTime = ISO8601DateFormatter()
        let parseFractionalTime = ISO8601DateFormatter()
        parseFractionalTime.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var records: [UsageRecord] = []
        for row in rows[(headerIndex + 1)...] {
            func field(_ name: String) -> String {
                guard let index = column[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            func count(_ name: String) -> Int { max(0, Int(field(name)) ?? 0) }

            if field("rejected") == "true" { continue }
            // Came in with a key handed to another computer or client: not this Mac's own use.
            if !field("caller_key_id").isEmpty { continue }
            let model = [field("served_model"), field("model"), field("requested_model")].first { !$0.isEmpty } ?? ""
            let time = field("time")
            let record = UsageRecord(
                time: parseTime.date(from: time) ?? parseFractionalTime.date(from: time),
                agent: field("agent"),
                model: model,
                input: count("input_tokens"),
                output: count("output_tokens"),
                cacheWrite: count("cache_write_tokens"),
                cacheRead: count("cache_read_tokens"),
                cost: max(0, Double(field("cost_usd")) ?? 0)
            )
            // Failed requests and health probes: nothing was used.
            if record.isEmpty { continue }
            records.append(record)
        }
        return records
    }

    /// RFC 4180: fields may be quoted, with commas, line breaks and doubled quotes inside.
    static func rows(_ text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var index = 0

        func endRow() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            if row != [""] { rows.append(row) }
            row = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if quoted {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    quoted = true
                case ",":
                    row.append(String(field))
                    field = String.UnicodeScalarView()
                case "\r", "\n":
                    if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                    endRow()
                default:
                    field.append(scalar)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

/// What this Mac spent on models in a day, by model and by agent.
struct DaySpend: Equatable {
    struct Tally: Equatable {
        var name: String
        var calls = 0
        var input = 0
        var output = 0
        var cacheWrite = 0
        var cacheRead = 0
        var cost: Double = 0

        mutating func add(_ record: UsageRecord) {
            calls += 1
            input += record.input
            output += record.output
            cacheWrite += record.cacheWrite
            cacheRead += record.cacheRead
            cost += record.cost
        }

        var tokens: Int { input + output + cacheWrite + cacheRead }
    }

    /// Most expensive first.
    var models: [Tally]
    var agents: [Tally]
    var calls: Int
    var cost: Double

    /// Only the records from `day`'s calendar day count; one without a time is taken as today's,
    /// since the history was already asked for today's.
    init(_ records: [UsageRecord], on day: Date, calendar: Calendar) {
        let today = records.filter { record in
            record.time.map { calendar.isDate($0, inSameDayAs: day) } ?? true
        }
        models = Self.tallies(today, by: { Self.modelName($0.model) })
        agents = Self.tallies(today, by: { Self.agentName($0.agent) })
        calls = today.count
        cost = today.reduce(0) { $0 + $1.cost }
    }

    private static func tallies(_ records: [UsageRecord], by name: (UsageRecord) -> String) -> [Tally] {
        var byName: [String: Tally] = [:]
        for record in records {
            let key = name(record)
            byName[key, default: Tally(name: key)].add(record)
        }
        return byName.values.sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return a.name < b.name
        }
    }

    /// `claude-opus-5-5` → `Opus 5.5`, as the session receipts print it; any longer and it
    /// would not fit beside its price. Other models keep their id, without any `vendor/` in
    /// front of it.
    static func modelName(_ id: String) -> String {
        var bare = String(id.split(separator: "/").last ?? "")
        // A dated snapshot reads as the model it is a snapshot of.
        bare = bare.replacing(/-\d{8}$/, with: "")
        if bare.isEmpty { return "未知模型" }
        if let match = bare.wholeMatch(of: /claude-([a-z]+)-(\d+)(?:-(\d+))?/) {
            return "\(match.1.capitalized) \(match.2)\(match.3.map { ".\($0)" } ?? "")"
        }
        if let match = bare.wholeMatch(of: /claude-(\d+)(?:-(\d+))?-([a-z]+)/) {
            return "\(match.3.capitalized) \(match.1)\(match.2.map { ".\($0)" } ?? "")"
        }
        return bare
    }

    /// Agents by the name people know them by. Scripts, HTTP libraries and anything else
    /// that called a model go under one line.
    static func agentName(_ id: String) -> String {
        knownAgents[id.lowercased()] ?? "其他"
    }

    static let knownAgents: [String: String] = [
        "claude": "Claude Code",
        "claude-desktop": "Claude 桌面版",
        "codex": "Codex",
        "gemini": "Gemini CLI",
        "antigravity": "Antigravity",
        "opencode": "OpenCode",
        "pi": "Pi",
        "dsh": "DeepSeek Harness",
        "cursor": "Cursor",
        "zed": "Zed",
        "copilot": "Copilot",
        "crush": "Crush",
        "goose": "Goose",
        "mimocode": "MiMo Code",
        "deveco": "DevEco",
        "aside": "Aside",
        "t3code": "T3 Code",
        "workbuddy": "WorkBuddy",
    ]
}

/// What the receipt says about the computer.
struct ThisMac: Equatable, Sendable {
    /// The name in Sharing settings, e.g. `xingyi-mbp16`.
    var name: String
    /// The kind of Mac, e.g. `MacBook Pro`.
    var model: String?
    /// e.g. `M1 Max`.
    var chip: String?
}

/// The receipt for a day's spending, in the markup `notchfax print` takes.
enum DailySpendReceipt {
    /// More than this many models or agents and the rest share one line, so the receipt stays
    /// well within the height a sheet can take.
    static let maxModels = 5
    static let maxAgents = 5

    static func text(_ spend: DaySpend, mac: ThisMac, now: Date, calendar: Calendar) -> String {
        var lines = header(mac: mac, now: now, calendar: calendar)
        guard spend.calls > 0 else {
            lines += [
                "^ 今天还没有用过模型",
                "---",
                "# 合计\t$0.00",
                "===",
                "^ > 明天见",
            ]
            return lines.joined(separator: "\n")
        }
        lines.insert("调用\t\(spend.calls) 次", at: lines.count - 1)

        for model in spend.models.prefix(maxModels) {
            lines.append("## \(truncated(model.name, 22))\t\(money(model.cost))")
            // Input and output always; the cache lines only when there is something on them.
            lines.append("> 输入\t\(tokens(model.input))")
            lines.append("> 输出\t\(tokens(model.output))")
            if model.cacheWrite > 0 { lines.append("> 缓存写\t\(tokens(model.cacheWrite))") }
            if model.cacheRead > 0 { lines.append("> 缓存读\t\(tokens(model.cacheRead))") }
        }
        let otherModels = spend.models.dropFirst(maxModels)
        if !otherModels.isEmpty {
            lines.append("## 其他 \(otherModels.count) 个模型\t\(money(otherModels.reduce(0) { $0 + $1.cost }))")
        }

        lines.append("---")
        lines.append("^ > 按助手")
        for agent in spend.agents.prefix(maxAgents) {
            lines.append("\(truncated(agent.name, 18))\t\(money(agent.cost))")
        }
        let otherAgents = spend.agents.dropFirst(maxAgents)
        if !otherAgents.isEmpty {
            lines.append("其他 \(otherAgents.count) 个\t\(money(otherAgents.reduce(0) { $0 + $1.cost }))")
        }

        lines += [
            "---",
            "# 合计\t\(money(spend.cost))",
            "^ > 按标价估算",
            "===",
            "^ > 今天辛苦了 · 明天见",
        ]
        return lines.joined(separator: "\n")
    }

    /// Printed when asked for by hand and the day's usage could not be read.
    static func unavailable(mac: ThisMac, now: Date, calendar: Calendar) -> String {
        (header(mac: mac, now: now, calendar: calendar) + [
            "^ 这会儿查不到今天的用量",
            "^ > 过一会儿再试试",
        ]).joined(separator: "\n")
    }

    /// Title, date, the computer, then a rule; the last line is always that rule.
    private static func header(mac: ThisMac, now: Date, calendar: Calendar) -> [String] {
        let date = DateFormatter()
        date.calendar = calendar
        date.timeZone = calendar.timeZone
        date.locale = Locale(identifier: "zh_CN")
        date.dateFormat = "M月d日 EEEE · 截至 HH:mm"
        var lines = [
            "# 今日 AI 花费",
            "^ > \(date.string(from: now))",
            "---",
            "电脑\t\(truncated(mac.name, 20))",
        ]
        if let model = mac.model { lines.append("机型\t\(truncated(model, 20))") }
        if let chip = mac.chip { lines.append("芯片\t\(truncated(chip, 20))") }
        lines.append("---")
        return lines
    }

    static func money(_ value: Double) -> String {
        if value > 0, value < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    /// Thousands separators under ten thousand, then 万 and 亿.
    static func tokens(_ count: Int) -> String {
        if count < 10_000 {
            var grouped = ""
            for (index, digit) in String(count).reversed().enumerated() {
                if index > 0, index % 3 == 0 { grouped.append(",") }
                grouped.append(digit)
            }
            return String(grouped.reversed())
        }
        if count < 100_000_000 {
            let text = String(format: "%.1f", Double(count) / 10_000)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "万"
        }
        var text = String(format: "%.2f", Double(count) / 100_000_000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "亿"
    }

    static func truncated(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
