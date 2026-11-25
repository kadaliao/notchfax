import Foundation
import Testing

@testable import RemotePrint

private let shanghai: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

/// 2026-11-25 18:30 in Shanghai.
private let evening = shanghai.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 18, minute: 30))!

private let header = "time,agent,requested_model,provider,model,served_model,input_tokens,output_tokens,cache_write_tokens,cache_read_tokens,cost_usd,status,error_message,rejected,caller_key_id"

private func record(_ agent: String, _ model: String, cost: Double, input: Int = 100, output: Int = 50, time: Date? = evening) -> UsageRecord {
    UsageRecord(time: time, agent: agent, model: model, input: input, output: output, cost: cost)
}

@Suite struct UsageCSVTests {
    @Test func readsRowsByColumnName() throws {
        let csv = """
        \(header)
        2026-11-25T08:27:17Z,claude,claude-opus-5-5,session-unknown,claude-opus-5-5,claude-opus-5-5,2,463,905,229852,0.062478,0,,false,
        2026-11-25T09:00:29+08:00,dsh,gpt-6.2-sol,someprovider,gpt-6.2-sol,,91501,2763,0,65536,0.217185,200,,false,
        """
        let records = try UsageCSV.records(from: csv)
        #expect(records == [
            UsageRecord(
                time: Date(timeIntervalSince1970: 1_795_595_237), agent: "claude", model: "claude-opus-5-5",
                input: 2, output: 463, cacheWrite: 905, cacheRead: 229_852, cost: 0.062478
            ),
            UsageRecord(
                time: Date(timeIntervalSince1970: 1_795_568_429), agent: "dsh", model: "gpt-6.2-sol",
                input: 91501, output: 2763, cacheWrite: 0, cacheRead: 65536, cost: 0.217185
            ),
        ])
    }

    @Test func leavesOutWhatThisMacDidNotUse() throws {
        let csv = """
        \(header)
        2026-11-25T08:00:00Z,claude,m,p,m,m,10,10,0,0,0.5,200,,true,
        2026-11-25T08:00:00Z,curl,m,p,m,m,10,10,0,0,0.5,200,,false,key_123
        2026-11-25T08:00:00Z,dsh,probe,p,probe,,0,0,0,0,0,502,"upstream said ""no"", twice",false,
        2026-11-25T08:00:00Z,codex,m,p,m,m,10,10,0,0,0.5,200,,false,
        """
        #expect(try UsageCSV.records(from: csv).map(\.agent) == ["codex"])
    }

    @Test func skipsWhatComesBeforeTheHeader() throws {
        let csv = "a newer version is out\n\(header)\n2026-11-25T08:00:00Z,codex,m,p,m,m,10,10,0,0,0.5,200,,false,\n"
        #expect(try UsageCSV.records(from: csv).count == 1)
        #expect(throws: UsageCSV.Failure.self) { try UsageCSV.records(from: "nothing here\n") }
    }

    @Test func quotedFields() {
        #expect(UsageCSV.rows("a,\"b, \"\"c\"\"\nd\",e\r\nf\n\n") == [["a", "b, \"c\"\nd", "e"], ["f"]])
    }
}

@Suite struct DaySpendTests {
    @Test func talliesByModelAndAgentMostExpensiveFirst() {
        let spend = DaySpend([
            record("claude", "claude-opus-5-5", cost: 2),
            record("claude", "claude-opus-5-5", cost: 1),
            record("dsh", "gpt-6.2-sol", cost: 0.5),
            record("magpie", "openai/gpt-image-2", cost: 0.25),
            record("Python-urllib", "gpt-6.2-sol", cost: 0.25),
        ], on: evening, calendar: shanghai)

        #expect(spend.models.map(\.name) == ["Opus 5.5", "gpt-6.2-sol", "gpt-image-2"])
        #expect(spend.models[0].calls == 2)
        #expect(spend.models[0].cost == 3)
        #expect(spend.agents.map(\.name) == ["Claude Code", "其他", "DeepSeek Harness"])
        #expect(spend.calls == 5)
        #expect(spend.cost == 4)
    }

    @Test func onlyTheDayAsked() {
        let yesterday = shanghai.date(byAdding: .day, value: -1, to: evening)!
        let spend = DaySpend([
            record("codex", "a", cost: 1),
            record("codex", "a", cost: 5, time: yesterday),
            record("codex", "a", cost: 2, time: nil),
        ], on: evening, calendar: shanghai)
        #expect(spend.cost == 3)
    }

    @Test func modelNames() {
        #expect(DaySpend.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(DaySpend.modelName("claude-opus-5") == "Opus 5")
        #expect(DaySpend.modelName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(DaySpend.modelName("claude-3-5-haiku") == "Haiku 3.5")
        #expect(DaySpend.modelName("openai/gpt-image-2.6-sunburst") == "gpt-image-2.6-sunburst")
        #expect(DaySpend.modelName("") == "未知模型")
    }
}

@Suite @MainActor struct DailySpendReceiptTests {
    let mac = ThisMac(name: "xingyi-mbp16", model: "MacBook Pro", chip: "M1 Max")

    @Test func numbers() {
        #expect(DailySpendReceipt.tokens(0) == "0")
        #expect(DailySpendReceipt.tokens(9_999) == "9,999")
        #expect(DailySpendReceipt.tokens(10_000) == "1万")
        #expect(DailySpendReceipt.tokens(1_012_345) == "101.2万")
        #expect(DailySpendReceipt.tokens(172_824_010) == "1.73亿")
        #expect(DailySpendReceipt.tokens(200_000_000) == "2亿")
        #expect(DailySpendReceipt.money(0) == "$0.00")
        #expect(DailySpendReceipt.money(0.002) == "<$0.01")
        #expect(DailySpendReceipt.money(74.105) == "$74.11")
    }

    @Test func layout() {
        let spend = DaySpend([
            UsageRecord(time: evening, agent: "claude", model: "claude-opus-5-5", input: 1950, output: 1_012_345, cacheWrite: 2_431_000, cacheRead: 172_824_010, cost: 74.45),
            UsageRecord(time: evening, agent: "dsh", model: "gpt-6.2-sol", input: 91501, output: 2763, cost: 0.22),
        ], on: evening, calendar: shanghai)
        #expect(DailySpendReceipt.text(spend, mac: mac, now: evening, calendar: shanghai) == """
        # 今日 AI 花费
        ^ > 11月25日 星期三 · 截至 18:30
        ---
        电脑\txingyi-mbp16
        机型\tMacBook Pro
        芯片\tM1 Max
        调用\t2 次
        ---
        ## Opus 5.5\t$74.45
        > 输入\t1,950
        > 输出\t101.2万
        > 缓存写\t243.1万
        > 缓存读\t1.73亿
        ## gpt-6.2-sol\t$0.22
        > 输入\t9.2万
        > 输出\t2,763
        ---
        ^ > 按助手
        Claude Code\t$74.45
        DeepSeek Harness\t$0.22
        ---
        # 合计\t$74.67
        ^ > 按标价估算
        ===
        ^ > 今天辛苦了 · 明天见
        """)
    }

    @Test func aQuietDay() {
        let text = DailySpendReceipt.text(DaySpend([], on: evening, calendar: shanghai), mac: ThisMac(name: "mini"), now: evening, calendar: shanghai)
        #expect(text.contains("今天还没有用过模型"))
        #expect(text.contains("# 合计\t$0.00"))
        #expect(!text.contains("机型"))
    }

    /// The receipt names the computer, never the tool the numbers came from.
    @Test func saysNothingOfWhereTheNumbersCameFrom() {
        let spend = DaySpend([
            record("magpie", "openai/gpt-image-2", cost: 1),
            record("claude", "claude-opus-5-5", cost: 2),
        ], on: evening, calendar: shanghai)
        let texts = [
            DailySpendReceipt.text(spend, mac: mac, now: evening, calendar: shanghai),
            DailySpendReceipt.unavailable(mac: mac, now: evening, calendar: shanghai),
        ]
        for text in texts {
            #expect(!text.lowercased().contains("magpie"))
            #expect(!text.lowercased().contains("openai/"))
        }
    }

    /// The most a receipt can hold: every model and agent line, long names, cache lines on all.
    @Test func theLongestReceiptFitsOnASheet() throws {
        var records: [UsageRecord] = []
        for index in 0..<9 {
            records.append(UsageRecord(
                time: evening, agent: Array(DaySpend.knownAgents.keys).sorted()[index],
                model: "a-rather-long-model-name-number-\(index)",
                input: 123_456_789, output: 98_765_432, cacheWrite: 12_345_678, cacheRead: 987_654_321, cost: Double(100 - index)
            ))
        }
        let spend = DaySpend(records, on: evening, calendar: shanghai)
        let long = ThisMac(name: "一台名字起得特别特别特别长的 MacBook Pro", model: "MacBook Pro", chip: "8-Core Intel Core i9")
        let text = DailySpendReceipt.text(spend, mac: long, now: evening, calendar: shanghai)
        #expect(text.contains("## 其他 4 个模型"))
        #expect(text.contains("其他 4 个\t"))
        _ = try RemoteJobs.job(for: PrintRequest(text: text))
    }

    @Test func chipNames() {
        #expect(ThisMac.chipName("Apple M1 Max") == "M1 Max")
        #expect(ThisMac.chipName("8-Core Intel Core i9") == "8-Core Intel Core i9")
        #expect(ThisMac.chipName(nil) == nil)
    }
}
